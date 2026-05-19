# Overture Explorer Airgap

This repository packages the Overture Maps Explorer for a disconnected environment.

The important split is:

- `overture-explorer-airgap`: tiny static viewer container
- `overture-tiles-airgap`: batch tile-generation container

The local Overture release expected on this machine is:

```text
D:\data\overturemaps-us-west-2\release\2026-04-15.0
```

## Build Images

```powershell
docker build -f Dockerfile.viewer -t overture-explorer-airgap:local .
docker build -t overture-tiles-airgap:local .\airgap\tile-generator
```

## Generate Israel Smoke Tiles

Generate one theme first:

```powershell
docker compose --profile generate run --rm tiles-israel-places
```

Generate the local catalog:

```powershell
node .\scripts\generate-airgap-catalog.mjs `
  --release 2026-04-15.0 `
  --tiles-dir .\airgap-output\tiles\2026-04-15.0 `
  --data-dir .\airgap-output\data\release\2026-04-15.0 `
  --out-dir .\airgap-output\catalog `
  --bbox 34.17,29.45,35.91,33.38 `
  --tile-base /tiles/2026-04-15.0/
```

## Run Viewer

```powershell
docker compose up -d viewer
```

Open:

```text
http://localhost:8088
```

## Runtime Config

The viewer reads:

```text
public/config/viewer-config.json
```

Default offline config:

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

Change `download.minZoom` in the mounted config to control when the
`Download visible layers` button is enabled. Lower values allow larger visible
areas; higher values restrict downloads to smaller visible areas.

## Capacity Assumptions

The viewer is a static nginx container. CPU and memory are usually not the
first bottleneck; capacity is mostly limited by pod egress bandwidth, storage
read throughput, and PMTiles/parquet HTTP range request volume.

For a medium pod, assume roughly:

- 2 vCPU
- 4 GiB RAM
- 1 Gbps effective network throughput
- local SSD or fast PVC-backed storage

Expected starting capacity for the Israel smoke dataset:

- Light or idle browsing: 500-1500 connected browser sessions
- Active panning and zooming: 100-300 concurrent users
- Heavy high-zoom panning: 50-100 concurrent users
- Small visible-layer downloads: 10-25 concurrent downloads
- Medium visible-layer downloads: 5-10 concurrent downloads
- Large downloads or lower `download.minZoom`: 2-5 concurrent downloads

Use this rule of thumb for download capacity:

```text
concurrent downloads = available network MB/s / average download server-read MB/s
```

On a 1 Gbps pod, practical usable throughput is commonly 70-100 MB/s. If each
active download reads about 10 MB/s, expect about 7-10 smooth concurrent
downloads before users feel slowdown.

Recommended shared deployment settings:

```json
"download": {
  "minZoom": 16
}
```

Use `minZoom: 15` to preserve the current default behavior. Use `minZoom: 17`
when downloads must be restricted to smaller visible areas. Lower values allow
larger downloads and should be paired with stronger rate limiting.

For production, start with at least two viewer replicas, keep the data on fast
read-optimized storage, and monitor pod egress, storage read throughput,
95th-percentile static response time, and `206` range request rate.

## Docs

- [Airgap design](docs/airgap-design.md)
- [GitHub and CI/CD](docs/github-cicd.md)
