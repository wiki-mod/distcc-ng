#!/bin/bash
# Runtime self-test for the distcc-ng-verify image's ptrace-dependent tools
# (gdb, strace, ltrace).
#
# WHY this is a separate script instead of living in the Dockerfile: `docker
# build`'s RUN steps execute without CAP_SYS_PTRACE and the default seccomp
# profile denies ptrace(2) regardless of image content, so gdb/strace/ltrace
# cannot actually attach to or trace anything at image-build time -- only
# --version-style existence checks are possible there (see the Dockerfile's
# self-test RUN step). A real functional proof needs a *running* container
# started with ptrace capability, which only `docker run` can grant. This
# script is that real functional proof; run it once per built image as part
# of verification (not part of the image itself, so the image stays minimal
# and this can be re-run against an already-built image without a rebuild):
#
#   docker run --rm --cap-add=SYS_PTRACE \
#     -v "$(pwd)/docker/verify:/verify:ro" \
#     <image> bash /verify/selftest-ptrace.sh
#
set -euo pipefail

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
cd "${work}"

echo 'int main(void) { return 0; }' > ok.c
gcc -g -O0 ok.c -o ok_gcc

# --- gdb: must actually hit a real breakpoint via a real ptrace attach ---
gdb -q -batch -ex 'break main' -ex run -ex continue ./ok_gcc > gdb.log 2>&1 || true
grep -q 'Breakpoint 1' gdb.log \
  || { echo "ERROR: gdb did not hit the breakpoint"; cat gdb.log; exit 1; }
echo "OK: gdb hit a real breakpoint"

# --- strace: must actually trace a real syscall ---
strace -f -e trace=execve ./ok_gcc > strace.log 2>&1 || true
grep -q '+++ exited with 0 +++' strace.log \
  || { echo "ERROR: strace did not report the traced process's exit"; cat strace.log; exit 1; }
echo "OK: strace traced a real process exit"

# --- ltrace: must actually trace a real library call ---
printf '%s\n' \
  '#include <stdlib.h>' \
  'int main(void) { free(malloc(1)); return 0; }' \
  > ltrace_target.c
gcc -g -O0 -o ltrace_target ltrace_target.c
ltrace -e 'malloc+free' ./ltrace_target > ltrace.log 2>&1 || true
grep -q 'malloc' ltrace.log \
  || { echo "ERROR: ltrace did not trace the expected library call"; cat ltrace.log; exit 1; }
echo "OK: ltrace traced a real library call"

# --- python3-dbg + gdb's py-bt: must show a real Python-level backtrace,
#     not just exist -- proves gdb's bundled python3-gdb.py auto-load
#     actually works against this image's python3-dbg build, for
#     debugging the include_server (a Python program) and its C extension
#     together.
#
#     gdb must launch python3-dbg as its OWN child (like the gdb/strace/
#     ltrace tests above), not attach to an already-running sibling
#     process via `gdb -p <pid>`: an earlier version of this test did the
#     latter and failed with "ptrace: Operation not permitted" even with
#     --cap-add=SYS_PTRACE, since Yama's default ptrace_scope=1 only
#     allows a process to attach to its own descendants (or requires the
#     tracer to actually hold an effective CAP_SYS_PTRACE, which a
#     non-root container user doesn't automatically get from `docker
#     run --cap-add` alone) -- a sibling launched independently via `&`
#     in the same shell is not a descendant of gdb itself. Breaking on
#     CPython's own `time_sleep` C function (Modules/timemodule.c) and
#     letting gdb `run` the target itself sidesteps this entirely, the
#     same "trace your own child" shape that already works below. ---
printf '%s\n' \
  'import time' \
  'def target_function():' \
  '    time.sleep(5)' \
  'target_function()' \
  > py_target.py
gdb -q -batch -ex 'break time_sleep' -ex run -ex 'py-bt' \
  --args python3-dbg py_target.py > py-bt.log 2>&1 || true
grep -q 'target_function' py-bt.log \
  || { echo "ERROR: gdb py-bt did not show the real Python frame target_function"; cat py-bt.log; exit 1; }
echo "OK: gdb py-bt showed a real Python-level backtrace"

echo "All ptrace-dependent tool self-tests passed."
