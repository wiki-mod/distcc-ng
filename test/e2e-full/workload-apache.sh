#!/usr/bin/env bash
#
# Apache httpd workload for the full bidirectional E2E test (issue #264) --
# NOT invoked by default. run-bidirectional-e2e.sh's WORKLOAD variable
# defaults to "samba" (the larger/more demanding real-world dependency
# surface, see docker/verify/Dockerfile's own sizing research); this script
# exists so switching to (or adding) Apache httpd as the workload is a
# one-line change (WORKLOAD=apache) rather than a rewrite -- and so the
# lighter, disabled-by-default weekly schedule (see
# .github/workflows/nightly-publish.yml's commented-out cron block) has a
# real, already-written script to use once that schedule is ever armed,
# without inventing one from scratch at that point.
#
# Same shape as workload-samba.sh: real tarball fetch + signature
# verification, a fresh per-leg extraction, a real distcc/pump-distributed
# build, and a real compiled-object count printed as the last stdout line.
#
# Usage: workload-apache.sh <mode: plain|pump> <src_dir>

set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

MODE="${1:?usage: workload-apache.sh <plain|pump> <src_dir>}"
SRC_DIR="${2:?usage: workload-apache.sh <plain|pump> <src_dir>}"

readonly HTTPD_VERSION="2.4.68"
readonly HTTPD_TARBALL_URL="https://downloads.apache.org/httpd/httpd-${HTTPD_VERSION}.tar.gz"
readonly HTTPD_SIG_URL="https://downloads.apache.org/httpd/httpd-${HTTPD_VERSION}.tar.gz.asc"
# The ASF's own httpd release-signing keys, published at this stable URL --
# same "project's own published key" bar as Samba's verification above (see
# doc/verification-checklist.md section 5).
readonly HTTPD_PUBKEY_URL="https://downloads.apache.org/httpd/KEYS"
readonly CACHE_DIR="/work/workload/httpd-cache"
readonly CACHE_MARKER="${CACHE_DIR}/.verified-ok"

if [ ! -f "${CACHE_MARKER}" ]; then
  echo "== Fetching and verifying real Apache httpd ${HTTPD_VERSION} release tarball (once, cached) ==" >&2
  fetch_and_verify_tarball "${HTTPD_TARBALL_URL}" "${HTTPD_SIG_URL}" "${HTTPD_PUBKEY_URL}" "${CACHE_DIR}"
  touch "${CACHE_MARKER}"
else
  echo "== Reusing already-verified Apache httpd ${HTTPD_VERSION} tarball ==" >&2
fi

rm -rf "${SRC_DIR}"
mkdir -p "$(dirname "${SRC_DIR}")"
cp "${CACHE_DIR}/httpd-${HTTPD_VERSION}.tar" "/tmp/httpd-leg-$$.tar"
mkdir -p "${SRC_DIR}"
tar xf "/tmp/httpd-leg-$$.tar" -C "${SRC_DIR}" --strip-components=1
rm -f "/tmp/httpd-leg-$$.tar"

CC_DISTCC="distcc gcc"

cd "${SRC_DIR}"
# Configure with the container's own real, local gcc, deliberately NOT
# distcc -- unlike Samba's waf-based build (see workload-samba.sh's own,
# more detailed comment on why *that* build needs CC=distcc from configure
# time onward), Apache httpd's autoconf-generated Makefile only assigns
# `CC = ...` once at the top; a `make CC="distcc gcc" ...` COMMAND-LINE
# variable assignment (not just an exported environment variable, which a
# plain `CC = ...` makefile line would still override) always wins over
# that per GNU Make's own semantics, so the build step below can switch to
# distcc without needing configure itself to have used it. This also
# sidesteps needing the same "temporarily allow fallback during configure"
# workaround workload-samba.sh needs for its own autoconf-style probing.
echo "== Configuring real Apache httpd ${HTTPD_VERSION} source (local compiler) ==" >&2
./configure >configure.log 2>&1 || {
  echo "::error::Apache httpd ./configure failed -- see configure.log" >&2
  tail -n 100 configure.log >&2
  exit 1
}

echo "== Building real Apache httpd ${HTTPD_VERSION} source, mode=${MODE}, DISTCC_HOSTS=${DISTCC_HOSTS:-<unset>} ==" >&2
export DISTCC_FALLBACK=0
if [ "${MODE}" = "pump" ]; then
  run_pump_build make -j"$(nproc)" CC="${CC_DISTCC}"
else
  make -j"$(nproc)" CC="${CC_DISTCC}"
fi

# Same rationale as workload-samba.sh's identical final line: the real
# compiled-object count from this build, computed before the server log is
# consulted.
find . -name '*.o' -o -name '*.lo' | wc -l
