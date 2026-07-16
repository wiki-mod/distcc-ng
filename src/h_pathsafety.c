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

#include <config.h>

#include <stdio.h>

#include "pathsafety.h"

/**
 * Test harness: make dcc_name_has_path_traversal() accessible from the
 * command line so it can be exercised by test/testdistcc.py without a full
 * client/server round trip (see src/srvrpc.c's dcc_r_many_files() for the
 * real caller and its rationale).
 *
 * Prints "safe" or "unsafe" for each NAME argument given.
 **/
int main(int argc, char *argv[])
{
    int i;

    if (argc < 2) {
        fprintf(stderr, "usage: h_pathsafety NAME...\n");
        return 1;
    }

    for (i = 1; i < argc; i++) {
        printf("%s %s\n",
               dcc_name_has_path_traversal(argv[i]) ? "unsafe" : "safe",
               argv[i]);
    }

    return 0;
}
