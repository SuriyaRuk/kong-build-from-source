#!/usr/bin/env bash
# =============================================================================
#  build.sh
#  Build the Kong RPM-based image (multi-arch) from the prebuilt .rpm packages
#  in output/ and push it to Docker Hub.
#
#  Inputs (output/):
#    kong-3.9.2-openresty1.31.1.1.amd64.rpm
#    kong-3.9.2-openresty1.31.1.1.arm64.rpm
#
#  Result:
#    docker.io/suriyaruk/kong-build-from-source:3.9.2-1.31.1.1-rpm
#
#  Usage:
#    ./build.sh                       # build + push multi-arch (amd64,arm64)
#    IMAGE=myrepo/kong:tag ./build.sh # override image name:tag
#    PUSH=false ./build.sh            # build only the host arch, load locally
# =============================================================================
set -euo pipefail

# ─── Config (override via env) ───────────────────────────────────────────────
KONG_VERSION="${KONG_VERSION:-3.9.2}"
RESTY_VERSION="${RESTY_VERSION:-1.31.1.1}"
IMAGE="${IMAGE:-suriyaruk/kong-oss-3.9.2-patch:${KONG_VERSION}-${RESTY_VERSION}-rpm}"
DOCKERFILE="${DOCKERFILE:-Dockerfile.rpm}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
PUSH="${PUSH:-true}"
BUILDER="${BUILDER:-multiarch}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

log() { echo "[INFO]  $*"; }
err() { echo "[ERROR] $*" >&2; exit 1; }

# ─── 1. Pre-flight: required files ───────────────────────────────────────────
[ -f "${DOCKERFILE}" ] || err "Dockerfile not found: ${DOCKERFILE}"

for arch in amd64 arm64; do
  rpm="output/kong-${KONG_VERSION}-openresty${RESTY_VERSION}.${arch}.rpm"
  [ -f "${rpm}" ] || err "Missing RPM: ${rpm} (run the RPM build scripts first)"
  log "Found ${rpm} ($(du -h "${rpm}" | cut -f1))"
done

# ─── 2. Ensure a multi-arch capable builder ──────────────────────────────────
# The default "docker" driver cannot do multi-platform --push builds; a
# docker-container builder is required for that.
if ! docker buildx inspect "${BUILDER}" >/dev/null 2>&1; then
  log "Creating buildx builder '${BUILDER}' ..."
  docker buildx create --name "${BUILDER}" --driver docker-container --bootstrap
fi

# ─── 3. Build (+ push) ───────────────────────────────────────────────────────
if [ "${PUSH}" = "true" ]; then
  log "Building ${IMAGE} for ${PLATFORMS} and pushing to Docker Hub ..."
  docker buildx build --builder "${BUILDER}" \
    --platform "${PLATFORMS}" \
    -f "${DOCKERFILE}" \
    -t "${IMAGE}" \
    --push \
    .
  log "Pushed: docker.io/${IMAGE}"
else
  log "Building ${IMAGE} for host arch only (PUSH=false) and loading locally ..."
  docker buildx build --builder "${BUILDER}" \
    -f "${DOCKERFILE}" \
    -t "${IMAGE}" \
    --load \
    .
  log "Loaded local image: ${IMAGE}"
fi

log "Done."
