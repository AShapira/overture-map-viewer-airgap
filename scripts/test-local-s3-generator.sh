#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

keep_services=false

usage() {
  cat <<'EOF'
Usage: ./scripts/test-local-s3-generator.sh [--keep-services]

Runs the local MinIO-backed tile-generator smoke test with rootless Podman.
EOF
}

while (($# > 0)); do
  case "$1" in
    --keep-services)
      keep_services=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "Unknown argument: $1"
      ;;
  esac
  shift
done

require_rootless_podman
require_command curl
podman_compose_bin >/dev/null
require_local_image "$TILES_IMAGE"

seed_parquet="$REPO_ROOT/airgap-output/data/release/2026-04-15.0/theme=places/type=place/filtered.parquet"
pmtiles_out="$REPO_ROOT/airgap-output/s3-smoke/tiles/2026-04-15.0/places.pmtiles"
parquet_out="$REPO_ROOT/airgap-output/s3-smoke/data/release/2026-04-15.0/theme=places/type=place/filtered.parquet"

[[ -f "$seed_parquet" ]] || die "Missing seed parquet: $seed_parquet. Generate the local places smoke output first."

cleanup() {
  local status=$?
  trap - EXIT INT TERM

  if [[ "$keep_services" == "true" ]]; then
    printf 'Keeping local MinIO running. Stop it with: podman-compose -f compose.local-s3.yml down\n'
  else
    printf 'Stopping local MinIO...\n'
    compose_local_s3 down >/dev/null 2>&1 || true
  fi

  exit "$status"
}
trap cleanup EXIT INT TERM

printf 'Starting local MinIO...\n'
compose_local_s3 up -d minio
wait_for_http "http://127.0.0.1:9000/minio/health/live" "MinIO"

printf 'Seeding the Overture parquet object...\n'
compose_local_s3 run --rm -T s3-seed

printf 'Checking the exact S3 object key...\n'
compose_local_s3 run --rm -T s3-key-check

printf 'Running the tile generator from local S3...\n'
compose_local_s3 run --rm -T tiles-smoke-places-s3

require_nonempty_file "$pmtiles_out"
require_nonempty_file "$parquet_out"

printf 'Local S3 generator smoke test passed.\n'
printf 'Verified key: %s\n' 's3://overture-local/release/2026-04-15.0/theme=places/type=place/filtered.parquet'
printf 'PMTiles output: %s\n' "$pmtiles_out"
printf 'Parquet output: %s\n' "$parquet_out"
