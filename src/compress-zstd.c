/* -*- c-file-style: "java"; indent-tabs-mode: nil; tab-width: 4; fill-column: 78 -*-
 *
 * distcc -- A simple distributed compiler system
 *
 * Copyright (C) 2017 by Shawn Landen <slandden@gmail.com>
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

#ifdef HAVE_ZSTD
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>

#include <sys/stat.h>
#include <sys/types.h>
#include <sys/socket.h>
#ifdef HAVE_SYS_MMAN_H
#  include <sys/mman.h>
#endif
#include <zstd.h>
/* zstd has not always shipped with <zstd_errors.h>. */
#define ZSTD_error_dstSize_tooSmall 70

#include <netinet/in.h>
#include <netinet/tcp.h>

#include "distcc.h"
#include "trace.h"
#include "util.h"
#include "exitcode.h"

static struct ZSTD_CCtx_s *cctx;
static struct ZSTD_DCtx_s *dctx;
/**
 * @file
 *
 * Compressed bulk data transfer for distcc.
 *
 * see compress-lzox1.c
 */


/*
 * Compress from a file to a newly malloc'd block.
 */
int dcc_compress_file_zstd(int in_fd,
                            size_t in_len,
                            char **out_buf,
                            size_t *out_len)
{
    char *in_buf = NULL;
    int ret;

    if ((in_buf = malloc(in_len)) == NULL) {
        rs_log_error("allocation of %ld byte buffer failed",
                     (long) in_len);
        ret = EXIT_OUT_OF_MEMORY;
        goto out;
    }

    if ((ret = dcc_readx(in_fd, in_buf, in_len)))
        goto out;

    if ((ret = dcc_compress_zstd_alloc(in_buf, in_len, out_buf, out_len)))
        goto out;

    out:
    if (in_buf != NULL) {
        free(in_buf);
    }

    return ret;
}


/**
 * Compress bulk data into one buffer for the distcc wire protocol.
 **/
int dcc_compress_zstd_alloc(const char *in_buf,
                             size_t in_len,
                             char **out_buf_ret,
                             size_t *out_len_ret)
{
    int ret = 0;
    char *out_buf = NULL;
    size_t out_size;
    size_t out_len;

    if (!cctx) {
        cctx = ZSTD_createCCtx();
        if (!cctx) {
            rs_log_error("failed to allocate CCtx buffer");
            return EXIT_OUT_OF_MEMORY;
        }
    }

    /* Zstd can expand incompressible input, so use its documented bound. */
    out_size = ZSTD_compressBound(in_len);
    if ((out_buf = malloc(out_size)) == NULL) {
        rs_log_error("failed to allocate compression buffer");
        return EXIT_OUT_OF_MEMORY;
    }

    out_len = ZSTD_compressCCtx(cctx,
                               out_buf, out_size,
                               in_buf, in_len,
                               1);
    if (ZSTD_isError(out_len)) {
        rs_log_error("Zstd compression failed: %s", ZSTD_getErrorName(out_len));
        free(out_buf);
        return EXIT_IO_ERROR;
    }

    *out_buf_ret = out_buf;
    *out_len_ret = out_len;

    rs_trace("compressed %ld bytes to %ld bytes: %d%%",
             (long) in_len, (long) out_len,
             (int) (in_len ? 100*out_len / in_len : 0));

    return ret;
}



/**
 * Receive @p in_len compressed bytes from @p in_fd, and write the
 * decompressed form to @p out_fd.
 *
 * Protocol version 4 sends both compressed and uncompressed sizes, so normal
 * zstd transfers allocate the exact output buffer before decompression.
 **/
int dcc_r_bulk_zstd(int out_fd, int in_fd,
                     unsigned in_len, unsigned uncompr_size)
{
    int ret;
    char *in_buf = NULL, *out_buf = NULL;
    size_t out_size = 0, out_len;

    /* NOTE: out_size is the buffer size, out_len is the amount of actual
     * data. */

    if (!dctx) {
        dctx = ZSTD_createDCtx();
        if (!dctx) {
            rs_log_error("failed to allocate DCtx buffer");
            return EXIT_OUT_OF_MEMORY;
        }
    }

    if (in_len == 0)
        return 0;               /* just check */

    if ((in_buf = malloc(in_len)) == NULL) {
        rs_log_error("failed to allocate decompression input");
        ret = EXIT_OUT_OF_MEMORY;
        goto out;
    }

    if ((ret = dcc_readx(in_fd, in_buf, in_len)) != 0)
        goto out;

    out_size = uncompr_size ? uncompr_size + 1 : 10000;

try_again_with_a_bigger_buffer:
    if ((out_buf = malloc(out_size)) == NULL) {
        rs_log_error("failed to allocate decompression buffer");
        ret = EXIT_OUT_OF_MEMORY;
        goto out;
    }

    out_len = ZSTD_decompressDCtx(dctx,
                                  out_buf, out_size,
                                  in_buf, in_len);

    if (!ZSTD_isError(out_len)) {
        rs_trace("decompressed %ld bytes to %ld bytes: %d%%",
                 (long) in_len, (long) out_len,
                 (int) (out_len ? 100*in_len / out_len : 0));

        ret = dcc_writex(out_fd, out_buf, out_len);

        goto out;
        /* ZSTD_getErrorCode(out_len) == ZSTD_error_dstSize_tooSmall. */
    } else if ((ssize_t)out_len == -ZSTD_error_dstSize_tooSmall) {
        free(out_buf);
        out_buf = 0;
        out_size *= 2;
        rs_trace("ZSTD_CONTENTSIZE_ERROR, trying again with %lu byte buffer",
                 (unsigned long) out_size);
        goto try_again_with_a_bigger_buffer;
    } else {
        rs_log_error("Zstd decompression failed: %s", ZSTD_getErrorName(out_len));
        ret = EXIT_IO_ERROR;
        goto out;
    }

out:
    free(in_buf);
    free(out_buf);

    return ret;
}
#endif
