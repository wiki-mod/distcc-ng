/* -*- c-file-style: "java"; indent-tabs-mode: nil; tab-width: 4; fill-column: 78 -*-
 *
 * distcc -- A simple distributed compiler system
 *
 * Copyright (C) 2026 distcc contributors
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

#include <config.h>

#include <stdlib.h>
#include <string.h>

#include "distcc.h"
#include "include_server_if.h"


static int dcc_compare_include_server_files(const void *left,
                                            const void *right)
{
    const char * const *left_file = left;
    const char * const *right_file = right;

    return strcmp(*left_file, *right_file);
}


void dcc_sort_include_server_files(char **files)
{
    qsort(files, dcc_argv_len(files), sizeof files[0],
          dcc_compare_include_server_files);
}
