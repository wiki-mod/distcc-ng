# Spurious "getline failed" warning on plain EOF in `dcc_check_unsupported_directives()`

**Fork issue:** none filed separately (surfaced live while investigating #263)
**Fixed by:** [wiki-mod/distcc-ng#348](https://github.com/wiki-mod/distcc-ng/pull/348)
**Upstream location:** `src/remote.c`, function `dcc_check_unsupported_directives()`
**Checked against upstream commit:** [`2deab40d`](https://github.com/distcc/distcc/commit/2deab40d07fe53af876709bbef0a105fe559818e) (`master`, checked 2026-07-28)
**Searched upstream issues/PRs for:** `getline errno`, `getline failed`, `incbin warning` — found only [distcc/distcc#461](https://github.com/distcc/distcc/pull/461), the very PR that introduced this function; no follow-up issue or PR addresses this.

## The problem

`getline()` returns `-1` both on a genuine stream read error and on plain,
successful end-of-file — the two cases are only distinguishable via
`ferror()`, not via `errno`, since POSIX makes no promise that `errno` is
left at `0` after a clean EOF (only that it is meaningful *on failure*).
Upstream's check uses `errno != 0` alone, with no reset beforehand, so a
stale `errno` value left over from an unrelated earlier syscall in the
same process (this client also does non-blocking network I/O, where
`EAGAIN` is a normal, expected outcome) can be misattributed to this local
file read — producing a misleading "getline failed" warning for what was
actually a normal, successful read to EOF.

This is exactly the kind of thing that looks intentional until checked:
the original patch (distcc/distcc#461) had an `errno = 0;` reset before
the loop, and a reviewer asked for it to be removed as a stylistic
preference only ("I feel like assigning to errno is considered bad a bad
idea... OK" / "It's not necessary, will remove it") — no technical
justification was given, and the removal reintroduced exactly the false
positive this writeup describes.

## Upstream code (unchanged as of the commit above, upstream)

`src/remote.c`, `dcc_check_unsupported_directives()`:

```c
    while ((bytes_read = getline(&line, &len, cpp_f)) != -1) {
        if (strstr(line, ".incbin \\\"") || strstr(line, ".incbin \"")) {
	    rs_log_info("Found unsupported .incbin directive, compiling locally.");
	    ret = 1;
	    goto out;
	}
    }

    if (bytes_read < 0 && errno != 0)
        rs_log_warning("%s: getline failed: %s (%d), file %s", __func__, strerror(errno), errno, cpp_fname);
```

No `errno = 0;` reset before the loop, and no `ferror(cpp_f)` check.

## Fixed code (this fork, PR #348)

```c
    /* Reset before the loop so a stale value left over from an unrelated
     * earlier syscall in this same process (e.g. EAGAIN from this client's
     * own non-blocking network I/O) can't be misread below as this read
     * having failed. */
    errno = 0;
    while ((bytes_read = getline(&line, &len, cpp_f)) != -1) {
        if (strstr(line, ".incbin \\\"") || strstr(line, ".incbin \"")) {
	    rs_log_info("Found unsupported .incbin directive, compiling locally.");
	    ret = 1;
	    goto out;
	}
    }

    if (bytes_read < 0 && (ferror(cpp_f) || errno != 0))
        rs_log_warning("%s: getline failed: %s (%d), file %s", __func__, strerror(errno), errno, cpp_fname);
```

`ferror(cpp_f)` reflects only this specific `FILE` stream's own error
state, so it can never be polluted by anything else happening in the
process. It alone is not sufficient, though: this fork's `util.c` compat
`getline()` (used on systems lacking their own, `#ifndef HAVE_GETLINE`)
can fail via `realloc()` without ever touching the `FILE` stream, so a
`ferror()`-only check can't tell that failure apart from plain EOF either.
The reset-then-check-both form (plus `util.c`'s compat `getline()` now
setting `errno = ENOMEM` explicitly on its allocation-failure path,
instead of relying only on `realloc()`'s own side effect) covers both
implementations.

## Empirical verification

Confirmed live with `strace`/direct testing that upstream's `errno != 0`
check does misfire: a prior unrelated `EAGAIN` in the same process
persists across the clean-EOF `getline()` loop and gets misreported as a
`getline failed` warning.

Separately verified — since this fork's own fix reintroduces an `errno`
check alongside `ferror()` — that doing so does *not* reintroduce the same
class of false positive: on a large (5MB, ~68k-line) real file read via
`fopen()` with glibc's own `getline()` (forcing many internal `read()`
buffer refills, not just one), `errno` stayed `0` across the clean EOF in
every trial, including with unrelated libc calls (`fstat()`) interleaved
mid-loop. A genuine read error (sabotaging the underlying fd mid-stream,
past the stdio buffer) was correctly caught by both `ferror()` and
`errno`.
