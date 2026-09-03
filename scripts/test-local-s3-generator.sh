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
publication_manifest="$REPO_ROOT/airgap-output/s3-smoke/publication/2026-04-15.0.json"
scratch_root="$REPO_ROOT/airgap-output/s3-smoke/scratch"
retained_pmtiles="$scratch_root/2026-04-15.0/places/places.pmtiles"
generator_log="$(mktemp)"
cap_log="$(mktemp)"

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

  rm -f -- "$generator_log" "$cap_log"

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

printf 'Checking the capacity gate...\n'
if compose_local_s3 run --rm -T -e PMTILES_MIN_FREE_GB=999999999 tiles-smoke-places-s3; then
  die "Generator accepted an impossible scratch capacity floor."
fi

printf 'Checking the removed THEME interface...\n'
if compose_local_s3 run --rm -T -e THEME=places tiles-smoke-places-s3; then
  die "Generator accepted the removed THEME variable."
fi

printf 'Checking the per-theme scratch ceiling...\n'
compose_local_s3 run --rm -T --entrypoint s5cmd s3-key-check \
  rm s3://overture-local/pmtiles/release/2026-04-15.0/places.pmtiles >/dev/null 2>&1 || true
if compose_local_s3 run --rm -T \
  -e PMTILES_MAX_SCRATCH_GB=0.001 \
  tiles-smoke-places-s3 >"$cap_log" 2>&1; then
  die "Generator accepted a run that crossed the per-theme scratch ceiling."
fi
rg -q 'theme scratch reached the configured 0.001 GiB ceiling' "$cap_log" \
  || die "Generator did not report the per-theme scratch ceiling failure."
if compose_local_s3 run --rm -T --entrypoint s5cmd s3-key-check \
  head s3://overture-local/pmtiles/release/2026-04-15.0/places.pmtiles >/dev/null 2>&1; then
  die "Generator published PMTiles after crossing the per-theme scratch ceiling."
fi
[[ ! -e "$publication_manifest" ]] \
  || die "Generator wrote a publication manifest after crossing the per-theme scratch ceiling."

printf 'Running the tile generator from local S3...\n'
compose_local_s3 run --rm -T tiles-smoke-places-s3 2>&1 | tee "$generator_log"

rg -q 'Indexed [0-9]+ S3 GeoParquet object.*no source download' "$generator_log" \
  || die "Generator did not confirm direct S3 range input."
rg -q 'Closed S3 GeoParquet source.*range request' "$generator_log" \
  || die "Generator did not report S3 range-read statistics."
require_nonempty_file "$publication_manifest"
if find "$scratch_root" -type f -name '*.pmtiles' -print -quit | grep -q .; then
  die "A successfully published PMTiles file remains in scratch."
fi

printf 'Checking the published PMTiles object...\n'
compose_local_s3 run --rm -T --entrypoint s5cmd s3-key-check \
  head s3://overture-local/pmtiles/release/2026-04-15.0/places.pmtiles

node -e '
  const fs = require("node:fs");
  const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (manifest.themes.join(",") !== "places") throw new Error("unexpected published themes");
  if (manifest.objects.length !== 1 || manifest.objects[0].size <= 0) throw new Error("invalid publication object");
' "$publication_manifest"

printf 'Checking upload-failure retention...\n'
if compose_local_s3 run --rm -T \
  -e OUTPUT=/failure-output \
  -e PMTILES_S3_PATH=s3://missing-bucket/pmtiles/release/2026-04-15.0 \
  tiles-smoke-places-s3; then
  die "Generator unexpectedly published to a missing bucket."
fi
require_nonempty_file "$retained_pmtiles"
rm -rf -- "$scratch_root/2026-04-15.0/places"

printf 'Local S3 generator smoke test passed.\n'
printf 'Verified key: %s\n' 's3://overture-local/release/2026-04-15.0/theme=places/type=place/filtered.parquet'
printf 'Published PMTiles: %s\n' 's3://overture-local/pmtiles/release/2026-04-15.0/places.pmtiles'
printf 'Publication manifest: %s\n' "$publication_manifest"
