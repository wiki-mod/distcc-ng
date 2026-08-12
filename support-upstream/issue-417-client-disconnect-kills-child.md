# `runcmd_background()`'s shell-exec-vs-fork ambiguity is a live, general hazard beyond the one case upstream already fixed

**Fork issue:** none filed (relates to #275's TODO-triage umbrella)
**Fixed by:** [wiki-mod/distcc-ng#417](https://github.com/wiki-mod/distcc-ng/pull/417)
**Upstream location:** `test/comfychair.py`, function `runcmd_background`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-08-05)
**Searched upstream issues/PRs for:** `runcmd_background`, `killDaemon`, `children are killed off` — found distcc/distcc#129 ("`distccd --no-detach` outlives its parent process") and its fix, PR #548 ("tests: Fix `NoDetachDaemon_Case` leaving zombies around", merged 2025-10-25). Directly relevant prior art for the same root cause, but scoped narrowly to one test case, not the general helper — see below.

**Note on scope:** this entry does not report a bug in upstream's *shipped* client/server functionality. It documents a real hazard in the shared test harness (`runcmd_background()`) that upstream has already partially, but not generically, addressed — relevant to any future test (in either this fork or upstream) that needs the pid `runcmd_background()` returns to reliably identify a specific real process.

## The problem

`comfychair.py`'s `runcmd_background(cmd)` forks and execs `/bin/sh -c cmd`, returning the forked pid. Whether that shell then **exec-replaces itself** with the actual command (same pid) or instead **forks a further child** to run it (different pid) is shell-implementation-dependent and not something a caller can rely on.

Upstream's own PR #548 documents this exact ambiguity (with the identical `bash` vs. `dash` `pstree` comparison independently rediscovered for this fork's work below) and fixes it — but only for `NoDetachDaemon_Case`'s own `killDaemon()` override, by reading the daemon's real pid from its pidfile instead of trusting the pid `runcmd_background()`/`startDaemon()` returned. That fix does not touch `runcmd_background()` itself, and does not apply to a case with no pidfile to fall back to — e.g. a background-launched `distcc` **client** process (not a daemon), which is exactly what this fork's new test needed to kill reliably.

## Upstream code (unchanged as of the commit above, upstream)

```python
def runcmd_background(self, cmd):
    self.test_log = self.test_log + "Run in background:\n" + repr(cmd) + "\n"
    pid = os.fork()
    if pid == 0:
        # child
        try:
            os.execvp("/bin/sh", ["/bin/sh", "-c", cmd])
        finally:
            os._exit(127)
    self.test_log = self.test_log + "pid: %d\n" % pid
    return pid
```

No comment or caveat documents that the returned pid may be either the shell or the exec'd command, depending on the platform's `/bin/sh` implementation.

## Fixed code (changed code as of the commit from distcc-ng fork)

This fork did not change `runcmd_background()` itself (a generic fix would need to work around the ambiguity for every existing caller, a larger change than this specific test needed). Instead, the new test bypasses it entirely for the one case that actually needs pid identity guaranteed:

```python
# Fork+exec distcc directly, NOT via runcmd_background() (which runs
# "/bin/sh -c cmd"): confirmed empirically via a real CI failure that
# killing the pid runcmd_background() returns does not reliably
# disconnect the daemon's connection -- whether that shell tail-call-
# execs into distcc in place (same pid) or instead forks a further
# child for it is a shell-implementation detail this test cannot
# depend on. A direct fork()+execvp() here guarantees client_pid
# really is the distcc client itself.
saved_fallback = os.environ.get('DISTCC_FALLBACK')
os.environ['DISTCC_FALLBACK'] = '0'
try:
    client_pid = os.fork()
    if client_pid == 0:
        try:
            os.execvp("distcc", ["distcc", slow_compiler, "-c", "testtmp.i"])
        finally:
            os._exit(127)
finally:
    if saved_fallback is None:
        del os.environ['DISTCC_FALLBACK']
    else:
        os.environ['DISTCC_FALLBACK'] = saved_fallback
```

## Empirical verification

Confirmed the ambiguity is real and platform-dependent, not theoretical, via a real CI failure: a `runcmd_background()`-based version of this test's client-kill step passed on `macOS-latest` but failed identically on both `ubuntu-latest` and the bundled-popt build variant (same failure signature on both Linux runners: the daemon never logged "Client fd disconnected, killing job" within the timeout, meaning the actual `distcc` client process was never the one killed). Switching to a direct `fork()`/`execvp()` (no shell involved at all) fixed it on all three CI legs — see PR #417's CI history.

The new test itself, `ClientDisconnectKillsServerChild_Case` (`test/testdistcc.py`), covers what "children are killed off" (a header-block TODO dating to this fork's own root commit, identical to upstream's own history — see below) concretely refers to: `src/exec.c`'s `dcc_collect_child()` `select()`s on the client's own socket while waiting for the compiler child; once that read hits EOF, it logs "Client fd disconnected, killing job" and `SIGTERM`s the compiler child's process group. This exact TODO (`# TODO: Check behaviour when children are killed off.`) and its neighbor (`# TODO: Run "sleep" as a compiler, then kill the client...`) are still present, word-for-word, in upstream's own `test/testdistcc.py` at the commit checked above — both untested there too.
