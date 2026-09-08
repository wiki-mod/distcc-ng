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
 * What: unit test for dcc_fs_jail_path_within_root(), the filesystem jail's
 * component-boundary containment primitive (issue #289 plan sections 5.4/98).
 * Why: this primitive is the trust decision the whole jail rests on, and it
 * is pure string logic testable without kernel namespaces -- so it gets a
 * real, adversarial test (prefix tricks, component boundaries, the root
 * case) rather than only being exercised implicitly by a live compile.
 * From: Issue #289.
 */

#include <config.h>

#include <stdio.h>
#include <stdlib.h>

#include "fs-jail.h"

const char *rs_program_name = __FILE__;

static int failures;

/**
 * What: assert dcc_fs_jail_path_within_root(@p path, @p root) equals
 * @p want, printing and counting a failure otherwise.
 * Why: keeps each case a single readable line while still reporting exactly
 * which input disagreed, so a regression names the offending pair.
 * From: Issue #289.
 */
static void check(const char *path, const char *root, int want)
{
    int got = dcc_fs_jail_path_within_root(path, root);
    if (got != want) {
        fprintf(stderr, "FAIL: within_root(\"%s\", \"%s\") = %d, want %d\n",
                path ? path : "(null)", root ? root : "(null)", got, want);
        failures++;
    }
}

int main(void)
{
    /* Exact match and genuine descendants are contained. */
    check("/usr", "/usr", 1);
    check("/usr/include", "/usr", 1);
    check("/usr/lib/gcc/x86_64-linux-gnu/14/include", "/usr", 1);
    check("/lib/x", "/lib", 1);

    /* Prefix tricks must NOT be treated as contained (the reason a plain
     * strncmp would be wrong -- plan section 5.4). */
    check("/usr-evil", "/usr", 0);
    check("/usrlocal", "/usr", 0);
    check("/lib64", "/lib", 0);
    check("/us", "/usr", 0);

    /* Sibling and unrelated paths are not contained. */
    check("/etc/shadow", "/usr", 0);
    check("/", "/usr", 0);
    check("/bin", "/usr", 0);

    /* Root "/" contains every absolute path, including itself. */
    check("/", "/", 1);
    check("/usr", "/", 1);
    check("/anything/deep/here", "/", 1);

    /* Non-absolute inputs and NULLs are never contained (defensive). */
    check("relative/path", "/usr", 0);
    check("/usr", "relative", 0);
    check(NULL, "/usr", 0);
    check("/usr", NULL, 0);

    if (failures) {
        fprintf(stderr, "h_fs_jail: %d case(s) failed\n", failures);
        return 1;
    }
    printf("h_fs_jail: all containment cases passed\n");
    return 0;
}
