#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$ROOT_DIR/mc_workdir"
MAIN_DIR="$ROOT_DIR/mc_maindir"
ARTIFACT_DIR="$ROOT_DIR/artifacts"
CRASH_DIR="$WORK_DIR/crash-reports"
mkdir -p "$WORK_DIR" "$MAIN_DIR" "$ARTIFACT_DIR"
LOG_FILE="$ARTIFACT_DIR/minecraft.log"
: >"$LOG_FILE"
rm -rf "$WORK_DIR/saves" "$WORK_DIR/screenshots" "$CRASH_DIR"
mkdir -p "$WORK_DIR/saves" "$WORK_DIR/screenshots"

PORTABLEMC="$HOME/.local/bin/portablemc"
[[ -x "$PORTABLEMC" ]] || python3 -m pip install --user portablemc

if ! command -v Xvfb >/dev/null || ! command -v xdotool >/dev/null || ! command -v import >/dev/null; then
  apt-get update -y >/dev/null
  apt-get install -y xvfb xdotool imagemagick libgl1-mesa-dri mesa-utils \
    libx11-6 libxrandr2 libxinerama1 libxcursor1 libxi6 libxext6 libxrender1 \
    libxtst6 libxcb1 >/dev/null
fi

# 拉取元数据（含官方 + 镜像兜底）
python3 - "$MAIN_DIR" "$LOG_FILE" <<'PY'
import json, urllib.request
from pathlib import Path
import sys
main_dir=Path(sys.argv[1]); log=Path(sys.argv[2])
mirrors=[
    "https://piston-meta.mojang.com",
    "https://bmclapi2.bangbang93.com",
    "https://download.mcbbs.net",
]

def fetch_json(urls, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    for u in urls:
        try:
            req=urllib.request.Request(u,headers={'User-Agent':'Mozilla/5.0'})
            with urllib.request.urlopen(req,timeout=20) as r:
                data=r.read()
            target.write_bytes(data)
            return True
        except Exception:
            continue
    return False

ver_dir=main_dir/"versions/1.21.8"
ver_json=ver_dir/"1.21.8.json"
manifest=main_dir/"version_manifest_v2.json"
if not ver_json.exists():
    if not manifest.exists():
        fetch_json([f"{m}/mc/game/version_manifest_v2.json" for m in mirrors], manifest)
    if manifest.exists():
        try:
            mf=json.loads(manifest.read_text(encoding="utf-8"))
            url=None
            for v in mf.get("versions",[]):
                if v.get("id")=="1.21.8":
                    url=v.get("url")
                    break
            if url:
                fetch_json([url], ver_json)
        except Exception:
            pass
    if not ver_json.exists():
        with open(log,"a",encoding="utf-8") as fp:
            fp.write("warning: failed to fetch 1.21.8.json\n")
PY

"$PORTABLEMC" --timeout 40 --work-dir "$WORK_DIR" --main-dir "$MAIN_DIR" start --dry --jvm "$(command -v java)" 1.21.8 -u AutoBot >>"$LOG_FILE" 2>&1 || true
"$PORTABLEMC" --timeout 40 --work-dir "$WORK_DIR" --main-dir "$MAIN_DIR" start --dry --jvm "$(command -v java)" fabric:1.21.8 -u AutoBot >>"$LOG_FILE" 2>&1 || true

# 多线路全量预取（官方 + BMCLAPI + MCBBS）
python3 - "$MAIN_DIR" "$LOG_FILE" <<'PY'
import concurrent.futures as cf, hashlib, json, urllib.request
from pathlib import Path
import sys
main_dir=Path(sys.argv[1]); log=Path(sys.argv[2])
mirrors=["https://bmclapi2.bangbang93.com","https://download.mcbbs.net"]
van_path=main_dir/'versions/1.21.8/1.21.8.json'
fab_path=main_dir/'versions/fabric-1.21.8-0.18.4/fabric-1.21.8-0.18.4.json'
if not van_path.exists():
    raise SystemExit("missing 1.21.8.json; run portablemc --dry first")
van=json.load(open(van_path))
fab=json.load(open(fab_path)) if fab_path.exists() else {"libraries":[]}
asset_meta=van.get("assetIndex",{})
asset_id=asset_meta.get("id","26")
assets_path=main_dir/f"assets/indexes/{asset_id}.json"
if not assets_path.exists() and asset_meta.get("url"):
    assets_path.parent.mkdir(parents=True, exist_ok=True)
    req=urllib.request.Request(asset_meta["url"],headers={'User-Agent':'Mozilla/5.0'})
    try:
        with urllib.request.urlopen(req,timeout=20) as r:
            assets_path.write_bytes(r.read())
    except Exception:
        pass
assets=json.load(open(assets_path))
jobs=[]
client=van['downloads']['client']
jobs.append((client['url'], main_dir/'versions/1.21.8/1.21.8.jar', client['sha1']))
jobs.append((client['url'], main_dir/'versions/fabric-1.21.8-0.18.4/fabric-1.21.8-0.18.4.jar', client['sha1']))
lf=van.get('logging',{}).get('client',{}).get('file',{})
if lf.get('url') and lf.get('sha1') and lf.get('id'):
    jobs.append((lf['url'], main_dir/'assets/log_configs'/lf['id'], lf['sha1']))
libs=van.get('libraries',[])+fab.get('libraries',[])
seen=set()
for lib in libs:
    d=lib.get('downloads',{}).get('artifact')
    if d and d.get('path'):
        p=d['path']
        if p in seen: continue
        seen.add(p); jobs.append((d.get('url'), main_dir/'libraries'/p, d.get('sha1'))); continue
    n=lib.get('name')
    if not n: continue
    sp=n.split(':')
    if len(sp)<3: continue
    g,a,v=sp[:3]; c=sp[3] if len(sp)>3 else None
    p=f"{g.replace('.', '/')}/{a}/{v}/{a}-{v}"+(f"-{c}" if c else "")+".jar"
    if p in seen: continue
    seen.add(p)
    base=lib.get('url','https://libraries.minecraft.net/')
    if not base.endswith('/'): base+='/';
    jobs.append((base+p, main_dir/'libraries'/p, None))
for o in assets['objects'].values():
    h=o['hash']; rel=f"{h[:2]}/{h}"
    jobs.append((f"https://resources.download.minecraft.net/{rel}", main_dir/'assets/objects'/rel, h))

def cands(u):
    r=[u]
    if u.startswith('https://libraries.minecraft.net/'):
        t=u.split('https://libraries.minecraft.net/')[1]; r += [f"{m}/maven/{t}" for m in mirrors]
    elif u.startswith('https://maven.fabricmc.net/'):
        t=u.split('https://maven.fabricmc.net/')[1]; r += [f"{m}/maven/{t}" for m in mirrors]
    elif u.startswith('https://resources.download.minecraft.net/'):
        t=u.split('https://resources.download.minecraft.net/')[1]; r += [f"{m}/assets/{t}" for m in mirrors]
    elif u.startswith('https://piston-data.mojang.com/'):
        t=u.split('https://piston-data.mojang.com/')[1]; r += [f"{m}/{t}" for m in mirrors]
    else:
        t=u.split('https://',1)[-1].split('/',1)[-1]; r += [f"{m}/{t}" for m in mirrors]
    return list(dict.fromkeys(r))

def sha(p):
    h=hashlib.sha1()
    with open(p,'rb') as f:
        for b in iter(lambda:f.read(1<<20),b''): h.update(b)
    return h.hexdigest()

def fetch(job):
    u,t,s=job; t.parent.mkdir(parents=True,exist_ok=True)
    if t.exists() and (not s or sha(t)==s): return True
    tmp=t.with_suffix(t.suffix+'.part')
    for cu in cands(u):
        try:
            req=urllib.request.Request(cu,headers={'User-Agent':'Mozilla/5.0'})
            with urllib.request.urlopen(req,timeout=20) as r, open(tmp,'wb') as w:
                for b in iter(lambda:r.read(1<<19), b''):
                    if not b: break
                    w.write(b)
            if s and sha(tmp)!=s:
                tmp.unlink(missing_ok=True); continue
            tmp.replace(t); return True
        except Exception:
            tmp.unlink(missing_ok=True)
    return False

ok=0
with cf.ThreadPoolExecutor(max_workers=24) as ex:
    for res in ex.map(fetch,jobs):
        ok += 1 if res else 0
with open(log,'a',encoding='utf-8') as fp:
    fp.write(f"prefetch total={len(jobs)} ok={ok}\n")
if ok < len(jobs):
    raise SystemExit(2)
PY

for i in {1..8}; do
  if "$PORTABLEMC" --timeout 40 --work-dir "$WORK_DIR" --main-dir "$MAIN_DIR" start --dry --jvm "$(command -v java)" fabric:1.21.8 -u AutoBot >>"$LOG_FILE" 2>&1; then
    break
  fi
  # 再次尝试补齐残缺文件
  "$PORTABLEMC" --timeout 40 --work-dir "$WORK_DIR" --main-dir "$MAIN_DIR" start --dry --jvm "$(command -v java)" fabric:1.21.8 -u AutoBot >>"$LOG_FILE" 2>&1 || true
  sleep 3
done
"$PORTABLEMC" --timeout 40 --work-dir "$WORK_DIR" --main-dir "$MAIN_DIR" start --dry --jvm "$(command -v java)" fabric:1.21.8 -u AutoBot >>"$LOG_FILE" 2>&1

rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
Xvfb :99 -screen 0 1280x720x24 -ac +extension GLX +render -noreset >/tmp/xvfb-mc.log 2>&1 &
XVFB_PID=$!
trap 'kill $XVFB_PID 2>/dev/null || true; kill ${MC_PID:-0} 2>/dev/null || true' EXIT
for _ in {1..20}; do
  [[ -S /tmp/.X11-unix/X99 ]] && break
  sleep 0.5
done
[[ -S /tmp/.X11-unix/X99 ]] || { echo "Xvfb failed to start" >&2; exit 1; }
export DISPLAY=:99
export LIBGL_ALWAYS_SOFTWARE=1
export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
export GLFW_PLATFORM=x11

"$PORTABLEMC" --timeout 40 --work-dir "$WORK_DIR" --main-dir "$MAIN_DIR" start --jvm "$(command -v java)" fabric:1.21.8 -u AutoBot --resolution 1280x720 >>"$LOG_FILE" 2>&1 &
MC_PID=$!

for _ in {1..300}; do
  WIN_ID=$(xdotool search --name "Minecraft" 2>/dev/null | head -n1 || true)
  [[ -n "${WIN_ID:-}" ]] && break
  if ls "$CRASH_DIR"/*.txt >/dev/null 2>&1; then
    echo "minecraft crashed (see crash-reports)" >&2
    exit 1
  fi
  sleep 1
done
[[ -n "${WIN_ID:-}" ]] || { echo "minecraft window not found" >&2; exit 1; }

# 等到主界面稳定
sleep 70

# 首次启动可能出现欢迎弹窗，先点 Continue 关闭
xdotool mousemove --window "$WIN_ID" 640 670 click 1
sleep 2

# 标题 -> 单人 -> 创建新世界
xdotool mousemove --window "$WIN_ID" 640 350 click 1
sleep 2
xdotool mousemove --window "$WIN_ID" 390 590 click 1
sleep 4
# 若仍在选世界界面，点击创建新世界
xdotool mousemove --window "$WIN_ID" 820 590 click 1
sleep 3

# 世界参数：切超平坦 + 开作弊
xdotool mousemove --window "$WIN_ID" 640 35 click 1
sleep 1
xdotool mousemove --window "$WIN_ID" 400 130 click 1
sleep 1
xdotool mousemove --window "$WIN_ID" 260 35 click 1
sleep 1
xdotool mousemove --window "$WIN_ID" 640 420 click 1
sleep 1

# 创建世界
xdotool mousemove --window "$WIN_ID" 390 670 click 1
sleep 45

# 额外强制整理与固定拍摄位
xdotool key t; sleep 1; xdotool type --delay 1 "/gamemode creative"; xdotool key Return; sleep 1
xdotool key t; sleep 1; xdotool type --delay 1 "/tp @s 0 300 0"; xdotool key Return; sleep 1
xdotool key t; sleep 1; xdotool type --delay 1 "/fill -20 299 -20 20 299 20 grass_block"; xdotool key Return; sleep 1
xdotool key t; sleep 1; xdotool type --delay 1 "/fill -20 300 -20 20 330 20 air"; xdotool key Return; sleep 1
xdotool key t; sleep 1; xdotool type --delay 1 "/setblock 0 300 3 stone"; xdotool key Return; sleep 1
xdotool key t; sleep 1; xdotool type --delay 1 "/tp @s 0 300 0 0 0"; xdotool key Return; sleep 1

# 必须使用刷怪蛋生成僵尸
xdotool key t; sleep 1; xdotool type --delay 1 "/clear @s minecraft:zombie_spawn_egg"; xdotool key Return; sleep 1
xdotool key t; sleep 1; xdotool type --delay 1 "/item replace entity @s hotbar.0 with minecraft:zombie_spawn_egg"; xdotool key Return; sleep 1
xdotool key 1
sleep 1
xdotool key t; sleep 1; xdotool type --delay 1 "/tp @s 0 300 0 0 30"; xdotool key Return; sleep 1
xdotool click 3
sleep 1
xdotool click 3
sleep 1
xdotool click 3
sleep 1
xdotool key t; sleep 1; xdotool type --delay 1 "/effect give @e[type=minecraft:zombie,sort=nearest,limit=1] glowing 120 0 true"; xdotool key Return; sleep 1
xdotool key t; sleep 1; xdotool type --delay 1 "/tp @e[type=minecraft:zombie,sort=nearest,limit=1] 0 300 3"; xdotool key Return; sleep 1
xdotool key t; sleep 1; xdotool type --delay 1 "/tp @s 0 300 0 facing 0 300 3"; xdotool key Return; sleep 2
xdotool key F2
sleep 2
import -display :99 -window root "$ARTIFACT_DIR/final_fullscreen.png"
LATEST=$(find "$WORK_DIR/screenshots" -type f -name '*.png' | sort | tail -n1 || true)
if [[ -n "$LATEST" ]]; then
  cp "$LATEST" "$ARTIFACT_DIR/minecraft_f2.png"
  base64 -w 0 "$LATEST" >"$ARTIFACT_DIR/minecraft_f2.png.txt"
  echo >>"$ARTIFACT_DIR/minecraft_f2.png.txt"
fi

echo "Done. Artifacts in $ARTIFACT_DIR"
