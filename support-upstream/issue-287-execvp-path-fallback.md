# `dcc_execvp()`'s directory-qualified-path failure silently retries with a bare-basename `$PATH` search

**Fork issue:** [wiki-mod/distcc-ng#287](https://github.com/wiki-mod/distcc-ng/issues/287)
**Fixed by:** wiki-mod/distcc-ng#TBD (draft PR, this change)
**Upstream location:** `src/exec.c`, function `dcc_execvp()` (line 248)
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-08-01)
**Searched upstream issues/PRs for:** `dcc_execvp`, `execvp basename`, `wrong compiler`, `compiler substitution`, `PATH fallback exec` — no matching report or fix attempt found, open or closed. This exact fallback traces back to distcc's original 2008 SVN import (this fork's own `git log -S"cause unintnded behaviour" -- src/exec.c` finds it already present, word-for-word including the "I don't think that's a problem" comment, in the initial commit `d6532ae1`) — it predates both this fork and any upstream history searchable via `gh`.

## The problem

`dcc_execvp()` is the single, shared function that actually execs a
compiler, on both `distcc` (client, for local fallback/cpp) and `distccd`
(server, for a remote client's chosen compiler). If the first `execvp()`
fails, it unconditionally retries with a second `execvp()` on just the
basename of `argv[0]`, letting the exec'ing host's own `$PATH` resolve it.

Empirically, this second `execvp()` can only ever be reached when
`argv[0]` already contains a `/`: `strrchr(argv[0], '/')` is `NULL`
otherwise, and POSIX `execvp()` already performs a full `$PATH` search
itself whenever the filename has no `/` — so a bare basename that fails
in the first call has already had every `$PATH` candidate tried, and the
fallback is unreachable for it. For a directory-qualified `argv[0]`
(absolute, or relative with a `/`), `execvp()` treats it as a literal
path and never consults `$PATH` — so reaching the fallback specifically
means that exact path doesn't exist on the host doing the exec.

On `distccd`, `argv[0]` is chosen by a remote, potentially
differently-configured client (`src/serve.c`'s `dcc_check_compiler_whitelist()`
lets a `/bin/`- or `/usr/bin/`-prefixed absolute path through even in the
secure default config — a real, mainstream case, not just the
`--enable-tcp-insecure`/`DISTCC_CMDLIST` configurations). If the server
happens to have a *different* binary of the same basename somewhere on
its own `$PATH` (a different vendor's or version's cross-toolchain, or
just an unrelated same-named tool), that binary silently runs instead —
no error, no signal to the client that a substitution happened, just a
compile that "succeeds" against a compiler nobody actually selected.

## Upstream code (unchanged as of the commit above, upstream)

```c
static void dcc_execvp(char **argv)
{
    char *slash;

    execvp(argv[0], argv);

    /* If we're still running, the program was not found on the path.  One
     * thing that might have happened here is that the client sent an absolute
     * compiler path, but the compiler's located somewhere else on the server.
     * In the absence of anything better to do, we search the path for its
     * basename.
     *
     * Actually this code is called on both the client and server, which might
     * cause unintnded behaviour in contrived cases, like giving a full path
     * to a file that doesn't exist.  I don't think that's a problem. */

    slash = strrchr(argv[0], '/');
    if (slash)
        execvp(slash + 1, argv);

    /* shouldn't be reached */
    rs_log_error("failed to exec %s: %s", argv[0], strerror(errno));

    dcc_exit(EXIT_COMPILER_MISSING); /* a generalization, i know */
}
```

## Fixed code (changed code as of the commit from distcc-ng fork)

```c
static void dcc_execvp(char **argv)
{
    execvp(argv[0], argv);

    if (dcc_find_basename(argv[0]) == argv[0]) {
        /* No directory component: the execvp() above already searched
         * $PATH for this exact name, so there is no narrower name left
         * to retry with. */
        rs_log_error("failed to exec %s: %s", argv[0], strerror(errno));
    } else {
        /* Directory-qualified and not found at that exact location.
         * Deliberately not retrying with a PATH search on just the
         * basename -- see the function comment above. */
        rs_log_error("failed to exec %s: %s "
                      "(not retrying with a PATH search for a substitute "
                      "compiler)",
                      argv[0], strerror(errno));
    }

    dcc_exit(EXIT_COMPILER_MISSING); /* a generalization, i know */
}
```

The fix removes the second `execvp()` entirely and instead always fails
loudly (the same `rs_log_error()` + `dcc_exit(EXIT_COMPILER_MISSING)` the
no-fallback-possible case already used) whenever the first `execvp()`
fails, with a clearer message when the failure was a directory-qualified
path (to make it obvious this isn't the "bare name genuinely missing
everywhere" case `MissingCompiler_Case` already covered). A loud failure
here is not a hard build break for a normal deployment: it becomes an
ordinary remote-compile failure on the client (`dcc_critique_status()` /
`dcc_build_somewhere()` in `src/compile.c`), which retries locally with a
logged warning when `DISTCC_FALLBACK` is enabled (the default), or a
clear hard failure when it's disabled — never a silent, wrong-compiler
"success."

## Empirical verification

Real build (`./autogen.sh && ./configure PYTHON=python3 && make`, inside
`ghcr.io/wiki-mod/distcc-ng-buildtools:latest`) of both the pre-fix and
fixed `distcc`/`distccd`, and a real client/server pair on the same host:

- `distccd` started with `--allow 127.0.0.1 --enable-tcp-insecure`, with a
  directory containing a marker script named `gcc-marker` added to
  *distccd's own* `$PATH`. The script logs its real invocation path and
  behaves like a trivially "successful" compiler (exit 0).
- Client: `DISTCC_HOSTS=127.0.0.1:3634,lzo DISTCC_FALLBACK=0 distcc /nonexistent/dir/gcc-marker -o hello.o -c hello.i` — `/nonexistent/dir/gcc-marker` exists nowhere on the filesystem.

**Pre-fix**, distccd's own log:
```
distccd[1900] (dcc_spawn_child) forking to execute: /nonexistent/dir/gcc-marker -o /tmp/distccd_72ebf1ac1ae6e0dc.o -c /tmp/distccd_301e6ecdbd8e6681.i
```
but the marker script's own log shows a *different* binary actually ran:
```
SUBSTITUTE COMPILER RAN: /work/repro/bin/gcc-marker -o /tmp/distccd_72ebf1ac1ae6e0dc.o -c /tmp/distccd_301e6ecdbd8e6681.i
```
Client: `distcc[1937] compile hello.i on 127.0.0.1:3634,lzo completed ok`, exit code 0 — a clean, silent, wrong-compiler "success."

**Post-fix**, identical scenario:
```
distccd[2196] (dcc_execvp) ERROR: failed to exec /nonexistent/dir/gcc-marker: No such file or directory (not retrying with a PATH search for a substitute compiler)
distcc[2195] ERROR: compile hello.i on 127.0.0.1:3634,lzo failed with exit code 110
```
Marker log absent — the substitute binary was never invoked; client exit
code 110 (`EXIT_COMPILER_MISSING`), loud and unambiguous.

A permanent regression test (`PathQualifiedCompilerNotSubstituted_Case` in
`test/testdistcc.py`) encodes this same scenario and passed as part of a
full `make check` run (see the fixing PR's own validation section for the
complete real test-suite output).
