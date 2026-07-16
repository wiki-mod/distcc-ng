/* -*- c-file-style: "java"; indent-tabs-mode: nil; tab-width: 4; fill-column: 78 -*-
 *
 * distcc -- A simple distributed compiler system
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,
 * USA.
 */

/**
 * @file
 *
 * Linux seccomp sandboxing for distccd's compiler children (issue #68,
 * originally distcc/distcc#233 "daemon: add seccomp filter on Linux").
 *
 * distcc/distcc#233 was never merged upstream and could not be ported
 * as-is: it applied an OpenSSH privilege-separation preauth filter
 * (references to ssh-sandbox.h, pmonitor, mm_log_handler that don't
 * exist in distcc) to the whole daemon process in main(), with an
 * allowlist that omits execve/fork/socket/accept -- installing it there
 * would have killed distccd itself the moment it tried to serve a
 * connection, not just constrained the compiler it spawns.
 *
 * This is a from-scratch design for the current codebase instead of a
 * literal port:
 *
 *   - Installed per-job, in the forked child in dcc_inside_child()
 *     (src/exec.c), only for the daemon's own compile spawn (src/serve.c),
 *     immediately before exec'ing the client-supplied compiler. Plain
 *     `distcc`/`cpp` local invocations (src/compile.c, src/cpp.c) are not
 *     sandboxed -- those run a trusted local build, not a remote client's
 *     job, so there is nothing to contain there.
 *
 *   - A denylist, not an allowlist. distccd has to run whatever compiler
 *     a client names (gcc, clang, any cross-compiler), each of which may
 *     itself fork further sub-processes (cc1, as, ld, collect2, LTO
 *     plugins). Enumerating a syscall allowlist complete enough to cover
 *     all of that, for every compiler this fork's users might point
 *     distccd at, is not something that can be verified by testing one
 *     compiler locally -- a filter that's too narrow breaks real builds
 *     in ways that only surface later, in production, for someone else's
 *     compiler. A denylist targeting syscalls no legitimate compiler
 *     invocation needs (kernel/module tampering, raw hardware access,
 *     ptrace-based introspection, ...) is weaker as a security boundary,
 *     but ships something that can actually be validated end-to-end
 *     against a real gcc invocation, and is meant as defense-in-depth
 *     layered on top of the compiler whitelist and unsafe-option checks
 *     src/serve.c already performs before the child is even forked --
 *     not as the sole thing standing between a hostile client and the
 *     host.
 *
 *   - No new hard dependency: libseccomp is detected at configure time
 *     (`--with-seccomp`/`--without-seccomp`, `configure.ac`) exactly like
 *     the optional zstd support in src/compress-zstd.c, and this file
 *     compiles to a no-op everywhere HAVE_SECCOMP isn't defined (older
 *     libseccomp-less systems, and non-Linux platforms), per
 *     doc/compatibility-policy.md.
 **/

#include <config.h>

#include "distcc.h"
#include "trace.h"
#include "sandbox-seccomp.h"

#ifdef HAVE_SECCOMP

#include <errno.h>
#include <string.h>
#include <sys/prctl.h>
#include <seccomp.h>

/**
 * Syscalls a legitimate compiler invocation (including its sub-processes:
 * cc1, as, ld, collect2, LTO plugins) never needs, grouped by the class of
 * mischief they enable. Listed by name and resolved at runtime via
 * seccomp_syscall_resolve_name() rather than the SCMP_SYS() macro: that
 * macro expands directly to the kernel's __NR_* constant and fails the
 * *build* if a name is missing on some architecture/libc combination this
 * fork targets, whereas the runtime resolver just returns "not found" for
 * a syscall that doesn't exist here, which we then simply skip -- the
 * denylist degrades per-architecture instead of needing every name kept
 * in lockstep with every target's kernel headers.
 **/
static const char *const dcc_seccomp_denied_syscalls[] = {
    /* Kernel/module/hardware tampering. */
    "reboot", "init_module", "finit_module", "delete_module",
    "iopl", "ioperm", "kexec_load", "kexec_file_load",
    "swapon", "swapoff", "mount", "umount2", "pivot_root",
    "quotactl", "acct",

    /* Introspection/escape primitives with no compiler use case. */
    "ptrace", "process_vm_readv", "process_vm_writev", "kcmp",
    "setns", "unshare", "personality",

    /* Kernel keyring / eBPF / perf: no compiler needs these, and each has
     * been a real privilege-escalation vector in its own right. */
    "add_key", "request_key", "keyctl", "bpf", "perf_event_open",

    /* Host clock/identity tampering. */
    "settimeofday", "clock_settime", "adjtimex", "clock_adjtime",
    "sethostname", "setdomainname",
};

/**
 * Install the syscall denylist in the calling process and load it.
 *
 * Every failure path here logs a warning and returns rather than aborting
 * the compile (fail-open, not fail-closed): this filter is explicitly
 * defense-in-depth on top of the checks src/serve.c already performs
 * before the child is forked (compiler whitelist, -fplugin/-specs
 * rejection, compiler masquerade check), not the only thing protecting
 * the host. Refusing every remote compile because one host's kernel has
 * seccomp disabled, is missing a syscall this libseccomp version expects,
 * or is running nested inside a container that itself restricts seccomp
 * would be an availability regression far larger than the additional
 * hardening lost by letting that one compile proceed unsandboxed -- and
 * would silently turn a hardening feature into an outage. An admin who
 * wants to confirm the filter is actually active on their kernel can
 * grep the daemon's log for the failure message this emits.
 **/
void dcc_seccomp_sandbox_child(void)
{
    scmp_filter_ctx ctx;
    size_t i;
    int rc;
    int syscall_nr;

    ctx = seccomp_init(SCMP_ACT_ALLOW);
    if (ctx == NULL) {
        rs_log_warning("seccomp_init() failed; running this compile without "
                       "a seccomp sandbox");
        return;
    }

    for (i = 0; i < sizeof(dcc_seccomp_denied_syscalls) /
                    sizeof(dcc_seccomp_denied_syscalls[0]); i++) {
        syscall_nr = seccomp_syscall_resolve_name(
            dcc_seccomp_denied_syscalls[i]);
        if (syscall_nr == __NR_SCMP_ERROR) {
            /* Doesn't exist on this architecture/libseccomp version --
             * nothing to deny, move on rather than failing the sandbox. */
            continue;
        }

        /* SCMP_ACT_ERRNO (not KILL): a denied call fails like an
         * unsupported/EPERM syscall normally would, rather than the
         * process dying to SIGSYS -- so if this denylist is ever wrong
         * about what a compiler needs, the failure looks like an
         * ordinary compiler error instead of an opaque crash. */
        rc = seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM), syscall_nr, 0);
        if (rc < 0) {
            rs_log_warning("seccomp_rule_add(%s) failed: %s; running this "
                           "compile without a seccomp sandbox",
                           dcc_seccomp_denied_syscalls[i], strerror(-rc));
            seccomp_release(ctx);
            return;
        }
    }

    /* The kernel requires PR_SET_NO_NEW_PRIVS before an unprivileged
     * process may install a seccomp filter. distccd's compiler children
     * never legitimately need to gain privileges via a setuid/setgid
     * binary, so this has no functional downside here. */
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
        rs_log_warning("prctl(PR_SET_NO_NEW_PRIVS) failed: %s; running this "
                       "compile without a seccomp sandbox",
                       strerror(errno));
        seccomp_release(ctx);
        return;
    }

    rc = seccomp_load(ctx);
    if (rc < 0) {
        rs_log_warning("seccomp_load() failed: %s; running this compile "
                       "without a seccomp sandbox", strerror(-rc));
    }

    /* seccomp_load() copies the compiled filter into the kernel; the
     * userspace context is no longer needed whether or not it succeeded. */
    seccomp_release(ctx);
}

/**
 * Called once from distccd's main() so a warning shows up in the daemon's
 * own log immediately if this hardening layer is compiled in, rather than
 * only being discovered later during a security review.
 **/
void dcc_seccomp_log_availability(void)
{
    rs_log_info("seccomp sandbox enabled for remote compiler processes");
}

#else /* !HAVE_SECCOMP */

/**
 * Built without libseccomp (see configure.ac's --with-seccomp /
 * --without-seccomp), or on a non-Linux host: nothing to install. Kept as
 * a real function (rather than requiring callers to #ifdef) so exec.c and
 * daemon.c don't need to know whether this build has seccomp support.
 **/
void dcc_seccomp_sandbox_child(void)
{
}

/**
 * See the HAVE_SECCOMP branch above; this is the "hardening is not
 * available" half of the same one-time startup notice.
 **/
void dcc_seccomp_log_availability(void)
{
    rs_log_warning("built without libseccomp support (or non-Linux host): "
                   "remote compiler processes will run without a seccomp "
                   "sandbox; rebuild with libseccomp installed for this "
                   "defense-in-depth hardening layer");
}

#endif /* HAVE_SECCOMP */
