#!/usr/bin/env bash
# Post-install smoke test: pod health, architecture, historyserver liveness/
# readiness, dashboard reachability, and (if present) RayCluster + collector
# status.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Error: ${ENV_FILE} not found." >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a; source "${ENV_FILE}"; set +a

CLI="oc"
command -v oc >/dev/null 2>&1 || CLI="kubectl"

fail=0
pass() { echo "  [OK]   $1"; }
bad()  { echo "  [FAIL] $1"; fail=1; }

echo "== Pods in ${NAMESPACE} =="
"$CLI" get pods -n "${NAMESPACE}"
echo

echo "== historyserver =="
HS_POD=$("$CLI" get pods -n "${NAMESPACE}" -l app=historyserver -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "${HS_POD}" ]]; then
  bad "no historyserver pod found"
else
  if "$CLI" exec -n "${NAMESPACE}" "${HS_POD}" -- true 2>/dev/null; then
    ARCH=$("$CLI" exec -n "${NAMESPACE}" "${HS_POD}" -- uname -m 2>/dev/null)
    [[ "$ARCH" == "x86_64" ]] && pass "historyserver arch: $ARCH" || bad "unexpected historyserver arch: $ARCH"

    LIVEZ=$("$CLI" exec -n "${NAMESPACE}" "${HS_POD}" -- curl -s http://localhost:8080/livez 2>/dev/null)
    [[ "$LIVEZ" == "ok" ]] && pass "/livez -> ok" || bad "/livez -> '$LIVEZ'"

    READZ=$("$CLI" exec -n "${NAMESPACE}" "${HS_POD}" -- curl -s http://localhost:8080/readz 2>/dev/null)
    [[ "$READZ" == "ok" ]] && pass "/readz -> ok" || bad "/readz -> '$READZ'"
  else
    bad "cannot exec into historyserver pod ${HS_POD} (not Running yet?)"
  fi
fi
echo

echo "== kuberay-dashboard =="
DASH_POD=$("$CLI" get pods -n "${NAMESPACE}" -l app=kuberay-dashboard -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "${DASH_POD}" ]]; then
  bad "no kuberay-dashboard pod found"
else
  STATUS=$("$CLI" get pod -n "${NAMESPACE}" "${DASH_POD}" -o jsonpath='{.status.phase}' 2>/dev/null)
  [[ "$STATUS" == "Running" ]] && pass "dashboard pod Running" || bad "dashboard pod phase: $STATUS"

  if "$CLI" exec -n "${NAMESPACE}" "${DASH_POD}" -- true 2>/dev/null; then
    HTTP_CODE=$("$CLI" exec -n "${NAMESPACE}" "${DASH_POD}" -- wget -qO- --server-response "http://localhost:3000${DASHBOARD_BASE_PATH}" 2>&1 | grep -o 'HTTP/[0-9.]* [0-9]*' | head -1)
    echo "  (dashboard self-check: ${HTTP_CODE:-no response})"
  fi
fi
echo

if [[ -n "${RAYCLUSTER_NAME:-}" ]]; then
  echo "== RayCluster ${RAYCLUSTER_NAME} =="
  if "$CLI" get raycluster "${RAYCLUSTER_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    "$CLI" get raycluster "${RAYCLUSTER_NAME}" -n "${NAMESPACE}"
    HEAD_POD=$("$CLI" get pods -n "${NAMESPACE}" -l "ray.io/cluster=${RAYCLUSTER_NAME},ray.io/node-type=head" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "${HEAD_POD}" ]]; then
      CONTAINERS=$("$CLI" get pod -n "${NAMESPACE}" "${HEAD_POD}" -o jsonpath='{.spec.containers[*].name}')
      [[ "$CONTAINERS" == *collector* ]] && pass "collector sidecar present in head pod ($CONTAINERS)" || bad "no collector container in head pod ($CONTAINERS)"
      ARCH=$("$CLI" exec -n "${NAMESPACE}" "${HEAD_POD}" -c collector -- uname -m 2>/dev/null)
      [[ "$ARCH" == "x86_64" ]] && pass "collector arch: $ARCH" || bad "unexpected collector arch: $ARCH"
    else
      bad "no head pod found for ${RAYCLUSTER_NAME}"
    fi
  else
    echo "  (not found -- skip if you haven't created it yet)"
  fi
  echo
fi

echo "== Routes =="
"$CLI" get route -n "${NAMESPACE}" 2>/dev/null

echo
if [[ "$fail" -eq 0 ]]; then
  echo "All checks passed."
else
  echo "One or more checks FAILED -- see [FAIL] lines above." >&2
fi
exit "$fail"
