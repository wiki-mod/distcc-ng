# Test daemon's `--lifetime` alarm can kill it mid-test on a slow/loaded runner, racing normal teardown

**Fork issue:** [wiki-mod/distcc-ng#379](https://github.com/wiki-mod/distcc-ng/issues/379)
**Fixed by:** [wiki-mod/distcc-ng#415](https://github.com/wiki-mod/distcc-ng/pull/415)
**Upstream location:** `test/testdistcc.py`, `WithDaemon_Case.daemon_lifetime()` and its per-case overrides (`HundredFold_Case`, `Concurrent_Case`, `BigAssFile_Case`)
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-08-05)
**Searched upstream issues/PRs for:** `lifetime daemon`, `opt_lifetime`, `killDaemon` — found distcc/distcc#129/PR #548 (a related but different test-harness timing/zombie issue, documented separately in `issue-417-client-disconnect-kills-child.md`). No report matching this specific `--lifetime`-races-teardown symptom found.

## The problem

`WithDaemon_Case.daemon_lifetime()` (default 60s, `HundredFold_Case`/`Concurrent_Case` 120s, `BigAssFile_Case` 300s) sets the value passed to `distccd --lifetime=N`, which installs a hard `alarm()` (`dcc_set_lifetime()` in `src/daemon.c`) that kills the daemon once it expires — **regardless of whether a test is still using it**.

The real teardown mechanism is separate and already correct: `killDaemon()` sends a real `SIGTERM` to the daemon and polls until it exits, at the end of every test (pass or fail). The `--lifetime` alarm was not meant to compete with that — but on a slow or loaded CI runner, a test can legitimately take longer than the guessed timeout, so the daemon gets killed by its own alarm mid-test, before `killDaemon()`'s own teardown ever runs. This is an intermittent, load-dependent failure: it does not reproduce reliably on a single run, which is exactly why it can go unnoticed for a long time.

## Upstream code (unchanged as of the commit above, upstream)

```python
def daemon_lifetime(self):
    # Enough for most tests, even on a fairly loaded machine.
    # Might need more for long-running tests.
    return 60
```

with `HundredFold_Case`/`Concurrent_Case` overriding to `120`, and `BigAssFile_Case` to `300` — identical values to this fork's own pre-fix state.

## Fixed code (changed code as of the commit from distcc-ng fork)

```python
def daemon_lifetime(self):
    # This is a leak-safety net, not the normal teardown mechanism --
    # killDaemon() (above) already sends a real SIGTERM and waits for
    # the process to go away at the end of every test, on both the
    # pass and fail path. This alarm exists only to stop an orphaned
    # daemon from running forever in the abnormal case where teardown
    # itself never runs at all (e.g. the test process itself is
    # killed/crashes before reaching teardown). Set generously (5x the
    # original values) so it never races a normal, still-running test
    # on a slow/loaded CI runner.
    return 300
```

All four values (default and the three per-case overrides) raised 5x across the board: 60s/120s/120s/300s → 300s/600s/600s/1500s. `BigAssFile_Case`'s new 1500s value stays comfortably under this fork's own `c-build.yml` 15-minute `make_check` job timeout, so even a genuine leak (teardown never running at all) is still caught inside the job's own window rather than only by the runner being torn down at the job timeout.

## Empirical verification

This is a test-harness timing fix for an intermittent, load-dependent failure — a single green CI run is not strong evidence on its own (the bug is that it *usually* doesn't reproduce). The change itself is a low-risk numeric adjustment with no behavioral change to the daemon or client. Verified via real GitHub Actions CI (`make_check`, both `ubuntu-latest` and `macOS-latest`, plus the bundled-popt build variant and the gcov coverage job) all passing after the change — see PR #415.
