#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="$ROOT_DIR/.mc-automation"
SERVER_DIR="$RUN_DIR/fabric-server-1.21.8"
NODE_DIR="$RUN_DIR/node"
LOG_DIR="$RUN_DIR/logs"
SCREENSHOT_PATH="$ROOT_DIR/output/zombie_spawn_result.png"
VIEWER_PORT="${VIEWER_PORT:-3007}"
MC_PORT="${MC_PORT:-25565}"
BOT_NAME="${BOT_NAME:-CodexBot}"

mkdir -p "$SERVER_DIR" "$NODE_DIR" "$LOG_DIR" "$ROOT_DIR/output"

cleanup() {
  set +e
  [[ -n "${BOT_PID:-}" ]] && kill "$BOT_PID" >/dev/null 2>&1
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" >/dev/null 2>&1
}
trap cleanup EXIT

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }
}

need_cmd curl
need_cmd jq
need_cmd java
need_cmd node
need_cmd npm
need_cmd python3

if [[ ! -f "$SERVER_DIR/server.jar" ]]; then
  echo "Downloading Fabric server launcher for Minecraft 1.21.8 ..."
  curl -fsSL "https://meta.fabricmc.net/v2/versions/loader/1.21.8" | jq -e 'length > 0' >/dev/null
  curl -fsSL "https://meta.fabricmc.net/v2/versions/loader/1.21.8" | jq -r '.[0].loader.version' > "$SERVER_DIR/.loader_version"
  LOADER_VERSION="$(cat "$SERVER_DIR/.loader_version")"
  INSTALLER_VERSION="$(curl -fsSL https://meta.fabricmc.net/v2/versions/installer | jq -r '.[0].version')"
  curl -fsSL "https://meta.fabricmc.net/v2/versions/loader/1.21.8/${LOADER_VERSION}/${INSTALLER_VERSION}/server/jar" -o "$SERVER_DIR/server.jar"
fi

cat > "$SERVER_DIR/eula.txt" <<EOT
eula=true
EOT

cat > "$SERVER_DIR/server.properties" <<EOT
motd=Fabric 1.21.8 Auto Test
enable-command-block=true
enable-rcon=false
online-mode=false
spawn-monsters=true
difficulty=easy
gamemode=creative
level-seed=123456789
level-type=minecraft\:flat
generate-structures=false
allow-flight=true
view-distance=8
simulation-distance=8
server-port=${MC_PORT}
EOT

if [[ ! -f "$NODE_DIR/package.json" ]]; then
  (cd "$NODE_DIR" && npm init -y >/dev/null 2>&1)
fi

(cd "$NODE_DIR" && npm install mineflayer mineflayer-pathfinder prismarine-viewer vec3 canvas >/dev/null)

echo "Starting Fabric server ..."
(
  cd "$SERVER_DIR"
  java -Xms1G -Xmx2G -jar server.jar nogui
) > "$LOG_DIR/server.log" 2>&1 &
SERVER_PID=$!

# Wait for server startup
for _ in {1..180}; do
  if rg -q "Done \(" "$LOG_DIR/server.log"; then
    break
  fi
  sleep 1
done

if ! rg -q "Done \(" "$LOG_DIR/server.log"; then
  echo "Server failed to start in time."
  tail -n 80 "$LOG_DIR/server.log"
  exit 1
fi

echo "Starting bot automation ..."
(
  cd "$NODE_DIR"
  NODE_PATH="$NODE_DIR/node_modules" MC_PORT="$MC_PORT" MC_USERNAME="$BOT_NAME" MC_VERSION="1.21.8" VIEWER_PORT="$VIEWER_PORT" node "$ROOT_DIR/scripts/bot_spawn_zombie.js"
) > "$LOG_DIR/bot.log" 2>&1 &
BOT_PID=$!

# Wait until bot joins
for _ in {1..120}; do
  if rg -q "${BOT_NAME} joined the game" "$LOG_DIR/server.log"; then
    break
  fi
  sleep 1
done

if ! rg -q "${BOT_NAME} joined the game" "$LOG_DIR/server.log"; then
  echo "Bot did not join in time."
  tail -n 120 "$LOG_DIR/server.log"
  tail -n 120 "$LOG_DIR/bot.log"
  exit 1
fi

# Wait for bot success
for _ in {1..120}; do
  if rg -q "SUCCESS: Zombie spawned with zombie spawn egg" "$LOG_DIR/bot.log"; then
    break
  fi
  if ! kill -0 "$BOT_PID" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! rg -q "SUCCESS: Zombie spawned with zombie spawn egg" "$LOG_DIR/bot.log"; then
  echo "Bot automation failed."
  tail -n 120 "$LOG_DIR/bot.log"
  exit 1
fi

VIEWER_URL="http://127.0.0.1:${VIEWER_PORT}"
echo "Capturing screenshot from viewer: ${VIEWER_URL}"

if ! python3 -c 'import playwright' >/dev/null 2>&1; then
  echo "Installing Python playwright ..."
  python3 -m pip install --user playwright >/dev/null
fi

echo "Installing Chromium for playwright (if missing) ..."
python3 -m playwright install chromium >/dev/null
echo "Installing Chromium system dependencies ..."
python3 -m playwright install-deps chromium >/dev/null


cd "$ROOT_DIR"
python3 - <<PY
from playwright.sync_api import sync_playwright

url = "${VIEWER_URL}"
out = "${SCREENSHOT_PATH}"

with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={"width": 1280, "height": 720})
    page.goto(url, wait_until="networkidle")
    page.wait_for_timeout(8000)
    page.screenshot(path=out, full_page=True)
    browser.close()
print(out)
PY

if [[ ! -f "$SCREENSHOT_PATH" ]]; then
  echo "Screenshot was not produced."
  exit 1
fi

echo "All done. Screenshot: $SCREENSHOT_PATH"
