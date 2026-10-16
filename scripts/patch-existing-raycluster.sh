#!/usr/bin/env bash
# Thin wrapper around patch-existing-raycluster.py that reads the same
# .env file used by install.sh, so you don't have to repeat
# S3_BUCKET/S3_REGION/etc. on the command line.
#
# Usage:
#   ./patch-existing-raycluster.sh RAYCLUSTER_NAME RAYCLUSTER_NAMESPACE [--apply]
#
# Example (dry run):
#   ./patch-existing-raycluster.sh raycluster-prod ray-prod
# Example (apply for real):
#   ./patch-existing-raycluster.sh raycluster-prod ray-prod --apply
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/../.env}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Error: ${ENV_FILE} not found. Copy .env.example to .env and fill it in first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${ENV_FILE}"

RC_NAME="${1:?Usage: $0 <raycluster-name> <raycluster-namespace> [--apply]}"
RC_NAMESPACE="${2:?Usage: $0 <raycluster-name> <raycluster-namespace> [--apply]}"
shift 2 || true

python3 "${SCRIPT_DIR}/patch-existing-raycluster.py" \
  --name "${RC_NAME}" \
  --namespace "${RC_NAMESPACE}" \
  --s3-bucket "${S3_BUCKET}" \
  --s3-region "${S3_REGION}" \
  --s3-endpoint "${S3_ENDPOINT:-}" \
  --s3-force-path-style "${S3FORCE_PATH_STYLE:-false}" \
  --s3-disable-ssl "${S3DISABLE_SSL:-false}" \
  --ssl-cert-file "${SSL_CERT_FILE:-}" \
  --s3-secret-name "${S3_SECRET_NAME}" \
  --collector-image "${COLLECTOR_IMAGE}" \
  "$@"
