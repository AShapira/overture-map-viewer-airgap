# Windows Podman Desktop air-gap runbook

Run from a native Windows checkout in PowerShell. Podman Desktop owns a WSL2
Podman machine; the operator workflow does not invoke a separate RHEL/Ubuntu
distribution. Existing RHEL development workflows remain available.

## Prepare the disconnected workstation

Install Podman Desktop/Podman with WSL2 enabled during workstation provisioning.
Prepare the machine OS image and installers before disconnection. Preserve the
operator-selected rootful/rootless connection; the wrapper reports it and does
not switch it. Check `podman machine list`, `podman system connection list`, and
`podman info` before allocating processing storage. WSL machine-list resource
values can differ from actual engine memory/CPU: inspect `podman info`.

Follow the upstream [Windows installation prerequisites](https://podman-desktop.io/docs/installation/windows-install).
Keep enough host space for the WSL2 machine's dynamically growing virtual disk,
images and swap in addition to the processing bind. Set machine resources during
provisioning; the wrappers do not resize or recreate an existing machine.

Install native Python and a dedicated `podman-compose` virtual environment.
Prepare a wheelhouse online and transfer it with the installers:

```powershell
py -m pip download --dest wheelhouse podman-compose==1.6.0
```

On the offline workstation:

```powershell
py -m venv D:\overture-tools
D:\overture-tools\Scripts\python.exe -m pip install --no-index --find-links .\wheelhouse podman-compose==1.6.0
$env:PODMAN_COMPOSE_PROVIDER = 'D:\overture-tools\Scripts\podman-compose.exe'
```

The provider's `python.exe` must be alongside `podman-compose.exe`; its bundled
PyYAML parses the rendered Compose model. The wrapper refuses any other provider.
Explicit provider selection is required because [Podman gives docker-compose
precedence when both providers are installed](https://docs.podman.io/en/latest/markdown/podman-compose.1.html).
The Windows Compose model also sets `x-podman.in_pod: false` explicitly.

Import the generator, viewer, and Node catalog images:

```powershell
podman load -i .\overture-generator.tar
podman load -i .\overture-viewer.tar
podman load -i .\node-catalog.tar
```

Alternatively pull approved digest-pinned images from internal Artifactory
before starting the job. Use `podman login <internal-registry>` interactively.
Compose uses `pull_policy: never`; image absence fails preflight.

For the catalog runtime, mirror the same Node 24 image used by the viewer build:
`docker.io/library/node:24.20.0-alpine3.24@sha256:e67514e5d0f6c46656005e1b693b2ec9d52e80b641307de684d4a015ba7a4eaf`.
Set `CATALOG_IMAGE` to its verified internal Artifactory digest after mirroring.

## Configure

Create Git-ignored `.env.windows-airgap`; it contains S3 credentials and must be
protected using workstation access controls. Only the generator receives this
file. Do not paste rendered Compose configuration into tickets or logs.

```dotenv
VIEWER_IMAGE=artifactory.internal/overture/viewer@sha256:REPLACE
TILES_IMAGE=artifactory.internal/overture/generator@sha256:REPLACE
CATALOG_IMAGE=artifactory.internal/library/node@sha256:REPLACE
OVERTURE_RELEASE=2026-07-22.0
THEMES=base,buildings,places,divisions,transportation,addresses
BBOX=34.2,29.4,35.9,33.4
S3_BUCKET=overture
SOURCE_RELEASE_PREFIX=release
PMTILES_RELEASE_PREFIX=pmtiles/runs/REPLACE_WITH_NEW_RUN_ID
S3_ENDPOINT_URL=https://s3.internal
S3_REGION=us-east-1
AWS_ACCESS_KEY_ID=REPLACE
AWS_SECRET_ACCESS_KEY='REPLACE'
S3_TRUST_DIR=D:/overture-trust
AWS_CA_BUNDLE=/trust/ca.crt
JAVA_TOOL_OPTIONS=-Djavax.net.ssl.trustStore=/trust/truststore.jks -Djavax.net.ssl.trustStorePassword=changeit
PMTILES_HTTP_BASE=https://s3-gateway.internal/overture/pmtiles/runs/REPLACE_WITH_NEW_RUN_ID/2026-07-22.0/
PMTILES_SCRATCH_DIR="D:/overture-processing/scratch with spaces"
OUTPUT_DIR=D:/overture-processing/state
PMTILES_MIN_FREE_GB=100
PMTILES_MAX_SCRATCH_GB=350
PMTILES_MAX_LOCAL_GB=400
PRESERVE_PARQUET=false
PLANETILER_COMPRESS_TEMP=true
PLANETILER_MMAP_TEMP=false
PLANETILER_SORT_MAX_READERS=1
PLANETILER_SORT_MAX_WRITERS=1
PLANETILER_THREADS=12
GENERATOR_MEMORY=24g
GENERATOR_CPUS=12
VIEWER_PORT=8088
DOWNLOAD_MIN_ZOOM=15
```

Limits above are examples for a spacious D: drive; use the README estimator and
actual available space for your site. `PMTILES_MAX_LOCAL_GB` includes the scratch
and state directories, deduplicating overlaps. GeoParquet preservation is opt-in
and consumes durable local space. A fresh destination prefix prevents accidental
overwriting of an existing map. Changing BBOX requires a distinct publication
prefix and matching `PMTILES_HTTP_BASE`.

Prepare directories, including the trust directory. For publicly trusted TLS,
the trust directory may be empty and `AWS_CA_BUNDLE`/`JAVA_TOOL_OPTIONS` omitted.
For an internal CA, put the PEM certificate in `ca.crt` and import it into a
Java truststore using the generator image's `keytool`, with an explicit store
password. This truststore contains public CA certificates, not client private
keys. Keep TLS verification enabled. Registry trust inside the Podman machine,
generator S3 trust, and browser gateway trust are separate configurations.

For example, create the generator truststore with a preloaded generator image:

```powershell
podman run --rm --pull=never --mount 'type=bind,source=D:/overture-trust,target=/trust' --entrypoint keytool $GeneratorImage -importcert -noprompt -alias internal-s3 -file /trust/ca.crt -keystore /trust/truststore.jks -storepass changeit
```

Set `$GeneratorImage` to the imported image reference first. The `changeit`
password above protects a store containing public trust anchors; specify it in
`JAVA_TOOL_OPTIONS` as shown. Provision registry CA trust inside the selected
machine and browser trust through the site's normal certificate process.

## Run

```powershell
.\scripts\windows-airgap.ps1 -Action Preflight
.\scripts\windows-airgap.ps1 -Action Generate -DryRun -Report /output/israel-estimate.json
.\scripts\windows-airgap.ps1 -Action Generate -EstimatePilot -Report /output/israel-calibration.json
.\scripts\windows-airgap.ps1 -Action Generate -DryRun -Calibration /output/israel-calibration.json -Report /output/israel-estimate-calibrated.json
.\scripts\windows-airgap.ps1 -Action Generate
.\scripts\windows-airgap.ps1 -Action Viewer
```

Use `-Action Catalog` to generate only the catalog/config. Use `-EnvFile` for an
alternate protected env file and `-ProjectName` to isolate deployments. Use
`-ComposeOverride path.yml` for site-specific
networking or mounts. Overrides are rendered and checked by the same preflight.
For an existing Windows GeoParquet release, use a read-only source override:

```yaml
# compose.mounted-source.yml
services:
  tiles-generator:
    environment:
      SOURCE_PATH: /input/release
    volumes:
      - type: bind
        source: "D:/Overture source/release/2026-07-22.0"
        target: /input/release
        read_only: true
```

Pass `-ComposeOverride compose.mounted-source.yml` to estimation and generation.
Planetiler reads these original files with the configured bounds; publication
still uses the configured S3 destination.

Report and calibration paths are **container paths** inside configured mounts. Dry-run
requires a new report filename and never replaces publication state. The pilot
generates only bounded samples and publishes nothing; default pilot scratch is
5 GiB per theme, adjustable with `PMTILES_PILOT_MAX_GB`.

The wrapper monitors C: and D: and stops only its named generator if either
crosses `-HostReserveGiB` (default 100). Configure `-MonitorDrives` for other
installations. The container separately monitors all processing/output
filesystems. Local S3 data must also fit its physical host disk; its apparent
bucket capacity is not additional workstation storage.

Catalog/viewer containers use no S3 credentials. The browser gateway must allow
read-only HTTPS access, CORS from the viewer origin, and HTTP 206 byte ranges.
Check reachability from native Windows, not only from a WSL shell. If localhost
forwarding is unavailable, use a reachable Podman-machine address or a site
gateway and configure `PMTILES_HTTP_BASE` accordingly. Machine addresses can
change after restart; production gateways need stable DNS and trusted TLS.

## Migration and failures

The current Compose file uses explicit host binds for state instead of previous
named volumes. Existing named volumes are left intact. Copy only required old
catalog/config/optional download data into the new state directory when retaining
an old deployment; do not bulk-copy the source release into processing storage.

Success leaves small catalog/publication/config files and optional explicitly
preserved GeoParquet locally. Completed archives survive failed uploads or
checksum verification in a unique run directory; see `latest-failure.json`.
Repair connectivity and explicitly publish/verify that archive, or use a fresh
run prefix. Later runs account for retained files and do not delete them.

Do not delete prior volumes, source files, unrelated images, or existing evidence
to make a test fit. Reconfigure capacity or use a smaller BBOX instead. The
README explains source, transient, final, local S3, and VHDX storage separately.
