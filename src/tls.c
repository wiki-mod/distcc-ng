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
#include <limits.h>

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>

#include <gnutls/gnutls.h>
#include <gnutls/x509.h>

#include "distcc.h"
#include "trace.h"
#include "exitcode.h"
#include "util.h"
#include "config-parser.h"
#include "client-config.h"
#include "sandbox-config.h"

/* TLS settings: compiled-in defaults, overridden by the tls-* keys of the
 * config file (distcc.conf for the client, distccd.conf for the daemon),
 * overridden in turn by environment variables (client) or command-line
 * options (daemon). */
static struct {
    int enabled;                /* daemon only: serve TLS */
    char *ca;
    char *cert;
    char *key;
    char *crl;
    int require_crl;
    /* How long a server waits for a client to complete the handshake.
     * The accepted socket is blocking, so without a limit a client that
     * connects and sends nothing would hold a server process forever. */
    int handshake_timeout;      /* seconds */
    int port;                   /* daemon only: listener port, 0 = --port */
    /* daemon only: files of client identities (certificate CN), one per
     * line; at most one of them is used, as with GSS-API's lists. */
    char *whitelist;
    char *blacklist;
} dcc_tls_cfg = { 0, NULL, NULL, NULL, NULL, 0, 10, 0, NULL, NULL };

/* The loaded white- or blacklist. */
static char **dcc_tls_list;
static int dcc_tls_list_count;

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
 * Replace the setting @p *slot with a copy of @p value, if @p value is set.
 **/
static void dcc_tls_set(char **slot, const char *value)
{
    if (!value || !*value)
        return;
    free(*slot);
    *slot = strdup(value);
}


/**
 * Config-file handler for the tls-* keys.  Other keys in the same file
 * belong to other readers and are skipped here.
 **/
static void dcc_tls_apply_kv(void *log_prefix, const char *key,
                             const char *value)
{
    int b;

    if (strncmp(key, "tls-", 4) != 0)
        return;

    if (strcmp(key, "tls-enabled") == 0
        || strcmp(key, "tls-require-crl") == 0) {
        if (!dcc_config_parse_bool(value, &b))
            rs_log_warning("%s: invalid boolean '%s' for '%s' (expected "
                           "true/false); ignoring", (char *) log_prefix,
                           value, key);
        else if (key[4] == 'e')
            dcc_tls_cfg.enabled = b;
        else
            dcc_tls_cfg.require_crl = b;
    } else if (strcmp(key, "tls-ca") == 0) {
        dcc_tls_set(&dcc_tls_cfg.ca, value);
    } else if (strcmp(key, "tls-cert") == 0) {
        dcc_tls_set(&dcc_tls_cfg.cert, value);
    } else if (strcmp(key, "tls-key") == 0) {
        dcc_tls_set(&dcc_tls_cfg.key, value);
    } else if (strcmp(key, "tls-crl") == 0) {
        dcc_tls_set(&dcc_tls_cfg.crl, value);
    } else if (strcmp(key, "tls-whitelist") == 0) {
        dcc_tls_set(&dcc_tls_cfg.whitelist, value);
    } else if (strcmp(key, "tls-blacklist") == 0) {
        dcc_tls_set(&dcc_tls_cfg.blacklist, value);
    } else if (strcmp(key, "tls-port") == 0) {
        if (!dcc_config_parse_port(value, &dcc_tls_cfg.port))
            rs_log_warning("%s: invalid tls-port '%s'; ignoring",
                           (char *) log_prefix, value);
    } else if (strcmp(key, "tls-handshake-timeout") == 0) {
        if (!dcc_config_parse_int(value, 1, INT_MAX / 1000,
                                  &dcc_tls_cfg.handshake_timeout))
            rs_log_warning("%s: invalid tls-handshake-timeout '%s'; "
                           "keeping %d", (char *) log_prefix, value,
                           dcc_tls_cfg.handshake_timeout);
    } else {
        rs_log_warning("%s: unknown key '%s'; ignoring",
                       (char *) log_prefix, key);
    }
}


/**
 * Refuse a private key that group or others can access, as ssh does.
 **/
static int dcc_tls_check_key_mode(const char *key)
{
    struct stat st;

    if (stat(key, &st) != 0) {
        rs_log_error("cannot access TLS key %s: %s", key, strerror(errno));
        return EXIT_BAD_ARGUMENTS;
    }
    if (st.st_mode & 077) {
        rs_log_error("TLS key %s is accessible by group or others (mode "
                     "%#o); restrict it, e.g. with chmod 600", key,
                     (unsigned) (st.st_mode & 07777));
        return EXIT_BAD_ARGUMENTS;
    }
    return 0;
}


/**
 * Load the CA, certificate, key and optional CRL from dcc_tls_cfg; they
 * are used for every TLS connection of this process.
 **/
static int dcc_tls_load_credentials(void)
{
    const char *ca = dcc_tls_cfg.ca, *cert = dcc_tls_cfg.cert;
    const char *key = dcc_tls_cfg.key, *crl = dcc_tls_cfg.crl;
    int r, ret;

    if (!ca || !cert || !key) {
        rs_log_error("TLS needs a CA file, a certificate file and a key file");
        return EXIT_BAD_ARGUMENTS;
    }
    if (dcc_tls_cfg.require_crl && !crl) {
        rs_log_error("tls-require-crl is set but no CRL file is configured");
        return EXIT_BAD_ARGUMENTS;
    }
    if ((ret = dcc_tls_check_key_mode(key)))
        return ret;
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
    if (crl) {
        r = gnutls_certificate_set_x509_crl_file(dcc_tls_cred, crl,
                                                 GNUTLS_X509_FMT_PEM);
        if (r < 0) {
            rs_log_error("failed to load TLS CRL %s: %s", crl,
                         gnutls_strerror(r));
            return EXIT_BAD_ARGUMENTS;
        }
        rs_trace("loaded %d CRL(s) from %s", r, crl);
    }
    return 0;
}


/**
 * Read the tls-* keys of distccd.conf.  Returns true if the file sets
 * tls-enabled.
 **/
int dcc_tls_server_config_load(void)
{
    dcc_config_load(DCC_DAEMON_CONFIG_DEFAULT_PATH, "distccd config",
                    dcc_tls_apply_kv, (void *) "distccd config");
    return dcc_tls_cfg.enabled;
}


/**
 * The tls-port of distccd.conf, or 0 if it is not set.
 **/
int dcc_tls_config_port(void)
{
    return dcc_tls_cfg.port;
}


/**
 * Load the daemon's TLS credentials and identity list.  Non-NULL arguments
 * (command-line options) override distccd.conf.  Called before distccd
 * gives up root, so that a key file readable only by root can be used.
 **/
int dcc_tls_load_server_credentials(const char *ca, const char *cert,
                                    const char *key, const char *crl,
                                    const char *whitelist,
                                    const char *blacklist)
{
    const char *list;
    int ret;

    dcc_tls_set(&dcc_tls_cfg.ca, ca);
    dcc_tls_set(&dcc_tls_cfg.cert, cert);
    dcc_tls_set(&dcc_tls_cfg.key, key);
    dcc_tls_set(&dcc_tls_cfg.crl, crl);
    dcc_tls_set(&dcc_tls_cfg.whitelist, whitelist);
    dcc_tls_set(&dcc_tls_cfg.blacklist, blacklist);

    if (dcc_tls_cfg.whitelist && dcc_tls_cfg.blacklist) {
        rs_log_error("can't use both a TLS whitelist and a TLS blacklist");
        return EXIT_BAD_ARGUMENTS;
    }
    if ((ret = dcc_tls_load_credentials()))
        return ret;

    list = dcc_tls_cfg.whitelist ? dcc_tls_cfg.whitelist
                                 : dcc_tls_cfg.blacklist;
    if (list) {
        if ((ret = dcc_config_load_name_list(list, &dcc_tls_list,
                                             &dcc_tls_list_count)))
            return ret == EXIT_IO_ERROR ? EXIT_BAD_ARGUMENTS : ret;
        rs_log_info("using %s as TLS %slist (%d names)", list,
                    dcc_tls_cfg.whitelist ? "white" : "black",
                    dcc_tls_list_count);
    }
    return 0;
}


/**
 * Apply the TLS white- or blacklist to the client certificate's common
 * name.  Returns 0 if the client may proceed.
 **/
static int dcc_tls_check_identity(gnutls_session_t session)
{
    const gnutls_datum_t *peers;
    unsigned n_peers = 0;
    gnutls_x509_crt_t crt;
    char cn[256];
    size_t cn_size = sizeof cn;
    int listed, r;

    if (!dcc_tls_cfg.whitelist && !dcc_tls_cfg.blacklist)
        return 0;

    cn[0] = '\0';
    peers = gnutls_certificate_get_peers(session, &n_peers);
    if (n_peers > 0 && gnutls_x509_crt_init(&crt) == 0) {
        r = gnutls_x509_crt_import(crt, &peers[0], GNUTLS_X509_FMT_DER);
        if (r == 0)
            r = gnutls_x509_crt_get_dn_by_oid(crt, GNUTLS_OID_X520_COMMON_NAME,
                                              0, 0, cn, &cn_size);
        if (r != 0)
            cn[0] = '\0';
        gnutls_x509_crt_deinit(crt);
    }

    listed = cn[0] && dcc_config_name_listed(dcc_tls_list,
                                             dcc_tls_list_count, cn);
    if (dcc_tls_cfg.whitelist ? listed : (cn[0] && !listed)) {
        rs_log_info("TLS access granted - %s %s", cn,
                    dcc_tls_cfg.whitelist ? "whitelisted" : "not blacklisted");
        return 0;
    }
    rs_log_warning("TLS access denied - client \"%s\" %s", cn,
                   dcc_tls_cfg.whitelist ? "not whitelisted" : "blacklisted");
    gnutls_alert_send(session, GNUTLS_AL_FATAL, GNUTLS_A_ACCESS_DENIED);
    return EXIT_ACCESS_DENIED;
}


/**
 * Load the client's TLS credentials: distcc.conf first, then the
 * DISTCC_TLS_* environment variables.
 **/
static int dcc_tls_load_client_credentials(void)
{
    dcc_config_load(DCC_CLIENT_CONFIG_DEFAULT_PATH, "distcc config",
                    dcc_tls_apply_kv, (void *) "distcc config");
    dcc_tls_set(&dcc_tls_cfg.ca, getenv("DISTCC_TLS_CA"));
    dcc_tls_set(&dcc_tls_cfg.cert, getenv("DISTCC_TLS_CERT"));
    dcc_tls_set(&dcc_tls_cfg.key, getenv("DISTCC_TLS_KEY"));
    dcc_tls_set(&dcc_tls_cfg.crl, getenv("DISTCC_TLS_CRL"));
    return dcc_tls_load_credentials();
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


/**
 * Turn off Nagle's algorithm on a TLS connection.  The protocol writes each
 * token as its own small TLS record; with Nagle, every record after the
 * first waits for the peer's delayed ACK (up to 40 ms on Linux), which
 * measured as about 35 ms extra per job.  TCP_CORK, where the code sets
 * it, still batches the request.  Not a socket (a pipe in inetd mode): no
 * effect.
 **/
static void dcc_tls_set_nodelay(int fd)
{
    int one = 1;

    if (setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one) != 0)
        rs_trace("TCP_NODELAY not set on fd%d: %s", fd, strerror(errno));
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
 * certificate must be signed by the configured CA and name @p hostname.
 **/
int dcc_tls_connect(int to_net_fd, int from_net_fd, const char *hostname,
                    int port)
{
    gnutls_session_t session;
    int r, ret;

    gnutls_typed_vdata_st verify[2];

    if (!dcc_tls_cred && (ret = dcc_tls_load_client_credentials()))
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
    /* The server certificate must name the host and be meant for a TLS
     * server, so a client certificate of the same CA is not accepted. */
    verify[0].type = GNUTLS_DT_DNS_HOSTNAME;
    verify[0].data = (unsigned char *) hostname;
    verify[0].size = 0;
    verify[1].type = GNUTLS_DT_KEY_PURPOSE_OID;
    verify[1].data = (unsigned char *) GNUTLS_KP_TLS_WWW_SERVER;
    verify[1].size = 0;
    gnutls_session_set_verify_cert2(session, verify, 2, 0);
    gnutls_transport_set_int2(session, from_net_fd, to_net_fd);

    r = dcc_tls_handshake(session, from_net_fd, dcc_get_io_timeout());
    if (r == 0) {
        char *desc = gnutls_session_get_desc(session);
        rs_log_info("TLS to %s:%d: %s", hostname, port, desc);
        gnutls_free(desc);
        dcc_tls_set_nodelay(to_net_fd);
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
    gnutls_typed_vdata_st verify;
    int r, ret;

    if ((ret = dcc_tls_new_session(&session,
                                   GNUTLS_SERVER | GNUTLS_NO_TICKETS)))
        return ret;

    /* The client certificate must be meant for a TLS client, so a server
     * certificate of the same CA is not accepted. */
    verify.type = GNUTLS_DT_KEY_PURPOSE_OID;
    verify.data = (unsigned char *) GNUTLS_KP_TLS_WWW_CLIENT;
    verify.size = 0;
    gnutls_certificate_server_set_request(session, GNUTLS_CERT_REQUIRE);
    gnutls_session_set_verify_cert2(session, &verify, 1, 0);
    gnutls_handshake_set_timeout(session,
                                 dcc_tls_cfg.handshake_timeout * 1000);
    gnutls_transport_set_int2(session, in_fd, out_fd);

    r = dcc_tls_handshake(session, in_fd, dcc_tls_cfg.handshake_timeout);
    if (r == 0) {
        char *desc = gnutls_session_get_desc(session);
        rs_log_info("TLS: %s", desc);
        gnutls_free(desc);
        if ((ret = dcc_tls_check_identity(session))) {
            gnutls_deinit(session);
            return ret;
        }
        dcc_tls_set_nodelay(out_fd);
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
