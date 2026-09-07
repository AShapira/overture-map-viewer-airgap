# Image update and Israel validation, 6 September 2026

The updated viewer and generator passed native Windows Podman validation for
`BBOX=34.2,29.4,35.9,33.4`, release `2026-07-22.0`, and all six themes.
All six published archive SHA-256 values match the previous Israel validation
in [capacity-validation.md](capacity-validation.md) exactly.

## Image selection

Build and runtime base references are pinned by registry digest in the
Dockerfiles. Local S3 Compose and integration tests use the same pinned MinIO
release references. These are the versions verified during this update:

| Component | Version or image tag |
|---|---|
| Viewer build and catalog Node | `24.20.0-alpine3.24` |
| Go builder | `1.27.1-alpine3.23` |
| NGINX unprivileged runtime | `1.30.4-alpine` |
| Temurin builder and generator runtime | `25-jdk-noble`, containing `25.0.4+7` |
| DuckDB | `1.5.5` |
| MinIO server | `RELEASE.2025-09-07T16-13-09Z` |
| MinIO client | `RELEASE.2025-08-13T08-35-41Z` |
| Planetiler | `0.10.2`, existing patches retained |
| s5cmd | `2.3.0`, built with Go `1.27.1` |

The Node pin in `package.json` also selects Node 24 for CI. s5cmd's module
version was verified using Go build metadata: its source-build `version`
command still reports `v0.0.0-dev`.

The [published Temurin image](https://hub.docker.com/_/eclipse-temurin) contains
Java `25.0.4+7`; the newer upstream `25.0.4.1+1` binary release was not available
as a Noble JDK image in the registry when checked. MinIO's community repository
is archived; pinning its last published images provides reproducibility, not
ongoing maintenance. Replacement of that test dependency is separate work.

## Security and regression checks

The first viewer scan found seven fixable HIGH/CRITICAL findings in `libuuid`.
The viewer's existing Alpine security update step now also upgrades `libuuid`.
The rebuilt viewer and generator pass the CI scan policy: HIGH/CRITICAL,
fixable vulnerabilities, with the repository's existing exceptions applied.
Trivy 0.70.0 used the vulnerability database updated on 6 September 2026.
The scanned image IDs match the images used in native Windows validation.

The three obsolete Go exceptions were removed. The unfiltered generator scan
still reports the three existing Planetiler/Jackson exceptions:
`GHSA-r7wm-3cxj-wff9`, `CVE-2026-54512`, and `CVE-2026-54513`.
No new exceptions were added.

- 661 Jest tests, 25 Python tests, and 6 Java adapter tests passed.
- Node 24 lint, production build, and four browser accessibility checks passed.
- Bash/Compose checks and Dockerfile lint passed at the existing CI thresholds.
  Existing Next.js image-element and Dockerfile lint warnings remain.
- DuckDB 1.5.5 read, filtered, and rewrote the GeoParquet fixture successfully:
  34,388 rows within the Israel rectangle.
- The isolated MinIO lifecycle test passed with the pinned images: failed-upload
  retention, successful-upload cleanup, overwrite protection, checksum rejection,
  preserved Parquet, catalog creation, viewer health, HTTP 206, and CORS.

## Native Israel results

The run reused 52 S3 source objects totaling 759,015,657 bytes. Before/after
inventories matched object keys, sizes, ETags, and modification times. The
previous publication manifest was unchanged. New outputs use a separate S3
prefix and validation directory.

Generation ran through native Windows PowerShell and Podman Desktop using the
existing rootful connection, with 24 GiB memory and 12 CPUs. The capacity estimate
passed before generation; the wrapper retained its 100 GiB host reserve.

| Result | Measurement |
|---|---:|
| Generation and verified publication | 321.457 seconds |
| Six archives combined | 729,469,586 bytes / 695.68 MiB |
| Additional sampled local occupancy peak | 732,954,624 bytes / 699 MiB |
| Archive hashes matching previous Israel run | 6 of 6 |
| Successful local PMTiles / generated Parquet remaining | 0 / 0 |
| Features rendered in native Chrome | 10,889 |
| Browser PMTiles HTTP 206 responses | 89 |
| Browser errors / failed requests / external requests | 0 / 0 / 0 |

Independent native Python checks verified complete remote SHA-256 contents,
sizes, bounds, expected layers/zooms, HTTP 206, and CORS for every archive.
Addresses is a valid 16,701-byte archive with zero tiles, consistent with the
empty source. Catalog generation used Node 24. Native Chrome configured all
six theme sources; its screenshot was visually checked. The test reused the
local test CA and a fresh browser context, without changing system trust.

## Reproduction and evidence

Candidate tags use `image-update-20260906` under
`localhost/overture-explorer-airgap`, `localhost/overture-tiles-airgap`, and
`localhost/overture-catalog-node`. The tested final image IDs are:

- Viewer: `7c3606da4f8000513d9424ffecc2ecc050bf6454ae22040c7bc04acdfa004ad4`
- Generator: `294c1ccb5a0fa8e75b2b1be4e4eec7aa64ead0c040c1d86d852aa9f3208193f9`

Run `bash scripts/test-static.sh` under Node 24 and
`bash scripts/test-local-s3-generator.sh --viewer-port PORT` with candidate
`VIEWER_IMAGE` and `TILES_IMAGE` overrides. Native runs use
`scripts/windows-airgap.ps1` with separate state/scratch directories, a new
publication prefix, and matching catalog URL; run Generate with `-DryRun`
before Generate, then Viewer.

Logs, scan JSON, the summary, and the screenshot are retained locally under
`airgap-output/image-update-20260906/`. Native scripts, image archives, inventory
records, and output state are retained under
`D:/overture-validation/20260906-image-update/`. These machine-specific artifacts
are not tracked. Existing validation services and data were preserved; no images
were published to Artifactory or another registry.
