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

echo "All ptrace-dependent tool self-tests passed."
