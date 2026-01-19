from __future__ import annotations

import os
import uuid
import urllib.request
from pathlib import Path
from typing import Any, Optional

import modal

MODEL_REPO_ID = "IndexTeam/IndexTTS-2"
DEFAULT_PROMPT_WAV_URL = (
    "https://huggingface.co/spaces/IndexTeam/IndexTTS-2-Demo/resolve/main/examples/voice_01.wav"
)

MODEL_VOLUME = modal.Volume.from_name("indextts2-models", create_if_missing=True)

image = (
    modal.Image.from_registry(
        "pytorch/pytorch:2.2.2-cuda12.1-cudnn8-runtime",
    )
    .apt_install(
        "ffmpeg",
        "libsndfile1",
    )
    .pip_install(
        # Core runtime
        "huggingface_hub>=0.20",
        "transformers==4.52.1",
        "tokenizers==0.21.0",
        "accelerate==1.8.1",
        "sentencepiece",
        "safetensors==0.5.2",
        "omegaconf",
        "fastapi",
        # Text normalization / G2P
        "cn2an==0.5.22",
        "jieba==0.42.1",
        "g2p-en==2.1.0",
        "textstat",
        "WeTextProcessing",
        # Audio
        "librosa==0.10.2.post1",
        "ffmpeg-python==0.2.0",
        "descript-audiotools==0.7.2",
        "munch==4.0.0",
        "json5==0.10.0",
        # Emotion model
        "modelscope==1.27.0",
    )
)

app = modal.App("indextts2-no-gradio")


def _download_to_path(url: str, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_suffix(dst.suffix + ".tmp")
    with urllib.request.urlopen(url) as r, tmp.open("wb") as f:
        while True:
            chunk = r.read(1024 * 1024)
            if not chunk:
                break
            f.write(chunk)
    tmp.replace(dst)


def _ensure_model_downloaded(model_dir: Path, hf_cache_dir: Path) -> None:
    cfg_path = model_dir / "config.yaml"
    if cfg_path.exists():
        return

    from huggingface_hub import snapshot_download

    model_dir.mkdir(parents=True, exist_ok=True)
    hf_cache_dir.mkdir(parents=True, exist_ok=True)

    snapshot_download(
        repo_id=MODEL_REPO_ID,
        local_dir=str(model_dir),
    )


@app.cls(
    image=image,
    gpu="A10G",
    timeout=60 * 60,
    container_idle_timeout=10 * 60,
    concurrency_limit=1,
    volumes={"/model": MODEL_VOLUME},
)
class IndexTTS2Service:
    def __init__(self):
        self.tts = None
        self.model_dir = Path("/model/checkpoints")
        self.hf_cache_dir = Path("/model/hf_cache")
        self.default_prompt_path = Path("/model/prompts/default_prompt.wav")

    @modal.enter()
    def load(self) -> None:
        os.environ["HF_HUB_CACHE"] = str(self.hf_cache_dir)
        os.environ["TRANSFORMERS_CACHE"] = str(self.hf_cache_dir)
        os.environ["HF_HOME"] = str(Path("/model/hf_home"))

        _ensure_model_downloaded(self.model_dir, self.hf_cache_dir)
        if not self.default_prompt_path.exists():
            _download_to_path(DEFAULT_PROMPT_WAV_URL, self.default_prompt_path)

        MODEL_VOLUME.commit()

        from indextts.infer_v2 import IndexTTS2

        self.tts = IndexTTS2(
            model_dir=str(self.model_dir),
            cfg_path=str(self.model_dir / "config.yaml"),
            use_fp16=True,
            use_deepspeed=False,
            use_cuda_kernel=True,
        )

    def _download_wav_to_tmp(self, url: str) -> str:
        tmp_path = Path("/tmp") / f"prompt_{uuid.uuid4().hex}.wav"
        _download_to_path(url, tmp_path)
        return str(tmp_path)

    @modal.method()
    def infer_wav_bytes(
        self,
        *,
        text: str,
        prompt_wav_url: Optional[str] = None,
        emo_wav_url: Optional[str] = None,
        emo_alpha: float = 1.0,
        max_text_tokens_per_segment: int = 120,
        generation_kwargs: Optional[dict[str, Any]] = None,
    ) -> bytes:
        if self.tts is None:
            raise RuntimeError("Model not initialized")

        spk_prompt_path = (
            self._download_wav_to_tmp(prompt_wav_url)
            if prompt_wav_url
            else str(self.default_prompt_path)
        )

        if emo_wav_url:
            emo_prompt_path = self._download_wav_to_tmp(emo_wav_url)
        else:
            emo_prompt_path = None

        out_path = Path("/tmp") / f"indextts2_{uuid.uuid4().hex}.wav"

        self.tts.infer(
            spk_audio_prompt=spk_prompt_path,
            text=text,
            output_path=str(out_path),
            emo_audio_prompt=emo_prompt_path,
            emo_alpha=float(emo_alpha),
            max_text_tokens_per_segment=int(max_text_tokens_per_segment),
            **(generation_kwargs or {}),
        )

        return out_path.read_bytes()


@app.function(image=image)
@modal.web_endpoint(method="POST")
def infer(request: dict[str, Any]) -> Any:
    from fastapi.responses import Response

    text = request.get("text")
    if not isinstance(text, str) or not text.strip():
        return {"error": "Missing required field: text"}

    audio_bytes = IndexTTS2Service().infer_wav_bytes.remote(
        text=text,
        prompt_wav_url=request.get("prompt_wav_url"),
        emo_wav_url=request.get("emo_wav_url"),
        emo_alpha=request.get("emo_alpha", 1.0),
        max_text_tokens_per_segment=request.get("max_text_tokens_per_segment", 120),
        generation_kwargs=request.get("generation_kwargs"),
    )

    return Response(content=audio_bytes, media_type="audio/wav")


@app.local_entrypoint()
def main(
    text: str = "Hello from IndexTTS-2",
    out: str = "out.wav",
    prompt_wav_url: Optional[str] = None,
    emo_wav_url: Optional[str] = None,
    emo_alpha: float = 1.0,
):
    audio_bytes = IndexTTS2Service().infer_wav_bytes.remote(
        text=text,
        prompt_wav_url=prompt_wav_url,
        emo_wav_url=emo_wav_url,
        emo_alpha=emo_alpha,
    )

    Path(out).write_bytes(audio_bytes)
    print(f"Wrote: {out}")
