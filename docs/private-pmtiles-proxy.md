# Private PMTiles through the viewer

The optional Node service lets the browser read PMTiles from a private
S3-compatible bucket through the viewer's existing origin:

```text
Browser → viewer:8080/pmtiles/<publication-id>/<theme>.pmtiles
        → pmtiles-proxy:8080 → private S3 endpoint
```

The browser and static viewer never receive S3 credentials. There is no new
login: anyone who can reach the viewer can read the published maps. Keep the
viewer inside the intended network boundary. CORS is a browser policy, not an
access-control mechanism. The proxy has no host port. Keep any existing site
HTTPS termination in front of the viewer; the proxy's HTTP hop stays on the
container network.

## Provision the reader

Create a separate S3 identity with this policy, replacing the bucket and exact
publication prefix. The prefix includes the release directory. Do not use the
generator's write credentials. HEAD uses the same GetObject permission; bucket
listing is unnecessary. If storage uses a customer-managed encryption key,
provide the corresponding read/decrypt permission through the site's existing
key policy as required by that backend.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject"],
    "Resource": ["arn:aws:s3:::overture/pmtiles/runs/israel-run-01/2026-07-22.0/*"]
  }]
}
```

Keep bucket anonymous access disabled. No browser CORS configuration is needed
on S3 itself: the browser only contacts the viewer.

Create a private `credentials.json` **outside the repository and output data
folders**, with this shape:

```json
{
  "accessKeyId": "REPLACE_WITH_READER_ACCESS_KEY",
  "secretAccessKey": "REPLACE_WITH_READER_SECRET_KEY"
}
```

An optional `sessionToken` supports temporary credentials. The service loads this
file explicitly at startup and never falls back to environment credentials or
instance metadata. Temporary credentials require operator-managed renewal and a
proxy restart. Do not put credentials in command arguments, catalogs, URLs,
viewer configuration or images. Limit file access using host ACLs. The container
runs as UID/GID 1000, which must be able to read its mounted file; on rootless
Linux check the UID mapping and grant the mapped identity read access, rather
than making the file world-readable. Native Windows mounts must likewise be
verified from the container. The preflight checks path existence; readiness
catches file permission or authentication failures.

## Configure and start

The generator and its publication manifest are unchanged. Use a unique
`PROXY_PUBLICATION_ID` for each dataset, including each region or rerun of the
same release. The service loads one manifest per instance and only serves its
listed themes. Its S3 URIs must exactly match the configured bucket and prefix.

Build the proxy during connected preparation:

```bash
podman build --format docker -t localhost/overture-pmtiles-proxy-airgap:local airgap/pmtiles-proxy
podman save -o overture-pmtiles-proxy.tar localhost/overture-pmtiles-proxy-airgap:local
```

Import the image offline with `podman load -i overture-pmtiles-proxy.tar`, or use
an approved digest-pinned internal registry image. Rebuild/import the viewer
image from this revision too; it includes the optional NGINX route include.
No package installation or external image pulls occur at runtime.

Add these values to your protected deployment environment file:

```dotenv
PROXY_IMAGE=localhost/overture-pmtiles-proxy-airgap:local
PROXY_PUBLICATION_ID=israel-run-01
PROXY_S3_BUCKET=overture
PROXY_S3_PREFIX=pmtiles/runs/israel-run-01/2026-07-22.0
PROXY_CREDENTIALS_PATH=/srv/overture-secrets/credentials.json
PROXY_MANIFEST_PATH=/srv/overture-state/publication/2026-07-22.0.json
S3_ENDPOINT_URL=https://s3.internal
S3_REGION=us-east-1
S3_TRUST_DIR=/srv/overture-trust
PROXY_CA_BUNDLE=/trust/ca.crt
PROXY_S3_FORCE_PATH_STYLE=true
PMTILES_HTTP_BASE=/pmtiles/israel-run-01/
```

For publicly trusted certificates, omit `PROXY_CA_BUNDLE`; the trust directory
can be empty. For a private CA, mount its PEM file and set the bundle path inside
the container as above. This uses Node's extra CA trust, independent of Java and
registry trust. Never disable certificate verification. Use HTTP only when the
site explicitly uses an internal HTTP S3 endpoint, such as the isolated test.

On Linux, generate the catalog using the existing catalog command with
`--tile-base /pmtiles/israel-run-01/`, then start with the shared override:

```bash
PODMAN_COMPOSE_PROVIDER="$(command -v podman-compose)" podman compose \
  --env-file .env.pmtiles-proxy \
  -f compose.airgap.yml -f compose.pmtiles-proxy.yml up -d viewer
```

The base Compose model still requires its existing generator variables during
interpolation. Include those values even when starting only the viewer. All
runtime images must already be available locally. For Linux, the existing base
viewer mounts `airgap-output/catalog`; generate the catalog there.

On native Windows, put the settings in `.env.windows-airgap`, using absolute
Windows paths for the three host mount directories/files, for example
`D:/overture-secrets/credentials.json`. Keep `PMTILES_HTTP_BASE` set as above even
with the catalog override, because the base model interpolates it first.

```powershell
$ProxyOverrides = @('compose.pmtiles-proxy.yml', 'compose.windows-pmtiles-proxy.yml')
.\scripts\windows-airgap.ps1 -Action Preflight -ComposeOverride $ProxyOverrides
.\scripts\windows-airgap.ps1 -Action Viewer -ComposeOverride $ProxyOverrides
```

The wrapper verifies the image and mount paths, generates the catalog, starts
a fresh proxy and checks its readiness before recreating the viewer. This also
reloads credentials and refreshes NGINX upstream address resolution. It preserves the
selected Podman connection. An initial proxy preflight requires a publication
manifest; generate tiles first without the proxy overrides when preparing a new
publication.

The shared override supplies long-form bind mounts for both platforms; the
Windows-specific override sets the catalog tile base. Default external-gateway
deployments continue to use the base Compose files without either override.

## HTTP contract and operation

- Full GET returns `200` and streams the archive. A single bounded, open-ended
  or suffix byte range returns `206`. HEAD ignores Range and returns full object
  metadata with no body. OPTIONS returns `204` for approved preflights.
- Malformed or multiple ranges return `400`; an unsatisfiable range returns
  `416` with `Content-Range: bytes */<size>`. Unknown routes return `404`,
  unsupported methods `405`. Queries and encoded path aliases are rejected.
- ETag and Last-Modified are preserved. `If-Match` and `If-None-Match` reach S3,
  including `412` and `304` outcomes. An S3 missing-object `404` is preserved;
  authentication/connection/backend errors return a sanitized `502` (or `504`
  on a pre-response timeout). Some S3 servers return `403` for missing objects
  without ListBucket permission; those become `502` without expanding IAM scope.
- Object sizes and range headers must match the immutable publication manifest.
  Whole-object content encoding is rejected. PMTiles' internal compression is
  supported; HTTP gzip/transformation is disabled.
- No archive cache or temporary archive files are created. Browser responses use
  `Cache-Control: private, max-age=3600`; error responses use `no-store`.
- Up to 64 active object reads are admitted per instance; excess reads return
  `503`. Connections time out after 5 seconds and stalled streams after 60
  seconds. Disconnects cancel upstream reads. Shutdown allows 10 seconds for
  active streams before cancellation. Container defaults: 1 CPU and 512 MiB.
- `/healthz` and `/readyz` are container-internal endpoints. Readiness HEAD-checks
  every manifest object against its expected size within 5 seconds. Container
  health uses readiness. Logs contain approved route, method, status, bytes,
  outcome and duration, never SDK error messages or request credentials.

Same-origin use requires no origin setting. For separate browser origins, set
`PROXY_CORS_ORIGINS=https://maps.internal,https://analysis.internal` (exact
origins, no wildcard or trailing slash). The proxy allows GET/HEAD/OPTIONS,
Range/If-Match/If-None-Match request headers and exposes ETag, Content-Range,
Content-Length, Accept-Ranges and Last-Modified, including on errors. It does
not use credentialed browser requests.

Rotate credentials by updating the protected file and recreating the proxy.
Recreate the viewer alongside it so NGINX resolves the new container address.
On Linux, use the same environment and Compose files with
`up -d --force-recreate pmtiles-proxy viewer`; on Windows, run the Viewer action
again with the proxy overrides. The catalog adds a revision to its latest-release link, so a page reload replaces
cached gateway URLs when the publication or tile base changes. Already-open
maps require a reload.

For rollback, regenerate the catalog with the previous external HTTP tile base,
then recreate the viewer using the base Compose files and remove the optional
proxy service. Do not make a private bucket public as a workaround.

## Validate

```bash
npm ci --prefix airgap/pmtiles-proxy --ignore-scripts
npm test --prefix airgap/pmtiles-proxy
PROXY_IMAGE=localhost/overture-pmtiles-proxy-airgap:local \
  node airgap/pmtiles-proxy/test/integration.mjs
```

The acceptance test requires the viewer/proxy images, the pinned MinIO server
and client images from `compose.local-s3.yml`, and installed Playwright Chromium.
It creates unique temporary containers and a network, denies anonymous reads,
uses a prefix-restricted reader, checks the real NGINX path, and renders a valid
small PMTiles fixture in the browser. It removes only its own containers and
network; it retains a screenshot/report in the printed temporary directory and
removes the temporary reader-credentials file. Storage exists only in the test
MinIO container and disappears with it.

Set `PROXY_TEST_TILES_DIR` to a directory with the six existing theme archives to
run Israel acceptance without regenerating tiles. This uploads those files to
the isolated test MinIO; allow enough free container storage for their combined
size. It does not alter source files or existing buckets. On native Windows run
the same Node test from a Windows checkout with `CONTAINER_ENGINE=podman.exe`,
using native Node and Playwright. If Windows cannot reach forwarded localhost
ports, set `PROXY_TEST_HOST` to the verified Podman-machine IP, as described in
the Windows runbook. This explicitly binds the fixture ports on the VM's external
interface; use it only on the intended test network. The test still needs working
container-to-container routing and DNS. A Windows deployment claim requires that
native run, not just Linux tests.
