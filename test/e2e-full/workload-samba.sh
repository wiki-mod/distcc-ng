#!/usr/bin/env bash
#
# Real workload for the full bidirectional E2E test (issue #264): Samba is
# the sizing/workload reference this repo already researched and baked into
# docker/verify/Dockerfile (51 real Debian build-deps vs. Apache httpd's 20 --
# see that Dockerfile's own header comment). This is the ENABLED workload;
# workload-apache.sh is the flagged-off alternative kept in sync so switching
# is a one-line change (see run-bidirectional-e2e.sh's WORKLOAD variable),
# not a rewrite.
#
# Run inside the CLIENT container for a given leg of the bidirectional
# matrix. Fetches+verifies the real Samba release tarball once (cached), then
# extracts a FRESH, unbuilt copy per leg so no leg's build artifacts can leak
# into another's compile count -- each of the four legs (direction A/B x
# plain/pump) gets an independent, from-scratch Samba source tree.
#
# Usage: workload-samba.sh <mode: plain|pump> <src_dir> [waf_targets]
#   mode         plain: `waf build` with CC wrapped through distcc.
#                pump:  same, but the whole waf invocation runs under `pump`
#                       so header discovery/preprocessing distributes too.
#   src_dir      fresh, not-yet-built Samba source tree to build in place.
#   waf_targets  optional --targets=... value, restricting the real build to
#                a bounded (but still real, unmodified Samba source) subset --
#                used to keep a CI/session-time-bounded run honest evidence
#                rather than the full multi-hour build. Omit for a full,
#                unrestricted `waf build` (the intended real production run,
#                see this test's own README.md on execution model).
#
# Prints the number of real distinct compiled objects produced (used by the
# orchestrator as the known-in-advance floor the server's own log must meet
# or exceed -- see lib.sh's count_compile_ok and this script's own comment
# below on why an object count, not a static pre-build guess, is the honest
# "known count" here) to stdout as the LAST line.

set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

MODE="${1:?usage: workload-samba.sh <plain|pump> <src_dir> [waf_targets]}"
SRC_DIR="${2:?usage: workload-samba.sh <plain|pump> <src_dir> [waf_targets]}"
WAF_TARGETS="${3:-}"

readonly SAMBA_VERSION="4.22.4"
readonly SAMBA_TARBALL_URL="https://download.samba.org/pub/samba/stable/samba-${SAMBA_VERSION}.tar.gz"
readonly SAMBA_SIG_URL="https://download.samba.org/pub/samba/stable/samba-${SAMBA_VERSION}.tar.asc"
readonly SAMBA_PUBKEY_URL="https://download.samba.org/pub/samba/samba-pubkey.asc"
readonly CACHE_DIR="/work/workload/samba-cache"
readonly CACHE_MARKER="${CACHE_DIR}/.verified-ok"

# --- Fetch + verify once, cached across all four legs of this run ---------
if [ ! -f "${CACHE_MARKER}" ]; then
  echo "== Fetching and verifying real Samba ${SAMBA_VERSION} release tarball (once, cached) ==" >&2
  fetch_and_verify_tarball "${SAMBA_TARBALL_URL}" "${SAMBA_SIG_URL}" "${SAMBA_PUBKEY_URL}" "${CACHE_DIR}"
  touch "${CACHE_MARKER}"
else
  echo "== Reusing already-verified Samba ${SAMBA_VERSION} tarball ==" >&2
fi

# --- Fresh, unbuilt extraction for THIS leg only ---------------------------
rm -rf "${SRC_DIR}"
mkdir -p "$(dirname "${SRC_DIR}")"
cp "${CACHE_DIR}/samba-${SAMBA_VERSION}.tar" "/tmp/samba-leg-$$.tar"
mkdir -p "${SRC_DIR}"
tar xf "/tmp/samba-leg-$$.tar" -C "${SRC_DIR}" --strip-components=1
rm -f "/tmp/samba-leg-$$.tar"

# Basename-only compilers (matches the masquerade whitelist both container
# stages populate in test/e2e-full/Dockerfile): an absolute path would be
# rejected by distccd's compiler-name check.
CC_DISTCC="distcc gcc"

cd "${SRC_DIR}"
export CC="${CC_DISTCC}"

# Configure with distcc as CC (waf bakes in whichever compiler it resolves
# at configure time and does not re-resolve CC from the environment at
# build time -- confirmed empirically: configuring with a plain local gcc
# and only switching to CC="distcc gcc" for the later `waf build` step
# silently kept using the local compiler baked in at configure time, so
# every "compile" during the real build step happened locally with zero
# distribution -- exactly the false-positive DISTCC_FALLBACK=0 exists to
# prevent, just one level up the tooling stack instead of inside distcc
# itself), but DISTCC_FALLBACK is deliberately left UNSET (real fallback
# enabled) for this configure step specifically. waf's configure phase
# performs many "does this optional header/feature exist" trial compiles
# (e.g. minix/config.h, which legitimately doesn't exist and is expected to
# fail) as its normal feature-detection mechanism -- those are supposed to
# fail sometimes, and with DISTCC_FALLBACK=0 already active here (confirmed
# empirically) every such expected probe failure became a hard distcc
# error ("failed to distribute and fallbacks are disabled") instead of a
# normal "feature absent" result, aborting configure entirely on the very
# first legitimately-absent optional header. DISTCC_FALLBACK=0 is restored
# below for the real build phase, which is what this test actually measures.
echo "== Configuring real Samba ${SAMBA_VERSION} source (waf, CC=distcc, fallback enabled) ==" >&2
env -u DISTCC_FALLBACK ./configure >configure.log 2>&1 || {
  echo "::error::Samba ./configure (waf) failed -- see configure.log" >&2
  tail -n 100 configure.log >&2
  exit 1
}

BUILD_CMD=(./buildtools/bin/waf build -j"$(nproc)")
[ -n "${WAF_TARGETS}" ] && BUILD_CMD+=(--targets="${WAF_TARGETS}")

# Samba's own generated `make` wrapper always sets PYTHONHASHSEED=1 before
# invoking waf directly (its build graph's ordering is sensitive to Python's
# hash randomization); calling waf directly without it, as this script does,
# hits Samba's own guard rail verbatim: "PYTHONHASHSEED=1 missing! Don't use
# waf directly, use ./configure and make!" -- confirmed empirically. Setting
# it here reproduces exactly what `make` would have done.
export PYTHONHASHSEED=1

echo "== Building real Samba ${SAMBA_VERSION} source, mode=${MODE}, DISTCC_HOSTS=${DISTCC_HOSTS:-<unset>} ==" >&2
export DISTCC_FALLBACK=0
if [ "${MODE}" = "pump" ]; then
  run_pump_build "${BUILD_CMD[@]}"
else
  "${BUILD_CMD[@]}"
fi

# Real, empirically-grounded compiled-unit count for THIS leg: the number of
# .o files waf actually produced. This is used, not a static pre-build guess,
# because Samba's own waf configure conditionally selects which of its many
# subsystems actually get built (Kerberos/LDAP/clustering/etc. each toggle a
# different real subset of source files depending on what the container's
# dependency surface satisfies) -- duplicating waf's own dependency
# resolution just to pre-compute an exact static number would be a second,
# parallel, drift-prone implementation of logic waf already owns (see
# AGENTS.md rule 69 on not re-implementing existing logic under a new name).
# The object count is still "known in advance of the server-log check" in the
# sense the design requires: it is computed from the real build BEFORE the
# server log is consulted, so a build that silently fell back to local
# compilation cannot pass by chance -- the server log must show at least this
# many real COMPILE_OK entries from the client's own subnet address.
find . -name '*.o' | wc -l
