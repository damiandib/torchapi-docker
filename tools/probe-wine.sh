#!/usr/bin/env bash
# Verify that a candidate WineHQ stable version can build a working prefix (.NET 4.8 present).
#
# The image's own build-time verification gate is the test: if the prefix is bad, the build
# fails, and so does this script. Use it to re-validate the pin against future Wine releases.
#
# Usage: tools/probe-wine.sh 11.0.0.0~bookworm-1
#        tools/probe-wine.sh 10.0.0.0~bookworm-1   # fallback ladder
#        tools/probe-wine.sh 9.0.0.0~bookworm-1
#
# Set DOCKER="sudo docker" if your user cannot reach the docker socket.
set -euo pipefail

VERSION=${1:?usage: tools/probe-wine.sh <winehq version, e.g. 11.0.0.0~bookworm-1>}
cd "$(dirname "$0")/.."

TAG="torchapi-probe:$(printf '%s' "$VERSION" | tr -c 'A-Za-z0-9._-' '-')"
DOCKER=${DOCKER:-docker}

echo "=== probing winehq-stable=${VERSION} -> ${TAG} ==="
if ! $DOCKER build --progress=plain --build-arg "WINEVERSION=${VERSION}" -t "$TAG" . ; then
  echo "FAIL: ${VERSION} did not produce a verified prefix (see build log above)"
  exit 1
fi

echo "=== ${VERSION} built; reading the prefix back ==="
$DOCKER run --rm --entrypoint /bin/bash "$TAG" -c \
  'runuser -u wine -- env WINEPREFIX=/wineprefix wine reg query "HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full" 2>/dev/null | tr -d "\r"'

echo "PASS: ${VERSION} produced a verified prefix (image ${TAG})"
echo "Remove it with: ${DOCKER} rmi ${TAG}"
