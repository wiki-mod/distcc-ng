# `dcc_add_clang_target()`/`dcc_gcc_rewrite_fqn()` match `argv[0]` literally, so cross-compile auto-rewrite never fires when the compiler is invoked by full path

**Fork issue:** [wiki-mod/distcc-ng#78](https://github.com/wiki-mod/distcc-ng/issues/78)
**Fixed by:** [wiki-mod/distcc-ng#281](https://github.com/wiki-mod/distcc-ng/pull/281)
**Upstream location:** `src/compile.c`, functions `dcc_add_clang_target()` (line 549) and `dcc_gcc_rewrite_fqn()` (line 577), confirmed exact via `git show 8d569d19:src/compile.c | grep -n "dcc_add_clang_target\|dcc_gcc_rewrite_fqn"`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-21)
**Upstream already has an open, unmerged fix:** [distcc/distcc#491](https://github.com/distcc/distcc/pull/491) ("Support cross compilation when compiler given as path"), open and unmerged as of 2026-07-21 (confirmed via `gh api repos/distcc/distcc/pulls/491`: `state: open`, `merged: false` — this literal-path form of `gh api` has no `--repo` flag to add per AGENTS.md rule 18's example list; `--repo` only applies to `gh` subcommands that resolve a repo ambiently, not to `gh api` calls whose endpoint path already names the repo explicitly, per `gh api --help`). This entry independently re-verifies that PR's diff is correct against this fork's current source before adopting it, per this fork's "never adopt unverified" policy, rather than porting it blind.
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
    newcmd = malloc(newcmd_len);
    ...
    snprintf(newcmd, newcmd_len, "%s-%s", target_with_vendor, base);
```

(Built via `snprintf()` rather than `malloc()`+`strcat()`+`strcat()` as of a later CodeQL `cpp/unbounded-write` cleanup on this same PR, commit `eba52b6` — the buffer sizing was already exact, but `snprintf()` makes the bound self-evident at the write site instead of relying on a remembered invariant a few lines above.)

A follow-up Codex review on PR #281 found two further, related issues in
`dcc_gcc_rewrite_fqn()` not part of the original basename fix: a NULL
`$PATH` would crash the PATH-search loop, and — more relevantly for this
entry — rewriting a directory-qualified `argv[0]` (e.g.
`/opt/toolchain/bin/gcc`) to a bare target-prefixed name and letting the
later `execvp()` resolve it via a fresh global `$PATH` search could
silently execute a *different* cross-toolchain's same-named binary than
the one the build system actually selected. Fixed (commit `7700663`) by
preferring the target-prefixed binary in the **same directory** as the
original compiler when `argv[0]` had one, only falling back to a global
`$PATH` search when it didn't (i.e. was already bare):

```c
    if (base != argv[0]) {
        size_t dirlen = (size_t) (base - argv[0]); /* includes trailing '/' */
        int dirbinlen = (int) dirlen + newcmd_len;
        char *dirbin = malloc(dirbinlen);
        ...
        memcpy(dirbin, argv[0], dirlen);
        memcpy(dirbin + dirlen, newcmd, newcmd_len);
        if (access(dirbin, X_OK) == 0) {
            ...
            argv[0] = dirbin;
            return 0;
        }
        free(dirbin);
        free(newcmd);
        return -ENOENT;
    }
```

This is a stricter, more correct behavior than a global `$PATH` search
would be for a directory-qualified invocation, and it's why the empirical
verification below distinguishes a directory-qualified full path with and
without the target-prefixed sibling present, rather than only the bare-name
case.

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

**Re-run 2026-07-22** against the branch tip as of commit `7700663`
("Fix two Codex P2 findings in `dcc_gcc_rewrite_fqn()`: NULL PATH and
toolchain-directory loss") — a Codex review on PR #281 correctly flagged
that an earlier version of this section had gone stale after that commit
changed `dcc_gcc_rewrite_fqn()`'s behavior for a directory-qualified
`argv[0]`: it no longer rewrites to a bare target-prefixed name resolved
via a global `$PATH` search; instead it looks for the target-prefixed
binary **in the same directory as the original compiler** and only
rewrites if that specific file exists, returning `-ENOENT` (no rewrite at
all) otherwise. The trace below was captured fresh from an actual build
and run, not edited by hand from the old text.

Built and tested on a real Linux host (native ext4, not WSL2/DrvFs), the
current branch tip:

- **Full path, target-prefixed sibling absent (the realistic case on a
  plain Debian host missing a matching cross-toolchain package)**: a
  fake `/.../nosibling/gcc` dispatcher script (no `x86_64-linux-gnu-gcc`
  alongside it) invoked as `DISTCC_VERBOSE=1 DISTCC_HOSTS=''  distcc
  /.../nosibling/gcc -c test.c -o out.o` produces **no**
  `dcc_gcc_rewrite_fqn` trace line at all — `dcc_gcc_rewrite_fqn()`
  returns `-ENOENT` internally and the original invocation
  (`/.../nosibling/gcc`) is executed unchanged:
  ```
  distcc[152314] exec on localhost: /tmp/.../nosibling/gcc -c test.c -o out_nosibling.o
  distcc[152314] (dcc_spawn_child) forking to execute: /tmp/.../nosibling/gcc -c test.c -o out_nosibling.o
  ```
- **Full path, target-prefixed sibling present** (a second fake
  `x86_64-linux-gnu-gcc` script placed in the *same* directory as `gcc`):
  the rewrite now fires and resolves to the full path **in that same
  directory**, not a bare name subject to a fresh global `$PATH` search:
  ```
  distcc[152320] (dcc_gcc_rewrite_fqn) Re-writing call to '/tmp/.../withsibling/gcc' to '/tmp/.../withsibling/x86_64-linux-gnu-gcc' to support cross-compilation.
  distcc[152320] exec on localhost: /tmp/.../withsibling/x86_64-linux-gnu-gcc -c test.c -o out.o
  ```
- **Bare name (no directory component, e.g. plain `gcc` on `$PATH`)**:
  unaffected by the directory-preserving change — still resolves via a
  global `$PATH` search to a bare rewritten name, exactly as before:
  ```
  distcc[152326] (dcc_gcc_rewrite_fqn) Re-writing call to 'gcc' to 'x86_64-linux-gnu-gcc' to support cross-compilation.
  distcc[152326] exec on localhost: x86_64-linux-gnu-gcc -c test.c -o out.o
  ```
- **clang, full path** (`/usr/bin/clang-19`, unaffected by the gcc-specific
  directory fix): `-target` still added as before:
  ```
  distcc[152332] (dcc_add_clang_target) Adding '-target x86_64-linux-gnu' to support clang cross-compilation.
  distcc[152332] exec on localhost: /usr/bin/clang-19 -c test.c -o out.o -target x86_64-linux-gnu
  ```
- All four cases produced a valid, non-empty `.o` object file
  (`ELF 64-bit LSB relocatable, x86-64`, confirmed via `file`/`ls -la`).
- Full `make check` passes cleanly on this branch tip on this real host
  (123 `OK` cases, no `FAIL`; including `ModeBits_Case`, which a genuine
  Unix-permission-honoring filesystem is required for), no new warnings
  from the changed files.

This supersedes the original (now-stale) trace this section previously
carried, which showed the pre-`7700663` behavior — a bare-name
`$PATH`-search rewrite even for a directory-qualified full-path
invocation. That behavior no longer exists; see the "Fixed code" section
above (last snippet) for the current directory-preserving logic itself.

### External-host interop (`doc/verification-checklist.md` section 4)

A further Codex review on PR #281 correctly pointed out that this change
is explicitly named in `doc/verification-checklist.md` section 4's own
"Relevant to" list (`dcc_gcc_rewrite_fqn` and similar compiler
masquerade/rewrite logic) and that only local/no-host traces plus
`make check` had been used as evidence so far — not sufficient for a
change affecting what compiler name/path is actually sent across the
wire to a remote host. Ran the full two-direction matrix for real,
2026-07-22, on two distinct real hosts (not the same machine, not
WSL2), each already running the distro-packaged `distcc`/`distccd`
3.4+really3.4-12 (Debian, independently built from this fork, `distccd`
built Apr 18 2025) as a live system service, alongside this branch's own
build (`3.7.0-NG`, built fresh from the current tip):

- **Direction A — this fork's fixed client against a real,
  independently-built `distccd`**: on host A, `DISTCC_HOSTS=<host
  B>:3632 DISTCC_FALLBACK=0` with this branch's own `distcc`, invoking
  `/usr/bin/gcc` (full path, with `/usr/bin/x86_64-linux-gnu-gcc`
  present alongside it — this host's real, unmodified Debian
  multiarch-gcc layout) across **15 real, distinct `.c` files from this
  project's own `src/`** (not a hello-world), each compiled in real
  parallel (`&`/`wait`, not sequential). All 15 produced valid non-empty
  `.o` object files. Client trace confirms the rewrite fired and the
  compile ran on the *remote* host, not locally:
  ```
  distcc[162050] (dcc_gcc_rewrite_fqn) Re-writing call to '/usr/bin/gcc' to '/usr/bin/x86_64-linux-gnu-gcc' to support cross-compilation.
  distcc[162050] exec on 192.168.1.240:3632: /usr/bin/x86_64-linux-gnu-gcc -Werror -g -O3 -W -Wall -o .../bulk.o -c src/bulk.c
  ```
  Confirmed from **host B's own independent log** (`journalctl -u
  distcc`, the real system `distccd`'s own record, not the client's
  claim), all 15 as `COMPILE_OK`:
  ```
  distccd[147]: (dcc_job_summary) client: 192.168.1.229:60940 COMPILE_OK exit:0 sig:0 core:0 ret:0 time:73ms /usr/bin/x86_64-linux-gnu-gcc src/bulk.c
  ```
  (and 14 further identically-shaped `COMPILE_OK` lines for the rest of
  the file set, one per source file, all `exit:0`).
- **Direction B — a real, independently-built `distcc` client against
  this fork's fixed `distccd`**: on host B, the same distro `distcc`
  3.4 binary (unmodified — this fix is client-side only, so this
  direction exercises whether the *server* still correctly serves an
  unmodified stock client, not the rewrite itself), `DISTCC_HOSTS=<host
  A>:43632 DISTCC_FALLBACK=0` (a dedicated instance of this branch's own
  `distccd`, started on a non-default port so as not to disturb host A's
  own pre-existing system `distccd` service), same 15-file real compile
  load, real parallelism. All 15 succeeded. Confirmed from **host A's own
  independent `distccd` log**, all 15 as `COMPILE_OK`:
  ```
  distccd[161987]: (dcc_job_summary) client: 192.168.1.240:49664 COMPILE_OK exit:0 sig:0 core:0 ret:0 time:28ms /usr/bin/gcc src/pathsafety.c
  ```
  (and 14 further identically-shaped lines for the rest of the file set).
- `DISTCC_FALLBACK=0` was set for both directions throughout — a failure
  to actually distribute would have hard-failed the compile (as it did
  transiently once, see below) rather than silently and misleadingly
  succeeding via local fallback.
- One real hiccup during this run, itself informative: the first
  Direction-B attempt failed everywhere with `fatal error: config.h: No
  such file or directory` (host B's checkout hadn't been `./configure`'d,
  so its local preprocessing step — which runs even for a fully remote
  compile, since distcc preprocesses locally — had no `config.h`; fixed by
  copying host A's already-generated `src/config.h` across). That single
  failure then poisoned all 15 *retried* jobs at once via distcc's own
  `backoff_tcp_<host>_<port>_0` lockfile mechanism (`dcc_remove_disliked`)
  marking the host disliked for a cooldown window; clearing that lockfile
  before retrying was necessary to get a clean re-run. Recorded here so a
  future re-verification of this section doesn't waste time
  re-diagnosing the same two artifacts.
- Both temporary hosts' test directories, the dedicated (non-service)
  `distccd` instance started for Direction B, and all generated object
  files/traces were removed after the run; each host's own pre-existing
  system `distccd` service (used as Direction A's server) was left
  untouched and running throughout, as it was never restarted or
  reconfigured — only connected to as a client.

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
