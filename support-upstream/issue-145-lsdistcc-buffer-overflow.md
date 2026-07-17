# Unbounded `sprintf`/`strcpy`/`strcat` into a fixed 256-byte stack buffer in `lsdistcc`'s `get_thename()`

**Fork issue:** [wiki-mod/distcc-ng#145](https://github.com/wiki-mod/distcc-ng/issues/145)
**Fixed by:** [wiki-mod/distcc-ng#146](https://github.com/wiki-mod/distcc-ng/pull/146)
**Upstream location:** `src/lsdistcc.c`, function `get_thename()` (called from `detect_distcc_servers()`, buffer declared there as `char thename[256]`)
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-17)
**Searched upstream issues/PRs for:** `get_thename`, `lsdistcc buffer`, `thename` — no matching report or fix attempt found, open or closed. (A separate, unrelated open report, [distcc/distcc#546](https://github.com/distcc/distcc/issues/546) "Buffer Overflow Detected on aarch64", crashes in `dcc_scan_args()` during normal compile argument scanning, not in `lsdistcc`'s `get_thename()` — checked and ruled out as the same bug.)

## The problem

`get_thename()` builds a hostname string into a caller-supplied buffer using
unbounded `sprintf()`, `strcpy()`, and two `strcat()` calls, with no
awareness of the destination buffer's actual size — the function doesn't
even take a size parameter. Its only caller, `detect_distcc_servers()`,
passes a fixed `char thename[256]` stack buffer. The format string
(`sformat[0]`/`sformat[i-1]`) and the domain name (`domain_name`, appended
when `opt_domain` is set) both come from `lsdistcc`'s own command-line
arguments/hosts configuration — a sufficiently long host-name-format string
or `--domain` value overflows the fixed 256-byte stack buffer. This is a
real stack-buffer overflow, though only locally triggered (via CLI
arguments/hosts file, not a network-facing attack surface).

Five sites in this fork's own code were originally flagged together by the
same CodeQL `cpp/unbounded-write` rule; independent verification against
upstream's current source confirms only this `lsdistcc.c` site is a genuine
live overflow there — the other four (`src/argutil.c`, two sites in
`src/compile.c`, `src/include_server_if.c`, `src/serve.c`) already had
correctly-sized buffers before their `strcpy`/`sprintf`→bounded-equivalent
swap in the fork, so they are CodeQL-hygiene hardening rather than a
distinct, still-live upstream bug and are intentionally not documented as
separate entries here.

## Upstream code (unchanged as of the commit above, upstream)

`src/lsdistcc.c`:

```c
void get_thename(const char**sformat, const char *domain_name, int i,
                char *thename)
{
    if (strstr(sformat[0], "%d") != NULL)
        sprintf(thename, sformat[0], i);
    else
        strcpy(thename, sformat[i-1]);
    if (opt_domain) {
        strcat(thename, ".");
        strcat(thename, domain_name);
    }
}
```

Called as (in `detect_distcc_servers()`, where `thename` is declared
`char thename[256]`):

```c
get_thename(sformat, domain_name, i, thename);
```

No length is ever passed into or checked by `get_thename()`.

## Fixed code (this fork, PR #146)

```c
void get_thename(const char**sformat, const char *domain_name,
                 int i, char *thename, size_t thename_size);
```

```c
/* thename_size is the maximum number of bytes that can be written to thename. */
void get_thename(const char**sformat, const char *domain_name, int i,
                char *thename, size_t thename_size)
{
    if (strstr(sformat[0], "%d") != NULL)
        snprintf(thename, thename_size, sformat[0], i);
    else
        strncpy(thename, sformat[i-1], thename_size - 1);
    if (opt_domain) {
        strncat(thename, ".", thename_size - strlen(thename) - 1);
        strncat(thename, domain_name, thename_size - strlen(thename) - 1);
    }
}
```

Called as:

```c
get_thename(sformat, domain_name, i, thename, sizeof(thename));
```

`get_thename()` now takes an explicit `thename_size` parameter and uses
`snprintf`/`strncat` bounded to it throughout, so a long format string or
domain name is truncated rather than overflowing the caller's stack buffer.

Landed via [wiki-mod/distcc-ng#146](https://github.com/wiki-mod/distcc-ng/pull/146).
