# `pump.in`'s `ShutDown()` never sends SIGTERM when `ps -p` isn't supported (e.g. BusyBox)

**Fork issue:** [wiki-mod/distcc-ng#398](https://github.com/wiki-mod/distcc-ng/issues/398)
**Fixed by:** [wiki-mod/distcc-ng#400](https://github.com/wiki-mod/distcc-ng/pull/400)
**Upstream location:** `pump.in`, function `ShutDown`, line 363
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-08-01)
**Searched upstream issues/PRs for:** `ps -p`, `busybox`, `pump shutdown`, `include_server hang`, `zombie` -- no matching report or fix attempt found for this exact `ps -p` dependency. Issue [#284](https://github.com/distcc/distcc/issues/284) ("`Shutting down distcc-pump include server` blocks indefinitely", closed) describes a similarly-shaped shutdown hang, but its symptom is the `while kill -0 $pid; do sleep 0.01; done` wait loop never terminating, not `ps -p` itself failing -- a different root cause, not a prior report of this issue.

## The problem

`ShutDown()`'s guard for whether to `kill` the include server depends
unconditionally on `ps -p PID` succeeding. BusyBox's `ps` applet (Alpine
Linux's default `/bin/sh` userland, and other minimal/embedded musl
distributions) does not implement `-p` at all -- it fails unconditionally
with `ps: unrecognized option: p`, regardless of whether the pid is alive.
So on any BusyBox-based system, the guard's `if` is always false, and the
include server (a resident-by-design process, forked to keep serving
header analysis across the build) never receives `kill`. It runs forever
as an orphan, holding open whatever stdout/stderr it inherited from the
invoking process -- hanging any caller that reads `pump`'s output through
a pipe (e.g. `subprocess.Popen(..., stdout=PIPE).communicate()`, or any
shell pipeline capturing `pump`'s output).

## Upstream code (unchanged as of the commit above, upstream)

```sh
ShutDown() {
  ReportDiscrepancies
  # Always -- at exit -- shut down include_server and remove $socket_dir
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

## Fixed code (changed code as of the commit from distcc-ng fork)

```sh
IsPositivePid() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 0 ] 2>/dev/null
}

IncludeServerAlive() {
  if ! IsPositivePid "$1"; then
    return 1
  fi
  if ! kill -0 "$1" 2>/dev/null; then
    return 1
  fi
  if [ -r "/proc/$1/stat" ]; then
    state=`ProcState "$1"`
  else
    state=`ps -o state= -p "$1" 2>/dev/null | tr -d '[:space:]'`
  fi
  case "$state" in
    Z*) return 1 ;;
    *) return 0 ;;
  esac
}

# ... in ShutDown():
  if [ -n "$include_server_pid" ] && \
    IncludeServerAlive "$include_server_pid"; then
    ...
    kill "$include_server_pid"
    ...
    while IncludeServerAlive "$include_server_pid"; do ... done
    if IncludeServerAlive "$include_server_pid"; then
      if IncludeServerPidLooksRight "$include_server_pid"; then
        kill -9 "$include_server_pid"
      fi
    fi
  fi
```

The base alive/dead check is now `kill -0` (POSIX-standard, works
identically under BusyBox), not `ps -p`. A zombie-state refinement
(`IncludeServerAlive`'s `Z*` check, reading `/proc/$pid/stat` directly via
`ProcState()` when available, falling back to `ps -o state= -p` on
non-Linux) prevents a zombied include server from being misreported alive
for the full wait timeout. A new `IncludeServerPidLooksRight()` helper
(reading `/proc/$pid/cmdline`, or a `ps`-row-count-aware fallback when
`/proc` is unavailable) guards the unrecoverable SIGKILL escalation
against a stale/recycled pid.

Landed via [wiki-mod/distcc-ng#400](https://github.com/wiki-mod/distcc-ng/pull/400).

## Empirical verification

Reproduced and verified against real, live containers -- not just a
source read:

- **Original hang**: `test/pump_include_server_path_test.py` run against
  the unfixed code in a real Alpine 3.20 container (BusyBox `ps`) hangs
  indefinitely; the same test against the same unfixed source in a real
  Debian 13 container (GNU/procps `ps`) completes in under 200ms.
  `strace`/`/proc/<pid>/wchan` inspection on Alpine confirmed the include
  server sits in `clock_nanosleep` forever, never receiving `SIGTERM`,
  while the test blocks in `read()` on its inherited output pipe.
- **Fixed behavior**: the same test against the fixed code completes in
  ~0.2s on both Alpine 3.20 and Debian 13, with no lingering processes on
  either platform afterward (confirmed via `ps aux`).
- **Zombie-detection fix**: created a deterministic zombie in a real
  Alpine 3.20 container (a subshell `exec`s into `sleep` so it never
  reaps its own already-exited child) and confirmed directly that the old
  `ps -o state= -p`-only logic reports it "alive" (the bug: `ps -o state=
  -p` fails with `unrecognized option: p` on BusyBox, and `kill -0`
  succeeds on a zombie), while the fixed `ProcState()`-based logic
  correctly reports it not-alive.
- **PID-identity-fallback fix**: confirmed in a real Alpine 3.20 container
  that `ps -p PID -o args=` (the original non-`/proc` fallback) fails
  outright on BusyBox, and that a plain unadorned `ps` succeeds and can be
  grepped by pid instead. Further confirmed, after `umount /proc` inside
  the same container (simulating a Linux system with no procfs at all),
  that even plain `ps` degrades to a header-only, zero-row listing on this
  BusyBox build (exit 0, not an error) -- so the fix additionally counts
  data rows in `ps`'s own output rather than trusting a "no match" result
  when no process information is available at all.

## Upstream status

Still present in upstream's live source (`distcc/distcc`, `pump.in` line
363, checked 2026-08-01). Not reported upstream (per this fork's read-only
upstream policy) -- filed here as passive reference only.
