#!/usr/bin/env bash
# Builds the historyserver, collector, and kuberay-dashboard images from a
# `kuberay` source checkout and pushes them to the target registry.
#
# Usage:
#   KUBERAY_SRC=/path/to/kuberay REGISTRY=quay.io/<your-namespace> TAG=v1.0.0 ./build-and-push.sh
#
# Requires: podman (or docker -- set CONTAINER_TOOL=docker), and that you are
# already logged in to $REGISTRY (`podman login $REGISTRY`).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBERAY_SRC="${KUBERAY_SRC:?Set KUBERAY_SRC to the path of a kuberay git checkout}"
REGISTRY="${REGISTRY:?Set REGISTRY, e.g. quay.io/<your-namespace> or your-registry.example.com/ray}"
TAG="${TAG:-v1.0.0}"
CONTAINER_TOOL="${CONTAINER_TOOL:-podman}"
PLATFORM="${PLATFORM:-linux/amd64}"
NEXT_PUBLIC_BASE_PATH="${NEXT_PUBLIC_BASE_PATH:-/kuberay-dashboard}"

HISTORYSERVER_SRC="${KUBERAY_SRC}/historyserver"
DASHBOARD_SRC="${KUBERAY_SRC}/dashboard"

echo "== Building historyserver, collector (from ${HISTORYSERVER_SRC}) and dashboard (from ${DASHBOARD_SRC}) =="
echo "   Registry : ${REGISTRY}"
echo "   Tag      : ${TAG}"
echo "   Platform : ${PLATFORM}"
echo

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

###############################################################################
# historyserver
###############################################################################
echo "--- historyserver ---"
hs_ctx="${workdir}/historyserver-ctx"
mkdir -p "${hs_ctx}"
cp -R "${HISTORYSERVER_SRC}/cmd" "${hs_ctx}/cmd"
cp -R "${HISTORYSERVER_SRC}/pkg" "${hs_ctx}/pkg"
cp "${HISTORYSERVER_SRC}/go.mod" "${HISTORYSERVER_SRC}/go.sum" "${HISTORYSERVER_SRC}/Makefile" "${hs_ctx}/"
cp "${SCRIPT_DIR}/Dockerfile.historyserver" "${hs_ctx}/Dockerfile"

"${CONTAINER_TOOL}" build --platform="${PLATFORM}" \
  -t "${REGISTRY}/historyserver:${TAG}" \
  "${hs_ctx}"
"${CONTAINER_TOOL}" push "${REGISTRY}/historyserver:${TAG}"

###############################################################################
# collector
###############################################################################
echo "--- collector ---"
col_ctx="${workdir}/collector-ctx"
mkdir -p "${col_ctx}"
cp -R "${HISTORYSERVER_SRC}/cmd" "${col_ctx}/cmd"
cp -R "${HISTORYSERVER_SRC}/pkg" "${col_ctx}/pkg"
cp "${HISTORYSERVER_SRC}/go.mod" "${HISTORYSERVER_SRC}/go.sum" "${HISTORYSERVER_SRC}/Makefile" "${col_ctx}/"
cp "${SCRIPT_DIR}/Dockerfile.collector" "${col_ctx}/Dockerfile"

"${CONTAINER_TOOL}" build --platform="${PLATFORM}" \
  -t "${REGISTRY}/collector:${TAG}" \
  "${col_ctx}"
"${CONTAINER_TOOL}" push "${REGISTRY}/collector:${TAG}"

###############################################################################
# kuberay-dashboard
###############################################################################
echo "--- kuberay-dashboard ---"
# NOTE: the patch file's paths are "dashboard/...", so the copied source must
# live at "${workdir}/dashboard" for `patch -p0` to find them.
dash_ctx="${workdir}/dashboard"
cp -R "${DASHBOARD_SRC}" "${dash_ctx}"
# Apply the basePath patch against the copied dashboard source (not the
# original source checkout) so the build is reproducible without
# mutating KUBERAY_SRC.
( cd "${workdir}" && patch -p0 < "${SCRIPT_DIR}/dashboard-basepath.patch" )
cp "${SCRIPT_DIR}/Dockerfile.dashboard" "${dash_ctx}/Dockerfile"

"${CONTAINER_TOOL}" build --platform="${PLATFORM}" \
  --build-arg NEXT_PUBLIC_BASE_PATH="${NEXT_PUBLIC_BASE_PATH}" \
  -t "${REGISTRY}/kuberay-dashboard:${TAG}" \
  "${dash_ctx}"
"${CONTAINER_TOOL}" push "${REGISTRY}/kuberay-dashboard:${TAG}"

echo
echo "== Done. Images pushed: =="
echo "  ${REGISTRY}/historyserver:${TAG}"
echo "  ${REGISTRY}/collector:${TAG}"
echo "  ${REGISTRY}/kuberay-dashboard:${TAG}"
echo
echo "Set these in .env as HISTORYSERVER_IMAGE / COLLECTOR_IMAGE / DASHBOARD_IMAGE."
