# dcc_mkdir() lacks parent-directory (mkdir -p) creation

**Fork issue:** [wiki-mod/distcc-ng#179](https://github.com/wiki-mod/distcc-ng/issues/179)
**Fixed by:** [wiki-mod/distcc-ng#180](https://github.com/wiki-mod/distcc-ng/pull/180)
**Upstream location:** `src/tempfile.c`, function `dcc_mkdir`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-17)
**Searched upstream issues/PRs for:** `dcc_mkdir`, `mkdir -p`, `ENOENT`, `parent directory`, `.distcc directory`, `HOME` — no matching report or fix attempt found, open or closed.

## The problem

`dcc_mkdir()` does a single, non-recursive `mkdir()` call. Its two callers,
`dcc_get_top_dir()` and `dcc_get_subdir()`, build paths like
`$HOME/.distcc` (or a subdirectory under `DISTCC_DIR`) and pass them
straight to `dcc_mkdir()`. If `$HOME` itself (or whatever parent directory
`DISTCC_DIR` resolves under) doesn't already exist — a minimal container, a
sandboxed/jailed build worker with no pre-populated home directory, etc. —
the plain `mkdir()` call fails with `ENOENT` instead of creating the
missing parent(s) first, and the whole distributed-compile setup aborts
with an error like:

```
distcc[2] (dcc_mkdir) ERROR: mkdir '/root/.distcc' failed: No such file or directory
distcc[2] (dcc_build_somewhere) ERROR: failed to distribute and fallbacks are disabled
```

This fork hit this for real during an overnight cross-project evaluation
of distcc-ng against `wiki-mod/lancache-ng`'s sccache+distcc-dist build
pipeline (a sandboxed build worker running inside a bubblewrap jail with no
pre-existing `/root`) — see
[wiki-mod/lancache-ng#919](https://github.com/wiki-mod/lancache-ng/issues/919)
for the original real-world trigger.

## Upstream code (unchanged as of the commit above, upstream)

```c
/**
 * Create the directory @p path.  If it already exists as a directory
 * we succeed.
 **/
int dcc_mkdir(const char *path)
{
    if ((mkdir(path, 0777) == -1) && (errno != EEXIST)) {
        rs_log_error("mkdir '%s' failed: %s", path, strerror(errno));
        return EXIT_IO_ERROR;
    }

    return 0;
}
```

No parent-directory handling at all — a bare `mkdir()`, tolerating only
`EEXIST`. Upstream's own `dcc_get_top_dir()`/`dcc_get_subdir()` (same file,
building the exact same `$HOME/.distcc`-style paths) call this function
directly, so the same `ENOENT` failure mode is live in upstream's current
source under the same conditions (missing `$HOME` or `DISTCC_DIR` parent).

## Fixed code (changed code as of the commit from distcc-ng fork)

```c
/**
 * Create the directory @p path, including any missing parent
 * directories (like `mkdir -p`).  If it already exists as a directory
 * we succeed.
 *
 * Callers (dcc_get_top_dir(), dcc_get_subdir()) build paths like
 * $HOME/.distcc -- $HOME itself is not guaranteed to already exist in
 * every environment this runs in (minimal containers, sandboxed build
 * workers), so a plain non-recursive mkdir() can fail with ENOENT even
 * though creating the directory is otherwise perfectly reasonable.
 **/
int dcc_mkdir(const char *path)
{
    int ret;

    if ((ret = dcc_mk_tmp_ancestor_dirs(path))) {
        return ret;
    }

    if ((mkdir(path, 0777) == -1) && (errno != EEXIST)) {
        rs_log_error("mkdir '%s' failed: %s", path, strerror(errno));
        return EXIT_IO_ERROR;
    }

    return 0;
}
```

The fix reuses `dcc_mk_tmp_ancestor_dirs()` — an existing helper already
used elsewhere in this same file for temp/input file paths — to create any
missing ancestor directories before the final `mkdir()`, giving
`dcc_mkdir()` real `mkdir -p` semantics. No new helper function, no new
dependency; the fix is purely reusing infrastructure this codebase (and
upstream's own copy of it, at `dcc_mk_tmp_ancestor_dirs` in the same file)
already has.

Landed via [wiki-mod/distcc-ng#180](https://github.com/wiki-mod/distcc-ng/pull/180).

## Empirical verification

- Real build (`./autogen.sh && ./configure PYTHON=python3 && make`) under
  WSL Debian, native filesystem — clean, `-Werror`, no warnings.
- `make check` — full suite passes (the one unrelated `ModeBits_Case`
  failure mode only reproduces on WSL's `/mnt/c` DrvFs mount, not present
  on native filesystem here).
- **Real functional reproduction of the exact bug and fix**: ran the built
  `distcc` with `HOME` pointed at a path whose entire parent chain didn't
  exist (`/tmp/fakehome/deep/nested/root`) — confirmed the pre-fix binary
  fails with the same `ENOENT` error quoted above, and the fixed binary
  successfully creates `.distcc` end-to-end, reproducing and resolving the
  real failure originally observed via lancache-ng#919.

Full details also in PR #180's own description on
[wiki-mod/distcc-ng#179](https://github.com/wiki-mod/distcc-ng/issues/179).
