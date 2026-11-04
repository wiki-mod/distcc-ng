/* -*- c-file-style: "java"; indent-tabs-mode: nil; tab-width: 4; fill-column: 78 -*-
 *
 * distcc -- A simple distributed compiler system
 *
 * Copyright (C) 2002, 2003 by Martin Pool <mbp@samba.org>
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


#include <config.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <ctype.h>
#include <stdint.h>

#include <sys/stat.h>

#include "distcc.h"
#include "trace.h"
#include "exitcode.h"
#include "rpc.h"
#include "snprintf.h"


/*
 * What: Sends (x) and receives (r) token packets via io.c.
 * Why: Each packet is a 4-char token plus hex value or data.
 */


/*
 * What: Sends a 4-char token and a value as 8 hex digits.
 * Why: Fixed-width packets let the reader check its position.
 */
int dcc_x_token_int(int ofd, const char *token, unsigned param)
{
    char buf[13];
    int shift;
    char *p;
    const char *hex = "0123456789abcdef";

    if (strlen(token) != 4) {
        rs_log_crit("token \"%s\" seems wrong", token);
        return EXIT_PROTOCOL_ERROR;
    }
    memcpy(buf, token, 4);

    /* What: Formats param as 8 hex digits by hand.
     * Why: snprintf() is slow for this frequently used path. */
    for (shift=28, p = &buf[4];
         shift >= 0;
         shift -= 4, p++) {
        *p = hex[(param >> shift) & 0xf];
    }
    buf[12] = '\0';

    rs_trace("send %s", buf);
    return dcc_writex(ofd, buf, 12);
}

/*
 * What: Sends a token and two values as 8 hex digits each.
 * Why: Zstd bodies carry compressed and plain lengths.
 * From: Issue #67 | PR #80
 */
int dcc_x_token_2int(int ofd, const char *token, unsigned param,
                     unsigned param2)
{
    char buf[21];
    int shift;
    char *p;
    const char *hex = "0123456789abcdef";

    if (strlen(token) != 4) {
        rs_log_crit("token \"%s\" seems wrong", token);
        return EXIT_PROTOCOL_ERROR;
    }
    memcpy(buf, token, 4);

    for (shift = 28, p = &buf[4]; shift >= 0; shift -= 4, p++) {
        *p = hex[(param >> shift) & 0xf];
    }
    for (shift = 28, p = &buf[12]; shift >= 0; shift -= 4, p++) {
        *p = hex[(param2 >> shift) & 0xf];
    }
    buf[20] = '\0';

    rs_trace("send %s", buf);
    return dcc_writex(ofd, buf, 20);
}


/*
 * What: Sends the DONE token with the protocol version.
 * Why: Starts every result so the client can check it.
 */
int dcc_x_result_header(int ofd,
                        enum dcc_protover protover)
{
    return dcc_x_token_int(ofd, "DONE", protover);
}


/*
 * What: Sends the compiler exit status as a STAT token.
 * Why: The client returns the remote compiler's status.
 */
int dcc_x_cc_status(int ofd, int status)
{
    return dcc_x_token_int(ofd, "STAT", (unsigned) status);
}


/*
 * What: Reads a bare 4-char token without its value.
 * Why: Exported helper; no caller exists in this tree.
 */
int dcc_r_token(int ifd, char *buf)
{
    return dcc_readx(ifd, buf, 4);
}


/*
 * What: Logs the printable bytes around a mismatched token.
 * Why: Shows what the peer sent instead of the protocol.
 */
int dcc_explain_mismatch(const char *buf,
                         size_t buflen,
                         int ifd)
{
    ssize_t ret;
    char extrabuf[200];
    char *p;
    size_t l;

    memcpy(extrabuf, buf, buflen);

    ret = dcc_transport_read(ifd, extrabuf + buflen, sizeof extrabuf - 1 - buflen);
    if (ret == -1) {
        ret = 0;
    }

    l = buflen + ret;

    extrabuf[l] = '\0';
    for (p = extrabuf; *p; p++)
        if (!(isprint((uint8_t)*p) || *p == ' ' || *p == '\t')) {
            *p = '\0';
            break;
        }

    rs_log_error("error context: \"%s\"", extrabuf);

    return 0;
}


/*
 * What: Reads an expected token and its 8-hex-digit value.
 * Why: Token names only check that the stream is in sync.
 */
int dcc_r_token_int(int ifd, const char *expected, unsigned *val)
{
    char buf[13], *bum;
    int ret;

    if (strlen(expected) != 4) {
        rs_log_error("expected token \"%s\" seems wrong", expected);
        return EXIT_PROTOCOL_ERROR;
    }

    if ((ret = dcc_readx(ifd, buf, 12))) {
        rs_log_error("read failed while waiting for token \"%s\"",
                    expected);
        return ret;
    }

    if (memcmp(buf, expected, 4)) {
        rs_log_error("protocol derailment: expected token \"%s\"", expected);
        dcc_explain_mismatch(buf, 12, ifd);
        return EXIT_PROTOCOL_ERROR;
    }

    buf[12] = '\0';

    *val = strtoul(&buf[4], &bum, 16);
    if (bum != &buf[12]) {
        rs_log_error("failed to parse parameter of token \"%s\"",
                     expected);
        dcc_explain_mismatch(buf, 12, ifd);
        return EXIT_PROTOCOL_ERROR;
    }

    rs_trace("got %s", buf);

    return 0;
}


/*
 * What: Reads an expected token and two hex values.
 * Why: Zstd bodies carry compressed and plain lengths.
 * From: Issue #67 | PR #80
 */
int dcc_r_token_2int(int ifd, const char *expected,
                     unsigned *val,
                     unsigned *val2)
{
    char buf[21], *bum, t;
    int ret;

    if (strlen(expected) != 4) {
        rs_log_error("expected token \"%s\" seems wrong", expected);
        return EXIT_PROTOCOL_ERROR;
    }

    if ((ret = dcc_readx(ifd, buf, 20))) {
        rs_log_error("read failed while waiting for token \"%s\"",
                    expected);
        return ret;
    }

    if (memcmp(buf, expected, 4)) {
        rs_log_error("protocol derailment: expected token \"%s\"", expected);
        dcc_explain_mismatch(buf, 12, ifd);
        return EXIT_PROTOCOL_ERROR;
    }

    t = buf[12];
    buf[12] = '\0';
    *val = strtoul(&buf[4], &bum, 16);
    if (bum != &buf[12]) {
        rs_log_error("failed to parse parameter of token \"%s\"",
                     expected);
        buf[12] = t;
        dcc_explain_mismatch(buf, 20, ifd);
        return EXIT_PROTOCOL_ERROR;
    }

    buf[12] = t;
    buf[20] = '\0';
    *val2 = strtoul(&buf[12], &bum, 16);
    if (bum != &buf[20]) {
        rs_log_error("failed to parse parameter of token \"%s\"",
                     expected);
        dcc_explain_mismatch(buf, 20, ifd);
        return EXIT_PROTOCOL_ERROR;
    }

    rs_trace("got %s", buf);

    return 0;
}

/*
 * What: Reads any token and its value into token and val.
 * Why: Used where several different tokens may come next.
 */
int dcc_r_sometoken_int(int ifd, char *token, unsigned *val)
{
    char buf[13], *bum;
    int ret;

    if ((ret = dcc_readx(ifd, buf, 12))) {
        rs_log_error("read failed while waiting for some token");
        return ret;
    }

    memcpy(token, buf, 4);
    token[4] = '\0';

    buf[12] = '\0';

    *val = strtoul(&buf[4], &bum, 16);
    if (bum != &buf[12]) {
        rs_log_error("failed to parse parameter of token \"%s\"",
                     token);
        dcc_explain_mismatch(buf, 12, ifd);
        return EXIT_PROTOCOL_ERROR;
    }

    rs_trace("got %s", buf);

    return 0;
}

/*
 * What: Reads l bytes into a new NUL-terminated buffer.
 * Why: Peer-supplied lengths are capped before malloc().
 * From: Issue #224 | PR #230
 */
int dcc_r_str_alloc(int fd, unsigned l, char **buf)
{
     char *s;

     if (l > DCC_MAX_RPC_STRING_LEN) {
         rs_log_error("string length %u from peer exceeds sanity limit "
                      "%u, rejecting", l, DCC_MAX_RPC_STRING_LEN);
         return EXIT_PROTOCOL_ERROR;
     }

     s = *buf = malloc((size_t) l + 1);
     if (!s) {
          rs_log_error("malloc failed");
          return EXIT_OUT_OF_MEMORY;
     }
     if (dcc_readx(fd, s, (size_t) l))
          return EXIT_OUT_OF_MEMORY;

     s[l] = 0;

     return 0;
}


/*
 * What: Sends a token with the string length, then its bytes.
 * Why: The NUL terminator is not sent on the wire.
 */
int dcc_x_token_string(int fd,
                       const char *token,
                       const char *buf)
{
    int ret;
    size_t len;

    len = strlen(buf);
    if ((ret = dcc_x_token_int(fd, token, (unsigned) len)))
        return ret;
    if ((ret = dcc_writex(fd, buf, len)))
        return ret;
    rs_trace("send string '%s'", buf);
    return 0;
}


/*
 * What: Reads an expected token and the string it announces.
 * Why: Pairs with dcc_x_token_string() on the sender.
 */
int dcc_r_token_string(int ifd, const char *expect_token,
                       char **p_str)
{
    unsigned a_len;
    int ret;

    if ((ret = dcc_r_token_int(ifd, expect_token, &a_len)))
        return ret;

    if ((ret = dcc_r_str_alloc(ifd, a_len, p_str)))
        return ret;

    rs_trace("got '%s'", *p_str);

    return 0;
}

/*
 * What: Reads an argc token and that many argv strings.
 * Why: The argument count from the peer is capped first.
 * From: Issue #224 | PR #230
 */
int dcc_r_argv(int ifd,
               const char *argc_token,
               const char *argv_token,
               /*@out@*/ char ***argv)
{
    unsigned i;
    unsigned argc;
    char **a;
    int ret;

    *argv = NULL;

    if (dcc_r_token_int(ifd, argc_token, &argc))
        return EXIT_PROTOCOL_ERROR;

    if (argc > DCC_MAX_RPC_ARGC) {
        rs_log_error("argument count %u from peer exceeds sanity limit "
                     "%u, rejecting", argc, DCC_MAX_RPC_ARGC);
        return EXIT_PROTOCOL_ERROR;
    }

    rs_trace("reading %d arguments from job submission", argc);

    /* What: Allocates argc + 1 slots.
     * Why: argv must end with a NULL element. */
    *argv = a = (char **) calloc((size_t) argc+1, sizeof a[0]);
    if (a == NULL) {
        rs_log_error("alloc failed");
        return EXIT_OUT_OF_MEMORY;
    }
    a[argc] = NULL;

    for (i = 0; i < argc; i++) {
        if ((ret = dcc_r_token_string(ifd, argv_token, &a[i])))
            return ret;

        rs_trace("argv[%d] = \"%s\"", i, a[i]);
    }

    dcc_trace_argv("got arguments", a);

    return 0;
}
