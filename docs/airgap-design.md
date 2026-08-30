# Air-Gapped Overture Explorer Design

## Goal

Run the Overture Maps Explorer in a disconnected network while preserving two
workflows:

- view Overture data from generated PMTiles
- download visible data as GeoJSON ZIP files from local parquet

The local development and RHEL operator environment is RHEL 10 on WSL2 with
rootless Podman. Production images can also run on Docker Desktop for Windows
with the separate `compose.windows-airgap.yml` workflow. The always-on viewer
remains small and static; tile generation is a separate batch image because it
needs Java, DuckDB, S3 tooling, temporary storage, and broader filesystem access.

## Components

### Viewer image

`Dockerfile.viewer` builds the Next.js static export and serves it with
`nginxinc/nginx-unprivileged` on port `8080`.

Runtime properties:

- non-root nginx user
- no server-side application runtime
- read-only container in `compose.airgap.yml`
- all Linux capabilities dropped and `no-new-privileges` enabled
- only nginx runtime paths backed by tmpfs
- runtime config mounted at `/config/viewer-config.json`
- configurable download zoom gate through `download.minZoom`
- synchronized Explore/Inspect split view backed by the same published PMTiles
- confirmation-before-download with a persistent browser fallback link

The viewer does not require public STAC, public Overture S3, Google Fonts, or a
public geocoder. Search stays disabled unless an internal geocoder is configured.
The default URL has no `mode` query parameter and opens at the split position;
`mode=explore` and `mode=inspect` select the corresponding full-map view.

### Tile generator image

`airgap/tile-generator/Dockerfile` packages the Overture Planetiler profiles,
DuckDB, and `s5cmd`. Its Ubuntu-based JDK and Alpine build stage are container
internals and do not impose host package-manager requirements on RHEL.

Input modes:

- a release bind-mounted at `/input/release`
- S3-compatible input selected with `SOURCE_PATH=s3://bucket/path`

The default source mount is `./data/release/2026-04-15.0`. Override it through
`OVERTURE_RELEASE_DIR`.

S3 keys below the release root must preserve this layout:

```text
theme=<theme>/type=<type>/<file>.parquet
```

Run the local MinIO smoke test with:

```bash
./scripts/test-local-s3-generator.sh
```

### Local catalog

`scripts/generate-airgap-catalog.mjs` creates the STAC-compatible catalogs and
download manifest from a successful publication manifest. Local metadata uses:

```text
airgap-output/
  data/release/<release>/theme=<theme>/type=<type>/filtered.parquet
  publication/<release>.json
  catalog/catalog.json
  catalog/<release>/catalog.json
  catalog/<release>/<theme>/catalog.json
  catalog/<release>/manifest.geojson
```

## Data Flow

1. Mount an Overture release or configure an internal S3 source.
2. Run one rootless generator job for the ordered `THEMES` configuration.
3. For each theme, generate in monitored local scratch, upload and verify its S3
   object, then delete the local PMTiles archive.
4. Write a publication manifest only after all configured themes succeed.
5. Generate the local catalog from that manifest.
6. Start the read-only viewer. The browser reads PMTiles from an internal
   range-capable HTTP gateway and catalogs/download parquet from configured
   local or internal endpoints.

The browser renders synchronized Explore and Inspect maps. This can increase
client GPU and memory use and generate PMTiles requests for both styles, while
the nginx viewer remains a static range-capable file server. Capacity testing
must therefore cover representative browser hardware as well as server egress.

A bounded smoke run receives its site-approved BBOX from the operator. Full-world
generation uses the same image without `BBOX`. The generator always processes
themes sequentially and uses a configured free-space floor to protect its local
scratch filesystem. PMTiles are not accumulated in a local output volume.

## Security and Host Integration

- The RHEL workflow requires rootless Podman; its project scripts reject
  rootful execution. The Windows production workflow uses Docker Desktop Linux
  containers and imported Artifactory images as documented separately.
- The viewer receives no cloud credentials and only read-only data mounts.
- Only the generator receives S3 credentials; catalog and viewer use the
  credential-free PMTiles HTTP gateway.
- The MinIO validation network is explicitly named `overture-airgap-s3`.
- WSL has SELinux disabled, so Windows-mounted source data uses no relabel flag.
  Native enforcing RHEL deployments must select `:z` or `:Z` deliberately on a
  Linux filesystem.
- Release bundles should include OCI image archives, checksums, SBOM/provenance
  where available, and the operational runbook.
