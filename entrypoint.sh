#!/bin/bash
# Runtime supervisor. Runs as root, drops to the `wine` user for every process via runuser.
#
# Note: -e is deliberately absent. This script supervises long-running processes and handles
# its own failures explicitly; -e would kill it on any benign non-zero status.
set -uo pipefail

export WINEARCH=win64
export WINEPREFIX=/wineprefix
export WINEDEBUG=${WINEDEBUG:--all}
export DISPLAY=:99

TORCH_DIR=/app/torch-server
TORCH_EXE=${TORCH_EXE:-Z:/app/torch-server/Torch.Server.exe}
# -noupdate disables Torch's own game/plugin updater. We install SE with native Linux steamcmd
# below, because Torch's updater runs the Windows steamcmd under Wine, which fails to retrieve
# appinfo ("Failed installing AppID 298740 (Missing configuration)") and then reports success.
TORCH_ARGS=${TORCH_ARGS:--noupdate}
VNC_PORT=${VNC_PORT:-5900}
XVFB_RES=${XVFB_RES:-1024x768x24}
CHOWN_TORCH_DIR=${CHOWN_TORCH_DIR:-1}
SE_APPID=${SE_APPID:-298740}
SE_UPDATE_ON_BOOT=${SE_UPDATE_ON_BOOT:-1}
STEAMCMD=${STEAMCMD:-/opt/steamcmd/steamcmd.sh}

log() { echo "[entrypoint] $*"; }

log "--------------------------- INIT SERVER ---------------------------"

# Xvfb runs as `wine` (euid != 0) and cannot create this itself.
mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
install -d -o wine -g wine -m 0755 /run/vnc /app/logs
install -o wine -g wine -m 0644 /dev/null /app/logs/x11vnc.log

# VNC password: from the environment, or generated per container. Never baked into a layer,
# and passed to x11vnc via -passwdfile so it does not appear in `ps` output.
if [ -z "${VNC_PASSWORD:-}" ]; then
  VNC_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
  log "VNC_PASSWORD not set; generated for this container: ${VNC_PASSWORD}"
  log "set VNC_PASSWORD in docker-compose.yml to keep it stable across restarts"
fi
runuser -u wine -- x11vnc -storepasswd "$VNC_PASSWORD" /run/vnc/passwd >/dev/null 2>&1
chmod 0600 /run/vnc/passwd
chown wine:wine /run/vnc/passwd
unset VNC_PASSWORD

if [ ! -f "${TORCH_DIR}/Torch.Server.exe" ]; then
  log "FATAL: ${TORCH_DIR}/Torch.Server.exe not found."
  log "Run ./start on the host -- it fetches torch-server.zip and unpacks it to ./torch-server."
  exit 1
fi

# Torch must be able to write its own directory. The bind mount arrives with host ownership.
if [ "$CHOWN_TORCH_DIR" = "1" ] && [ "$(stat -c '%u' "$TORCH_DIR")" != "1000" ]; then
  log "chowning ${TORCH_DIR} to wine (uid 1000)"
  chown -R wine:wine "$TORCH_DIR"
fi

# ---- Space Engineers dedicated server: install/update with NATIVE Linux steamcmd ----
# @sSteamCmdForcePlatformType windows makes Linux steamcmd fetch the Windows build of the app,
# which is what Wine has to run.
install_se() {
  runuser -u wine -- "$STEAMCMD" \
    +force_install_dir "$TORCH_DIR" \
    +login anonymous \
    +@sSteamCmdForcePlatformType windows \
    +app_update "$SE_APPID" "$@" \
    +quit
}

SE_SENTINEL="${TORCH_DIR}/DedicatedServer64/steam_api64.dll"

if [ ! -f "$SE_SENTINEL" ]; then
  log "SE dedicated server absent; installing app ${SE_APPID} (first run downloads several GB)"
  if ! install_se validate; then
    log "FATAL: steamcmd could not install app ${SE_APPID}"
    exit 1
  fi
elif [ "$SE_UPDATE_ON_BOOT" = "1" ]; then
  log "updating SE dedicated server (app ${SE_APPID}); set SE_UPDATE_ON_BOOT=0 to skip"
  if ! install_se; then
    log "WARNING: steamcmd update failed; continuing with the copy already on disk"
  fi
fi

# Gate: Torch copies this file during Initializer.Initialize and dies with a
# DirectoryNotFoundException if it is missing. Fail here with a clear reason instead.
if [ ! -f "$SE_SENTINEL" ]; then
  log "FATAL: ${SE_SENTINEL} still missing after steamcmd -- Torch cannot start."
  exit 1
fi
log "SE dedicated server present"

log "starting Xvfb on ${DISPLAY} (${XVFB_RES})"
runuser -u wine -- bash -c "Xvfb ${DISPLAY} -screen 0 ${XVFB_RES} -ac -br &"

# Poll instead of sleeping a fixed interval, so a slow host cannot race us.
for _ in $(seq 1 30); do
  runuser -u wine -- xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
  sleep 1
done
if ! runuser -u wine -- xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
  log "FATAL: ${DISPLAY} never became ready"
  exit 1
fi
log "display ready"

log "starting x11vnc on port ${VNC_PORT}"
runuser -u wine -- bash -c "x11vnc -display ${DISPLAY} -forever -shared -rfbport ${VNC_PORT} \
  -passwdfile /run/vnc/passwd -o /app/logs/x11vnc.log -bg"

# Torch's GUI expects a window manager.
log "starting openbox"
runuser -u wine -- bash -c "DISPLAY=${DISPLAY} openbox &"

# Deliberate: gives VNC users a way to move server files around.
log "starting winefile"
runuser -u wine -- bash -c "DISPLAY=${DISPLAY} winefile &"

log "starting Torch: ${TORCH_EXE} ${TORCH_ARGS}"
runuser -u wine -- bash -c "cd ${TORCH_DIR} && DISPLAY=${DISPLAY} exec wine '${TORCH_EXE}' ${TORCH_ARGS}" &
TORCH_PID=$!

shutdown() {
  log "signal received, stopping Torch"
  runuser -u wine -- wineserver -k 2>/dev/null || true
  kill -TERM "$TORCH_PID" 2>/dev/null || true
}
trap shutdown TERM INT

wait "$TORCH_PID"
RC=$?
log "Torch exited with code ${RC}"
exit "$RC"
