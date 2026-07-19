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

#include "dopt.h"
#include "distcc.h"

const char *rs_program_name = __FILE__;

int arg_stats;
int arg_stats_port;
char *opt_listen_addr;
struct dcc_allow_list *opt_allowed;
int dcc_max_kids;

void dcc_manage_kids(int listen_fd);
int dcc_stats_test_prune_old_head(void);

void dcc_manage_kids(int listen_fd) {
    (void) listen_fd;
}

int main(int argc, char **argv) {
    int ret;

    if (argc != 2 || strcmp(argv[1], "prune-old-head") != 0) {
        fprintf(stderr, "usage: %s prune-old-head\n", argv[0]);
        return 1;
    }

    ret = dcc_stats_test_prune_old_head();
    if (ret != 0) {
        fprintf(stderr, "h_stats prune-old-head failed: %d\n", ret);
        return ret;
    }

    puts("ok");
    return 0;
}
