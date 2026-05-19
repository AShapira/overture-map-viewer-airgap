# GitHub and CI/CD Model

## Repository Model

This repo is the public airgap fork of `OvertureMaps/explore-site`.

Expected remotes:

```text
origin   https://github.com/AShapira/overture-map-viewer-airgap.git
upstream https://github.com/OvertureMaps/explore-site.git
```

`origin` is the publish target. `upstream` is read-only and is used only to fetch
new Overture Explorer changes.

Recommended branches:

- `main`: stable airgap product branch
- `feature/*`: implementation branches
- `upstream-sync/*`: temporary branches for merging upstream viewer changes
- `release/*`: optional stabilization branches for internal releases

Recommended release tags:

- `airgap-vX.Y.Z` for a combined viewer/generator release

## CI/CD Flow

The airgap workflow lives in `.github/workflows/airgap-ci.yml`.

Pull requests to `main` run:

```text
npm ci --ignore-scripts
npm run postinstall
npm run lint
npm test -- --runInBand
npm run build
browser smoke test with no external requests
build viewer image
build tile generator image
run hardened viewer smoke test
Trivy image scans
SBOM generation
Hadolint Dockerfile checks
Gitleaks secret scan
```

Pushes to `main` run the same checks and publish development images.

Tags matching `airgap-v*` run the same checks and publish release-tagged images.

## Image Hosting

Images are hosted in GitHub Container Registry:

```text
ghcr.io/ashapira/overture-explorer-airgap
ghcr.io/ashapira/overture-tiles-airgap
```

Published tags:

- `main` for the current `main` branch
- `sha-<short-sha>` for every pushed commit
- `airgap-vX.Y.Z` for release tags

The workflow does not create Docker tar files, OCI archives, checksums, or GitHub
release bundles. Import into the airgapped artifact registry is handled by an
external tool that consumes GHCR images.

## Safety Gates

The CI workflow applies these gates before publishing images:

- application lint, tests, and production static build
- browser smoke test that fails on external network requests
- Docker build for both images
- hardened viewer container smoke test with read-only filesystem, non-root user,
  dropped Linux capabilities, and `no-new-privileges`
- static serving checks for `/`, config, catalog, PMTiles, and parquet paths
- Trivy HIGH/CRITICAL image vulnerability scans with unfixed issues ignored
- SBOM generation for both images, uploaded as workflow artifacts
- Hadolint Dockerfile checks
- Gitleaks secret scan

## Upstream Sync Workflow

Import upstream Overture changes through a branch and pull request:

```powershell
git fetch upstream
git switch -c upstream-sync/YYYY-MM-DD
git merge upstream/main
```

Resolve conflicts, run local checks, then push the sync branch:

```powershell
git push -u origin upstream-sync/YYYY-MM-DD
```

Open a PR from `upstream-sync/YYYY-MM-DD` into `main` in this fork. Use merge
commits rather than rebase so the repository history clearly records when
upstream Overture changes were imported.

Common conflict areas:

- `components/nav/*`
- `components/MapView.jsx`
- `lib/stacService.js`
- `lib/viewerConfig.js`
- `app/layout.jsx`
- `package.json` and `package-lock.json`
- `.github/workflows/*`
