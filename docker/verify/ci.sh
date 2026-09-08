#!/usr/bin/env bash
# What: orchestrates this repo's CI verification steps, dispatched by subcommand
#   ($1). Container image checks for verify-image-build.yml (ptrace-selftest,
#   build-test, ccache-redis, samba-configure-dryrun, prepare-etc) and one
#   host-side filesystem-jail happy-path check for c-build.yml (fs-jail-e2e,
#   which builds distcc-ng and runs a real jailed pump compile on the runner).
# Why: keeps the YAML workflows thin orchestrators with no embedded logic to
#   duplicate or drift, and lets the two ptrace-dependent steps share one flag
#   definition instead of two hand-copied ones.
# From: Issue #285, PR #528; Issue #289 (fs-jail-e2e).
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
# From: Issue #285, PR #528, doc/verification-checklist.md Section 5.
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

# What: build distcc-ng and prove one real pump-mode compile succeeds *through*
#   the filesystem jail (fs-jail = required) on the runner's own root fs. Runs
#   directly on the host, not in a container (unlike the steps above).
# Why: the jail's happy path (bind-mounts + pivot_root actually engaging) cannot
#   run inside the buildtools container, whose overlayfs root fails an
#   unprivileged-userns bind-mount (EINVAL); ubuntu-latest's ext4 root can. The
#   proof is not vacuous: serve.c always passes temp_dir as the job dir, so
#   dcc_fs_jail_enter's no-jail early return is unreachable for a server
#   compile, and under `required` the compile is refused unless the jail
#   engaged; with DISTCC_FALLBACK=0 the object can only come from that jailed
#   server compile, and the daemon's --verbose "entered mount-namespace jail"
#   trace confirms it engaged.
# From: Issue #289.
step_fs_jail_e2e() {
    # Ubuntu 24.04 restricts unprivileged user namespaces via AppArmor, which
    # would make the jail's unshare(CLONE_NEWUSER) fail EPERM; relax it,
    # tolerating absence on older kernels. The jail is otherwise unprivileged.
    sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 2>/dev/null || true
    sudo sysctl -w kernel.unprivileged_userns_clone=1 2>/dev/null || true

    local prefix="${RUNNER_TEMP:-/tmp}/distcc-jail-inst"
    local work="${RUNNER_TEMP:-/tmp}/distcc-jail-work"
    local log="${RUNNER_TEMP:-/tmp}/distccd-jail.log"
    local pidfile="${RUNNER_TEMP:-/tmp}/distccd-jail.pid"
    local port=3633

    # Build and install into a throwaway prefix so distcc/distccd/pump/
    # include_server resolve each other by their normal installed paths.
    ( cd "${REPO_ROOT}" \
        && ./autogen.sh \
        && ./configure --with-seccomp PYTHON=python3 --prefix="${prefix}" \
        && make -j"$(nproc)" \
        && make install )
    export PATH="${prefix}/bin:${PATH}"

    # fs-jail = required: read from /etc/distcc/distccd.conf at daemon startup
    # (dcc_seccomp_config_load), so a jail-setup failure refuses the compile
    # rather than silently running it unjailed.
    sudo mkdir -p /etc/distcc
    echo "fs-jail = required" | sudo tee /etc/distcc/distccd.conf >/dev/null

    rm -rf "${work}"; mkdir -p "${work}"
    printf 'int main(void) { return 0; }\n' > "${work}/hello.c"

    # One daemon, --verbose so the jail's DEBUG-level "entered ... jail" trace
    # is emitted; killed on exit.
    distccd --no-detach --daemon --verbose \
        --log-file "${log}" --pid-file "${pidfile}" \
        --port "${port}" --allow 127.0.0.1 --enable-tcp-insecure \
        --lifetime 120 &
    local daemon_pid=$!
    # Expand daemon_pid now, not at EXIT, where this local is out of scope.
    # shellcheck disable=SC2064
    trap "kill ${daemon_pid} 2>/dev/null || true" EXIT

    # Wait for the listener (bash /dev/tcp needs no extra tools).
    for _ in $(seq 1 40); do
        if (exec 3<>/dev/tcp/127.0.0.1/"${port}") 2>/dev/null; then break; fi
        sleep 0.5
    done

    # One real pump-mode compile against only this server, no local fallback.
    export DISTCC_HOSTS="127.0.0.1:${port},cpp,lzo"
    export DISTCC_FALLBACK=0
    ( cd "${work}" && pump distcc gcc -c hello.c -o hello.o ) \
        2> "${work}/compile.err" \
        || { echo "ERROR: pump distcc compile failed"; cat "${work}/compile.err" "${log}"; exit 1; }

    # Assertion 1: a real object came back. With DISTCC_FALLBACK=0 no local
    # compile is possible, so this can only be the jailed server's output.
    [ -s "${work}/hello.o" ] \
        || { echo "ERROR: no/empty object -- jailed server compile produced no output"; cat "${log}"; exit 1; }

    # Assertion 2: the daemon actually entered the jail for this job. The trace
    # may land in the daemon log or the client-returned stderr depending on fd
    # routing, so accept either.
    grep -q "entered mount-namespace jail" "${log}" "${work}/compile.err" \
        || { echo "ERROR: no 'entered mount-namespace jail' trace -- compile did not go through the jail"; cat "${log}"; exit 1; }

    echo "OK: real pump-mode compile succeeded through the fs-jail (object non-empty, jail engaged)."
}

# What: dispatches to the requested verification subcommand.
# Why: keeps the workflows thin orchestrators -- each step is a single
#   `bash docker/verify/ci.sh <subcommand>` call with no embedded logic.
# From: Issue #285, PR #528; Issue #289 (fs-jail-e2e).
case "${1:-}" in
    prepare-etc) step_prepare_etc ;;
    ptrace-selftest) step_ptrace_selftest ;;
    build-test) step_build_test ;;
    ccache-redis) step_ccache_redis ;;
    samba-configure-dryrun) step_samba_configure_dryrun ;;
    fs-jail-e2e) step_fs_jail_e2e ;;
    *)
        echo "usage: $0 {prepare-etc|ptrace-selftest|build-test|ccache-redis|samba-configure-dryrun|fs-jail-e2e}" >&2
        exit 1
        ;;
esac
