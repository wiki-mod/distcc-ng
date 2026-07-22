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
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "distcc.h"
#include "rpc.h"
#include "bulk.h"
#include "exitcode.h"
#include "trace.h"

/* trace.c references this symbol; every distcc executable (and every test
 * harness) must define it. Matches the other h_*.c harnesses. */
const char *rs_program_name = "h_srvrpc";

/**
 * Test harness: drive the *real* server-side dcc_r_many_files() (src/srvrpc.c)
 * with a fully client-controlled NFIL token stream, so the actual
 * materialization code path -- the symlink-safe component-wise NAME
 * resolution added for issue #292 -- can be exercised end-to-end from
 * test/testdistcc.py without standing up a real TCP daemon and a cooperating
 * malicious client (no such client exists; a benign distcc client would
 * never emit the malicious sequence this test needs).
 *
 * The crafted request is written into one end of a pipe using the same
 * dcc_x_token_*()/dcc_writex() wire encoders a real client uses, then
 * dcc_r_many_files() consumes it from the other end against the given job
 * directory. The whole request is tiny (well under a pipe buffer), so
 * writing it all before reading cannot deadlock.
 *
 * Usage:
 *   h_srvrpc attack <jobdir> <relative-link-target>
 *   h_srvrpc legit  <jobdir>
 *
 * "attack" reproduces issue #292's exact escape sequence: entry 1 creates a
 * symlink NAME "/safe" whose (relative, deliberately-unvalidated) target is
 * <relative-link-target>; entry 2 sends a FILE whose NAME "/safe/pwned" is
 * nested *underneath* that symlink. A vulnerable server follows the symlink
 * and writes outside the job dir; the fixed server rejects entry 2.
 *
 * "legit" sends a benign nested sequence (real directories, plus one leaf
 * mirror-style symlink that nothing is nested under) that must still work.
 *
 * Prints "ret=<n>" (the dcc_r_many_files() return code) to stdout so the
 * Python harness can assert on it; created files are left in place (no
 * cleanup) for the harness to inspect.
 **/

/* Emit a NAME token (4-char tag + hex length + raw bytes), exactly as a
 * real client's dcc_x_token_string() would. */
static void emit_name(int fd, const char *name)
{
    dcc_x_token_string(fd, "NAME", name);
}

/* Emit a FILE token followed by its raw body bytes. */
static void emit_file(int fd, const char *body)
{
    size_t len = strlen(body);
    dcc_x_token_int(fd, "FILE", (unsigned) len);
    dcc_writex(fd, body, len);
}

/* Emit a LINK token followed by its raw target bytes. */
static void emit_link(int fd, const char *target)
{
    size_t len = strlen(target);
    dcc_x_token_int(fd, "LINK", (unsigned) len);
    dcc_writex(fd, target, len);
}

int main(int argc, char *argv[])
{
    int pipefd[2];
    int ret;
    const char *scenario;
    const char *jobdir;

    if (argc < 3) {
        fprintf(stderr, "usage: h_srvrpc attack <jobdir> <link-target>\n"
                        "       h_srvrpc legit  <jobdir>\n");
        return 2;
    }
    scenario = argv[1];
    jobdir = argv[2];

    if (pipe(pipefd) == -1) {
        perror("pipe");
        return 2;
    }

    if (strcmp(scenario, "attack") == 0) {
        if (argc < 4) {
            fprintf(stderr, "attack scenario needs a link-target argument\n");
            return 2;
        }
        /* Two entries in one batch: a symlink leaf, then a FILE nested
         * under it. See this file's header comment for the threat model. */
        dcc_x_token_int(pipefd[1], "NFIL", 2);
        emit_name(pipefd[1], "/safe");
        emit_link(pipefd[1], argv[3]);        /* relative, unvalidated */
        emit_name(pipefd[1], "/safe/pwned");
        emit_file(pipefd[1], "PWNED");
    } else if (strcmp(scenario, "legit") == 0) {
        /* Benign nested traffic: real directories created on demand, plus a
         * leaf mirror-style relative symlink that nothing is nested under. */
        dcc_x_token_int(pipefd[1], "NFIL", 3);
        emit_name(pipefd[1], "/a/b/c/first.h");
        emit_file(pipefd[1], "one");
        emit_name(pipefd[1], "/a/b/c/d/second.h");
        emit_file(pipefd[1], "two");
        emit_name(pipefd[1], "/a/mirror.h");
        emit_link(pipefd[1], "../elsewhere/real.h");
    } else {
        fprintf(stderr, "unknown scenario '%s'\n", scenario);
        return 2;
    }

    /* Close the write end so dcc_r_many_files() sees EOF after the last
     * token rather than blocking for more. */
    close(pipefd[1]);

    ret = dcc_r_many_files(pipefd[0], jobdir, DCC_COMPRESS_NONE);
    close(pipefd[0]);

    printf("ret=%d\n", ret);
    return 0;
}
