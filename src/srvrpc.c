/* -*- c-file-style: "java"; indent-tabs-mode: nil; tab-width: 4; fill-column: 78 -*-
 *
 * distcc -- A simple distributed compiler system
 *
 * Copyright (C) 2002, 2003 by Martin Pool <mbp@samba.org>
 * Copyright 2007 Google Inc.
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
 * Server-specific RPC code.
  **/



#include <config.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>

#include "distcc.h"
#include "trace.h"
#include "util.h"
#include "rpc.h"
#include "exitcode.h"
#include "dopt.h"
#include "hosts.h"
#include "bulk.h"
#include "snprintf.h"
#include "pathsafety.h"

/* Read the client's initial "DIST" version token and validate it against
 * the range of protocol versions this build understands. */
int dcc_r_request_header(int ifd,
                         enum dcc_protover *ver_ret)
{
    unsigned vers;
    int ret;

    if ((ret = dcc_r_token_int(ifd, "DIST", &vers)) != 0) {
        rs_log_error("client did not provide distcc magic fairy dust");
        return ret;
    }

    /* Known protocol versions are not a contiguous range (see #304's
     * numbering policy: the entire 0-3999 range is reserved for whatever
     * upstream distcc/distcc might ever define, and this fork's own
     * extensions start at 4000+/5000+), so "vers >= __DCC_VER_MAX" alone
     * can't reject an unknown value that falls in the reserved-for-
     * upstream range -- dcc_get_features_from_protover() (hosts.c) still
     * rejects it properly one step later, before any ARGV/file data is
     * exchanged, but reject it here too for an accurate error message
     * and to keep this function's own stated contract honest. */
    if (vers != DCC_VER_1 && vers != DCC_VER_2 && vers != DCC_VER_3 &&
        vers != DCC_VER_4000 && vers != DCC_VER_5000) {
        rs_log_error("can't handle requested protocol version is %d", vers);
        return EXIT_PROTOCOL_ERROR;
    }

    *ver_ret = (enum dcc_protover) vers;

    return 0;
}


 /**
  * Receive the working directory from the client
  */
int dcc_r_cwd(int ifd, char **cwd)
{
    return dcc_r_token_string(ifd, "CDIR", cwd);
}

/* @p path must be point to malloc'ed memory
 * Replaces **path with a pointer to a string containing
 * dirname + path.
 * path must be absolute.
 *
 * Callers are responsible for rejecting a *path that could make the
 * concatenated result escape dirname (see dcc_name_has_path_traversal()) --
 * this function itself does no such validation, it only concatenates.
 */
static int prepend_dir_to_name(const char *dirname, char **path)
{
    char *buf;
    checked_asprintf(&buf, "%s%s", dirname, *path);
    if (buf == NULL) {
            return EXIT_OUT_OF_MEMORY;
    }
    free(*path);
    *path = buf;
        return 0;
}

/* Resolve a client-supplied NAME (already checked by
 * dcc_name_has_path_traversal(): rooted at '/', no ".." path component) to
 * the directory that will hold its final component, walking the name one
 * component at a time relative to root_fd -- an fd on the job's own temp
 * directory -- with O_NOFOLLOW on every step.
 *
 * WHY this component-wise openat()/mkdirat() walk instead of building the
 * whole path string and handing it to mkdir()/open() (as the code did
 * before): if an intermediate component of NAME already exists on disk as a
 * *symlink* -- e.g. one created by an earlier LINK entry in the same NFIL
 * batch, whose relative target is deliberately left unvalidated (see
 * dcc_r_many_files()'s comment) -- the kernel would transparently follow it
 * during ordinary path resolution and let the subsequent write land outside
 * the per-job temp directory entirely. Refusing to traverse any symlink
 * component (O_NOFOLLOW turns it into ELOOP) closes that write-escape
 * without the server having to decide whether the symlink is legitimate --
 * the problem #95 found genuinely unsolvable by inspecting the target
 * string alone (issue #292; CWE-59). A missing intermediate directory is
 * created with mkdirat(); an intermediate that turns out to be a symlink or
 * a non-directory is rejected (ELOOP/ENOTDIR) as EXIT_PROTOCOL_ERROR.
 *
 * On success *parent_fd_ret receives a fresh fd on the leaf's parent
 * directory (the caller must close it) and *leaf_ret a malloc'd copy of the
 * final component (the caller must free it). dirname is used only to build
 * the full on-disk path string for cleanup registration of any directory
 * this creates, never for the resolution itself (which is purely fd-
 * relative). A NAME with no final component (empty, "/" only, or a trailing
 * "/") is rejected, as is a "." or ".." component, matching and tightening
 * dcc_name_has_path_traversal()'s intent.
 */
static int dcc_open_parent_beneath(int root_fd, const char *dirname,
                                   const char *name, int *parent_fd_ret,
                                   char **leaf_ret)
{
    int ret = 0;
    int dir_fd = -1;
    char *copy = NULL;
    char *full = NULL;      /* running "dirname/comp0/.../compN" prefix */
    char *p;
    size_t namelen = strlen(name);

    *parent_fd_ret = -1;
    *leaf_ret = NULL;

    /* A trailing '/' (or a name that is only slashes, e.g. "/") means the
     * final component is empty -- there is no file/symlink leaf to create.
     * Reject rather than silently treating the last directory as the leaf. */
    if (namelen == 0 || name[namelen - 1] == '/') {
        rs_log_error("rejected NAME with an empty final component: %s", name);
        return EXIT_PROTOCOL_ERROR;
    }

    /* Start the walk at a dup() of root_fd so the "close the previous dir
     * fd, keep the newly opened one" step below is uniform on every
     * iteration and the zero-intermediate-component case (NAME like
     * "/leaf") cannot accidentally close the caller's root_fd. */
    if ((dir_fd = dup(root_fd)) == -1) {
        rs_log_error("dup of job-directory fd failed: %s", strerror(errno));
        return EXIT_IO_ERROR;
    }

    if ((copy = strdup(name)) == NULL) {
        ret = EXIT_OUT_OF_MEMORY;
        goto fail;
    }
    if ((full = strdup(dirname)) == NULL) {
        ret = EXIT_OUT_OF_MEMORY;
        goto fail;
    }

    p = copy;
    while (*p == '/')           /* skip the leading slash run */
        p++;

    while (*p) {
        char *comp = p;
        int is_last;
        int next_fd;
        int created = 0;
        char *newfull;

        while (*p && *p != '/') /* find end of this component */
            p++;
        if (*p == '/') {
            *p++ = '\0';        /* terminate comp, step past its slash */
            while (*p == '/')   /* collapse any consecutive slashes */
                p++;
        }
        is_last = (*p == '\0'); /* nothing (non-slash) follows -> leaf */

        /* "." and ".." must never appear as a resolved component. ".." is
         * already refused by dcc_name_has_path_traversal(); "." is refused
         * here for defence in depth (it would otherwise be a harmless no-op,
         * but there is no legitimate reason for the client to send it). */
        if (strcmp(comp, ".") == 0 || strcmp(comp, "..") == 0) {
            rs_log_error("rejected NAME with a '%s' component: %s",
                         comp, name);
            ret = EXIT_PROTOCOL_ERROR;
            goto fail;
        }

        if (is_last) {
            /* This is the leaf; its parent is the directory dir_fd now
             * refers to. Hand both back to the caller. */
            if ((*leaf_ret = strdup(comp)) == NULL) {
                ret = EXIT_OUT_OF_MEMORY;
                goto fail;
            }
            *parent_fd_ret = dir_fd;
            dir_fd = -1;        /* ownership transferred to caller */
            free(copy);
            free(full);
            return 0;
        }

        /* Intermediate directory component: descend into it, creating it if
         * absent, but never following a symlink to get there. */
        next_fd = openat(dir_fd, comp,
                         O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next_fd == -1 && errno == ENOENT) {
            if (mkdirat(dir_fd, comp, 0777) == -1 && errno != EEXIST) {
                rs_log_error("failed to create directory component '%s' of "
                             "%s: %s", comp, name, strerror(errno));
                ret = EXIT_IO_ERROR;
                goto fail;
            }
            created = 1;
            /* Re-open the just-created (or raced-in) directory, still with
             * O_NOFOLLOW: if a concurrent actor slipped a symlink in where
             * we expected a directory, this fails ELOOP and we reject. */
            next_fd = openat(dir_fd, comp,
                             O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        }

        if (next_fd == -1) {
            if (errno == ELOOP || errno == ENOTDIR) {
                rs_log_error("rejected NAME '%s': intermediate component "
                             "'%s' is a symlink or not a directory", name,
                             comp);
                ret = EXIT_PROTOCOL_ERROR;
            } else {
                rs_log_error("failed to open directory component '%s' of "
                             "%s: %s", comp, name, strerror(errno));
                ret = EXIT_IO_ERROR;
            }
            goto fail;
        }

        /* Extend the running full-path prefix, then -- only for a directory
         * we actually created this pass -- register it for cleanup so the
         * job's temp tree is torn down leaf-first at the end (matching the
         * old dcc_mk_tmpdir() behaviour). An already-existing directory is
         * not registered: we did not make it, so we must not delete it. */
        checked_asprintf(&newfull, "%s/%s", full, comp);
        if (newfull == NULL) {
            close(next_fd);
            ret = EXIT_OUT_OF_MEMORY;
            goto fail;
        }
        free(full);
        full = newfull;

        if (created && (ret = dcc_add_cleanup(full))) {
            close(next_fd);
            goto fail;
        }

        close(dir_fd);
        dir_fd = next_fd;
    }

    /* Falling out of the loop means no leaf was found (only slashes) --
     * already guarded by the trailing-slash check above, so this is a
     * defensive backstop. */
    rs_log_error("rejected NAME with no usable final component: %s", name);
    ret = EXIT_PROTOCOL_ERROR;

fail:
    if (dir_fd != -1)
        close(dir_fd);
    free(copy);
    free(full);
    free(*leaf_ret);
    *leaf_ret = NULL;
    return ret;
}

/* Receive NFIL files and/or symlinks sent by the client (protocol tokens
 * NAME, then either LINK+target or FILE+contents, repeated NFIL times) and
 * materialize them under dirname, the server's own per-job temp directory.
 *
 * Each entry's NAME is validated by dcc_name_has_path_traversal() before
 * use (see that function's comment) as a first-line string check, then
 * resolved by dcc_open_parent_beneath() one path component at a time
 * relative to root_fd (an fd on dirname) with O_NOFOLLOW throughout. That
 * component-wise resolution -- not the string check -- is what prevents a
 * symlink sitting at an intermediate NAME component from redirecting the
 * FILE-write or LINK-create outside the job directory (issue #292); the
 * string check alone cannot see that a component already exists on disk as
 * a symlink. The leaf itself is created relative to the resolved parent fd
 * (dcc_r_file_beneath() / symlinkat()), again with O_NOFOLLOW, so a leaf
 * that already exists as a symlink is refused rather than followed.
 *
 * A LINK entry's link_target (the symlink's target, as opposed to its own
 * path/name) is only partly validated, unlike NAME: an absolute-style
 * link_target (starting with '/') is checked the same way NAME is (see
 * dcc_absolute_link_target_has_path_traversal()), since it gets prepended
 * with dirname. A relative link_target is NOT validated -- the
 * include-server's own legitimate mirroring symlinks use a leading run of
 * ".." segments to reference real system directories from a mirror tree
 * (see _MakeLinkFromMirrorToRealLocation() in
 * include_server/compiler_defaults.py), and a text-only check can't tell
 * that case apart from an attacker-supplied relative link_target of the
 * same shape (see dcc_absolute_link_target_has_path_traversal()'s own
 * comment in pathsafety.h for why). That residual case does not by itself
 * grant a write-escape any more, precisely because the O_NOFOLLOW
 * resolution above refuses to *traverse* such a symlink when materializing
 * a later entry; a broader OS-level containment boundary around the job
 * directory remains tracked in issue #289.
 */
/* @p file_mode is caller-supplied (rather than read from a global) so this
 * function stays free of distccd-only option state: srvrpc.c is compiled
 * into more than just the distccd binary -- also into the h_srvrpc test
 * harness and, via include_server/setup.py's own separate build, into the
 * include-server's Python C extension -- and none of those link
 * src/dopt.c (server-only option parsing, and pulling it in would also
 * require access.o and popt, see Makefile.in's h_dopt_obj). The only
 * distccd-only caller (src/serve.c) supplies opt_job_file_mode. */
int dcc_r_many_files(int in_fd,
                     const char *dirname,
                     enum dcc_compress compr,
                     mode_t file_mode)
{
    int ret = 0;
    unsigned int n_files;
    unsigned int i;
    char *name = 0;
    char *link_target = 0;
    char *leaf = 0;
    char *full_name = 0;
    int parent_fd = -1;
    int root_fd = -1;
    char token[5];

    if ((ret = dcc_r_token_int(in_fd, "NFIL", &n_files)))
        return ret;

    /* Open the job's own temp directory once and resolve every NAME
     * relative to this fd (see dcc_open_parent_beneath()). O_NOFOLLOW here
     * is defensive -- dirname is the server's freshly-mkdtemp()'d directory,
     * not a symlink -- but costs nothing and keeps the whole resolution
     * chain symlink-free from the very first step. */
    root_fd = open(dirname, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root_fd == -1) {
        rs_log_error("failed to open job directory %s: %s", dirname,
                     strerror(errno));
        return EXIT_IO_ERROR;
    }

    for (i = 0; i < n_files; ++i) {
        /* like dcc_r_argv */
        unsigned int link_or_file_len;

        if ((ret = dcc_r_token_string(in_fd, "NAME", &name)))
            goto out_cleanup;

        if (dcc_name_has_path_traversal(name)) {
            rs_log_error("rejected NAME with a path-traversal sequence "
                         "(must start with '/' and contain no '..'): %s",
                         name);
            ret = EXIT_PROTOCOL_ERROR;
            goto out_cleanup;
        }

        /* Resolve NAME to (parent_fd, leaf) beneath root_fd without ever
         * following a symlink component; this creates any missing ancestor
         * directories and rejects a symlink/non-dir intermediate. */
        if ((ret = dcc_open_parent_beneath(root_fd, dirname, name,
                                           &parent_fd, &leaf)))
            goto out_cleanup;

        /* Full on-disk path of the leaf, used only for cleanup registration
         * and log messages; the actual create is fd-relative (symlinkat /
         * dcc_r_file_beneath), so this string is never resolved as a path
         * for the security-sensitive operation. */
        checked_asprintf(&full_name, "%s%s", dirname, name);
        if (full_name == NULL) {
            ret = EXIT_OUT_OF_MEMORY;
            goto out_cleanup;
        }

        if ((ret = dcc_r_sometoken_int(in_fd, token, &link_or_file_len)))
            goto out_cleanup;

        if (strncmp(token, "LINK", 4) == 0) {

            if ((ret = dcc_r_str_alloc(in_fd, link_or_file_len, &link_target))){
                goto out_cleanup;
            }
            if (link_target[0] == '/') {
                if (dcc_absolute_link_target_has_path_traversal(link_target)) {
                    rs_log_error("rejected absolute LINK target with a "
                                 "path-traversal sequence: %s", link_target);
                    ret = EXIT_PROTOCOL_ERROR;
                    goto out_cleanup;
                }
                if ((ret = prepend_dir_to_name(dirname, &link_target))) {
                    goto out_cleanup;
                }
            }
            /* A relative link_target (not starting with '/') is NOT
             * validated here -- see this function's own comment above for
             * why a text-only check can't distinguish the include-server's
             * legitimate mirroring symlinks from an attacker-supplied one of
             * the same shape (issue #95, tracked residual risk; issue #289
             * for broader containment). symlinkat() stores link_target
             * verbatim; it does not resolve it, and O_NOFOLLOW resolution of
             * any *later* NAME nested under this symlink is what actually
             * refuses the escape. */
            if (symlinkat(link_target, parent_fd, leaf) != 0) {
                rs_log_error("failed to create symlink %s: %s", full_name,
                             strerror(errno));
                ret = EXIT_IO_ERROR;
                goto out_cleanup;
            }
            if ((ret = dcc_add_cleanup(full_name))) {
                /* bailing out */
                unlinkat(parent_fd, leaf, 0);
                goto out_cleanup;
            }
        } else if (strncmp(token, "FILE", 4) == 0) {
            if ((ret = dcc_r_file_beneath(in_fd, parent_fd, leaf,
                                          link_or_file_len, 0, compr,
                                          file_mode))) {
                goto out_cleanup;
            }
            if ((ret = dcc_add_cleanup(full_name))) {
              /* bailing out */
              unlinkat(parent_fd, leaf, 0);
              goto out_cleanup;
            }
        } else {
            char buf[4 + sizeof(link_or_file_len)];
            /* unexpected token */
            rs_log_error("protocol derailment: expected token FILE or LINK");
            /* We should explain what happened here, but we have already read
             * a few more bytes.
             */
            memcpy(buf, token, 4);
            /* TODO(manos): this is probably not kosher */
            memcpy(&buf[4], &link_or_file_len, sizeof(link_or_file_len));
            dcc_explain_mismatch(buf, 12, in_fd);
            ret = EXIT_PROTOCOL_ERROR;
            goto out_cleanup;
        }

out_cleanup:
        if (parent_fd != -1) {
            close(parent_fd);
            parent_fd = -1;
        }
        free(name);
        name = NULL;
        free(link_target);
        link_target = NULL;
        free(leaf);
        leaf = NULL;
        free(full_name);
        full_name = NULL;
        if (ret)
            break;
    }

    if (root_fd != -1)
        close(root_fd);
    return ret;
}
