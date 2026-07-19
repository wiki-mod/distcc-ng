# `strtok()` on `getenv("DISTCC_SSH")` corrupts the process's own environment

**Fork issue:** none filed separately (see upstream reports below)
**Fixed by:** [wiki-mod/distcc-ng#2](https://github.com/wiki-mod/distcc-ng/pull/2)
**Upstream location:** `src/ssh.c`, function `dcc_ssh_connect()`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-17)
**Searched upstream issues/PRs for:** `DISTCC_SSH`, `strtok DISTCC_SSH`, `ssh preserve options` — found [distcc/distcc#583](https://github.com/distcc/distcc/issues/583) ("ssh: preserve DISTCC_SSH options across connections") and its apparent duplicate [distcc/distcc#590](https://github.com/distcc/distcc/issues/590) (same title) — both closed by their own reporter without a fix landing ("since it seems my efforts are not liked, i will close it"), not resolved.

## The problem

`dcc_ssh_connect()` reads the `DISTCC_SSH` environment variable and tokenizes
it in place with `strtok()`, directly on the pointer returned by `getenv()` —
without ever `strdup()`-ing it first. `strtok()` mutates the string it is
given by writing `NUL` bytes at each delimiter it finds. Since `getenv()`
does not return a copy, this corrupts the process's actual `DISTCC_SSH`
value in `environ` the first time a host is connected: only the text up to
the first space survives, and everything after the first delimiter is lost.

For a distcc client connecting to multiple hosts using SSH transport in the
same run, only the first connection sees the full `DISTCC_SSH` options —
every subsequent connection in that same process silently loses whatever
came after the first space (extra ssh flags, `-p<port>`, identity files,
etc.), with no error or warning.

## Upstream code (unchanged as of the commit above, upstream)

`src/ssh.c`, `dcc_ssh_connect()`:

```c
char *ssh_cmd_in;

/* We need to cast away constness.  I promise the strings in the argv[]
 * will not be modified. */

if (!ssh_cmd && (ssh_cmd_in = getenv("DISTCC_SSH"))) {
    ssh_cmd = strtok(ssh_cmd_in, " ");
    char *token = strtok(NULL, " ");
    while (token != NULL) {
        ssh_args[num_ssh_args++] = token;
        token = strtok(NULL, " ");
        if (num_ssh_args == MAX_SSH_ARGS)
            break;
    }
}
```

`ssh_cmd_in` is the raw `getenv()` pointer, passed straight into `strtok()`
with no `strdup()` anywhere in the function.

## Fixed code (this fork, PR #2)

```c
char *ssh_cmd_buf = NULL;
char *ssh_cmd_in;

if (!ssh_cmd && (ssh_cmd_in = getenv("DISTCC_SSH"))) {
    ssh_cmd_buf = strdup(ssh_cmd_in);
    if (!ssh_cmd_buf) {
        rs_log_crit("failed to duplicate DISTCC_SSH");
        return EXIT_OUT_OF_MEMORY;
    }
    ssh_cmd_in = ssh_cmd_buf;
    ssh_cmd = strtok(ssh_cmd_in, " ");
    char *token = strtok(NULL, " ");
    while (token != NULL) {
        ssh_args[num_ssh_args++] = token;
        token = strtok(NULL, " ");
        if (num_ssh_args == MAX_SSH_ARGS)
            break;
    }
}
...
ret = dcc_run_piped_cmd(child_argv, f_in, f_out, ssh_pid);
free(ssh_cmd_buf);
```

`strtok()` now operates on a heap `strdup()` of the environment value,
freed after use, so the real `DISTCC_SSH` in `environ` is never mutated. A
new regression test (`SecureShellCommandEnvironment_Case` in
`test/testdistcc.py`, backed by a new `h_ssh` test harness in
`src/h_ssh.c`) calls `dcc_ssh_connect()` twice in the same process and
asserts the second call still sees the full, unmangled `DISTCC_SSH` value.

Landed via [wiki-mod/distcc-ng#2](https://github.com/wiki-mod/distcc-ng/pull/2).
