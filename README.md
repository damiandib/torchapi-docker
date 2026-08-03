# torchapi-docker

Space Engineers **Torch** dedicated server running under Wine in Docker, headless, with a
VNC-accessible desktop.

Rebuild of [`torchapi-wine9`](https://github.com/stubkan/torchapi-wine9), whose prefix installed
.NET 4.0 instead of the 4.8 Torch needs — on a build that reported success. See
`docs/superpowers/specs/2026-08-03-torch-wine-container-design.md` for the full root-cause analysis.

## Quick start

```bash
./start          # fetch Torch, unpack, chown to uid 1000, build if needed, up -d, tail logs
./stop           # compose stop && down
```

Then connect a VNC client to `host:5900`. Set `VNC_PASSWORD` in the environment, in a `.env` file
next to `docker-compose.yml`, or directly in the compose file:

```bash
echo 'VNC_PASSWORD=hunter2' > .env
```

If unset, a random password is generated per container and printed to the log:

```bash
sudo docker compose logs | grep "generated for this container"
```

**VNC auth uses only the first 8 characters** of the password — a DES limitation of the protocol, not
this image. Longer values are accepted and silently truncated, so use 8 characters to avoid
confusion.

## Requirements

Docker with Compose v2 (`docker compose`, not `docker-compose`), and roughly 6 GB of disk for the
image. The winetricks layer takes ~5 minutes to build.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `VNC_PASSWORD` | *(random per container)* | VNC password. Never baked into the image |
| `VNC_PORT` | `5900` | x11vnc port inside the container |
| `XVFB_RES` | `1024x768x24` | Virtual display geometry |
| `CHOWN_TORCH_DIR` | `1` | Chown `/app/torch-server` to uid 1000 at boot |
| `TORCH_EXE` | `Z:/app/torch-server/Torch.Server.exe` | Wine path to the server binary |
| `TORCH_ARGS` | `-noupdate` | Args passed to Torch. See "SE install" below before changing |
| `SE_APPID` | `298740` | Steam app id of the SE dedicated server |
| `SE_UPDATE_ON_BOOT` | `1` | Run `app_update` on every boot. `0` uses the copy on disk |
| `STEAMCMD` | `/opt/steamcmd/steamcmd.sh` | Native Linux steamcmd used for the SE install |
| `INSTANCE_NAME` | `TORCHAPI` | For Torch's instance layout; unused by these scripts |

## SE install — why `-noupdate`

Torch normally installs the SE dedicated server itself by downloading the *Windows* steamcmd and
running it under Wine. That does not work here: steamcmd starts, never retrieves app metadata, and
fails with `Failed installing AppID 298740 (Missing configuration)` — leaving `appcache/appinfo.vdf`
absent. Torch logs `SteamCMD update check complete` regardless and then dies with

```
System.IO.DirectoryNotFoundException: Could not find a part of the path
'Z:\app\torch-server\DedicatedServer64\steam_api64.dll'
```

So the entrypoint installs SE with **native Linux steamcmd** and
`+@sSteamCmdForcePlatformType windows` (which fetches the Windows build Wine needs), verifies
`DedicatedServer64/steam_api64.dll` exists, and starts Torch with `-noupdate` so it does not retry
the broken path. First boot downloads several GB; later boots run `app_update` unless
`SE_UPDATE_ON_BOOT=0`.

If you set `TORCH_ARGS` to something without `-noupdate`, Torch will attempt its own update again.

Ports: `27016/udp` (game) and `5900/tcp` (VNC). Port 27016 is UDP **only** — plugins or a Remote API
needing TCP require uncommenting that mapping in `docker-compose.yml`.

## Verification

```bash
tools/probe-wine.sh 11.0.0.0~bookworm-1   # can this Wine version build a working prefix?
tools/smoke-test.sh                        # does the image boot and run Torch?
```

Both exit non-zero on failure. There is no unit test suite; these are the tests. Prefix `DOCKER="sudo
docker"` if your user cannot reach the docker socket.

## Rebuilding

Editing `entrypoint.sh` is cheap — it is the last layer. Editing `winetricks.sh` or anything above it
rebuilds the ~5-minute winetricks layer.

```bash
sudo docker compose up -d --build
```

## Notes

- **The server is single-shot.** Restarting Torch from inside its own GUI kills the window manager
  and does not cleanly recover. Restart the container instead. Edit server and instance configs while
  stopped, not live.
- **Torch's own updater is bypassed.** Left to itself, Torch unpacks a Windows steamcmd into
  `./torch-server/steam/steamcmd/` and runs it under Wine, where it cannot install app 298740. We use
  native Linux steamcmd instead and pass `-noupdate` — see "SE install" above. To force a clean SE
  reinstall, delete `./torch-server/DedicatedServer64/` and restart the container.
- **The prefix is baked into the image, not a volume.** Prefix changes require a rebuild — deliberate,
  because the prefix is verified at build time.
- **File ownership.** Everything in the container runs as `wine` (uid 1000). Root-owned files under
  `./torch-server` are unwritable by Torch; `./start` and the entrypoint both correct this.
