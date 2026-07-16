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

#endif /* _DISTCC_PATHSAFETY_H */
