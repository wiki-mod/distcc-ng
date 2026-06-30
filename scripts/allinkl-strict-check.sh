#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
readonly JOBS="${JOBS:-2}"
readonly PYTHON_BIN="${PYTHON_BIN:-python3.13}"

log() {
  printf '[allinkl-strict] %s\n' "$*"
}

fail() {
  printf '[allinkl-strict] ERROR: %s\n' "$*" >&2
  exit 1
}

run_logged() {
  local name="$1"
  shift

  local log_file
  log_file="$(mktemp "${TMPDIR:-/tmp}/distcc-ng-${name}.XXXXXX.log")"

  log "running ${name}: $*"
  if ! "$@" >"${log_file}" 2>&1; then
    cat "${log_file}" >&2
    rm -f "${log_file}"
    fail "${name} failed"
  fi

  if grep -E '(^|[^[:alpha:]])([Ww]arning|WARNING)(:|[[:space:]]|$)' "${log_file}" >/dev/null; then
    cat "${log_file}" >&2
    rm -f "${log_file}"
    fail "${name} emitted a warning"
  fi

  rm -f "${log_file}"
  log "passed ${name}"
}

run_capture_allow_output_check() {
  local name="$1"
  local expected="$2"
  shift 2

  local log_file
  log_file="$(mktemp "${TMPDIR:-/tmp}/distcc-ng-${name}.XXXXXX.log")"

  log "running ${name}: $*"
  if ! "$@" >"${log_file}" 2>&1; then
    cat "${log_file}" >&2
    rm -f "${log_file}"
    fail "${name} failed"
  fi

  if ! grep -F -- "${expected}" "${log_file}" >/dev/null; then
    cat "${log_file}" >&2
    rm -f "${log_file}"
    fail "${name} did not emit expected text: ${expected}"
  fi

  rm -f "${log_file}"
  log "passed ${name}"
}

main() {
  cd "${ROOT_DIR}"

  if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    fail "required Python interpreter not found: ${PYTHON_BIN}"
  fi

  run_logged autogen ./autogen.sh
  run_logged configure-zstd ./configure PYTHON="${PYTHON_BIN}" --with-zstd --enable-Werror
  run_logged build-zstd make "-j${JOBS}"
  run_logged maintainer-zstd make TESTDISTCC_OPTS=--zstd distcc-maintainer-check
  run_logged check-zstd make check
  run_logged dist make dist

  run_logged configure-no-zstd ./configure PYTHON="${PYTHON_BIN}" --without-zstd --enable-Werror
  run_logged build-no-zstd make "-j${JOBS}"
  run_capture_allow_output_check no-zstd-host-option \
    'zstd support not built' \
    env DISTCC_HOSTS=localhost,zstd ./distcc --show-hosts

  log "all strict checks passed"
}

main "$@"
