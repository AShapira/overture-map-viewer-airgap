#!/usr/bin/env bash
# Isolated fixtures only: never clear existing buckets, output directories or volumes.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
keep=false
viewer_port=""
while (($#)); do
  case "$1" in
    --keep-services) keep=true ;;
    --viewer-port) viewer_port="${2:?Missing port}"; shift ;;
    -h|--help) printf 'Usage: %s [--keep-services] [--viewer-port PORT]\n' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done
require_rootless_podman
require_command curl
require_command node
for image in "$TILES_IMAGE" docker.io/minio/minio:latest docker.io/minio/mc:latest; do require_local_image "$image"; done
if [[ -n "$viewer_port" ]]; then
  [[ "$viewer_port" =~ ^[0-9]+$ ]] && ((viewer_port >= 1024 && viewer_port <= 65535)) || die 'Invalid viewer port'
  require_local_image "$VIEWER_IMAGE"
fi
seed="${SEED_PARQUET:-$REPO_ROOT/airgap-output/full-validation-20260830/fixture-normalized/release/2026-07-22.0/theme=places/type=place/filtered.parquet}"
require_nonempty_file "$seed"
mkdir -p "$REPO_ROOT/airgap-output"
root="$(mktemp -d "$REPO_ROOT/airgap-output/s3-validation.XXXXXX")"
name="overture-s3-test-$(basename "$root" | tr '[:upper:].' '[:lower:]-')"
mkdir -p "$root"/{store,scratch,output,seed,viewer-config}
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ "$keep" == false ]]; then
    podman rm -f "$name-viewer" "$name" >/dev/null 2>&1 || true
  else
    printf 'Keeping test containers %s and %s-viewer\n' "$name" "$name"
  fi
  printf 'Retained isolated evidence: %s\n' "$root"
  exit "$status"
}
trap cleanup EXIT INT TERM
podman run -d --pull=never --name "$name" -p 127.0.0.1::9000 \
  -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \
  --mount "type=bind,source=$root/store,target=/data" docker.io/minio/minio:latest server /data >/dev/null
port="$(podman port "$name" 9000/tcp | sed 's/.*://')"
wait_for_http "http://127.0.0.1:$port/minio/health/live" 'isolated MinIO'
run_image() {
  podman run --rm --pull=never --network "container:$name" --memory=8g --cpus=4 \
    -e AWS_ACCESS_KEY_ID=minioadmin -e AWS_SECRET_ACCESS_KEY=minioadmin \
    -e AWS_REGION=us-east-1 -e S3_REGION=us-east-1 -e S3_ENDPOINT_URL=http://127.0.0.1:9000 \
    "$@"
}
run_mc() {
  podman run --rm --pull=never --network "container:$name" \
    --mount "type=bind,source=$root,target=/test,ro=true" \
    --entrypoint /bin/sh docker.io/minio/mc:latest -ec \
    'mc alias set local http://127.0.0.1:9000 minioadmin minioadmin >/dev/null; exec mc "$@"' -- "$@"
}
run_image --mount "type=bind,source=$seed,target=/seed.parquet,ro=true" --entrypoint bash "$TILES_IMAGE" -ec \
  's5cmd mb s3://test-source; s5cmd mb s3://test-output; s5cmd cp /seed.parquet s3://test-source/release/theme=places/type=place/part.parquet'
run_generator() {
  run_image -e RELEASE=test-release -e THEMES=places -e BBOX=34.75,32.03,34.85,32.13 \
    -e SOURCE_PATH=s3://test-source/release -e PMTILES_S3_PATH=s3://test-output/pmtiles \
    -e PMTILES_MIN_FREE_GB=1 -e PMTILES_MAX_LOCAL_GB=10 -e PMTILES_MAX_SCRATCH_GB=5 -e PLANETILER_THREADS=4 \
    -e OUTPUT=/output --mount "type=bind,source=$root/output,target=/output" \
    --mount "type=bind,source=$root/scratch,target=/scratch" "$@"
}
run_generator "$TILES_IMAGE" --dry-run --report /output/estimate.json >"$root/estimate.log" 2>&1
[[ ! -d "$root/output/publication" ]] || die 'Dry-run changed publication state'
[[ -z "$(find "$root/scratch" -type f -print -quit)" ]] || die 'Dry-run wrote scratch data'
if run_generator -e PMTILES_MIN_FREE_GB=999999999 "$TILES_IMAGE" >"$root/floor.log" 2>&1; then die 'Impossible free-space floor accepted'; fi
if run_generator -e PMTILES_MAX_SCRATCH_GB=0.001 "$TILES_IMAGE" >"$root/ceiling.log" 2>&1; then die 'Scratch ceiling accepted'; fi
rg -q 'scratch reached.*ceiling' "$root/ceiling.log" || die 'Missing scratch cancellation evidence'
if run_image --entrypoint s5cmd "$TILES_IMAGE" head s3://test-output/pmtiles/places.pmtiles >/dev/null 2>&1; then die 'Published after capacity cancellation'; fi

# Real write-denied publication: readable/listable source and destination, no PutObject.
cat >"$root/read-only.json" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:ListBucket"],"Resource":["arn:aws:s3:::test-source","arn:aws:s3:::test-output"]},{"Effect":"Allow","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::test-source/*","arn:aws:s3:::test-output/*"]}]}
JSON
run_mc admin user add local reader test-reader-password >/dev/null
run_mc admin policy create local test-read-only /test/read-only.json >/dev/null
run_mc admin policy attach local test-read-only --user reader >/dev/null
for attempt in 1 2; do
  if run_generator -e AWS_ACCESS_KEY_ID=reader -e AWS_SECRET_ACCESS_KEY=test-reader-password "$TILES_IMAGE" >"$root/failure-$attempt.log" 2>&1; then die 'Write-denied publication succeeded'; fi
  [[ "$(find "$root/scratch" -name '*.pmtiles' -type f | wc -l)" -eq "$attempt" ]] || die 'Failed archive not retained across runs'
done
run_generator -e PRESERVE_PARQUET=true "$TILES_IMAGE" >"$root/generator.log" 2>&1
require_nonempty_file "$root/output/data/release/test-release/theme=places/type=place/part-000000.parquet"
require_nonempty_file "$root/output/publication/test-release.json"
[[ "$(find "$root/scratch" -name '*.pmtiles' -type f | wc -l)" -eq 2 ]] || die 'Successful archive remains or previous failures were removed'
rg -q 'no source download' "$root/generator.log" || die 'Direct S3 adapter was not used'
if run_generator "$TILES_IMAGE" >"$root/existing-publication.log" 2>&1; then die 'Existing published map could be overwritten'; fi
rg -q 'Destination contains published' "$root/existing-publication.log" || die 'Existing-map protection did not fire'
size="$(node -e 'console.log(require(process.argv[1]).objects[0].size)' "$root/output/publication/test-release.json")"
if run_image --entrypoint java "$TILES_IMAGE" -cp /app/s3-parquet-adapter.jar:/app/planetiler.jar \
  com.onthegomap.planetiler.reader.parquet.AirgapTools verify-remote s3://test-output/pmtiles/places.pmtiles "$size" \
  0000000000000000000000000000000000000000000000000000000000000000 >"$root/checksum-mismatch.log" 2>&1; then die 'Incorrect remote checksum accepted'; fi
rg -q 'SHA-256/size mismatch' "$root/checksum-mismatch.log" || die 'Checksum mismatch was not detected'
node "$REPO_ROOT/scripts/generate-airgap-catalog.mjs" --release test-release \
  --publication-manifest "$root/output/publication/test-release.json" --data-dir "$root/output/data/release/test-release" \
  --out-dir "$root/output/catalog" --bbox 34.75,32.03,34.85,32.13 --tile-base "http://127.0.0.1:$port/test-output/pmtiles/"
run_mc anonymous set download local/test-output/pmtiles >/dev/null
status="$(curl -fsS -H 'Origin: http://localhost' --range 0-7 -D "$root/range.headers" -o "$root/range.bin" -w '%{http_code}' "http://127.0.0.1:$port/test-output/pmtiles/places.pmtiles")"
[[ "$status" == 206 ]] || die 'PMTiles HTTP range did not return 206'
[[ "$(od -An -tx1 "$root/range.bin" | tr -d ' \n')" == 504d54696c657303 ]] || die 'Invalid remote PMTiles magic'
rg -qi '^access-control-allow-origin:' "$root/range.headers" || die 'Missing CORS response'
if [[ -n "$viewer_port" ]]; then
  cat >"$root/viewer-config/viewer-config.json" <<'JSON'
{"stacCatalogUrl":"/catalog/catalog.json","downloadBaseUrl":"/data/release/test-release/","releaseId":"test-release","geocoderBaseUrl":null,"features":{"search":false,"download":true,"externalDocs":false},"download":{"minZoom":15}}
JSON
  podman run -d --pull=never --name "$name-viewer" --read-only --cap-drop ALL --security-opt no-new-privileges:true \
    -p "127.0.0.1:$viewer_port:8080" --mount "type=bind,source=$root/output/catalog,target=/usr/share/nginx/html/catalog,ro=true" \
    --mount "type=bind,source=$root/output/data,target=/usr/share/nginx/html/data,ro=true" \
    --mount "type=bind,source=$root/viewer-config,target=/usr/share/nginx/html/config,ro=true" \
    --tmpfs /tmp --tmpfs /var/cache/nginx --tmpfs /var/run "$VIEWER_IMAGE" >/dev/null
  wait_for_http "http://127.0.0.1:$viewer_port/" 'validation viewer'
  podman healthcheck run "$name-viewer" >/dev/null
  curl -fsS "http://127.0.0.1:$viewer_port/catalog/test-release/places/catalog.json" >/dev/null
fi
printf 'Isolated S3 lifecycle, preservation, checksum, recovery, range, CORS and catalog tests passed.\n'
