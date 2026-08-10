#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
AIRGAP_COMPOSE_FILE="$REPO_ROOT/compose.airgap.yml"
LOCAL_S3_COMPOSE_FILE="$REPO_ROOT/compose.local-s3.yml"
LOCAL_S3_NETWORK="overture-airgap-s3"
VIEWER_IMAGE="localhost/overture-explorer-airgap:local"
TILES_IMAGE="localhost/overture-tiles-airgap:local"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

podman_compose_bin() {
  if [[ -x /usr/local/bin/podman-compose ]]; then
    printf '%s\n' /usr/local/bin/podman-compose
    return
  fi

  if command -v podman-compose >/dev/null 2>&1; then
    command -v podman-compose
    return
  fi

  die "podman-compose is required. Install it in RHEL and ensure it is on PATH."
}

require_rootless_podman() {
  require_command podman

  local rootless
  rootless="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" \
    || die "Podman is unavailable. Start the RHEL WSL distro and verify 'podman info'."

  [[ "$rootless" == "true" ]] \
    || die "This project supports rootless Podman only. Run as your RHEL user without sudo."
}

compose_local_s3() {
  local compose_bin
  compose_bin="$(podman_compose_bin)"
  "$compose_bin" -f "$LOCAL_S3_COMPOSE_FILE" "$@"
}

require_local_image() {
  podman image exists "$1" \
    || die "Missing image $1. Build the local Podman images first; see README.md."
}

require_nonempty_file() {
  local path="$1"
  [[ -s "$path" ]] || die "Expected non-empty file was not created: $path"
}

wait_for_http() {
  local url="$1"
  local description="$2"
  local attempts="${3:-60}"

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done

  die "Timed out waiting for $description at $url"
}
