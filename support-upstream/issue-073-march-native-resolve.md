# -march=native/-mtune=native hard-fail to local — upstream has an open, unmerged fix with real bugs of its own

**Fork issue:** [wiki-mod/distcc-ng#73](https://github.com/wiki-mod/distcc-ng/issues/73)
**Fixed by:** [wiki-mod/distcc-ng#175](https://github.com/wiki-mod/distcc-ng/pull/175)
**Upstream location:** `src/arg.c`, `dcc_scan_args()`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-17)
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
