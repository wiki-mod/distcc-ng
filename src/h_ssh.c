/* -*- c-file-style: "java"; indent-tabs-mode: nil; tab-width: 4; fill-column: 78 -*-
 *
 * distcc -- A simple distributed compiler system
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 */

/**
 * Test harness for ssh.c.
 **/

#include <config.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <sys/wait.h>

#include "distcc.h"
#include "exitcode.h"
#include "trace.h"
#include "util.h"

#define USAGE \
"usage: h_ssh COMMAND\n" \
"where\n" \
"  COMMAND is repeat-env\n"

const char *rs_program_name = "h_ssh";


static int collect_ssh_child(pid_t ssh_pid)
{
    int status;
    pid_t ret;

    do {
        ret = waitpid(ssh_pid, &status, 0);
    } while (ret == -1 && errno == EINTR);

    if (ret == -1) {
        rs_log_error("waitpid failed: %s", strerror(errno));
        return EXIT_IO_ERROR;
    }

    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        rs_log_error("ssh command exited with status %d", status);
        return EXIT_DISTCC_FAILED;
    }

    return 0;
}


static int run_connect_once(void)
{
    char user[] = "builduser";
    char machine[] = "buildhost";
    char path[] = "distccd";
    int f_in = -1;
    int f_out = -1;
    int ret;
    int close_ret = 0;
    pid_t ssh_pid = 0;

    ret = dcc_ssh_connect(NULL, user, machine, path, &f_in, &f_out, &ssh_pid);
    if (ret != 0)
        return ret;

    if (f_out != -1 && dcc_close(f_out))
        close_ret = EXIT_IO_ERROR;

    ret = collect_ssh_child(ssh_pid);

    if (f_in != -1 && dcc_close(f_in))
        close_ret = EXIT_IO_ERROR;

    if (ret != 0)
        return ret;

    return close_ret;
}


int main(int argc, char *argv[])
{
    int ret;

    rs_add_logger(rs_logger_file, RS_LOG_DEBUG, NULL, STDERR_FILENO);

    if (argc != 2) {
        rs_log_error(USAGE);
        return EXIT_BAD_ARGUMENTS;
    }

    if (strcmp(argv[1], "repeat-env") != 0) {
        rs_log_error(USAGE);
        return EXIT_BAD_ARGUMENTS;
    }

    if (!getenv("DISTCC_SSH")) {
        rs_log_error("DISTCC_SSH must be set");
        return EXIT_BAD_ARGUMENTS;
    }

    ret = run_connect_once();
    if (ret != 0)
        return ret;

    return run_connect_once();
}
