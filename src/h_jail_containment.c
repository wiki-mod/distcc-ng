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
 * What: end-to-end containment proof for the filesystem jail (issue #289).
 * Enters a real fs-jail=required jail via dcc_fs_jail_enter(), then checks
 * from inside it that the allowlist survives, a host secret and /proc are
 * absent, and a #95-style escape symlink cannot resolve outside the jail.
 * Why: src/h_fs_jail.c already unit-tests the pure containment string logic;
 * this is the one harness that calls dcc_fs_jail_enter() itself and checks
 * its real, kernel-enforced pivot_root result.
 * From: Issue #289.
 *
 * Needs a working unprivileged user+mount namespace with a real bind mount;
 * dcc_probe_userns_bind_mount() below checks that separately, before
 * dcc_fs_jail_enter() is ever called.
 */

/* What: define _GNU_SOURCE before any header so unshare()/CLONE_NEWUSER/
 * CLONE_NEWNS/mkdtemp()/mkstemp() are declared.
 * Why: mirrors fs-jail.c's own guard -- the CI fuzzer harness build compiles
 * this file standalone, without configure.ac's global CPPFLAGS.
 * From: Issue #289. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <config.h>

#include <stdio.h>
#include <stdlib.h>

#include "fs-jail.h"

const char *rs_program_name = __FILE__;

#ifdef __linux__

#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <fcntl.h>
#include <sched.h>
#include <sys/wait.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>

#include "sandbox-config.h"

/* What: process exit code meaning "this environment cannot run the test",
 * distinct from 0 (pass) and 1 (fail).
 * Why: comfychair/automake both treat 77 as a skip, letting this harness
 * report "not testable here" (an overlay-root CI container) without either
 * a false pass or a false fail.
 * From: Issue #289. */
#define DCC_JAIL_TEST_SKIP 77

static int failures;

/**
 * What: in a forked child, attempt the same minimal unprivileged
 * user+mount-namespace steps dcc_fs_jail_enter() itself performs (unshare,
 * uid/gid mapping, one real bind mount), reporting success via the child's
 * exit status; a throwaway child keeps the harness's own namespaces
 * untouched if the probe fails partway through.
 * Why: some hosts let unshare(CLONE_NEWUSER|CLONE_NEWNS) succeed but still
 * refuse the bind mount itself (an overlay-root container, a restrictive
 * LSM policy), so only a real bind-mount attempt tells this harness whether
 * fs-jail is testable here at all.
 * From: Issue #289.
 */
static int dcc_probe_userns_bind_mount(void)
{
    char scratch[PATH_MAX];
    char dst[PATH_MAX];
    pid_t pid;
    int status;
    int ok;

    strcpy(scratch, "/tmp/h_jail_containment_probe.XXXXXX");
    if (mkdtemp(scratch) == NULL)
        return -1;
    if (snprintf(dst, sizeof dst, "%s/dst", scratch) >= (int) sizeof dst) {
        rmdir(scratch);
        return -1;
    }
    if (mkdir(dst, 0700) != 0) {
        rmdir(dst);
        rmdir(scratch);
        return -1;
    }

    pid = fork();
    if (pid < 0) {
        rmdir(dst);
        rmdir(scratch);
        return -1;
    }

    if (pid == 0) {
        uid_t my_uid = getuid();
        gid_t my_gid = getgid();
        char mapbuf[64];
        int maplen, fd;

        if (unshare(CLONE_NEWUSER | CLONE_NEWNS) != 0)
            _exit(1);

        fd = open("/proc/self/setgroups", O_WRONLY);
        if (fd >= 0) {
            if (write(fd, "deny", 4) != 4)
                _exit(1);
            close(fd);
        }
        maplen = snprintf(mapbuf, sizeof mapbuf, "0 %d 1\n", (int) my_uid);
        fd = open("/proc/self/uid_map", O_WRONLY);
        if (fd < 0 || write(fd, mapbuf, maplen) != maplen)
            _exit(1);
        close(fd);
        maplen = snprintf(mapbuf, sizeof mapbuf, "0 %d 1\n", (int) my_gid);
        fd = open("/proc/self/gid_map", O_WRONLY);
        if (fd < 0 || write(fd, mapbuf, maplen) != maplen)
            _exit(1);
        close(fd);

        /* Make propagation private, then bind an overlay-backed system root
         * exactly as dcc_jail_setup() does. Binding a tmpfs path (e.g. a
         * fresh /tmp dir) would succeed even in an overlay-root container and
         * mask the real EINVAL the jail hits binding /usr there, giving a
         * false "testable" and turning a legitimate skip into a failure. */
        if (mount("/", "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0)
            _exit(1);
        _exit(mount("/usr", dst, NULL, MS_BIND, NULL) == 0 ? 0 : 1);
    }

    ok = (waitpid(pid, &status, 0) == pid) && WIFEXITED(status) &&
        WEXITSTATUS(status) == 0;
    rmdir(dst);
    rmdir(scratch);
    return ok ? 0 : -1;
}

/**
 * What: fail (increment the shared counter) unless @p path is reachable
 * inside the jail; @p what labels the case in the failure message.
 * Why: an allowlist entry must stay reachable, or the jail broke the
 * compiler's own header/library search path, not just its containment.
 * From: Issue #289.
 */
static void assert_present(const char *path, const char *what)
{
    if (access(path, F_OK) != 0) {
        fprintf(stderr, "FAIL: %s (%s) not reachable inside the jail: %s\n",
                what, path, strerror(errno));
        failures++;
    }
}

/**
 * What: fail unless @p path is unreachable (ENOENT) inside the jail; @p
 * what labels the case in the failure message.
 * Why: the jail's containment claim rests on everything outside the
 * allowlist being genuinely absent, not merely unreadable -- a non-ENOENT
 * errno is noted but does not by itself count as a pass.
 * From: Issue #289.
 */
static void assert_absent(const char *path, const char *what)
{
    if (access(path, F_OK) == 0) {
        fprintf(stderr, "FAIL: %s (%s) is reachable inside the jail, "
                "expected absent\n", what, path);
        failures++;
    } else if (errno != ENOENT) {
        fprintf(stderr, "NOTE: %s (%s) absent via errno %d (%s), not ENOENT\n",
                what, path, errno, strerror(errno));
    }
}

/**
 * What: probe namespace support, then enter a real fs-jail=required jail
 * and assert what is/isn't reachable from inside it, including a #95-style
 * escape symlink planted in the job directory.
 * Why: this is the one harness that actually calls dcc_fs_jail_enter() and
 * checks its real, kernel-enforced result rather than the allowlist's pure
 * comparison logic (already covered by h_fs_jail.c).
 * From: Issue #289.
 */
int main(void)
{
    struct stat st;
    char job_dir[PATH_MAX];
    char resolved_job_dir[PATH_MAX];
    char escape_path[PATH_MAX];
    char conf_path[PATH_MAX];
    char jail_root_path[PATH_MAX];
    FILE *conf;
    int rc;

    /* Without a host secret to target, the escape/absence assertions below
     * would prove nothing -- some minimal container images strip it. */
    if (stat("/etc/shadow", &st) != 0) {
        printf("h_jail_containment: skip (/etc/shadow absent on this host, "
               "no host secret to prove containment against)\n");
        return DCC_JAIL_TEST_SKIP;
    }

    if (dcc_probe_userns_bind_mount() != 0) {
        printf("h_jail_containment: skip (unprivileged user+mount namespace "
               "with a real bind mount is not usable here, e.g. an "
               "overlay-root container or a restrictive kernel/LSM policy)\n");
        return DCC_JAIL_TEST_SKIP;
    }

    strcpy(job_dir, "/tmp/h_jail_containment_job.XXXXXX");
    if (mkdtemp(job_dir) == NULL) {
        fprintf(stderr, "h_jail_containment: mkdtemp(%s) failed: %s\n",
                job_dir, strerror(errno));
        return 1;
    }
    if (realpath(job_dir, resolved_job_dir) == NULL) {
        fprintf(stderr, "h_jail_containment: realpath(%s) failed: %s\n",
                job_dir, strerror(errno));
        return 1;
    }
    if (snprintf(escape_path, sizeof escape_path, "%s/escape",
                 resolved_job_dir) >= (int) sizeof escape_path) {
        fprintf(stderr, "h_jail_containment: escape path too long\n");
        return 1;
    }
    /* The issue #95-shaped attack: a symlink inside the job dir pointing at
     * a host file well outside the jail's allowlist. */
    if (symlink("/etc/shadow", escape_path) != 0) {
        fprintf(stderr, "h_jail_containment: symlink(%s) failed: %s\n",
                escape_path, strerror(errno));
        return 1;
    }

    /* Force fs-jail=required via a throwaway config file, the same key
     * sandbox-config.c parses for src/daemon.c's real startup path. */
    strcpy(conf_path, "/tmp/h_jail_containment_conf.XXXXXX");
    {
        int fd = mkstemp(conf_path);
        if (fd < 0) {
            fprintf(stderr, "h_jail_containment: mkstemp failed: %s\n",
                    strerror(errno));
            return 1;
        }
        close(fd);
    }
    conf = fopen(conf_path, "w");
    if (conf == NULL) {
        fprintf(stderr, "h_jail_containment: fopen(%s) failed: %s\n",
                conf_path, strerror(errno));
        return 1;
    }
    fprintf(conf, "fs-jail = required\n");
    fclose(conf);
    dcc_seccomp_config_load(conf_path);
    unlink(conf_path);

    /* dcc_fs_jail_enter() restores the caller's cwd inside the jail (its final
     * chdir(orig_cwd)), so the cwd at call time must be a path that still
     * exists after pivot_root -- i.e. the job dir itself, which is bind-mounted
     * in. distccd's serve.c chdir's into the job temp_dir before forking; mirror
     * that here, or the restore chdir fails and the jail is (correctly) refused. */
    if (chdir(resolved_job_dir) != 0) {
        fprintf(stderr, "h_jail_containment: chdir(%s) failed: %s\n",
                resolved_job_dir, strerror(errno));
        return 1;
    }

    /* dcc_fs_jail_enter()'s 0/-1 return does not itself distinguish a
     * pre-pivot setup failure from a post-pivot one; the namespace probe
     * above already ruled out "this environment can't do it at all", so any
     * -1 here is treated as a genuine jail defect instead. */
    rc = dcc_fs_jail_enter(resolved_job_dir);
    if (rc != 0) {
        fprintf(stderr, "h_jail_containment: dcc_fs_jail_enter() returned %d "
                "although the earlier namespace probe confirmed this host "
                "can unshare+bind-mount -- treating this as a real jail "
                "setup failure, not an environment limitation\n", rc);
        return 1;
    }

    /* Past this point pivot_root has already happened inside
     * dcc_fs_jail_enter() and this process's own root now IS the jail:
     * plain access() calls below see exactly what the allowlist mounted. */
    assert_present("/usr/lib", "an allowlisted system directory");
    assert_absent("/etc/shadow", "a host secret outside the allowlist");
    assert_absent("/proc", "the deliberately unmounted /proc");
    assert_absent(escape_path, "the issue #95-style escape symlink's target");

    /* Best-effort cleanup: the job dir is bind-mounted at its own real
     * path, so removing it here removes the same underlying host files. */
    if (dcc_fs_jail_root_path(resolved_job_dir, jail_root_path,
                              sizeof jail_root_path) == 0)
        rmdir(jail_root_path);
    unlink(escape_path);
    rmdir(resolved_job_dir);

    if (failures) {
        fprintf(stderr, "h_jail_containment: %d containment case(s) failed\n",
                failures);
        return 1;
    }
    printf("h_jail_containment: all fs-jail containment cases passed\n");
    return 0;
}

#else /* !__linux__ */

/**
 * What: non-Linux skip -- mount namespaces and pivot_root are Linux-only.
 * Why: mirrors fs-jail.c's own non-Linux dcc_fs_jail_enter() no-op; this
 * harness has nothing to exercise on a platform where the jail itself is
 * always disabled (doc/compatibility-policy.md).
 * From: Issue #289.
 */
int main(void)
{
    printf("h_jail_containment: skip (fs-jail is Linux-only)\n");
    return 77;
}

#endif /* __linux__ */
