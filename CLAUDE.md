# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

A Docker image running the Space Engineers **Torch** dedicated server (a Windows .NET Framework 4.8
application) on Debian bookworm under a pinned WineHQ stable 11.0, headless, with an
X11VNC-accessible desktop. There is no application source here — the repo is the container build plus
orchestration shell scripts. Torch itself is fetched by `./start` at runtime and is not committed.

Rebuild of `stubkan/torchapi-wine9`. The design and full root-cause analysis are in
`docs/superpowers/specs/2026-08-03-torch-wine-container-design.md`. Read §2 before changing the build.

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
  predecessor's root cause: verbs aimed at `DISPLAY=:99.0` with no X server during `docker build`, so
  `dotnet48` aborted before launching its installer and only its `dotnet40` dependency's .NET 4.0
  landed — while the build still passed. Torch then died with
  `MissingMethodException: Environment.get_CurrentManagedThreadId` (a .NET 4.5+ method).
- **The verification gate must stay.** `Release >= 528040`, the vcrun/d3dcompiler DLLs, every expected
  verb in `winetricks.log`, and a non-win7 winver. A build that cannot prove the prefix is good must
  fail.
- **`winetricks win10` stays last.** `load_dotnet48()` calls `w_set_winver win7` and never restores
  it. Steam dropped Windows 7/8/8.1 on 2024-01-01, so a win7 prefix makes `steamcmd.exe` fetch
  `client-update.steamstatic.com/steam_cmd_legacy_win32`, which Valve removed — HTTP 404, then
  `Steamcmd needs to be online to update`, and no server update ever.
- **Never add `vcrun2017`.** `vcrun2015`/`vcrun2017`/`vcrun2019` are one VC++ 14.x family; winetricks
  refuses the second (`vcrun2019 conflicts with vcrun2017`). The predecessor's script installed both,
  so its `vcrun2019` line could never have succeeded.
- **Never `rm -rf /tmp/*`.** It deletes `/tmp/.X11-unix`, and Xvfb runs as `wine` (euid != 0) and
  cannot recreate it. This was the predecessor's `_XSERVTransmkdir: euid != 0` error.
- **`WINEPREFIX=/wineprefix`, one value only.** The predecessor also set `/root/server`, which was
  dead and confusing.
- **`wine` must be uid 1000.** `docker-compose.yml` bind-mounts `./torch-server` and Torch must be
  able to write it.
- **Wine and winetricks stay pinned** (`11.0.0.0~bookworm-1`; commit `08304e81` + sha256). The
  predecessor curled winetricks from `master`, and its image was built with `--build-arg` values that
  disagreed with its own Dockerfile — so its Wine version was never actually controlled. Use
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
- **Torch uses its own Wine-side steamcmd**, not any Linux package. Delete `./torch-server/steamcmd/`
  to reset it.

## Style

Plain POSIX `sh`/`bash`. Build and verification scripts use `set -euo pipefail` — a silent failure is
the bug class this repo exists to prevent. `entrypoint.sh` uses `set -uo pipefail` (not `-e`) because
it supervises long-running processes. Privilege drop is always `runuser -u wine -- bash -c '...'`; no
`su`, `gosu`, or `USER` directive.
