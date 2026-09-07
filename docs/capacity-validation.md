# Capacity validation, 6 September 2026

Validation uses release `2026-07-22.0`: 974 unchanged GeoParquet files totaling
610,161,853,931 bytes (568.3 GiB). Source preparation reads that complete release
through a read-only RHEL bind and uploads genuine regional partitions to a
separate Windows Podman MinIO store. No whole-world tiles were generated.

## Environment and accounting

The isolated directory is `D:/overture-validation/20260906-podman-capacity/`.
Both regions use a `processing scratch` directory containing a space. Generation
runs through native Windows PowerShell, `podman-compose` 1.6.0 and the existing
rootful Podman Desktop WSL2 connection, with 24 GiB memory and 12 CPUs per job.
The selected connection was not changed. Every validation container uses
preloaded images; the generator needs no online package/extension installation.

The native wrapper monitors actual C: and D: free space and preserves a 100 GiB
reserve. The generator independently measures combined scratch/state occupancy,
with a 400 GiB combined ceiling and 350 GiB active-theme ceiling. Budget occupancy
uses max(logical length, reported allocation); allocated-byte increases are also
recorded. These sampled figures are not hard filesystem quotas.

Temporary test CA trust is mounted into generation containers. Producer and
native Python checks verify TLS and complete remote SHA-256 contents. The native
Chrome test uses a fresh profile allowing the temporary test certificate; no
workstation-wide certificate store was changed. This workstation does not
forward these Podman ports to Windows localhost: native tests reach the WSL2
machine's private IP. Production needs a stable, reachable gateway and trusted
certificate, as described in the Windows runbook.

## Israel

BBOX: `34.2,29.4,35.9,33.4`. All six themes passed archive/directory/payload
integrity, streamed remote SHA-256, expected bounds/layers, HTTP 206, CORS,
catalog creation and native Chrome rendering. Addresses is genuinely empty in
this region: its valid 16,701-byte PMTiles has zero tiles and no fabricated data.

Source preparation uploaded 52 verified partitions totaling 759,015,657 bytes
(723.85 MiB), with 65 MiB sampled staging peak, in 141.3 seconds. The bounded
six-theme pilot peaked at 84 MiB of additional occupancy. Its measured
coefficients supplied the predictions below.

| Theme | Predicted scratch expected / conservative MiB | Measured scratch peak MiB | Predicted archive MiB | Actual archive MiB | Generation + publication seconds |
|---|---:|---:|---:|---:|---:|
| base | 286.9 / 717.2 | 289.0 | 70.13 | 120.67 | 52.7 |
| buildings | 934.5 / 2336.4 | 571.0 | 257.93 | 234.88 | 83.0 |
| places | 180.3 / 450.8 | 139.0 | 49.22 | 52.09 | 43.5 |
| divisions | 103.2 / 258.0 | 66.0 | 15.25 | 16.14 | 29.4 |
| transportation | 861.6 / 2153.9 | 699.0 | 279.45 | 271.89 | 85.4 |
| addresses | 32.0 / 128.1 | 1.0 | 0.03 | 0.02 | 28.0 |

Generation and publication took 322.0 seconds (excluding the
separate metadata estimate, source preparation, catalog and browser checks).
The observed additional local peak was 699 MiB,
versus 934.5 MiB expected and
2336.4 MiB conservative.
The largest per-theme expected underestimate was base (286.9 versus 289 MiB);
the conservative range covered every observed peak. Archive prediction error
was largest for base; the complete Israel measurement is now included in the
checked-in prior, taking the larger ratio from pilot and complete generation.
Using `(actual / expected - 1) × 100`, local peak error was −25.2%; base's archive
error was +72.1%. These are comparisons against predictions recorded before
generation, without retrospectively replacing those predictions.

The six archives total 695.68 MiB; compressed
diagnostics total 32,821 bytes. Successful
local PMTiles and generated GeoParquet payloads are both zero. Explicit estimate
reports, publication/catalog/config JSON, screenshots and test logs remain as
validation evidence. No previous datasets or evidence were cleared.

Native Chrome rendered 10,889 features with all six
sources configured; 89 PMTiles responses returned HTTP 206. There
were no failed requests, external network requests, or JavaScript page errors.

## Middle East

BBOX: `24.0,22.0,64.0,43.0`. The preparation
gate rechecked all 974 source file identities and used the larger of Israel
pilot/full-run coefficients with the regional row-group metadata. It allowed
151.9 GiB of additional shared-disk occupancy, including conservative source
export, maximum processing scratch, and all new archives/diagnostics together.
Live free space already excluded retained Israel output and every existing
artifact. Headroom beyond the 100 GiB reserve was 340.2 GiB.

Source preparation completed in 2347.3 seconds, with a 129 MiB sampled staging
peak. It uploaded and verified 634 partitions, retaining the original schemas
and valid empty addresses type. No staging GeoParquet remained. Native host
monitoring recorded minimum free space of 571.0 GiB on D: and 751.9 GiB on C:.

| Theme | Regional rows | Source bytes | Partitions |
|---|---:|---:|---:|
| base | 10,451,843 | 4,497,522,273 | 76 |
| buildings | 85,873,662 | 8,609,191,535 | 357 |
| places | 3,196,628 | 368,230,438 | 14 |
| divisions | 294,145 | 171,466,197 | 8 |
| transportation | 41,494,538 | 4,228,465,330 | 178 |
| addresses | 0 | 3,371 | 1 |

After source preparation, the native metadata/capacity gate allowed 94.1 GiB
of additional shared-disk occupancy for conservative processing plus all new
archives/diagnostics. It still had 377.0 GiB headroom beyond the 100 GiB reserve.
Native generation and publication completed in 5054.6 seconds (84.24 minutes),
excluding source preparation, metadata estimates, catalog and browser checks.
All six archives passed producer integrity checks and full remote SHA-256
verification. Independent native Windows checks then repeated the complete
remote checksums and confirmed bounds, layers, HTTP 206, CORS and catalog output.

| Theme | Predicted scratch expected / conservative GiB | Measured scratch peak GiB | Predicted archive GiB | Actual archive GiB | Generation + validation + publication seconds |
|---|---:|---:|---:|---:|---:|
| base | 8.92 / 22.30 | 9.54 | 3.49 | 4.54 | 1089.1 |
| buildings | 21.72 / 54.30 | 12.94 | 6.20 | 5.47 | 1580.1 |
| places | 1.91 / 4.76 | 1.59 | 0.646 | 0.678 | 243.7 |
| divisions | 1.10 / 2.76 | 2.98 | 0.240 | 0.866 | 424.9 |
| transportation | 15.84 / 39.60 | 14.86 | 5.33 | 6.14 | 1694.2 |
| addresses | 0.031 / 0.125 | 0.001 | 32 KiB | 16,701 bytes | 22.6 |

The combined processing/output occupancy peaked at 15,941,500,928 bytes, with
15,940,452,352 bytes (14.8457 GiB) additional occupancy and the same reported
new allocation peak. Different sampled scans of a theme and its enclosing roots
can record slightly different peaks while files grow. Overall additional local
peak error was −31.7% against the original 21.72 GiB expected estimate.
The original 54.30 GiB conservative overall allowance covered the run.

Divisions was an important prediction miss: its archive was 260.4% larger than
expected and its scratch peak exceeded the original conservative estimate by
7.8%. The final priors take the larger ratios observed in the pilot and complete
regions, with a divisions planning factor of 4 instead of 2.5. A compatible
pilot retains that uncertainty floor. These changes do not replace the original
predictions in the table. The other archive errors were base +30.1%, buildings
−11.8%, places +5.0%, transportation +15.4%, and empty addresses −49.0% against
its minimum-size allowance.

The six archives total 18,996,276,420 bytes (17.6917 GiB), 11.3% above their
combined expected size. Compressed diagnostics total 65,219 bytes. Both regional
inputs and publications, including retained Israel objects, total 35.7253 GiB
of logical S3 data. Backend metadata/allocation and validation image archives
are separate costs. Successful local PMTiles and generated GeoParquet payloads
are zero; small publication/catalog/config files and explicitly requested
estimate reports remain.

Native generation recorded minimum host free space of 542.84 GiB on D: and
745.40 GiB on C:. The selected rootful connection and existing volumes were not
changed. A final check confirmed all 974 original source size/mtime identities
and Israel's publication checksum records were unchanged.

Native Chrome rendered Tehran at zoom 13 with 65,432 visible features and all
six sources configured. All 63 PMTiles responses returned HTTP 206 with CORS
for the actual viewer origin. There were zero failed requests, external network
requests, or JavaScript page errors; the screenshot was visually inspected.
A second zoom-14 check rendered 18,508 features and completed 99 HTTP 206
responses, including payload reads from all five nonempty themes. It also had
zero failed/external requests and page errors; its screenshot was inspected.

## Bounded baseline comparison

The Tel Aviv fixture BBOX was `34.75,32.03,34.85,32.13`. Baseline settings used a
schema-preserving filtered copy, uncompressed temporary features and mmap;
optimized settings read the original fixture with bounds and compressed temp
without mmap. Profiles, zooms and source attributes were unchanged. This tests
storage/filtering equivalence using the same schema; it does not reproduce the
legacy DuckDB helper's injected filesystem `filename` field.

All 197 occupied tile coordinates and every decoded MVT feature matched,
including geometry, properties, IDs, extent and layers, at every configured zoom.
Both address outputs were empty. Conservative scratch occupancy ranged from
1,778–1,818 MiB for the mmap baseline and 1–35 MiB for optimized generation.
The mmap figure includes logical sparse-file length; it is not a claim of that
much physical disk allocation. Reproduce with `scripts/compare-generator-storage.py`
inside the image and `node scripts/compare-pmtiles.mjs TEST_OUTPUT` afterward.

## Whole world: extrapolation only

The refined metadata estimate gives 697.6–1744.1 GiB additional local peak
and 617.6–1631.8 GiB additional S3 output/diagnostics after incorporating both
regional measurements. It does not fit
the workstation's 400 GiB processing budget. For a deployment retaining the
complete source in S3, add its 568.3 GiB and all older outputs. S3 quota/free space
is unknown. These ranges are extrapolations, not guaranteed bounds or confidence
intervals. Addresses has no nonempty measurement in either region and remains explicitly
uncalibrated; zero regional data is not interpreted as zero world usage.

The final metadata-only recheck used image
`f084a7fa22e55ea200baa96fe40684063ebac7b6283c5adefea5efae5aea2552`.
Its conservative local shortfall was 1344.4 GiB against the configured 400 GiB
combined limit, including existing report occupancy. This image adds readable
report details, refined estimates and write-path symlink guards, compared with
the Middle East generation image
`609c58635aa2f810e5d49afc7cbdc9e9e2b4c241bc38144cce742a6e8673e855`;
tile generation, archive validation, and publication logic are identical.

## Regression evidence

- 6 Java adapter/export tests, including schema/GeoParquet metadata and empty output.
- 25 Python estimator/lifecycle/capacity tests, including cancellation of a child
  process group, stale calibration, shared paths, report-write limits, checksum
  failures, retention across subsequent runs, redirected write paths, invalid
  coefficients, and the measured uncertainty floor for pilot calibration.
- Isolated real MinIO integration: write-denied publication retained two separate
  completed archives; a later successful run removed only its own archive.
  Deliberately wrong remote SHA-256 was rejected. Preserved Parquet, catalog,
  HTTP 206/CORS, and a RHEL viewer also passed.
- Native overlapping-bind dry-run counted one existing 8 MiB file exactly once.
  The viewer's GeoArrow WASM decoded 34,388 preserved ZSTD-compressed points and
  the genuine empty addresses GeoParquet without introducing placeholder data.
- 661 Jest tests, lint, static build, 4 browser accessibility tests, Bash/Compose
  checks and native PowerShell execution. Existing Next.js image-element lint
  warnings remain; no new application UI code was introduced.

Detailed JSON, native logs, screenshots and image archives are retained beneath
the isolated validation directory. Comparison archives and deliberately retained
failed-upload fixtures remain as separate test evidence; successful regional
production runs retain no local PMTiles. Commits, pushes, workstation software removal,
and whole-world production are outside this validation.
