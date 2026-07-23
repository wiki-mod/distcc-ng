# 1-byte heap NUL overflow in `dcc_fresh_dependency_exists()` (`.d` TOCTOU)

**Fork issue:** [wiki-mod/distcc-ng#256](https://github.com/wiki-mod/distcc-ng/issues/256)
**Fixed by:** [wiki-mod/distcc-ng#257](https://github.com/wiki-mod/distcc-ng/pull/257)
**Upstream location:** `src/compile.c`, function `dcc_fresh_dependency_exists`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-19)
**Searched upstream issues/PRs for:** `dcc_fresh_dependency_exists`, `dotd_fname_size`, `heap overflow dotd`, `.d file overflow`, `toctou compile.c` — no matching report or fix attempt found, open or closed.

## The problem

`dcc_fresh_dependency_exists()` sizes a heap buffer from an earlier `stat()`
of the `.d` dependency file, then re-reads that same file through a separate
`fopen()`/`getc()` pass. The dependency-name copy loop bounds-checks every
content byte it writes against that `stat()`-time size, but the terminator
write after the loop does not re-check the index. If the `.d` file grows
between the `stat()` and the read (a real TOCTOU window: the `.d` file is
produced by the same locally-invoked preprocessor/compiler and is fully
writable by the invoking user during this window), a dependency token can
land exactly at the buffer's size, and the terminator write goes one byte
past the allocation — a 1-byte heap NUL overflow.

## Upstream code (unchanged as of the commit above, upstream)

```c
    dotd_fname_size = stat_dotd.st_size;
    /* Is dotd_fname_size representable as a size_t value ? */
    if ((off_t) (size_t) dotd_fname_size == dotd_fname_size) {
        dep_name = malloc((size_t) dotd_fname_size);
        if (!dep_name) {
            rs_log_error("failed to allocate space for dotd file");
            return EXIT_OUT_OF_MEMORY;
        }
    } else { /* This is exceedingly unlikely. */
        ...
    }
    ...
        while ((c = getc(fp)) != EOF &&
               (!isspace(c) || c == '\\')) {
            if (i >= dotd_fname_size) {
                /* Impossible */
                rs_log_error("not enough room for dependency name");
                goto return_0;
            }
            if (c == '\\') {
                ...
            }
            else dep_name[i++] = c;
        }
        if (i != 0) {
            dep_name[i] = '\0';
```

`malloc((size_t) dotd_fname_size)` allocates exactly `dotd_fname_size`
bytes (valid indices `0 .. dotd_fname_size - 1`). The copy loop's own bound
check (`i >= dotd_fname_size`) only guards the content-byte writes
(`dep_name[i++] = c`); it does not run again before the unconditional
`dep_name[i] = '\0'` that follows the loop. If a dependency token is exactly
`dotd_fname_size` characters long, the loop exits normally (the terminating
whitespace/EOF fails the `while` condition before the bound check is
reached again) with `i == dotd_fname_size`, and the terminator write is
out of bounds.

## Fixed code (changed code as of the commit from distcc-ng fork)

```c
        /* +1 reserves the NUL-terminator slot: the copy loop below bounds-
         * checks each byte it writes against dotd_fname_size (i >=
         * dotd_fname_size), but the terminator write after the loop
         * (dep_name[i] = '\0') does not re-check i. If the .d file grows
         * between this stat() and the read below, i can legitimately reach
         * dotd_fname_size, and without this extra byte the terminator
         * write lands one past the end of the allocation. */
        dep_name = malloc((size_t) dotd_fname_size + 1);
```

One extra byte makes every index the loop can produce (`0 .. dotd_fname_size`)
in-bounds for the terminator write, with no other behavioral change. The
stale `/* Impossible */` comment on the loop's own bound check was also
corrected — that branch is exactly what fires when the TOCTOU race is lost
on the other side (a token *longer* than `dotd_fname_size`), so it is not
actually impossible.

## Empirical verification

Client-only code path (`compile.o` is linked into `distcc` only, never
`distccd`) — real, deterministic reproduction using the existing
`src/h_compile.c` test harness (`h_compile dcc_fresh_dependency_exists
DOTD_FNAME EXCL_PAT REF_TIME`, which calls the actual, unmodified function),
built with AddressSanitizer (`CFLAGS="-fsanitize=address -g -O0"`) and
linked with `-Wl,--wrap=stat` against a small interposer that reports an
undersized `st_size` for one specific target path — deterministically
reproducing the exact consequence of the TOCTOU race (a `stat()`-time size
smaller than what the subsequent read actually returns) without depending
on winning a real timing race.

Target `.d` file (18 bytes on disk): `foo.o: AAAAAAAAAA\n` — a 10-character
dependency token. The interposer reports `st_size = 10` for this path
(matching the token length) while the real file is 18 bytes, i.e. the file
is legitimately larger than what `stat()` reported, exactly the TOCTOU
precondition.

- **Pre-fix tree** (`malloc(dotd_fname_size)`): ASan reports
  `heap-buffer-overflow ... WRITE of size 1` at the `dep_name[i] = '\0'`
  line, 1 byte after a 10-byte heap region allocated in
  `dcc_fresh_dependency_exists`.
- **Fixed tree** (`malloc(dotd_fname_size + 1)`): same input, same
  interposer; ASan reports no violation, `h_compile` exits cleanly with
  `result (NULL)` (the fabricated dependency name doesn't exist on disk, so
  the function correctly falls through to `return_0` after the
  out-of-bounds condition no longer occurs).

Also verified: a clean `-Werror` autoconf/automake build and the full
`make check` suite (including `DotD_Case` and `Compile_c_Case`, which
already exercise `dcc_fresh_dependency_exists()` through real compiles)
pass unchanged on both trees.

## Addendum (fork issue #268 / PR #271) — the TOCTOU pattern itself

The `malloc(+1)` fix above closes the memory-safety consequence, but
CodeQL alert #3 stayed **open** against this same function after #257
merged: the flagged pattern is the `stat(dotd_fname, &stat_dotd)` at
(then) `compile.c:282` followed by a separate `fopen(dotd_fname, "r")` a
few lines later — two syscalls that each independently resolve
`dotd_fname`, so the file the size/mtime check describes and the file
actually read can differ if something replaces or grows it in between.

**Checked against the same upstream commit** ([`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d)):
upstream's `dcc_fresh_dependency_exists()` still does `stat(dotd_fname,
&stat_dotd)` at line 282 followed by `fopen(dotd_fname, "r")` at line 305 —
the check-then-act pattern is live and unchanged upstream, same as the
overflow issue above.

**Fork fix**: reorder to `fopen()` first, then `fstat(fileno(fp),
&stat_dotd)` on the already-open descriptor instead of `stat()`-ing the
path beforehand. `fstat()` on an open fd is guaranteed to describe the
exact file subsequently read (same open file description/inode), so
there is no window in which `dotd_fname` could resolve to a different
file between the check and the read. This pattern is already idiomatic
in this codebase (`src/config-parser.c`'s `fstat(fileno(fp), &st)`).
This is a larger structural change than the one-line `+1` fix above (it
reorders every early-return path in the function to `fclose()` the
now-earlier-opened `fp`), so it is tracked and verified as its own
fork issue/PR rather than folded into this one after the fact.

Not proposed as an upstream contribution — this fork does not send
patches upstream (see `AGENTS.md`); recorded here only as the required
per-PR support-upstream cross-check.
