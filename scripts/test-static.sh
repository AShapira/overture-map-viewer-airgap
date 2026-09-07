#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_rootless_podman
require_command npm
require_command rg
podman_compose_bin >/dev/null

printf 'Checking Bash syntax...\n'
while IFS= read -r script; do
  bash -n "$script"
done < <(find "$REPO_ROOT/scripts" "$REPO_ROOT/airgap" -type f -name '*.sh' -print)

printf 'Checking BBOX theme coverage...\n'
rg -q 'base\) TYPES="[^"]*land_use[^"]*"' "$REPO_ROOT/airgap/tile-generator/bbox.sh" \
  || die "BBOX filtering must include the base land_use type."
python3 -B "$REPO_ROOT/scripts/test-generator.py"
rg -q 'S3InputFiles.open' "$REPO_ROOT/airgap/tile-generator/profiles/OvertureProfile.java" \
  || die "Overture profile must route S3 input through the range adapter."

printf 'Validating Podman Compose files...\n'
env \
  PMTILES_S3_PATH=s3://example/pmtiles/release/2026-04-15.0 \
  PMTILES_MIN_FREE_GB=1 \
  S3_REGION=us-east-1 \
  S3_ENDPOINT_URL=https://s3.example.invalid \
  AWS_ACCESS_KEY_ID=test \
  AWS_SECRET_ACCESS_KEY=test \
  "$(podman_compose_bin)" -f "$AIRGAP_COMPOSE_FILE" config >/dev/null
"$(podman_compose_bin)" -f "$LOCAL_S3_COMPOSE_FILE" config >/dev/null

printf 'Checking single-stage generation configuration...\n'
if rg -q '^  publish-pmtiles:' "$REPO_ROOT/compose.windows-airgap.yml"; then
  die "The separate PMTiles publisher service remains configured."
fi
if rg -q 'tiles_output|/usr/share/nginx/html/tiles' \
  "$REPO_ROOT/compose.windows-airgap.yml" "$REPO_ROOT/compose.airgap.yml"; then
  die "A local PMTiles volume or viewer mount remains configured."
fi

generator_test_root="$(mktemp -d)"
mkdir -p "$generator_test_root/scratch"
cleanup_generator_test() {
  rm -rf -- "$generator_test_root"
}
trap cleanup_generator_test EXIT

if THEME=places OUTPUT="$generator_test_root/output" PMTILES_SCRATCH_ROOT="$generator_test_root/scratch" \
  PMTILES_S3_PATH=s3://example/pmtiles PMTILES_MIN_FREE_GB=1 \
  bash "$REPO_ROOT/airgap/tile-generator/run-airgap.sh" >/dev/null 2>&1; then
  die "Generator accepted the removed THEME variable."
fi

if THEMES=places,places OUTPUT="$generator_test_root/output" \
  PMTILES_SCRATCH_ROOT="$generator_test_root/scratch" PMTILES_S3_PATH=s3://example/pmtiles \
  PMTILES_MIN_FREE_GB=1 bash "$REPO_ROOT/airgap/tile-generator/run-airgap.sh" >/dev/null 2>&1; then
  die "Generator accepted duplicate THEMES entries."
fi

if THEMES=places OUTPUT="$generator_test_root/output" \
  PMTILES_SCRATCH_ROOT="$generator_test_root/scratch" PMTILES_S3_PATH=s3://example/pmtiles \
  PMTILES_MIN_FREE_GB=999999999 bash "$REPO_ROOT/airgap/tile-generator/run-airgap.sh" >/dev/null 2>&1; then
  die "Generator accepted an impossible capacity floor."
fi

if THEMES=places OUTPUT="$generator_test_root/output" \
  PMTILES_SCRATCH_ROOT="$generator_test_root/scratch" PMTILES_S3_PATH=s3://example/pmtiles \
  PMTILES_MIN_FREE_GB=1 PLANETILER_COMPRESS_TEMP=true PLANETILER_MMAP_TEMP=true \
  bash "$REPO_ROOT/airgap/tile-generator/run-airgap.sh" >/dev/null 2>&1; then
  die "Generator accepted compressed temp with mmap temp enabled."
fi

if THEMES=places OUTPUT="$generator_test_root/output" \
  PMTILES_SCRATCH_ROOT="$generator_test_root/scratch" PMTILES_S3_PATH=s3://example/pmtiles \
  PMTILES_MIN_FREE_GB=1 PMTILES_MAX_SCRATCH_GB=invalid \
  bash "$REPO_ROOT/airgap/tile-generator/run-airgap.sh" >/dev/null 2>&1; then
  die "Generator accepted an invalid per-theme scratch ceiling."
fi

mkdir -p "$generator_test_root/data" "$generator_test_root/catalog"
printf '%s\n' '{"schema_version":1,"release":"test-release","bbox":[-180,-90,180,90],"themes":["places"],"objects":[{"theme":"places","filename":"places.pmtiles","uri":"s3://example/places.pmtiles","size":123}]}' \
  >"$generator_test_root/publication.json"
node "$REPO_ROOT/scripts/generate-airgap-catalog.mjs" \
  --release test-release \
  --publication-manifest "$generator_test_root/publication.json" \
  --data-dir "$generator_test_root/data" \
  --out-dir "$generator_test_root/catalog" \
  --tile-base https://tiles.example.invalid/test-release/ >/dev/null
rg -q 'https://tiles\.example\.invalid/test-release/places\.pmtiles' \
  "$generator_test_root/catalog/test-release/places/catalog.json" \
  || die "Catalog did not use the remote PMTiles base URL."
if node "$REPO_ROOT/scripts/generate-airgap-catalog.mjs" \
  --release test-release \
  --publication-manifest "$generator_test_root/publication.json" \
  --data-dir "$generator_test_root/data" \
  --out-dir "$generator_test_root/catalog" \
  --bbox 0,0,1,1 \
  --tile-base https://tiles.example.invalid/test-release/ >/dev/null 2>&1; then
  die "Catalog accepted a BBOX that did not match the publication manifest."
fi
cleanup_generator_test
trap - EXIT

printf 'Checking for unsupported local tooling...\n'
runtime_paths=(
  "$REPO_ROOT/README.md"
  "$REPO_ROOT/docs/airgap-design.md"
  "$REPO_ROOT/docs/airgap-s3-runbook.md"
  "$REPO_ROOT/docs/windows-podman-desktop-airgap.md"
  "$REPO_ROOT/scripts"
  "$REPO_ROOT/compose.airgap.yml"
  "$REPO_ROOT/compose.local-s3.yml"
  "$REPO_ROOT/compose.windows-airgap.yml"
)

if rg -n -i -g '!test-static.sh' 'docker[[:space:]]+(build|compose|images|load|run|save)|Docker Desktop' "${runtime_paths[@]}"; then
  die "Unsupported Docker local-runtime instructions remain."
fi

npm --prefix "$REPO_ROOT/airgap/pmtiles-proxy" test

printf 'Running npm lint...\n'
(cd "$REPO_ROOT" && npm run lint)

printf 'Running Jest tests...\n'
(cd "$REPO_ROOT" && npm test -- --runInBand)

printf 'Building the static viewer...\n'
(cd "$REPO_ROOT" && npm run build)

printf 'Running browser accessibility checks...\n'
(cd "$REPO_ROOT" && npm run test:a11y)

printf 'Static validation passed.\n'
