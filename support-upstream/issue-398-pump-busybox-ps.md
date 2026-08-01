# `pump.in`'s `ShutDown()` never fires when `ps -p` isn't supported (e.g. BusyBox)

## Upstream location

`pump.in`, `ShutDown()`:

```sh
ShutDown() {
  ReportDiscrepancies
  # Always -- at exit -- shut down include_server and remove $socket_dir
  if [ -n "$include_server_pid" ] && \
    ps -p "$include_server_pid" > /dev/null; then
    ...
    kill $include_server_pid
    ...
  fi
}
```

## The bug

`ps -p PID` is not implemented by BusyBox's `ps` applet (Alpine Linux's
default `/bin/sh` userland, and other minimal/embedded distributions) --
it fails unconditionally with `ps: unrecognized option: p`, regardless of
whether the pid is alive. So on any BusyBox-based system, the `ps -p`
check above always fails, the `if` is always false, and the include
server (a resident-by-design process, forked to keep serving header
analysis across the build) never receives `kill`. It runs forever as an
orphan, holding open whatever stdout/stderr it inherited from the
invoking process -- hanging any caller that reads `pump`'s output
through a pipe (e.g. `subprocess.Popen(..., stdout=PIPE).communicate()`,
or any shell pipeline capturing `pump`'s output).

## How this was found

distcc-ng's own fork (this repo) hardened this same function further in
an earlier fix (adding zombie-state detection for a Cygwin `ps -p`
gap, unrelated to this issue), which is where the `IncludeServerAlive()`
helper this bug was found in originates -- but the underlying `ps -p`
reliance traces directly back to upstream's own `ShutDown()` above,
which has the identical unconditional dependency on `ps -p` working.

Confirmed via a real, live reproduction: building and running
`test/pump_include_server_path_test.py` in a real Alpine 3.20 container
(BusyBox `ps`) hangs indefinitely; the same test in a real Debian 13
container (GNU/procps `ps`) completes in under 200ms. `strace`/`/proc`
inspection confirmed the include server sits in `clock_nanosleep`
forever, never receiving `SIGTERM`, while the test blocks in `read()` on
its inherited output pipe.

## Fix applied in this fork

Replaced the `ps -p` check with `kill -0 "$pid" 2>/dev/null` -- POSIX-
standard, works identically under BusyBox, no `ps` dependency at all for
the basic "is this pid alive" question. See `wiki-mod/distcc-ng` PR #400.

## Upstream status

Still present in upstream's live source (`distcc/distcc`, `pump.in`,
checked 2026-08-01). Not reported upstream (per this fork's read-only
upstream policy) -- filed here as passive reference only.
