# Unchecked second `readlinkat()` return value used as array index in `dcc_rewrite_generic_compiler()`

**Fork issue:** [wiki-mod/distcc-ng#13](https://github.com/wiki-mod/distcc-ng/issues/13)
**Fixed by:** [wiki-mod/distcc-ng#24](https://github.com/wiki-mod/distcc-ng/pull/24)
**Upstream location:** `src/compile.c`, function `dcc_rewrite_generic_compiler()`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-17)

## The problem

`dcc_rewrite_generic_compiler()` follows a chain of symlinks via two
separate `readlinkat()` calls. The first call (resolving the initial
compiler path) already checks the return value for a negative result before
using it. The second call — inside the loop that chases further symlink
hops via the `m` buffer — does not: its return value (`ssz`, an
`ssize_t`) is used directly as the index terminating the string with `'\0'`,
with no check that it is non-negative. If this second `readlinkat()` call
fails (`ssz == -1`), the code writes `linkbuf[-1] = '\0'` — one byte before
the start of the stack buffer.

## Upstream code (unchanged as of the commit above, upstream)

`src/compile.c`, `dcc_rewrite_generic_compiler()`:

```c
ssz = readlinkat(dir, t + 1, linkbuf, sizeof(linkbuf) - 1);
if (ssz < 0)
    return;
linkbuf[ssz] = '\0';
```

— this first call site (line ~501) is correctly guarded. Later in the same
function's symlink-chase loop:

```c
strcpy(m, linkbuf);

ssz = readlinkat(dir, m, linkbuf, sizeof(linkbuf) - 1);
linkbuf[ssz] = '\0';
```

— this second call site has no `if (ssz < 0)` check at all before
`linkbuf[ssz] = '\0'` runs.

## Fixed code (this fork, PR #24)

```c
strcpy(m, linkbuf);

ssz = readlinkat(dir, m, linkbuf, sizeof(linkbuf) - 1);
if (ssz < 0)
    return;
linkbuf[ssz] = '\0';
```

The second call site now returns immediately on a negative `readlinkat()`
result, matching the guard already present on the first call site in the
same function.

Landed via [wiki-mod/distcc-ng#24](https://github.com/wiki-mod/distcc-ng/pull/24).
