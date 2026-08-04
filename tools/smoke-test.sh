#!/usr/bin/env bash
# Build the image, boot it, and assert Torch actually starts.
#
# Two independent checks, because a crashed Torch and a healthy Torch can look similar
# in a truncated log:
#   1. the image's prefix really has .NET 4.8
#   2. Torch.Server.exe is still alive after the startup window, with no unhandled exception
#
# Set DOCKER="sudo docker" if your user cannot reach the docker socket.
set -euo pipefail

cd "$(dirname "$0")/.."
DOCKER=${DOCKER:-docker}
COMPOSE="${DOCKER} compose"
# Read logs by container name: `compose logs` has been observed returning nothing on hosts where
# `docker logs torchapi` works, and a test reading an empty log passes for the wrong reason.
CONTAINER=${CONTAINER:-torchapi}
logs() { $DOCKER logs "$CONTAINER" 2>&1; }
# The first boot installs the SE dedicated server (several GB), so raise TIMEOUT for it:
#   TIMEOUT=3600 tools/smoke-test.sh
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

report() { echo "--- last 60 log lines ---"; $DOCKER logs --tail 60 "$CONTAINER" 2>&1 || true; }

# Torch emits this once it has loaded Torch.cfg and finished applying its patches -- i.e. it is
# genuinely initialised, not merely running. Verified against a working server.
TORCH_READY='PatchManager: Patching done'

deadline=$(( SECONDS + TIMEOUT ))
started=0
while [ "$SECONDS" -lt "$deadline" ]; do
  if logs | grep -qE "MissingMethodException|Unhandled Exception|WineDbg attached"; then
    echo "FAIL: Torch threw an unhandled exception"
    report
    exit 1
  fi
  if logs | grep -q "_XSERVTransmkdir: ERROR"; then
    echo "FAIL: /tmp/.X11-unix is missing from the image"
    report
    exit 1
  fi
  if logs | grep -q "\[entrypoint\] FATAL"; then
    echo "FAIL: the entrypoint refused to start Torch"
    logs | grep "\[entrypoint\] FATAL"
    exit 1
  fi
  if logs | grep -q "$TORCH_READY"; then
    started=1
    break
  fi
  sleep 5
done

if [ "$started" -ne 1 ]; then
  echo "FAIL: Torch never reached '${TORCH_READY}' within ${TIMEOUT}s"
  if $DOCKER exec "$CONTAINER" pgrep -f Torch.Server.exe >/dev/null 2>&1; then
    echo "       (Torch.Server.exe is running but never finished initialising)"
  fi
  report
  exit 1
fi
echo "Torch initialised: '${TORCH_READY}' seen"

echo "=== Torch is running; confirming it stays up for ${STABLE_FOR}s ==="
sleep "$STABLE_FOR"

if logs | grep -qE "MissingMethodException|Unhandled Exception|WineDbg attached"; then
  echo "FAIL: Torch crashed during the stability window"
  report
  exit 1
fi
if ! $DOCKER exec "$CONTAINER" pgrep -f Torch.Server.exe >/dev/null 2>&1; then
  echo "FAIL: Torch.Server.exe exited during the stability window"
  report
  exit 1
fi

echo "PASS: image boots, .NET 4.8 present, Torch running and stable for ${STABLE_FOR}s"
