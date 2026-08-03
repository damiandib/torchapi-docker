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

Then connect a VNC client to `host:5900`. Set `VNC_PASSWORD` in `docker-compose.yml` or the
environment; if unset, a random password is generated per container and printed to the log:

```bash
sudo docker compose logs | grep "generated for this container"
```

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
| `INSTANCE_NAME` | `TORCHAPI` | For Torch's instance layout; unused by these scripts |

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
- **Torch downloads its own Windows steamcmd.** `Torch.Server.exe` fetches
  `steamcdn-a.akamaihd.net/client/installer/steamcmd.zip`, unpacks it to `steamcmd/` under its
  working directory, and runs `steamcmd.exe` under Wine with `app_update 298740`. No Linux steamcmd is
  installed or used. If it gets into a bad state, delete `./torch-server/steamcmd/` and let Torch
  re-bootstrap it.
- **The prefix is baked into the image, not a volume.** Prefix changes require a rebuild — deliberate,
  because the prefix is verified at build time.
- **File ownership.** Everything in the container runs as `wine` (uid 1000). Root-owned files under
  `./torch-server` are unwritable by Torch; `./start` and the entrypoint both correct this.
