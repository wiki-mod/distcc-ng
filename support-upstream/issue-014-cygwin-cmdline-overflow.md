# Unbounded strcat command-line construction overflows fixed 261-byte buffer in dcc_execvp_cyg (Cygwin)

**Fork issue:** [wiki-mod/distcc-ng#14](https://github.com/wiki-mod/distcc-ng/issues/14)
**Fixed by:** [wiki-mod/distcc-ng#25](https://github.com/wiki-mod/distcc-ng/pull/25)
**Upstream location:** `src/exec.c`, `dcc_execvp_cyg()`
**Checked against upstream commit:** [`6c177fb5`](https://github.com/distcc/distcc/commit/6c177fb52ab6e66d71178df791a248683b98a4a3) (latest commit touching `src/exec.c`, `master`, checked 2026-07-17)
**Searched upstream issues/PRs for:** `dcc_execvp_cyg`, `cygwin command line buffer`, `cygwin MAX_PATH overflow` — no matching report or fix attempt found, open or closed.

## The problem

`dcc_execvp_cyg()` (the Cygwin-specific process-launch path, used when the
compiler being invoked is a native Windows executable rather than a Cygwin
one) builds the child process's command line by `strcat`-ing every `argv`
element, one after another with a separating space, into a fixed-size
stack buffer sized `MAX_PATH+1` (261 bytes on Windows). A real compiler
invocation's combined argument length has no fixed upper bound — long
include paths, many `-D`/`-I` flags, and distcc/pump-injected arguments can
easily exceed 261 bytes — so any invocation whose concatenated arguments
are longer than that overflows the stack buffer silently (no bounds
checking anywhere in the loop).

## Upstream code (unchanged as of the commit above, upstream `master`)

`src/exec.c`, `dcc_execvp_cyg()`:

```c
static DWORD dcc_execvp_cyg(char **argv, const char *input_file,
    ...
{
    STARTUPINFO    m_siStartInfo;
    PROCESS_INFORMATION m_piProcInfo;
    char cmdline[MAX_PATH+1]={0};
    ...
    /* Create command line */
    for (ptr=argv;*ptr!=NULL;ptr++)
    {
        strcat(cmdline, *ptr);
        strcat(cmdline, " ");
    }
```

The buffer is still the fixed `MAX_PATH+1` (261-byte) stack array today,
and the `strcat` loop still performs no length checking of any kind before
writing — the exact bug this fork fixed.

## Fixed code (this fork, PR #25)

`cmdline` becomes a heap allocation sized to fit the actual concatenated
argument length (plus separators and the trailing NUL), computed before
the `strcat` loop runs, and freed on every exit path:

```c
char *cmdline = NULL;
...
/* Create command line.  A compiler invocation's combined argument
 * length has no fixed upper bound (long include paths, many -D/-I
 * flags, distcc/pump-injected arguments), so size the buffer to
 * fit rather than using a fixed-size buffer -- a fixed 261-byte
 * (MAX_PATH) buffer here previously overflowed on any invocation
 * whose arguments exceeded that, silently corrupting the stack. */
{
    size_t cmdline_len = 1; /* for the trailing NUL */
    for (ptr=argv;*ptr!=NULL;ptr++)
        cmdline_len += strlen(*ptr) + 1; /* +1 for the separating space */
    cmdline = calloc(cmdline_len, 1);
    if (!cmdline) {
        exit_code = ERROR_NOT_ENOUGH_MEMORY;
        goto cleanup;
    }
}
for (ptr=argv;*ptr!=NULL;ptr++)
{
    strcat(cmdline, *ptr);
    strcat(cmdline, " ");
}
...
cleanup:
    free(cmdline);
```

Landed via [wiki-mod/distcc-ng#25](https://github.com/wiki-mod/distcc-ng/pull/25).
