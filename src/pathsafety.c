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

/**
 * @file
 *
 * Path-safety validation for client-supplied file paths received over the
 * wire protocol (see src/srvrpc.c's dcc_r_many_files()). Deliberately kept
 * free of any other distcc-internal dependency so it can be linked into
 * the small h_pathsafety.c test harness without pulling in the rest of
 * distccd (see Makefile.in's h_pathsafety_obj).
 **/

#include <config.h>

#include <string.h>

#include "pathsafety.h"

/* Reject a client-supplied absolute-style path (as received in a NAME
 * token, before it is prepended with the server's own temp dirname) that
 * could escape the intended directory tree.
 *
 * "escape" means: not rooted at '/', or containing a ".." path component
 * (leading "/../", embedded "/../", or trailing "/.."). Any of those,
 * concatenated onto a dirname, can walk the resulting path outside dirname
 * entirely -- e.g. dirname "/var/tmp/distccd-XXXXXX" + name
 * "/../../../etc/cron.d/evil" resolves outside the server's temp dir.
 *
 * Returns 1 (unsafe, reject) or 0 (safe to use).
 */
int dcc_name_has_path_traversal(const char *name)
{
    size_t len = strlen(name);

    if (name[0] != '/')
        return 1;

    if (strstr(name, "/../") != NULL)
        return 1;

    if (len >= 3 && strcmp(name + len - 3, "/..") == 0)
        return 1;

    return 0;
}

/* Reject a client-supplied CDIR (current working directory) token that
 * contains ".." path components which could escape the intended directory
 * tree when concatenated with the server's temp directory.
 *
 * Unlike NAME tokens which must be absolute paths starting with '/', CDIR
 * can be any path (absolute or relative) representing the client's current
 * working directory at the time of the request. However, ".." components
 * can cause directory traversal: concatenating temp_dir "/tmp/distccd-XXXXXX"
 * with cdir "../../etc" would result in a path that resolves to /etc instead
 * of a subdirectory of the temp directory.
 *
 * This function checks for ".." as:
 *  - The entire CDIR string (e.g., ".."),
 *  - A leading component (e.g., "../foo"),
 *  - An embedded component (e.g., "a/../b", "a/../../c", "/a/../b"),
 *  - A trailing component (e.g., "a/..", "a/b/..", "/a/..").
 *
 * Returns 1 (unsafe, reject) or 0 (safe to use).
 */
int dcc_cdir_has_path_traversal(const char *cdir)
{
    size_t len = strlen(cdir);

    /* Reject ".." as the entire path */
    if (strcmp(cdir, "..") == 0)
        return 1;

    /* Reject ".." as a leading path component in relative paths (e.g., "../foo") */
    if (len >= 3 && strncmp(cdir, "../", 3) == 0)
        return 1;

    /* Reject ".." as an embedded path component (e.g., "a/../b" or "a/../../c") */
    if (strstr(cdir, "/../") != NULL)
        return 1;

    /* Reject ".." as a trailing path component (e.g., "a/.." or "/a/..") */
    if (len >= 3 && strcmp(cdir + len - 3, "/..") == 0)
        return 1;

    return 0;
}
