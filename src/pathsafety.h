/* -*- c-file-style: "java"; indent-tabs-mode: nil; tab-width: 4; fill-column: 78 -*-
 *
 * distcc -- A simple distributed compiler system
 *
 * Copyright 2026 wiki-mod/distcc-ng contributors
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

#ifndef _DISTCC_PATHSAFETY_H
#define _DISTCC_PATHSAFETY_H

/* Returns 1 if a client-supplied NAME token could escape the server's temp
 * directory when concatenated onto it (not rooted at '/', or containing a
 * ".." path component -- leading, embedded, or trailing), 0 if it is safe
 * to use as-is. See the function definition in pathsafety.c for the full
 * rationale; used by srvrpc.c's dcc_r_many_files() and unit-tested
 * directly by h_pathsafety.c. */
int dcc_name_has_path_traversal(const char *name);

/* Returns 1 if a client-supplied CDIR (current working directory) token
 * contains ".." path components that could allow directory traversal when
 * the path is concatenated with the server's temp directory, 0 if safe.
 * Used by serve.c's make_temp_dir_and_chdir_for_cpp() to validate paths
 * before mkdir/chdir operations. */
int dcc_cdir_has_path_traversal(const char *cdir);

/* Returns 1 if a filename taken from an environment variable (or derived
 * from one) is sane enough to hand to open()/fopen() -- non-empty, within
 * PATH_MAX, and free of control characters -- 0 otherwise. Unlike
 * dcc_name_has_path_traversal(), this is not a directory-escape check: these
 * paths are used as-is, not concatenated onto a fixed base directory, so a
 * ".." component is not inherently unsafe here. It exists to reject
 * pathological values (truncated/binary-garbage environment, empty string)
 * before they reach a file-access function. See callers in compile.c,
 * serve.c, and traceenv.c. */
int dcc_sane_env_path(const char *path);

#endif /* _DISTCC_PATHSAFETY_H */
