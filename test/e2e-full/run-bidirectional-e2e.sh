#!/usr/bin/env bash
#
# Full bidirectional native-compatibility distributed-build E2E test
# (issue #264's later design comments -- consolidated maintainer design,
# 2026-07-21). Distinct from test/e2e/run-e2e.sh's quick two-container
# hello-world-style check (that stays as-is, unchanged, per the issue's
# explicit "not folded into the existing quick E2E check" instruction).
#
# What this proves, in one run:
#   - Direction A: this fork's -NG distcc client -> a real, independently-
#     built native distccd (Debian's own packaged distccd, not this fork's
#     binary).
#   - Direction B: a real, independently-built native distcc client ->
#     this fork's -NG distccd.
#   - Both directions, in BOTH plain mode and pump mode (Debian ships
#     distcc-pump as a genuinely separate package from distcc -- both get
#     exercised, not just one).
#   - Each leg builds a real, substantial, multi-file third-party project
#     (Samba by default; see WORKLOAD below) -- not a synthetic/trivial
#     stand-in.
#   - Success is the SERVER's own independently-observed log showing at
#     least as many real COMPILE_OK entries as objects the build actually
#     produced -- not just the client's exit code, which a silent local
#     DISTCC_FALLBACK could also produce (which is why every invocation
#     below sets DISTCC_FALLBACK=0 as well, belt-and-suspenders).
#
# This is exactly the shape of bug #225 in this repo's own history (tested
# one direction, broken in the other) -- see doc/verification-checklist.md
# section 4, which this script is the automated form of.
#
# Environment knobs:
#   WORKLOAD        "samba" (default, the enabled real workload) or
#                    "apache" (present, flagged off by default -- switching
#                    is this one line, not a rewrite; see workload-apache.sh).
#   WAF_TARGETS      Passed through to workload-samba.sh's optional
#                    --targets=... scoping (see that script's own comment on
#                    why a bounded-but-real subset is sometimes the honest
#                    choice for a CI/session-time-bounded run vs. the full,
#                    unrestricted production run this test is designed for).
#   DAEMON_JOBS      distccd --jobs value (default: nproc).

set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source ./lib.sh

readonly WORKLOAD="${WORKLOAD:-samba}"
readonly WAF_TARGETS="${WAF_TARGETS:-}"
readonly DAEMON_JOBS="${DAEMON_JOBS:-4}"

# /e2e-scripts is this same directory (test/e2e-full), bind-mounted
# read-only into both containers by docker-compose.yml -- the workload
# scripts and lib.sh live on the host, not baked into either image.
case "${WORKLOAD}" in
  samba)  WORKLOAD_SCRIPT="/e2e-scripts/workload-samba.sh" ;;
  apache) WORKLOAD_SCRIPT="/e2e-scripts/workload-apache.sh" ;;
  *) echo "::error::unknown WORKLOAD='${WORKLOAD}' (expected samba or apache)" >&2; exit 1 ;;
esac

readonly NG_IP="10.89.0.10"
readonly NATIVE_IP="10.89.0.20"

WORKDIR="$(mktemp -d)"
overall_rc=0

# Always surface every leg's server log and tear the whole stack down, even
# on an early failure -- a leaked network/container would break the next run
# on a shared host (see AGENTS.md's SSH-scratch-cleanup convention, same
# spirit applied to Docker resources here).
cleanup() {
  echo "== Tearing down the bidirectional E2E stack =="
  docker compose exec -T ng-node bash -c 'pkill distccd || true' 2>/dev/null || true
  docker compose exec -T native-node bash -c 'pkill distccd || true' 2>/dev/null || true
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

echo "== Building the ng (throwaway, current checkout) and native (stable, apt-installed) images =="
docker compose build

echo "== Bringing the two-container stack up =="
docker compose up -d

# Runs one leg: starts distccd on ${server_service} (fresh, own log file),
# runs the real workload build on ${client_service} pointed at the server's
# fixed compose-network IP, verifies the server's own log independently, and
# always stops the daemon before returning (whether the leg passed or not).
#
# leg_id is a short, shell-metacharacter-free identifier (e.g. "dirA_plain")
# used to build real filesystem paths -- leg_label is the human-readable
# description used only in echoed output. Keeping these separate matters:
# an earlier version of this script used leg_label directly for src_dir,
# and its literal "(" "/" ">" characters broke Samba's own build (its Heimdal
# error-table code generator shells out with the build path embedded
# unquoted, so a path containing "(" hit a real "/bin/sh: Syntax error: (
# unexpected" -- confirmed empirically, not a hypothetical concern).
#
# Args: <leg_id> <leg_label> <server_service> <server_ip> <client_service> <client_ip> <mode: plain|pump>
run_leg() {
  local leg_id="$1" leg_label="$2" server_service="$3" server_ip="$4" client_service="$5" client_ip="$6" mode="$7"
  local remote_log="/tmp/distccd-${mode}.log"
  local local_log="${WORKDIR}/${leg_id}.log"

  echo
  echo "=============================================================="
  echo "== Leg: ${leg_label} (mode=${mode}) =="
  echo "=============================================================="

  echo "-- Starting distccd on ${server_service} (${server_ip}) --"
  # --log-file and --log-stderr are mutually exclusive destinations ("send
  # messages here instead of syslog" / "send messages to stderr" -- distccd
  # --help): passing both was tried first and silently dropped the file (the
  # last-parsed option won, sending everything to stderr, which a detached
  # `docker compose exec -d` discards) -- confirmed empirically, not assumed
  # from the --help wording alone. --log-file alone is what actually produces
  # a file this script can read back after the leg finishes.
  docker compose exec -T -d "${server_service}" bash -c "
    rm -f ${remote_log}
    distccd --no-detach --daemon --verbose --log-file=${remote_log} \
      --port 3632 --allow 10.89.0.0/24 --jobs ${DAEMON_JOBS}
  "
  # No compose healthcheck here (unlike test/e2e/docker-compose.yml) because
  # this same daemon process is started/stopped per leg rather than once at
  # container start -- poll for the log file existing instead of a fixed
  # sleep, which would either race a slow-starting daemon or waste time on a
  # fast one.
  for _ in $(seq 1 20); do
    docker compose exec -T "${server_service}" test -f "${remote_log}" && break
    sleep 0.5
  done

  local client_rc=0
  local src_dir="/work/workload/${leg_id}"
  echo "-- Running real ${WORKLOAD} build on ${client_service}, distributing to ${server_ip}:3632 --"
  docker compose exec -T \
    -e "DISTCC_HOSTS=${server_ip}:3632" \
    -e "DISTCC_FALLBACK=0" \
    -e "DISTCC_VERBOSE=1" \
    "${client_service}" \
    bash "${WORKLOAD_SCRIPT}" "${mode}" "${src_dir}" ${WAF_TARGETS:+"${WAF_TARGETS}"} \
    > "${local_log}" 2>&1 || client_rc=$?

  echo "-- Stopping distccd on ${server_service} --"
  docker compose cp "${server_service}:${remote_log}" "${local_log}.server" 2>/dev/null || true
  docker compose exec -T "${server_service}" bash -c 'pkill distccd || true'

  if [ "${client_rc}" -ne 0 ]; then
    echo "::error::${leg_label} (mode=${mode}): client build exited ${client_rc}" >&2
    tail -n 100 "${local_log}" >&2
    return 1
  fi

  # workload-*.sh prints the real, empirically-produced object count as its
  # LAST stdout line (see those scripts' own comments on why this, not a
  # static pre-build guess, is the honest known-count reference here).
  local expected_objects
  expected_objects="$(tail -n 1 "${local_log}" | tr -dc '0-9')"
  if [ -z "${expected_objects}" ] || [ "${expected_objects}" -le 0 ]; then
    echo "::error::${leg_label} (mode=${mode}): could not read a real compiled-object count from the workload script's output" >&2
    tail -n 20 "${local_log}" >&2
    return 1
  fi

  local remote_jobs
  remote_jobs="$(count_compile_ok "${local_log}.server" "${client_ip}")"
  echo "${leg_label} (mode=${mode}): built ${expected_objects} real objects; server log shows ${remote_jobs} COMPILE_OK from ${client_ip}"

  if [ "${remote_jobs}" -lt "${expected_objects}" ]; then
    echo "::error::${leg_label} (mode=${mode}): server log shows only ${remote_jobs} COMPILE_OK, fewer than the ${expected_objects} objects the build actually produced -- distribution did not fully happen (DISTCC_FALLBACK=0 should have made a real failure loud, but this is the independent server-side check the design calls for)." >&2
    return 1
  fi

  echo "PASS: ${leg_label} (mode=${mode})"
}

# --- The four legs: direction A/B x plain/pump -----------------------------
for mode in plain pump; do
  run_leg "dirA_${mode}" "Direction A (ng client -> native server) ${mode}" \
    native-node "${NATIVE_IP}" ng-node "${NG_IP}" "${mode}" || overall_rc=1
  run_leg "dirB_${mode}" "Direction B (native client -> ng server) ${mode}" \
    ng-node "${NG_IP}" native-node "${NATIVE_IP}" "${mode}" || overall_rc=1
done

if [ "${overall_rc}" -ne 0 ]; then
  echo "FAILED: one or more legs of the bidirectional native-compatibility matrix did not pass -- see the ::error:: lines above." >&2
  exit 1
fi

echo
echo "SUCCESS: all four legs of the bidirectional native-compatibility matrix (direction A/B x plain/pump) passed, workload=${WORKLOAD}."
