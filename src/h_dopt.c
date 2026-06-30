/* -*- c-file-style: "java"; indent-tabs-mode: nil; tab-width: 4; fill-column: 78 -*-
 *
 * distcc -- A simple distributed compiler system
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 */

#include <config.h>

#include <stdio.h>
#include <string.h>

#include "distcc.h"
#include "dopt.h"

const char *rs_program_name = __FILE__;
const char *opt_user = "distcc";

extern int opt_allow_private;

int dcc_should_be_inetd(void);

static void reset_options(void) {
    opt_enable_tcp_insecure = 0;
    opt_inetd_mode = 0;
    opt_daemon_mode = 0;
    opt_allow_private = 0;
    opt_allowed = NULL;
}

int dcc_should_be_inetd(void) {
    return opt_inetd_mode;
}

static int check_tcp_insecure_order(const char *label,
                                    const char **argv,
                                    int argc) {
    reset_options();

    if (distccd_parse_options(argc, argv) != 0) {
        fprintf(stderr, "%s: parser returned failure\n", label);
        return 1;
    }

    if (!opt_enable_tcp_insecure) {
        fprintf(stderr, "%s: --enable-tcp-insecure was not honored\n", label);
        return 1;
    }

    if (!opt_inetd_mode) {
        fprintf(stderr, "%s: --inetd was not honored\n", label);
        return 1;
    }

    return 0;
}

int main(int argc, char **argv) {
    const char *first_args[] = {
        "distccd",
        "--enable-tcp-insecure",
        "--inetd",
        NULL
    };
    const char *last_args[] = {
        "distccd",
        "--inetd",
        "--enable-tcp-insecure",
        NULL
    };

    if (argc != 2 || strcmp(argv[1], "tcp-insecure-order") != 0) {
        fprintf(stderr, "usage: %s tcp-insecure-order\n", argv[0]);
        return 1;
    }

    if (check_tcp_insecure_order("first", first_args, 3) != 0) {
        return 1;
    }
    if (check_tcp_insecure_order("last", last_args, 3) != 0) {
        return 1;
    }

    puts("ok");
    return 0;
}
