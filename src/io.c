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


/**
 * @file
 *
 * Common low-level IO utilities.
 *
 * This code is not meant to know about our protocol, only to provide
 * a more comfortable layer on top of Unix IO.
 *
 * @todo Perhaps write things out using writev() to reduce the number
 * of system calls, and the risk of small packets when not using
 * TCP_CORK.
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


/**
 * The job connection and the transport it is bound to.  A process has at
 * most one job connection at a time.  In inetd mode it uses two
 * descriptors (stdin and stdout) for the same connection.
 **/
static struct {
    int in_fd;
    int out_fd;
    const struct dcc_transport *ops;
    void *ctx;
} dcc_conn = { -1, -1, NULL, NULL };


static ssize_t dcc_plain_read(void *UNUSED(ctx), int fd, void *buf,
                              size_t len)
{
    return read(fd, buf, len);
}


static ssize_t dcc_plain_write(void *UNUSED(ctx), int fd, const void *buf,
                               size_t len)
{
    return write(fd, buf, len);
}


/**
 * Plain transport: unencrypted TCP, SSH pipes and inetd descriptors.
 **/
const struct dcc_transport dcc_transport_plain = {
    dcc_plain_read,
    dcc_plain_write,
    NULL,
    1,
    NULL,
    NULL
};


/**
 * Bind the job connection descriptors to a transport.  All network I/O on
 * @p in_fd and @p out_fd then goes through @p ops.
 **/
void dcc_transport_bind(int in_fd, int out_fd,
                        const struct dcc_transport *ops, void *ctx)
{
    dcc_conn.in_fd = in_fd;
    dcc_conn.out_fd = out_fd;
    dcc_conn.ops = ops;
    dcc_conn.ctx = ctx;
}


/**
 * Return the transport bound to @p fd, or NULL for unbound descriptors
 * such as local files and pipes to the compiler.
 **/
static const struct dcc_transport *dcc_transport_of(int fd)
{
    if (dcc_conn.ops && (fd == dcc_conn.in_fd || fd == dcc_conn.out_fd))
        return dcc_conn.ops;
    return NULL;
}


/**
 * Read once from @p fd, with the same return convention as read().
 **/
ssize_t dcc_transport_read(int fd, void *buf, size_t len)
{
    const struct dcc_transport *ops = dcc_transport_of(fd);

    if (ops)
        return ops->read(dcc_conn.ctx, fd, buf, len);
    return read(fd, buf, len);
}


/**
 * Write once to @p fd, with the same return convention as write().
 **/
ssize_t dcc_transport_write(int fd, const void *buf, size_t len)
{
    const struct dcc_transport *ops = dcc_transport_of(fd);

    if (ops)
        return ops->write(dcc_conn.ctx, fd, buf, len);
    return write(fd, buf, len);
}


/**
 * Return true if sendfile() may write directly to @p fd.  A transport
 * that frames or encrypts the stream must not be bypassed.
 **/
int dcc_transport_allows_sendfile(int fd)
{
    const struct dcc_transport *ops = dcc_transport_of(fd);

    return ops ? ops->allows_sendfile : 1;
}


int dcc_get_io_timeout(void)
{
    /** Timeout for all IO other than opening connections.  Much longer,
     * because compiling files can take a long time. **/
    static const int default_dcc_io_timeout = 300; /* seconds */
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

/**
 * @todo Perhaps only apply the timeout for initial connections, not when
 * doing regular IO.
 *
 * For a bound transport this waits until a read can make progress: it
 * returns at once if decrypted data is already buffered, and waits for
 * writability if the transport must send before it can read.
 **/
int dcc_select_for_read(int fd,
                        int timeout)
{
    fd_set fds;
    int rs;
    struct timeval tv;
    const struct dcc_transport *ops = dcc_transport_of(fd);

    if (ops && ops->pending && ops->pending(dcc_conn.ctx) > 0)
        return 0;
    if (ops && ops->wants_write && ops->wants_write(dcc_conn.ctx))
        return dcc_select_for_write(fd, timeout);

    tv.tv_sec = timeout;
    tv.tv_usec = 0;

    while (1) {
        FD_ZERO(&fds);
        FD_SET(fd, &fds);

        /* Linux updates the timeval to reflect the remaining time, but other
         * OSs may not.  So on other systems, we may wait a bit too long if
         * the client is interrupted -- but that won't happen very often so
         * it's no big deal.
         */

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
            break;              /* woot */
        }
    }
    return 0;
}


/*
 * Calls select() to block until the specified fd becomes writeable
 * or has an error condition, or the timeout expires.
 *
 * For a bound transport that must receive before it can send, this waits
 * for readability instead.
 */
int dcc_select_for_write(int fd, int timeout)
{
    fd_set write_fds;
    fd_set except_fds;
    int rs;
    const struct dcc_transport *ops = dcc_transport_of(fd);

    struct timeval tv;

    if (ops && ops->wants_write && !ops->wants_write(dcc_conn.ctx))
        return dcc_select_for_read(fd, timeout);

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
              /*
               * Don't fail here; we couldn't give a good error
               * message, because we don't know what the error
               * condition is.  Instead just return 0 (success),
               * indicating that the select has successfully finished.
               * The next call to write() for that fd will fail but
               * will also set errno properly so that we can give a
               * good error message at that point.
               */
            }
            return 0;
        }
    }
}



/**
 * Read exactly @p len bytes from a file.
 **/
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


/**
 * Write bytes to an fd.  Keep writing until we're all done or something goes
 * wrong.
 *
 * @returns 0 or exit code.
 **/
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

/**
 * Stick a TCP cork in the socket.  It's not clear that this will help
 * performance, but it might.
 *
 * This is a no-op if we don't think this platform has corks.
 **/
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
            /* no need to complain about not uncorking */
        } else {
            rs_log_warning("setsockopt(corked=%d) failed: %s",
                           corked, strerror(errno));
            /* continue anyhow */
        }
    }
#endif /* def TCP_CORK */
    return 0;
}

/**
 * Close @p fd.  Closing either descriptor of the bound job connection ends
 * the connection: the transport's close hook runs and the binding is
 * cleared, so no transport I/O can follow.
 **/
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
