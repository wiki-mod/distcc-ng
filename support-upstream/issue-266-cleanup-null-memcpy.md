# NULL-source, zero-length `memcpy()` UB on the first call to `dcc_add_cleanup()`

**Fork issue:** none filed separately (found via #229's sanitizer verification work, tracked in #266)
**Fixed by:** [wiki-mod/distcc-ng#352](https://github.com/wiki-mod/distcc-ng/pull/352)
**Upstream location:** `src/cleanup.c`, function `dcc_add_cleanup()`
**Checked against upstream commit:** [`0c1febc1`](https://github.com/distcc/distcc/commit/0c1febc188ad6ac79cadf83789e835df602481e7) (`master`, checked 2026-07-28)
**Searched upstream issues/PRs for:** `cleanup memcpy`, `UBSan cleanup`, `maybe-uninitialized cleanup.c` — found nothing; this repo's own sanitizer sweep (#266) is, as far as could be found, the first time this line has been flagged anywhere.

## The problem

`dcc_add_cleanup()`'s array-growth path copies the existing `cleanups`
array into a freshly `malloc()`'d, larger buffer via `memcpy()`. On the
very first call in a process's lifetime, the global `cleanups` pointer is
still `NULL` and `cleanups_size` is still `0`, so this becomes
`memcpy(new_cleanups, NULL, 0)` — a zero-length copy from a `NULL`
source. This never actually dereferences anything and is harmless in
practice, but it is technically undefined behavior per the C standard:
libc declares `memcpy()`'s source parameter `nonnull`, and UBSan enforces
that regardless of the length argument. It fires on the first cleanup
registration in any real compile or daemon session -- simple early-exit
invocations like `--version`/`--help`/`--show-hosts` (`src/distcc.c`)
return before ever reaching `dcc_add_cleanup()`'s call sites in
`src/srvrpc.c`/`src/tempfile.c`, so those specific invocations never
trigger it.

## Upstream code (unchanged as of the commit above, upstream)

`src/cleanup.c`, `dcc_add_cleanup()`:

```c
        char **new_cleanups = malloc(new_cleanups_size * sizeof(char *));
        if (new_cleanups == NULL) {
            rs_log_crit("malloc failed - too many cleanups");
            return EXIT_OUT_OF_MEMORY;
        }
        memcpy(new_cleanups, (char **)cleanups, cleanups_size * sizeof(char *));
        old_cleanups = (char **)cleanups;
```

No guard against `cleanups_size == 0` before the `memcpy()`.

## Fixed code (this fork, PR #352)

```c
        char **new_cleanups = malloc(new_cleanups_size * sizeof(char *));
        if (new_cleanups == NULL) {
            rs_log_crit("malloc failed - too many cleanups");
            return EXIT_OUT_OF_MEMORY;
        }
        /* On the very first call, cleanups is still NULL and cleanups_size
         * is 0 -- skip the copy rather than passing a NULL source to
         * memcpy(), which is undefined behavior even at a zero length (libc
         * declares memcpy()'s source parameter nonnull). */
        if (cleanups_size > 0)
            memcpy(new_cleanups, (char **)cleanups, cleanups_size * sizeof(char *));
        old_cleanups = (char **)cleanups;
```

## Empirical verification

Confirmed in the mandatory `distcc-ng-buildtools` container: a
`-fsanitize=undefined` build of the unfixed code reports
`src/cleanup.c:146: runtime error: null pointer passed as argument 2,
which is declared to never be null` on every daemon-starting test case
(e.g. `NoDetachDaemon_Case`); after the fix, that report is gone, and a
plain (non-sanitizer) `make check` still passes in full.
