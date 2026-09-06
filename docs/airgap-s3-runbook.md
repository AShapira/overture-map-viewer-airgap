# Air-Gap S3 Generation and Viewer Runbook

This runbook generates configured Overture PMTiles sequentially with rootless
Podman, publishes each completed archive immediately to internal S3, and serves
it to browsers through a range-capable HTTP gateway. PMTiles are never retained
in a local output volume.

## 1. Data Flow

```text
mounted GeoParquet or direct S3 ranged GeoParquet reads
  -> rootless one-shot tile-generator
  -> monitored local scratch folder
  -> one completed theme archive
  -> upload and streamed SHA-256 and byte-size verification in S3
  -> immediate local deletion
  -> publication manifest after all configured themes succeed
  -> local catalog/config and optional preserved GeoParquet
  -> read-only viewer using an internal S3 HTTP gateway for PMTiles
```

Only the generator receives S3 credentials. The viewer reads HTTPS URLs from
the generated catalogs.

## 2. Object Layout and Permissions

Source keys must preserve the release layout:

```text
s3://<source-bucket>/<source-prefix>/<release>/theme=<theme>/type=<type>/<file>.parquet
```

Generated archives use:

```text
s3://<output-bucket>/<pmtiles-prefix>/<release>/<theme>.pmtiles
```

The generator identity needs list/read access to source keys and list/read/write
access only to the generated prefix. The HTTP gateway must support `GET`, `HEAD`,
CORS from the viewer origin, and byte ranges returning HTTP `206`.

## 3. Validate Rootless Podman and Images

```bash
podman info --format 'rootless={{.Host.Security.Rootless}}'
podman image exists localhost/overture-tiles-airgap:local
podman image exists localhost/overture-explorer-airgap:local
```

The first command must report `rootless=true`. Import verified OCI archives into
the disconnected environment before continuing.

## 4. Configure the Run

```bash
export RELEASE=2026-04-15.0
export THEMES=base,buildings,places,divisions,transportation,addresses
export BBOX=
export SOURCE_PATH=s3://overture-source/release/$RELEASE
export PMTILES_S3_PATH=s3://overture-generated/pmtiles/release/$RELEASE
export PMTILES_HTTP_BASE=https://s3-gateway.internal/overture-generated/pmtiles/release/$RELEASE/
export PMTILES_SCRATCH_DIR=/path/to/large-local-scratch
export PMTILES_MIN_FREE_GB=100
export PMTILES_MAX_SCRATCH_GB=95
export PRESERVE_PARQUET=false
export PMTILES_MAX_LOCAL_GB=100
export PLANETILER_SORT_MAX_READERS=1
export PLANETILER_SORT_MAX_WRITERS=1
export PLANETILER_COMPRESS_TEMP=true
export PLANETILER_MMAP_TEMP=false

export S3_ENDPOINT_URL=https://s3.internal
export S3_REGION=us-east-1
export AWS_ACCESS_KEY_ID=replace-with-access-key
export AWS_SECRET_ACCESS_KEY=replace-with-secret-key
```

`THEMES` is an ordered comma-separated subset of `base`, `buildings`, `places`,
`divisions`, `transportation`, and `addresses`. It defaults to all six. The old
singular `THEME` variable is rejected.

`BBOX` is `min_lon,min_lat,max_lon,max_lat`; leave it empty for whole-world
generation. `PMTILES_MIN_FREE_GB` is a safety reserve, not an estimate of total
required storage. `PMTILES_MAX_SCRATCH_GB` is an optional per-theme ceiling;
`PMTILES_MAX_LOCAL_GB` counts the combined scratch/output footprint, including
older retained files. Both are sampled twice per second and can briefly
overshoot before shutdown. Leave headroom beyond the configured ceiling.
S3 input is range-read directly, so
scratch needs to fit Planetiler temporary files and the final archive, not a
second copy of the source GeoParquet.

`PLANETILER_COMPRESS_TEMP=true` and `PLANETILER_MMAP_TEMP=false` are the
recommended S3 settings. Compression trades CPU time for substantially less
feature-store space. `PRESERVE_PARQUET=false` is required when the goal is no
local GeoParquet payload; setting it to `true` exports selected records directly
into bounded partitions in the durable output area after generation. See the
[storage model and estimator](../README.md#processing-storage-and-capacity-planning)
before selecting limits.

Protect credentials in the operator environment and shell history. Use a
site-approved protected environment file when appropriate.

## 5. Verify Exact Source Keys

Define a helper that passes credentials only to short-lived generator
containers:

```bash
podman_s3() {
  podman run --rm \
    -e AWS_ACCESS_KEY_ID \
    -e AWS_SECRET_ACCESS_KEY \
    -e AWS_REGION="$S3_REGION" \
    -e S3_REGION \
    -e S3_ENDPOINT_URL \
    "$@"
}
```

Check every configured theme:

```bash
IFS=, read -ra configured_themes <<< "$THEMES"
for theme in "${configured_themes[@]}"; do
  podman_s3 \
    --entrypoint s5cmd \
    localhost/overture-tiles-airgap:local \
    ls "${SOURCE_PATH%/}/theme=$theme/type=*/*.parquet"
done
```

Do not continue until each configured prefix contains the expected data.

## 6. Generate and Publish in One Stage

For S3 input:

```bash
mkdir -p "$PMTILES_SCRATCH_DIR" "$PWD/airgap-output"

podman_s3 \
  -e RELEASE \
  -e THEMES \
  -e BBOX \
  -e SOURCE_PATH \
  -e PMTILES_S3_PATH \
  -e PMTILES_MIN_FREE_GB \
  -e PMTILES_MAX_SCRATCH_GB \
  -e PMTILES_MAX_LOCAL_GB \
  -e PLANETILER_SORT_MAX_READERS \
  -e PLANETILER_SORT_MAX_WRITERS \
  -e PRESERVE_PARQUET \
  -e PLANETILER_COMPRESS_TEMP \
  -e PLANETILER_MMAP_TEMP \
  -e PMTILES_SCRATCH_ROOT=/scratch \
  -e OUTPUT=/output \
  --mount "type=bind,source=$PMTILES_SCRATCH_DIR,target=/scratch" \
  --mount "type=bind,source=$PWD/airgap-output,target=/output" \
  localhost/overture-tiles-airgap:local
```

For a mounted release, also mount it read-only and set
`SOURCE_PATH=/input/release`:

```bash
podman_s3 \
  -e RELEASE \
  -e THEMES \
  -e BBOX \
  -e SOURCE_PATH=/input/release \
  -e PMTILES_S3_PATH \
  -e PMTILES_MIN_FREE_GB \
  -e PMTILES_MAX_SCRATCH_GB \
  -e PMTILES_MAX_LOCAL_GB \
  -e PRESERVE_PARQUET \
  -e PMTILES_SCRATCH_ROOT=/scratch \
  -e OUTPUT=/output \
  --mount "type=bind,source=$OVERTURE_RELEASE_DIR,target=/input/release,ro=true" \
  --mount "type=bind,source=$PMTILES_SCRATCH_DIR,target=/scratch" \
  --mount "type=bind,source=$PWD/airgap-output,target=/output" \
  localhost/overture-tiles-airgap:local
```

The job processes themes sequentially. It monitors free space and combined local
usage twice per second while child processes run, reports the observed peak,
verifies each uploaded object's SHA-256 and byte size, and deletes the local archive before
starting the next theme. The ceiling is fail-safe: it stops the run and does not
automatically spill Planetiler's mutable temp files into S3.

On generation or capacity failure, incomplete current-theme scratch is removed.
On upload or verification failure, the completed archive is retained at:

```text
<scratch>/<release>/<unique-run-id>/<theme>/<theme>.pmtiles
```

The success marker is `airgap-output/publication/<release>.json`. Previous
publication state is preserved until a complete new run succeeds. Use a fresh
S3 destination prefix for each generation; existing PMTiles are never overwritten.

The Compose wrapper provides the same workflow:

```bash
THEMES="$THEMES" \
PMTILES_S3_PATH="$PMTILES_S3_PATH" \
PMTILES_SCRATCH_DIR="$PMTILES_SCRATCH_DIR" \
PMTILES_MIN_FREE_GB="$PMTILES_MIN_FREE_GB" \
PMTILES_MAX_SCRATCH_GB="$PMTILES_MAX_SCRATCH_GB" \
PLANETILER_COMPRESS_TEMP="$PLANETILER_COMPRESS_TEMP" \
PLANETILER_MMAP_TEMP="$PLANETILER_MMAP_TEMP" \
S3_REGION="$S3_REGION" \
S3_ENDPOINT_URL="$S3_ENDPOINT_URL" \
AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
podman-compose -f compose.airgap.yml --profile generate run --rm -T tiles-generator
```

## 7. Generate the Catalog

The catalog reads the publication manifest rather than scanning local PMTiles:

```bash
node ./scripts/generate-airgap-catalog.mjs \
  --release "$RELEASE" \
  --publication-manifest "$PWD/airgap-output/publication/$RELEASE.json" \
  --data-dir "$PWD/airgap-output/data/release/$RELEASE" \
  --out-dir "$PWD/airgap-output/catalog" \
  --tile-base "$PMTILES_HTTP_BASE"
```

Add `--bbox "$BBOX"` for a bounded run. The command rejects a BBOX that does
not match the publication manifest.

Confirm these files exist:

```text
airgap-output/catalog/catalog.json
airgap-output/catalog/<release>/catalog.json
airgap-output/catalog/<release>/manifest.geojson
airgap-output/catalog/<release>/<theme>/catalog.json
```

Each theme catalog must link to
`<PMTILES_HTTP_BASE>/<theme>.pmtiles`.

## 8. Configure and Run the Viewer

Use a runtime config such as:

```json
{
  "stacCatalogUrl": "/catalog/catalog.json",
  "downloadBaseUrl": "/data/release/2026-04-15.0/",
  "releaseId": "2026-04-15.0",
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
```

Run the viewer without a local PMTiles mount:

```bash
podman run -d \
  --name overture-viewer \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  -p 8088:8080 \
  --mount "type=bind,source=$PWD/airgap-output/catalog,target=/usr/share/nginx/html/catalog,ro=true" \
  --mount "type=bind,source=$PWD/airgap-output/data,target=/usr/share/nginx/html/data,ro=true" \
  --mount "type=bind,source=$PWD/public/config/viewer-config.json,target=/usr/share/nginx/html/config/viewer-config.json,ro=true" \
  --tmpfs /tmp \
  --tmpfs /var/cache/nginx \
  --tmpfs /var/run \
  localhost/overture-explorer-airgap:local
```

## 9. Validate and Test

```bash
curl -fsS http://127.0.0.1:8088/config/viewer-config.json >/dev/null
curl -fsS http://127.0.0.1:8088/catalog/catalog.json >/dev/null
curl -fsS http://127.0.0.1:8088/catalog/$RELEASE/manifest.geojson >/dev/null
curl -fsS --range 0-1023 "${PMTILES_HTTP_BASE%/}/places.pmtiles" >/dev/null
```

The PMTiles response must be `206`, all configured themes must appear in the
catalog, and no local PMTiles files should remain after a successful run.

The repository's isolated MinIO validation exercises exact source keys, capacity
rejection, streamed checksums, deliberate write-denied retention across two
runs, schema-preserving downloads, publication-manifest catalogs, HTTP 206/CORS,
and viewer startup. Supply a bounded places fixture intersecting
`34.75,32.03,34.85,32.13`; each test creates its own store and retains evidence:

```bash
SEED_PARQUET=/path/to/place.parquet ./scripts/test-local-s3-generator.sh
SEED_PARQUET=/path/to/place.parquet ./scripts/validate-airgap-s3-runbook.sh
```

## 10. Troubleshooting and Operations

- If capacity validation fails, provision more local scratch space or reduce the
  BBOX. Do not lower the reserve merely to bypass the guard.
- If an upload fails, retain the reported completed archive while correcting
  endpoint, region, certificate, or policy settings.
- If catalog generation fails, confirm the publication manifest exists and
  matches the requested release and BBOX.
- If the viewer is blank, fetch a catalog and its PMTiles URL directly and
  verify CORS plus byte-range behavior.
- Keep generator credentials out of the viewer and catalog processes.
- Use a distinct generated prefix per release or independently managed run.
- Record image digests, release, BBOX, ordered themes, capacity floor, remote
  object sizes, and HTTP `206` evidence.
