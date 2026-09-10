#!/usr/bin/env bash
# What: orchestrates every `docker run distcc-ng-verify:ci` verification step
#   used by .github/workflows/verify-image-build.yml, dispatched by subcommand
#   ($1): ptrace-selftest, build-test, ccache-redis, samba-configure-dryrun.
# Why: keeps the YAML a thin orchestrator with no embedded docker-run logic to
#   duplicate or drift, and lets the two ptrace-dependent steps share one flag
#   definition instead of two hand-copied ones.
# From: Issue #285, PR #528.
set -euo pipefail

# What: overridable image tag and seccomp profile path; REPO_ROOT prefers
#   GITHUB_WORKSPACE (the real CI checkout root) and falls back to this
#   script's own on-disk location otherwise.
# Why: a caller (a future OS-specific variant, or a local invocation outside
#   CI) needs to override the image/profile without editing this file.
# From: Issue #285, PR #528.
REPO_ROOT="${GITHUB_WORKSPACE:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
IMAGE="${VERIFY_IMAGE:-distcc-ng-verify:ci}"
SECCOMP_PROFILE="${VERIFY_SECCOMP:-${REPO_ROOT}/docker/verify/seccomp-verify.json}"

# What: shared flags for the two ptrace-dependent steps below (SYS_PTRACE
#   capability plus this repo's narrow seccomp profile), with step-specific
#   flags/image/command appended via "$@".
# Why: previously duplicated by hand across two separate `docker run`
#   invocations, letting them drift -- one had no seccomp profile at all, the
#   other used the unrelated `unconfined` profile (Codex review comment 2,
#   PR #528).
# From: Issue #285, PR #528.
docker_run_ptrace() {
    docker run --rm --cap-add=SYS_PTRACE \
        --security-opt seccomp="${SECCOMP_PROFILE}" \
        "$@"
}

# What: runs the ptrace-dependent tool self-test (gdb/strace/ltrace/py-bt)
#   under this repo's narrow seccomp profile, asserting gdb can still disable
#   ASLR under it.
# Why: previously ran with only --cap-add=SYS_PTRACE and no seccomp profile,
#   so a profile regression narrowing personality() too far would have gone
#   undetected here (Codex review comment 2, PR #528).
# From: Issue #285, PR #528.
step_ptrace_selftest() {
    docker_run_ptrace \
        -e ASLR_MUST_DISABLE=1 \
        -v "${REPO_ROOT}/docker/verify:/verify:ro" \
        "${IMAGE}" bash /verify/selftest-ptrace.sh
}

# What: runs this repo's own ./autogen.sh/./configure/make/make check inside
#   the verify image, as the runner's own numeric uid with a synthesized
#   /etc/passwd entry (written by the caller into RUNNER_TEMP), under --init
#   and the narrow seccomp profile.
# Why: the numeric --user needs a real /etc/passwd entry (getpwuid() callers
#   like ssh-keygen fatal() without one) and a writable $HOME (Docker leaves
#   HOME=/ otherwise); --init reaps distccd's detached, PID-1-reparented
#   children that make check's teardown polls for; the seccomp profile (not
#   unconfined) still allows gdb's personality(ADDR_NO_RANDOMIZE) call
#   (Codex review comment 2, PR #528).
# From: Issue #286, Issue #285, PR #528.
step_build_test() {
    # The bash -c payload is intentionally single-quoted: $HOME and the build
    # commands must run inside the container, not expand in this outer shell.
    # shellcheck disable=SC2016
    docker_run_ptrace \
        --user "$(id -u):$(id -g)" --init \
        -v "${REPO_ROOT}:/work/src:rw" \
        -v "${RUNNER_TEMP}/verify-etc/passwd:/etc/passwd:ro" \
        -v "${RUNNER_TEMP}/verify-etc/group:/etc/group:ro" \
        -w /work/src \
        -e HOME=/tmp/distcc-ng-verify-home \
        "${IMAGE}" bash -c '
            set -euo pipefail
            mkdir -p "$HOME"
            id
            ./autogen.sh
            ./configure PYTHON=python3
            make
            make check
        '
}

# What: proves ccache's Redis remote-storage backend actually serves a real
#   cache hit, using two independent, fresh containers against the caller's
#   ephemeral Redis service (not this step's concern to start).
# Why: a single container's own local ccache dir would produce a false hit
#   without Redis ever being involved, and an unwritable $HOME breaks
#   ccache's local cache before Redis is reached at all; unaffected by Codex
#   review comment 2, which is scoped to the two ptrace-dependent steps only.
# From: Issue #285, PR #528.
step_ccache_redis() {
    run_ccache_build() {
        local label="$1"
        local stats_file="$2"
        # The bash -c payload is intentionally single-quoted: $HOME and the
        # ccache commands must run inside the container, not expand here.
        # shellcheck disable=SC2016
        docker run --rm --network host --user "$(id -u):$(id -g)" \
            -v "${REPO_ROOT}:/work/src:rw" \
            -w /work/src \
            -e CCACHE_REMOTE_STORAGE="redis://127.0.0.1:6379" \
            -e HOME=/tmp/ccache-home \
            "${IMAGE}" bash -c '
                set -euo pipefail
                mkdir -p "$HOME"
                cd /work/src
                ccache --zero-stats >/dev/null
                touch src/dopt.c
                make CC="ccache gcc" src/dopt.o
                ccache --show-stats
            ' | tee "${stats_file}"
        echo "--- ${label}: ccache stats above ---"
    }

    run_ccache_build "First container (expect a MISS, pushes the object to Redis)" "${RUNNER_TEMP}/first-run-stats.log"
    run_ccache_build "Second container (fresh filesystem, no local ccache dir -- a Hit here can only have come from Redis)" "${RUNNER_TEMP}/second-run-stats.log"

    if ! grep -qE "Hits:[[:space:]]*[1-9]" "${RUNNER_TEMP}/second-run-stats.log"; then
        echo "::error::ccache reported no cache hit on the second, fresh container -- Redis remote storage did not actually serve the cached object"
        exit 1
    fi
    echo "Real cache hit confirmed against the ephemeral Redis remote-storage backend."
}

# What: downloads the real upstream Samba release tarball, verifies its GPG
#   signature against Samba's own published key, then proves this image's
#   package inventory is sufficient via Samba's own ./configure (waf) exit
#   code.
# Why: waf's own exit code is checked, not a "not found" text grep -- waf
#   legitimately prints benign "not found" lines for disabled optional
#   features, which previously produced a false failure; unaffected by
#   Codex review comment 2, since this step has no ptrace/seccomp involvement.
# From: Issue #285, PR #528, doc/combined-test-and-release_checklist.md VER-SOURCE.
step_samba_configure_dryrun() {
    docker run --rm "${IMAGE}" bash -c '
        set -euo pipefail
        cd /tmp
        wget -q https://download.samba.org/pub/samba/stable/samba-4.22.4.tar.gz
        wget -q https://download.samba.org/pub/samba/stable/samba-4.22.4.tar.asc
        wget -q https://download.samba.org/pub/samba/samba-pubkey.asc
        gpg --batch --import samba-pubkey.asc
        gunzip -k samba-4.22.4.tar.gz
        gpg --batch --verify samba-4.22.4.tar.asc samba-4.22.4.tar 2>&1 | tee gpg-verify.log
        grep -q "Good signature from" gpg-verify.log \
          || { echo "::error::Samba tarball signature did not verify against samba.org own published key -- refusing to use it as verification evidence"; exit 1; }
        tar xf samba-4.22.4.tar
        cd samba-4.22.4
        if ./configure 2>&1 | tee configure.log; then
            echo "Samba ./configure exited 0 -- this images package inventory is sufficient."
        else
            echo "::error::Samba ./configure exited non-zero -- this images package inventory is not actually sufficient"
            exit 1
        fi
    '
}

# What: writes the verify image's own /etc/passwd and /etc/group into
#   RUNNER_TEMP, then appends one synthetic entry for the runner's numeric
#   uid/gid, for step_build_test to bind-mount read-only.
# Why: the numeric --user has no /etc/passwd entry in the image, and
#   ssh-keygen's getpwuid(getuid()) fatal()s without one (SSHMode_Case);
#   reading the image's real files first preserves every account it ships,
#   keeping issue #286's no-root/no-chown property (no rebuild, no su).
# From: Issue #286, Issue #285, PR #528.
step_prepare_etc() {
    mkdir -p "${RUNNER_TEMP}/verify-etc"
    docker run --rm "${IMAGE}" cat /etc/passwd > "${RUNNER_TEMP}/verify-etc/passwd"
    docker run --rm "${IMAGE}" cat /etc/group > "${RUNNER_TEMP}/verify-etc/group"
    printf 'ci-runner:x:%s:%s:GitHub Actions runner uid:/tmp/distcc-ng-verify-home:/bin/bash\n' \
        "$(id -u)" "$(id -g)" >> "${RUNNER_TEMP}/verify-etc/passwd"
    printf 'ci-runner:x:%s:\n' "$(id -g)" >> "${RUNNER_TEMP}/verify-etc/group"
}

# What: dispatches to the requested verification subcommand.
# Why: keeps verify-image-build.yml's steps to a single
#   `bash docker/verify/ci.sh <subcommand>` call each, with no embedded
#   docker-run logic left in the YAML itself.
# From: Issue #285, PR #528.
case "${1:-}" in
    prepare-etc) step_prepare_etc ;;
    ptrace-selftest) step_ptrace_selftest ;;
    build-test) step_build_test ;;
    ccache-redis) step_ccache_redis ;;
    samba-configure-dryrun) step_samba_configure_dryrun ;;
    *)
        echo "usage: $0 {prepare-etc|ptrace-selftest|build-test|ccache-redis|samba-configure-dryrun}" >&2
        exit 1
        ;;
esac
