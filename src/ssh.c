/* -*- c-file-style: "java"; indent-tabs-mode: nil; tab-width: 4; fill-column: 78 -*-
 *
 * distcc -- A simple distributed compiler system
 *
 * Copyright (C) 2001-2004 by Martin Pool
 * Copyright (C) 1996-2001 by Andrew Tridgell
 * Copyright (C) 1996 by Paul Mackerras
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


/*
 * ssh.c -- Open a connection a server over ssh or something similar.
 *
 * The ssh connection always opens immediately from distcc's point of view,
 * because the local socket/pipe to the child is ready.  If the remote
 * connection failed or is slow, distcc will only know when it tries to read
 * or write.  (And in fact the first page or more written will go out
 * immediately too...)
 *
 * This file always uses nonblocking ssh, which has proven in rsync to be the
 * better solution for ssh.  It may cause trouble with ancient proprietary rsh
 * implementations which can't handle their input being in nonblocking mode.
 * rsync has a configuration option for that, but I don't support it here,
 * because there's no point using rsh, you might as well use the native
 * protocol.
 */


#include <config.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>

#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/socket.h>

#include "distcc.h"
#include "trace.h"
#include "exitcode.h"
#include "util.h"
#include "exec.h"
#include "snprintf.h"
#include "netutil.h"

const char *dcc_default_ssh = "ssh";




/**
 * Create a file descriptor pair - like pipe() but use socketpair if
 * possible (because of blocking issues on pipes).
 *
 * Always set non-blocking.
 */
static int fd_pair(int fd[2])
{
    int ret;

#if HAVE_SOCKETPAIR
    ret = socketpair(AF_UNIX, SOCK_STREAM, 0, fd);
#else
    ret = pipe(fd);
#endif

    if (ret == 0) {
        dcc_set_nonblocking(fd[0]);
        dcc_set_nonblocking(fd[1]);
    }

    return ret;
}


/**
 * Create a child connected to use on stdin/stdout.
 *
 * This is derived from CVS code
 *
 * Note that in the child STDIN is set to blocking and STDOUT is set to
 * non-blocking. This is necessary as rsh relies on stdin being blocking and
 * ssh relies on stdout being non-blocking
 **/
static int dcc_run_piped_cmd(char **argv,
                             int *f_in,
                             int *f_out,
                             pid_t * child_pid)
{
    pid_t pid;
    int to_child_pipe[2];
    int from_child_pipe[2];

    dcc_trace_argv("execute", argv);

    if (fd_pair(to_child_pipe) < 0) {
        rs_log_error("fd_pair: %s", strerror(errno));
        return EXIT_IO_ERROR;
    }

    if (fd_pair(from_child_pipe) < 0) {
        dcc_close(to_child_pipe[0]);
        dcc_close(to_child_pipe[1]);
        rs_log_error("fd_pair: %s", strerror(errno));
        return EXIT_IO_ERROR;
    }

    *child_pid = pid = fork();
    if (pid == -1) {
        rs_log_error("fork failed: %s", strerror(errno));
        dcc_close(to_child_pipe[0]);
        dcc_close(to_child_pipe[1]);
        dcc_close(from_child_pipe[0]);
        dcc_close(from_child_pipe[1]);
        return EXIT_IO_ERROR;
    }

    if (pid == 0) {
        if (dup2(to_child_pipe[0], STDIN_FILENO) < 0 ||
            close(to_child_pipe[1]) < 0 ||
            close(from_child_pipe[0]) < 0 ||
            dup2(from_child_pipe[1], STDOUT_FILENO) < 0) {
            rs_log_error("dup/close: %s", strerror(errno));
            return EXIT_IO_ERROR;
        }
        if (to_child_pipe[0] != STDIN_FILENO)
            close(to_child_pipe[0]);
        if (from_child_pipe[1] != STDOUT_FILENO)
            close(from_child_pipe[1]);
        dcc_set_blocking(STDIN_FILENO);

        execvp(argv[0], (char **) argv);
        rs_log_error("failed to exec %s: %s", argv[0], strerror(errno));
        return EXIT_IO_ERROR;
    }

    if (dcc_close(from_child_pipe[1]) || dcc_close(to_child_pipe[0])) {
        rs_log_error("failed to close pipes");
        return EXIT_IO_ERROR;
    }

    *f_in = from_child_pipe[0];
    *f_out = to_child_pipe[1];

    return 0;
}



/**
 * Sanity-check the resolved SSH transport command before it is handed to
 * execvp() as argv[0].
 *
 * This is deliberately NOT an absolute-path or PATH-resolution check.  The
 * transport command legitimately comes from the invoking user's own
 * environment ($DISTCC_SSH) or host spec and is very often a bare command
 * name such as "ssh" that relies on execvp()'s own $PATH search -- forcing an
 * absolute path here (as the compile.c clang-probe path must, because it
 * pre-resolves and execs later) would break normal, intended usage.  execvp()
 * performs its lookup atomically at exec time, so unlike that pre-resolve
 * path there is no check-then-use (TOCTOU) window to close either.
 *
 * What is worth rejecting is a value that is not a plausible command at all:
 * an empty token (can arise from a host-spec-supplied command; the $DISTCC_SSH
 * path already can't produce one, since strtok() skips leading spaces and
 * returns NULL, which falls back to the default), or a token beginning with
 * '-' that execvp() or the spawned program would misread as an option.  This
 * is robustness/error-clarity hardening of a client-side, user-supplied
 * value, not a privilege boundary -- ssh.o is client-only and runs as the
 * invoking user.
 */
static int dcc_ssh_cmd_is_sane(const char *ssh_cmd)
{
    if (!ssh_cmd || ssh_cmd[0] == '\0') {
        rs_log_error("SSH transport command is empty");
        return 0;
    }
    if (ssh_cmd[0] == '-') {
        rs_log_error("SSH transport command \"%s\" looks like an option, "
                     "not a command", ssh_cmd);
        return 0;
    }
    return 1;
}


/**
 * Open a connection to a remote machine over ssh.
 *
 * Based on code in rsync, but rewritten.
 *
 * @note The tunnel command is always opened directly using execvp(), not
 * through a shell.  So you cannot pass shell operators like redirections, and
 * at the moment you cannot specify additional options.  Perhaps it would be
 * nice for us to parse it into an argv[] string by splitting on
 * wildcards/quotes, but at the moment this seems redundant.  It can be done
 * adequately using .ssh/config I think.
 *
 * @note the ssh command does need to be tokenized as we have hundreds of
 * users and a corporate requirement that keeps us from modifying the
 * system ssh config files. We can at the same time set command-line options
 * through the tool in use one level above this. - prw 08/09/2016
 *
 **/
int dcc_ssh_connect(char *ssh_cmd,
                    char *user,
                    char *machine,
                    char *path,
                    int *f_in, int *f_out,
                    pid_t *ssh_pid)
{
    pid_t ret;
    enum { MAX_SSH_ARGS = 12 };
    char *ssh_args[MAX_SSH_ARGS];
    char *child_argv[11+MAX_SSH_ARGS];
    int i,j;
    int num_ssh_args = 0;
    char *ssh_cmd_buf = NULL;
    char *ssh_cmd_in;

    /* We need to cast away constness.  I promise the strings in the argv[]
     * will not be modified. */

    if (!ssh_cmd && (ssh_cmd_in = getenv("DISTCC_SSH"))) {
        ssh_cmd_buf = strdup(ssh_cmd_in);
        if (!ssh_cmd_buf) {
            rs_log_crit("failed to duplicate DISTCC_SSH");
            return EXIT_OUT_OF_MEMORY;
        }
        ssh_cmd_in = ssh_cmd_buf;
        ssh_cmd = strtok(ssh_cmd_in, " ");
        char *token = strtok(NULL, " ");
        while (token != NULL) {
            ssh_args[num_ssh_args++] = token;
            token = strtok(NULL, " ");
            if (num_ssh_args == MAX_SSH_ARGS)
                break;
        }
    }
    if (!ssh_cmd)
        ssh_cmd = (char *) dcc_default_ssh;

    /* Validate the resolved command (argv[0] to come) before we build the
     * child argv and fork -- rejecting here returns a clean error instead of
     * failing deep inside the forked child after execvp(). */
    if (!dcc_ssh_cmd_is_sane(ssh_cmd)) {
        free(ssh_cmd_buf);
        return EXIT_DISTCC_FAILED;
    }

    if (!machine) {
        rs_log_crit("no machine defined!");
        return EXIT_DISTCC_FAILED;
    }
    if (!path)
        path = (char *) "distccd";

    i = 0;
    child_argv[i++] = ssh_cmd;
    for (j=0; j<num_ssh_args; ) {
        child_argv[i++] = ssh_args[j++];
    }

    if (user) {
        child_argv[i++] = (char *) "-l";
        child_argv[i++] = user;
    }
    child_argv[i++] = machine;
    child_argv[i++] = path;
    child_argv[i++] = (char *) "--inetd";
    child_argv[i++] = (char *) "--enable-tcp-insecure";
    child_argv[i++] = NULL;

    rs_trace("connecting to %s using %s", machine, ssh_cmd);

    /* TODO: If we're verbose, perhaps make the server verbose too, and send
     * its log to our stderr? */
    /*     child_argv[i++] = (char *) "--log-stderr"; */

    ret = dcc_run_piped_cmd(child_argv, f_in, f_out, ssh_pid);
    free(ssh_cmd_buf);

    return ret;
}
