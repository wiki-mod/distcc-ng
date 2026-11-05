# Host list port outside 1 to 65535 is accepted and silently truncated

**Fork issue:** [wiki-mod/distcc-ng#248](https://github.com/wiki-mod/distcc-ng/issues/248)
**Fixed by:** commit `5c2a1c7` on branch `dev/issue248_tls-transport-audit`, not yet merged
**Upstream location:** `src/hosts.c`, function `dcc_parse_tcp_host`; `src/clinet.c`, function `dcc_connect_by_name`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-11-05)
**Searched upstream issues/PRs for:** `port 65535`, `invalid tcp port`, `DISTCC_HOSTS port range`, `htons port truncate` — no matching report or fix attempt found, open or closed; the three hits for `invalid tcp port` concern IPv6 addresses from zeroconf, not the port range.

## The problem

`dcc_parse_tcp_host()` reads the port of a `DISTCC_HOSTS` entry with
`strtol()` and checks only the character after the number. It never checks
the range, so `host:70000`, `host:0` and `host:-1` are accepted, and an
empty port (`host:,lzo`) becomes port 0. In a build without
`--enable-rfc2553`, `dcc_connect_by_name()` then passes the value through
`htons((in_port_t) port)`, which keeps only the low 16 bits: `host:70000`
connects to port 4464 without any warning.

## Upstream code (unchanged as of the commit above, upstream)

`src/hosts.c`:

```c
    hostdef->port = dcc_default_port;
    if (token[0] == ':') {
        char *tail;

        token++;

        hostdef->port = strtol(token, &tail, 10);
        if (*tail != '\0' && !isspace((uint8_t)*tail) && *tail != '/' && *tail != ',') {
            rs_log_error("invalid tcp port specification in \"%s\"", token);
            return EXIT_BAD_HOSTSPEC;
        } else {
            token = tail;
        }
    }
```

`src/clinet.c`:

```c
    sock_out.sin_port = htons((in_port_t) port);
```

## Fixed code (changed code as of the commit from distcc-ng fork)

`src/hosts.c` cuts the port out with the existing `dcc_dup_part()` and
validates it with `dcc_config_parse_port()`, the same helper the fork's
`tls-port` setting uses:

```c
    if (token[0] == ':') {
        char *port = NULL;
        int valid;

        token++;
        if ((ret = dcc_dup_part(&token, &port, "/ \t\n\r\f,")))
            return ret;
        valid = port && dcc_config_parse_port(port, &hostdef->port);
        if (!valid) {
            rs_log_error("invalid tcp port specification in \"%s\"",
                         token_start);
            free(port);
            return EXIT_BAD_HOSTSPEC;
        }
        free(port);
    }
```

`src/config-parser.c`:

```c
int dcc_config_parse_int(const char *value, int min, int max, int *out)
{
    char *end;
    long n;

    errno = 0;
    n = strtol(value, &end, 10);
    if (end == value || *end != '\0' || errno == ERANGE || n < min || n > max)
        return 0;
    *out = (int) n;
    return 1;
}

int dcc_config_parse_port(const char *value, int *out)
{
    return dcc_config_parse_int(value, 1, 65535, out);
}
```

## Empirical verification

Both trees built in `ghcr.io/wiki-mod/distcc-ng-buildtools` (Debian 13.6)
with the default configuration (no `--enable-rfc2553`). A listener on
`127.0.0.1:4464`, then `DISTCC_FALLBACK=0 DISTCC_HOSTS=127.0.0.1:70000
distcc gcc -c h.c`:

| Client | Result |
|---|---|
| unchanged code (`b5fb3d2`, same parser as upstream) | the listener on port 4464 receives the connection; the client then fails with `failed to write: Connection reset by peer` |
| fixed code (`5c2a1c7`) | `invalid tcp port specification in "127.0.0.1:70000"`, no connection |

`h_hosts` with the fixed code rejects `angry:0`, `angry:65536`,
`angry:70000`, `angry:`, `angry:,lzo`, `angry:3633abc`, `angry:-1`,
`angry::` and `[::1]:99999` (exit 106), and still accepts `angry:1`,
`angry:65535`, `angry:300/44`, `angry/44:300`, `angry:3000,lzo` and
`[::1]:4200` with the same ports as before. `make check` passes unchanged
(187 OK, 27 not run, 0 failed), with and without GnuTLS.
