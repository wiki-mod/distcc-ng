#!/usr/bin/env bash
#
# Runs inside the distcc-client container for the weekly master heartbeat.
# Clones ccache's own source -- a real third-party C/C++ CMake project, pinned
# to a released tag -- and builds it fully distributed to the distccd-server
# container. This is a heavier, more representative real-world validation than
# the distcc-ng self-compile: a larger external codebase exercised end to end.
# DISTCC_FALLBACK=0 (set in the compose file) makes a failed remote compile a
# hard error instead of a silent local rebuild, so a broken distribution path
# cannot pass as a green heartbeat.

set -euo pipefail

# Pinned to a released ccache tag rather than a moving branch, so the heartbeat
# validates distribution -- not whatever churn happens to be on ccache's HEAD.
# Read from the environment (set once, workflow-level, in
# master-heartbeat.yml) rather than duplicated as a second literal, so the
# diagnostic control build (test/e2e/control-build.sh) always builds the
# exact same ccache revision this script does.
readonly CCACHE_TAG="${CCACHE_HEARTBEAT_TAG:-v4.13.6}"
readonly SRC_DIR="/tmp/ccache-src"
readonly BUILD_DIR="/tmp/ccache-build"
JOBS="$(nproc)"

echo "== distcc client configuration =="
echo "DISTCC_HOSTS=${DISTCC_HOSTS}"
echo "DISTCC_FALLBACK=${DISTCC_FALLBACK:-<unset>}"
distcc --show-hosts || true
echo

echo "== Cloning ccache ${CCACHE_TAG} =="
rm -rf "${SRC_DIR}" "${BUILD_DIR}"
git clone --depth 1 --branch "${CCACHE_TAG}" \
  https://github.com/ccache/ccache "${SRC_DIR}"
echo

# CMAKE_<LANG>_COMPILER_LAUNCHER prepends `distcc` to every compile, so ccache's
# object files are built on the server; links and other non-compile steps run
# locally as usual (they are not distributed at all, so DISTCC_FALLBACK does not
# apply to them). The compilers resolve under /usr/bin, which distccd's
# whitelist accepts via its /usr/bin path exception (the cc/c++ names are in the
# masquerade dir created by update-distcc-symlinks). Tests are off to keep the
# build to pure library/binary compiles.
#
# -Wno-error=maybe-uninitialized -Wno-error=restrict: ccache's own build
# auto-enables "dev mode" (CCACHE_DEV_MODE, see its CMakeLists.txt) whenever
# it's built from a git checkout, which turns its own -Werror on by default.
# That surfaced two real GCC 12.2.0 (Debian bookworm) false positives:
# -Wmaybe-uninitialized in argprocessing.cpp (a deeply-inlined
# tl::expected/std::optional chain at -O3), and -Wrestrict in
# core/statistics.cpp (obviously-impossible offsets) -- confirmed via issue
# #263 to reproduce identically with a plain local compile
# (test/e2e/control-build.sh), i.e. entirely independent of distcc.
#
# Deliberately these two named -Wno-error flags, not a blanket
# -DWARNINGS_AS_ERRORS=OFF: this heartbeat's whole point is validating that
# distccd's remote compile of the *preprocessed* source behaves like a local
# one, and a real distcc-specific bug (e.g. something a .ii file's
# preprocessing changes) can manifest as a warning on a class this build
# doesn't otherwise expect to see -- turning off -Werror wholesale would
# silently swallow that class of bug instead of catching it. Only the two
# specific, diagnosed false positives above are silenced; every other
# warning in ccache's own build (including on the server side, where
# distccd actually runs this exact command) still fails the build.
echo "== Configuring ccache (CMake, distributed via distcc) =="
cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER_LAUNCHER=distcc \
  -DCMAKE_CXX_COMPILER_LAUNCHER=distcc \
  -DCMAKE_CXX_FLAGS="-Wno-error=maybe-uninitialized -Wno-error=restrict" \
  -DENABLE_TESTING=OFF
echo

echo "== Building ccache distributed =="
cmake --build "${BUILD_DIR}" -j"${JOBS}"
echo

echo "== Smoke check: distributed-built ccache runs =="
test -x "${BUILD_DIR}/ccache"
"${BUILD_DIR}/ccache" --version

echo
echo "ccache heartbeat build completed successfully"
