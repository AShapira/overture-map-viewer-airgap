#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

viewer_port=8099
keep_services=false

usage() {
  cat <<'EOF'
Usage: ./scripts/validate-airgap-s3-runbook.sh [--viewer-port PORT] [--keep-services]

Validates the complete local S3-to-viewer air-gap workflow with rootless Podman.
EOF
}

while (($# > 0)); do
  case "$1" in
    --viewer-port)
      (($# >= 2)) || die "--viewer-port requires a value"
      viewer_port="$2"
      shift
      ;;
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

[[ "$viewer_port" =~ ^[0-9]+$ ]] && ((viewer_port >= 1024 && viewer_port <= 65535)) \
  || die "Viewer port must be an unprivileged port from 1024 through 65535."

require_rootless_podman
require_command curl
require_command node
podman_compose_bin >/dev/null
require_local_image "$TILES_IMAGE"
require_local_image "$VIEWER_IMAGE"

release="2026-04-15.0"
bbox="${BBOX:-}"
source_path="s3://overture-source/release/$release"
output_bucket="s3://overture-generated"
s3_endpoint="http://minio:9000"
viewer_name="overture-runbook-validation-viewer"

seed_parquet="$REPO_ROOT/airgap-output/data/release/$release/theme=places/type=place/filtered.parquet"
validation_root="$REPO_ROOT/airgap-output/runbook-validation"
generator_output="$validation_root/generator-output"
scratch_root="$validation_root/scratch"
viewer_root="$validation_root/viewer-data"
viewer_config="$validation_root/viewer-config.json"
source_object_name="part-00000.parquet"
normalized_seed="$validation_root/$source_object_name"
if [[ -n "$bbox" ]]; then
  preserved_object_name="filtered.parquet"
else
  preserved_object_name="$source_object_name"
fi

[[ -f "$seed_parquet" ]] || die "Missing seed parquet: $seed_parquet. Generate the local places smoke output first."

remove_validation_viewer() {
  podman rm -f "$viewer_name" >/dev/null 2>&1 || true
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM

  if [[ "$keep_services" == "true" ]]; then
    printf 'Keeping the validation viewer and MinIO running.\n'
    printf 'Stop the viewer with: podman rm -f %s\n' "$viewer_name"
    printf 'Stop MinIO with: podman-compose -f compose.local-s3.yml down\n'
  else
    remove_validation_viewer
    compose_local_s3 down >/dev/null 2>&1 || true
  fi

  exit "$status"
}
trap cleanup EXIT INT TERM

run_tile_image() {
  podman run --rm \
    --network "$LOCAL_S3_NETWORK" \
    -e AWS_ACCESS_KEY_ID=minioadmin \
    -e AWS_SECRET_ACCESS_KEY=minioadmin \
    -e AWS_REGION=us-east-1 \
    -e S3_REGION=us-east-1 \
    -e S3_ENDPOINT_URL="$s3_endpoint" \
    "$@"
}

test_http_range() {
  local url="$1"
  local status
  status="$(curl -sS --range 0-1023 --output /dev/null --write-out '%{http_code}' "$url")"
  [[ "$status" == "200" || "$status" == "206" ]] \
    || die "Unexpected PMTiles range status $status for $url"
}

case "$validation_root" in
  "$REPO_ROOT"/airgap-output/runbook-validation) ;;
  *) die "Refusing to clear unexpected validation path: $validation_root" ;;
esac
rm -rf -- "$validation_root"
mkdir -p -- "$generator_output" "$scratch_root" "$viewer_root"

cat >"$viewer_config" <<EOF
{
  "stacCatalogUrl": "/catalog/catalog.json",
  "downloadBaseUrl": "/data/release/$release/",
  "releaseId": "$release",
  "geocoderBaseUrl": null,
  "features": {
    "search": false,
    "download": true,
    "externalDocs": false
  },
  "download": {
    "minZoom": 15
  }
}
EOF

printf 'Starting local MinIO...\n'
compose_local_s3 up -d minio
wait_for_http "http://127.0.0.1:9000/minio/health/live" "MinIO"

printf 'Normalizing the seed GeoParquet...\n'
podman run --rm \
  --mount "type=bind,source=$seed_parquet,target=/seed/filtered.parquet,ro=true" \
  --mount "type=bind,source=$validation_root,target=/validation" \
  --entrypoint duckdb \
  "$TILES_IMAGE" \
  -c "COPY (SELECT * EXCLUDE (filename) FROM read_parquet('/seed/filtered.parquet')) TO '/validation/$source_object_name';"
require_nonempty_file "$normalized_seed"

printf 'Seeding the source GeoParquet bucket...\n'
run_tile_image \
  --mount "type=bind,source=$normalized_seed,target=/seed/$source_object_name,ro=true" \
  --entrypoint bash \
  "$TILES_IMAGE" \
  -c "set -eu; s5cmd mb s3://overture-source >/dev/null 2>&1 || true; s5cmd rm 's3://overture-source/*' >/dev/null 2>&1 || true; s5cmd cp /seed/$source_object_name s3://overture-source/release/$release/theme=places/type=place/$source_object_name; s5cmd head s3://overture-source/release/$release/theme=places/type=place/$source_object_name"

printf 'Creating the generated-output bucket...\n'
run_tile_image \
  --entrypoint bash \
  "$TILES_IMAGE" \
  -c "s5cmd mb s3://overture-generated >/dev/null 2>&1 || true; s5cmd rm 's3://overture-generated/*' >/dev/null 2>&1 || true; s5cmd ls s3://overture-generated >/dev/null"

printf 'Generating tiles from the source bucket...\n'
run_tile_image \
  -e RELEASE="$release" \
  -e THEMES=places \
  -e BBOX="$bbox" \
  -e SOURCE_PATH="$source_path" \
  -e PMTILES_S3_PATH="$output_bucket/pmtiles/release/$release" \
  -e PMTILES_SCRATCH_ROOT=/scratch \
  -e PMTILES_MIN_FREE_GB=1 \
  -e OUTPUT=/output \
  -e PRESERVE_PARQUET=true \
  --mount "type=bind,source=$generator_output,target=/output" \
  --mount "type=bind,source=$scratch_root,target=/scratch" \
  "$TILES_IMAGE"

require_nonempty_file "$generator_output/data/release/$release/theme=places/type=place/$preserved_object_name"
require_nonempty_file "$generator_output/publication/$release.json"
if find "$scratch_root" -type f -name '*.pmtiles' -print -quit | grep -q .; then
  die "A successfully published PMTiles file remains in scratch."
fi

run_tile_image \
  --entrypoint s5cmd \
  "$TILES_IMAGE" \
  head "$output_bucket/pmtiles/release/$release/places.pmtiles"

printf 'Generating the local STAC catalog...\n'
node "$REPO_ROOT/scripts/generate-airgap-catalog.mjs" \
  --release "$release" \
  --publication-manifest "$generator_output/publication/$release.json" \
  --data-dir "$generator_output/data/release/$release" \
  --out-dir "$generator_output/catalog" \
  --bbox "$bbox" \
  --tile-base "http://127.0.0.1:9000/overture-generated/pmtiles/release/$release/"

require_nonempty_file "$generator_output/catalog/catalog.json"
require_nonempty_file "$generator_output/catalog/$release/manifest.geojson"

printf 'Uploading catalog and parquet output to MinIO...\n'
for prefix in data catalog; do
  run_tile_image \
    --mount "type=bind,source=$generator_output,target=/output,ro=true" \
    --entrypoint s5cmd \
    "$TILES_IMAGE" \
    sync "/output/$prefix/*" "$output_bucket/$prefix/"
done

printf 'Allowing anonymous HTTP reads of the validation PMTiles prefix...\n'
compose_local_s3 run --rm -T s3-public-read

printf 'Synchronizing generated output into the viewer data directory...\n'
for prefix in catalog data; do
  run_tile_image \
    --mount "type=bind,source=$viewer_root,target=/viewer-data" \
    --entrypoint s5cmd \
    "$TILES_IMAGE" \
    sync "$output_bucket/$prefix/*" "/viewer-data/$prefix/"
done

remove_validation_viewer
printf 'Starting the validation viewer on port %s...\n' "$viewer_port"
podman run -d \
  --name "$viewer_name" \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --health-interval disable \
  -p "$viewer_port:8080" \
  --mount "type=bind,source=$viewer_root/catalog,target=/usr/share/nginx/html/catalog,ro=true" \
  --mount "type=bind,source=$viewer_root/data,target=/usr/share/nginx/html/data,ro=true" \
  --mount "type=bind,source=$viewer_config,target=/usr/share/nginx/html/config/viewer-config.json,ro=true" \
  --tmpfs /tmp \
  --tmpfs /var/cache/nginx \
  --tmpfs /var/run \
  "$VIEWER_IMAGE" >/dev/null

base_url="http://127.0.0.1:$viewer_port"
wait_for_http "$base_url/" "validation viewer"
podman healthcheck run "$viewer_name" >/dev/null
[[ "$(podman inspect "$viewer_name" --format '{{.State.Health.Status}}')" == "healthy" ]] \
  || die "Validation viewer image healthcheck did not pass."
curl -fsS "$base_url/config/viewer-config.json" >/dev/null
curl -fsS "$base_url/catalog/catalog.json" >/dev/null
curl -fsS "$base_url/catalog/$release/manifest.geojson" >/dev/null
pmtiles_url="http://127.0.0.1:9000/overture-generated/pmtiles/release/$release/places.pmtiles"
curl -fsS "$pmtiles_url" >/dev/null
test_http_range "$pmtiles_url"

printf 'Runbook validation passed.\n'
printf 'Viewer URL: %s\n' "$base_url"
printf 'Generated output: %s\n' "$generator_output"
printf 'Viewer data: %s\n' "$viewer_root"
