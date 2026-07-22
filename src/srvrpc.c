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

    if (vers >= __DCC_VER_MAX) {
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

/* Receive NFIL files and/or symlinks sent by the client (protocol tokens
 * NAME, then either LINK+target or FILE+contents, repeated NFIL times) and
 * materialize them under dirname, the server's own per-job temp directory.
 *
 * Each entry's NAME is validated by dcc_name_has_path_traversal() before
 * use (see that function's comment) since it is otherwise fully
 * client-controlled and gets prepended with dirname to form the on-disk
 * path for both the FILE-write and the LINK-create cases.
 *
 * A LINK entry's link_target (the symlink's target, as opposed to its own
 * path/name) is only partly validated, unlike NAME: an absolute-style
 * link_target (starting with '/') is checked the same way NAME is (see
 * dcc_absolute_link_target_has_path_traversal()), since it gets prepended
 * with dirname exactly like NAME does. A relative link_target is NOT
 * validated -- the include-server's own legitimate mirroring symlinks use
 * a leading run of ".." segments to reference real system directories
 * from a mirror tree (see _MakeLinkFromMirrorToRealLocation() in
 * include_server/compiler_defaults.py), and a text-only check can't tell
 * that case apart from an attacker-supplied relative link_target of the
 * same shape (see dcc_absolute_link_target_has_path_traversal()'s own
 * comment in pathsafety.h for why). Closing that residual case is tracked
 * in issue #289 (a real OS-level containment boundary around the job
 * directory), not attempted here.
 */
int dcc_r_many_files(int in_fd,
                     const char *dirname,
                     enum dcc_compress compr)
{
    int ret = 0;
    unsigned int n_files;
    unsigned int i;
    char *name = 0;
    char *link_target = 0;
    char token[5];

    if ((ret = dcc_r_token_int(in_fd, "NFIL", &n_files)))
        return ret;

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

        if ((ret = prepend_dir_to_name(dirname, &name)))
            goto out_cleanup;

        if ((ret = dcc_r_sometoken_int(in_fd, token, &link_or_file_len)))
            goto out_cleanup;

        /* Must prepend the dirname for the file name, a link's target name. */
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
             * legitimate mirroring symlinks from an attacker-supplied one
             * of the same shape (issue #95, tracked residual risk; real
             * fix in issue #289). */
            if ((ret = dcc_mk_tmp_ancestor_dirs(name))) {
                goto out_cleanup;
            }
            if (symlink(link_target, name) != 0) {
                rs_log_error("failed to create path for %s: %s", name,
                             strerror(errno));
                ret = 1;
                goto out_cleanup;
            }
            if ((ret = dcc_add_cleanup(name))) {
                /* bailing out */
                unlink(name);
                goto out_cleanup;
            }
        } else if (strncmp(token, "FILE", 4) == 0) {
            if ((ret = dcc_r_file(in_fd, name, link_or_file_len, 0, compr))) {
                goto out_cleanup;
            }
            if ((ret = dcc_add_cleanup(name))) {
              /* bailing out */
              unlink(name);
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
        free(name);
        name = NULL;
        free(link_target);
        link_target = NULL;
        if (ret)
            break;
    }
    return ret;
}
