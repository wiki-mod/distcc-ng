# Unbounded allocation size from wire-protocol input in `dcc_r_str_alloc()`/`dcc_r_argv()`/bulk receivers

**Fork issue:** [wiki-mod/distcc-ng#224](https://github.com/wiki-mod/distcc-ng/issues/224)
**Fixed by:** [wiki-mod/distcc-ng#230](https://github.com/wiki-mod/distcc-ng/pull/230)
**Upstream location:** `src/rpc.c`, functions `dcc_r_str_alloc()` and `dcc_r_argv()`; `src/compress.c`, function `dcc_r_bulk_lzo1x()`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-18)
**Searched upstream issues/PRs for:** `malloc`, `calloc`, `unbounded`, `DoS`, `out of memory` -- no existing report or fix found for this specific pattern.

## The problem

`dcc_r_str_alloc()` allocates `l + 1` bytes, where `l` is a length read directly off the wire (`dcc_r_token_int`) with no upper-bound check. This function backs every string the daemon or client reads from its peer: every `argv[i]` entry (via `dcc_r_token_string()` → `dcc_r_argv()`), every filename and symlink target in `dcc_r_many_files()`. `dcc_r_argv()`'s own `argc` (also read straight off the wire) is likewise unbounded before driving a `calloc()` and a loop of (also-unbounded) string reads. `dcc_r_bulk_lzo1x()` (in `compress.c`) has the identical missing bound on its `in_len` parameter before `malloc(in_len)`.

A corrupted or hostile peer can therefore claim an arbitrary length or argument count and force an oversized allocation attempt. Depending on the exact value and the receiving host's memory/overcommit configuration, this can manifest as an immediate clean allocation failure (best case, already handled), a successful-but-enormous allocation that exhausts real memory, or -- for a value chosen just large enough to succeed but far larger than any real argument list -- a worker process that blocks indefinitely holding that memory and a connection slot while waiting to read arguments that will never arrive, since the peer only needs to send the oversized count and then stop.

## Upstream code (unchanged as of the commit above, upstream)

```c
int dcc_r_str_alloc(int fd, unsigned l, char **buf)
{
     char *s;

#if 0
     /* never true  */
     if (l < 0) {
         rs_log_crit("oops, l < 0");
         return EXIT_PROTOCOL_ERROR;
     }
#endif

/*      rs_trace("read %d byte string", l); */

     s = *buf = malloc((size_t) l + 1);
     if (!s)
          rs_log_error("malloc failed");
     if (dcc_readx(fd, s, (size_t) l))
          return EXIT_OUT_OF_MEMORY;

     s[l] = 0;

     return 0;
}
```

Note the pre-existing, separate bug in the same function: if `malloc()` returns `NULL`, the code logs an error but does **not** return -- it falls through to `dcc_readx(fd, s, ...)` with `s == NULL`, a guaranteed NULL-pointer dereference on an allocation failure that a bound would otherwise make more likely to actually occur (a huge-but-not-overflowing request is more likely to fail than a small one).

`dcc_r_argv()`'s `argc` read has the same missing bound (`if (dcc_r_token_int(ifd, argc_token, &argc)) return EXIT_PROTOCOL_ERROR;` with no subsequent range check before `calloc((size_t) argc+1, sizeof a[0])`), and `dcc_r_bulk_lzo1x()`'s `in_len` parameter is used directly in `malloc(in_len)` with the same absence of a check.

## Fixed code (changed code as of the commit from distcc-ng fork)

Three new sanity-ceiling constants added to `src/distcc.h` (`DCC_MAX_RPC_STRING_LEN` = 16 MiB, `DCC_MAX_RPC_ARGC` = 65536, `DCC_MAX_BULK_FILE_LEN` = 1 GiB -- deliberately generous, well above any realistic single argv entry, argument count, or file size), checked before each of the three allocation sites, rejecting with a logged `EXIT_PROTOCOL_ERROR` instead of attempting the allocation. `dcc_r_str_alloc()`'s malloc-failure-not-checked bug was also fixed in the same change (now returns `EXIT_OUT_OF_MEMORY` immediately rather than falling through). See PR #230's diff for the exact fork-side patch (also touches `src/compress-zstd.c`, a distcc-ng-only file with the same pattern, not present upstream).

## Empirical verification

Real before/after test: two `distccd` binaries were built from the same source tree, one with the fix and one without (upstream-equivalent code restored for `rpc.c`/`compress.c`-equivalent files), both started locally. A hand-crafted client spoke the wire protocol directly (`DIST` version token, then a forged `ARGC` token) to each:

- Unpatched, `ARGC=0xFFFFFFFF`: `calloc()` itself failed in this test environment (not guaranteed on a host with more memory/overcommit headroom), logged as `alloc failed` -- the existing checked-`calloc` path happened to catch it here, but this is environment-dependent luck, not a guarantee.
- Unpatched, `ARGC=100000000` (100 million, ~800MB of pointer storage): the allocation **succeeded**, and the worker then blocked for the full duration the client stayed connected (3+ seconds in the test, unbounded for a real attacker that doesn't disconnect), holding the allocation and a connection slot, before finally erroring out once the client closed the socket (`dcc_readx: unexpected eof`).
- Patched, both values: rejected immediately (`time:0ms` in the daemon's own job-summary log) with a clear `argument count N from peer exceeds sanity limit 65536, rejecting` message, no allocation attempted.

`make check`'s full real test suite (including `BigAssFile_Case`, a real large-file distributed-compile test, and `CompressedCompile_Case`) passed with zero regressions on the patched build, confirming the new ceilings don't affect any legitimate request.
