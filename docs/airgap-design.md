# Airgapped Overture Explorer Design

## Goal

Run the Overture Maps Explorer in a disconnected network while preserving the two important workflows:

- view Overture data from generated PMTiles
- download visible data as GeoJSON ZIP files from local parquet

The always-on viewer is intentionally static and small. Tile generation is a separate batch image because it needs Java, DuckDB, S3 tooling, large temporary storage, and broader filesystem access.

## Components

### Viewer image

`Dockerfile.viewer` builds the Next.js static export and serves it with `nginxinc/nginx-unprivileged:stable-alpine` on port `8080`.

Runtime properties:

- non-root nginx user
- no server-side application runtime
- read-only container in Compose
- dropped Linux capabilities in Compose
- static files only
- runtime config from `/config/viewer-config.json`
- configurable download zoom gate via `download.minZoom`

The viewer no longer requires public STAC, public Overture S3, Google Fonts, or the public geocoder. Search is disabled unless an internal geocoder URL is configured.

### Tile generator image

`airgap/tile-generator/Dockerfile` packages the upstream Overture Planetiler profiles with DuckDB and `s5cmd`.
It uses a current Ubuntu-based JRE image, builds `s5cmd` from source with a current Go toolchain, and patches the shaded `io.airlift:aircompressor` classes in `planetiler.jar` to the fixed version until Planetiler ships that dependency upstream.

Input modes:

- mounted filesystem release, for example `/input/release/theme=places/type=place/*.parquet`
- S3-compatible source using `SOURCE_PATH=s3://bucket/path`

Output layout:

```text
airgap-output/
  tiles/<release>/<theme>.pmtiles
  data/release/<release>/theme=<theme>/type=<type>/filtered.parquet
  catalog/catalog.json
  catalog/<release>/catalog.json
  catalog/<release>/<theme>/catalog.json
  catalog/<release>/manifest.geojson
```

### Local catalog

`scripts/generate-airgap-catalog.mjs` creates a small STAC-compatible catalog with the fields the viewer already consumes:

- root catalog with the latest release link
- release catalog with theme children
- per-theme catalogs with `rel="pmtiles"`
- `manifest.geojson` for browser-side downloads

The manifest points downloads at the local parquet paths under `/data/release/<release>/`.

## Data Flow

1. Copy or mount an Overture release into the airgapped environment.
2. Run the tile generator for each selected theme and BBOX.
3. Generate the local catalog.
4. Start the viewer container.
5. The browser loads:
   - `/catalog/catalog.json`
   - `/tiles/<release>/<theme>.pmtiles`
   - `/data/release/<release>/.../*.parquet` when the user downloads visible data

## Israel Smoke Region

The default smoke BBOX is:

```text
34.17,29.45,35.91,33.38
```

This covers Israel plus nearby border/coastal context and is small enough for repeatable local testing.

## Full-World Mode

Full-world generation uses the same image without `BBOX`. It should be run one theme at a time with large persistent scratch and output volumes. Do not run full-world generation inside the viewer container.

## Security Notes

- The viewer has no write access except tmpfs locations needed by nginx.
- The viewer does not need cloud credentials.
- The generator is the only component that should receive S3 credentials, and only when using S3-compatible input or output.
- Release bundles should include image tarballs, checksums, SBOM/provenance where available, and this runbook.
