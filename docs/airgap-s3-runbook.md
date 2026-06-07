# Air-Gapped S3 Runbook

This manual describes how to set up the Overture tile generator, create PMTiles
and preserved GeoParquet for a selected area or the whole world, publish the
result to S3-compatible storage, and run the static viewer in a fully
air-gapped network.

The workflow assumes:

- Overture GeoParquet is already available in an internal S3-compatible object
  store.
- Generated PMTiles, preserved filtered GeoParquet, and STAC catalog files are
  stored in internal S3-compatible storage.
- The viewer is static and only reads HTTP-accessible files. It does not read
  `s3://` URIs directly.
- Any required container images, Node dependencies, source code, and Overture
  data have already been transferred into the air-gapped network.

## 1. Architecture

Use these components:

1. S3-compatible object storage, for example MinIO, Ceph RGW, Dell ECS, or an
   internal appliance.
2. Tile generator container: `overture-tiles-airgap`.
3. Static viewer container: `overture-explorer-airgap`.
4. Optional internal HTTP gateway or reverse proxy in front of S3.

The normal data flow is:

```text
S3 GeoParquet source
  -> tile generator
  -> local generator output
  -> S3 generated output bucket
  -> viewer host sync or S3 HTTP gateway
  -> browser
```

The viewer needs these URLs to work:

```text
/catalog/catalog.json
/tiles/<release>/<theme>.pmtiles
/data/release/<release>/theme=<theme>/type=<type>/<file>.parquet
/config/viewer-config.json
```

You can provide those paths in either of two ways:

- Recommended for simple air-gapped deployments: sync the generated S3 objects
  to local read-only directories on the viewer host and mount them into the
  viewer container.
- Alternative: expose S3 objects through an internal HTTP gateway that supports
  byte-range requests and CORS, then configure the viewer and catalog with
  absolute internal HTTP URLs.

## 2. Required Object Layout

The source GeoParquet bucket must preserve the Overture release layout:

```text
s3://<source-bucket>/<source-prefix>/<release>/theme=<theme>/type=<type>/<file>.parquet
```

Example:

```text
s3://overture-source/release/2026-04-15.0/theme=places/type=place/part-00000.parquet
```

The generator `SOURCE_PATH` points at the release root, not at a theme:

```text
SOURCE_PATH=s3://overture-source/release/2026-04-15.0
```

The generated output should use this layout:

```text
s3://<output-bucket>/tiles/<release>/<theme>.pmtiles
s3://<output-bucket>/data/release/<release>/theme=<theme>/type=<type>/filtered.parquet
s3://<output-bucket>/catalog/catalog.json
s3://<output-bucket>/catalog/<release>/catalog.json
s3://<output-bucket>/catalog/<release>/<theme>/catalog.json
s3://<output-bucket>/catalog/<release>/manifest.geojson
```

## 3. Preload Images For Air Gap

Build or pull these images in a connected environment:

```powershell
docker build -f Dockerfile.viewer -t overture-explorer-airgap:local .
docker build -t overture-tiles-airgap:local .\airgap\tile-generator
```

Export them:

```powershell
docker save overture-explorer-airgap:local -o overture-explorer-airgap.local.tar
docker save overture-tiles-airgap:local -o overture-tiles-airgap.local.tar
```

Transfer the tar files into the air-gapped network, then import them:

```powershell
docker load -i .\overture-explorer-airgap.local.tar
docker load -i .\overture-tiles-airgap.local.tar
```

Confirm both images are present:

```powershell
docker images overture-explorer-airgap
docker images overture-tiles-airgap
```

## 4. Define Environment Values

Choose release, storage, and area values before generating tiles.

Example PowerShell variables:

```powershell
$env:RELEASE = "2026-04-15.0"
$env:S3_ENDPOINT_URL = "http://minio.internal:9000"
$env:AWS_ACCESS_KEY_ID = "overture-generator"
$env:AWS_SECRET_ACCESS_KEY = "replace-with-internal-secret"
$env:AWS_REGION = "us-east-1"

$env:SOURCE_PATH = "s3://overture-source/release/$env:RELEASE"
$env:OUTPUT_BUCKET = "s3://overture-generated"
$env:LOCAL_OUTPUT = "$PWD\airgap-output"
```

For a bounded area, define a BBOX in:

```text
min_lon,min_lat,max_lon,max_lat
```

Example Israel smoke area:

```powershell
$env:BBOX = "34.17,29.45,35.91,33.38"
```

For whole-world generation, do not set `BBOX`.

## 5. Verify S3 Access By Key

Before running the generator, verify that the container can access the exact
GeoParquet keys.

Run a key listing from the tile generator image:

```powershell
docker run --rm `
  -e AWS_ACCESS_KEY_ID=$env:AWS_ACCESS_KEY_ID `
  -e AWS_SECRET_ACCESS_KEY=$env:AWS_SECRET_ACCESS_KEY `
  -e AWS_REGION=$env:AWS_REGION `
  -e S3_ENDPOINT_URL=$env:S3_ENDPOINT_URL `
  --entrypoint s5cmd `
  overture-tiles-airgap:local `
  ls "$env:SOURCE_PATH/theme=places/type=place/*.parquet"
```

Run a metadata check on one exact object key:

```powershell
docker run --rm `
  -e AWS_ACCESS_KEY_ID=$env:AWS_ACCESS_KEY_ID `
  -e AWS_SECRET_ACCESS_KEY=$env:AWS_SECRET_ACCESS_KEY `
  -e AWS_REGION=$env:AWS_REGION `
  -e S3_ENDPOINT_URL=$env:S3_ENDPOINT_URL `
  --entrypoint s5cmd `
  overture-tiles-airgap:local `
  head "s3://overture-source/release/$env:RELEASE/theme=places/type=place/part-00000.parquet"
```

Do not continue until object access works by exact key.

## 6. Generate Tiles For A Desired Area

Generate one theme at a time. This keeps memory, disk, and failure recovery
manageable.

Supported themes:

```text
addresses
base
buildings
divisions
places
transportation
```

Create a local output directory:

```powershell
New-Item -ItemType Directory -Force -Path $env:LOCAL_OUTPUT | Out-Null
```

Run one bounded-area theme:

```powershell
docker run --rm `
  -e RELEASE=$env:RELEASE `
  -e THEME=places `
  -e BBOX=$env:BBOX `
  -e SOURCE_PATH=$env:SOURCE_PATH `
  -e OUTPUT=/output `
  -e PRESERVE_PARQUET=true `
  -e S3_REGION=$env:AWS_REGION `
  -e AWS_REGION=$env:AWS_REGION `
  -e AWS_ACCESS_KEY_ID=$env:AWS_ACCESS_KEY_ID `
  -e AWS_SECRET_ACCESS_KEY=$env:AWS_SECRET_ACCESS_KEY `
  -e S3_ENDPOINT_URL=$env:S3_ENDPOINT_URL `
  -v "${env:LOCAL_OUTPUT}:/output" `
  overture-tiles-airgap:local
```

Repeat for the remaining themes by changing `THEME`.

Expected local output after one theme:

```text
airgap-output/
  tiles/<release>/places.pmtiles
  data/release/<release>/theme=places/type=place/filtered.parquet
```

Check that output files are non-empty:

```powershell
Get-Item "$env:LOCAL_OUTPUT\tiles\$env:RELEASE\places.pmtiles"
Get-ChildItem -Recurse "$env:LOCAL_OUTPUT\data\release\$env:RELEASE\theme=places" -Filter *.parquet
```

## 7. Generate Whole-World Tiles

Whole-world generation uses the same command without `BBOX`.

Important operating rules:

- Run one theme at a time.
- Use large persistent local scratch and output storage.
- Keep `PRESERVE_PARQUET=true` only if the viewer must support browser-side
  downloads from local filtered parquet. For whole-world data this can require
  very large storage.
- Expect long runtimes for large themes such as `base`, `buildings`, and
  `transportation`.
- Do not run whole-world generation inside the viewer container.

Example whole-world run for `places`:

```powershell
docker run --rm `
  -e RELEASE=$env:RELEASE `
  -e THEME=places `
  -e SOURCE_PATH=$env:SOURCE_PATH `
  -e OUTPUT=/output `
  -e PRESERVE_PARQUET=true `
  -e S3_REGION=$env:AWS_REGION `
  -e AWS_REGION=$env:AWS_REGION `
  -e AWS_ACCESS_KEY_ID=$env:AWS_ACCESS_KEY_ID `
  -e AWS_SECRET_ACCESS_KEY=$env:AWS_SECRET_ACCESS_KEY `
  -e S3_ENDPOINT_URL=$env:S3_ENDPOINT_URL `
  -v "${env:LOCAL_OUTPUT}:/output" `
  overture-tiles-airgap:local
```

Repeat for each required theme.

## 8. Generate The Local Catalog

After all selected themes have been generated, create the catalog consumed by
the viewer.

For a bounded area:

```powershell
node .\scripts\generate-airgap-catalog.mjs `
  --release $env:RELEASE `
  --tiles-dir "$env:LOCAL_OUTPUT\tiles\$env:RELEASE" `
  --data-dir "$env:LOCAL_OUTPUT\data\release\$env:RELEASE" `
  --out-dir "$env:LOCAL_OUTPUT\catalog" `
  --bbox $env:BBOX `
  --tile-base "/tiles/$env:RELEASE/"
```

For whole world, omit `--bbox`:

```powershell
node .\scripts\generate-airgap-catalog.mjs `
  --release $env:RELEASE `
  --tiles-dir "$env:LOCAL_OUTPUT\tiles\$env:RELEASE" `
  --data-dir "$env:LOCAL_OUTPUT\data\release\$env:RELEASE" `
  --out-dir "$env:LOCAL_OUTPUT\catalog" `
  --tile-base "/tiles/$env:RELEASE/"
```

If you will serve PMTiles through an internal S3 HTTP gateway instead of local
viewer mounts, set `--tile-base` to the internal HTTP base URL:

```powershell
--tile-base "https://s3-gateway.internal/overture-generated/tiles/$env:RELEASE/"
```

Expected catalog output:

```text
airgap-output/catalog/catalog.json
airgap-output/catalog/<release>/catalog.json
airgap-output/catalog/<release>/manifest.geojson
airgap-output/catalog/<release>/<theme>/catalog.json
```

## 9. Upload Generated Output To S3

Sync the generated output to the internal output bucket.

```powershell
docker run --rm `
  -e AWS_ACCESS_KEY_ID=$env:AWS_ACCESS_KEY_ID `
  -e AWS_SECRET_ACCESS_KEY=$env:AWS_SECRET_ACCESS_KEY `
  -e AWS_REGION=$env:AWS_REGION `
  -e S3_ENDPOINT_URL=$env:S3_ENDPOINT_URL `
  -v "${env:LOCAL_OUTPUT}:/output:ro" `
  --entrypoint s5cmd `
  overture-tiles-airgap:local `
  sync "/output/tiles/*" "$env:OUTPUT_BUCKET/tiles/"
```

```powershell
docker run --rm `
  -e AWS_ACCESS_KEY_ID=$env:AWS_ACCESS_KEY_ID `
  -e AWS_SECRET_ACCESS_KEY=$env:AWS_SECRET_ACCESS_KEY `
  -e AWS_REGION=$env:AWS_REGION `
  -e S3_ENDPOINT_URL=$env:S3_ENDPOINT_URL `
  -v "${env:LOCAL_OUTPUT}:/output:ro" `
  --entrypoint s5cmd `
  overture-tiles-airgap:local `
  sync "/output/data/*" "$env:OUTPUT_BUCKET/data/"
```

```powershell
docker run --rm `
  -e AWS_ACCESS_KEY_ID=$env:AWS_ACCESS_KEY_ID `
  -e AWS_SECRET_ACCESS_KEY=$env:AWS_SECRET_ACCESS_KEY `
  -e AWS_REGION=$env:AWS_REGION `
  -e S3_ENDPOINT_URL=$env:S3_ENDPOINT_URL `
  -v "${env:LOCAL_OUTPUT}:/output:ro" `
  --entrypoint s5cmd `
  overture-tiles-airgap:local `
  sync "/output/catalog/*" "$env:OUTPUT_BUCKET/catalog/"
```

Verify uploaded output:

```powershell
docker run --rm `
  -e AWS_ACCESS_KEY_ID=$env:AWS_ACCESS_KEY_ID `
  -e AWS_SECRET_ACCESS_KEY=$env:AWS_SECRET_ACCESS_KEY `
  -e AWS_REGION=$env:AWS_REGION `
  -e S3_ENDPOINT_URL=$env:S3_ENDPOINT_URL `
  --entrypoint s5cmd `
  overture-tiles-airgap:local `
  ls "$env:OUTPUT_BUCKET/tiles/$env:RELEASE/*.pmtiles"
```

## 10. Configure Viewer Files

Create or edit `public/config/viewer-config.json` before building the viewer,
or mount a runtime replacement at:

```text
/usr/share/nginx/html/config/viewer-config.json
```

For local mounted files:

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

For an internal HTTP gateway in front of S3:

```json
{
  "stacCatalogUrl": "https://s3-gateway.internal/overture-generated/catalog/catalog.json",
  "downloadBaseUrl": "https://s3-gateway.internal/overture-generated/data/release/2026-04-15.0/",
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

Requirements for an S3 HTTP gateway:

- It must support HTTP `Range` requests for `.pmtiles`.
- It must serve `.pmtiles`, `.parquet`, `.json`, and `.geojson` files.
- It must allow browser access from the viewer origin with CORS headers.
- It must not require internet access.

## 11. Run Viewer With Synced Local Data

This is the simplest production shape for a fully air-gapped network.

First, sync generated objects from S3 to the viewer host:

```powershell
$viewerRoot = "$PWD\viewer-data"
New-Item -ItemType Directory -Force -Path $viewerRoot | Out-Null
```

```powershell
docker run --rm `
  -e AWS_ACCESS_KEY_ID=$env:AWS_ACCESS_KEY_ID `
  -e AWS_SECRET_ACCESS_KEY=$env:AWS_SECRET_ACCESS_KEY `
  -e AWS_REGION=$env:AWS_REGION `
  -e S3_ENDPOINT_URL=$env:S3_ENDPOINT_URL `
  -v "${viewerRoot}:/viewer-data" `
  --entrypoint s5cmd `
  overture-tiles-airgap:local `
  sync "$env:OUTPUT_BUCKET/catalog/*" "/viewer-data/catalog/"
```

```powershell
docker run --rm `
  -e AWS_ACCESS_KEY_ID=$env:AWS_ACCESS_KEY_ID `
  -e AWS_SECRET_ACCESS_KEY=$env:AWS_SECRET_ACCESS_KEY `
  -e AWS_REGION=$env:AWS_REGION `
  -e S3_ENDPOINT_URL=$env:S3_ENDPOINT_URL `
  -v "${viewerRoot}:/viewer-data" `
  --entrypoint s5cmd `
  overture-tiles-airgap:local `
  sync "$env:OUTPUT_BUCKET/tiles/*" "/viewer-data/tiles/"
```

```powershell
docker run --rm `
  -e AWS_ACCESS_KEY_ID=$env:AWS_ACCESS_KEY_ID `
  -e AWS_SECRET_ACCESS_KEY=$env:AWS_SECRET_ACCESS_KEY `
  -e AWS_REGION=$env:AWS_REGION `
  -e S3_ENDPOINT_URL=$env:S3_ENDPOINT_URL `
  -v "${viewerRoot}:/viewer-data" `
  --entrypoint s5cmd `
  overture-tiles-airgap:local `
  sync "$env:OUTPUT_BUCKET/data/*" "/viewer-data/data/"
```

Run the viewer:

```powershell
docker run -d `
  --name overture-viewer `
  --read-only `
  --cap-drop ALL `
  --security-opt no-new-privileges:true `
  -p 8088:8080 `
  -v "${viewerRoot}\catalog:/usr/share/nginx/html/catalog:ro" `
  -v "${viewerRoot}\tiles:/usr/share/nginx/html/tiles:ro" `
  -v "${viewerRoot}\data:/usr/share/nginx/html/data:ro" `
  -v "$PWD\public\config\viewer-config.json:/usr/share/nginx/html/config/viewer-config.json:ro" `
  --tmpfs /tmp `
  --tmpfs /var/cache/nginx `
  --tmpfs /var/run `
  overture-explorer-airgap:local
```

Open the viewer from inside the air-gapped network:

```text
http://<viewer-host>:8088
```

## 12. Run Viewer With An S3 HTTP Gateway

Use this mode only if the S3-compatible storage is exposed through an internal
HTTP endpoint that supports browser-safe access.

Generate the catalog with an absolute `--tile-base`:

```powershell
node .\scripts\generate-airgap-catalog.mjs `
  --release $env:RELEASE `
  --tiles-dir "$env:LOCAL_OUTPUT\tiles\$env:RELEASE" `
  --data-dir "$env:LOCAL_OUTPUT\data\release\$env:RELEASE" `
  --out-dir "$env:LOCAL_OUTPUT\catalog" `
  --bbox $env:BBOX `
  --tile-base "https://s3-gateway.internal/overture-generated/tiles/$env:RELEASE/"
```

Set `viewer-config.json` with absolute HTTP URLs:

```json
{
  "stacCatalogUrl": "https://s3-gateway.internal/overture-generated/catalog/catalog.json",
  "downloadBaseUrl": "https://s3-gateway.internal/overture-generated/data/release/2026-04-15.0/",
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

Run the viewer without mounting catalog, tiles, or data:

```powershell
docker run -d `
  --name overture-viewer `
  --read-only `
  --cap-drop ALL `
  --security-opt no-new-privileges:true `
  -p 8088:8080 `
  -v "$PWD\public\config\viewer-config.json:/usr/share/nginx/html/config/viewer-config.json:ro" `
  --tmpfs /tmp `
  --tmpfs /var/cache/nginx `
  --tmpfs /var/run `
  overture-explorer-airgap:local
```

## 13. Validate The Deployment

From a machine inside the air-gapped network, verify the viewer endpoints:

```powershell
Invoke-WebRequest http://<viewer-host>:8088/config/viewer-config.json
Invoke-WebRequest http://<viewer-host>:8088/catalog/catalog.json
Invoke-WebRequest http://<viewer-host>:8088/catalog/$env:RELEASE/manifest.geojson
```

Verify PMTiles byte-range support:

```powershell
Invoke-WebRequest `
  -Uri "http://<viewer-host>:8088/tiles/$env:RELEASE/places.pmtiles" `
  -Headers @{ Range = "bytes=0-1023" }
```

Expected result:

- HTTP status is `206 Partial Content` for byte-range requests, or the client
  otherwise receives a valid ranged response.
- The browser loads the map.
- The layer tree shows generated themes.
- Panning and zooming request `.pmtiles` files.
- Download visible layers requests `.parquet` files under
  `/data/release/<release>/`.

This repository also includes an automated validation harness for the manual.
It uses local MinIO as the S3-compatible source and output store, then runs the
same bounded-area `places` workflow described above:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\validate-airgap-s3-runbook.ps1
```

The script validates:

- exact GeoParquet key access in `s3://overture-source`
- tile generation from S3-compatible input
- catalog generation
- upload to `s3://overture-generated`
- sync from generated S3 output to viewer data directories
- viewer startup
- viewer config, catalog, manifest, PMTiles, and range-request HTTP probes

Use `-KeepServices` to leave MinIO and the validation viewer running:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\validate-airgap-s3-runbook.ps1 -KeepServices
```

## 14. Troubleshooting

If S3 reads fail:

- Confirm `S3_ENDPOINT_URL`, access key, secret key, and region are set.
- Confirm the object key layout starts at `theme=<theme>/type=<type>/`.
- Run `s5cmd head` on one exact parquet key.

If the generator finds no features:

- Check the BBOX order: `min_lon,min_lat,max_lon,max_lat`.
- Confirm the BBOX intersects the source data.
- Confirm the source parquet includes the `bbox` struct used by the filter.

If the viewer opens but the map is blank:

- Fetch `/catalog/catalog.json` in the browser.
- Fetch the release catalog and one theme catalog.
- Confirm each theme catalog has a `rel="pmtiles"` link.
- Confirm the linked `.pmtiles` URL is reachable from the browser.
- Confirm the HTTP server or gateway supports byte-range reads.

If downloads fail:

- Fetch `/catalog/<release>/manifest.geojson`.
- Confirm `downloadBaseUrl` ends with `/data/release/<release>/`.
- Confirm parquet files exist under the paths listed in `manifest.geojson`.

If air-gapped builds fail:

- Do not build images inside the air gap unless all package repositories and
  dependency artifacts are mirrored internally.
- Build images in a connected environment, export them with `docker save`, and
  import them with `docker load`.

## 15. Operational Notes

- Keep generator credentials out of the viewer container.
- The viewer only needs read access to static files.
- Use one release prefix per Overture release.
- Use one output bucket or prefix per generated deployment.
- Keep bounded-area and whole-world outputs separate.
- For whole-world runs, monitor local disk, object-store throughput, memory, and
  runtime per theme.
- Regenerate the catalog after adding or removing generated themes.
