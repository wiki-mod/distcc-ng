# `lsdistcc`'s `get_thename()` treats "contains %d" as safe to use as a printf format string

**Fork issue:** [wiki-mod/distcc-ng#226](https://github.com/wiki-mod/distcc-ng/issues/226)
**Fixed by:** [wiki-mod/distcc-ng#242](https://github.com/wiki-mod/distcc-ng/pull/242)
**Upstream location:** `src/lsdistcc.c`, function `get_thename()`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-18)
**Searched upstream issues/PRs for:** `lsdistcc`, `format string` — found [distcc/distcc#148](https://github.com/distcc/distcc/issues/148) ("lsdistcc segfaults when called with more than 502 hosts"), but that is a different bug (a `MAXHOSTS`-sized array overflow triggered by passing a *plain host list* of more than ~502 names, not the `%d`-format code path at all) — checked and ruled out as the same issue, same as `issue-145-lsdistcc-buffer-overflow.md`'s own precedent for this file.

## The problem

`get_thename()` accepts a caller-supplied format string (`sformat[0]`,
which traces back to an `lsdistcc` command-line argument or a hosts-file
entry) and only checks that it *contains* `"%d"` somewhere before handing
it directly to a `printf`-family function as the *format* argument:

```c
if (strstr(sformat[0], "%d") != NULL)
    sprintf(thename, sformat[0], i);
```

`strstr(..., "%d")` is satisfied by any string that has `%d` anywhere in
it — including `"%d%s%s%s%n"`, which also contains `%d`. Once that string
reaches `sprintf()`/`snprintf()` as the format argument, the extra `%s`
and `%n` conversions are processed too, even though the call site only
ever supplies a single `int` argument (`i`). `%s` reads an argument that
was never passed (typically garbage from the stack/registers) and
dereferences it as a `char *`; `%n` writes the number of bytes emitted so
far to a pointer argument that was likewise never supplied. Both are
out-of-bounds memory accesses driven entirely by attacker-controlled
input, not a formatting inconvenience.

This is a distinct bug from the one already documented in
`issue-145-lsdistcc-buffer-overflow.md` (that entry covers the *missing
destination-buffer bound* — `sprintf`/`strcpy`/`strcat` writing past a
fixed 256-byte stack buffer with no size awareness at all). This entry is
about the *format string itself* being attacker-controlled with an
insufficient safety check, independent of whether the destination buffer
is correctly bounded — upstream's version is vulnerable to both at once
(no bound *and* no format validation); this fork had already fixed the
missing-bound half (via #146) before this PR, but still had the
format-validation gap fixed here.

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

No validation beyond `strstr(..., "%d") != NULL` is ever performed on the
format string before it is used as one.

## Fixed code (this fork, PR #242)

```c
static int dcc_thename_format_is_safe(const char *fmt)
{
    int seen_conversion = 0;
    const char *p = fmt;

    while (*p != '\0') {
        if (*p != '%') {
            p++;
            continue;
        }
        if (seen_conversion)
            return 0;            /* a second '%' of any kind -> unsafe */
        p++;                     /* past '%' */
        while (*p == '-' || *p == '+' || *p == ' ' || *p == '0' || *p == '#')
            p++;                 /* flags */
        while (isdigit((unsigned char) *p))
            p++;                 /* width (a literal digit only) */
        if (*p == '.') {
            p++;
            while (isdigit((unsigned char) *p))
                p++;             /* precision, same reasoning as width */
        }
        if (*p != 'd')
            return 0;            /* not a plain int conversion -> unsafe */
        seen_conversion = 1;
        p++;                     /* past 'd' */
    }
    return seen_conversion;
}

void get_thename(const char**sformat, const char *domain_name, int i,
                char *thename, size_t thename_size)
{
    if (strstr(sformat[0], "%d") != NULL) {
        if (!dcc_thename_format_is_safe(sformat[0])) {
            fprintf(stderr, "lsdistcc: host-name format '%s' must contain "
                    "exactly one '%%d' conversion and no other '%%' "
                    "specifier\n", sformat[0]);
            exit(1);
        }
        snprintf(thename, thename_size, sformat[0], i);
    } else
        strncpy(thename, sformat[i-1], thename_size - 1);
    ...
}
```

A format string is now only used if it contains exactly one integer
conversion (`%d`, optionally with flags/width/precision like `%02d` —
still allowing realistic zero-padded host formats such as `distcc%02d`)
and no other `%` conversion specifier at all — an unsafe format is
refused outright with a clear error rather than partially trusted. (The
`thename_size`/`snprintf` bound itself is the pre-existing fix from
`issue-145-lsdistcc-buffer-overflow.md` / PR #146, not new in this PR —
shown here only for completeness of the current call site.)

## Empirical verification

Built an AddressSanitizer-instrumented binary of the *pre-this-fix*
`get_thename()` (i.e. the `strstr`-only guard, matching upstream's
current logic modulo the already-fixed buffer bound) and ran it with a
crafted format argument:

```
$ ./lsdistcc "%d%s%s%s%n" -t1 -h1
==77119==ERROR: AddressSanitizer: SEGV on unknown address 0x000000044401
    ...
    #4 0x... in get_thename src/lsdistcc.c:888
    #5 0x... in detect_distcc_servers src/lsdistcc.c:984
    #6 0x... in main src/lsdistcc.c:1101
SUMMARY: AddressSanitizer: SEGV ... in __sanitizer::internal_strlen
```

The crash is a real SEGV inside the vulnerable `snprintf()` call itself,
reading an unsupplied `%s` argument as a garbage pointer — confirming
this is a genuine, exploitable memory-safety bug, not a theoretical
concern. The post-fix binary rejects the same input cleanly with a
nonzero exit and no crash, while still accepting the default format
(`distcc%d`) and a realistic zero-padded format (`distcc%02d`) without
regression. Landed via
[wiki-mod/distcc-ng#242](https://github.com/wiki-mod/distcc-ng/pull/242).
