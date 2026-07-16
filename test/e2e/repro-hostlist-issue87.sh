#!/usr/bin/env bash
#
# Reproduces (for real, not from reading code) the failure modes behind
# issue #87: distcc/pump currently need two different host-list entries.
# Runs entirely inside the distcc-client container of the existing e2e
# harness (test/e2e/docker-compose.yml), against the same distccd-server.
# Does not touch DISTCC_HOSTS from the environment -- each scenario sets it
# explicitly to isolate exactly one variable at a time.
#
# This is an investigation tool, not a permanent regression test -- it is
# expected to demonstrate CURRENT failures, some of which issue #87 may fix.

set -uo pipefail  # deliberately no -e: every scenario's exit status is data

echo "distcc version: $(distcc --version | head -1)"
echo "pump version: $(pump --version 2>&1 | head -1 || echo '(pump --version unsupported)')"
echo

run_scenario() {
  local name="$1" hosts="$2"; shift 2
  echo "############################################################"
  echo "### Scenario: ${name}"
  echo "### DISTCC_HOSTS=${hosts}"
  echo "### Command: $*"
  echo "############################################################"
  DISTCC_HOSTS="${hosts}" "$@"
  local rc=$?
  echo "--- exit code: ${rc} ---"
  echo
  return 0
}

probe_dir="$(mktemp -d)"
cat > "${probe_dir}/probe.c" <<'EOF'
int distcc_e2e_probe_87(int x) { return x + 1; }
EOF
cd "${probe_dir}"

# --- Scenario A: manual DISTCC_HOSTS (bare, no suffix) via `pump` directly ---
# Reproduces the claimed pump.in:613-616 hard failure: pump.in's manual-hosts
# path does NOT auto-append ,cpp,lzo the way its lsdistcc/DISTCC_POTENTIAL_HOSTS
# path does -- it instead demands the list already contain ,cpp.
run_scenario "A: bare host list under pump (manual DISTCC_HOSTS)" \
  "distccd-server:3632" \
  pump gcc -O2 -c probe.c -o a.o

# --- Scenario B: ,cpp without compression, plain distcc (no pump) ---
# Reproduces the claimed hosts.c:485-487 parse-time rejection: dcc_parse_options
# requires a compression option (,lzo or ,zstd) alongside ,cpp.
run_scenario "B: ,cpp without compression, plain distcc" \
  "distccd-server:3632,cpp" \
  distcc gcc -O2 -c probe.c -o b.o

# --- Scenario C: well-formed ,cpp,lzo under PLAIN (non-pump) distcc ---
# Tests the claimed compile.c:793-811 graceful runtime fallback: no include
# server is running here (not invoked via `pump`), so dcc_talk_to_include_server
# should fail and cpp_where should downgrade to client-side with a warning,
# not a crash -- if true, a single well-formed host entry already works in
# both contexts at runtime, and the real friction is elsewhere.
run_scenario "C: well-formed ,cpp,lzo under plain (non-pump) distcc" \
  "distccd-server:3632,cpp,lzo" \
  distcc gcc -O2 -c probe.c -o c.o

# --- Scenario D: ,cpp,zstd under pump (auto-discovery path, so pump.in's ---
# --- own auto-suffix logic isn't the variable being tested here) ---
# Tests the claimed hosts.c:463-489 gap: no protocol version is wired for
# compr=ZSTD + cpp_where=DCC_CPP_ON_SERVER (only LZO pairs with server-side cpp).
run_scenario "D: ,cpp,zstd (pump + zstd combination)" \
  "distccd-server:3632,cpp,zstd" \
  distcc gcc -O2 -c probe.c -o d.o

echo "== repro run complete =="
