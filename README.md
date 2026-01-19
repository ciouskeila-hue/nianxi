# IndexTTS-2 (no Gradio) – Modal deployment

This repo removes the Gradio-based WebUI from the original Hugging Face Space and instead provides a **Modal** deployment for IndexTTS-2 inference.

## Files

- `modal_app.py`: Modal app (GPU) exposing an HTTP endpoint and a CLI-style entrypoint for inference.
- `requirements.txt`: lightweight deps for local development (`modal`).
- `requirements.inference.txt`: full deps if you want to run inference locally (not required for Modal).

## Deploy to Modal

1. Install the Modal CLI / SDK locally:

```bash
pip install -r requirements.txt
```

2. Authenticate with Modal (use your own token):

```bash
modal token set
```

3. Deploy:

```bash
modal deploy modal_app.py
```

## Test inference

Run a one-off inference job (runs remotely on Modal GPU and writes `out.wav` locally):

```bash
modal run modal_app.py --text "Hello from IndexTTS-2" --out out.wav
```

## HTTP API

After `modal deploy`, Modal will print a public URL for the web endpoint.

Example request:

```bash
curl -X POST \
  -H 'Content-Type: application/json' \
  -d '{"text":"Hello from IndexTTS-2"}' \
  "<YOUR_MODAL_ENDPOINT_URL>" \
  --output out.wav
```

Optional JSON fields:

- `prompt_wav_url`: URL to a reference speaker WAV file.
- `emo_wav_url`: URL to an emotion reference WAV file.
- `emo_alpha`: float, emotion mixing strength (default `1.0`).
