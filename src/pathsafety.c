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
