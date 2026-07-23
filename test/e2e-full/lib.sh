#!/usr/bin/env bash
#
# Shared helpers for the full bidirectional native-compatibility E2E test
# (issue #264). Sourced by workload-samba.sh, workload-apache.sh, and
# run-bidirectional-e2e.sh -- kept in one place so the artifact-verification
# and log-counting logic isn't duplicated (and can't silently drift) between
# the two workload scripts or between CI and a manual host run.

set -euo pipefail

# Downloads a project release tarball plus its detached signature and the
# project's own published public key, then verifies the signature against
# the *uncompressed* tarball -- doc/verification-checklist.md section 5's
# requirement ("verify a downloaded artifact against the upstream project's
# own published value, not just 'it downloaded without error'"), and the
# exact method already proven in .github/workflows/verify-image-build.yml's
# "Real Samba configure dry-run" step for Samba specifically. Exits non-zero
# (not a silent warning) on any verification failure, per AGENTS.md rule 66:
# a signature check that "usually passes" must be a hard gate, not advisory.
#
# Args: <tarball_url> <sig_url> <pubkey_url> <dest_dir>
fetch_and_verify_tarball() {
  local tarball_url="$1" sig_url="$2" pubkey_url="$3" dest_dir="$4"
  local tarball_name sig_name
  tarball_name="$(basename "${tarball_url}")"
  sig_name="$(basename "${sig_url}")"

  mkdir -p "${dest_dir}"
  ( cd "${dest_dir}"
    wget -q "${tarball_url}"
    wget -q "${sig_url}"
    wget -q "${pubkey_url}" -O pubkey.asc
    gpg --batch --import pubkey.asc
    # gpg --verify needs the *uncompressed* tarball for a detached .asc/.sig
    # made against the .tar, not the .tar.gz -- matching the exact method
    # documented on the upstream project's own download page in each case.
    gunzip -k "${tarball_name}"
    local uncompressed="${tarball_name%.gz}"
    gpg --batch --verify "${sig_name}" "${uncompressed}" 2>&1 | tee gpg-verify.log
    grep -q "Good signature from" gpg-verify.log \
      || { echo "::error::${tarball_name} signature did not verify against the project's own published key -- refusing to use it as verification evidence" >&2; exit 1; }
    tar xf "${uncompressed}"
  )
}

# Runs a build command under pump mode, on WHICHEVER of the two client
# flavours this container actually has -- distcc-ng's own `pump` wrapper
# (auto-appends ",cpp,lzo" per this fork's issue #87 fix) on the `ng`
# container, or Debian's separately-packaged `distcc-pump` (needs ",cpp,lzo"
# added to DISTCC_HOSTS explicitly -- confirmed empirically: without it,
# `distcc-pump distcc ...` refuses with "pump mode requested, but distcc
# hosts list does not contain any hosts with ',cpp' option") on the `native`
# container.
#
# Debian's `distcc-pump --shutdown` was found, empirically, to hang
# indefinitely in this container's non-interactive `docker compose exec -T`
# environment (reproduces this fork's own support-upstream/
# issue-007-pump-fail-closed.md finding -- "pump's shutdown and startup
# handshakes can block/hang forever with no timeout", still live in
# upstream): the include server itself starts and serves the build
# correctly (confirmed via the server's own COMPILE_OK log), only the
# shutdown handshake afterward blocks. Since this test's containers are
# always torn down right after each leg regardless (see
# run-bidirectional-e2e.sh's cleanup trap), an include server left running
# past `--shutdown`'s timeout is harmless here -- `timeout` bounds the wait
# so this script doesn't hang the whole run over a shutdown handshake this
# script isn't testing.
#
# Runs in the caller's current working directory (the caller is expected to
# have already `cd`ed into the source tree being built).
#
# Args: <build_cmd...>
run_pump_build() {
  if command -v pump >/dev/null 2>&1; then
    pump "$@"
  else
    export DISTCC_HOSTS="${DISTCC_HOSTS},cpp,lzo"
    eval "$(timeout 30 distcc-pump --startup)"
    local build_rc=0
    "$@" || build_rc=$?
    timeout 15 distcc-pump --shutdown >/dev/null 2>&1 || true
    return "${build_rc}"
  fi
}

# distccd's per-job summary for a successful compile is
#   "... client: <ip>:<port> COMPILE_OK ..."
# (see dcc_job_summary in src/serve.c and STATS_COMPILE_OK in src/stats.c,
# identically true of Debian's own distccd package -- same upstream lineage,
# same log line format). Counting only lines attributable to the expected
# client subnet proves both that jobs completed AND that they arrived over
# the network from that specific client, not a localhost self-connection --
# the exact pattern test/e2e/run-e2e.sh already uses for the quick check.
#
# Args: <server_log_file> <client_ip>
# Prints the count to stdout. Uses grep -c (not `grep | grep -q`, which under
# `set -o pipefail` would report failure on the very match it's looking for).
count_compile_ok() {
  local server_log="$1" client_ip="$2"
  # Dots escaped so they are literal, not regex "any character".
  local pattern="client: ${client_ip//./\\.}:[0-9]+ COMPILE_OK"
  grep -Ec "${pattern}" "${server_log}" || true
}
