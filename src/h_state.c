/* -*- c-file-style: "java"; indent-tabs-mode: nil -*-
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

#include <stdio.h>
#include <string.h>

#include "distcc.h"
#include "exitcode.h"
#include "mon.h"
#include "state.h"
#include "trace.h"

const char *rs_program_name = __FILE__;


static int dcc_state_atomic_write_check(void)
{
    struct dcc_task_state *list = NULL;
    struct dcc_task_state *item;
    int found = 0;
    int ret;

    ret = dcc_note_state(DCC_PHASE_CPP, "state-input.c", "localhost",
                         DCC_LOCAL);
    if (ret)
        return ret;

    ret = dcc_mon_poll(&list);
    if (ret) {
        dcc_remove_state_file();
        return ret;
    }

    for (item = list; item; item = item->next) {
        if (item->curr_phase == DCC_PHASE_CPP &&
            strcmp(item->file, "state-input.c") == 0 &&
            strcmp(item->host, "localhost") == 0) {
            found = 1;
            break;
        }
    }

    dcc_task_state_free(list);
    dcc_remove_state_file();

    return found ? 0 : EXIT_DISTCC_FAILED;
}


int main(int argc, char **argv)
{
    if (argc != 2 || strcmp(argv[1], "atomic-write") != 0) {
        rs_log_error("usage: %s atomic-write", argv[0]);
        return 1;
    }

    return dcc_state_atomic_write_check();
}
