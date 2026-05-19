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

## Docs

- [Airgap design](docs/airgap-design.md)
- [GitHub and CI/CD](docs/github-cicd.md)
