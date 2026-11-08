#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
IMAGE=${HADRON_YOCTO_DOCKER_IMAGE:-hadron-yocto:scarthgap}
DOWNLOADS=${HADRON_DL_CACHE:-/media/ranshal/jetson/shared/downloads}
SSTATE=${HADRON_SSTATE_CACHE:-/media/ranshal/jetson/shared/sstate}
HOST_UID=${SUDO_UID:-$(id -u)}
HOST_GID=${SUDO_GID:-$(id -g)}
HOST_USER=${SUDO_USER:-$(id -un)}

if [[ "$HOST_UID" == 0 ]]; then
    echo "Run as a non-root user (sudo from that user is supported)." >&2
    exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
    echo "Required command not found: docker" >&2
    exit 1
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Docker image unavailable or Docker access denied: $IMAGE" >&2
    echo "Build it first: docker build -f ci/Dockerfile -t $IMAGE ci" >&2
    exit 1
fi
for cache in "$DOWNLOADS" "$SSTATE"; do
    if [[ ! -d "$cache" ]]; then
        echo "Cache directory not found: $cache" >&2
        echo "Create it first or set HADRON_DL_CACHE and HADRON_SSTATE_CACHE." >&2
        exit 1
    fi
done

# Preserve absolute paths recorded in an existing BitBake build directory.
exec docker run --rm \
    -e "UID=$HOST_UID" \
    -e "GID=$HOST_GID" \
    -e "USERNAME=$HOST_USER" \
    -w "$ROOT_DIR" \
    -v "$ROOT_DIR:$ROOT_DIR" \
    -v "$DOWNLOADS:/media/ranshal/jetson/shared/downloads" \
    -v "$SSTATE:/media/ranshal/jetson/shared/sstate" \
    "$IMAGE" \
    kas build kas.yml "$@"
