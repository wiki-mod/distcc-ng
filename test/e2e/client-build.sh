#!/usr/bin/env bash
#
# Runs inside the distcc-client container. Distributes distcc-ng's own source
# tree to the distccd-server container (plain and pump mode), then verifies a
# distributed compile is byte-identical to a local-only one. Distribution
# failures surface as hard errors because DISTCC_FALLBACK=0 (set in the compose
# file) turns distcc's silent local-fallback safety net off -- a broken
# distribution path can no longer masquerade as a green build.

set -euo pipefail

# Basename-only compilers: the server whitelist accepts "gcc"/"g++" (see the
# masquerade dir in the Dockerfile); an absolute path would be rejected.
CC_DISTCC="distcc gcc"
CXX_DISTCC="distcc g++"
JOBS="$(nproc)"

echo "== distcc client configuration =="
echo "DISTCC_HOSTS=${DISTCC_HOSTS}"
echo "DISTCC_FALLBACK=${DISTCC_FALLBACK:-<unset>}"
distcc --show-hosts || true
echo

# --- Distribution proof 1: plain-mode full self-compile -------------------
# make clean (not distclean) keeps the configure output from the image build,
# so this recompiles every object -- through distcc -- without re-running
# autoconf. With DISTCC_FALLBACK=0 a single unreachable-server compile aborts
# the whole build.
echo "== PLAIN distributed self-compile of distcc-ng =="
make clean >/dev/null 2>&1 || true
make -j"${JOBS}" CC="${CC_DISTCC}" CXX="${CXX_DISTCC}"
test -x ./distcc && test -x ./distccd
echo "plain-mode self-compile OK"
echo

# --- Distribution proof 2: pump-mode full self-compile --------------------
# Pump mode preprocesses server-side, so the host spec must carry the ,cpp,lzo
# options; the include server is started/stopped by the pump wrapper.
echo "== PUMP distributed self-compile of distcc-ng =="
make clean >/dev/null 2>&1 || true
DISTCC_HOSTS="distccd-server:3632,cpp,lzo" \
  pump make -j"${JOBS}" CC="${CC_DISTCC}" CXX="${CXX_DISTCC}"
test -x ./distcc && test -x ./distccd
echo "pump-mode self-compile OK"
echo

# --- Correctness: distributed result must match a local-only result -------
# A tiny, deterministic probe (no __FILE__/__DATE__, no debug info) compiled
# both locally and remotely with the same gcc must yield byte-identical
# objects. This is the honest form of "matches a local-only build": a
# controlled input avoids the false positives a diff of distcc-ng's own
# version-stamped binaries would produce, while still proving the remote
# toolchain produced identical code.
echo "== Correctness: local-only vs distributed object compare =="
probe_dir="$(mktemp -d)"
cat > "${probe_dir}/probe.c" <<'EOF'
int distcc_e2e_probe(int x) { return (x * 2) + 1; }
EOF
gcc -O2 -c "${probe_dir}/probe.c" -o "${probe_dir}/local.o"
DISTCC_FALLBACK=0 distcc gcc -O2 -c "${probe_dir}/probe.c" -o "${probe_dir}/dist.o"
if ! cmp "${probe_dir}/local.o" "${probe_dir}/dist.o"; then
  echo "ERROR: distributed object differs from local-only object" >&2
  exit 1
fi
echo "distributed object is byte-identical to local-only object"

echo
echo "client build script completed successfully"
