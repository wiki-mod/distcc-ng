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
 * What: production Linux mount-namespace filesystem jail for pump-mode
 * compile jobs (see fs-jail.h for the design summary).
 * Why: this replaces issue #289's prototype trust model -- which derived the
 * jail's bind-mount set by walking the job's client-supplied symlink farm --
 * with a server-controlled allowlist, because a trust decision made from
 * client input is exactly the escape vector the jail exists to close (plan
 * section 5).
 * From: Issue #289.
 *
 * Why raw syscalls, not shelling out to unshare(1): the jail must be
 * established, then src/sandbox-seccomp.c's denylist installed, then the
 * compiler exec'd, all in this one process (dcc_inside_child). Shelling out
 * would exec away before the seccomp filter could be installed on the
 * eventual compiler, and the denylist itself blocks unshare/mount/pivot_root
 * -- doing the jail in-process, before the filter, keeps that ordering and
 * still denies those syscalls to the untrusted compiler afterward.
 */

#include <config.h>

#include <string.h>

#include "fs-jail.h"

/**
 * What: see fs-jail.h. Non-zero if canonical absolute @p path equals @p root
 * or is a descendant of it at a path-component boundary.
 * Why: kept out of the __linux__ guard below so it can be unit-tested on any
 * platform (it is pure string logic with no kernel dependency), and because
 * a strncmp() prefix would wrongly accept "/usr-evil" as inside "/usr".
 * From: Issue #289.
 */
int dcc_fs_jail_path_within_root(const char *path, const char *root)
{
    size_t rlen;

    if (path == NULL || root == NULL || path[0] != '/' || root[0] != '/')
        return 0;

    /* Root "/" is the ancestor of every absolute path; its length-1 form
     * would make the component-boundary test below misfire, so handle it
     * explicitly. */
    if (root[1] == '\0')
        return 1;

    rlen = strlen(root);
    if (strncmp(path, root, rlen) != 0)
        return 0;

    /* Exact match, or the next character is the separator -- never a mid-
     * component match like "/usr" against "/usrlocal". */
    return path[rlen] == '\0' || path[rlen] == '/';
}

#ifdef __linux__

/* _GNU_SOURCE is supplied globally by configure.ac's CPPFLAGS; redefining it
 * here is a hard error under this fork's -Werror build. unshare()/CLONE_* and
 * the syscall wrappers below all come from that same global macro. */
#include <sched.h>
#include <sys/syscall.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <limits.h>
#include <fcntl.h>

#include "distcc.h"
#include "trace.h"
#include "sandbox-config.h"

/* What: read-only system roots bind-mounted whole into every jail.
 * Why: these cover the compiler binaries, its sub-programs (cc1/as/ld/
 * collect2) and every system header/library search dir, so header symlinks
 * the include-server mirrors still resolve -- chosen by the server, never
 * from client input (plan section 5.2). A real cross-toolchain rollout
 * (plan section 6) will still need multiarch/clang-resource-dir coverage.
 * From: Issue #289. */
static const char *const dcc_jail_mount_roots[] = {
    "/usr", "/lib", "/lib64", "/bin", "/sbin", NULL
};

/* What: the containment policy -- every read-only mount source's realpath
 * must lie within one of these, or the jail refuses to mount it.
 * Why: broader than dcc_jail_mount_roots (it also admits the individual
 * /etc and /dev entries below) but still a closed set, so a host symlink
 * that pointed a system dir outside these roots is caught rather than
 * silently mounted (plan sections 5.3/5.4).
 * From: Issue #289. */
static const char *const dcc_jail_allowed_roots[] = {
    "/usr", "/lib", "/lib64", "/bin", "/sbin", "/etc", "/dev", NULL
};

/* What: individual /etc files and dirs the dynamic linker and Debian-style
 * compiler-alternative symlinks need.
 * Why: mounting all of /etc would expose /etc/shadow and other host secrets
 * (plan section 70); only these specific entries are bound instead. /dev
 * nodes are bind-mounted individually rather than exposing the host /dev
 * (plan section 7.2), and /proc is deliberately absent (plan section 8).
 * From: Issue #289. */
static const char *const dcc_jail_etc_paths[] = {
    "/etc/ld.so.cache", "/etc/ld.so.conf", "/etc/ld.so.conf.d",
    "/etc/alternatives", NULL
};
static const char *const dcc_jail_dev_nodes[] = {
    "/dev/null", "/dev/zero", "/dev/full", "/dev/random", "/dev/urandom", NULL
};

/**
 * What: return 1 if @p realpath_src is within any dcc_jail_allowed_roots
 * entry, else 0.
 * Why: the runtime application of the containment primitive -- every read-
 * only system mount source is checked through here after realpath(), so a
 * source resolving outside the policy is skipped rather than trusted.
 * From: Issue #289.
 */
static int dcc_jail_source_allowed(const char *realpath_src)
{
    int i;
    for (i = 0; dcc_jail_allowed_roots[i] != NULL; i++)
        if (dcc_fs_jail_path_within_root(realpath_src, dcc_jail_allowed_roots[i]))
            return 1;
    return 0;
}

/**
 * What: bind-mount @p src (a directory or a single file/device node) at the
 * same path under @p jail_root, read-only when @p readonly.
 * Why: returns 0 for both success and a genuinely-absent source (not every
 * host has every path), so a missing optional path is not an error; returns
 * -1 only when a source that does exist could not be mounted, letting the
 * caller decide whether that source was mandatory. A read-only bind needs a
 * second MS_REMOUNT pass on Linux; failing only that is logged, not fatal,
 * since the containment property does not depend on it.
 * From: Issue #289.
 */
static int dcc_jail_bind_mount(const char *src, const char *jail_root,
                               int readonly)
{
    char dst[PATH_MAX];
    struct stat st;

    if (stat(src, &st) != 0)
        return 0; /* absent on this host -- not an error */

    if (snprintf(dst, sizeof dst, "%s%s", jail_root, src) >= (int) sizeof dst) {
        rs_log_warning("fs-jail: mount target path too long, skipping %s", src);
        return -1;
    }

    if (S_ISDIR(st.st_mode)) {
        dcc_mk_tmp_ancestor_dirs(dst);
        mkdir(dst, 0755);
    } else {
        /* A regular file or device node needs an empty file to bind onto. */
        int fd;
        dcc_mk_tmp_ancestor_dirs(dst);
        fd = open(dst, O_WRONLY | O_CREAT, 0644);
        if (fd >= 0)
            close(fd);
    }

    if (mount(src, dst, NULL, MS_BIND, NULL) != 0) {
        rs_log_warning("fs-jail: bind mount %s -> %s failed: %s",
                       src, dst, strerror(errno));
        return -1;
    }
    if (readonly &&
        mount(src, dst, NULL, MS_BIND | MS_REMOUNT | MS_RDONLY, NULL) != 0) {
        rs_log_warning("fs-jail: read-only remount of %s failed "
                       "(mounted read-write instead): %s", dst,
                       strerror(errno));
    }
    return 0;
}

/**
 * What: bind-mount one server-controlled read-only system source, after
 * resolving it and checking it against the containment policy.
 * Why: this is the single choke point where the trust model differs from the
 * prototype -- a source is mounted only if its realpath stays within
 * dcc_jail_allowed_roots, never because a client symlink pointed at it. A
 * source that resolves outside the policy is refused (plan section 5).
 * From: Issue #289.
 */
static int dcc_jail_mount_allowed_source(const char *src, const char *jail_root)
{
    char resolved[PATH_MAX];

    if (realpath(src, resolved) == NULL)
        return 0; /* absent/unresolvable -- treated as not present, not fatal */
    if (!dcc_jail_source_allowed(resolved)) {
        rs_log_warning("fs-jail: refusing to mount %s: resolves to %s, "
                       "outside the allowed-root policy", src, resolved);
        return -1;
    }
    return dcc_jail_bind_mount(resolved, jail_root, 1 /* readonly */);
}

/**
 * What: perform the full jail setup for @p resolved_job_dir; return 0 on
 * success, 1 on a failure before pivot_root (safe to proceed unjailed), or
 * -1 on a failure after pivot_root (jailed but broken -- must refuse).
 * Why: the pre/post-pivot distinction is what makes fs-jail=optional safe --
 * before pivot_root the process still sees the real root, so proceeding
 * unjailed is harmless; after it, the compiler would run in a half-built
 * jail, so the compile must fail regardless of mode (plan section 53).
 * From: Issue #289.
 */
static int dcc_jail_setup(const char *resolved_job_dir, const char *orig_cwd)
{
    char jail_root[] = "/tmp/distccd-fs-jail-XXXXXX";
    uid_t my_uid;
    gid_t my_gid;
    int i, fd;
    char mapbuf[64];
    int maplen;

    /* Real host ids must be read before unshare(): inside a fresh, not-yet-
     * mapped user namespace the kernel reports the overflow id (65534), which
     * would write a silently-wrong uid_map. */
    my_uid = getuid();
    my_gid = getgid();

    if (unshare(CLONE_NEWUSER | CLONE_NEWNS) != 0) {
        rs_log_error("fs-jail: unshare(CLONE_NEWUSER|CLONE_NEWNS) failed: %s",
                     strerror(errno));
        return 1;
    }

    /* Map our own uid/gid to root within this namespace only (no privilege
     * outside it); setgroups must be denied before gid_map is writable by an
     * unprivileged process. Explicit write() error checks, since a wrong-id
     * write here succeeds silently but breaks a later mount. */
    fd = open("/proc/self/setgroups", O_WRONLY);
    if (fd >= 0) {
        if (write(fd, "deny", 4) != 4)
            rs_log_warning("fs-jail: writing setgroups=deny failed: %s",
                           strerror(errno));
        close(fd);
    }
    maplen = snprintf(mapbuf, sizeof mapbuf, "0 %d 1\n", (int) my_uid);
    fd = open("/proc/self/uid_map", O_WRONLY);
    if (fd < 0 || write(fd, mapbuf, maplen) != maplen) {
        rs_log_error("fs-jail: writing uid_map failed: %s", strerror(errno));
        if (fd >= 0) close(fd);
        return 1;
    }
    close(fd);
    maplen = snprintf(mapbuf, sizeof mapbuf, "0 %d 1\n", (int) my_gid);
    fd = open("/proc/self/gid_map", O_WRONLY);
    if (fd < 0 || write(fd, mapbuf, maplen) != maplen) {
        rs_log_error("fs-jail: writing gid_map failed: %s", strerror(errno));
        if (fd >= 0) close(fd);
        return 1;
    }
    close(fd);

    /* Make all mount propagation private so nothing the jail does leaks back
     * into the host mount namespace (plan section 3.4/35). */
    if (mount("/", "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) {
        rs_log_error("fs-jail: mount MS_PRIVATE on / failed: %s",
                     strerror(errno));
        return 1;
    }

    if (mkdtemp(jail_root) == NULL) {
        rs_log_error("fs-jail: mkdtemp failed: %s", strerror(errno));
        return 1;
    }
    if (mount("tmpfs", jail_root, "tmpfs", 0, "mode=0755") != 0) {
        rs_log_error("fs-jail: mount tmpfs on %s failed: %s", jail_root,
                     strerror(errno));
        return 1;
    }

    /* Read-only system roots (mandatory: a failed mount of an existing root
     * means a broken jail, so abort before pivoting). */
    for (i = 0; dcc_jail_mount_roots[i] != NULL; i++) {
        if (dcc_jail_mount_allowed_source(dcc_jail_mount_roots[i],
                                          jail_root) != 0)
            return 1;
    }
    /* Individual /etc and /dev entries (best-effort: a missing one is
     * tolerated; the compile fails loudly later if it truly needed it). */
    for (i = 0; dcc_jail_etc_paths[i] != NULL; i++)
        dcc_jail_mount_allowed_source(dcc_jail_etc_paths[i], jail_root);
    for (i = 0; dcc_jail_dev_nodes[i] != NULL; i++)
        dcc_jail_mount_allowed_source(dcc_jail_dev_nodes[i], jail_root);

    /* The job directory itself, read-write, at its own real absolute path so
     * all of serve.c's temp_dir-based path arithmetic keeps working. It is
     * server-created (mkdtemp), so it is trusted by construction and not
     * subject to the allowed-root policy. Mandatory: this is the one place
     * the compile writes. */
    {
        char dst[PATH_MAX];
        if (snprintf(dst, sizeof dst, "%s%s", jail_root, resolved_job_dir)
                >= (int) sizeof dst) {
            rs_log_error("fs-jail: job-dir mount target too long");
            return 1;
        }
        dcc_mk_tmp_ancestor_dirs(dst);
        mkdir(dst, 0755);
        if (mount(resolved_job_dir, dst, NULL, MS_BIND, NULL) != 0) {
            rs_log_error("fs-jail: bind-mounting job dir %s failed: %s",
                         resolved_job_dir, strerror(errno));
            return 1;
        }
    }

    /* Pivot into the jail. glibc has no pivot_root() wrapper, so it goes
     * through syscall(2) directly. This is the point of no return: any
     * failure after pivot_root succeeds returns -1, never 1. */
    {
        char oldroot[PATH_MAX];
        if (snprintf(oldroot, sizeof oldroot, "%s/oldroot", jail_root)
                >= (int) sizeof oldroot) {
            rs_log_error("fs-jail: oldroot path too long");
            return 1;
        }
        if (mkdir(oldroot, 0700) != 0) {
            rs_log_error("fs-jail: mkdir(%s) failed: %s", oldroot,
                         strerror(errno));
            return 1;
        }
        if (chdir(jail_root) != 0) {
            rs_log_error("fs-jail: chdir(%s) failed: %s", jail_root,
                         strerror(errno));
            return 1;
        }
        if (syscall(SYS_pivot_root, ".", "oldroot") != 0) {
            rs_log_error("fs-jail: pivot_root failed: %s", strerror(errno));
            return 1;
        }
    }

    /* --- past the point of no return: failures below return -1 --- */
    if (chdir("/") != 0) {
        rs_log_error("fs-jail: chdir(/) after pivot_root failed: %s",
                     strerror(errno));
        return -1;
    }
    /* Detach the old root so the host filesystem is fully gone from the jail.
     * umount2(2) is a raw syscall, so unlike umount(8) it needs no /proc. */
    if (umount2("/oldroot", MNT_DETACH) != 0)
        rs_log_warning("fs-jail: detaching old root failed (non-fatal, "
                       "containment already in effect): %s", strerror(errno));
    rmdir("/oldroot");

    /* Restore the job's working directory (serve.c chdir'd here pre-fork and
     * the compiler opens its input by a relative path). Fail-closed: exec'ing
     * from the wrong directory breaks the compile outright. */
    if (chdir(orig_cwd) != 0) {
        rs_log_error("fs-jail: chdir(%s) to restore job cwd inside jail "
                     "failed: %s", orig_cwd, strerror(errno));
        return -1;
    }
    return 0;
}

/**
 * What: see fs-jail.h. Read the configured mode and, unless off, enter a
 * jail for @p job_dir, translating dcc_jail_setup()'s tri-state result into
 * the caller's 0/-1 contract per the configured fail-open/closed mode.
 * Why: keeping the mode/fail-closed decision here (not in dcc_jail_setup)
 * mirrors dcc_seccomp_sandbox_child()'s split and keeps the setup routine a
 * pure success/where-did-it-fail reporter (plan section 53).
 * From: Issue #289.
 */
int dcc_fs_jail_enter(const char *job_dir)
{
    const struct dcc_seccomp_config *cfg;
    enum dcc_fs_jail_mode mode;
    char resolved_job_dir[PATH_MAX];
    char orig_cwd[PATH_MAX];
    int r;

    if (job_dir == NULL)
        return 0; /* plain mode: no directory tree to jail */

    cfg = dcc_seccomp_config_get();
    mode = cfg->fs_jail_mode;
    if (mode == DCC_FS_JAIL_OFF)
        return 0;

    /* Capture cwd before any chdir here, and resolve the job dir while the
     * real root is still visible. */
    if (getcwd(orig_cwd, sizeof orig_cwd) == NULL) {
        rs_log_error("fs-jail: getcwd() failed: %s", strerror(errno));
        return mode == DCC_FS_JAIL_REQUIRED ? -1 : 0;
    }
    if (realpath(job_dir, resolved_job_dir) == NULL) {
        rs_log_error("fs-jail: realpath(%s) failed: %s", job_dir,
                     strerror(errno));
        return mode == DCC_FS_JAIL_REQUIRED ? -1 : 0;
    }

    r = dcc_jail_setup(resolved_job_dir, orig_cwd);
    if (r == 0) {
        rs_trace("fs-jail: entered mount-namespace jail for %s",
                 resolved_job_dir);
        return 0;
    }
    if (r < 0) {
        rs_log_error("fs-jail: setup failed past the point of no return, "
                     "refusing compile");
        return -1;
    }
    /* r > 0: failed before pivot_root, still on the real root. */
    if (mode == DCC_FS_JAIL_REQUIRED) {
        rs_log_error("fs-jail: setup failed and fs-jail=required, refusing "
                     "compile");
        return -1;
    }
    rs_log_warning("fs-jail: setup failed, proceeding unjailed "
                   "(fs-jail=optional)");
    return 0;
}

#else /* !__linux__ */

/**
 * What: non-Linux no-op -- mount namespaces are Linux-only.
 * Why: per doc/compatibility-policy.md this must never become a hard
 * dependency or change behaviour on macOS/FreeBSD; a real backend there
 * (sandbox-exec/jails) is a separate, deferred effort (plan section 55).
 * From: Issue #289.
 */
int dcc_fs_jail_enter(const char *job_dir)
{
    (void) job_dir;
    return 0;
}

#endif /* __linux__ */
