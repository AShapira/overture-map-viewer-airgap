# Overture Explorer Airgap

This repository packages the Overture Maps Explorer for a disconnected environment.

The important split is:

- `localhost/overture-explorer-airgap:local`: small static viewer container
- `localhost/overture-tiles-airgap:local`: batch tile-generation container

Local development and RHEL air-gap operations support rootless Podman on RHEL 10
under WSL2. A separate production deployment uses imported Artifactory images
with Docker Desktop on an air-gapped Windows host. The OCI `Dockerfile`s remain
portable image definitions, and GitHub-hosted CI continues to use Docker tooling.

## Prerequisites

Run all commands inside the RHEL WSL distro as your normal Linux user. The
validated baseline is Podman 5.8.2, `podman-compose` 1.6.0, Node.js 22, and npm.

```bash
podman --version
podman-compose --version
podman info --format 'rootless={{.Host.Security.Rootless}}'
node --version
npm --version
```

The final command must report `rootless=true`. Do not prefix project commands
with `sudo`.

Install the lockfile-pinned application dependencies once per clean checkout:

```bash
npm ci --ignore-scripts
npm run postinstall
```

The browser accessibility check also needs Playwright Chromium and its RHEL
runtime libraries:

```bash
sudo dnf install -y \
  alsa-lib atk at-spi2-atk at-spi2-core \
  libX11 libXcomposite libXdamage libXext libXfixes libXrandr \
  libxcb mesa-libgbm
npx playwright install chromium
```

The default local Overture release path is:

```text
./data/release/2026-04-15.0
```

Override it when needed:

```bash
export OVERTURE_RELEASE_DIR=/path/to/release/2026-04-15.0
```

## Build Images

```bash
./scripts/build-images.sh
```

The script uses Podman with Docker-format image metadata so the viewer's OCI
`HEALTHCHECK` instruction is preserved. Compose consumes these prebuilt images.

## Generate Smoke Tiles

Generate one theme from the mounted release:

```bash
BBOX="min_lon,min_lat,max_lon,max_lat" \
  podman-compose -f compose.airgap.yml --profile generate run --rm -T tiles-smoke-places
```

Generate the local catalog:

```bash
npm run airgap:catalog:smoke -- --bbox "$BBOX"
```

The output is written under `airgap-output/`.

## Test Local S3 Input

The tile generator can read release data from an S3-compatible source with:

```text
SOURCE_PATH=s3://bucket/prefix
```

After generating the local places smoke output, run the MinIO-backed test:

```bash
./scripts/test-local-s3-generator.sh
```

Use `--keep-services` to leave MinIO running. The script seeds and verifies:

```text
s3://overture-local/release/2026-04-15.0/theme=places/type=place/filtered.parquet
```

The S3 key layout must match the mounted release layout:

```text
<prefix>/theme=<theme>/type=<type>/<file>.parquet
```

The smoke output is written to `airgap-output/s3-smoke/`.

Validate the complete source S3, generated-output S3, catalog, viewer sync, and
HTTP flow with:

```bash
./scripts/validate-airgap-s3-runbook.sh
```

Optional arguments are `--viewer-port PORT` and `--keep-services`.

## Run Viewer

```bash
podman-compose -f compose.airgap.yml up -d viewer
```

Open [http://localhost:8088](http://localhost:8088). Stop it with:

```bash
podman-compose -f compose.airgap.yml down
```

If port 8088 is already in use, select another unprivileged host port:

```bash
VIEWER_PORT=18088 podman-compose -f compose.airgap.yml up -d viewer
```

## Runtime Config

The viewer reads `public/config/viewer-config.json`, mounted at runtime by the
Compose stack. The default offline config is:

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

Change `download.minZoom` to control when `Download visible layers` is enabled.
Lower values allow larger visible areas; higher values restrict downloads to
smaller visible areas.

## Validation

Run the complete static suite with:

```bash
./scripts/test-static.sh
```

It validates Bash and Compose syntax, rejects unsupported Windows/Docker local
tooling, and runs lint, Jest, the static build, and browser accessibility checks.

## RHEL and WSL Notes

- Keep the checkout in the RHEL filesystem and use RHEL-local Git and GitHub CLI.
- Ports `8088`, `8099`, `9000`, and `9001` are unprivileged and work rootlessly.
- SELinux is disabled in the supported WSL environment, so `/mnt/d` bind mounts
  do not use relabel options.
- On native RHEL with enforcing SELinux, copy operational data to a Linux
  filesystem and add an appropriate `:z` or `:Z` label after reviewing whether
  each mount is shared or private.
- WSL-mounted Windows storage is convenient for the source dataset but slower
  than the Linux filesystem for generator scratch and output; keep
  `airgap-output/` inside the Linux checkout.

## Capacity Assumptions

The viewer is a static nginx container. Capacity is mostly limited by pod
egress bandwidth, storage read throughput, and PMTiles/parquet range requests.
For a medium deployment, start with 2 vCPU, 4 GiB RAM, 1 Gbps effective network
throughput, and fast local or PVC-backed storage.

Reasonable starting estimates for a bounded smoke dataset are:

- Light browsing: 500–1500 connected sessions
- Active panning: 100–300 concurrent users
- Heavy high-zoom panning: 50–100 concurrent users
- Small visible-layer downloads: 10–25 concurrent downloads
- Medium visible-layer downloads: 5–10 concurrent downloads

For shared production deployments, start with at least two viewer replicas,
use `download.minZoom: 16`, and monitor egress, storage throughput, p95 static
response time, and `206` range-request rate.

## Documentation

- [Air-gap design](docs/airgap-design.md)
- [Air-gapped S3 runbook](docs/airgap-s3-runbook.md)
- [Windows Docker Desktop air-gap runbook](docs/windows-docker-desktop-airgap.md)
- [GitHub and CI/CD](docs/github-cicd.md)
