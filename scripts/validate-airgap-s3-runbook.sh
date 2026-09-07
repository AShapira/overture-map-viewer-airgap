#!/usr/bin/env bash
# The isolated S3 regression also exercises preserved downloads and viewer startup.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/test-local-s3-generator.sh" --viewer-port 8099 "$@"
