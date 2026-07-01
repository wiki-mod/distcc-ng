#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
GIT_COMMIT="$(git -C "${ROOT_DIR}" rev-parse --short=12 HEAD)"
readonly GIT_COMMIT
if [ -z "${VERSION_LABEL:-}" ]; then
  VERSION_LABEL="$(git -C "${ROOT_DIR}" describe --tags --match "v*" --abbrev=0 2>/dev/null \
    | sed -E 's/^v//' \
    | sed -E 's/^([0-9]+(\.[0-9]+){0,2}).*$/\1/' \
    | head -n 1)"
  if [ -z "${VERSION_LABEL}" ]; then
    VERSION_LABEL="3.4.1"
  fi
fi
readonly VERSION_LABEL

IMAGE_TAG_PREFIX="${IMAGE_TAG_PREFIX:-${IMAGE_TAG:-distcc-ng-zstd:${VERSION_LABEL}}}"
readonly IMAGE_TAG_PREFIX
readonly BUILD_PUMP_VARIANTS="${BUILD_PUMP_VARIANTS:-with-pump nopump}"

log() {
  printf '[allinkl-container] %s\n' "$*"
}

build_variant() {
  local pump_variant="$1"
  local image_tag="${IMAGE_TAG_PREFIX}-${pump_variant}"
  local log_file
  log_file="$(mktemp "${TMPDIR:-/tmp}/distcc-ng-container.XXXXXX.log")"

  log "building ${image_tag} (pump ${pump_variant})"

  if ! DOCKER_BUILDKIT=1 docker build \
      --file docker/allinkl/Dockerfile \
      --build-arg "VCS_REF=${GIT_COMMIT}" \
      --build-arg "VERSION=${VERSION_LABEL}" \
      --build-arg "PUMP_VARIANT=${pump_variant}" \
      --tag "${image_tag}" \
      . >"${log_file}" 2>&1; then
    cat "${log_file}" >&2
    rm -f "${log_file}"
    return 1
  fi

  if grep -E '(^|[^[:alpha:]])([Ww]arning|WARNING)(:|[[:space:]]|$)' "${log_file}" >/dev/null; then
    cat "${log_file}" >&2
    rm -f "${log_file}"
    printf '[allinkl-container] ERROR: docker build emitted a warning\n' >&2
    return 1
  fi

  rm -f "${log_file}"
  log "built ${image_tag} (pump ${pump_variant})"
}

main() {
  cd "${ROOT_DIR}"

  for pump_variant in ${BUILD_PUMP_VARIANTS}; do
    build_variant "${pump_variant}"
  done
}

main "$@"
