# `pump`'s shutdown and startup handshakes can block/hang forever with no timeout

**Fork issue:** none filed separately
**Fixed by:** [wiki-mod/distcc-ng#7](https://github.com/wiki-mod/distcc-ng/pull/7)
**Upstream location:** `pump.in` (`ShutDown()`) and `include_server/include_server.py` (`_IncludeServerPortReady.Acquire()`)
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-17)
**Searched upstream issues/PRs for:** `pump ShutDown hang`, `include server zombie`, `IncludeServerPortReady`, `pump hangs` — no matching report or fix attempt found, open or closed.

## The problem

Two separate places in pump mode's process-lifecycle handling can block
indefinitely with no timeout at all, hanging the entire `pump`-wrapped
build if the include-server child process misbehaves:

1. **`pump.in`'s `ShutDown()`**: after sending `SIGTERM` to the include
   server, it busy-waits on `kill -0 $include_server_pid` until the process
   is gone — with no escalation to `SIGKILL` and no timeout. If the include
   server ignores or fails to act on `SIGTERM` (wedged, deadlocked, stuck in
   a syscall), this loop spins forever and `pump` never returns.
2. **`include_server/include_server.py`'s `_IncludeServerPortReady.Acquire()`**:
   the parent process blocks on a plain `os.read(self.read_fd, 1)` waiting
   for the forked include-server child to signal it has finished its own
   setup. If that child hangs during its own `_SetUp()` (rather than
   crashing, which would close the pipe and unblock the read), the parent —
   and therefore the whole `pump` invocation — blocks forever with no
   deadline.

## Upstream code (unchanged as of the commit above, upstream)

`pump.in`, `ShutDown()`:

```sh
if [ -n "$include_server_pid" ] && \
  ps -p "$include_server_pid" > /dev/null; then
  if [ "$verbose" = 1 ]; then
    echo '__________Shutting down distcc-pump include server'
  fi
  kill $include_server_pid
  # Wait until it's really dead.  We need to do this because the
  # include server may produce output after receiving SIGTERM.
  # Note that while 'sleep 0.01' is relying on a feature of GNU sleep,
  # that's OK; on systems that don't support it, it's effectively the
  # same as 'sleep 0', i.e. we'll just busy-wait rather than sleeping.
  while kill -0 $include_server_pid; do sleep 0.01; done >/dev/null 2>&1
fi
```

`include_server/include_server.py`, `_IncludeServerPortReady`:

```python
def Acquire(self):
    if os.read(self.read_fd, 1) != b'\n':
      sys.exit("Include server: _IncludeServerPortReady.Acquire failed.")
```

Neither site has any bound on how long it may wait.

## Fixed code (this fork, PR #7)

`pump.in`'s `ShutDown()` gains a bounded wait with a `SIGKILL` escalation
instead of an unbounded `kill -0` busy-wait loop, and
`include_server/include_server.py`'s `_IncludeServerPortReady.Acquire()`
gains a real deadline via `select.select(..., TIMEOUT_SECONDS)` around the
readiness-pipe read, failing closed (treating a timed-out child as failed
rather than waiting forever) instead of blocking indefinitely. The
underlying C extension (`include_server/c_extensions/distcc_pump_c_extensions_module.c`)
also gained deadline-aware `RCwdTimeout`/`RArgvTimeout` read variants used
elsewhere in the same fail-closed effort, and
`include_server/basics.py`'s `IncludeAnalyzerTimer` gained a wall-clock
quota (`REQUEST_WALL_TIME_QUOTA`) alongside its pre-existing CPU-time-only
quota, since a stalled network/filesystem read previously never tripped
any timeout at all.

Landed via [wiki-mod/distcc-ng#7](https://github.com/wiki-mod/distcc-ng/pull/7).

## Related follow-up fix (not a separate upstream entry)

A later fork PR, [wiki-mod/distcc-ng#173](https://github.com/wiki-mod/distcc-ng/pull/173)
("pump.in: detect zombie include-server process in ShutDown()"), refines
this fork's own bounded-wait `ShutDown()` (added by PR #7 above) further:
`ps -p $include_server_pid` and `kill -0 $include_server_pid` both report
"still alive" for a zombie process (exited but not yet reaped by its
parent), so a naive liveness check can misjudge a zombie as running and
waste a full wait/escalation cycle. This is not written up as a separate
upstream entry because upstream's `ShutDown()` has no bounded-wait/
`SIGKILL`-escalation structure at all for a zombie-detection refinement to
attach to (see "Upstream code" above) — the exact same unbounded `kill -0`
loop already documented in this entry is what a zombie `include_server_pid`
would also spin against forever upstream, so the fix already proposed
above (a real, bounded wait) is the relevant upstream-applicable
correction; PR #173's specific zombie-vs-alive distinction only becomes a
separate, addressable question once a bounded-wait/escalation structure
like PR #7's exists to refine.
