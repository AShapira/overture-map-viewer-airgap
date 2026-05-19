# GitHub and CI/CD Model

## Repository Model

This repo is a local airgap fork of `OvertureMaps/explore-site`. Keep the upstream remote for periodic syncs, but do not push this local repo unless explicitly requested.

Recommended branches:

- `main`: stable local integration branch
- `feature/*`: implementation branches
- `upstream-sync/*`: temporary branches for merging upstream viewer changes
- `release/*`: optional stabilization branches for internal airgap releases

Recommended tags:

- `airgap-vX.Y.Z` for a combined viewer/generator release
- or `viewer-vX.Y.Z` and `tiles-vX.Y.Z` if the two images are released independently

## CI Stages

Pull request CI should run:

```text
npm ci
npm run lint
npm test
npm run build
docker build -f Dockerfile.viewer -t overture-explorer-airgap:ci .
docker build airgap/tile-generator -t overture-tiles-airgap:ci
```

Release CI should add:

- container vulnerability scan
- SBOM generation
- image export as OCI or Docker tar archives
- checksum generation
- optional signing or provenance attestations

## Release Bundle

A practical airgap release bundle should contain:

```text
overture-explorer-airgap-vX.Y.Z.tar
overture-tiles-airgap-vX.Y.Z.tar
docker-compose.airgap.yml
viewer-config.example.json
docs/
SHA256SUMS.txt
```

The online CI environment builds the bundle. The airgapped environment only imports images and runs the documented commands.
