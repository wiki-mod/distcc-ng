# SSH transport command passed to `execvp()` without a plausibility check

**Fork issue:** [wiki-mod/distcc-ng#143](https://github.com/wiki-mod/distcc-ng/issues/143) (Group H, CodeQL `cpp/uncontrolled-process-operation`, alert #10)
**Fixed by:** [wiki-mod/distcc-ng#PR](https://github.com/wiki-mod/distcc-ng/pulls) (this PR)
**Upstream location:** `src/ssh.c`, function `dcc_ssh_connect` (feeding `dcc_run_piped_cmd`'s `execvp(argv[0], argv)`)
**Checked against upstream commit:** [`8d569d1`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-18)
**Searched upstream issues/PRs for:** `DISTCC_SSH execvp`, `uncontrolled-process-operation`, `ssh command validation` — nothing found; upstream has no CodeQL scanning and no validation of the resolved SSH command.

## Note on scope

This is **not** a vulnerability report — it is a defensive-hardening note, included
per this fork's rule 57 because the underlying code pattern is byte-for-byte live
in upstream. `src/ssh.o` is linked into the **client only** (`distcc`, not
`distccd`), so the SSH transport command runs as the invoking user, from that
user's own `$DISTCC_SSH` / host spec, with no privilege boundary crossed and no
network-controlled input. CodeQL's `cpp/uncontrolled-process-operation` flags the
`getenv("DISTCC_SSH")` → `execvp(argv[0], …)` taint flow structurally; the real
exposure is nil (a user who can set their own environment can already run any
command). The change below is robustness / error-clarity, not a security fix, and
is documented here honestly as such rather than force-fitting the "still-live
upstream bug" framing.

Note this is a **distinct** finding from
[`issue-002-ssh-distcc-env.md`](issue-002-ssh-distcc-env.md) (which is about
`strtok()` mutating the process's own `environ`): that concerns the *parsing* of
`$DISTCC_SSH`; this concerns the *absence of any sanity check on the resolved
command* before it becomes `argv[0]` to `execvp()`.

## The problem

`dcc_ssh_connect()` resolves the transport command from `$DISTCC_SSH` (tokenised
on spaces), a host-spec-supplied `ssh_cmd`, or the compiled-in default `"ssh"`, and
passes it straight through to `execvp(argv[0], argv)` with no check that the
resolved token is even a plausible command. A host-spec-supplied empty command
would reach `execvp("")`; a value like `-oProxyCommand=…` would be handed to
`execvp()` as a command name and to the spawned program as `argv[0]`. There is no
attempt to reject an obviously-malformed value before the fork/exec, so any such
failure surfaces deep inside the forked child rather than as a clean caller error.

Deliberately, an **absolute-path requirement is the wrong fix here** (unlike the
`compile.c` clang-probe path, which pre-resolves via `dcc_which()` and execs later):
`execvp()` does its own `$PATH` search **atomically at exec time**, so there is no
check-then-use (TOCTOU) window, and a bare command name like `"ssh"` relying on that
PATH search is the normal, intended usage. Forcing an absolute path would be a real
behaviour regression.

## Upstream code (unchanged as of the commit above, upstream)

`src/ssh.c`, `dcc_ssh_connect` — the resolved command goes straight to argv with no
validation:

```c
    if (!ssh_cmd)
        ssh_cmd = (char *) dcc_default_ssh;

    if (!machine) {
        rs_log_crit("no machine defined!");
        return EXIT_DISTCC_FAILED;
    }
    ...
    i = 0;
    child_argv[i++] = ssh_cmd;      /* -> execvp(argv[0], argv) in dcc_run_piped_cmd */
```

## Fixed code (changed code as of the commit from distcc-ng fork)

A `dcc_ssh_cmd_is_sane()` helper validates only the resolved command token (never
the option tokens, which legitimately begin with `-`), called after the command is
finalised and before the child argv is built / forked:

```c
static int dcc_ssh_cmd_is_sane(const char *ssh_cmd)
{
    if (!ssh_cmd || ssh_cmd[0] == '\0') {
        rs_log_error("SSH transport command is empty");
        return 0;
    }
    if (ssh_cmd[0] == '-') {
        rs_log_error("SSH transport command \"%s\" looks like an option, "
                     "not a command", ssh_cmd);
        return 0;
    }
    return 1;
}
...
    if (!ssh_cmd)
        ssh_cmd = (char *) dcc_default_ssh;

    if (!dcc_ssh_cmd_is_sane(ssh_cmd)) {
        free(ssh_cmd_buf);
        return EXIT_DISTCC_FAILED;
    }
```

A `/`-containing value (e.g. `/usr/bin/ssh`) is intentionally **not** rejected —
`execvp()` handles absolute/relative paths correctly and they are legitimate.

## Empirical verification

Exercised against the real `distcc` client binary (built with `-Werror`):

- `DISTCC_SSH="-oProxyCommand=evil" DISTCC_HOSTS="@localhost" DISTCC_FALLBACK=0 distcc gcc -c x.c`
  → rejected cleanly:
  `ERROR: SSH transport command "-oProxyCommand=evil" looks like an option, not a command`,
  then `failed to distribute and fallbacks are disabled` — no fork/exec attempted.
- `DISTCC_SSH="ssh" DISTCC_HOSTS="@host"` → unchanged: passes the check and reaches
  `dcc_ssh_connect: connecting to <host> using ssh` / `dcc_run_piped_cmd: execute: ssh <host> distccd --inetd …`.
- `DISTCC_SSH="   "` (whitespace only) → unchanged: `strtok` yields no token, falls
  back to the default `"ssh"`, not rejected.
