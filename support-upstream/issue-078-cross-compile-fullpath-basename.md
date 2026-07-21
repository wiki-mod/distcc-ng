# `dcc_add_clang_target()`/`dcc_gcc_rewrite_fqn()` match `argv[0]` literally, so cross-compile auto-rewrite never fires when the compiler is invoked by full path

**Fork issue:** [wiki-mod/distcc-ng#78](https://github.com/wiki-mod/distcc-ng/issues/78)
**Fixed by:** [wiki-mod/distcc-ng#281](https://github.com/wiki-mod/distcc-ng/pull/281)
**Upstream location:** `src/compile.c`, functions `dcc_add_clang_target()` (~line 550) and `dcc_gcc_rewrite_fqn()` (~line 582)
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-21)
**Upstream already has an open, unmerged fix:** [distcc/distcc#491](https://github.com/distcc/distcc/pull/491) ("Support cross compilation when compiler given as path"), open and unmerged as of 2026-07-21 (confirmed via `gh api repos/distcc/distcc/pulls/491 --repo wiki-mod/distcc-ng`, per AGENTS.md rule 18's blanket requirement to pass `--repo` on every `gh` command: `state: open`, `merged: false`). This entry independently re-verifies that PR's diff is correct against this fork's current source before adopting it, per this fork's "never adopt unverified" policy, rather than porting it blind.
**Searched upstream issues/PRs for:** `dcc_add_clang_target`, `dcc_gcc_rewrite_fqn`, `dcc_find_basename`, `"cross compilation when compiler given as path"` — the only relevant result is #491 above, no other open report or fix attempt for this specific pair of functions. This is a distinct bug from this fork's own issue #227 (`issue-227-compiler-family-basename-trust.md`): #227 is about a *wrong* family match (a name that resolves but lies about what it is); this one is about *no* match at all (a name that would resolve correctly but is never even tried) once a full path is involved.

## The problem

Both functions decide whether to apply cross-compilation special-casing
by comparing `argv[0]` **directly**, with no basename extraction:

- `dcc_add_clang_target()` checks `strcmp(argv[0], "clang") == 0` etc. to
  decide whether to append `-target <NATIVE_COMPILER_TRIPLE>`.
- `dcc_gcc_rewrite_fqn()` checks `strcmp(argv[0], "gcc") == 0` etc. to
  decide whether to rewrite the invocation to
  `<NATIVE_COMPILER_TRIPLE>-gcc` (searched on `$PATH`).

If the user (or a build system, e.g. CMake's `CMAKE_C_COMPILER` absolute-path
convention) invokes the compiler by an absolute or relative path —
`/usr/bin/gcc`, `/usr/bin/clang-19`, `./gcc-11` — neither `strcmp` nor
`strncmp` against the bare family name can ever match, since the compared
string still contains the leading path. Both functions silently no-op:
no `-target` flag is added for clang, and no fully-qualified cross-compiler
rewrite happens for gcc, even though the *bare* name would have worked.

## Upstream code (unchanged as of the commit above, upstream)

```c
static void dcc_add_clang_target(char **argv)
{
        /* defined by autoheader */
    const char *target = NATIVE_COMPILER_TRIPLE;

    if (strcmp(argv[0], "clang") == 0 || strncmp(argv[0], "clang-", strlen("clang-")) == 0 ||
        strcmp(argv[0], "clang++") == 0 || strncmp(argv[0], "clang++-", strlen("clang++-")) == 0)
        ;
    else
        return;
```

```c
static int dcc_gcc_rewrite_fqn(char **argv)
{
        /* defined by autoheader */
    const char *target_with_vendor = NATIVE_COMPILER_TRIPLE;
    char *newcmd, *t, *path;
    int pathlen = 0;
    int newcmd_len = 0;

    if (strcmp(argv[0], "gcc") == 0 || strncmp(argv[0], "gcc-", strlen("gcc-")) == 0 ||
        strcmp(argv[0], "g++") == 0 || strncmp(argv[0], "g++-", strlen("g++-")) == 0)
        ;
    else
        return -ENOENT;

    newcmd_len = strlen(target_with_vendor) + 1 + strlen(argv[0]) + 1;
    ...
    strcat(newcmd, "-");
    strcat(newcmd, argv[0]);
```

Note the second bug in `dcc_gcc_rewrite_fqn()`, present in upstream's own
current source and also fixed by #491's diff: the rewritten command name
is built by concatenating the *raw* `argv[0]`, not the basename — even if
the match above were somehow reached with a full path, the resulting
`newcmd` would be malformed (e.g. `x86_64-linux-gnu-/usr/bin/gcc-11`
instead of `x86_64-linux-gnu-gcc-11`).

## Fixed code (changed code as of the commit from distcc-ng fork)

Both functions now compare (and, for `dcc_gcc_rewrite_fqn()`, concatenate)
`dcc_find_basename(argv[0])` instead of raw `argv[0]` — the same helper
already used elsewhere in this codebase (`arg.c`, `dotd.c`, `state.c`,
`distcc.c`) for exactly this kind of "resolve to the last path component"
need:

```c
    const char *base = dcc_find_basename(argv[0]);

    if (strcmp(base, "clang") == 0 || strncmp(base, "clang-", strlen("clang-")) == 0 ||
        strcmp(base, "clang++") == 0 || strncmp(base, "clang++-", strlen("clang++-")) == 0)
        ;
    else
        return;
```

```c
    const char *base = dcc_find_basename(argv[0]);
    ...
    if (strcmp(base, "gcc") == 0 || strncmp(base, "gcc-", strlen("gcc-")) == 0 ||
        strcmp(base, "g++") == 0 || strncmp(base, "g++-", strlen("g++-")) == 0)
        ;
    else
        return -ENOENT;

    newcmd_len = strlen(target_with_vendor) + 1 + strlen(base) + 1;
    ...
    strcat(newcmd, "-");
    strcat(newcmd, base);
```

This fix is safe because neither function *executes* `argv[0]` itself —
they only use it for string classification and (for gcc) to build a new
`argv[0]` value that a later stage of `dcc_build_somewhere()` will use.
This is unlike the unrelated, opposite-shaped bug found in the same area
of this fork (`src/arg.c`'s `dcc_resolve_march_native()`, tracked in
issue-073-march-native-resolve.md / fixed alongside issue #278's Codex
findings), where stripping to a basename before an actual `execlp()` call
changes *which physical binary runs* (PATH search vs. the caller's
originally-resolved path) — a real behavior change, not a safe
normalization. No such risk exists here since these two functions never
exec anything.

A third instance of the same literal-`argv[0]`-comparison pattern exists
in the same file, `dcc_rewrite_generic_compiler()`'s entry check
(`strcmp(argv[0], "cc") == 0`), also unable to fire for a full path.
It was deliberately **not** fixed alongside this pair: unlike the two
functions above, `dcc_rewrite_generic_compiler()` performs its own
`dcc_which()` PATH-based lookup after this check succeeds, one keyed on
a hardcoded `"cc"`/`"c++"`, not on the resolved basename — making a
basename-based entry-check-only fix a materially different, separately-
reasoned change (with the same "wrong physical binary" risk shape as
`arg.c`'s `dcc_resolve_march_native()`) rather than a safe drop-in of the
same fix. Left as a follow-up: see wiki-mod/distcc-ng#78's PR discussion.

## Empirical verification

Built and tested on a real Linux host (native ext4, not
WSL2/DrvFs), both the unmodified (`origin/current_dev`) and fixed
`src/compile.c`, side by side:

- **Before (unmodified):** `DISTCC_HOSTS='' distcc /usr/bin/gcc -c test.c -o test.o`
  and `DISTCC_HOSTS='' distcc /usr/bin/clang-19 -c test.c -o test.o`
  (`DISTCC_VERBOSE=1`) produce **no** `dcc_gcc_rewrite_fqn`/
  `dcc_add_clang_target` trace line at all — confirmed by `grep`ing the
  trace output for `rewrit|target|adding` and getting zero matches for
  both.
- **After (fixed):** the identical commands produce
  `(dcc_gcc_rewrite_fqn) Re-writing call to '/usr/bin/gcc' to
  'x86_64-linux-gnu-gcc' to support cross-compilation.` and
  `(dcc_add_clang_target) Adding '-target x86_64-linux-gnu' to support
  clang cross-compilation.` respectively — both compiles then proceed
  using the rewritten/target-augmented command.
- **No regression on bare names:** `distcc gcc -c test.c -o test.o` and
  `distcc clang-19 -c test.c -o test.o` produce byte-identical trace
  lines before and after the fix (the existing, already-working case).
- Full `make check` passes cleanly on the fixed tree on this real host
  (including `ModeBits_Case`, which a genuine Unix-permission-honoring
  filesystem is required for), no new warnings from the changed files.

### The issue's own example (`/usr/bin/arm-linux-gnueabihf-gcc`) does not need this fix, or any fix

Fork issue #78's own wording ("aren't correctly detected as the
target-specific compiler they are") reads as if a target-triple-prefixed
name like `arm-linux-gnueabihf-gcc` is *mishandled* today. It isn't, and
this fix doesn't change its behavior at all — verified empirically, not
just by re-reading the match patterns:

A real fake cross-compiler dispatcher, `/tmp/.../xbin/arm-linux-gnueabihf-gcc`
(a `#!/bin/sh; exec /usr/bin/gcc "$@"` script — a real executable, not a
symlink, so it can't false-green off `dcc_rewrite_generic_compiler()`'s
existing symlink-chasing branch), invoked by its full path through both
an unmodified `origin/current_dev` build and this fix's build, on the
same real host:

```
=== BASELINE (unmodified current_dev) ===
distcc[130083] exec on localhost: /tmp/.../xbin/arm-linux-gnueabihf-gcc -c test.c -o test_base.o
distcc[130083] (dcc_spawn_child) forking to execute: /tmp/.../xbin/arm-linux-gnueabihf-gcc -c test.c -o test_base.o
=== FIXED (this PR) ===
distcc[130088] exec on localhost: /tmp/.../xbin/arm-linux-gnueabihf-gcc -c test.c -o test_fixed.o
distcc[130088] (dcc_spawn_child) forking to execute: /tmp/.../xbin/arm-linux-gnueabihf-gcc -c test.c -o test_fixed.o
```

Byte-identical trace in both cases: no `dcc_gcc_rewrite_fqn`/
`dcc_add_clang_target`/`dcc_rewrite_generic_compiler` line fires either
before or after this fix, in both cases the compiler is executed exactly
as given (full path preserved, name untouched), and both produce an
identical, valid `.o` object file (`file test_base.o test_fixed.o`: both
`ELF 64-bit LSB relocatable, x86-64 ... not stripped`).

This is expected, not a gap: `arm-linux-gnueabihf-gcc` never matches
`dcc_add_clang_target()`'s or `dcc_gcc_rewrite_fqn()`'s `"clang"`/`"gcc"`
family patterns (`strncmp("arm-linux-gnueabihf-gcc", "gcc-", 4)` fails —
different string, not a prefix relationship) — with or without basename
extraction — nor `dcc_rewrite_generic_compiler()`'s exact `"cc"`/`"c++"`
check. All three functions exist to **add** cross-compilation handling to
a compiler invocation that doesn't already carry it (a bare `cc`, `gcc`,
or `clang` that needs a `-target` flag or a target-prefixed rename to
become cross-capable). A name that is *already* fully target-prefixed —
which is exactly what `arm-linux-gnueabihf-gcc` is — needs none of that:
it is passed straight through to the remote/local compile step unmodified,
under its own full path, which is already the correct behavior (the
named binary is the compiler that should run). There is no code path in
`src/compile.c`, `src/arg.c`, or `src/climasq.c` that special-cases or
mishandles an already-target-prefixed compiler name. Confirmed by a full
grep of all three files for compiler-family string comparisons
(`"gcc"`/`"clang"`/`"cc"`/`"c++"` literals and prefix checks), not just
reasoning about the two functions this PR touches.

**Conclusion:** the issue's illustrative example was imprecise. The
underlying, real bug this PR fixes is real and distinct: a *bare*
`gcc`/`g++`/`gcc-N`/`clang`/`clang-N` compiler invoked via a full path
(e.g. `/usr/bin/gcc-11`) previously did not get the cross-compilation
handling it would have gotten via its bare name, purely because of the
unstripped-path string comparison. An already fully-qualified
cross-compiler name was never broken and needs no further change.
