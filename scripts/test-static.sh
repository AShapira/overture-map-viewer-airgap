#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_rootless_podman
require_command npm
require_command rg
podman_compose_bin >/dev/null

printf 'Checking Bash syntax...\n'
while IFS= read -r script; do
  bash -n "$script"
done < <(find "$REPO_ROOT/scripts" "$REPO_ROOT/airgap" -type f -name '*.sh' -print)

printf 'Validating Podman Compose files...\n'
"$(podman_compose_bin)" -f "$AIRGAP_COMPOSE_FILE" config >/dev/null
"$(podman_compose_bin)" -f "$LOCAL_S3_COMPOSE_FILE" config >/dev/null

printf 'Checking for unsupported local tooling...\n'
if find "$REPO_ROOT/scripts" -type f \( -name '*.ps1' -o -name '*.bat' -o -name '*.cmd' \) -print -quit | grep -q .; then
  find "$REPO_ROOT/scripts" -type f \( -name '*.ps1' -o -name '*.bat' -o -name '*.cmd' \) -print >&2
  die "Windows operator scripts remain tracked."
fi

runtime_paths=(
  "$REPO_ROOT/README.md"
  "$REPO_ROOT/docs/airgap-design.md"
  "$REPO_ROOT/docs/airgap-s3-runbook.md"
  "$REPO_ROOT/scripts"
  "$REPO_ROOT/compose.airgap.yml"
  "$REPO_ROOT/compose.local-s3.yml"
)

if rg -n -i -g '!test-static.sh' 'powershell|\.ps1\b|docker[[:space:]]+(build|compose|images|load|run|save)' "${runtime_paths[@]}"; then
  die "Unsupported Windows/Docker local-runtime instructions remain."
fi

if rg -n -g '!test-static.sh' '(^|[^[:alpha:]])[A-Za-z]:\\|\\(scripts|airgap-output|public)\\' "${runtime_paths[@]}"; then
  die "Windows paths remain in the supported local-runtime material."
fi

printf 'Running npm lint...\n'
(cd "$REPO_ROOT" && npm run lint)

printf 'Running Jest tests...\n'
(cd "$REPO_ROOT" && npm test -- --runInBand)

printf 'Building the static viewer...\n'
(cd "$REPO_ROOT" && npm run build)

printf 'Running browser accessibility checks...\n'
(cd "$REPO_ROOT" && npm run test:a11y)

printf 'Static validation passed.\n'
