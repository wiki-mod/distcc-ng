/* -*- c-file-style: "java"; indent-tabs-mode: nil; tab-width: 4; fill-column: 78 -*-
 *
 * distcc -- A simple distributed compiler system
 *
 * Copyright (C) 2002, 2003, 2004 by Martin Pool
 * Copyright 2008 Google Inc.
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
 * What: Sends file bodies to a peer with sendfile().
 * Why: Avoids copying file data through user space.
 */

#include <config.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>

#include <sys/stat.h>
#ifdef HAVE_SYS_SENDFILE_H
#  include <sys/sendfile.h>
#endif
#include <sys/types.h>
#include <sys/socket.h>

#include <netinet/in.h>
#include <netinet/tcp.h>

#include "distcc.h"
#include "trace.h"
#include "util.h"
#include "exitcode.h"



#ifdef HAVE_SENDFILE

#if defined(__FreeBSD__)
/*
 * What: FreeBSD sendfile() with the Linux-style result.
 * Why: Argument order and results differ per platform.
 */
static ssize_t sys_sendfile(int ofd, int ifd, off_t *offset, size_t size)
{
    off_t sent_bytes;
    int ret;

    ret = sendfile(ifd, ofd, *offset, size, 0, &sent_bytes, 0);
    if (ret == -1) {
        if (errno == EAGAIN) {
            if (sent_bytes == 0) {
                return -1;
            } else {
                /* What: Returns a partial send as success.
                 * Why: The caller loops until the size is sent. */
                *offset += sent_bytes;
                return sent_bytes;
            }
        } else {
            return -1;
        }
    } else if (ret == 0) {
        *offset += size;
        return size;
    } else {
        rs_log_error("don't know how to handle return %d from BSD sendfile",
                     ret);
        return -1;
    }
}
#elif defined(linux) || defined(__GNU__)
/*
 * What: Linux sendfile(); updates offset by the bytes sent.
 * Why: The reference interface the other variants mimic.
 */
static ssize_t sys_sendfile(int ofd, int ifd, off_t *offset, size_t size)
{
    return sendfile(ofd, ifd, offset, size);
}
#elif defined(__hpux) || defined(__hpux__)
/*
 * What: HP-UX sendfile() with the Linux-style result.
 * Why: HP cc defines __hpux and gcc defines __hpux__.
 */
static ssize_t sys_sendfile(int ofd, int ifd, off_t *offset, size_t size)
{
    ssize_t ret;

    ret = sendfile(ofd, ifd, *offset, size, NULL, 0);
    if (ret == -1) {
        return -1;
    } else if (ret > 0) {
        *offset += ret;
        return ret;
    } else {
        rs_log_error("don't know how to handle return %ld from HP-UX sendfile",
                     (long) ret);
        return -1;
    }
}
#elif defined(__MACH__) && defined(__APPLE__)
/*
 * What: macOS sendfile() with the Linux-style result.
 * Why: Argument order and results differ per platform.
 */
static ssize_t sys_sendfile(int ofd, int ifd, off_t *offset, size_t size)
{
    off_t sent_bytes = size;
    int ret;

    ret = sendfile(ofd, ifd, *offset, &sent_bytes, NULL, 0);
    if (ret == -1) {
        if (errno == EAGAIN) {
            if (sent_bytes == 0) {
                return -1;
            } else {
                /* What: Returns a partial send as success.
                 * Why: The caller loops until the size is sent. */
                *offset += sent_bytes;
                return sent_bytes;
            }
        } else {
            return -1;
        }
    } else if (ret == 0) {
        *offset += size;
        return size;
    } else {
        rs_log_error("don't know how to handle return %d from OS X sendfile",
                     ret);
        return -1;
    }
}
#else
/*
 * What: Fails with ENOSYS on platforms without a variant.
 * Why: The caller then falls back to read and write.
 */
static ssize_t sys_sendfile(int UNUSED(ofd), int UNUSED(ifd),
                            off_t *UNUSED(offset), size_t UNUSED(size))
{
    rs_log_warning("no sendfile implementation on this platform");
    errno = ENOSYS;
    return -1;
}
#endif /* !(__FreeBSD__) && !def(linux) && ... */


/*
 * What: Sends size bytes of ifd to ofd, else read and write.
 * Why: Some filesystems and transports cannot use sendfile().
 * From: Issue #248
 */
int
dcc_pump_sendfile(int ofd, int ifd, size_t size)
{
    ssize_t sent;
    off_t offset = 0;
    int ret;

    if (!dcc_transport_allows_sendfile(ofd))
        return dcc_pump_readwrite(ofd, ifd, size);

    while (size) {
        sent = sys_sendfile(ofd, ifd, &offset, size);
        if (sent == -1) {
            if (errno == EAGAIN) {
                if ((ret = dcc_select_for_write(ofd,
                                                dcc_get_io_timeout())) != 0) {
                    return ret;
                }
                rs_trace("select() returned, continuing to write");
            } else if (errno == EINTR) {
                rs_trace("sendfile() interrupted, continuing");
            } else if (offset == 0) {
                /* What: Falls back to read/write only before any send.
                 * Why: sendfile() leaves the file position unchanged. */
                rs_log_info("decided to use read/write rather than sendfile");
                return dcc_pump_readwrite(ofd, ifd, size);
            } else {
                rs_log_error("sendfile failed: %s", strerror(errno));
                return EXIT_IO_ERROR;
            }
        } else if (sent == 0) {
            rs_log_error("sendfile returned 0? can't cope");
            return EXIT_IO_ERROR;
        } else if (sent != (ssize_t) size) {
            /* What: Retries the rest; sys_sendfile advanced offset.
             * Why: A signal or full buffer can stop a send early. */
            size -= sent;
            rs_log_notice("sendfile: partial transmission of %ld bytes; retrying %ld @%ld",
                          (long) sent, (long) size, (long) offset);
        } else {
            break;
        }
    }
    return 0;
}
#endif /* def HAVE_SENDFILE */
