#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_rootless_podman

printf 'Building the viewer image...\n'
podman build \
  --format docker \
  -f "$REPO_ROOT/Dockerfile.viewer" \
  -t "$VIEWER_IMAGE" \
  "$REPO_ROOT"

printf 'Building the tile-generator image...\n'
podman build \
  --format docker \
  -t "$TILES_IMAGE" \
  "$REPO_ROOT/airgap/tile-generator"

printf 'Building the PMTiles proxy image...\n'
podman build --format docker -t "$PROXY_IMAGE" "$REPO_ROOT/airgap/pmtiles-proxy"

printf 'Built %s, %s and %s with rootless Podman.\n' "$VIEWER_IMAGE" "$TILES_IMAGE" "$PROXY_IMAGE"
