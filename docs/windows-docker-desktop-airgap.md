# Windows Docker Desktop Air-Gap Runbook

This runbook generates Overture PMTiles with imported production images on
Docker Desktop for Windows. GeoParquet is read from an internal S3-compatible
service and each completed PMTiles archive is published back to the same bucket.
No public registry or public network is required at runtime.

Run every command from PowerShell in the repository root.

## 1. Architecture

```text
internal S3 GeoParquet
  -> one-shot multi-theme tile-generator
  -> one configured local scratch folder
  -> upload and byte-size verification after each theme
  -> same S3 bucket under pmtiles/release/<release>/
  -> immediate deletion of the verified local PMTiles file
  -> publication manifest after every configured theme succeeds
  -> local catalog/config volumes
  -> read-only viewer plus browser-accessible S3 HTTP gateway
```

Only `tiles-generator` receives S3 credentials. Catalog and viewer containers
do not. The viewer reads PMTiles through an internal HTTP gateway because a
browser cannot read `s3://` URLs directly.

## 2. Prerequisites

Use Docker Desktop in Linux-container mode with current Docker Compose v2. The
air-gapped Artifactory must contain:

1. The viewer image built from `Dockerfile.viewer`.
2. The tile-generator image built from `airgap/tile-generator/Dockerfile`.
3. A mirrored Node 20 image for the catalog job.

Use immutable tags or digest-pinned references and keep TLS verification
enabled. Select a local scratch folder on a filesystem large enough for one
theme's input, Planetiler temporary data, and PMTiles output. A whole-world run
can require substantially more scratch than its final archives; the configured
free-space floor protects the workstation but is not a size estimate.

## 3. Configure `.env.windows-airgap`

Create the Git-ignored file in the repository root:

```dotenv
VIEWER_IMAGE=artifactory.airgap.example/overture/overture-explorer-airgap:1.0.0
TILES_IMAGE=artifactory.airgap.example/overture/overture-tiles-airgap:1.0.0
CATALOG_IMAGE=artifactory.airgap.example/dockerhub/library/node:20-alpine

OVERTURE_RELEASE=2026-04-15.0
THEMES=base,buildings,places,divisions,transportation,addresses
BBOX=
PRESERVE_PARQUET=true

S3_BUCKET=overture-source
SOURCE_RELEASE_PREFIX=release
PMTILES_RELEASE_PREFIX=pmtiles/release
S3_ENDPOINT_URL=https://s3.airgap.example
S3_REGION=us-east-1
AWS_ACCESS_KEY_ID=replace-with-s3-access-key
AWS_SECRET_ACCESS_KEY='replace-with-s3-secret-key'

PMTILES_SCRATCH_DIR=D:/overture-scratch
PMTILES_MIN_FREE_GB=100
PMTILES_HTTP_BASE=https://s3-gateway.airgap.example/overture-source/pmtiles/release/2026-04-15.0/

DOWNLOAD_MIN_ZOOM=15
VIEWER_PORT=8088
OUTPUT_VOLUME_PREFIX=overture-2026-04-15-0
```

`THEMES` is an ordered comma-separated subset of `base`, `buildings`, `places`,
`divisions`, `transportation`, and `addresses`. If omitted, all six run. The old
singular `THEME` setting is not accepted.

`BBOX` is `min_lon,min_lat,max_lon,max_lat`; leave it empty for whole-world
generation. `PMTILES_MIN_FREE_GB` is the safety reserve that must remain on the
scratch filesystem. The generator checks it before every theme and every five
seconds while Planetiler runs.

The source and generated layouts are:

```text
s3://<bucket>/<source-prefix>/<release>/theme=<theme>/type=<type>/<file>.parquet
s3://<bucket>/<pmtiles-prefix>/<release>/<theme>.pmtiles
```

`PMTILES_HTTP_BASE` must expose the generated release prefix with browser `GET`
and `HEAD`, CORS for the viewer origin, and byte ranges returning HTTP `206`.
Avoid expiring presigned URLs in the static catalog.

## 4. Protect Credentials and Grant S3 Access

Confirm the environment file remains ignored:

```powershell
git check-ignore .env.windows-airgap
git status --short
```

Restrict its Windows ACL. The S3 identity needs `ListBucket` and `GetObject` on
the source prefix, plus `ListBucket`, `GetObject`, and `PutObject` on only the
generated PMTiles release prefix. It does not need permission to modify source
GeoParquet.

## 5. Verify Images and Source Objects

```powershell
docker login artifactory.airgap.example
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml --profile generate config --images
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml --profile generate pull
```

Record immutable image digests with `docker image inspect`. Avoid unrestricted
`docker compose config` output because rendered configuration can contain
credentials.

Verify every configured source theme before the expensive run:

```powershell
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml --profile generate run --rm --entrypoint /bin/bash tiles-generator -euc 'IFS=, read -ra themes <<< "$THEMES"; for theme in "${themes[@]}"; do echo "Checking $theme"; s5cmd ls "${SOURCE_PATH%/}/theme=$theme/type=*/*.parquet" | head -n 1; done'
```

Do not continue unless every configured theme returns at least one object.

## 6. Generate and Publish in One Stage

```powershell
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml --profile generate run --rm tiles-generator
```

The job processes themes sequentially. For each theme it checks capacity,
generates one archive in `PMTILES_SCRATCH_DIR`, uploads the exact final key,
compares the remote and local byte sizes, and deletes the local archive. It does
not begin the next theme until verification succeeds.

If generation fails or the capacity floor is crossed, incomplete current-theme
scratch is removed and the job stops. If upload or verification fails, the
completed PMTiles file is retained under:

```text
<PMTILES_SCRATCH_DIR>/<release>/<theme>/<theme>.pmtiles
```

After every configured theme succeeds, the job writes a small publication
manifest to the persistent publication volume. Catalog generation refuses to
run without a valid release-matched manifest, so a partial run is not presented
as complete.

## 7. Generate the Catalog and Start the Viewer

Run this only after the generator exits successfully:

```powershell
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml run --rm catalog
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml up -d viewer
```

Open `http://localhost:8088`, or the configured `VIEWER_PORT`. The viewer mounts
only preserved GeoParquet, catalogs, and runtime configuration. PMTiles never
return to a Docker-local volume.

To republish a changed release or theme selection, rerun the single generator
job, then recreate the catalog and viewer:

```powershell
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml --profile generate run --rm tiles-generator
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml run --rm catalog
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml up -d --force-recreate viewer
```

## 8. Validate the Deployment

```powershell
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml ps -a
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml logs catalog viewer

curl.exe -fsS http://localhost:8088/config/viewer-config.json
curl.exe -fsS http://localhost:8088/catalog/catalog.json
curl.exe -fsS http://localhost:8088/catalog/2026-04-15.0/manifest.geojson
curl.exe -fsS -D - --range 0-1023 -o NUL https://s3-gateway.airgap.example/overture-source/pmtiles/release/2026-04-15.0/places.pmtiles
```

The range request must return `206 Partial Content`. Confirm all configured
themes appear in the catalog and the browser makes no public-network requests.

## 9. Lifecycle and Troubleshooting

Stop or restart the viewer without deleting persistent metadata:

```powershell
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml down
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml up -d viewer
```

Do not use `down --volumes` unless deletion of preserved GeoParquet, publication
state, catalogs, and runtime configuration is intended. Published PMTiles remain
in S3 and are not controlled by Compose volume deletion.

If generation refuses to start, inspect free space on `PMTILES_SCRATCH_DIR` and
set a deliberate reserve; do not lower it merely to bypass the safety gate. If
an upload fails, fix endpoint, region, certificate, or policy errors and retain
the reported archive until it can be published or deliberately regenerated.

If the viewer is blank, confirm the publication manifest and catalog job match
the release, fetch a theme's HTTP PMTiles URL directly, and verify CORS and byte
ranges. Catalog and viewer services must never receive S3 write credentials.

## 10. Security Checklist

- Use immutable verified image digests from internal Artifactory.
- Limit S3 writes to the generated release prefix.
- Protect `.env.windows-airgap` and keep secrets out of logs and tickets.
- Keep TLS verification enabled for Artifactory, S3, and the HTTP gateway.
- Verify no PMTiles named volume or viewer tile mount exists.
- Record release, BBOX, ordered themes, image digests, capacity floor, published
  object sizes, catalog timestamp, and HTTP `206` evidence.
