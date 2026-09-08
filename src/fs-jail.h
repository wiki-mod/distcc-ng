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
 * What: Linux mount-namespace filesystem jail for a server-side (pump-mode)
 * compile job -- a kernel-enforced containment boundary around the job's
 * directory tree, on top of the include-server's symlink mirroring and the
 * seccomp sandbox.
 * Why: even a successful symlink escape (issue #95's shape or one not yet
 * found) cannot reach anything the server did not explicitly allow, because
 * the jail's mount set is a server-controlled allowlist, never derived from
 * client-supplied symlinks (issue #289 plan section 5).
 * From: Issue #289.
 *
 * This header deliberately does not #include "distcc.h": that file has no
 * include guard, so pulling it in here and again from the .c would redefine
 * every enum in it under this fork's -Werror build (the exact build error
 * hit while prototyping). The .c includes "distcc.h" itself, first.
 */

#ifndef _DISTCC_FS_JAIL_H
#define _DISTCC_FS_JAIL_H

/**
 * What: the three operating modes for the filesystem jail, read once from
 * distccd.conf's `fs-jail` key.
 * Why: an admin needs to express "don't jail at all" (the default, so no
 * existing deployment changes behavior), "jail but tolerate a setup failure"
 * (optional), and "jail or refuse the compile outright" (required) as three
 * distinct choices -- the same fail-open/fail-closed distinction the seccomp
 * sandbox already draws, plus an explicit off (issue #289 plan section 53).
 * From: Issue #289.
 */
enum dcc_fs_jail_mode {
    DCC_FS_JAIL_OFF = 0,    /* default: no jail, behaviour unchanged */
    DCC_FS_JAIL_OPTIONAL,   /* jail; on setup failure log and proceed unjailed */
    DCC_FS_JAIL_REQUIRED    /* jail; on setup failure refuse the compile */
};

/**
 * What: enter a filesystem jail for @p job_dir (the per-job server temp
 * directory, `temp_dir` in src/serve.c; NULL for a plain-mode job with no
 * directory tree to jail) just before the compiler is exec'd.
 * Why: the caller (src/exec.c's dcc_inside_child) must be able to treat a
 * hard failure as an ordinary compile failure, so the return contract
 * mirrors dcc_seccomp_sandbox_child()'s exactly -- see the return doc below.
 * From: Issue #289.
 *
 * Precondition: the current working directory must be a path that still
 * exists inside the jail (in practice @p job_dir itself, which is bind-mounted
 * in), because on success the jail restores the caller's cwd after pivot_root.
 * src/serve.c chdir's into the job temp_dir before forking, so this holds for
 * the real caller; a standalone caller must chdir into @p job_dir first, or
 * the post-pivot cwd restore fails and (in mode required) the compile is
 * refused.
 *
 * Returns 0 when the jail was entered, or when not entering one is the
 * correct outcome (mode off, non-Linux build, @p job_dir NULL, or mode
 * optional and setup failed -- the last logs a warning and proceeds
 * unjailed). Returns -1 only when mode required and the jail genuinely could
 * not be established: the caller must then refuse the compile, never exec the
 * untrusted compiler unconfined after the admin demanded containment.
 */
int dcc_fs_jail_enter(const char *job_dir);

/**
 * What: return non-zero if canonical absolute path @p path is @p root itself
 * or a descendant of it, comparing at a path-component boundary.
 * Why: a plain strncmp() prefix test would accept "/usr-evil" as inside
 * "/usr"; the mount trust model depends on this being a real component
 * boundary, so it is a separate, unit-testable primitive (issue #289 plan
 * sections 5.4/98). Both arguments must already be absolute and canonical
 * (no "." / ".." / trailing slash except root "/").
 * From: Issue #289.
 */
int dcc_fs_jail_path_within_root(const char *path, const char *root);

/**
 * What: write the jail-root directory path for job directory @p job_dir into
 * @p buf (a subdirectory inside @p job_dir); return 0, or -1 if it would not
 * fit.
 * Why: the jail root must live inside the per-job temp_dir so the parent
 * distccd's existing cleanup removes it -- a global mkdtemp would leak one
 * empty dir per job (after pivot_root the jail root is "/" and cannot self-
 * remove). Both the jail (src/fs-jail.c) and the cleanup registration
 * (src/serve.c) derive the path here, so the two never drift.
 * From: Issue #289.
 */
int dcc_fs_jail_root_path(const char *job_dir, char *buf, size_t buflen);

#endif /* _DISTCC_FS_JAIL_H */
