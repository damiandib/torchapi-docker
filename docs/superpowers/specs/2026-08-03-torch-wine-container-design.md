# Torch-on-Wine container — design

**Date:** 2026-08-03
**Status:** approved design, pending implementation plan
**Predecessor:** `~/projects/torchapi-wine9` (fork of `stubkan/torchapi-wine9`), left untouched as a reference

## 1. Purpose

A Docker image that runs the Space Engineers **Torch** dedicated server — a Windows .NET Framework 4.8
application — on Debian under Wine, headless, with an X11VNC-accessible desktop.

This is a rebuild of `torchapi-wine9`, not a patch. It exists because the predecessor ships a
**silently broken Wine prefix**: the build reports success while the .NET runtime Torch requires is
absent. The rebuild's central design goal is that *this class of failure cannot recur* — every
runtime dependency is verified at build time, and a missing one fails the build.

## 2. The defect being fixed

Torch crashes at startup:

```
Unhandled Exception: System.MissingMethodException: Method not found:
'Int32 System.Environment.get_CurrentManagedThreadId()'.
   at NLog.LogFactory.<GetDefaultCandidateConfigFilePaths>d__11..ctor(Int32 <>1__state)
   ...
   at Torch.Server.Program.Main(String[] args)
```

### Root cause chain

1. `Torch.Server.exe.config` declares `<supportedRuntime version="v4.0" sku=".NETFramework,Version=v4.8" />`.
   `Environment.CurrentManagedThreadId` was introduced in .NET Framework **4.5**.
2. The image's prefix has .NET **4.0 only**. Evidence: `NDP\v4\Full` contains `Version 4.0.30319`
   and `TargetVersion 4.0.0` with **no `Release` value** (`Release` exists only from 4.5 up), and
   `mscorlib.dll` is dated **2010-03-18** — .NET 4.0 RTM.
3. `winetricks.log` lists the verbs that completed: `corefonts`, `sound=disabled`,
   `remove_mono internal` ×2, `winxp`, `dotnet40`, `sound=disabled`, `d3dcompiler_47`, `win10`.
   **`dotnet48` is absent.** So are `vcrun2013`, `vcrun2017`, `vcrun2019`.
   The .NET 4.0 in the prefix came from `dotnet40`, which is dotnet48's own dependency.
4. `dotnet48` died before launching its installer: `load_dotnet48()` calls `w_set_winver win7`
   immediately before running `ndp48-x86-x64-allos-enu.exe`, and no `win7` line appears in the log.
5. **Why:** `winetricks.sh` points every verb at `DISPLAY=:99.0`, but nothing starts an X server
   during `docker build`. The display named does not exist. Corroborated by three independent
   working implementations — `mmmaxwwwell/space-engineers-dedicated-docker-linux`,
   `FragSoc/steamcmd-wine-xvfb-docker`, and `scottyhardy/docker-wine` — all of which start a
   display before doing Wine work. The vcrun verbs' DLL overrides are present in the registry while
   their log entries are not, which is the same signature: winetricks writes overrides *before*
   running an installer, so an aborted installer leaves the override behind.
6. **Why it shipped green:** `winetricks.sh` has no `set -e`, and a Dockerfile `RUN` only fails on
   its *last* command. A dead verb is invisible to the build.

### Secondary defects confirmed during investigation

- `winetricks.sh` ends with `rm -rf ~/.cache ~/.config ~/.local /tmp/*`. That deletes
  `/tmp/.X11-unix` from the image, which is the cause of the runtime error
  `_XSERVTransmkdir: ERROR: euid != 0, directory /tmp/.X11-unix will not be created` — Xvfb runs as
  `wine` and cannot recreate it.
- The VNC password is a plaintext literal (`-passwd mypassword`) baked into an image layer.
  `x11vnc -passwd` additionally exposes it in `ps` output to every process in the container.
- `WINEPREFIX` is set twice and disagrees: `ENV WINEPREFIX=/root/server` in the Dockerfile is dead;
  `/wineprefix` is the real one.
- **The image does not match its own Dockerfile.** `docker history` shows it was built with
  `--build-arg WINEBRANCH=staging WINEVERSION=10.17~bookworm-1`, while the Dockerfile pins
  `stable` / `9.0.0.0~bookworm-1`. Nothing in the repo passes those args — `start` runs a plain
  `docker-compose up -d`. Wine version was therefore never actually controlled.
- `winetricks` is curled from `master` at build time, so no two builds are guaranteed identical.
- **`winetricks.sh` line 8 (`vcrun2019`) can never have succeeded.** winetricks rejects it with
  `error: vcrun2019 conflicts with vcrun2017, which is already installed`, because `vcrun2015`,
  `vcrun2017` and `vcrun2019` are one VC++ 14.x family. Confirmed by direct observation in a clean
  Wine 11 build. Another instance of the same silent-failure class: the verb dies, the build passes.
- Torch parked in WineDbg after crashing holds the prefix open, and winetricks' `wineserver -w`
  then blocks forever ("This will hang until all wine processes in prefix terminate"). This makes
  any in-container repair attempt appear to hang.

## 3. Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Wine runtime | Latest WineHQ **stable**, explicitly pinned | Asked-for update, but a stable branch and reproducible. Available for bookworm: `11.0.0.0`, `10.0.0.0`, `9.0.0.0` — a real fallback ladder |
| Wine version value | Resolved by probe; `11.0.0.0~bookworm-1` first choice | Unknown whether new-wow64 Wine 11 can install .NET 4.8. The probe decides; the ladder is the fallback |
| .NET runtime | Real .NET 4.8 via `winetricks dotnet48`, mono removed | Torch targets 4.8; wine-mono is not a validated substitute for this workload |
| GUI / VNC | **Always on**, as today | User's explicit choice. Xvfb + x11vnc + openbox + winefile all retained |
| Base image | `debian:bookworm-slim`, our own build | Rejected `scottyhardy/docker-wine`: unpinned latest, ships wine-mono, RDP not VNC, user not UID 1000 |
| Proton | No | Proton's advantages (DXVK/VKD3D, Steam runtime, per-title patches) are game-rendering concerns. A headless WinForms server gains nothing and pays umu-launcher + protontricks complexity |
| Prefix storage | Baked into the image, not a volume | Prefix is a build artifact and must be verified at build time |
| Repo | New private repo, own folder | User's choice. Remote created only on explicit instruction |

### Rejected: building on a steamcmd+Wine base image

Surveyed `steamcmd/docker` (no Wine variant at all — Ubuntu/Debian/Alpine/Rocky/CentOS/CachyOS,
Windows tags unavailable), `nuxy/docker-steamcmd-wine` (the one Valve's wiki recommends;
`FROM scottyhardy/docker-wine`, installs no .NET), `FragSoc/steamcmd-wine-xvfb-docker`,
`thomasleveil/docker-steamcmd-wine`, `honestventures/docker-steamcmd-wine`. None install .NET,
which is why none encounter this bug. There is nothing to inherit that we don't have to write anyway.

### Dropped from the old build

- `steamcmd` apt package — unused. Torch downloads its own Windows `steamcmd.exe`
  (`steamcdn-a.akamaihd.net/client/installer/steamcmd.zip`) and runs it under Wine. The Debian
  package exists only to pull in `non-free` plus a debconf license prompt. Reversible.
- `htop`, `net-tools` — debugging leftovers.
- `software-properties-common`, `gnupg2` — installed and then removed within the same build.

## 4. Architecture

```
docker build
 └─ Dockerfile
     ├─ apt: pinned winehq-stable + i386, xvfb, x11-utils, x11vnc, openbox, winbind, cabextract
     ├─ pinned winetricks release (not master)
     ├─ adduser wine, uid/gid 1000
     └─ RUN winetricks.sh   ← starts its own Xvfb; verifies; FAILS BUILD if .NET 4.8 absent

docker run
 └─ entrypoint.sh (root, drops to wine per process via runuser)
     ├─ ensure /tmp/.X11-unix 1777
     ├─ write VNC passwd file 0600
     ├─ chown /app/torch-server to wine if root-owned
     ├─ Xvfb :99          → poll until it answers
     ├─ x11vnc :5900      → -passwdfile, not -passwd
     ├─ openbox           → Torch's GUI needs a WM
     ├─ winefile          → file management over VNC
     └─ exec wine Z:/app/torch-server/Torch.Server.exe   (foreground; container dies with it)
```

Privilege-drop idiom stays `runuser -u wine -- bash -c '...'` throughout — no `su`, `gosu`, or
`USER` directive — matching the predecessor's established style.

## 5. Components

### 5.1 `Dockerfile`

- `FROM debian:bookworm-slim`
- `ARG WINEBRANCH=stable`, `ARG WINEVERSION=<probe result>`, `ARG WINETRICKS_VERSION=<pinned tag>`
- `ENV WINEPREFIX=/wineprefix` — single source of truth, no second value anywhere
- `dpkg --add-architecture i386`; WineHQ keyring to `/etc/apt/keyrings/`; pinned install of
  `winehq-stable`, `wine-stable`, `wine-stable-amd64`, `wine-stable-i386` at `${WINEVERSION}`
- Runtime packages: `xvfb`, `x11-utils` (for `xdpyinfo` polling), `x11vnc`, `openbox`, `winbind`,
  `cabextract`, `procps`, `libfaudio0` + `:i386`
- `winetricks` fetched at a **pinned release tag**
- `adduser` `wine` with explicit `--uid 1000` (the bind mount depends on it; the old build left it
  to `adduser`'s default)
- Log the resolved Wine version into the build output for auditability
- `COPY entrypoint.sh` stays the **last** layer before `ENTRYPOINT`, so entrypoint edits never
  invalidate the expensive winetricks layer

### 5.2 `winetricks.sh` (build time)

```
set -euo pipefail
```

1. Start `Xvfb :99`; poll `xdpyinfo` until it answers (fail after N seconds). **This is the fix for
   the root cause.**
2. `WINEDLLOVERRIDES="mscoree=d" wineboot --init /nogui` to suppress the wine-mono prompt;
   `wineserver -w`.
3. Verbs: `corefonts`, `vcrun2013`, `vcrun2019`, `dotnet48`, `d3dcompiler_47`,
   `sound=disabled`, `d3d9=native`, WPF `DisableHWAcceleration`.
   **`vcrun2017` must not be installed alongside `vcrun2019`.** `vcrun2015`, `vcrun2017` and
   `vcrun2019` are the same VC++ 14.x redist family and winetricks refuses to stack them
   (`error: vcrun2019 conflicts with vcrun2017, which is already installed`). `vcrun2019` is the
   superset; `vcrun2013` is a separate family (VC++ 12.0) and installs alongside it fine.
   Each verb is invoked as its own `winetricks` call, so a failure is attributable to one verb.
4. `winetricks win10` **last**. Non-negotiable and must stay last: `load_dotnet48()` calls
   `w_set_winver win7` and never restores it. Steam dropped Windows 7/8/8.1 on 2024-01-01, so a
   win7 prefix makes `steamcmd.exe` select the legacy track and fetch
   `client-update.steamstatic.com/steam_cmd_legacy_win32`, which Valve removed — HTTP 404, then
   `Steamcmd needs to be online to update`, and Torch can never update the SE server.
   `steam_cmd_win32`/`steam_cmd_win64` still return 200. Any verb added after `dotnet48` must not
   re-pin the version.
5. **Verification gate.** Query `HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full` `Release`;
   require `>= 528040` (.NET 4.8). Assert the vcrun DLLs exist in `system32`/`syswow64`. Assert each
   expected verb appears in `winetricks.log`. Any failure ⇒ non-zero exit ⇒ **the build fails.**
6. Cleanup: remove `~/.cache/winetricks` only. **Never `rm -rf /tmp/*`** — that is what deletes
   `/tmp/.X11-unix`. Kill the build-time Xvfb. Recreate `/tmp/.X11-unix` `1777`.

### 5.3 `entrypoint.sh` (runtime)

- `mkdir -p /tmp/.X11-unix && chmod 1777` as root before dropping privileges
- `VNC_PASSWORD` env → `x11vnc -storepasswd` file at `0600`, consumed via `-passwdfile`.
  Unset ⇒ generate a random password and print it **once** to the log. No weak baked-in default,
  and never visible in `ps`.
- Poll for X readiness via `xdpyinfo` instead of `sleep 5`
- `chown -R wine:wine /app/torch-server` when root-owned (the README's manual fix, automated;
  gated by `CHOWN_TORCH_DIR=1`, default on)
- Start `openbox`, then `winefile`
- `exec` the final `runuser` so `SIGTERM` reaches Wine and `docker stop` doesn't wait out its
  10-second timeout
- On exit, report Torch's actual exit code — replacing `"Something didn't work. Break this."`

Explicitly **not** fixed here: restarting Torch from inside its own GUI still kills the window
manager and does not cleanly recover. Restart the container instead. Documented, not solved —
that's separate work.

### 5.4 `docker-compose.yml`

- Drop the obsolete `version:` key
- `27016/udp` and `5900/tcp` as today; a commented `27016/tcp` for plugins / Remote API
- `VNC_PASSWORD` passed through; `restart: unless-stopped` retained
- Bind mount `./torch-server:/app/torch-server` unchanged

### 5.5 `tools/probe-wine.sh`

Builds a throwaway image at a candidate `WINEVERSION` and runs the full prefix setup, printing the
resulting `Release` value and exiting non-zero if .NET 4.8 is missing. This is how the pin gets
chosen and how it gets re-validated against future Wine releases. Derived from the probe used to
diagnose this bug.

### 5.6 `tools/smoke-test.sh`

Builds, boots, and asserts Torch reaches its console prompt within a timeout; asserts the in-image
`Release` value. Fails loudly. This is the project's substitute for a test suite.

### 5.7 `start` / `stop`

Behavior preserved: fetch `torch-server.zip` if absent, unzip, force UID/GID 1000 ownership,
`docker compose up -d`, tail logs. `torch-server.zip` is **not** committed — `start` fetches the
current build from `build.torchapi.com` (the predecessor's committed copy dates from June 2024).

## 6. Error handling

| Failure | Behavior |
|---|---|
| A winetricks verb fails | `set -euo pipefail` ⇒ build fails at that line |
| .NET 4.8 missing after install | Verification gate ⇒ build fails with the `Release` value it found |
| Build-time X server won't start | Poll times out ⇒ build fails before any verb runs |
| Wine version not in repo | Pinned `apt-get install` fails ⇒ build fails |
| Torch exits at runtime | Exit code logged; container exits; `restart: unless-stopped` restarts |
| `./torch-server` root-owned | Auto-chowned to `wine` at startup |
| `VNC_PASSWORD` unset | Random password generated and logged once |

## 7. Verification

No build system, no test suite, no linter — same as the predecessor. Verification is:

1. `tools/probe-wine.sh 11.0.0.0~bookworm-1` → `PASS` before the pin is written
2. `docker compose build` → must fail if any runtime dependency is missing
3. In-image assertion: `Release >= 528040`
4. `tools/smoke-test.sh` → Torch reaches its console prompt
5. VNC client to `host:5900` → desktop with openbox and winefile

Rebuilds are slow; the winetricks layer dominates. Nothing above `COPY entrypoint.sh` should be
touched casually.

## 8. Rollback

The existing `spaceengineers:torchapi` image and the `torchapi-wine9` repo are untouched. The new
image builds under a different tag. Rollback is running the old compose file.

## 9. Open items

- **Wine pin.** `11.0.0.0~bookworm-1` pending probe. Fallback ladder: `10.0.0.0~bookworm-1`, then
  `9.0.0.0~bookworm-1`. Unresolved question: whether Wine 10/11's new-wow64 mode can install the
  32-bit .NET 4.8 installer. Wine 9 stable with `wine-stable-i386` uses old-style WoW64 and is the
  configuration `dotnet48` is best tested against, so it is the known-good floor.
- **Pinned winetricks tag.** Set to whatever version the passing probe reports.
- **Private remote.** Not created. Awaiting explicit instruction.
