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
#include <stdlib.h>
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

#define DCC_SECCOMP_BUILTIN_COUNT \
    (sizeof(dcc_seccomp_denied_syscalls) / sizeof(dcc_seccomp_denied_syscalls[0]))

/**
 * Syscalls that establish a network connection or move data over one.
 * Only added to the filter when the config's `deny-network` key (default
 * false) turns this on -- see issue #192. Not part of the always-on
 * built-in denylist above because plenty of legitimate distcc deployments
 * have no reason to expect their compiler child to touch the network at
 * all, but this fork's default posture (issue #192 decision 1) is to leave
 * that choice to the admin rather than assume it either way.
 *
 * Deliberately does not include getsockopt/setsockopt/getsockname/
 * getpeername/fcntl-on-a-socket: those inspect or tune an *already open*
 * descriptor rather than establish a new connection or move data, and a
 * compiler child has no legitimate open socket to begin with once this
 * list below is active, so they add no real restriction of their own.
 * Note the hard limit on what this can express at all: seccomp/BPF only
 * sees the syscall number and scalar arguments, never the contents of a
 * pointer argument like connect()'s sockaddr* -- so this can block "any
 * networking" but cannot express "only same-subnet" or any other
 * destination-aware policy. See doc/seccomp-sandbox.md.
 **/
static const char *const dcc_seccomp_network_syscalls[] = {
    "socket", "socketpair", "connect", "bind", "listen",
    "accept", "accept4", "sendto", "recvfrom", "sendmsg", "recvmsg",
    "sendmmsg", "recvmmsg", "shutdown",
};

#define DCC_SECCOMP_NETWORK_COUNT \
    (sizeof(dcc_seccomp_network_syscalls) / sizeof(dcc_seccomp_network_syscalls[0]))

/* Cached, resolved effective configuration -- computed once by
 * dcc_seccomp_configure() so dcc_seccomp_sandbox_child() (called once per
 * forked child, i.e. once per remote compile) never has to re-parse a
 * config file, re-walk allow_override/extra_deny strings, or re-log a
 * warning that's already been logged at startup. */
static int dcc_seccomp_cfg_enabled = 1;
static int dcc_seccomp_cfg_deny_network = 0;
static int dcc_seccomp_cfg_fail_open = 1;
static int *dcc_seccomp_effective_denylist = NULL;
static size_t dcc_seccomp_effective_denylist_count = 0;
static int *dcc_seccomp_effective_network_list = NULL;
static size_t dcc_seccomp_effective_network_list_count = 0;
static int dcc_seccomp_configured = 0;

/**
 * True if @p name is one of the always-on built-in denylist entries above
 * -- used by dcc_seccomp_configure() to tell an actual override apart from
 * an allow-override entry that names something not in the built-in list to
 * begin with (which is harmless but worth a different, lower-severity log
 * message).
 **/
static int dcc_seccomp_name_in_builtin(const char *name)
{
    size_t i;
    for (i = 0; i < DCC_SECCOMP_BUILTIN_COUNT; i++) {
        if (strcmp(dcc_seccomp_denied_syscalls[i], name) == 0)
            return 1;
    }
    return 0;
}

/**
 * Resolve @p name to a kernel syscall number via libseccomp's runtime name
 * table, exactly as the built-in list already does (see the file comment
 * above dcc_seccomp_denied_syscalls for why this is done by name at
 * runtime rather than SCMP_SYS() at compile time). Returns -1 for a name
 * that doesn't exist on this architecture/libseccomp version rather than
 * libseccomp's own __NR_SCMP_ERROR sentinel, so callers outside this file
 * never need to know that libseccomp-specific constant.
 **/
static int dcc_seccomp_resolve(const char *name)
{
    int nr = seccomp_syscall_resolve_name(name);
    return (nr == __NR_SCMP_ERROR) ? -1 : nr;
}

/**
 * Free a previously computed effective list (if any) so dcc_seccomp_configure()
 * can be called more than once (e.g. by a future test harness) without
 * leaking the array from an earlier call.
 **/
static void dcc_seccomp_free_effective_lists(void)
{
    free(dcc_seccomp_effective_denylist);
    dcc_seccomp_effective_denylist = NULL;
    dcc_seccomp_effective_denylist_count = 0;
    free(dcc_seccomp_effective_network_list);
    dcc_seccomp_effective_network_list = NULL;
    dcc_seccomp_effective_network_list_count = 0;
}

/**
 * See sandbox-seccomp.h. Computes and caches everything
 * dcc_seccomp_sandbox_child() needs so that function stays cheap enough to
 * call on every fork: the effective denylist (built-in list, plus
 * config's `extra-deny`, minus config's `allow-override`, all resolved to
 * syscall numbers up front), the resolved network-syscall group, and the
 * enabled/deny-network/fail-open flags themselves.
 *
 * `cfg->require_seccomp` is deliberately not read here: it answers "must
 * this distccd have been *compiled* with libseccomp support at all",
 * which is trivially true in this HAVE_SECCOMP build -- it only has a
 * decision to make in the non-HAVE_SECCOMP branch below, where the
 * sandbox was never compiled in to begin with.
 **/
void dcc_seccomp_configure(const struct dcc_seccomp_config *cfg)
{
    size_t i;
    size_t cap;
    int *list;
    size_t count;

    dcc_seccomp_free_effective_lists();

    dcc_seccomp_cfg_enabled = cfg->enabled;
    dcc_seccomp_cfg_deny_network = cfg->deny_network;
    dcc_seccomp_cfg_fail_open = cfg->fail_open;

    /* Built-in list minus allow-override, plus room to grow for
     * extra-deny -- sized generously up front since this only runs once
     * at startup, not per compile. */
    cap = DCC_SECCOMP_BUILTIN_COUNT;
    for (i = 0; cfg->extra_deny[i] != NULL; i++)
        cap++;
    list = (int *) malloc((cap > 0 ? cap : 1) * sizeof(int));
    count = 0;

    for (i = 0; i < DCC_SECCOMP_BUILTIN_COUNT; i++) {
        const char *name = dcc_seccomp_denied_syscalls[i];
        size_t j;
        int overridden = 0;
        int nr;

        for (j = 0; cfg->allow_override[j] != NULL; j++) {
            if (strcmp(cfg->allow_override[j], name) == 0) {
                overridden = 1;
                break;
            }
        }
        if (overridden) {
            /* Named explicitly, per issue #192, rather than just a count --
             * an admin auditing why ptrace() suddenly works again needs
             * this line to say so directly. */
            rs_log_warning("seccomp config: 'allow-override' removes '%s' "
                            "from the built-in denylist", name);
            continue;
        }

        /* Mirror the extra_deny loop below: dcc_seccomp_resolve() returns
         * -1 for a syscall name libseccomp doesn't know on this
         * architecture. Storing that -1 uncritically would later reach
         * seccomp_rule_add(..., -1, ...), which fails -- breaking seccomp
         * setup for every compile because of one unresolvable built-in
         * name, not just skipping that one syscall. */
        nr = dcc_seccomp_resolve(name);
        if (nr < 0) {
            rs_log_warning("seccomp config: built-in denylist syscall '%s' "
                            "could not be resolved on this architecture; "
                            "skipping", name);
            continue;
        }
        if (list != NULL)
            list[count++] = nr;
    }

    for (i = 0; cfg->extra_deny[i] != NULL; i++) {
        int nr = dcc_seccomp_resolve(cfg->extra_deny[i]);
        if (nr < 0) {
            rs_log_warning("seccomp config: 'extra-deny' names unknown "
                            "syscall '%s' on this architecture; ignoring",
                            cfg->extra_deny[i]);
            continue;
        }
        if (list != NULL)
            list[count++] = nr;
    }

    /* Warn about allow-override entries that named something harmless
     * rather than an actual built-in syscall -- almost certainly a typo,
     * and worth flagging distinctly from "successfully removed X". */
    for (i = 0; cfg->allow_override[i] != NULL; i++) {
        if (!dcc_seccomp_name_in_builtin(cfg->allow_override[i]))
            rs_log_info("seccomp config: 'allow-override' names '%s', which "
                        "is not in the built-in denylist; nothing to remove",
                        cfg->allow_override[i]);
    }

    dcc_seccomp_effective_denylist = list;
    dcc_seccomp_effective_denylist_count = count;

    /* Network group: always resolved (cheap, done once), only actually
     * applied per-child when deny_network is set -- see
     * dcc_seccomp_sandbox_child(). */
    list = (int *) malloc(DCC_SECCOMP_NETWORK_COUNT * sizeof(int));
    count = 0;
    for (i = 0; i < DCC_SECCOMP_NETWORK_COUNT; i++) {
        int nr = dcc_seccomp_resolve(dcc_seccomp_network_syscalls[i]);
        if (nr < 0)
            continue;
        if (list != NULL)
            list[count++] = nr;
    }
    dcc_seccomp_effective_network_list = list;
    dcc_seccomp_effective_network_list_count = count;

    dcc_seccomp_configured = 1;
}

/**
 * Install the effective syscall denylist (see dcc_seccomp_configure()) in
 * the calling process and load it.
 *
 * Fail-open (config default) vs. fail-closed is the only thing that
 * changes what a failure path here does: fail-open logs a warning and
 * returns 0 so the caller proceeds to exec the compiler unsandboxed
 * (this is the exact prior behavior of this function before issue #192);
 * fail-closed logs a warning and returns -1, so the caller (see
 * dcc_inside_child() in exec.c) refuses the compile via the same ordinary
 * failure path an actual compiler error would take, rather than a new ad
 * hoc one. Rationale for why fail-open remains the *default*: this filter
 * is explicitly defense-in-depth on top of the checks src/serve.c already
 * performs before the child is forked (compiler whitelist, -fplugin/
 * -specs rejection, compiler masquerade check), not the only thing
 * protecting the host, so an admin who hasn't opted into fail-closed
 * shouldn't have one host's seccomp-incompatible kernel turn into a
 * blanket compile-farm outage.
 **/
int dcc_seccomp_sandbox_child(void)
{
    scmp_filter_ctx ctx;
    size_t i;
    int rc;

    if (!dcc_seccomp_configured) {
        /* Defensive: dcc_seccomp_configure() should always have run by
         * the time a compile is spawned (see src/daemon.c's main()), but
         * if it somehow hasn't, fall back to "sandbox active with
         * built-in defaults" rather than silently running unsandboxed. */
        static const struct dcc_seccomp_config defaults = {
            1, 0, 1, 0, NULL, NULL
        };
        static char *empty_list[] = { NULL };
        struct dcc_seccomp_config safe_defaults = defaults;
        safe_defaults.extra_deny = empty_list;
        safe_defaults.allow_override = empty_list;
        dcc_seccomp_configure(&safe_defaults);
    }

    if (!dcc_seccomp_cfg_enabled) {
        /* enabled = false: a genuine no-op, equivalent to
         * --without-seccomp at configure time -- nothing is installed,
         * nothing to fail open or closed on. */
        return 0;
    }

    ctx = seccomp_init(SCMP_ACT_ALLOW);
    if (ctx == NULL) {
        rs_log_warning("seccomp_init() failed; %s",
                       dcc_seccomp_cfg_fail_open
                           ? "running this compile without a seccomp sandbox"
                           : "refusing this compile (fail-open disabled)");
        return dcc_seccomp_cfg_fail_open ? 0 : -1;
    }

    for (i = 0; i < dcc_seccomp_effective_denylist_count; i++) {
        /* SCMP_ACT_ERRNO (not KILL): a denied call fails like an
         * unsupported/EPERM syscall normally would, rather than the
         * process dying to SIGSYS -- so if this denylist is ever wrong
         * about what a compiler needs, the failure looks like an
         * ordinary compiler error instead of an opaque crash. */
        rc = seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM),
                              dcc_seccomp_effective_denylist[i], 0);
        if (rc < 0) {
            rs_log_warning("seccomp_rule_add() failed: %s; %s",
                           strerror(-rc),
                           dcc_seccomp_cfg_fail_open
                               ? "running this compile without a seccomp "
                                 "sandbox"
                               : "refusing this compile (fail-open "
                                 "disabled)");
            seccomp_release(ctx);
            return dcc_seccomp_cfg_fail_open ? 0 : -1;
        }
    }

    if (dcc_seccomp_cfg_deny_network) {
        for (i = 0; i < dcc_seccomp_effective_network_list_count; i++) {
            rc = seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EPERM),
                                  dcc_seccomp_effective_network_list[i], 0);
            if (rc < 0) {
                rs_log_warning("seccomp_rule_add() failed for network "
                               "syscall: %s; %s", strerror(-rc),
                               dcc_seccomp_cfg_fail_open
                                   ? "running this compile without a "
                                     "seccomp sandbox"
                                   : "refusing this compile (fail-open "
                                     "disabled)");
                seccomp_release(ctx);
                return dcc_seccomp_cfg_fail_open ? 0 : -1;
            }
        }
    }

    /* The kernel requires PR_SET_NO_NEW_PRIVS before an unprivileged
     * process may install a seccomp filter. distccd's compiler children
     * never legitimately need to gain privileges via a setuid/setgid
     * binary, so this has no functional downside here. */
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
        rs_log_warning("prctl(PR_SET_NO_NEW_PRIVS) failed: %s; %s",
                       strerror(errno),
                       dcc_seccomp_cfg_fail_open
                           ? "running this compile without a seccomp sandbox"
                           : "refusing this compile (fail-open disabled)");
        seccomp_release(ctx);
        return dcc_seccomp_cfg_fail_open ? 0 : -1;
    }

    rc = seccomp_load(ctx);
    seccomp_release(ctx);
    if (rc < 0) {
        rs_log_warning("seccomp_load() failed: %s; %s", strerror(-rc),
                       dcc_seccomp_cfg_fail_open
                           ? "running this compile without a seccomp sandbox"
                           : "refusing this compile (fail-open disabled)");
        return dcc_seccomp_cfg_fail_open ? 0 : -1;
    }

    return 0;
}

/**
 * Called once from distccd's main() so a warning shows up in the daemon's
 * own log immediately if this hardening layer is compiled in, rather than
 * only being discovered later during a security review. Reflects the
 * config's `enabled` key too, since "compiled in but administratively
 * disabled" is just as important for an admin to see at a glance as
 * "not compiled in at all".
 **/
void dcc_seccomp_log_availability(void)
{
    if (dcc_seccomp_configured && !dcc_seccomp_cfg_enabled)
        rs_log_info("seccomp sandbox compiled in but disabled via "
                    "'enabled = false' in the seccomp config; remote "
                    "compiler processes will run unsandboxed");
    else
        rs_log_info("seccomp sandbox enabled for remote compiler processes");
}

#else /* !HAVE_SECCOMP */

/* `fail-open`/`fail-closed` has no scope here: it only governs a build
 * that *can* sandbox (see the HAVE_SECCOMP branch above) genuinely
 * failing to install the filter at runtime, which cannot happen in a
 * build that never compiled the sandbox in to begin with. `require-
 * seccomp` is the deliberately separate switch for *this* build
 * configuration -- "was the sandbox ever compiled in at all" is a
 * different question from "did installing it fail at runtime", and this
 * fork keeps them on independent switches rather than folding one into
 * the other: an admin who wants "refuse if the sandbox breaks at
 * runtime" on their libseccomp hosts should not also be forced into (or
 * exempted from) "refuse every host that never had libseccomp installed
 * at all" as a side effect of that same setting. */
static int dcc_seccomp_stub_require_seccomp = 0;
static int dcc_seccomp_stub_configured = 0;

/**
 * See sandbox-seccomp.h. In a build without libseccomp there is nothing to
 * resolve or cache except the require-seccomp flag itself -- fail-open
 * has no meaning here (see the file comment above).
 **/
void dcc_seccomp_configure(const struct dcc_seccomp_config *cfg)
{
    dcc_seccomp_stub_require_seccomp = cfg->require_seccomp;
    dcc_seccomp_stub_configured = 1;
}

/**
 * Built without libseccomp (see configure.ac's --with-seccomp /
 * --without-seccomp), or on a non-Linux host: nothing to install. Kept as
 * a real function (rather than requiring callers to #ifdef) so exec.c and
 * daemon.c don't need to know whether this build has seccomp support.
 * Honors only `require-seccomp` here (see the file comment above for why
 * `fail-open` is out of scope in this build): default false preserves
 * this build's original behavior of always proceeding unsandboxed; true
 * refuses every remote compile outright, for an admin who wants "this
 * host must have the sandbox available at all" enforced regardless of
 * what any single compile's own runtime failure mode would have been.
 **/
int dcc_seccomp_sandbox_child(void)
{
    if (dcc_seccomp_stub_configured && dcc_seccomp_stub_require_seccomp) {
        rs_log_warning("refusing this compile: 'require-seccomp = true' in "
                       "the seccomp config, but this distccd was built "
                       "without libseccomp support (or is running on a "
                       "non-Linux host) and cannot sandbox it");
        return -1;
    }
    return 0;
}

/**
 * See the HAVE_SECCOMP branch above; this is the "hardening is not
 * available" half of the same one-time startup notice. Also flags
 * whether `require-seccomp` will actually turn that unavailability into
 * refused compiles on this host, since that's the difference between an
 * administrator's expected hardening posture and an unexpected outage.
 **/
void dcc_seccomp_log_availability(void)
{
    if (dcc_seccomp_stub_configured && dcc_seccomp_stub_require_seccomp)
        rs_log_warning("built without libseccomp support (or non-Linux "
                       "host), and 'require-seccomp = true' in the seccomp "
                       "config: every remote compile on this host will be "
                       "refused until it is rebuilt with libseccomp");
    else
        rs_log_warning("built without libseccomp support (or non-Linux host): "
                       "remote compiler processes will run without a seccomp "
                       "sandbox; rebuild with libseccomp installed for this "
                       "defense-in-depth hardening layer");
}

#endif /* HAVE_SECCOMP */
