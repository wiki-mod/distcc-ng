#! /usr/bin/env python3

# Copyright 2026 distcc contributors
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.

"""Regression test for pump --shutdown's pre-SIGTERM pid-identity check.

pump --startup and pump --shutdown are two independent process
invocations, connected only by $INCLUDE_SERVER_PID passed through the
environment (see pump.in's Main(), --startup/--shutdown case arms).
Arbitrary wall-clock time can pass between the two -- long enough for the
real include server to exit and its pid to be recycled by an unrelated
process, which ShutDown() must not then signal. This test does not rely on
forcing real OS pid recycling (not reliably controllable from a test);
instead it hands pump --shutdown the pid of an unrelated, real, running
process directly, which exercises IncludeServerPidLooksRight()'s identity
check the same way a genuinely recycled pid would.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import time


def Main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: pump_shutdown_pid_identity_test.py PUMP")

    pump = sys.argv[1]
    tempdir = tempfile.mkdtemp(prefix="distcc-pump-shutdown-test.")
    unrelated = subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(60)"])
    try:
        # Give the unrelated process a moment to actually be running before
        # pointing pump --shutdown at its pid.
        time.sleep(0.2)

        env = os.environ.copy()
        env["INCLUDE_SERVER_PID"] = str(unrelated.pid)
        env["INCLUDE_SERVER_DIR"] = tempdir

        process = subprocess.run(
            [pump, "--shutdown"], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True, timeout=30)

        if process.returncode != 0:
            raise AssertionError(
                "pump --shutdown exited %d\nstdout:\n%s\nstderr:\n%s" %
                (process.returncode, process.stdout, process.stderr))

        # The unrelated process must survive: ShutDown() must not have sent
        # it SIGTERM (or SIGKILL) merely because its pid happened to be
        # alive -- it does not look like the include server.
        time.sleep(0.5)
        if unrelated.poll() is not None:
            raise AssertionError(
                "pump --shutdown signaled an unrelated, non-include-server "
                "process instead of rejecting its pid; stderr:\n%s" %
                process.stderr)

        if "no longer looks like the include server" not in process.stderr:
            raise AssertionError(
                "pump --shutdown did not report skipping the unrelated "
                "pid; stderr:\n%s" % process.stderr)
    finally:
        if unrelated.poll() is None:
            unrelated.terminate()
            try:
                unrelated.wait(timeout=5)
            except subprocess.TimeoutExpired:
                unrelated.kill()
                unrelated.wait()
        shutil.rmtree(tempdir, ignore_errors=True)


if __name__ == "__main__":
    Main()
