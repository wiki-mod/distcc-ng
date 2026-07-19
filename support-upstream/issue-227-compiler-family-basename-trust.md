# Compiler family (gcc vs clang) trusted from `argv[0]` basename only in three functions — one has its own admitting TODO

**Fork issue:** [wiki-mod/distcc-ng#227](https://github.com/wiki-mod/distcc-ng/issues/227)
**Fixed by:** [wiki-mod/distcc-ng#245](https://github.com/wiki-mod/distcc-ng/pull/245)
**Upstream location:** `src/compile.c`, functions `dcc_rewrite_generic_compiler()`, `dcc_add_clang_target()`, `dcc_gcc_rewrite_fqn()`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-18)
**Searched upstream issues/PRs for:** `dcc_rewrite_generic_compiler`, `dcc_add_clang_target`, `dcc_gcc_rewrite_fqn`, `"use cc -v"`, `autoheader clang`, `symlink cc` — no report or fix attempt found for the non-symlink gap or the basename-trust pattern in these three functions. The closest related-but-distinct issue is [distcc/distcc#491](https://github.com/distcc/distcc/issues/491) ("Support cross compilation when compiler given as path"), which complains that `argv[0]` matching fails entirely for a full path (no match at all) rather than flagging that a *wrong* match can happen — a different failure mode, not a duplicate of this one.

## The problem

Three functions in `src/compile.c` decide whether a compiler invocation is
gcc or clang purely by string-matching `argv[0]`, with no verification
that the name matches what the binary actually is:

1. `dcc_rewrite_generic_compiler()` rewrites a bare `"cc"`/`"c++"`
   invocation to the real underlying compiler name. It correctly resolves
   the case where the resolved `cc`/`c++` path is a **symlink** (chases it
   via `readlinkat()`). When it is **not** a symlink — e.g. macOS's `cc`,
   a small dispatch binary rather than a symlink — the function has an
   explicit, still-unaddressed `TODO` and just gives up, leaving
   `argv[0]` unchanged as `"cc"`/`"c++"`.
2. `dcc_add_clang_target()` — which only fires when `argv[0]` already
   says `"clang"`/`"clang++"` — carries its **own** admitting `TODO`
   acknowledging the same class of problem in its own docstring, still
   unaddressed.
3. `dcc_gcc_rewrite_fqn()` matches `argv[0]` against `"gcc"`/`"g++"`
   prefixes with no probing at all, the mirror-image gap.

The practical failure mode this fork's issue #227 documented: on a
dispatcher-style `cc` (case 1), `dcc_rewrite_generic_compiler()` silently
no-ops, so `argv[0]` stays `"cc"` and neither `dcc_add_clang_target()` nor
`dcc_gcc_rewrite_fqn()` ever fires (both require an already-correct
`argv[0]` to match) — the compiler proceeds as literally `"cc"`, without
gaining the clang cross-compilation `-target` flag it would need, or the
gcc fully-qualified-name rewrite it would need, depending on what `cc`
actually is.

## Upstream code (unchanged as of the commit above, upstream)

`src/compile.c`, `dcc_rewrite_generic_compiler()` (~line 498, inside the
`#ifdef HAVE_FSTATAT` guard):

```c
    ret = fstatat(dir, t + 1, &st, AT_SYMLINK_NOFOLLOW);
    if (ret < 0)
        return;
    if ((st.st_mode & S_IFMT) != S_IFLNK)
        /* TODO use cc -v */
        return;
```

`src/compile.c`, `dcc_add_clang_target()`'s own docstring (~line 546),
naming exactly this gap in its own words:

```c
/* Clang is a native cross-compiler, but needs to be told to what target it is
 * building.
 * TODO: actually probe clang with clang --version, instead of trusting
 * autoheader.
 */
static void dcc_add_clang_target(char **argv)
{
    if (strcmp(argv[0], "clang") == 0 || strncmp(argv[0], "clang-", strlen("clang-")) == 0 ||
        strcmp(argv[0], "clang++") == 0 || strncmp(argv[0], "clang++-", strlen("clang++-")) == 0)
        ;
    else
        return;
```

`src/compile.c`, `dcc_gcc_rewrite_fqn()` (~line 577), the same pattern
with no acknowledging comment:

```c
static int dcc_gcc_rewrite_fqn(char **argv)
{
    if (strcmp(argv[0], "gcc") == 0 || strncmp(argv[0], "gcc-", strlen("gcc-")) == 0 ||
        strcmp(argv[0], "g++") == 0 || strncmp(argv[0], "g++-", strlen("g++-")) == 0)
        ;
    else
        return -ENOENT;
```

## Fixed code (this fork, PR #245)

Only `dcc_rewrite_generic_compiler()`'s non-symlink branch needed a real
fix: `dcc_add_clang_target()`/`dcc_gcc_rewrite_fqn()` already run *after*
it in `dcc_build_somewhere()`'s call sequence, so correcting `argv[0]`
here is sufficient to fix all three call sites without changing the other
two functions' own bodies. A new static helper does exactly what
`dcc_add_clang_target()`'s own TODO already asked for — probe with
`--version` instead of trusting a name:

```c
/* Probe @p path -- a resolved, executable compiler binary that is not
 * itself a symlink, so readlinkat() can't tell us anything about it --
 * by running "<path> --version" and checking whether it self-identifies
 * as clang. Both gcc and clang always print their own family name in the
 * first line of "--version" output ("gcc (...) X.Y.Z" vs. "... clang
 * version X.Y.Z", verified against real gcc/clang output). */
static int dcc_probe_is_clang(const char *path)
{
    ...
    execl(path, path, "--version", (char *) NULL);
    ...
    if (fgets(buff, sizeof(buff), in) != NULL)
        is_clang = (strstr(buff, "clang") != NULL) ? 1 : 0;
    ...
}
```

```c
    if ((st.st_mode & S_IFMT) != S_IFLNK) {
        int probed_is_clang = dcc_probe_is_clang(link);

        if (probed_is_clang < 0)
            return;
        free(argv[0]);
        argv[0] = strdup(probed_is_clang ? (cpp ? "clang++" : "clang")
                                          : (cpp ? "g++" : "gcc"));
        rs_trace("Rewriting '%s' to '%s'", cpp ? "c++" : "cc", argv[0]);
        return;
    }
```

Separately (not part of this entry's upstream location, but the same
fork issue/PR): `dcc_resolve_march_native()` in `src/arg.c` had the same
basename-trust bug for its own `is_clang` — see
[issue-073-march-native-resolve.md](issue-073-march-native-resolve.md)'s
"Two more bugs found in the same draft" section, since that function's
upstream equivalent only exists in upstream's still-unmerged draft PR
#384, not in `master`.

Landed via [wiki-mod/distcc-ng#245](https://github.com/wiki-mod/distcc-ng/pull/245).

## Empirical verification

Real tests against actual gcc/clang binaries (not just a diff read),
using non-symlink shell-script dispatchers specifically because a
symlink test would false-green against the pre-existing, already-working
symlink branch:

- A `#!/bin/sh; exec clang "$@"` script named `cc` (not a symlink) on
  `PATH`: `distcc cc -c test.c -o test.o` trace shows
  `(dcc_rewrite_generic_compiler) Rewriting 'cc' to 'clang'` followed by
  `(dcc_add_clang_target) Adding '-target x86_64-linux-gnu' ...` — the
  downstream function now correctly fires because `argv[0]` was already
  corrected. Before the fix, this dispatcher produced no rewrite at all
  and no `-target` flag.
- Same technique wrapping `gcc` instead: trace shows
  `Rewriting 'cc' to 'gcc'`, compiled successfully as the fully-resolved
  name.
- Full `make check` run against the fix, compared line-by-line against
  an identical run on unmodified `current_dev` in a separate worktree:
  identical two pre-existing failures in both
  (`ModeBits_Case`/`maintainer-check-no-set-path`, a WSL/DrvFs `/mnt/c`
  mount permission-bit artifact, confirmed unrelated to this change by
  reproducing on the unmodified baseline).
