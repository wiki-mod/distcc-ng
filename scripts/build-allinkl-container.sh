#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
GIT_COMMIT="$(git -C "${ROOT_DIR}" rev-parse --short=12 HEAD)"
readonly GIT_COMMIT
readonly IMAGE_TAG="${IMAGE_TAG:-distcc-ng:allinkl-${GIT_COMMIT}}"
readonly VERSION_LABEL="${VERSION_LABEL:-allinkl-${GIT_COMMIT}}"

log() {
  printf '[allinkl-container] %s\n' "$*"
}

main() {
  cd "${ROOT_DIR}"

  local log_file
  log_file="$(mktemp "${TMPDIR:-/tmp}/distcc-ng-container.XXXXXX.log")"

  log "building ${IMAGE_TAG}"
  if ! DOCKER_BUILDKIT=1 docker build \
      --file docker/allinkl/Dockerfile \
      --build-arg "VCS_REF=${GIT_COMMIT}" \
      --build-arg "VERSION=${VERSION_LABEL}" \
      --tag "${IMAGE_TAG}" \
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

  log "built ${IMAGE_TAG}"
}

main "$@"
