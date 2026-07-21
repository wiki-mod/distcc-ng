# -march=native/-mtune=native hard-fail to local — upstream has an open, unmerged fix with real bugs of its own

**Fork issue:** [wiki-mod/distcc-ng#73](https://github.com/wiki-mod/distcc-ng/issues/73)
**Fixed by:** [wiki-mod/distcc-ng#175](https://github.com/wiki-mod/distcc-ng/pull/175) (bugs 1-4 below); [wiki-mod/distcc-ng#245](https://github.com/wiki-mod/distcc-ng/pull/245) (bugs 5-6, found later via [wiki-mod/distcc-ng#227](https://github.com/wiki-mod/distcc-ng/issues/227))
**Upstream location:** `src/arg.c`, `dcc_scan_args()`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-18)
**Searched upstream issues/PRs for:** `march=native`, `mtune=native`, `mcpu=native` — found upstream's own open, unmerged attempts: [distcc/distcc#350](https://github.com/distcc/distcc/pull/350) and its rebase [distcc/distcc#384](https://github.com/distcc/distcc/pull/384).

## Note on scope: upstream already knows about this one

Unlike this folder's other entries, upstream is not unaware of this
problem — they have their own open pull requests attempting to fix it.
This entry documents two things instead: (1) upstream's default `master`
branch still has the un-fixed, hard-failing behavior today regardless of
those open PRs, and (2) this fork's port of the same idea found and fixed
several real correctness/safety bugs in upstream's own draft that their
still-open PR doesn't address — potentially useful for upstream's own
review of #350/#384, whether or not they ever look here.

## The problem

`-march=native`, `-mtune=native`, and (in this fork) `-mcpu=native` are
only meaningful on the machine that actually runs the codegen. Shipping
one of these flags unresolved to a remote compile server would silently
compile for the *server's* CPU instead of the client's — a real
correctness hazard, not just an inconvenience. Upstream's current
`dcc_scan_args()` handles this the blunt way: hard-fail and force the
*entire* compilation to run locally, rather than resolving what "native"
actually expands to on the client and shipping the concrete flags remotely.

## Upstream code (unchanged as of the commit above, upstream `master`)

```c
} else if (!strcmp(a, "-march=native")) {
    rs_trace("-march=native generates code for local machine; "
             "must be local");
    return EXIT_DISTCC_FAILED;
} else if (!strcmp(a, "-mtune=native")) {
    rs_trace("-mtune=native optimizes for local machine; "
             "must be local");
    return EXIT_DISTCC_FAILED;
```

This is `master`'s live behavior today — upstream's own #350/#384 change
this, but neither has been merged.

## Fixed code (changed code as of the commit from distcc-ng fork)

`src/arg.c` gains `dcc_resolve_march_native()`, invoked from
`dcc_scan_args()` before the old hard-fail path would otherwise trigger:

```c
/* Resolve "native" to concrete flags by asking the local compiler.
 * Runs `<compiler> -v -E -x c -march=native ... -` (stdin closed, an
 * empty translation unit) and scrapes the resolved flags off gcc/clang's
 * verbose cc1 invocation line. Falls back to the old hard-fail behavior
 * if resolution fails for any reason -- a compile is never shipped
 * remotely with an unresolved "native" flag. */
static int dcc_resolve_march_native(char *argv[], char ***ret_newargv,
                                     int *ret_newargc)
{
    ...
    pid = fork();
    if (pid == 0) {
        /* child: redirect the probe compiler's own stdout to /dev/null
         * (upstream's draft left this connected to distcc's stdout) */
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull != -1) {
            dup2(devnull, STDOUT_FILENO);
            close(devnull);
        }

        execlp(compiler, compiler, "-v", "-E", "-x", "c",
               found_arch_native ? "-march=native" : "-DDCC_MARCH_NATIVE_UNUSED",
               found_tune_native ? "-mtune=native" : "-DDCC_MTUNE_NATIVE_UNUSED",
               found_cpu_native  ? "-mcpu=native"  : "-DDCC_MCPU_NATIVE_UNUSED",
               "-", (char *) NULL);
        /* execlp() only returns on failure -- _exit(), never fall back
         * into normal control flow (upstream's draft used a bare
         * `return` here, which would fork the whole distcc client
         * process in two). */
        _exit(127);
    }
    ...
    waitpid(pid, &status, 0);   /* upstream's draft never reaped the child */
    ...
}
```

Three real bugs fixed relative to upstream's own #350/#384 draft, found
while adapting it to this fork's current `src/arg.c`:

1. **Fork-bomb-shaped control-flow bug**: if `execlp()` failed, upstream's
   draft fell through via a bare `return` back into the forked child's own
   copy of the calling function — which would then continue running as if
   it were the *parent*, effectively duplicating the whole `distcc` client
   process from that point on. This fork's version always `_exit()`s from
   the child on any exec failure.
2. **Unreaped child process**: upstream's draft never called `waitpid()`
   on the forked probe process, leaking a zombie on every single
   `-march=native` resolution. This fork's version reaps it.
3. **stdout pollution**: the probe compiler's own child process had its
   stdout left connected to distcc's own stdout, so the probe's harmless
   preprocessor output could leak into the client's real output stream.
   This fork's version redirects the child's stdout to `/dev/null`.

A fourth, security-relevant issue was found and fixed **within this
fork's own port** (not present in upstream's draft, since upstream's PR
predates this fork's server-side compiler whitelist ordering): a real
CodeQL finding (`cpp/uncontrolled-process-operation`) showed that on the
*server* side, `dcc_scan_args()` — and therefore `dcc_resolve_march_native()`'s
`execlp()` — could run before the compiler-name whitelist/masquerade
checks, meaning an unvalidated, network-supplied compiler name could reach
`execlp()`. Fixed by reordering the server's whitelist validation to run
before `dcc_scan_args()`. See PR #175's own commit history and review
thread for the full detail — not upstream-relevant on its own since it's
specific to how this fork structured the port, but documented here for
completeness since it's part of the same function's story.

Landed via [wiki-mod/distcc-ng#175](https://github.com/wiki-mod/distcc-ng/pull/175).

### Two more bugs found in the same draft (#384), fixed via #227/#245

A later fork issue ([wiki-mod/distcc-ng#227](https://github.com/wiki-mod/distcc-ng/issues/227))
found two further real bugs in upstream's #384 draft while working on a
different but related problem (compiler-family misdetection). Both are
still present in the draft as of the commit checked below; neither has
master-branch line numbers since `dcc_resolve_march_native()` doesn't
exist in `master` at all (see this entry's main body above).

**5. `is_clang` trusted from `argv[0]`'s basename, not the actual invoked
compiler.** From `gh pr diff 384 --repo distcc/distcc`:

```c
const char* compiler = strrchr(argv[0], '/');
compiler = (compiler == 0) ? (argv[0]) : (compiler + 1);
int is_clang = strncmp(compiler, "clang", strlen("clang")) == 0;
```

A dispatcher invoked under a name that doesn't contain "clang" (e.g.
macOS's `cc`) is misclassified as gcc even when it actually runs clang,
so the (also unfiltered — see bug 6) gcc-branch code path forwards raw
clang-internal `cc1` tokens as if they were gcc flags. This fork's fix
(#227/#245) instead reads the actual backend invocation this same
function already captures during its `-v -E` probe: clang always invokes
its frontend as the literal dash-prefixed `-cc1`; gcc's `cc1`/`cc1plus`
never is dash-prefixed. No new subprocess or reorder needed — the data
was already being read, just not used for this.

**6. No token filter at all on the non-clang (gcc) branch.** Same diff,
the token-splitting loop unconditionally forwards every space-separated
token from the resolved `-v -E` output for anything not detected as
clang:

```c
if (is_clang) {
    if (strncmp(insert, "-target", strlen("-target")) == 0) {
        /* need to forward the following option */
        clang_force_next = 1;
    } else {
        /* discard non-target options */
        ...
```

— clang's branch discards non-`-target*` tokens, but there is no
equivalent `else` filter for the non-clang path: every gcc `cc1` token,
including driver-internal noise (`-quiet`, `-imultiarch <triple>`,
`--param <name>=<value>`, `-fasynchronous-unwind-tables`, `-dumpbase -`,
the trailing bare `-`), gets forwarded to gcc as-is. Verified against
real `gcc -v -E -march=native` output (see #227's issue body/PR #245 for
the full captured line). This fork's fix keeps only `-m`-prefixed tokens.

**Searched upstream issues/PRs again for this specific angle:**
`is_clang`, `argv[0] basename clang`, `cc1 filter` — no discussion found
of detection accuracy or the missing gcc-branch filter in #384's own
review thread or elsewhere.

Landed via [wiki-mod/distcc-ng#245](https://github.com/wiki-mod/distcc-ng/pull/245).

### A seventh bug in the same draft, found via a Codex review of #219, fixed via #278

A Codex (chatgpt-codex-connector) review of PR #219 (later tracked as
[wiki-mod/distcc-ng#278](https://github.com/wiki-mod/distcc-ng/issues/278))
found that bug 5's fix (reading the actual backend invocation to decide
`is_clang`) left one remaining piece of the same basename-trust problem
untouched: the variable that decides **which binary to actually exec**
for the probe, not just which family to interpret its output as.

**7. The probe execs a re-resolved basename, not the invoked binary.**
Confirmed still present in upstream's #384 draft as of the same commit
checked above (`gh pr diff 384 --repo distcc/distcc`, checked
2026-07-21):

```c
const char* compiler = strrchr(argv[0], '/');
compiler = (compiler == 0) ? (argv[0]) : (compiler + 1);
...
execlp(compiler, compiler, "-v", "-E", "-x", "c", ...);
```

This is the same line quoted under bug 5 above, but the relevant defect
is different: regardless of how `is_clang` gets decided, `execlp()` is
handed the stripped **basename**, not `argv[0]` itself. If `argv[0]` was
an explicit path (the user invoked `distcc /opt/x/cc ...` directly, or a
masquerade symlink already resolved to one) rather than a bare name meant
to be found on `PATH`, stripping to the basename before `execlp()` throws
away that distinction and forces a *fresh* `PATH` search for just the
name — which can silently resolve to a *different* binary than the one
actually invoked (or fail to resolve at all, if that name isn't on
`PATH` under its own basename). This fork's fix (#278) instead passes
`argv[0]` through unchanged: `execlp()` already implements the correct
rule on its own — a name containing `/` is executed literally with no
`PATH` search, a bare name is looked up on `PATH` — so the fix is to stop
overriding that with a basename-only value.

**Searched upstream issues/PRs again for this specific angle:**
`execlp compiler basename`, `argv[0] path distcc-ng`, `cc1 exec path` —
no discussion found of the exec-target (as opposed to the family-
detection) side of this basename-trust problem in #384's own review
thread or elsewhere.

Landed via wiki-mod/distcc-ng#278 (PR number filled in once opened).

## Empirical verification

Real end-to-end test against an actual `distccd` (not just a diff read):

- Started `distccd --daemon --allow 127.0.0.1 --port 13632`.
- Ran `distcc gcc -c -march=native hello.c -o hello.o` with
  `DISTCC_HOSTS=127.0.0.1:13632` — **exit 0**; previously hard-failed with
  `EXIT_DISTCC_FAILED`.
- Client's verbose log confirms `dcc_resolve_march_native` firing and the
  resolved argv exactly matching `gcc -march=native -E -v -x c -`'s own
  direct output for the real local CPU.
- Daemon log confirms a genuine remote compile (`COMPILE_OK exit:0`).
- Full `make check` suite passes.

Full details also in PR #175's own description on
[wiki-mod/distcc-ng#73](https://github.com/wiki-mod/distcc-ng/issues/73).
