# Bare `os.wait()` in the test harness's `killDaemon()` can reap the wrong child process

**Fork issue:** none filed separately
**Fixed by:** [wiki-mod/distcc-ng#8](https://github.com/wiki-mod/distcc-ng/pull/8)
**Upstream location:** `test/testdistcc.py`, `NoDetachDaemon_Case.killDaemon()`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-17)

## The problem

`NoDetachDaemon_Case.killDaemon()` sends `SIGTERM` to the daemon and then
calls the bare, global `os.wait()` to reap it. `os.wait()` reaps *any*
exited child of the calling test process, not necessarily the specific
daemon child being torn down — if any other subprocess (a previous test's
leftover child, a different concurrently-running helper) happens to exit
around the same time, `os.wait()` can return that unrelated pid instead.
The very next line, `self.assert_equal(self.pid, pid)`, then either
spuriously fails the test (a false test failure unrelated to the daemon
under test) or, if the assertion is weak/skipped, silently leaves the
actual daemon child unreaped as a zombie. This is a genuine test-isolation
flakiness bug in the shared test harness, not just a fork-local test
detail — the daemon-startup path this function pairs with
(`startDaemon()`) even carries its own long-standing, still-unaddressed
`FIXME` about port-reuse races in the identical upstream source.

## Upstream code (unchanged as of the commit above, upstream)

`test/testdistcc.py`, `NoDetachDaemon_Case`:

```python
class NoDetachDaemon_Case(CompileHello_Case):
    """Test the --no-detach option."""
    def startDaemon(self):
        # FIXME: This  does not work well if it happens to get the same
        # port as an existing server, because we can't catch the error.
        cmd = (self.distccd() +
               "--no-detach --daemon --verbose --log-file %s --pid-file %s "
               "--port %d --allow 127.0.0.1 --enable-tcp-insecure --sysroot %s" %
               (_ShellSafe(self.daemon_logfile),
                _ShellSafe(self.daemon_pidfile),
                self.server_port,
                _ShellSafe(self.daemon_sysroot)))
        self.pid = self.runcmd_background(cmd)
        self.add_cleanup(self.killDaemon)
        # Wait until the server is ready for connections.
        time.sleep(0.2)   # Give distccd chance to start listening on the port
        sock = socket.socket()
        while sock.connect_ex(('127.0.0.1', self.server_port)) != 0:
            time.sleep(0.2)
    ...

    def killDaemon(self):
        # Terminate the process specified by the pidfile.  That should kill
        # the distccd process, any child distccd processes and the shell
        # process used to launch distccd.
        daemon_pid = int(open(self.daemon_pidfile, 'rt').read())
        os.kill(daemon_pid, signal.SIGTERM)

        pid, ret = os.wait()
        self.assert_equal(self.pid, pid)
```

The still-live `FIXME` about port-reuse races sits directly above the same
`killDaemon()`/`startDaemon()` pairing, unaddressed; `os.wait()` reaps
whichever child happens to exit, not specifically `self.pid`.

## Fixed code (this fork, PR #8)

```python
def killDaemon(self):
    try:
        daemon_pid = int(open(self.daemon_pidfile, 'rt').read())
    except IOError:
        try:
            os.kill(self.pid, signal.SIGTERM)
            os.waitpid(self.pid, 0)
        except OSError:
            pass
        return
    os.kill(daemon_pid, signal.SIGTERM)

    pid, ret = os.waitpid(self.pid, 0)
```

`os.wait()` is replaced with `os.waitpid(self.pid, 0)`, which only reaps
the specific tracked child, removing the race with any other exiting
subprocess in the same test process. The fork's PR also hardened
`startDaemon()`'s readiness/retry loop more broadly (deadline-bounded
retries, distinguishing an actual startup failure from a not-yet-ready
daemon), but the `os.wait()` → `os.waitpid()` fix in `killDaemon()` is the
part directly mirrored by this entry, since that specific pattern is what
is still live, unchanged, in upstream's current source.

Landed via [wiki-mod/distcc-ng#8](https://github.com/wiki-mod/distcc-ng/pull/8).
