/* -*- c-file-style: "java"; indent-tabs-mode: nil; tab-width: 4; fill-column: 78 -*-
 *
 * distcc -- A simple distributed compiler system
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
 * tls.c -- Native TLS transport for job connections, using GnuTLS.
 *
 * TLS runs below the distcc protocol.  Once the TCP connection exists (and,
 * on the server, once --allow has accepted the client), both sides run a
 * TLS 1.3 handshake in which each one presents a certificate signed by the
 * configured CA.  The connection is then bound to the TLS transport in io.c
 * and the unchanged compile protocol runs through it.  A failed handshake
 * fails the job for that host; there is never a retry in plaintext.
 *
 * Configuration (issue #248): the host option
 * ",tls" with an explicit port, the client environment variables
 * DISTCC_TLS_CA, DISTCC_TLS_CERT and DISTCC_TLS_KEY, and the daemon options
 * --tls, --tls-ca, --tls-cert and --tls-key.
 */


#include <config.h>

#ifdef HAVE_GNUTLS

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include <gnutls/gnutls.h>
#include <gnutls/x509.h>

#include "distcc.h"
#include "trace.h"
#include "exitcode.h"
#include "util.h"

/* How long a server waits for a client to complete the handshake.  The
 * accepted socket is blocking, so without this a client that connects and
 * sends nothing would hold a server process forever. */
#define DCC_TLS_SERVER_HANDSHAKE_TIMEOUT 10 /* seconds */

/* Both ends are distcc-ng, so only TLS 1.3 is offered. */
static const char dcc_tls_priority_append[] = "-VERS-ALL:+VERS-TLS1.3";

static gnutls_certificate_credentials_t dcc_tls_cred;


static ssize_t dcc_tls_read(void *ctx, int UNUSED(fd), void *buf, size_t len)
{
    ssize_t r = gnutls_record_recv((gnutls_session_t) ctx, buf, len);

    if (r >= 0)
        return r;
    if (r == GNUTLS_E_AGAIN) {
        errno = EAGAIN;
    } else if (r == GNUTLS_E_INTERRUPTED) {
        errno = EINTR;
    } else if (r == GNUTLS_E_PREMATURE_TERMINATION) {
        /* The peer closed the TCP connection without close_notify.  Report
         * it as end of file, as a plain socket would; the length-framed
         * distcc protocol detects a truncated stream by itself. */
        rs_trace("TLS peer closed without close_notify");
        return 0;
    } else {
        rs_log_error("TLS read failed: %s", gnutls_strerror((int) r));
        errno = EIO;
    }
    return -1;
}


static ssize_t dcc_tls_write(void *ctx, int UNUSED(fd), const void *buf,
                             size_t len)
{
    ssize_t r = gnutls_record_send((gnutls_session_t) ctx, buf, len);

    if (r >= 0)
        return r;
    if (r == GNUTLS_E_AGAIN) {
        errno = EAGAIN;
    } else if (r == GNUTLS_E_INTERRUPTED) {
        errno = EINTR;
    } else {
        rs_log_error("TLS write failed: %s", gnutls_strerror((int) r));
        errno = EIO;
    }
    return -1;
}


/**
 * Send close_notify and release the session.  A peer that has already gone
 * away is not an error at this point.
 **/
static int dcc_tls_close(void *ctx, int fd)
{
    gnutls_session_t session = (gnutls_session_t) ctx;
    int r;

    while ((r = gnutls_bye(session, GNUTLS_SHUT_WR)) == GNUTLS_E_AGAIN
           || r == GNUTLS_E_INTERRUPTED) {
        if (r == GNUTLS_E_AGAIN
            && dcc_select_for_write(fd, dcc_get_io_timeout()) != 0)
            break;
    }
    if (r < 0)
        rs_trace("TLS close_notify not sent: %s", gnutls_strerror(r));
    gnutls_deinit(session);
    return 0;
}


static size_t dcc_tls_pending(void *ctx)
{
    return gnutls_record_check_pending((gnutls_session_t) ctx);
}


static int dcc_tls_wants_write(void *ctx)
{
    return gnutls_record_get_direction((gnutls_session_t) ctx) == 1;
}


static const struct dcc_transport dcc_transport_tls = {
    dcc_tls_read,
    dcc_tls_write,
    dcc_tls_close,
    0,                          /* sendfile() would bypass the encryption */
    dcc_tls_pending,
    dcc_tls_wants_write
};


/**
 * Load the CA, certificate and key used for every TLS connection of this
 * process.
 **/
static int dcc_tls_load_credentials(const char *ca, const char *cert,
                                    const char *key)
{
    int r;

    if (!ca || !cert || !key) {
        rs_log_error("TLS needs a CA file, a certificate file and a key file");
        return EXIT_BAD_ARGUMENTS;
    }
    if ((r = gnutls_certificate_allocate_credentials(&dcc_tls_cred)) < 0) {
        rs_log_error("TLS credentials: %s", gnutls_strerror(r));
        return EXIT_OUT_OF_MEMORY;
    }
    r = gnutls_certificate_set_x509_trust_file(dcc_tls_cred, ca,
                                               GNUTLS_X509_FMT_PEM);
    if (r <= 0) {
        rs_log_error("no CA certificate loaded from %s: %s", ca,
                     r < 0 ? gnutls_strerror(r) : "file holds none");
        return EXIT_BAD_ARGUMENTS;
    }
    r = gnutls_certificate_set_x509_key_file(dcc_tls_cred, cert, key,
                                             GNUTLS_X509_FMT_PEM);
    if (r < 0) {
        rs_log_error("failed to load TLS certificate %s and key %s: %s",
                     cert, key, gnutls_strerror(r));
        return EXIT_BAD_ARGUMENTS;
    }
    return 0;
}


/**
 * Load the daemon's TLS credentials.  Called before distccd gives up root,
 * so that a key file readable only by root can be used.
 **/
int dcc_tls_load_server_credentials(const char *ca, const char *cert,
                                    const char *key)
{
    return dcc_tls_load_credentials(ca, cert, key);
}


static int dcc_tls_new_session(gnutls_session_t *session, unsigned flags)
{
    const char *bad_pos = NULL;
    int r;

    if ((r = gnutls_init(session, flags)) < 0) {
        rs_log_error("TLS session: %s", gnutls_strerror(r));
        return EXIT_OUT_OF_MEMORY;
    }
    if ((r = gnutls_set_default_priority_append(*session,
                                                dcc_tls_priority_append,
                                                &bad_pos, 0)) < 0
        || (r = gnutls_credentials_set(*session, GNUTLS_CRD_CERTIFICATE,
                                       dcc_tls_cred)) < 0) {
        rs_log_error("TLS session setup: %s", gnutls_strerror(r));
        gnutls_deinit(*session);
        return EXIT_DISTCC_FAILED;
    }
    return 0;
}


/**
 * Run the handshake to completion.  @p fd is waited on in whichever
 * direction GnuTLS needs; each wait is limited to @p timeout seconds.
 **/
static int dcc_tls_handshake(gnutls_session_t session, int fd, int timeout)
{
    int r;

    while ((r = gnutls_handshake(session)) < 0) {
        if (r == GNUTLS_E_AGAIN) {
            int ret = gnutls_record_get_direction(session)
                ? dcc_select_for_write(fd, timeout)
                : dcc_select_for_read(fd, timeout);
            if (ret)
                return GNUTLS_E_TIMEDOUT;
        } else if (gnutls_error_is_fatal(r)) {
            return r;
        }
    }
    return 0;
}


/**
 * Log why certificate verification failed.
 **/
static void dcc_tls_log_verify_failure(gnutls_session_t session,
                                       const char *peer)
{
    gnutls_datum_t out;
    unsigned status = gnutls_session_get_verify_cert_status(session);

    if (gnutls_certificate_verification_status_print(
            status, gnutls_certificate_type_get(session), &out, 0) == 0) {
        rs_log_error("TLS certificate of %s rejected: %s", peer, out.data);
        gnutls_free(out.data);
    } else {
        rs_log_error("TLS certificate of %s rejected", peer);
    }
}


static int dcc_is_ip_literal(const char *host)
{
    unsigned char addr[sizeof(struct in6_addr)];

    return inet_pton(AF_INET, host, addr) == 1
        || inet_pton(AF_INET6, host, addr) == 1;
}


/**
 * Client side: run the TLS handshake on a connected socket to
 * @p hostname:@p port and bind it to the TLS transport.  The server
 * certificate must be signed by DISTCC_TLS_CA and name @p hostname.
 **/
int dcc_tls_connect(int to_net_fd, int from_net_fd, const char *hostname,
                    int port)
{
    gnutls_session_t session;
    int r, ret;

    if (!dcc_tls_cred
        && (ret = dcc_tls_load_credentials(getenv("DISTCC_TLS_CA"),
                                           getenv("DISTCC_TLS_CERT"),
                                           getenv("DISTCC_TLS_KEY"))))
        return ret;

    if ((ret = dcc_tls_new_session(&session,
                                   GNUTLS_CLIENT | GNUTLS_NONBLOCK
                                   | GNUTLS_NO_TICKETS)))
        return ret;

    /* SNI must not carry an IP address (RFC 6066); the certificate is
     * still checked against it. */
    if (!dcc_is_ip_literal(hostname))
        gnutls_server_name_set(session, GNUTLS_NAME_DNS, hostname,
                               strlen(hostname));
    gnutls_session_set_verify_cert(session, hostname, 0);
    gnutls_transport_set_int2(session, from_net_fd, to_net_fd);

    r = dcc_tls_handshake(session, from_net_fd, dcc_get_io_timeout());
    if (r == 0) {
        char *desc = gnutls_session_get_desc(session);
        rs_log_info("TLS to %s:%d: %s", hostname, port, desc);
        gnutls_free(desc);
        dcc_transport_bind(from_net_fd, to_net_fd, &dcc_transport_tls,
                           session);
        return 0;
    }

    if (r == GNUTLS_E_CERTIFICATE_VERIFICATION_ERROR) {
        dcc_tls_log_verify_failure(session, hostname);
    } else if (r == GNUTLS_E_PULL_ERROR || r == GNUTLS_E_PUSH_ERROR
               || r == GNUTLS_E_PREMATURE_TERMINATION) {
        rs_log_error("TLS handshake with %s:%d failed: %s; the endpoint is "
                     "probably not a distccd TLS listener",
                     hostname, port, gnutls_strerror(r));
    } else {
        rs_log_error("TLS handshake with %s:%d failed: %s",
                     hostname, port, gnutls_strerror(r));
    }
    gnutls_deinit(session);
    return EXIT_CONNECT_FAILED;
}


/**
 * Server side: run the TLS handshake on an accepted connection and bind it
 * to the TLS transport.  The client must present a certificate signed by
 * the daemon's CA.
 **/
int dcc_tls_accept(int in_fd, int out_fd)
{
    gnutls_session_t session;
    int r, ret;

    if ((ret = dcc_tls_new_session(&session,
                                   GNUTLS_SERVER | GNUTLS_NO_TICKETS)))
        return ret;

    gnutls_certificate_server_set_request(session, GNUTLS_CERT_REQUIRE);
    gnutls_session_set_verify_cert(session, NULL, 0);
    gnutls_handshake_set_timeout(session,
                                 DCC_TLS_SERVER_HANDSHAKE_TIMEOUT * 1000);
    gnutls_transport_set_int2(session, in_fd, out_fd);

    r = dcc_tls_handshake(session, in_fd, DCC_TLS_SERVER_HANDSHAKE_TIMEOUT);
    if (r == 0) {
        char *desc = gnutls_session_get_desc(session);
        rs_log_info("TLS: %s", desc);
        gnutls_free(desc);
        dcc_transport_bind(in_fd, out_fd, &dcc_transport_tls, session);
        return 0;
    }

    if (r == GNUTLS_E_CERTIFICATE_VERIFICATION_ERROR)
        dcc_tls_log_verify_failure(session, "client");
    else if (r == GNUTLS_E_UNEXPECTED_PACKET
             || r == GNUTLS_E_UNSUPPORTED_VERSION_PACKET)
        rs_log_error("TLS handshake failed: %s; the client is probably not "
                     "using TLS", gnutls_strerror(r));
    else
        rs_log_error("TLS handshake failed: %s", gnutls_strerror(r));
    gnutls_deinit(session);
    return EXIT_ACCESS_DENIED;
}

#endif /* HAVE_GNUTLS */
