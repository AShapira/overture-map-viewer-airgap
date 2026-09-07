# Overture Explorer Airgap

For private PMTiles buckets, use the optional [PMTiles proxy](docs/private-pmtiles-proxy.md) with a dedicated read-only S3 identity.

This repository packages the Overture Maps Explorer for a disconnected environment.

The important split is:

- `localhost/overture-explorer-airgap:local`: small static viewer container
- `localhost/overture-tiles-airgap:local`: batch tile-generation container
- `localhost/overture-pmtiles-proxy-airgap:local`: optional private-S3 PMTiles reader

Local development and RHEL air-gap operations support rootless Podman on RHEL 10
under WSL2. Windows production deployment uses native PowerShell and Podman Desktop
with imported Artifactory images and its WSL2 Podman machine. The OCI `Dockerfile`s remain
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

## Generate and Publish Tiles

Generate every configured theme sequentially from the mounted release, publish
each completed PMTiles archive to S3, and delete its local scratch copy:

```bash
THEMES=places \
BBOX="min_lon,min_lat,max_lon,max_lat" \
PMTILES_S3_PATH=s3://overture-generated/pmtiles/release/2026-04-15.0 \
PMTILES_SCRATCH_DIR="$PWD/airgap-output/scratch" \
PMTILES_MIN_FREE_GB=1 \
S3_REGION=us-east-1 \
S3_ENDPOINT_URL=http://127.0.0.1:9000 \
AWS_ACCESS_KEY_ID=minioadmin \
AWS_SECRET_ACCESS_KEY=minioadmin \
  podman-compose -f compose.airgap.yml --profile generate run --rm -T tiles-generator
```

`THEMES` defaults to all six supported themes. For an S3 `SOURCE_PATH`, the
generator range-reads GeoParquet objects directly and does not stage their
payloads in scratch. It checks both the free-space reserve and optional
per-theme scratch ceiling during Planetiler, uploads and verifies the exact S3
object by streamed SHA-256 and byte count, then removes the local PMTiles file. Generate the catalog from the
success manifest and the browser-facing S3 HTTP URL:

```bash
PMTILES_HTTP_BASE=http://127.0.0.1:9000/overture-generated/pmtiles/release/2026-04-15.0/ \
  npm run airgap:catalog:smoke -- --bbox "$BBOX"
```

Use a fresh `PMTILES_S3_PATH` prefix for each generation; existing PMTiles are
never overwritten. Catalogs, optional preserved GeoParquet, and publication state are written under
`airgap-output/`; PMTiles remain only in S3 after success.

## Test Local S3 Input

The tile generator can read release data from an S3-compatible source with:

```text
SOURCE_PATH=s3://bucket/prefix
```

Supply a bounded places GeoParquet fixture and run the isolated MinIO test:

```bash
SEED_PARQUET=/path/to/bounded-place.parquet ./scripts/test-local-s3-generator.sh
```

Use `--keep-services` to leave the test containers running. Each run creates a
new directory and a new MinIO store, then seeds and verifies:

```text
s3://test-source/release/theme=places/type=place/part.parquet
```

The S3 key layout must match the mounted release layout:

```text
<prefix>/theme=<theme>/type=<type>/<file>.parquet
```

The same low-storage defaults apply to both local and S3 sources: sequential
themes, compressed temporary features, no temporary mmap, one sort reader and
writer, and no preserved GeoParquet. Set deliberate `PMTILES_MAX_SCRATCH_GB`,
`PMTILES_MAX_LOCAL_GB`, and `PMTILES_MIN_FREE_GB` values for your site; none is a
promise that a particular release or whole-world theme will fit.

The test uses the Tel Aviv BBOX `34.75,32.03,34.85,32.13`; use a fixture intersecting
it. It retains evidence under `airgap-output/s3-validation.<unique-id>/`, including
two deliberately retained write-denied archives. It verifies that a later
successful run removes only its own archive and preserves earlier failures.

Validate the complete source S3, generated-output S3, publication manifest,
catalog, remote PMTiles range access, and viewer flow with:

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

## Viewer Interaction

The default map is a synchronized split view: Explore styling is on the left
and Inspect styling is on the right. Drag the divider, or use its arrow buttons,
to compare the same location. Shared URLs use `mode=explore` or `mode=inspect`
for the corresponding full-map view; when `mode` is absent, the viewer opens at
the default split position.

Downloads now open a confirmation dialog before reading local parquet. The
generated GeoJSON follows `overturemaps-py` conventions: feature IDs are stored
as top-level GeoJSON IDs, the internal `bbox` property is omitted, and
single-part multi-geometries are emitted in their single-geometry form. After
generation, the browser keeps a visible fallback link until it is dismissed.

## Validation

Run the complete static suite with:

```bash
./scripts/test-static.sh
```

It validates Bash and Compose syntax, the shared capacity/lifecycle controller,
and supported Podman tooling, then runs lint, Jest, the static build, and browser
accessibility checks. Native PowerShell acceptance is recorded separately.

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

The split view renders two synchronized MapLibre maps and can request Explore
and Inspect tiles for the same viewport. Treat its browser GPU/memory use and
PMTiles request rate as higher than the previous single-map mode, and validate
capacity with representative clients and data before fixing production limits.

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
- [Windows Podman Desktop air-gap runbook](docs/windows-podman-desktop-airgap.md)
- [GitHub and CI/CD](docs/github-cicd.md)

## Processing storage and capacity planning

S3 capacity and processing capacity are independent. Remote GeoParquet is read
with bounded range buffers. Local GeoParquet is mounted read-only and filtered
by the same Planetiler bounds logic. Neither path materializes a filtered source
copy before generation. The source can be hundreds of GiB while a regional job
needs far less local storage; the selected geometry, attributes, zooms and tile
fanout determine the working set.

### Local and S3 lifecycle

| Stage | Additional local storage | S3 storage |
|---|---|---|
| Estimate | Metadata in memory; optional explicit JSON report | Existing source objects, read only |
| Optional pilot | Bounded sample partitions, feature/sort files, sample PMTiles | No new objects |
| Read/render | Compressed intermediate features; small path index and JVM temp | Ranged reads of original GeoParquet |
| Sort | Feature chunks rewritten in place; no second complete sort copy | Unchanged |
| Write archive | Remaining features plus one seekable PMTiles archive | Unchanged |
| Optional preservation | Bounded output partitions and replacement overlap | Direct reads; no full-source staging |
| Publish/verify | One completed archive until streamed SHA-256 verification passes | Newly uploaded archive, briefly coexisting with its local copy |
| Successful finish | Small manifest/catalog/config and explicitly preserved GeoParquet | All completed themes and bounded compressed diagnostic logs |
| Upload failure | Completed archive in its unique run directory, plus one bounded latest-failure report | Earlier verified objects and possibly the failed/unverified upload |

For sequential themes, calculate **existing local occupancy + maximum concurrent
stage footprint**, not the sum of every theme's peak. Reserve space must remain
free in addition to that footprint. With preservation enabled, completed
preserved datasets accumulate and contribute to later themes' peaks; existing
data also remains during replacement. The estimator includes this overlap.

Planetiler's feature store survives into archive writing. Both feature/sort
files and PMTiles require seekable local storage with this implementation. S3
is not used as a writable scratch filesystem. No OSM node-location or
multipolygon-index formula is applied to these GeoParquet jobs.

In the pinned [Planetiler 0.10.2 sorter](https://github.com/onthegomap/planetiler/blob/v0.10.2/planetiler-core/src/main/java/com/onthegomap/planetiler/collection/ExternalMergeSort.java),
each chunk group is read into RAM and rewritten to the original chunk path;
merged companion chunks are removed. The model therefore assigns no second
complete on-disk sorting copy. Its measured feature-store coefficient covers
the peak before/during sorting, including changes in compression after sorting.
The conservative overlap is that work peak plus the full archive and bounded
overhead. Working files are released before upload and checksum read-back.

`PLANETILER_COMPRESS_TEMP=true`, `PLANETILER_MMAP_TEMP=false`, and
`PLANETILER_SORT_MAX_READERS=1` / `PLANETILER_SORT_MAX_WRITERS=1` are the defaults.
Compression costs CPU; reduced I/O concurrency can increase sort time. Exact
remote SHA-256 verification reads the complete uploaded object again, adding
network traffic and time but no second local archive. Temporary inputs from
pilots/exports are bounded; selected source datasets are never copied wholesale
into generation scratch.

Preservation/export targets partitions of roughly 128 MiB of writer data or
250,000 records, with 16 MiB row groups. A single large record and writer buffers
can exceed a target; the sampled capacity guard remains the stopping mechanism.
Every completed staging partition can be uploaded and checksum-verified before
the next partition is produced by the regional-source validation helper.

Three independent controls apply:

- `PMTILES_MAX_SCRATCH_GB`: active-theme scratch ceiling.
- `PMTILES_MAX_LOCAL_GB`: combined scratch/output occupancy, including old retained
  files; overlapping paths count once. Inode identity also deduplicates hardlinks
  within a filesystem view. The Windows wrapper identifies enclosing host binds
  because separate exports can expose different virtual device IDs.
- `PMTILES_MIN_FREE_GB`: free-space floor on every involved filesystem.

Generation rejects symlinks beneath writable roots along its release,
publication, and preserved-output paths. Such links could otherwise redirect
writes outside monitored storage or redirect preserved-data replacement.

Budget occupancy uses the larger of logical file length and filesystem-reported
allocation for each file, so sparse/mmap files are not treated as free capacity.
Measurements also record reported allocated bytes and the largest allocation
increase from the start of the run, separately from that conservative occupancy.
Allocation reported through VM bind mounts can differ from physical host use;
the native drive monitor checks actual remaining host capacity as well.

The controller samples twice per second,
checks between operations, and terminates the entire child process group when a
limit is reached. This is a cancellation guard, not a filesystem quota: a burst
of writes can briefly overshoot before detection and shutdown. Never configure
its ceiling at the disk's absolute remaining capacity.

On Windows, the wrapper also checks host drive free space. The processing bind,
Podman-machine filesystem, RHEL filesystem and C:-backed VHDX are different
accounting views. Free space inside a virtual disk does not guarantee its host
drive can grow. Removing files inside a VM also does not guarantee immediate
VHDX shrinkage. Images, build caches, container logs, Python tools and swap are
outside the processing budget and must be counted separately.

### Estimates and calibration

The generator supports `--dry-run`, `--estimate-pilot`, `--report PATH`, and
`--calibration PATH`. The two estimate modes are mutually exclusive. Native
Windows examples are in the [Podman runbook](docs/windows-podman-desktop-airgap.md).
For RHEL, pass these arguments after the generator image in the existing
`podman run` invocation, retaining the same source/scratch/output mounts:

```bash
# Generator arguments; no tile generation or publication:
--dry-run --report /output/israel-estimate.json

# Explicit bounded sample generation; no publication:
--estimate-pilot --report /output/israel-calibration.json

# Re-estimate using compatible measured samples:
--dry-run --calibration /output/israel-calibration.json --report /output/israel-calibrated.json
```

Set `BBOX=` for whole-world estimation and `THEMES` to the desired ordered subset.
Dry-run is read-only except for the explicitly requested new JSON report. It
never replaces publication state or overwrites an existing report. The report
path must be new, inside the monitored scratch/output directories, and outside
the publication-state directory. Writing a large report is capacity-checked too.
The report
shows per-theme candidate rows, source bytes, feature/sort work, PMTiles bytes,
preserved-output allowance, local peak, reserve/headroom, S3 growth and the
calibration provenance. Byte-valued JSON fields use bytes; readable sizes use GiB
(2^30 bytes), including environment variables whose historical names end in `GB`.
An explicitly requested full JSON estimate includes per-object/row-group metadata
and can occupy tens of MiB for a complete release. Publication manifests retain
the compact estimate summary, excluding those detailed input inventories.

Candidate rows are **not exact BBOX-selected rows**. The estimator reads Parquet
footers and includes complete intersecting row groups; missing statistics remain
candidates. It does not scale solely by the rectangle's area. Initial estimates
without compatible measured coefficients are labelled `uncalibrated` and use
explicit broad heuristics, not invented measurement claims. Compatible checked-in
measurements are labelled `measured-prior`; a matching pilot is `source-calibrated`.

The bundled [measured coefficients](airgap/tile-generator/capacity-priors.json)
record their source, profile/settings compatibility, pilot measurements, and
complete Israel and Egypt–Turkey–Iran measurements. For candidate compressed row-group bytes `B`,
expected work is `work_coefficient × B`; expected archive size is the larger of
32 KiB and `output_coefficient × B`. Add 32 MiB per active theme for bounded
overhead. The conservative theme peak multiplies that sum by the planning
factor: 2.5 for most bundled measurements, 4 for divisions following the larger
regional validation, or 4 for the uncalibrated fallback
(work coefficient 3, archive coefficient 1.5). Missing BBOX statistics double
the factor. Preservation adds the larger of candidate compressed/uncompressed
bytes, accumulating across themes; existing preserved data is already included
in initial occupancy during replacement. These deliberately broad allowances
should be replaced or checked with measurements from representative site data.
A compatible pilot retains at least the uncertainty factor already observed in
complete regional runs; invalid, negative or nonfinite coefficients are rejected.

Pilot sampling covers each available type and low/median/high row-group counts,
spatial density proxies, geometry bytes and compressed sizes. It reads a deterministic bounded number of
records per selected group, runs the unchanged profiles, and measures scratch and
archive bytes. A 5 GiB per-theme pilot ceiling applies by default. This is not a
random statistical sample: rare complex geometries and spatial skew can still
make extrapolation inaccurate. Calibration fingerprints include source object
identities and generation settings; stale calibration is rejected. Planning
ranges are not guaranteed bounds or statistical confidence intervals. A pilot
that exceeds its budget stops and reports the failure without publishing.

### Final storage and local S3

With `PRESERVE_PARQUET=false`, successful processing leaves **zero local PMTiles
archives** and no generated GeoParquet payload. Small manifests, catalogs and
viewer configuration remain. Diagnostic tails are capped at 8 MiB per theme
before compression and stored in S3. A single local failure summary includes at
most 64 KiB of log tail; completed failed-upload archives remain until explicitly
recovered. Existing ignored data and earlier archives are not automatically
removed. With preservation enabled, the final local footprint also includes the
selected GeoParquet downloads; account for them explicitly.

Final S3 consumption is **retained sources + retained older publications + sum
of new theme archives + diagnostics**. The estimator separately reports selected
source bytes, existing destination occupancy when readable, and additional
publication bytes. Generic S3 APIs do not reveal an authoritative usable quota;
unknown quota/free space stays `null`, not zero or infinite. Bucket versioning,
replication/erasure coding and abandoned multipart uploads can increase physical
backend usage beyond logical object sizes; configure retention with the S3
operator.

A workstation-hosted MinIO bucket uses actual workstation disk. When MinIO and
scratch share D:, budget the regional S3 source, retained Israel outputs, new
Middle East outputs and the largest scratch/upload overlap together. An upload
briefly stores the archive twice on that drive. In a real deployment with S3 on
separate storage, only its local archive copy counts against processing storage.

Native validation measurements and estimate errors are recorded in
[validation evidence](docs/capacity-validation.md). Both regions below completed
all six themes through native Windows PowerShell and Podman Desktop, using
24 GiB memory and 12 CPUs. Predictions in this table were recorded **before**
their respective generation runs; sizes are GiB.

| Scope | Predicted additional local peak expected / conservative | Measured additional local peak | Predicted archives | Measured archives | Generation + validation + publication |
|---|---:|---:|---:|---:|---:|
| Israel: `34.2,29.4,35.9,33.4` | 0.913 / 2.282 | 0.683 | 0.656 | 0.679 | 5.37 min |
| Egypt–Turkey–Iran: `24,22,64,43` | 21.72 / 54.30 | 14.85 | 15.90 | 17.69 | 84.24 min |

The Middle East overall local peak was 31.7% below its expected estimate;
archives were 11.3% larger than expected. Divisions exceeded its original
conservative theme peak by 7.8%, so the final bundled coefficients include the
larger regional measurements and a wider divisions margin. The capacity guard
remained active, and native D: free space never fell below 542.8 GiB. Both runs
passed integrity, streamed SHA-256, HTTP 206/CORS, catalog and native browser
checks, and left zero successful local PMTiles or generated GeoParquet payloads.

Regional source preparation added a separate 2.35 minutes/65 MiB staging peak
for Israel and 39.12 minutes/129 MiB for the larger rectangle. In this isolated
local-MinIO test, retained inputs and outputs for both regions total 35.73 GiB
of logical S3 objects, including diagnostics. Reports, screenshots, image
archives, backend metadata and other validation evidence are separate local costs.

The final whole-world metadata estimate is **697.6–1744.1 GiB additional local
peak** and **617.6–1631.8 GiB additional S3 objects**. Add retained S3 inputs
(568.3 GiB for this complete release) and previous outputs when applicable.
These are extrapolations; no whole-world production run was performed.
