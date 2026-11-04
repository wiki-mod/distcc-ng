/* -*- c-file-style: "java"; indent-tabs-mode: nil; tab-width: 4; fill-column: 78 -*-
 *
 * distcc -- A simple distributed compiler system
 *
 * Copyright (C) 2002, 2003, 2004 by Martin Pool
 * Copyright 2007 Google Inc.
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
 * What: Low-level descriptor I/O and job transport binding.
 * Why: Keeps the RPC code independent of the byte transport.
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
#include <sys/socket.h>
#ifdef HAVE_SYS_SELECT_H
#  include <sys/select.h>
#endif
#include <sys/time.h>

#include <netinet/in.h>
#include <netinet/tcp.h>

#include "distcc.h"
#include "trace.h"
#include "util.h"
#include "exitcode.h"


/*
 * What: Descriptors of the job connection and its transport.
 * Why: inetd mode carries one connection on fd 0 and fd 1.
 * From: Issue #248
 */
static struct {
    int in_fd;
    int out_fd;
    const struct dcc_transport *ops;
    void *ctx;
} dcc_conn = { -1, -1, NULL, NULL };


/*
 * What: Reads once from fd through read(2).
 * Why: Plain TCP uses the same dispatch path as TLS.
 * From: Issue #248
 */
static ssize_t dcc_plain_read(void *UNUSED(ctx), int fd, void *buf,
                              size_t len)
{
    return read(fd, buf, len);
}


/*
 * What: Writes once to fd through write(2).
 * Why: Plain TCP uses the same dispatch path as TLS.
 * From: Issue #248
 */
static ssize_t dcc_plain_write(void *UNUSED(ctx), int fd, const void *buf,
                               size_t len)
{
    return write(fd, buf, len);
}


/*
 * What: Transport for plain TCP and pipe connections.
 * Why: Makes plain connections use the bound dispatch path.
 * From: Issue #248
 */
const struct dcc_transport dcc_transport_plain = {
    dcc_plain_read,
    dcc_plain_write,
    NULL,
    1
};


/*
 * What: Binds the job connection descriptors to a transport.
 * Why: Network I/O on them must pass through ops.
 * From: Issue #248
 */
void dcc_transport_bind(int in_fd, int out_fd,
                        const struct dcc_transport *ops, void *ctx)
{
    dcc_conn.in_fd = in_fd;
    dcc_conn.out_fd = out_fd;
    dcc_conn.ops = ops;
    dcc_conn.ctx = ctx;
}


/*
 * What: Returns the transport bound to fd, or NULL.
 * Why: Unbound descriptors are local files and pipes.
 * From: Issue #248
 */
static const struct dcc_transport *dcc_transport_of(int fd)
{
    if (dcc_conn.ops && (fd == dcc_conn.in_fd || fd == dcc_conn.out_fd))
        return dcc_conn.ops;
    return NULL;
}


/*
 * What: Reads once from fd with read(2) result semantics.
 * Why: Single entry point for every network read.
 * From: Issue #248
 */
ssize_t dcc_transport_read(int fd, void *buf, size_t len)
{
    const struct dcc_transport *ops = dcc_transport_of(fd);

    if (ops)
        return ops->read(dcc_conn.ctx, fd, buf, len);
    return read(fd, buf, len);
}


/*
 * What: Writes once to fd with write(2) result semantics.
 * Why: Single entry point for every network write.
 * From: Issue #248
 */
ssize_t dcc_transport_write(int fd, const void *buf, size_t len)
{
    const struct dcc_transport *ops = dcc_transport_of(fd);

    if (ops)
        return ops->write(dcc_conn.ctx, fd, buf, len);
    return write(fd, buf, len);
}


/*
 * What: Returns 1 if sendfile() may write to fd directly.
 * Why: sendfile() bypasses a transport that frames bytes.
 * From: Issue #248
 */
int dcc_transport_allows_sendfile(int fd)
{
    const struct dcc_transport *ops = dcc_transport_of(fd);

    return ops ? ops->allows_sendfile : 1;
}


/*
 * What: Returns the I/O timeout, DISTCC_IO_TIMEOUT or 300s.
 * Why: A compile can take far longer than a connect.
 */
int dcc_get_io_timeout(void)
{
    static const int default_dcc_io_timeout = 300;
    static int current_timeout = 0;

    if (current_timeout > 0)
        return current_timeout;

    const char *user_timeout = getenv("DISTCC_IO_TIMEOUT");
    if (user_timeout) {
        int parsed_user_timeout = atoi(user_timeout);
        if (parsed_user_timeout <= 0) {
          rs_log_error("Bad DISTCC_IO_TIMEOUT value: %s", user_timeout);
          exit(EXIT_BAD_ARGUMENTS);
        }
        current_timeout = parsed_user_timeout;
    } else {
        current_timeout = default_dcc_io_timeout;
    }
    return current_timeout;
}

/*
 * What: Waits until fd is readable or timeout seconds pass.
 * Why: Bounds waits on nonblocking descriptors.
 */
int dcc_select_for_read(int fd,
                        int timeout)
{
    fd_set fds;
    int rs;
    struct timeval tv;

    tv.tv_sec = timeout;
    tv.tv_usec = 0;

    while (1) {
        FD_ZERO(&fds);
        FD_SET(fd, &fds);

        /* What: Retries select() with tv as the OS left it.
         * Why: Only Linux updates tv, so others may wait longer. */

        rs_trace("select for read on fd%d for %ds", fd, (int) tv.tv_sec);
        rs = select(fd+1, &fds, NULL, NULL, &tv);
        if (rs == -1 && errno == EINTR) {
            rs_trace("select was interrupted");
            continue;
        } else if (rs == -1) {
            rs_log_error("select() failed: %s", strerror(errno));
            return EXIT_IO_ERROR;
        } else if (rs == 0) {
            rs_log_error("IO timeout");
            return EXIT_IO_ERROR;
        } else if (!FD_ISSET(fd, &fds)) {
            rs_log_error("how did fd not get set?");
            continue;
        } else {
            break;
        }
    }
    return 0;
}


/*
 * What: Waits until fd is writable, errored, or timed out.
 * Why: The next write() reports an error state with errno.
 */
int dcc_select_for_write(int fd, int timeout)
{
    fd_set write_fds;
    fd_set except_fds;
    int rs;

    struct timeval tv;

    tv.tv_sec = timeout;
    tv.tv_usec = 0;

    while (1) {
        FD_ZERO(&write_fds);
        FD_ZERO(&except_fds);
        FD_SET(fd, &write_fds);
        FD_SET(fd, &except_fds);
        rs_trace("select for write on fd%d", fd);

        rs = select(fd + 1, NULL, &write_fds, &except_fds, &tv);

        if (rs == -1 && errno == EINTR) {
            rs_trace("select was interrupted");
            continue;
        } else if (rs == -1) {
            rs_log_error("select failed: %s", strerror(errno));
            return EXIT_IO_ERROR;
        } else if (rs == 0) {
            rs_log_error("IO timeout");
            return EXIT_IO_ERROR;
        } else {
            if (FD_ISSET(fd, &except_fds)) {
              rs_trace("error condition on fd%d", fd);
            }
            return 0;
        }
    }
}



/*
 * What: Reads exactly len bytes from fd.
 * Why: Protocol tokens and bodies have fixed lengths.
 */
int dcc_readx(int fd, void *buf, size_t len)
{
    ssize_t r;
    int ret;

    while (len > 0) {
        r = dcc_transport_read(fd, buf, len);

        if (r == -1 && errno == EAGAIN) {
            if ((ret = dcc_select_for_read(fd, dcc_get_io_timeout())))
                return ret;
            else
                continue;
        } else if (r == -1 && errno == EINTR) {
            continue;
        } else if (r == -1) {
            rs_log_error("failed to read: %s", strerror(errno));
            return EXIT_IO_ERROR;
        } else if (r == 0) {
            rs_log_error("unexpected eof on fd%d", fd);
            return EXIT_TRUNCATED;
        } else {
            buf = &((char *) buf)[r];
            len -= r;
        }
    }

    return 0;
}


/*
 * What: Writes all len bytes to fd; returns 0 or exit code.
 * Why: write() may accept only part of the buffer.
 */
int dcc_writex(int fd, const void *buf, size_t len)
{
    ssize_t r;
    int ret;

    while (len > 0) {
        r = dcc_transport_write(fd, buf, len);

        if (r == -1 && errno == EAGAIN) {
            if ((ret = dcc_select_for_write(fd, dcc_get_io_timeout())))
                return ret;
            else
                continue;
        } else if (r == -1 && errno == EINTR) {
            continue;
        } else if (r == -1) {
            rs_log_error("failed to write: %s", strerror(errno));
            return EXIT_IO_ERROR;
        } else {
            buf = &((char *) buf)[r];
            len -= r;
        }
    }

    return 0;
}

/*
 * What: Sets TCP_CORK on fd where available and enabled.
 * Why: Lets the kernel coalesce small protocol writes.
 */
int tcp_cork_sock(int POSSIBLY_UNUSED(fd), int POSSIBLY_UNUSED(corked))
{
#if defined(TCP_CORK) && defined(SOL_TCP)
    if (!dcc_getenv_bool("DISTCC_TCP_CORK", 1) || !(not_sd_is_socket(fd, AF_INET, SOCK_STREAM, 1) ||
                                                    not_sd_is_socket(fd, AF_INET6, SOCK_STREAM, 1)))
        return 0;

    if (setsockopt(fd, SOL_TCP, TCP_CORK, &corked, sizeof corked) == -1) {
        if (errno == ENOSYS || errno == ENOTSUP) {
            if (corked)
                rs_trace("no corks allowed on fd%d", fd);
        } else {
            rs_log_warning("setsockopt(corked=%d) failed: %s",
                           corked, strerror(errno));
        }
    }
#endif
    return 0;
}

/*
 * What: Closes fd; closing either fd ends the job connection.
 * Why: No transport I/O may follow the first close.
 * From: Issue #248
 */
int dcc_close(int fd)
{
    const struct dcc_transport *ops = dcc_transport_of(fd);

    if (ops) {
        if (ops->close)
            ops->close(dcc_conn.ctx, fd);
        dcc_transport_bind(-1, -1, NULL, NULL);
    }

    if (close(fd) != 0) {
        rs_log_error("failed to close fd%d: %s", fd, strerror(errno));
        return EXIT_IO_ERROR;
    }
    return 0;
}
