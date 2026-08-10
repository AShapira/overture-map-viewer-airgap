# Windows Docker Desktop Air-Gap Runbook

This runbook runs the production Overture tile generator and static viewer on
Docker Desktop for Windows. The Overture GeoParquet source is an internal
S3-compatible service, and all runtime images come from an Artifactory registry
inside the disconnected network. Nothing in this workflow builds an image or
requires a public registry.

The deployment uses [compose.windows-airgap.yml](../compose.windows-airgap.yml).
Run every command below from PowerShell in the repository root.

## 1. Architecture

```text
internal S3 GeoParquet
  -> one-shot tile-generator container
  -> Docker named volumes for PMTiles and preserved GeoParquet
  -> one-shot PMTiles publisher
  -> same S3 bucket under pmtiles/release/<release>/
  -> one-shot catalog container
  -> Docker named volumes for catalogs and viewer configuration
  -> read-only nginx viewer plus browser-accessible S3 HTTP gateway
  -> browser on the Windows host
```

Only `tiles-generator` and `publish-pmtiles` receive the S3 credentials. The
catalog and viewer containers have no S3 credentials. The browser reads PMTiles
through an internal HTTP endpoint because browsers cannot read `s3://` URLs
directly. The viewer continues to serve preserved GeoParquet downloads locally.

## 2. Prerequisites

Use Docker Desktop in Linux-container mode with a current Docker Compose v2.
Allocate enough Docker Desktop CPU, memory, and virtual-disk capacity for the
selected Overture themes. Whole-world `base`, `buildings`, and `transportation`
runs can be large; run one theme at a time and monitor free space.

The air-gapped Artifactory must contain these Linux images:

1. The production Overture viewer image built from `Dockerfile.viewer`.
2. The production tile-generator image built from
   `airgap/tile-generator/Dockerfile`.
3. A production Node 20 image used only for the one-shot catalog job. A mirrored
   `node:20-alpine` image is sufficient because the catalog script uses only
   Node built-ins.

Use immutable release tags or, preferably, digest-pinned Artifactory references.
The tile-generator and catalog images must match the CPU architecture selected
in Docker Desktop. The production images must already trust the internal
Artifactory and S3 certificate authorities; do not disable TLS verification.

Confirm Docker Desktop and Compose are available:

```powershell
docker version
docker compose version
```

## 3. Configure the Environment File

Create `.env.windows-airgap` in the repository root. It contains both deployment
settings and the S3 credentials. Replace every example value with the
deployment's actual value:

```dotenv
VIEWER_IMAGE=artifactory.airgap.example/overture/overture-explorer-airgap:1.0.0
TILES_IMAGE=artifactory.airgap.example/overture/overture-tiles-airgap:1.0.0
CATALOG_IMAGE=artifactory.airgap.example/dockerhub/library/node:20-alpine

OVERTURE_RELEASE=2026-04-15.0
S3_BUCKET=overture-source
SOURCE_RELEASE_PREFIX=release
PMTILES_RELEASE_PREFIX=pmtiles/release
S3_ENDPOINT_URL=https://s3.airgap.example
S3_REGION=us-east-1
AWS_ACCESS_KEY_ID=replace-with-s3-access-key
AWS_SECRET_ACCESS_KEY='replace-with-s3-secret-key'
PMTILES_HTTP_BASE=https://s3-gateway.airgap.example/overture-source/pmtiles/release/2026-04-15.0/

THEME=places
BBOX=
PRESERVE_PARQUET=true
DOWNLOAD_MIN_ZOOM=15
VIEWER_PORT=8088
OUTPUT_VOLUME_PREFIX=overture-2026-04-15-0
```

The Compose stack constructs both S3 paths from the same `S3_BUCKET`:

```text
s3://<bucket>/<source-release-prefix>/<release>/theme=<theme>/type=<type>/<file>.parquet
s3://<bucket>/<pmtiles-release-prefix>/<release>/<theme>.pmtiles
```

For example:

```text
s3://overture-source/release/2026-04-15.0/theme=places/type=place/part-00000.parquet
s3://overture-source/pmtiles/release/2026-04-15.0/places.pmtiles
```

Do not include leading or trailing slashes in `SOURCE_RELEASE_PREFIX` or
`PMTILES_RELEASE_PREFIX`. `PMTILES_HTTP_BASE` is the browser-accessible URL for
the generated release directory and must refer to the same objects as the
`s3://.../pmtiles/release/<release>/` path. It may be an S3 HTTP endpoint or an
internal reverse proxy, but it must allow browser `GET` and `HEAD`, byte-range
requests, and CORS from the viewer origin. Avoid expiring presigned URLs in the
static catalog.

`BBOX` is `min_lon,min_lat,max_lon,max_lat`. Set `BBOX=` for a whole-world run.
Use a different `OUTPUT_VOLUME_PREFIX` for each release or independently managed
deployment so that outputs cannot be mixed accidentally.

If the S3 service runs directly on the Windows host, use an endpoint such as
`https://host.docker.internal:<port>`. Do not use `localhost`: inside the
generator container it means the container itself.

Use single quotes for a secret containing `$`, `#`, spaces, or other characters
that Docker Compose could otherwise interpret. The quotes delimit the dotenv
value and are not passed to S3.

## 4. Protect and Validate the Environment File

`.env.windows-airgap` is excluded by the repository's `.gitignore`. Confirm that
before adding or committing files:

```powershell
git check-ignore .env.windows-airgap
git status --short
```

The first command must print `.env.windows-airgap`, and the second must not list
it. Restrict the file's Windows ACL to the operator and required administrator
accounts. Do not paste or print the file in tickets, logs, or deployment records.
The Compose stack loads it only into the one-shot `tiles-generator` and
`publish-pmtiles` services; the catalog and viewer services do not use this env
file.

The S3 identity needs `ListBucket` and `GetObject` on the configured source
prefix. It also needs `ListBucket`, `GetObject`, and `PutObject` on only the
`pmtiles/release/<release>/` output prefix. It does not need permission to modify
the source GeoParquet objects.

## 5. Authenticate to Artifactory and Verify Images

Authenticate only to the internal registry. Do not place the registry password
in `.env.windows-airgap`. `config --images` prints only resolved image names;
avoid an unrestricted `docker compose config` because its rendered output can
include environment values:

```powershell
docker login artifactory.airgap.example
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml --profile generate config --images
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml --profile generate pull
```

Inspect the resolved images and record their immutable digests in the deployment
log:

```powershell
docker image inspect artifactory.airgap.example/overture/overture-explorer-airgap:1.0.0 --format '{{json .RepoDigests}} {{.Os}}/{{.Architecture}}'
docker image inspect artifactory.airgap.example/overture/overture-tiles-airgap:1.0.0 --format '{{json .RepoDigests}} {{.Os}}/{{.Architecture}}'
docker image inspect artifactory.airgap.example/dockerhub/library/node:20-alpine --format '{{json .RepoDigests}} {{.Os}}/{{.Architecture}}'
```

All three images must report `linux/<Docker Desktop architecture>`. Once the
images are present locally, generation and viewing do not require Artifactory to
remain reachable.

## 6. Verify the Exact S3 Prefix

Test credentials, endpoint, region, certificate trust, and the expected object
layout before starting an expensive generation run:

```powershell
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml --profile generate run --rm --entrypoint /bin/bash tiles-generator -euc 's5cmd ls "${SOURCE_PATH%/}/theme=${THEME}/type=*/*.parquet"'
```

Do not continue unless this returns one or more parquet objects. If the S3
appliance does not support that wildcard form, use `s5cmd ls` successively on
the theme prefix and a known exact object key.

## 7. Generate PMTiles and GeoParquet

Generate the theme configured by `THEME`:

```powershell
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml --profile generate run --rm tiles-generator
```

To generate several themes with the same release and bounding box, run them
sequentially:

```powershell
$Themes = @("base", "buildings", "places", "divisions", "transportation", "addresses")
foreach ($Theme in $Themes) {
  docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml --profile generate run --rm -e "THEME=$Theme" tiles-generator
  if ($LASTEXITCODE -ne 0) { throw "Tile generation failed for $Theme" }
}
```

Each successful run writes:

```text
tiles/<release>/<theme>.pmtiles
data/release/<release>/theme=<theme>/type=<type>/<file>.parquet
```

The PMTiles file is initially local. The publisher uploads it to the configured
path in the same S3 bucket before the viewer starts.

The generator downloads the selected theme from S3 into its temporary container
storage before processing it. Ensure Docker Desktop has enough free virtual-disk
space for both temporary input and persistent output. Removing the one-shot
container after success releases its temporary layer; the named output volumes
remain.

## 8. Generate the Catalog and Start the Viewer

Start the viewer only after at least one theme has completed:

```powershell
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml up -d viewer
```

Compose first runs the one-shot `publish-pmtiles` service, which synchronizes all
locally generated PMTiles for the release to
`s3://<bucket>/pmtiles/release/<release>/`. The one-shot `catalog` service then
discovers the available PMTiles and parquet files, writes S3 HTTP PMTiles links
into the STAC catalogs, creates the download manifest and release-matched
`viewer-config.json`, and exits. The viewer starts only if both jobs succeed.

Open:

```text
http://localhost:8088
```

Use the configured `VIEWER_PORT` instead of `8088` if it was changed.

After generating another theme, rerun the catalog and recreate the viewer so the
new theme is listed:

```powershell
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml run --rm publish-pmtiles
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml run --rm catalog
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml up -d --force-recreate viewer
```

## 9. Validate the Deployment

Check container state and logs:

```powershell
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml ps -a
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml logs publish-pmtiles catalog viewer
```

Probe the runtime configuration, root catalog, release manifest, uploaded
PMTiles object, and PMTiles range support:

```powershell
curl.exe -fsS http://localhost:8088/config/viewer-config.json
curl.exe -fsS http://localhost:8088/catalog/catalog.json
curl.exe -fsS http://localhost:8088/catalog/2026-04-15.0/manifest.geojson
curl.exe -fsS -D - --range 0-1023 -o NUL https://s3-gateway.airgap.example/overture-source/pmtiles/release/2026-04-15.0/places.pmtiles
```

Replace the port, release, and theme in those URLs with the configured values.
The final request should print HTTP `206 Partial Content` in its response
headers. In the browser, confirm that the map loads with
the network disconnected from all public services and that visible-layer
downloads return data from `/data/release/<release>/`.

## 10. Stop, Restart, and Preserve Data

Stop the viewer while retaining every generated object:

```powershell
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml down
```

Restart it later with:

```powershell
docker compose --env-file .env.windows-airgap -f compose.windows-airgap.yml up -d viewer
```

The named volumes are persistent workstation data inside Docker Desktop. Back
them up according to the deployment's recovery requirements. Do not use
`docker compose down --volumes` unless permanent deletion of all generated
PMTiles, GeoParquet, catalogs, and runtime configuration is intended.

## 11. Troubleshooting

If Artifactory pulls fail:

- Confirm the three image references are fully qualified internal names.
- Confirm Docker Desktop trusts the Artifactory CA and the operator is logged in.
- Confirm the image architecture matches Docker Desktop.

If S3 access fails:

- Confirm the endpoint is reachable from a Linux container, not only Windows.
- Do not use `localhost` for a service running on the Windows host; use
  `host.docker.internal`.
- Confirm the S3 certificate chain is trusted by the production generator image.
- Confirm the region, read/write access policies, both release prefixes, and
  object-key case.
- Re-run the exact-prefix check from section 6.

If PMTiles publishing or browser loading fails:

- Run `publish-pmtiles` directly and confirm `s5cmd ls` reports the uploaded key.
- Confirm `PMTILES_HTTP_BASE` maps to the same bucket and release prefix.
- Confirm the HTTP endpoint supports anonymous or gateway-authorized browser
  reads without exposing the S3 write credentials.
- Confirm CORS permits the viewer origin and byte-range requests return `206`.

If generation is killed or Docker Desktop runs out of space:

- Increase Docker Desktop memory and virtual-disk capacity.
- Generate one theme at a time and use a bounded `BBOX` first.
- Inspect Docker Desktop disk usage before retrying.

If the viewer is blank:

- Confirm the catalog job completed successfully.
- Confirm the requested release and theme exist in the named volumes.
- Fetch the catalog and PMTiles URLs from section 9 directly.
- Confirm PMTiles responses support byte ranges.

## 12. Security Checklist

- Use immutable, verified production image digests from internal Artifactory.
- Give the S3 identity read-only access to the source prefix and write access
  only to the generated PMTiles prefix.
- Keep secret values out of Compose, logs, the viewer, and deployment records.
- Protect `.env.windows-airgap` with Windows ACLs and rotate it according to site
  policy.
- Keep TLS verification enabled for Artifactory and S3.
- Validate that browser developer tools show no public-network requests.
- Retain deployment records for image digests, release, BBOX, generated themes,
  catalog timestamp, and validation results.
