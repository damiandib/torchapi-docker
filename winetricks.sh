#!/bin/bash
# Build-time Wine prefix setup. Runs as the `wine` user against WINEPREFIX=/wineprefix.
#
# Every verb runs against a REAL X display started here. The predecessor image aimed its
# verbs at DISPLAY=:99.0 without ever starting an X server, so `dotnet48` aborted before
# launching its installer, leaving only the .NET 4.0 that its dotnet40 dependency pulled in
# -- and the build still reported success. See docs/superpowers/specs/ section 2.
set -euo pipefail

export WINEARCH=win64
export WINEPREFIX=/wineprefix
export WINEDEBUG=-all
export DISPLAY=:99

# .NET 4.8 == 528040 or higher in NDP\v4\Full\Release. Release only exists from 4.5 up.
DOTNET48_RELEASE_MIN=528040

log() { echo "[winetricks.sh] $*"; }

start_display() {
  log "starting Xvfb on ${DISPLAY}"
  Xvfb "$DISPLAY" -screen 0 1024x768x24 -ac -br &
  XVFB_PID=$!
  for _ in $(seq 1 30); do
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
      log "display ready"
      return 0
    fi
    sleep 1
  done
  log "FATAL: ${DISPLAY} never became ready"
  return 1
}

stop_display() {
  if [ -n "${XVFB_PID:-}" ]; then
    kill "$XVFB_PID" 2>/dev/null || true
  fi
}
trap stop_display EXIT

start_display

log "initialising prefix (mscoree disabled so wine-mono is never installed)"
WINEDLLOVERRIDES="mscoree=d" wineboot --init /nogui
wineserver -w

# One winetricks call per verb, so a failure is attributable to a single verb.
# vcrun2017 is deliberately absent: vcrun2015/2017/2019 are one VC++ 14.x family and
# winetricks rejects the second one ("vcrun2019 conflicts with vcrun2017").
for verb in corefonts vcrun2013 vcrun2019 dotnet48 d3dcompiler_47; do
  log "installing verb: ${verb}"
  winetricks -q "$verb"
done

log "disabling sound"
winetricks -q sound=disabled

log "forcing d3d9 native and disabling WPF hardware acceleration"
wine reg add 'HKCU\Software\Wine\DllOverrides' /f /v d3d9 /t REG_SZ /d native
wine reg add 'HKCU\SOFTWARE\Microsoft\Avalon.Graphics' /v DisableHWAcceleration /t REG_DWORD /d 1 /f

# MUST stay last. winetricks' load_dotnet48() calls `w_set_winver win7` and never restores it.
# Steam dropped Windows 7/8/8.1 on 2024-01-01, so a win7 prefix makes steamcmd.exe select the
# legacy package track and fetch client-update.steamstatic.com/steam_cmd_legacy_win32, which
# Valve removed (HTTP 404). steamcmd then aborts with "Steamcmd needs to be online to update"
# and Torch can never update the SE dedicated server. steam_cmd_win32/win64 still return 200.
# Any verb added below this line must not re-pin the Windows version.
log "resetting reported Windows version to win10"
winetricks win10

# ---------- verification gate: the build MUST fail if a dependency is missing ----------
log "verifying prefix"

RELEASE_RAW=$(wine reg query 'HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full' /v Release 2>/dev/null \
  | tr -d '\r' | awk '/Release/{print $NF}' || true)

if [ -z "$RELEASE_RAW" ]; then
  log "FATAL: NDP\\v4\\Full has no Release value -- .NET 4.5+ was never installed."
  log "Dumping the key for diagnosis:"
  wine reg query 'HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full' 2>&1 | tr -d '\r' || true
  log "Verbs that did complete:"
  cat "${WINEPREFIX}/winetricks.log" || true
  exit 1
fi

RELEASE=$(( RELEASE_RAW ))
log "NDP\\v4\\Full Release = ${RELEASE_RAW} (${RELEASE})"
if [ "$RELEASE" -lt "$DOTNET48_RELEASE_MIN" ]; then
  log "FATAL: Torch requires .NET 4.8 (Release >= ${DOTNET48_RELEASE_MIN}); found ${RELEASE}."
  exit 1
fi

for dll in msvcp140.dll vcruntime140.dll msvcp120.dll d3dcompiler_47.dll; do
  if [ ! -f "${WINEPREFIX}/drive_c/windows/system32/${dll}" ]; then
    log "FATAL: ${dll} missing from system32 -- a vcrun/d3dcompiler verb failed silently."
    exit 1
  fi
done

for verb in corefonts vcrun2013 vcrun2019 dotnet48 d3dcompiler_47 win10; do
  if ! grep -qx "$verb" "${WINEPREFIX}/winetricks.log"; then
    log "FATAL: verb '${verb}' is not recorded in ${WINEPREFIX}/winetricks.log"
    exit 1
  fi
done

# Guard the Steam legacy-track trap directly: win7 reports CurrentVersion 6.1, win10 reports 10.0.
CURRENT_VER=$(wine reg query 'HKLM\Software\Microsoft\Windows NT\CurrentVersion' /v CurrentVersion 2>/dev/null \
  | tr -d '\r' | awk '/CurrentVersion/{print $NF}' || true)
log "reported Windows CurrentVersion = ${CURRENT_VER:-unknown}"
if [ "${CURRENT_VER:-}" = "6.1" ]; then
  log "FATAL: prefix is still pinned to Windows 7. 'winetricks win10' must run after dotnet48."
  exit 1
fi

log "prefix verified: .NET ${RELEASE_RAW}, vcrun + d3dcompiler present, winver ${CURRENT_VER}"

# Clean the winetricks download cache ONLY. Never `rm -rf /tmp/*`: that deletes
# /tmp/.X11-unix from the image, and Xvfb runs as `wine` (euid != 0) and cannot recreate it.
rm -rf "${HOME}/.cache/winetricks"
