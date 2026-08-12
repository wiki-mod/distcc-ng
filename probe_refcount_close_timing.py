#!/usr/bin/env python3
"""Investigation for wiki-mod/distcc-ng PR #466's review question: is the
"open(...).write(...) with no explicit close, read back by a subprocess"
pattern actually reproducibly broken on some Python, or only a theoretical
risk on CPython? Two independent checks, run against whichever Python
interpreter this script is invoked with.

Not part of the actual fix -- a throwaway investigation script on a
disposable probe branch, not intended to be merged.
"""
import subprocess
import sys
import tempfile
import os
import weakref


def mechanistic_check():
    """Directly observes *when* the file object's finalizer (which flushes
    and closes it) actually runs relative to the statement after it, using
    a weakref finalizer callback as a tripwire. This is not probabilistic --
    it demonstrates the actual object-lifetime mechanism the "relies on
    refcounting" claim is about.
    """
    order = []
    path = tempfile.mktemp()
    try:
        def unsafe_write():
            f = open(path, "wt")
            weakref.finalize(f, lambda: order.append("finalized"))
            f.write("hello")
            order.append("write-returned")
            # `f`'s only reference is this local variable; it goes out of
            # scope when this function returns.

        unsafe_write()
        order.append("after-unsafe-write-returned")
        print("mechanistic order of events:", order)
        immediate = order == ["write-returned", "finalized", "after-unsafe-write-returned"]
        print("finalize-before-next-statement:", immediate)
        return immediate
    finally:
        try:
            os.remove(path)
        except OSError:
            pass


def stress_check(iterations):
    """Empirically repeats the actual bug pattern (write with no explicit
    close, then a real *separate subprocess* reads the same path back) many
    times, and checks the subprocess always sees the complete content.
    """
    failures = 0
    with tempfile.TemporaryDirectory() as tmpdir:
        for i in range(iterations):
            path = os.path.join(tmpdir, "probe_%d.txt" % i)
            content = ("line-%06d\n" % i) * 400  # ~4KB, larger than a single write() syscall buffer on some platforms
            # The exact flagged pattern: open(...).write(...), no `with`, no explicit close.
            open(path, "wt").write(content)
            result = subprocess.run(
                [sys.executable, "-c",
                 "import sys; sys.stdout.write(open(sys.argv[1]).read())", path],
                capture_output=True, text=True)
            if result.stdout != content:
                failures += 1
                print("FAIL at iteration %d: expected %d bytes, subprocess read %d bytes"
                      % (i, len(content), len(result.stdout)))
    print("stress check: %d/%d iterations matched" % (iterations - failures, iterations))
    return failures == 0


def main():
    print("Python implementation:", sys.implementation.name, sys.version)
    mech_ok = mechanistic_check()
    stress_ok = stress_check(int(sys.argv[1]) if len(sys.argv) > 1 else 3000)
    print("RESULT implementation=%s mechanistic_immediate_close=%s stress_all_passed=%s"
          % (sys.implementation.name, mech_ok, stress_ok))


if __name__ == "__main__":
    main()
