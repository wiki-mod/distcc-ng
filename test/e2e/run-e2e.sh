#!/usr/bin/env bash
#
# Orchestrates the two-container distributed-compile end-to-end test on the CI
# runner (or a developer's machine with docker + compose). It brings the stack
# up, lets the client self-compile distcc-ng across the network, and then
# independently confirms from the *server's* own log that real compile jobs
# landed there -- so a silently-local build cannot pass even if the client
# script were somehow fooled. Logs are always dumped and the stack always torn
# down, whatever the outcome.

set -euo pipefail

cd "$(dirname "$0")"

# Minimum number of remote compiles we insist on seeing in the server log.
# distcc-ng has far more than this many source files, and the run compiles the
# whole tree twice (plain + pump); the floor only guards against a degenerate
# "one job slipped through, the rest fell back" result. It is intentionally a
# floor, not the exact count, so it stays robust as the source tree grows.
readonly MIN_REMOTE_JOBS=5

# The token distccd's per-job summary prints for a successful compile (see
# STATS_COMPILE_OK / dcc_job_summary in src/stats.c and src/serve.c), and the
# compose subnet the client must appear to originate from.
readonly OK_TOKEN="COMPILE_OK"
readonly CLIENT_SUBNET_PREFIX="10.88.0."

server_log="$(mktemp)"

# Always surface both containers' logs and tear the stack down, even on an
# early failure -- a leaked network/container would break the next CI run.
cleanup() {
  echo "== distccd-server log (tail) =="
  docker compose logs --no-color distccd-server 2>/dev/null | tail -n 100 || true
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  rm -f "${server_log}"
}
trap cleanup EXIT

echo "== Bringing up client+server and running the distributed build =="
# --abort-on-container-exit stops the long-running server as soon as the client
# finishes; --exit-code-from propagates the client's exit status. Captured
# without tripping set -e so we can still inspect the server log and tear down.
client_rc=0
docker compose up --build --abort-on-container-exit \
  --exit-code-from distcc-client || client_rc=$?

if [ "${client_rc}" -ne 0 ]; then
  echo "ERROR: client build container exited with status ${client_rc}" >&2
  exit 1
fi

echo "== Verifying real distribution from the server log =="
docker compose logs --no-color distccd-server > "${server_log}" 2>&1

remote_jobs="$(grep -c "${OK_TOKEN}" "${server_log}" || true)"
echo "server reported ${remote_jobs} successful remote compile(s)"

if [ "${remote_jobs}" -lt "${MIN_REMOTE_JOBS}" ]; then
  echo "ERROR: expected at least ${MIN_REMOTE_JOBS} remote compiles on the" \
       "server, saw ${remote_jobs} -- the build likely fell back to local" \
       "compilation instead of distributing." >&2
  exit 1
fi

# Confirm the jobs genuinely arrived from the client container over the network
# (its compose-subnet address), not from a localhost self-connection.
if ! grep "${OK_TOKEN}" "${server_log}" | grep -q "${CLIENT_SUBNET_PREFIX}"; then
  echo "ERROR: no successful compile in the server log originated from the" \
       "client subnet ${CLIENT_SUBNET_PREFIX}0/24 -- distribution not proven." >&2
  exit 1
fi

echo "SUCCESS: distributed compile validated (${remote_jobs} remote jobs, from the client subnet)"
