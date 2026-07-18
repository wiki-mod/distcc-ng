# `alloca()` inside the `-specs=` argument loop accumulates unbounded stack allocation

**Fork issue:** [wiki-mod/distcc-ng#226](https://github.com/wiki-mod/distcc-ng/issues/226)
**Fixed by:** [wiki-mod/distcc-ng#242](https://github.com/wiki-mod/distcc-ng/pull/242)
**Upstream location:** `src/serve.c`, inside the compiler-argument scan for `-fplugin=`/`-specs=` (the function containing this loop; upstream doesn't split it into a separately named `dcc_run_job()` the way this fork does, but it is the same argument-scanning code, byte-for-byte, including the same explanatory comment)
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-18)
**Searched upstream issues/PRs for:** `alloca`, `specs` — found [distcc/distcc#531](https://github.com/distcc/distcc/pull/531) ("Add sysroot option and allow -specs option from compiler", closed/merged — the PR that originally introduced this exact code) and [distcc/distcc#344](https://github.com/distcc/distcc/pull/344) ("report warning when -fplugin or -specs passed", closed/merged, the `-fplugin=` half of the same block), but no open report of the alloca-in-loop stack-exhaustion behavior itself.

## The problem

The loop over a compile command's arguments calls `alloca()` once for
every `-specs=` argument found, to build a candidate path under the
daemon's configured `--sysroot`:

```c
for (i = 0; (a = argv[i]); i++) {
    ...
    if (strncmp(a, "-specs=", strlen("-specs=")) == 0) {
        int fail = 1;
        if (arg_sysroot) {
            char *spec_file = strchr(a, '=') + 1;
            char *spec_path = alloca(strlen(spec_file) + strlen(arg_sysroot) + 8);
            ...
        }
        ...
    }
}
```

`alloca()`'s allocation is only released when the *enclosing function*
returns — not at the end of each loop iteration. Since `argv` (and
therefore how many `-specs=` arguments appear, and how many times this
loop calls `alloca()`) is entirely client-controlled, a compile command
with many `-specs=` arguments accumulates unbounded, unfreed stack
allocation for as long as the function that contains this loop is still
running — a real, remotely-triggerable stack-exhaustion condition in the
daemon, bounded only by how many `-specs=` arguments a client chooses to
send in one compile request.

## Upstream code (unchanged as of the commit above, upstream)

`src/serve.c`:

```c
    /* unsafe compiler options. See  https://youtu.be/bSkpMdDe4g4?t=53m12s
       on securing https://godbolt.org/ */
    char *a;
    int i;
    for (i = 0; (a = argv[i]); i++) {
        if (strncmp(a, "-fplugin=", strlen("-fplugin=")) == 0) {
            rs_log_warning("-fplugin= passed, which are insecure and not supported.");
            goto out_cleanup;
        }
        if (strncmp(a, "-specs=", strlen("-specs=")) == 0) {
            int fail = 1;
            if (arg_sysroot) {
                char *spec_file = strchr(a, '=') + 1;
                char *spec_path = alloca(strlen(spec_file) + strlen(arg_sysroot) + 8);
                sprintf(spec_path, "%s/%s", arg_sysroot, spec_file);
                struct stat spec_stat;
                if (stat(spec_path, &spec_stat) != -1 && (spec_stat.st_mode & S_IFMT) == S_IFREG) {
                  fail = 0;
                }
            }
            if (fail) {
              rs_log_warning("-specs= passed, but we cannot find the specs.");
              goto out_cleanup;
            }
       }
    }
```

(Upstream also uses raw `sprintf()` for `spec_path` rather than a bounded
`snprintf()` — this fork's version already used `snprintf()` here before
this PR, from earlier, unrelated work; that pre-existing difference is
not part of what this PR fixes, and is noted here only for an accurate
side-by-side comparison, not claimed as this PR's own contribution.)

## Fixed code (this fork, PR #242)

```c
        if (strncmp(a, "-specs=", strlen("-specs=")) == 0) {
            int fail = 1;
            if (arg_sysroot) {
                char *spec_file = strchr(a, '=') + 1;
                size_t spec_path_size = strlen(spec_file) + strlen(arg_sysroot) + 8;
                char *spec_path = malloc(spec_path_size);
                if (spec_path == NULL) {
                    rs_log_error("failed to allocate %lu bytes for spec_path",
                                 (unsigned long) spec_path_size);
                    ret = EXIT_OUT_OF_MEMORY;
                    goto out_cleanup;
                }
                snprintf(spec_path, spec_path_size, "%s/%s", arg_sysroot, spec_file);
                struct stat spec_stat;
                if (stat(spec_path, &spec_stat) != -1 && (spec_stat.st_mode & S_IFMT) == S_IFREG) {
                  fail = 0;
                }
                free(spec_path);
            }
            if (fail) {
              rs_log_warning("-specs= passed, but we cannot find the specs.");
              goto out_cleanup;
            }
       }
```

`alloca()` is replaced with `malloc()`/`free()`, freed explicitly at the
end of each loop iteration instead of accumulating on the stack until the
whole function returns.

## Empirical verification

Sent a real compile command with 3000 `-specs=` arguments (each pointing
at the same real, existing regular file under a configured `--sysroot`)
through a real `distccd`, with `RLIMIT_STACK` reduced to 512KB on the
daemon before it forked its workers (so the accumulation is deterministic
and fast rather than needing tens of thousands of iterations against the
default 8MB stack):

- **Pre-fix code** (the `alloca()` version, i.e. upstream's current
  logic): the worker child processing the job died partway through —
  daemon log: `(dcc_log_child_exited) ERROR: child <pid>: signal 11 (core
  dumped)`. A genuine stack-overflow crash, not a theoretical concern.
- **Post-fix code** (`malloc()`/`free()`): same 3000 arguments, same
  reduced stack limit — the worker completes the loop and the job:
  `(dcc_job_summary) ... sig:0 core:0 ... job complete`. The compile
  itself still fails for an unrelated, expected reason (the real
  compiler's own spec-file path resolution), but the daemon process
  itself no longer crashes handling the argument list.

Landed via
[wiki-mod/distcc-ng#242](https://github.com/wiki-mod/distcc-ng/pull/242).
