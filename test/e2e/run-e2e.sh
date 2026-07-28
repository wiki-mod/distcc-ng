#!/usr/bin/env bash
#
# Orchestrates a two-container distributed-compile validation on the CI runner
# (or a developer's machine with docker + compose). It brings the stack up, has
# the client build a project across the network, and then independently
# confirms from the *server's* own log that real compile jobs landed there --
# so a silently-local build cannot pass even if the client script were somehow
# fooled. Logs are always dumped and the stack always torn down.
#
# The client-side workload is pluggable so the same orchestrator drives both
# the nightly distcc-ng self-compile and the weekly ccache heartbeat:
#   E2E_CLIENT_SCRIPT   repo-relative client script to run in the client
#                       container (default: the distcc-ng self-compile).
#   E2E_MIN_REMOTE_JOBS floor on remote compiles the server must report.
#   E2E_SCENARIO        human label for log output.
#   E2E_MAX_ATTEMPTS    how many full up/build/verify cycles to try before
#                       giving up (default 1, i.e. no retry).

set -euo pipefail

cd "$(dirname "$0")"

# Exported so docker-compose interpolates it into the client service's command.
export E2E_CLIENT_SCRIPT="${E2E_CLIENT_SCRIPT:-test/e2e/client-build.sh}"
readonly SCENARIO="${E2E_SCENARIO:-distcc-ng self-compile}"

# Minimum number of remote compiles we insist on seeing in the server log. The
# default suits the distcc-ng self-compile (far more than this many files, built
# twice for plain + pump); the floor only guards against a degenerate "one job
# slipped through, the rest fell back" result, so it stays robust as a tree
# grows. Heartbeat runs raise it via the environment.
readonly MIN_REMOTE_JOBS="${E2E_MIN_REMOTE_JOBS:-5}"

# Attempts before a failure is treated as final. Defaults to 1 (no retry) so
# existing callers that don't set this -- notably c-build.yml's per-push
# distributed_e2e job -- keep surfacing a flake immediately rather than having
# it silently absorbed. The weekly ccache heartbeat (master-heartbeat.yml)
# raises this via the environment to ride out a one-off network/container
# flake; a failure that reproduces on every attempt still exits non-zero, so a
# real, reproducible distcc bug is never hidden by the retry.
readonly MAX_ATTEMPTS="${E2E_MAX_ATTEMPTS:-1}"

# distccd's per-job summary for a successful compile is
#   "... client: <ip>:<port> COMPILE_OK ..."
# (see dcc_job_summary in src/serve.c and STATS_COMPILE_OK in src/stats.c).
# Matching a successful compile *paired with the client's compose-subnet
# address* proves, in a single pattern, both that real jobs completed and that
# they arrived over the network from the client container -- not a localhost
# self-connection. The dots are escaped so they are literal, not regex "any".
readonly REMOTE_OK_RE='client: 10\.88\.0\.[0-9]+:[0-9]+ COMPILE_OK'

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

# Runs one full up/build/verify cycle and returns non-zero on any failure
# (client build failure or too few remote jobs) without tearing the stack
# down itself -- the retry loop below owns teardown-between-attempts, and the
# EXIT trap owns final teardown, so a failed attempt's containers are still
# up (and their logs inspectable) for as long as this function's caller needs
# them. Note: calling this via `if run_attempt; then` (below) makes `set -e`
# inert for the function body, same as it always is for any command tested
# directly in an `if`/`while` condition -- this is safe here because every
# command whose failure must actually stop the attempt already has an
# explicit check (client_rc, remote_jobs) below, not a silent full-script
# abort. It does mean an unexpected failure of `docker compose logs` itself
# would fall through to the remote_jobs check on an empty/stale server_log
# rather than aborting outright -- acceptable since that check already fails
# safely (0 remote jobs < MIN_REMOTE_JOBS) rather than silently passing.
run_attempt() {
  echo "== Bringing up client+server and running the distributed build =="
  # --abort-on-container-exit stops the long-running server as soon as the
  # client finishes; --exit-code-from propagates the client's exit status.
  # Captured without tripping set -e so we can still inspect the server log.
  local client_rc=0
  docker compose up --build --abort-on-container-exit \
    --exit-code-from distcc-client || client_rc=$?

  if [ "${client_rc}" -ne 0 ]; then
    echo "ERROR: client build container exited with status ${client_rc}" >&2
    return 1
  fi

  echo "== Verifying real distribution from the server log =="
  docker compose logs --no-color distccd-server > "${server_log}" 2>&1

  # Single grep -c, deliberately not `grep ... | grep -q`: under `set -o
  # pipefail` the reader (`grep -q`) exits on first match and SIGPIPEs the
  # writer, so the pipeline reports failure even on a match -- which would
  # falsely read as "no remote jobs".
  local remote_jobs
  remote_jobs="$(grep -Ec "${REMOTE_OK_RE}" "${server_log}" || true)"
  echo "server reported ${remote_jobs} successful remote compile(s) from the client subnet"

  if [ "${remote_jobs}" -lt "${MIN_REMOTE_JOBS}" ]; then
    echo "ERROR: expected at least ${MIN_REMOTE_JOBS} remote compiles from the" \
         "client subnet, saw ${remote_jobs} -- the build likely fell back to" \
         "local compilation instead of distributing." >&2
    return 1
  fi

  echo "SUCCESS: ${SCENARIO} validated (${remote_jobs} remote jobs from the client subnet)"
  return 0
}

echo "== Scenario: ${SCENARIO} (client script: ${E2E_CLIENT_SCRIPT}) =="

attempt=1
while :; do
  echo "== Attempt ${attempt}/${MAX_ATTEMPTS} =="
  if run_attempt; then
    exit 0
  fi

  if [ "${attempt}" -ge "${MAX_ATTEMPTS}" ]; then
    echo "ERROR: ${SCENARIO} failed on attempt ${attempt}/${MAX_ATTEMPTS} -- not retrying further, this is a real failure." >&2
    exit 1
  fi

  echo "== Attempt ${attempt}/${MAX_ATTEMPTS} failed; tearing the stack down and retrying =="
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  attempt=$((attempt + 1))
done
