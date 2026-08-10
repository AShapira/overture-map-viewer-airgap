# Air-Gapped S3 Runbook

This runbook creates PMTiles and preserved GeoParquet from an internal
S3-compatible Overture source, publishes the generated result, and runs the
static viewer in a disconnected network. All operator commands run in Bash on
RHEL 10 with rootless Podman.

The workflow assumes that container images, Node dependencies, source code, and
Overture data have already been transferred into the air-gapped network. The
viewer reads HTTP resources; it does not read `s3://` URLs directly.

## 1. Architecture

Use these components:

1. S3-compatible storage such as MinIO, Ceph RGW, Dell ECS, or an internal appliance.
2. `localhost/overture-tiles-airgap:local`, the batch generator image.
3. `localhost/overture-explorer-airgap:local`, the static viewer image.
4. Optionally, an internal HTTP gateway or reverse proxy in front of S3.

```text
S3 GeoParquet source
  -> tile generator
  -> local generator output
  -> S3 generated output bucket
  -> viewer host sync or internal HTTP gateway
  -> browser
```

The viewer needs these paths:

```text
/catalog/catalog.json
/tiles/<release>/<theme>.pmtiles
/data/release/<release>/theme=<theme>/type=<type>/<file>.parquet
/config/viewer-config.json
```

For the simplest deployment, synchronize generated objects onto the viewer host
and mount them read-only. An HTTP gateway is also valid when it supports byte
ranges and browser-safe CORS.

## 2. Required Object Layout

The source bucket must preserve the Overture release layout:

```text
s3://<source-bucket>/<source-prefix>/<release>/theme=<theme>/type=<type>/<file>.parquet
```

For example:

```text
s3://overture-source/release/2026-04-15.0/theme=places/type=place/part-00000.parquet
```

`SOURCE_PATH` points to the release root:

```text
SOURCE_PATH=s3://overture-source/release/2026-04-15.0
```

Generated output uses:

```text
s3://<output-bucket>/tiles/<release>/<theme>.pmtiles
s3://<output-bucket>/data/release/<release>/theme=<theme>/type=<type>/<file>.parquet
s3://<output-bucket>/catalog/catalog.json
s3://<output-bucket>/catalog/<release>/catalog.json
s3://<output-bucket>/catalog/<release>/<theme>/catalog.json
s3://<output-bucket>/catalog/<release>/manifest.geojson
```

With `PRESERVE_PARQUET=true`, unfiltered input object names are retained (for
example, `part-00000.parquet`). BBOX-filtered generation writes
`filtered.parquet` instead. The generated manifest records the actual relative
path in either case.

## 3. Validate Rootless Podman

Run as the normal RHEL user, without `sudo`:

```bash
podman --version
podman info --format 'rootless={{.Host.Security.Rootless}}'
podman-compose --version
```

The Podman information must report `rootless=true`. Ports used by this project
are above 1024 and require no privileged port configuration.

## 4. Preload Images for the Air Gap

Build the images in a connected RHEL environment:

```bash
./scripts/build-images.sh
```

The build script uses Podman for both builds and requests Docker-format image
metadata so the viewer health check is retained.

Export portable OCI archives:

```bash
podman save --format oci-archive \
  -o overture-explorer-airgap.local.oci \
  localhost/overture-explorer-airgap:local
podman save --format oci-archive \
  -o overture-tiles-airgap.local.oci \
  localhost/overture-tiles-airgap:local
```

Transfer the archives, verify their external checksums, and import them in the
air-gapped RHEL environment:

```bash
podman load -i overture-explorer-airgap.local.oci
podman load -i overture-tiles-airgap.local.oci
podman image exists localhost/overture-explorer-airgap:local
podman image exists localhost/overture-tiles-airgap:local
```

Do not build inside the air gap unless every base image, package repository,
Node dependency, and downloaded generator artifact is mirrored internally.

## 5. Define Environment Values

Set the deployment values in the current Bash session:

```bash
export RELEASE=2026-04-15.0
export S3_ENDPOINT_URL=http://minio.internal:9000
export AWS_ACCESS_KEY_ID=overture-generator
export AWS_SECRET_ACCESS_KEY=replace-with-internal-secret
export AWS_REGION=us-east-1
export S3_REGION="$AWS_REGION"
export SOURCE_PATH="s3://overture-source/release/$RELEASE"
export OUTPUT_BUCKET=s3://overture-generated
export LOCAL_OUTPUT="$PWD/airgap-output"
export BBOX=
export TILES_IMAGE=localhost/overture-tiles-airgap:local
export VIEWER_IMAGE=localhost/overture-explorer-airgap:local
mkdir -p "$LOCAL_OUTPUT"
```

The BBOX order is `min_lon,min_lat,max_lon,max_lat`. Leave it empty for a
whole-world run, or set it to a site-approved boundary for a bounded run. Keep
secrets out of shell history and persistent environment files according to the
deployment's credential policy.

The examples below use this helper to pass S3 credentials consistently:

```bash
podman_s3() {
  podman run --rm \
    -e AWS_ACCESS_KEY_ID \
    -e AWS_SECRET_ACCESS_KEY \
    -e AWS_REGION \
    -e S3_REGION \
    -e S3_ENDPOINT_URL \
    "$@"
}
```

## 6. Verify S3 Access by Exact Key

List the expected input prefix:

```bash
podman_s3 \
  --entrypoint s5cmd \
  "$TILES_IMAGE" \
  ls "$SOURCE_PATH/theme=places/type=place/*.parquet"
```

Check one exact object:

```bash
podman_s3 \
  --entrypoint s5cmd \
  "$TILES_IMAGE" \
  head "s3://overture-source/release/$RELEASE/theme=places/type=place/part-00000.parquet"
```

Do not continue until exact-key access succeeds.

## 7. Generate a Bounded Area

Supported themes are `addresses`, `base`, `buildings`, `divisions`, `places`,
and `transportation`. Generate one theme at a time:

```bash
podman_s3 \
  -e RELEASE \
  -e THEME=places \
  -e BBOX \
  -e SOURCE_PATH \
  -e OUTPUT=/output \
  -e PRESERVE_PARQUET=true \
  --mount "type=bind,source=$LOCAL_OUTPUT,target=/output" \
  "$TILES_IMAGE"
```

Repeat with another `THEME` value as needed. Confirm the result is non-empty:

```bash
test -s "$LOCAL_OUTPUT/tiles/$RELEASE/places.pmtiles"
find "$LOCAL_OUTPUT/data/release/$RELEASE/theme=places" \
  -type f -name '*.parquet' -size +0 -print
```

## 8. Generate Whole-World Tiles

Whole-world generation uses the same command without `BBOX`:

```bash
podman_s3 \
  -e RELEASE \
  -e THEME=places \
  -e SOURCE_PATH \
  -e OUTPUT=/output \
  -e PRESERVE_PARQUET=true \
  --mount "type=bind,source=$LOCAL_OUTPUT,target=/output" \
  "$TILES_IMAGE"
```

Run one theme at a time with persistent scratch and output storage. Large themes
such as `base`, `buildings`, and `transportation` can require substantial time,
memory, and disk. Disable parquet preservation only if browser downloads are not
required.

## 9. Generate the Local Catalog

For bounded output:

```bash
node ./scripts/generate-airgap-catalog.mjs \
  --release "$RELEASE" \
  --tiles-dir "$LOCAL_OUTPUT/tiles/$RELEASE" \
  --data-dir "$LOCAL_OUTPUT/data/release/$RELEASE" \
  --out-dir "$LOCAL_OUTPUT/catalog" \
  --bbox "$BBOX" \
  --tile-base "/tiles/$RELEASE/"
```

For whole-world output, omit `--bbox`. For an internal HTTP gateway, replace
`--tile-base` with its absolute browser-accessible URL:

```bash
--tile-base "https://s3-gateway.internal/overture-generated/tiles/$RELEASE/"
```

Confirm these files exist:

```text
airgap-output/catalog/catalog.json
airgap-output/catalog/<release>/catalog.json
airgap-output/catalog/<release>/manifest.geojson
airgap-output/catalog/<release>/<theme>/catalog.json
```

## 10. Upload Generated Output to S3

Synchronize each top-level prefix:

```bash
for prefix in tiles data catalog; do
  podman_s3 \
    --mount "type=bind,source=$LOCAL_OUTPUT,target=/output,ro=true" \
    --entrypoint s5cmd \
    "$TILES_IMAGE" \
    sync "/output/$prefix/*" "$OUTPUT_BUCKET/$prefix/"
done
```

Verify the uploaded PMTiles:

```bash
podman_s3 \
  --entrypoint s5cmd \
  "$TILES_IMAGE" \
  ls "$OUTPUT_BUCKET/tiles/$RELEASE/*.pmtiles"
```

## 11. Configure the Viewer

The normal local-files configuration is:

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

Edit `public/config/viewer-config.json` before building, or mount a replacement
at `/usr/share/nginx/html/config/viewer-config.json`.

For an internal gateway, use absolute internal HTTP URLs for
`stacCatalogUrl` and `downloadBaseUrl`. The gateway must serve PMTiles, parquet,
JSON, and GeoJSON; support byte ranges; allow the viewer origin through CORS;
and require no public-network access.

## 12. Run the Viewer with Synced Local Data

Synchronize output from S3 onto the viewer host:

```bash
export VIEWER_ROOT="$PWD/viewer-data"
mkdir -p "$VIEWER_ROOT"

for prefix in catalog tiles data; do
  podman_s3 \
    --mount "type=bind,source=$VIEWER_ROOT,target=/viewer-data" \
    --entrypoint s5cmd \
    "$TILES_IMAGE" \
    sync "$OUTPUT_BUCKET/$prefix/*" "/viewer-data/$prefix/"
done
```

Run the hardened viewer:

```bash
podman run -d \
  --name overture-viewer \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  -p 8088:8080 \
  --mount "type=bind,source=$VIEWER_ROOT/catalog,target=/usr/share/nginx/html/catalog,ro=true" \
  --mount "type=bind,source=$VIEWER_ROOT/tiles,target=/usr/share/nginx/html/tiles,ro=true" \
  --mount "type=bind,source=$VIEWER_ROOT/data,target=/usr/share/nginx/html/data,ro=true" \
  --mount "type=bind,source=$PWD/public/config/viewer-config.json,target=/usr/share/nginx/html/config/viewer-config.json,ro=true" \
  --tmpfs /tmp \
  --tmpfs /var/cache/nginx \
  --tmpfs /var/run \
  "$VIEWER_IMAGE"
```

Open `http://<viewer-host>:8088`. Stop the container with:

```bash
podman rm -f overture-viewer
```

## 13. Run the Viewer through an S3 HTTP Gateway

Generate the catalog with the gateway URL as `--tile-base`, update the runtime
config with absolute internal URLs, and run the viewer without catalog, tiles,
or data mounts:

```bash
podman run -d \
  --name overture-viewer \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  -p 8088:8080 \
  --mount "type=bind,source=$PWD/public/config/viewer-config.json,target=/usr/share/nginx/html/config/viewer-config.json,ro=true" \
  --tmpfs /tmp \
  --tmpfs /var/cache/nginx \
  --tmpfs /var/run \
  "$VIEWER_IMAGE"
```

## 14. Validate the Deployment

Probe the required resources from inside the disconnected network:

```bash
curl -fsS "http://<viewer-host>:8088/config/viewer-config.json" >/dev/null
curl -fsS "http://<viewer-host>:8088/catalog/catalog.json" >/dev/null
curl -fsS "http://<viewer-host>:8088/catalog/$RELEASE/manifest.geojson" >/dev/null
curl -fsS --range 0-1023 \
  "http://<viewer-host>:8088/tiles/$RELEASE/places.pmtiles" >/dev/null
```

The map must load without public requests, catalogs must enumerate generated
themes, PMTiles must support ranged reads, and visible-layer downloads must read
parquet below `/data/release/<release>/`.

The repository includes a local MinIO harness for the complete documented flow:

```bash
./scripts/validate-airgap-s3-runbook.sh
```

It validates exact source-key access, S3 input generation, catalog creation,
upload to `s3://overture-generated`, synchronization back to viewer directories,
viewer startup, required HTTP resources, and a PMTiles range request.

Use another unprivileged port or keep the services for inspection:

```bash
./scripts/validate-airgap-s3-runbook.sh --viewer-port 8099 --keep-services
```

## 15. Troubleshooting

If S3 access fails:

- Confirm the endpoint, credentials, region, and exact object-key layout.
- Confirm `SOURCE_PATH` ends at the release root.
- Run `s5cmd head` on a known parquet object.

If generation finds no features:

- Confirm BBOX order is `min_lon,min_lat,max_lon,max_lat`.
- Confirm the source intersects the area and includes the `bbox` struct.

If the viewer is blank:

- Fetch the root, release, and theme catalogs directly.
- Confirm each theme catalog contains a `rel="pmtiles"` link.
- Confirm the referenced PMTiles is browser-accessible and supports ranges.

If downloads fail:

- Fetch `/catalog/<release>/manifest.geojson`.
- Confirm `downloadBaseUrl` ends in `/data/release/<release>/`.
- Confirm every parquet path in the manifest exists.

If a bind mount is denied on native enforcing RHEL, move the data to a Linux
filesystem and apply a deliberate `:z` or `:Z` label. Do not add relabel flags
to the supported WSL `/mnt/d` mount, where SELinux is disabled.

## 16. Operational Notes

- Keep generator credentials out of the viewer container.
- Use one release prefix per Overture release and separate bounded/world outputs.
- Regenerate the catalog after changing generated themes.
- Monitor disk, object-store throughput, memory, and runtime per theme.
- Import only verified OCI archives into the disconnected environment.
