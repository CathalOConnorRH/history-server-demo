#!/usr/bin/env bash
# Renders the manifests/*.yaml.tpl templates with envsubst and applies them,
# in order, to stand up the historyserver + kuberay-dashboard stack (and,
# optionally, a brand-new RayCluster pre-wired to report to it).
#
# Usage:
#   cp .env.example .env    # fill in your values first
#   ./scripts/install.sh              # historyserver + dashboard only
#   ./scripts/install.sh --with-raycluster   # also create a new RayCluster
#
# Requires: oc (or kubectl), envsubst (part of GNU gettext -- on macOS:
# `brew install gettext && brew link --force gettext`; on RHEL/Fedora:
# `dnf install gettext`; on Debian/Ubuntu: `apt install gettext-base`).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"
MANIFESTS_DIR="${ROOT_DIR}/manifests"

WITH_RAYCLUSTER=false
for arg in "$@"; do
  case "$arg" in
    --with-raycluster) WITH_RAYCLUSTER=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

command -v envsubst >/dev/null 2>&1 || {
  echo "Error: envsubst not found. See the comment at the top of this script for how to install it." >&2
  exit 1
}

CLI="oc"
command -v oc >/dev/null 2>&1 || CLI="kubectl"
command -v "$CLI" >/dev/null 2>&1 || { echo "Error: neither oc nor kubectl found on PATH." >&2; exit 1; }

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Error: ${ENV_FILE} not found. Copy .env.example to .env and fill it in first." >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a; source "${ENV_FILE}"; set +a

required_vars=(NAMESPACE S3_SECRET_NAME S3_BUCKET S3_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY HISTORYSERVER_IMAGE DASHBOARD_IMAGE OAUTH_PROXY_IMAGE)
for v in "${required_vars[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo "Error: required variable '$v' is not set in ${ENV_FILE}" >&2
    exit 1
  fi
done

# Auto-generate a cookie secret for the OAuth proxy if not provided.
if [[ -z "${OAUTH_COOKIE_SECRET:-}" ]]; then
  OAUTH_COOKIE_SECRET=$(openssl rand -base64 32)
  echo "Note: generated OAUTH_COOKIE_SECRET (add to .env to persist across re-installs)"
fi
export OAUTH_COOKIE_SECRET

# Explicit variable list for envsubst so that shell variables embedded in
# templates (e.g. $id, $i in the RayCluster postStart lifecycle hook) are
# left untouched instead of being replaced with empty strings.
ENVSUBST_VARS='${NAMESPACE} ${S3_SECRET_NAME} ${S3_BUCKET} ${S3_REGION} ${S3_ENDPOINT} ${S3FORCE_PATH_STYLE} ${S3DISABLE_SSL} ${SSL_CERT_FILE} ${AWS_ACCESS_KEY_ID} ${AWS_SECRET_ACCESS_KEY} ${HISTORYSERVER_IMAGE} ${DASHBOARD_IMAGE} ${DASHBOARD_BASE_PATH} ${COLLECTOR_IMAGE} ${RAY_IMAGE} ${RAYCLUSTER_NAME} ${WORKER_REPLICAS} ${WORKER_MIN_REPLICAS} ${WORKER_MAX_REPLICAS} ${GATEWAY_NAME} ${GATEWAY_NAMESPACE} ${OAUTH_PROXY_IMAGE} ${OAUTH_COOKIE_SECRET}'

render_and_apply() {
  local tpl="$1"
  echo "--- Applying $(basename "$tpl") ---"
  envsubst "${ENVSUBST_VARS}" < "$tpl" | "$CLI" apply -f -
}

render_and_apply "${MANIFESTS_DIR}/00-namespace.yaml.tpl"
render_and_apply "${MANIFESTS_DIR}/01-secret-s3-credentials.yaml.tpl"
render_and_apply "${MANIFESTS_DIR}/02-historyserver.yaml.tpl"
render_and_apply "${MANIFESTS_DIR}/03-dashboard.yaml.tpl"

if [[ -f "${MANIFESTS_DIR}/04-dashboard-httproute.yaml.tpl" ]]; then
  render_and_apply "${MANIFESTS_DIR}/04-dashboard-httproute.yaml.tpl"
fi

if $WITH_RAYCLUSTER; then
  required_rc_vars=(RAYCLUSTER_NAME RAY_IMAGE COLLECTOR_IMAGE WORKER_REPLICAS WORKER_MIN_REPLICAS WORKER_MAX_REPLICAS)
  for v in "${required_rc_vars[@]}"; do
    if [[ -z "${!v:-}" ]]; then
      echo "Error: --with-raycluster requires '$v' to be set in ${ENV_FILE}" >&2
      exit 1
    fi
  done
  render_and_apply "${MANIFESTS_DIR}/05-raycluster-new.yaml.tpl"
fi

echo
echo "Done. Next:"
echo "  ${CLI} get pods -n ${NAMESPACE}"
echo "  ./scripts/verify.sh"
