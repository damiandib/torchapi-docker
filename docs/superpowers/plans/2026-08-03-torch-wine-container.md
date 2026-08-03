# Torch-on-Wine Container Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Docker image that runs the Space Engineers Torch dedicated server under a pinned Wine 11.0 with a **self-verifying** Wine prefix, so a missing runtime dependency fails the build instead of crashing the server at startup.

**Architecture:** `debian:bookworm-slim` + pinned `winehq-stable=11.0.0.0~bookworm-1`. A build-time `winetricks.sh` starts its own Xvfb (the predecessor's root-cause bug was verbs aimed at a display that did not exist), installs the runtime verbs, then asserts .NET 4.8 is present and exits non-zero if not. A runtime `entrypoint.sh` runs as root and drops to the `wine` user per process via `runuser`, bringing up Xvfb → x11vnc → openbox → winefile → Torch in the foreground.

**Tech Stack:** Docker + Compose v2, Debian bookworm, WineHQ stable 11.0, winetricks (pinned commit), Xvfb, x11vnc, openbox, POSIX `sh`/`bash`.

**Spec:** `docs/superpowers/specs/2026-08-03-torch-wine-container-design.md` — read §2 (root cause) before starting.

## Global Constraints

- Wine pin: `WINEVERSION=11.0.0.0~bookworm-1`, `WINEBRANCH=stable`. Probe-verified. Fallback ladder if a future release regresses: `10.0.0.0~bookworm-1`, then `9.0.0.0~bookworm-1`.
- winetricks pin: commit `08304e81f9ac9a83c552a6bd78689040d174bf95`, sha256 `954d17f56ae5f4d32eb083193a4a838c73ae5ff6b91765d93b0eab59cf2e7d29`. Never track `master`.
- .NET floor: `HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full` → `Release` must be `>= 528040`. Verified value on Wine 11.0 is `0x80eb1` (528049).
- `WINEPREFIX=/wineprefix` is the **only** prefix path. Never reintroduce a second value.
- `WINEARCH=win64`.
- Verb list: `corefonts`, `vcrun2013`, `vcrun2019`, `dotnet48`, `d3dcompiler_47`, `sound=disabled`. **`vcrun2017` must never be added** — `vcrun2015`/`vcrun2017`/`vcrun2019` are one VC++ 14.x family and winetricks refuses to stack them.
- `winetricks win10` must be the **last** verb. `load_dotnet48()` sets `win7` and never restores it; a win7 prefix breaks Torch's SE update path (Steam dropped Win7/8/8.1 on 2024-01-01 → `steamcmd.exe` picks the legacy track → `steam_cmd_legacy_win32` 404 → "Steamcmd needs to be online to update").
- **Never `rm -rf /tmp/*`** in any build or runtime script. It deletes `/tmp/.X11-unix`, which Xvfb (running as `wine`, euid != 0) cannot recreate.
- Privilege-drop idiom is `runuser -u wine -- bash -c '...'`. No `su`, no `gosu`, no `USER` directive in the runtime path.
- `wine` user must be **uid/gid 1000** — the `./torch-server` bind mount depends on it.
- No secrets in image layers. VNC password comes from the `VNC_PASSWORD` env var and is passed to x11vnc via `-passwdfile`, never `-passwd` (which leaks it into `ps`).
- Every build/verify script starts with `set -euo pipefail`.
- Do **not** commit `torch-server.zip` or `torch-server/` (already in `.gitignore`).
- No remote is configured. Do not create or push to a GitHub remote — the user does that explicitly.

---

### Task 1: Build layer — Dockerfile + self-verifying winetricks.sh

The heart of the rebuild. The test here is the build itself: it must **fail** without a build-time display and **pass** with one, which reproduces and then fixes the original defect.

**Files:**
- Create: `~/projects/torchapi-docker/Dockerfile`
- Create: `~/projects/torchapi-docker/winetricks.sh`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: an image whose `/wineprefix` has .NET 4.8; build args `WINEBRANCH`, `WINEVERSION`, `WINETRICKS_COMMIT`, `WINETRICKS_SHA256`; a `wine` user at uid 1000; `/app` owned by `wine`; `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]` (file supplied by Task 3 — until then the build ends at the `COPY`, so Task 1 is verified with `--target`-free builds that stop before that line; see Step 1 note).

- [ ] **Step 1: Write `winetricks.sh` WITHOUT the display, to watch the gate catch the original bug**

Create `winetricks.sh` exactly as below **except** comment out the `start_display` call (leave the function defined). This deliberately recreates the predecessor's bug so you can confirm the verification gate catches it.

```bash
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
```

To create the deliberately-broken first version, change the bare `start_display` call line to:

```bash
# start_display   # TEMPORARILY DISABLED to prove the verification gate works
```

- [ ] **Step 2: Write the Dockerfile**

Create `Dockerfile`. Note `COPY entrypoint.sh` is deliberately **absent** for now — Task 3 adds it. Keeping it out means Task 1 builds standalone, and adding it later as the final layer means entrypoint edits never invalidate the expensive winetricks layer.

```dockerfile
FROM debian:bookworm-slim

# ARG only, never ENV, for DEBIAN_FRONTEND -- an ENV would leak into the running container.
ARG DEBIAN_FRONTEND=noninteractive
ARG WINEBRANCH=stable
ARG WINEVERSION=11.0.0.0~bookworm-1
ARG WINETRICKS_COMMIT=08304e81f9ac9a83c552a6bd78689040d174bf95
ARG WINETRICKS_SHA256=954d17f56ae5f4d32eb083193a4a838c73ae5ff6b91765d93b0eab59cf2e7d29

# /wineprefix is the ONE prefix path. The predecessor also set /root/server, which was dead.
ENV WINEARCH=win64 \
    WINEPREFIX=/wineprefix \
    WINEDEBUG=-all \
    DISPLAY=:99

# WineHQ repo + pinned Wine. An unavailable pin fails the build here, loudly.
RUN dpkg --add-architecture i386 && \
    apt-get -qq update && \
    apt-get install -y -qq --no-install-recommends ca-certificates wget && \
    mkdir -pm755 /etc/apt/keyrings && \
    wget -qO /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key && \
    wget -qNP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources && \
    apt-get -qq update && \
    apt-get install -y -qq --install-recommends \
      winehq-${WINEBRANCH}=${WINEVERSION} \
      wine-${WINEBRANCH}=${WINEVERSION} \
      wine-${WINEBRANCH}-amd64=${WINEVERSION} \
      wine-${WINEBRANCH}-i386=${WINEVERSION} && \
    apt-get install -y -qq --no-install-recommends \
      xvfb x11-utils x11vnc openbox winbind cabextract procps unzip \
      libfaudio0 libfaudio0:i386 && \
    rm -rf /var/lib/apt/lists/* && \
    echo "pinned Wine: ${WINEVERSION}" && wine --version

# Pinned winetricks with a checksum, so upstream cannot silently change the prefix.
RUN wget -qO /usr/local/bin/winetricks \
      "https://raw.githubusercontent.com/Winetricks/winetricks/${WINETRICKS_COMMIT}/src/winetricks" && \
    echo "${WINETRICKS_SHA256}  /usr/local/bin/winetricks" | sha256sum -c - && \
    chmod +x /usr/local/bin/winetricks

# uid 1000 is load-bearing: docker-compose bind-mounts ./torch-server here and Torch must write to it.
RUN adduser --disabled-password --gecos "" --uid 1000 wine && \
    mkdir -p /wineprefix /app /scripts && \
    chown -R wine:wine /wineprefix /app

# The expensive layer. Everything below it should stay below it.
COPY winetricks.sh /scripts/winetricks.sh
RUN chmod +x /scripts/winetricks.sh && \
    runuser -u wine -- /scripts/winetricks.sh

# Xvfb runs as `wine` at runtime and cannot create this itself (euid != 0).
RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

WORKDIR /app
EXPOSE 5900 27016/udp
```

- [ ] **Step 3: Run the build and confirm it FAILS at the gate**

```bash
cd ~/projects/torchapi-docker
sudo docker build --progress=plain -t torchapi:wine11 . 2>&1 | tail -40
```

Expected: **build fails.** Either a verb errors out for lack of a display, or the run reaches `=== verifying prefix ===` and dies with `FATAL: NDP\v4\Full has no Release value` / `FATAL: Torch requires .NET 4.8`. Either way the exit code is non-zero and no image is produced. That is the predecessor's bug being caught instead of shipped.

If the build **succeeds** at this step, stop — the gate is not working, and shipping it would defeat the entire rebuild. Check that `set -euo pipefail` is present and that the `Release` comparison is `-lt`, not `-gt`.

- [ ] **Step 4: Re-enable the display and confirm the build PASSES**

Restore the call in `winetricks.sh`:

```bash
start_display
```

Then rebuild:

```bash
sudo docker build --progress=plain -t torchapi:wine11 . 2>&1 | grep -avE "^#[0-9]+ [0-9.]+ *[0-9]+K |\.\.\.\.\.\.\.\.\.\." | tail -40
```

Expected, near the end:

```
[winetricks.sh] NDP\v4\Full Release = 0x80eb1 (528049)
[winetricks.sh] reported Windows CurrentVersion = 10.0
[winetricks.sh] prefix verified: .NET 0x80eb1, vcrun + d3dcompiler present, winver 10.0
```

~5 minutes for the winetricks layer. If .NET 4.8 fails to install, step the pin down: `--build-arg WINEVERSION=10.0.0.0~bookworm-1`, then `9.0.0.0~bookworm-1`.

- [ ] **Step 5: Confirm the prefix inside the built image**

```bash
sudo docker run --rm --entrypoint /bin/bash torchapi:wine11 -c \
  'runuser -u wine -- env WINEPREFIX=/wineprefix wine reg query "HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full" /v Release 2>/dev/null | tr -d "\r"
   ls -l /wineprefix/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/mscorlib.dll
   ls -ld /tmp/.X11-unix
   id wine'
```

Expected: `Release REG_DWORD 0x80eb1`; `mscorlib.dll` dated **2019** (not 2010); `/tmp/.X11-unix` present and `drwxrwxrwt`; `uid=1000(wine) gid=1000(wine)`.

- [ ] **Step 6: Commit**

```bash
cd ~/projects/torchapi-docker
git add Dockerfile winetricks.sh
git commit -m "Add self-verifying Wine 11 build layer

winetricks.sh starts its own Xvfb before any Wine work, which is the fix for the
predecessor's root cause: verbs aimed at DISPLAY=:99.0 with no X server running
during docker build, so dotnet48 aborted before launching its installer and the
build still passed.

A verification gate now asserts NDP\v4\Full Release >= 528040, the vcrun and
d3dcompiler DLLs, every expected verb in winetricks.log, and that the prefix is
not left pinned to Windows 7. Any of those failing fails the build.

Wine is pinned to 11.0.0.0~bookworm-1 and winetricks to commit 08304e81 with a
sha256 check, so neither can drift between builds.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `tools/probe-wine.sh` — validate a candidate Wine version

**Files:**
- Create: `~/projects/torchapi-docker/tools/probe-wine.sh`

**Interfaces:**
- Consumes: Task 1's `Dockerfile` and its `WINEVERSION` build arg.
- Produces: `tools/probe-wine.sh <winehq-version>` → exit 0 with `PASS:` on stdout when that version yields a verified prefix, non-zero with `FAIL:` otherwise.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Verify that a candidate WineHQ stable version can build a working prefix (.NET 4.8 present).
#
# The image's own build-time verification gate is the test: if the prefix is bad, the build
# fails, and so does this script. Use it to re-validate the pin against future Wine releases.
#
# Usage: tools/probe-wine.sh 11.0.0.0~bookworm-1
#        tools/probe-wine.sh 10.0.0.0~bookworm-1   # fallback ladder
#        tools/probe-wine.sh 9.0.0.0~bookworm-1
set -euo pipefail

VERSION=${1:?usage: tools/probe-wine.sh <winehq version, e.g. 11.0.0.0~bookworm-1>}
cd "$(dirname "$0")/.."

TAG="torchapi-probe:$(printf '%s' "$VERSION" | tr -c 'A-Za-z0-9._-' '-')"
DOCKER=${DOCKER:-docker}

echo "=== probing winehq-stable=${VERSION} -> ${TAG} ==="
if ! "$DOCKER" build --progress=plain --build-arg "WINEVERSION=${VERSION}" -t "$TAG" . ; then
  echo "FAIL: ${VERSION} did not produce a verified prefix (see build log above)"
  exit 1
fi

echo "=== ${VERSION} built; reading the prefix back ==="
"$DOCKER" run --rm --entrypoint /bin/bash "$TAG" -c \
  'runuser -u wine -- env WINEPREFIX=/wineprefix wine reg query "HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full" 2>/dev/null | tr -d "\r"'

echo "PASS: ${VERSION} produced a verified prefix (image ${TAG})"
echo "Remove it with: ${DOCKER} rmi ${TAG}"
```

- [ ] **Step 2: Make it executable and run it against the known-good pin**

```bash
cd ~/projects/torchapi-docker
chmod +x tools/probe-wine.sh
DOCKER="sudo docker" tools/probe-wine.sh 11.0.0.0~bookworm-1 2>&1 | tail -20
```

Expected: `PASS: 11.0.0.0~bookworm-1 produced a verified prefix`, preceded by the registry dump showing `Release REG_DWORD 0x80eb1` and `Version REG_SZ 4.8.03761`. Fast on a warm cache — Task 1 already built these layers.

- [ ] **Step 3: Verify it fails on a nonexistent version**

```bash
cd ~/projects/torchapi-docker
DOCKER="sudo docker" tools/probe-wine.sh 99.0.0.0~bookworm-1 2>&1 | tail -5; echo "exit=$?"
```

Expected: apt cannot satisfy the pin, the build fails, and the script prints `FAIL: 99.0.0.0~bookworm-1 did not produce a verified prefix`. Confirms the probe reports failure rather than swallowing it.

- [ ] **Step 4: Commit**

```bash
cd ~/projects/torchapi-docker
git add tools/probe-wine.sh
git commit -m "Add probe tool for validating a candidate Wine version

Wraps the image build, whose verification gate is the actual test, so the Wine
pin can be re-validated against future releases instead of trusted.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Runtime — `entrypoint.sh`, compose file, host scripts

**Files:**
- Create: `~/projects/torchapi-docker/entrypoint.sh`
- Create: `~/projects/torchapi-docker/docker-compose.yml`
- Create: `~/projects/torchapi-docker/start`
- Create: `~/projects/torchapi-docker/stop`
- Modify: `~/projects/torchapi-docker/Dockerfile` (append the `COPY entrypoint.sh` + `ENTRYPOINT` layers)

**Interfaces:**
- Consumes: Task 1's image (`wine` user at uid 1000, verified `/wineprefix`, `/tmp/.X11-unix` at 1777, `/app` owned by `wine`).
- Produces: env contract `VNC_PASSWORD` (optional; random generated and logged if unset), `VNC_PORT` (default `5900`), `XVFB_RES` (default `1024x768x24`), `CHOWN_TORCH_DIR` (default `1`), `TORCH_EXE` (default `Z:/app/torch-server/Torch.Server.exe`); compose service name **`torch`**, container name **`torchapi`**, image tag **`torchapi:wine11`**; x11vnc log at `/app/logs/x11vnc.log`.

- [ ] **Step 1: Write `entrypoint.sh`**

```bash
#!/bin/bash
# Runtime supervisor. Runs as root, drops to the `wine` user for every process via runuser.
set -uo pipefail

export WINEARCH=win64
export WINEPREFIX=/wineprefix
export WINEDEBUG=${WINEDEBUG:--all}
export DISPLAY=:99

TORCH_DIR=/app/torch-server
TORCH_EXE=${TORCH_EXE:-Z:/app/torch-server/Torch.Server.exe}
VNC_PORT=${VNC_PORT:-5900}
XVFB_RES=${XVFB_RES:-1024x768x24}
CHOWN_TORCH_DIR=${CHOWN_TORCH_DIR:-1}

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

log "starting Torch: ${TORCH_EXE}"
runuser -u wine -- bash -c "cd ${TORCH_DIR} && DISPLAY=${DISPLAY} exec wine '${TORCH_EXE}'" &
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
```

- [ ] **Step 2: Append the entrypoint layers to the Dockerfile**

Add to the **end** of `Dockerfile`, after the `EXPOSE` line — last so entrypoint edits don't invalidate the winetricks layer:

```dockerfile
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

- [ ] **Step 3: Write `docker-compose.yml`**

```yaml
# No `version:` key -- obsolete in Compose v2 and warns if present.
services:
  torch:
    build:
      context: .
      args:
        WINEVERSION: 11.0.0.0~bookworm-1
    image: torchapi:wine11
    container_name: torchapi
    restart: unless-stopped
    volumes:
      - ./torch-server:/app/torch-server
    ports:
      - "27016:27016/udp"
      # Torch plugins or a Remote API needing TCP require this mapping explicitly:
      # - "27016:27016/tcp"
      - "5900:5900"
    environment:
      - WINEDEBUG=-all
      # Consumed by Torch/instance layout under /app/torch-server, not by this repo's scripts.
      - INSTANCE_NAME=TORCHAPI
      # Unset means a random password is generated and printed to the container log on boot.
      - VNC_PASSWORD=${VNC_PASSWORD:-}
```

- [ ] **Step 4: Write `start` and `stop`**

`start`:

```sh
#! /bin/sh
set -eu

if [ ! -f ./torch-server.zip ]; then
  wget https://build.torchapi.com/job/Torch/job/master/lastSuccessfulBuild/artifact/bin/torch-server.zip
fi

if [ ! -d ./torch-server ]; then
  unzip -q -d torch-server torch-server.zip
fi

# Load-bearing: everything in the container runs as the `wine` user (uid 1000) and Torch
# cannot write files owned by root in the bind-mounted tree.
if [ "$(stat -c '%u' torch-server)" != "1000" ]; then
  echo "Setting owner of torch-server to UID 1000"
  sudo chown -R 1000:1000 torch-server
fi

sudo docker compose up -d --build
sudo docker compose logs -f
```

`stop`:

```sh
#! /bin/sh
set -eu
sudo docker compose stop
sudo docker compose down
```

- [ ] **Step 5: Build, then verify the runtime comes up**

```bash
cd ~/projects/torchapi-docker
chmod +x start stop
./start
```

Expected in the log, in order: `INIT SERVER`, `display ready`, `starting x11vnc on port 5900`, `starting openbox`, `starting winefile`, `starting Torch: Z:/app/torch-server/Torch.Server.exe`, then Torch's own output.

Must **not** appear: `_XSERVTransmkdir: ERROR: euid != 0` (that's the `/tmp/.X11-unix` bug) and `MissingMethodException` (that's the .NET 4.0 bug). Both are the defects this rebuild exists to fix.

- [ ] **Step 6: Verify the VNC password is not leaking**

```bash
sudo docker exec torchapi ps aux | grep x11vnc | grep -v grep
sudo docker exec torchapi ls -l /run/vnc/passwd
sudo docker exec torchapi ss -lntp 2>/dev/null | grep 5900 || sudo docker exec torchapi netstat -lntp 2>/dev/null | grep 5900
```

Expected: the x11vnc command line shows `-passwdfile /run/vnc/passwd` and **no plaintext password**; the file is `-rw------- wine wine`; port 5900 is listening. Then connect a VNC client to `host:5900` with the password from the boot log and confirm the openbox desktop with winefile.

- [ ] **Step 7: Verify clean shutdown**

```bash
cd ~/projects/torchapi-docker
time ./stop
```

Expected: `Torch exited with code N` in the log and a stop that takes ~1–2 seconds, not the 10-second SIGKILL timeout. That confirms the trap forwards SIGTERM.

- [ ] **Step 8: Commit**

```bash
cd ~/projects/torchapi-docker
git add entrypoint.sh docker-compose.yml start stop Dockerfile
git commit -m "Add runtime entrypoint, compose file and host scripts

Keeps the VNC stack always on: Xvfb, x11vnc, openbox and winefile, with Torch in
the foreground and restart: unless-stopped behind it.

Fixes carried over from the predecessor: /tmp/.X11-unix is recreated 1777 before
privileges are dropped, so Xvfb running as an unprivileged user stops erroring
with 'euid != 0'; the VNC password comes from the environment and reaches x11vnc
via -passwdfile rather than -passwd, so it is neither baked into an image layer
nor visible in ps; display readiness is polled instead of slept; the bind-mounted
torch-server directory is chowned to uid 1000 automatically; SIGTERM is forwarded
so docker stop does not wait out its timeout; and Torch's real exit code is
logged and propagated.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: `tools/smoke-test.sh` — assert the built image actually runs Torch

**Files:**
- Create: `~/projects/torchapi-docker/tools/smoke-test.sh`

**Interfaces:**
- Consumes: Task 3's compose service `torch` / container `torchapi`; Task 1's verified prefix.
- Produces: `tools/smoke-test.sh` → exit 0 with `PASS:` when the image boots and Torch survives its startup window, non-zero with `FAIL:` and the tail of the container log otherwise. Honours `TIMEOUT` (default `300`) and `DOCKER` (default `docker`).

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Build the image, boot it, and assert Torch actually starts.
#
# Two independent checks, because a crashed Torch and a healthy Torch can look similar
# in a truncated log:
#   1. the image's prefix really has .NET 4.8
#   2. Torch.Server.exe is still alive after the startup window, with no unhandled exception
set -euo pipefail

cd "$(dirname "$0")/.."
DOCKER=${DOCKER:-docker}
COMPOSE="${DOCKER} compose"
TIMEOUT=${TIMEOUT:-300}
STABLE_FOR=${STABLE_FOR:-60}

if [ ! -f torch-server/Torch.Server.exe ]; then
  echo "FAIL: ./torch-server/Torch.Server.exe missing -- run ./start first"
  exit 1
fi

echo "=== build ==="
$COMPOSE build

echo "=== assert .NET 4.8 in the image ==="
RAW=$($DOCKER run --rm --entrypoint /bin/bash torchapi:wine11 -c \
  'runuser -u wine -- env WINEPREFIX=/wineprefix wine reg query "HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full" /v Release 2>/dev/null | tr -d "\r" | awk "/Release/{print \$NF}"')
if [ -z "$RAW" ]; then
  echo "FAIL: image prefix has no NDP\\v4\\Full Release value"
  exit 1
fi
echo "Release=${RAW} ($(( RAW )))"
if [ "$(( RAW ))" -lt 528040 ]; then
  echo "FAIL: image prefix lacks .NET 4.8 (need >= 528040)"
  exit 1
fi

echo "=== boot ==="
$COMPOSE up -d

report() { echo "--- last 60 log lines ---"; $COMPOSE logs --tail 60 2>&1 || true; }

deadline=$(( SECONDS + TIMEOUT ))
started=0
while [ "$SECONDS" -lt "$deadline" ]; do
  if $COMPOSE logs 2>&1 | grep -qE "MissingMethodException|Unhandled Exception|WineDbg attached"; then
    echo "FAIL: Torch threw an unhandled exception"
    report
    exit 1
  fi
  if $COMPOSE logs 2>&1 | grep -q "_XSERVTransmkdir: ERROR"; then
    echo "FAIL: /tmp/.X11-unix is missing from the image"
    report
    exit 1
  fi
  if $DOCKER exec torchapi pgrep -f Torch.Server.exe >/dev/null 2>&1; then
    started=1
    break
  fi
  sleep 5
done

if [ "$started" -ne 1 ]; then
  echo "FAIL: Torch.Server.exe never appeared within ${TIMEOUT}s"
  report
  exit 1
fi

echo "=== Torch is running; confirming it stays up for ${STABLE_FOR}s ==="
sleep "$STABLE_FOR"

if $COMPOSE logs 2>&1 | grep -qE "MissingMethodException|Unhandled Exception|WineDbg attached"; then
  echo "FAIL: Torch crashed during the stability window"
  report
  exit 1
fi
if ! $DOCKER exec torchapi pgrep -f Torch.Server.exe >/dev/null 2>&1; then
  echo "FAIL: Torch.Server.exe exited during the stability window"
  report
  exit 1
fi

echo "PASS: image boots, .NET 4.8 present, Torch running and stable for ${STABLE_FOR}s"
```

- [ ] **Step 2: Make it executable and run it**

```bash
cd ~/projects/torchapi-docker
chmod +x tools/smoke-test.sh
DOCKER="sudo docker" tools/smoke-test.sh
```

Expected: `Release=0x80eb1 (528049)`, then `PASS: image boots, .NET 4.8 present, Torch running and stable for 60s`. Takes ~2 minutes on a warm build cache.

- [ ] **Step 3: Confirm the smoke test can actually fail**

Point it at the old broken prefix to prove the assertions bite rather than always passing:

```bash
cd ~/projects/torchapi-docker
DOCKER="sudo docker" TIMEOUT=60 tools/smoke-test.sh 2>&1 | tail -5   # baseline: PASS

# now against the predecessor's broken image, which has .NET 4.0 only
sudo docker tag torchapi:wine11 torchapi:wine11-backup
sudo docker tag spaceengineers:torchapi torchapi:wine11
DOCKER="sudo docker" TIMEOUT=60 tools/smoke-test.sh 2>&1 | tail -5   # expect FAIL
sudo docker tag torchapi:wine11-backup torchapi:wine11               # restore
sudo docker rmi torchapi:wine11-backup
```

Expected on the second run: `FAIL: image prefix lacks .NET 4.8 (need >= 528040)` — the .NET check catching the exact bug that started this. Skip this step if the old `spaceengineers:torchapi` image is gone; note that in the commit message if so.

- [ ] **Step 4: Commit**

```bash
cd ~/projects/torchapi-docker
git add tools/smoke-test.sh
git commit -m "Add smoke test asserting the image boots and runs Torch

Checks the prefix's .NET 4.8 release value and that Torch.Server.exe is alive
after a stability window, failing on MissingMethodException, WineDbg attachment
or the _XSERVTransmkdir error. Verified against the predecessor's broken image,
where the .NET assertion fails as intended.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Documentation — `README.md` and `CLAUDE.md`

**Files:**
- Create: `~/projects/torchapi-docker/README.md`
- Create: `~/projects/torchapi-docker/CLAUDE.md`

**Interfaces:**
- Consumes: everything from Tasks 1–4 (exact filenames, env var names, tag `torchapi:wine11`, service `torch`, container `torchapi`).
- Produces: no code.

- [ ] **Step 1: Write `README.md`**

```markdown
# torchapi-docker

Space Engineers **Torch** dedicated server running under Wine in Docker, headless, with a
VNC-accessible desktop.

Rebuild of [`torchapi-wine9`](https://github.com/stubkan/torchapi-wine9) whose prefix installed
.NET 4.0 instead of the 4.8 Torch needs, on a build that reported success. See
`docs/superpowers/specs/2026-08-03-torch-wine-container-design.md`.

## Quick start

```bash
./start          # fetch Torch, unpack, chown to uid 1000, build if needed, up -d, tail logs
./stop           # compose stop && down
```

Then connect a VNC client to `host:5900`. Set `VNC_PASSWORD` in `docker-compose.yml` or the
environment; if unset, a random password is generated per container and printed to the log:

```bash
sudo docker compose logs | grep "generated for this container"
```

## Requirements

Docker with Compose v2 (`docker compose`, not `docker-compose`), and roughly 6 GB of disk for
the image. The winetricks layer takes ~5 minutes to build.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `VNC_PASSWORD` | *(random per container)* | VNC password. Never baked into the image |
| `VNC_PORT` | `5900` | x11vnc port inside the container |
| `XVFB_RES` | `1024x768x24` | Virtual display geometry |
| `CHOWN_TORCH_DIR` | `1` | Chown `/app/torch-server` to uid 1000 at boot |
| `TORCH_EXE` | `Z:/app/torch-server/Torch.Server.exe` | Wine path to the server binary |
| `INSTANCE_NAME` | `TORCHAPI` | For Torch's instance layout; unused by these scripts |

Ports: `27016/udp` (game) and `5900/tcp` (VNC). Port 27016 is UDP **only** — plugins or a Remote
API needing TCP require uncommenting that mapping in `docker-compose.yml`.

## Verification

```bash
tools/probe-wine.sh 11.0.0.0~bookworm-1   # can this Wine version build a working prefix?
tools/smoke-test.sh                        # does the image boot and run Torch?
```

Both exit non-zero on failure. There is no unit test suite; these are the tests.

## Rebuilding

Editing `entrypoint.sh` is cheap — it is the last layer. Editing `winetricks.sh` or anything above
it rebuilds the ~5-minute winetricks layer.

```bash
sudo docker compose up -d --build
```

## Notes

- **The server is single-shot.** Restarting Torch from inside its own GUI kills the window manager
  and does not cleanly recover. Restart the container instead. Edit server and instance configs
  while stopped, not live.
- **Torch downloads its own Windows steamcmd.** `Torch.Server.exe` fetches
  `steamcdn-a.akamaihd.net/client/installer/steamcmd.zip`, unpacks it to `steamcmd/` under its
  working directory, and runs `steamcmd.exe` under Wine with `app_update 298740`. No Linux steamcmd
  is installed or used. If it gets into a bad state, delete `./torch-server/steamcmd/` and let Torch
  re-bootstrap it.
- **The prefix is baked into the image, not a volume.** Prefix changes require a rebuild — that is
  deliberate, because the prefix is verified at build time.
- **File ownership.** Everything in the container runs as `wine` (uid 1000). Root-owned files under
  `./torch-server` are unwritable by Torch; `./start` and the entrypoint both correct this.
```

- [ ] **Step 2: Write `CLAUDE.md`**

```markdown
# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

A Docker image running the Space Engineers **Torch** dedicated server (a Windows .NET Framework 4.8
application) on Debian bookworm under a pinned WineHQ stable 11.0, headless, with an
X11VNC-accessible desktop. There is no application source here — the repo is the container build
plus orchestration shell scripts. Torch itself is fetched by `./start` at runtime and is not
committed.

Rebuild of `stubkan/torchapi-wine9`. The design and the full root-cause analysis it came from are in
`docs/superpowers/specs/2026-08-03-torch-wine-container-design.md`. Read §2 before changing the
build.

## Commands

```bash
./start                                # fetch, unpack, chown 1000, up -d --build, tail logs
./stop                                 # compose stop && down
sudo docker compose up -d --build      # REQUIRED after editing Dockerfile/winetricks.sh/entrypoint.sh
sudo docker exec -it torchapi /bin/bash

tools/probe-wine.sh 11.0.0.0~bookworm-1   # validate a candidate Wine version
tools/smoke-test.sh                        # build, boot, assert Torch runs
```

No build system, linter, or unit tests. The two `tools/` scripts are the test suite.

## Invariants — do not break these

- **`winetricks.sh` must start its own Xvfb before any Wine work.** This is the fix for the
  predecessor's root cause: verbs aimed at `DISPLAY=:99.0` with no X server during `docker build`,
  so `dotnet48` aborted before launching its installer and only its `dotnet40` dependency's .NET 4.0
  landed — while the build still passed. Torch then died with
  `MissingMethodException: Environment.get_CurrentManagedThreadId` (a .NET 4.5+ method).
- **The verification gate must stay.** `Release >= 528040`, the vcrun/d3dcompiler DLLs, every
  expected verb in `winetricks.log`, and a non-win7 winver. A build that cannot prove the prefix is
  good must fail.
- **`winetricks win10` stays last.** `load_dotnet48()` calls `w_set_winver win7` and never restores
  it. Steam dropped Windows 7/8/8.1 on 2024-01-01, so a win7 prefix makes `steamcmd.exe` fetch
  `client-update.steamstatic.com/steam_cmd_legacy_win32`, which Valve removed — HTTP 404, then
  `Steamcmd needs to be online to update`, and no server update ever.
- **Never add `vcrun2017`.** `vcrun2015`/`vcrun2017`/`vcrun2019` are one VC++ 14.x family;
  winetricks refuses the second (`vcrun2019 conflicts with vcrun2017`). The predecessor's script
  installed both, so its `vcrun2019` line could never have succeeded.
- **Never `rm -rf /tmp/*`.** It deletes `/tmp/.X11-unix`, and Xvfb runs as `wine` (euid != 0) and
  cannot recreate it. This was the predecessor's `_XSERVTransmkdir: euid != 0` error.
- **`WINEPREFIX=/wineprefix`, one value only.** The predecessor also set `/root/server`, which was
  dead and confusing.
- **`wine` must be uid 1000.** `docker-compose.yml` bind-mounts `./torch-server` and Torch must be
  able to write it.
- **Wine and winetricks stay pinned** (`11.0.0.0~bookworm-1`; commit `08304e81` + sha256). The
  predecessor curled winetricks from `master`, and its image was built with `--build-arg` values
  that disagreed with its own Dockerfile — so its Wine version was never actually controlled. Use
  `tools/probe-wine.sh` before changing the pin.
- **No secrets in layers.** VNC password comes from `VNC_PASSWORD` and is passed via `-passwdfile`,
  never `-passwd` (which shows up in `ps`).

## Layer ordering

`COPY entrypoint.sh` is the last layer on purpose — entrypoint edits must not invalidate the
~5-minute winetricks layer. Do not move anything above it casually.

## Gotchas

- **The server is single-shot.** Restarting Torch from its own GUI kills the window manager and does
  not recover. Restart the container.
- **A crashed Torch parks in WineDbg and holds the prefix open.** Any `wineserver -w` (which
  winetricks runs) then blocks forever, which looks exactly like a hang. Kill `winedbg` first.
- **Port 27016 is UDP only.** TCP needs an explicit mapping.
- **`INSTANCE_NAME` is consumed by nothing in this repo.** It exists for Torch's instance layout.
- **Torch uses its own Wine-side steamcmd**, not any Linux package. Delete
  `./torch-server/steamcmd/` to reset it.

## Style

Plain POSIX `sh`/`bash`. Build and verification scripts use `set -euo pipefail` — a silent failure
is the bug class this repo exists to prevent. `entrypoint.sh` uses `set -uo pipefail` (not `-e`)
because it supervises long-running processes. Privilege drop is always
`runuser -u wine -- bash -c '...'`; no `su`, `gosu`, or `USER` directive.
```

- [ ] **Step 3: Verify the docs match reality**

```bash
cd ~/projects/torchapi-docker
# every env var the docs claim must exist in entrypoint.sh
for v in VNC_PASSWORD VNC_PORT XVFB_RES CHOWN_TORCH_DIR TORCH_EXE; do
  grep -q "$v" entrypoint.sh && echo "ok: $v" || echo "MISSING: $v"
done
# every command the docs claim must exist
ls -l start stop tools/probe-wine.sh tools/smoke-test.sh
grep -n "torchapi:wine11" docker-compose.yml tools/smoke-test.sh
```

Expected: all `ok:`, all four scripts executable, and the image tag consistent between the compose file and the smoke test.

- [ ] **Step 4: Commit**

```bash
cd ~/projects/torchapi-docker
git add README.md CLAUDE.md
git commit -m "Add README and CLAUDE.md

CLAUDE.md records the invariants as invariants, each with the failure it
prevents, so the silent-failure bugs this rebuild fixes cannot be reintroduced
by someone who does not know why the rules exist.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Self-review

**Spec coverage:**

| Spec section | Task |
|---|---|
| §4 architecture, §5.1 Dockerfile | Task 1 |
| §5.2 winetricks.sh + verification gate | Task 1 |
| §5.3 entrypoint.sh | Task 3 |
| §5.4 docker-compose.yml | Task 3 |
| §5.5 tools/probe-wine.sh | Task 2 |
| §5.6 tools/smoke-test.sh | Task 4 |
| §5.7 start / stop | Task 3 |
| §6 error handling table | Tasks 1 + 3 (gate, chown, random password, exit code) |
| §7.2 ongoing verification | Tasks 2 + 4 |
| §3 dropped packages (`steamcmd`, `htop`, `net-tools`, `software-properties-common`, `gnupg2`) | Task 1 — absent from the new Dockerfile |
| §8 rollback | No task; old repo and image are untouched by construction |
| §9 private remote | No task; explicitly the user's action |

**Placeholder scan:** No TBD/TODO. Every code step carries complete file content. The one
intentionally-temporary edit (commenting out `start_display` in Task 1 Step 1) is reverted in
Task 1 Step 4 and exists to prove the gate fires.

**Type/name consistency:** `WINEPREFIX=/wineprefix` throughout; image tag `torchapi:wine11` in
`docker-compose.yml`, `tools/smoke-test.sh`, and `CLAUDE.md`; compose service `torch` and container
`torchapi` in the compose file, smoke test (`docker exec torchapi`), and docs; `DOTNET48_RELEASE_MIN`
and the literal `528040` agree in `winetricks.sh`, `tools/smoke-test.sh`, and both docs;
`/run/vnc/passwd` consistent between `entrypoint.sh` and Task 3 Step 6; verb list identical in
`winetricks.sh`, its gate loop, and `CLAUDE.md`.

**Known follow-up, not a placeholder:** `tools/smoke-test.sh` asserts Torch's *liveness and absence
of exceptions* rather than matching a specific Torch startup log line, because the exact strings a
healthy Torch emits are unverified. After the first successful run, tightening it to grep a known
banner would be a strict improvement.
