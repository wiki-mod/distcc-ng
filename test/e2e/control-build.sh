#!/usr/bin/env bash
#
# Diagnostic-only control build for the weekly ccache heartbeat (see
# .github/workflows/master-heartbeat.yml's ccache_control_build job and issue
# #263, where a real ccache_heartbeat failure took real effort to trace back
# to a compiler-version problem rather than a distcc-ng bug). Builds the same
# pinned ccache source directly with this image's plain compiler -- no
# distcc, no distccd, no network hop, nothing distributed at all. Runs inside
# the exact same distcc-ng-e2e image the heartbeat's own containers use, so
# the compiler/toolchain version is identical and the launcher is the only
# variable that differs from that build.
#
# This script's outcome is diagnostic evidence only and must never substitute
# for ccache_heartbeat's own pass/fail: a failure here means ccache's own
# source does not build with this compiler at all, so a same-run
# ccache_heartbeat failure is very likely a compiler/toolchain/ccache-version
# problem rather than a distcc-ng distribution bug -- it does not mean
# ccache_heartbeat's own result should be ignored or overridden.

set -euo pipefail

# Same tag client-heartbeat.sh builds, read from the same environment
# variable so both scripts stay in lockstep instead of duplicating the
# literal tag in two places.
readonly CCACHE_TAG="${CCACHE_HEARTBEAT_TAG:-v4.13.6}"
readonly SRC_DIR="/tmp/ccache-control-src"
readonly BUILD_DIR="/tmp/ccache-control-build"
JOBS="$(nproc)"

echo "== Control build: plain compiler, distcc/distccd out of the loop entirely =="
echo

echo "== Cloning ccache ${CCACHE_TAG} =="
rm -rf "${SRC_DIR}" "${BUILD_DIR}"
git clone --depth 1 --branch "${CCACHE_TAG}" \
  https://github.com/ccache/ccache "${SRC_DIR}"
echo

# Deliberately no CMAKE_<LANG>_COMPILER_LAUNCHER: cmake invokes the plain
# system compiler directly on this same image, so the launcher is the only
# variable versus client-heartbeat.sh's distributed build.
#
# -DWARNINGS_AS_ERRORS=OFF: see the matching flag in client-heartbeat.sh --
# this control build must use the exact same flags as the distributed build
# (launcher aside), or a warning-level mismatch could masquerade as a real
# distribution difference.
echo "== Configuring ccache (plain CMake, no distcc launcher) =="
cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DWARNINGS_AS_ERRORS=OFF \
  -DENABLE_TESTING=OFF
echo

echo "== Building ccache directly =="
cmake --build "${BUILD_DIR}" -j"${JOBS}"
echo

echo "== Smoke check: control-built ccache runs =="
test -x "${BUILD_DIR}/ccache"
"${BUILD_DIR}/ccache" --version

echo
echo "Control build completed successfully -- ccache's source builds cleanly with this image's plain compiler."
