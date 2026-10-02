#! /usr/bin/env python3
# coding=utf-8

# Copyright (C) 2002, 2003, 2004 by Martin Pool <mbp@samba.org>
# Copyright 2007 Google Inc.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,
# USA.

# What: distcc test suite on comfychair; PATH picks binaries.
# Why: --valgrind, --lzo, --zstd, --pump vary each run.

# What: Test classes nest: daemon, compile, and so on.
# Why: One instance is one run; bases offer callable helpers.

# What: No test runs the suite under malloc debugging.
# Why: A dev convenience with no automatable coverage gap.
# From: Issue #275

# What: No test sends daemon output through syslogd.
# Why: rs_logger_syslog() is hardwired to /dev/log in trace.c.
# From: Issue #275

# What: No test varies hostspecs for argument scanning.
# Why: dcc_scan_args() never sees a hostspec; result is fixed.
# From: Issue #275

# What: No test yet checks temp cleanup without SAVE_TEMPS.
# Why: Leaked temporary files remain an untested gap.

# What: No test redirects the suite's own stdout/stderr.
# Why: comfychair's run_captured() logs both per command.
# From: Issue #275

# What: No standalone bulk.c harness; compiles cover it.
# Why: bulk.c has no h_* helper; every compile moves files.
# From: Issue #275

# What: HostSelectionAlgorithm_Case covers host selection.
# Why: dcc_lock_one() picks hosts in list order per slot.
# From: Issue #275

# What: AutogroupNicenessPrivilegeDrop_Case covers --user.
# Why: CI runners have real root, so the drop can be tested.

import time, sys, os, glob, re, socket, errno
import signal, os.path, pwd, tempfile, shutil
import comfychair

from stat import *

EXIT_DISTCC_FAILED           = 100
EXIT_BAD_ARGUMENTS           = 101
EXIT_BIND_FAILED             = 102
EXIT_CONNECT_FAILED          = 103
EXIT_COMPILER_CRASHED        = 104
EXIT_OUT_OF_MEMORY           = 105
EXIT_BAD_HOSTSPEC            = 106
EXIT_COMPILER_MISSING        = 110
EXIT_RECURSION               = 111
EXIT_ACCESS_DENIED           = 113

DISTCC_TEST_PORT             = 42000

# What: Full path of the compiler under test.
# Why: Set once by initCompiler from PATH.
_cc                          = None
# What: Prefix command such as "valgrind --quiet ".
# Why: --valgrind wraps every program the suite starts.
_valgrind_command            = ""
# What: Host options for the server: "", ",lzo" or ",lzo,cpp".
# Why: One suite covers plain, compressed and pump modes.
_server_options              = ""

# What: Quote s so the shell reads it literally.
# Why: Paths go into shell command lines unescaped otherwise.
def _ShellSafe(s):
    return "'" + s.replace("'", "'\"'\"'") + "'"

# What: Return the first count bytes of a file.
# Why: Some tests only apply to certain object formats.
def _FirstBytes(filename, count):
    f = open(filename, 'rb')
    try:
        return f.read(count)
    finally:
        f.close()

# What: True if the file starts with the ELF magic number.
# Why: Magic from /usr/share/file/magic, not the extension.
def _IsElf(filename):
    contents = _FirstBytes(filename, 5)
    return contents.startswith(b'\177ELF')

# What: True if the file starts with a Mach-O magic number.
# Why: Masked BE/LE feedface forms are Mach-O too, per magic.
def _IsMachO(filename):
    contents = _FirstBytes(filename, 10)
    return (contents.startswith(b'\xCA\xFE\xBA\xBE') or
            contents.startswith(b'\xFE\xED\xFA\xCE') or
            contents.startswith(b'\xCE\xFA\xED\xFE') or
            contents.startswith(b'\xFF\xED\xFA\xCE') or
            contents.startswith(b'\xCE\xFA\xED\xFF'))

# What: True if the file starts with the PE magic "MZ".
# Why: Magic from /usr/share/file/magic, not the extension.
def _IsPE(filename):
    contents = _FirstBytes(filename, 5)
    return contents.startswith(b'MZ')

# What: Update a file's times, creating it if missing.
# Why: Tests need fresh mtimes without rewriting content.
def _Touch(filename):
    f = open(filename, 'a')
    try:
        os.utime(filename, None)
    finally:
        f.close()


# What: Abstract base class for distcc tests.
# Why: Every case needs a clean env and a known compiler.
class SimpleDistCC_Case(comfychair.TestCase):
    # What: Strip DISTCC_* from the env and pick the compiler.
    # Why: Runs before every test of every subclass.
    def setup(self):
        self.stripEnvironment()
        self.initCompiler()

    # What: Store the compiler under test in self._cc.
    # Why: cc may be gcc or clang; tests need the real one.
    def initCompiler(self):
        self._cc = self._get_compiler()

    # What: Drop DISTCC_* vars; point TMPDIR, DISTCC_DIR here.
    # Why: The developer's own environment must not leak in.
    def stripEnvironment(self):
        for key in list(os.environ.keys()):
            if key[:7] == 'DISTCC_':
                del os.environ[key]
        os.environ['TMPDIR'] = self.tmpdir
        ddir = os.path.join(self.tmpdir, 'distccdir')
        os.mkdir(ddir)
        os.environ['DISTCC_DIR'] = ddir

    # What: Return the valgrind prefix for commands.
    # Why: Empty unless the suite runs with --valgrind.
    def valgrind(self):
        return _valgrind_command;

    # What: Return the distcc command line prefix.
    # Why: Pump mode needs the testing include-server hook.
    def distcc(self):
        if "cpp" not in _server_options:
            return self.valgrind() + "distcc "
        else:
            return "DISTCC_TESTING_INCLUDE_SERVER=1 " + self.valgrind() + "distcc "


    # What: Return the distccd command line prefix.
    # Why: The daemon runs under the same valgrind prefix.
    def distccd(self):
        return self.valgrind() + "distccd "

    # What: Return distcc with local fallback enabled.
    # Why: Some cases test the fall-back-to-local path.
    def distcc_with_fallback(self):
        return "DISTCC_FALLBACK=1 " + self.distcc()

    # What: Return distcc with local fallback disabled.
    # Why: Remote failures must surface instead of hiding.
    def distcc_without_fallback(self):
        return "DISTCC_FALLBACK=0 " + self.distcc()

    # What: Return the clang or gcc path behind "cc".
    # Why: Tests branch on compiler family; unknown fails.
    def _get_compiler(self):
        cc = self._find_compiler("cc")
        if self.is_clang(cc):
            return self._find_compiler("clang")
        elif self.is_gcc(cc):
            return self._find_compiler("gcc")
        raise AssertionError("Unknown compiler")

    # What: Return the first PATH entry holding compiler.
    # Why: Tests need the binary a shell would run for it.
    def _find_compiler(self, compiler):
        for path in os.environ['PATH'].split (':'):
            abs_path = os.path.join (path, compiler)

            if os.path.isfile (abs_path):
                return abs_path
        return None

    # What: True if compiler --version names the FSF.
    # Why: gcc identifies itself by its copyright line.
    def is_gcc(self, compiler):
        out, err = self.runcmd(compiler + " --version")
        if re.search('Free Software Foundation', out):
            return True
        return False

    # What: True if compiler --version mentions clang.
    # Why: Apple's cc is clang under another name.
    def is_clang(self, compiler):
        out, err = self.runcmd(compiler + " --version")
        if re.search('clang', out):
            return True
        return False


# What: Start a daemon, then run commands locally against it.
# Why: distccd detaches only once bound, so clients can go.
class WithDaemon_Case(SimpleDistCC_Case):

    # What: Set daemon paths and port, start it, set client env.
    # Why: Every daemon test needs the same fixture order.
    def setup(self):
        SimpleDistCC_Case.setup(self)
        self.daemon_pidfile = os.path.join(os.getcwd(), "daemonpid.tmp")
        self.daemon_logfile = os.path.join(os.getcwd(), "distccd.log")
        self.daemon_sysroot = os.getcwd()
        self.server_port = DISTCC_TEST_PORT
        self.startDaemon()
        self.setupEnv()

    # What: Point DISTCC_HOSTS, DISTCC_LOG at this daemon.
    # Why: The client must reach the test daemon and log it.
    def setupEnv(self):
        os.environ['DISTCC_HOSTS'] = ('127.0.0.1:%d%s' %
          (self.server_port, _server_options))
        os.environ['DISTCC_LOG'] = os.path.join(os.getcwd(), 'distcc.log')
        os.environ['DISTCC_VERBOSE'] = '1'


    # What: Run the base teardown.
    # Why: Cleanups registered in setup stop the daemon.
    def teardown(self):
        SimpleDistCC_Case.teardown(self)

    # What: Poll a log for pattern; fail with it after timeout.
    # Why: A forked child may log after the next step began.
    # From: Issue #379
    def waitForLogPattern(self, pattern, timeout, logfile=None):
        if logfile is None:
            logfile = self.daemon_logfile
        deadline = time.time() + timeout
        log_contents = ""
        while True:
            try:
                with open(logfile, 'rt') as f:
                    log_contents = f.read()
            except IOError:
                log_contents = ""
            if re.search(pattern, log_contents) is not None:
                return log_contents
            if time.time() > deadline:
                self.fail(
                    "timed out after %ds waiting for %r in the daemon log, "
                    "got:\n%s" % (timeout, pattern, log_contents))
            time.sleep(0.2)


    # What: SIGTERM the daemon from its pidfile, wait it out.
    # Why: No pidfile means it exited; never signal a reused pid.
    def killDaemon(self):
        try:
            with open(self.daemon_pidfile, 'rt') as f:
                pid = int(f.read())
        except IOError:
            return
        os.kill(pid, signal.SIGTERM)

        # What: Probe the pid with signal 0 until it is gone.
        # Why: The daemon detached, so it cannot be waited on.
        while 1:
            try:
                os.kill(pid, 0)
            except OSError:
                break
            time.sleep(0.2)


    # What: Return the distccd command line for this test.
    # Why: Subclasses override it to add or change options.
    def daemon_command(self):
        return (self.distccd() +
                "--verbose --lifetime=%d --daemon --log-file %s "
                "--pid-file %s --port %d --allow 127.0.0.1 --enable-tcp-insecure "
		"--sysroot %s"
                % (self.daemon_lifetime(),
                   _ShellSafe(self.daemon_logfile),
                   _ShellSafe(self.daemon_pidfile),
                   self.server_port,
                   _ShellSafe(self.daemon_sysroot)))

    # What: Daemon --lifetime: 300s leak-safety net.
    # Why: Only stops orphans; 60s once killed a live test.
    # From: Issue #379
    def daemon_lifetime(self):
        return 300

    # What: Start distccd in ./daemon, retrying the next port.
    # Why: Own cwd and TMPDIR keep it apart from the client.
    def startDaemon(self):
        old_tmpdir = os.environ['TMPDIR']
        daemon_tmpdir = old_tmpdir + "/daemon_tmp"
        os.mkdir(daemon_tmpdir)
        os.environ['TMPDIR'] = daemon_tmpdir
        os.mkdir("daemon")
        os.chdir("daemon")
        try:
          while 1:
            cmd = self.daemon_command()
            result, out, err = self.runcmd_unchecked(cmd)
            if result == 0:
                break
            elif result == EXIT_BIND_FAILED:
                self.server_port += 1
                continue
            else:
                self.fail("failed to start daemon: %d" % result)
          self.add_cleanup(self.killDaemon)
        finally:
          os.environ['TMPDIR'] = old_tmpdir
          os.chdir("..")

# What: Start and stop a daemon with no test body.
# Why: Proves the fixture alone runs and tears down cleanly.
class StartStopDaemon_Case(WithDaemon_Case):
    # What: Do nothing; setup and teardown are the test.
    # Why: A daemon that cannot start fails in setup.
    def runtest(self):
        pass


# What: --version prints the version and protocol lines.
# Why: Also proves both programs built and execute.
class VersionOption_Case(SimpleDistCC_Case):
    # What: Check both --version lines of distcc and distccd.
    # Why: The format is what packagers and scripts parse.
    def runtest(self):
        for prog in 'distcc', 'distccd':
            out, err = self.runcmd("%s --version" % prog)
            assert out[-1] == '\n'
            out = out[:-1]
            line1,line2,trash = out.split('\n', 2)
            self.assert_re_match(r'^%s [\w.-]+ [.\w-]+$'
                                 % prog, line1)
            self.assert_re_match(r'^[ \t]+\(protocol.*\) \(default port 3632\)$'
                                 , line2)


# What: --help prints a usage message.
# Why: A broken option table shows up here first.
class HelpOption_Case(SimpleDistCC_Case):
    # What: Check both programs print "Usage:" for --help.
    # Why: Both must still parse options at all.
    def runtest(self):
        for prog in 'distcc', 'distccd':
            out, err = self.runcmd(prog + " --help")
            self.assert_re_search("Usage:", out)


# What: An unknown option goes to the implicit compiler.
# Why: distcc passes it to gcc, which exits non-zero.
class BogusOption_Case(SimpleDistCC_Case):
    # What: distcc mirrors gcc's rc; distccd rejects the option.
    # Why: NotRun in pump mode: the wrapper needs DISTCC_HOSTS.
    def runtest(self):
        if "cpp" in _server_options:
            raise comfychair.NotRunError('pump wrapper expects DISTCC_HOSTS')

        error_rc, _, _ = self.runcmd_unchecked(self._cc + " --bogus-option")
        assert error_rc != 0
        self.runcmd(self.distcc() + self._cc + " --bogus-option", error_rc)
        self.runcmd(self.distccd() + self._cc + " --bogus-option",
                    EXIT_BAD_ARGUMENTS)


# What: Options after the compiler name reach the compiler.
# Why: distcc must not swallow the compiler's own options.
class CompilerOptionsPassed_Case(SimpleDistCC_Case):
    # What: cc --help through distcc shows the compiler's help.
    # Why: distcc's own text in it means distcc consumed it.
    def runtest(self):
        out, err = self.runcmd("DISTCC_HOSTS=localhost%s " % _server_options
                               + self.distcc()
                               + self._cc + " --help")
        if re.search('distcc', out):
            raise AssertionError("compiler help contains \"distcc\": \"%s\"" % out)
        if self.is_gcc(self._cc):
            self.assert_re_match(r"Usage: [^ ]*gcc", out)
        elif self.is_clang(self._cc):
            self.assert_re_match(r"OVERVIEW: [^ ]*clang", out)
        else:
            raise AssertionError("Unknown compiler found")


# What: Local-only preprocessor arguments are stripped.
# Why: The server compiles preprocessed source without them.
class StripArgs_Case(SimpleDistCC_Case):
    # What: h_strip each command line; compare to the expected.
    # Why: Table-driven so each strip rule has its own case.
    def runtest(self):
        cases = (("gcc -c hello.c", "gcc -c hello.c"),
                 ("cc -Dhello hello.c -c", "cc hello.c -c"),
                 ("gcc -g -O2 -W -Wall -Wshadow -Wpointer-arith -Wcast-align -c -o h_strip.o h_strip.c",
                  "gcc -g -O2 -W -Wall -Wshadow -Wpointer-arith -Wcast-align -c -o h_strip.o h_strip.c"),
                 # What: Dangling -D/-I forms still strip cleanly.
                 # Why: Invalid input must not crash or keep junk.
                 ("cc -c hello.c -D", "cc -c hello.c"),
                 ("cc -c hello.c -D -D", "cc -c hello.c"),
                 ("cc -c hello.c -I ../include", "cc -c hello.c"),
                 ("cc -c -I ../include  hello.c", "cc -c hello.c"),
                 ("cc -c -I. -I.. -I../include -I/home/mbp/garnome/include -c -o foo.o foo.c",
                  "cc -c -c -o foo.o foo.c"),
                 ("cc -c hello.c -iquote .", "cc -c hello.c"),
                 ("cc -c hello.c -iquote.", "cc -c hello.c"),
                 ("cc -c -DDEBUG -DFOO=23 -D BAR -c -o foo.o foo.c",
                  "cc -c -c -o foo.o foo.c"),

                 # What: Options stripped since distcc 0.11.
                 # Why: A real Mozilla build line covers them at once.
                 ("cc -o nsinstall.o -c -DOSTYPE=\"Linux2.4\" -DOSARCH=\"Linux\" -DOJI -D_BSD_SOURCE -I../dist/include -I../dist/include -I/home/mbp/work/mozilla/mozilla-1.1/dist/include/nspr -I/usr/X11R6/include -fPIC -I/usr/X11R6/include -Wall -W -Wno-unused -Wpointer-arith -Wcast-align -pedantic -Wno-long-long -pthread -pipe -DDEBUG -D_DEBUG -DDEBUG_mbp -DTRACING -g -I/usr/X11R6/include -include ../config-defs.h -DMOZILLA_CLIENT -Wp,-MD,.deps/nsinstall.pp nsinstall.c",
                  "cc -o nsinstall.o -c -fPIC -Wall -W -Wno-unused -Wpointer-arith -Wcast-align -pedantic -Wno-long-long -pthread -pipe -g nsinstall.c"),

                 # What: -x is stripped, two-word and combined forms.
                 # Why: Remote compiles of .ii must keep debug info.
                 # From: Issue #79
                 ("gcc -x c++ -g -std=c++17 -c hello.ii -o hello.o",
                  "gcc -g -std=c++17 -c hello.ii -o hello.o"),
                 ("g++ -xc++ -g -c hello.ii -o hello.o",
                  "g++ -g -c hello.ii -o hello.o"),
                 ("gcc -xobjective-c++ -g -c hello.mii -o hello.o",
                  "gcc -g -c hello.mii -o hello.o"),

                 # What: A token after -Xclang survives stripping.
                 # Why: -lwp/-xop look like -l/-x but are cc1 payload.
                 ("clang -Xclang -target-feature -Xclang -lwp -c hello.c -o hello.o",
                  "clang -Xclang -target-feature -Xclang -lwp -c hello.c -o hello.o"),
                 ("clang -Xclang -target-feature -Xclang -xop -c hello.c -o hello.o",
                  "clang -Xclang -target-feature -Xclang -xop -c hello.c -o hello.o"),
                 # What: A bare -lwp is still a -l link flag, stripped.
                 # Why: Only -Xclang changes what a token means.
                 ("clang -lwp -c hello.c -o hello.o",
                  "clang -c hello.c -o hello.o"),
                 )
        for cmd, expect in cases:
            o, err = self.runcmd("h_strip %s" % cmd)
            if o[-1] == '\n': o = o[:-1]
            self.assert_equal(o, expect)


# What: distccd statistics list maintenance.
# Why: Pruning the list head must not corrupt it.
class Stats_Case(SimpleDistCC_Case):
    # What: h_stats prune-old-head must print "ok".
    # Why: The C helper does the real list checks.
    def runtest(self):
        out, err = self.runcmd("h_stats prune-old-head")
        self.assert_equal(out.strip(), "ok")


# What: distcc's source and preprocessed file detection.
# Why: The suffix decides whether a job can be distributed.
class IsSource_Case(SimpleDistCC_Case):
    # What: h_issource each name; compare both classifications.
    # Why: Table-driven so each suffix rule has its own case.
    def runtest(self):
        cases = (( "hello.c",          "source",       "not-preprocessed" ),
                 ( "hello.cc",         "source",       "not-preprocessed" ),
                 ( "hello.cxx",        "source",       "not-preprocessed" ),
                 ( "hello.cpp",        "source",       "not-preprocessed" ),
                 ( "hello.c++",        "source",       "not-preprocessed" ),
                 # What: .m is Objective-C; .M and .mm are Objective-C++.
                 # Why: Case and length both matter for the suffix.
                 ( "hello.m",          "source",       "not-preprocessed" ),
                 ( "hello.M",          "source",       "not-preprocessed" ),
                 ( "hello.mm",         "source",       "not-preprocessed" ),
                 # What: .mi and .mii are preprocessed Objective-C/C++.
                 # Why: They need no second preprocessor pass.
                 ( "hello.mi",         "source",       "preprocessed" ),
                 ( "hello.mii",        "source",       "preprocessed" ),
                 ( "hello.2.4.4.i",    "source",       "preprocessed" ),
                 ( ".foo",             "not-source",   "not-preprocessed" ),
                 ( "gcc",              "not-source",   "not-preprocessed" ),
                 ( "hello.ii",         "source",       "preprocessed" ),
                 ( "boot.s",           "not-source",   "not-preprocessed" ),
                 ( "boot.S",           "not-source",   "not-preprocessed" ))
        for f, issrc, iscpp in cases:
            o, err = self.runcmd("h_issource '%s'" % f)
            expected = ("%s %s\n" % (issrc, iscpp))
            if o != expected:
                raise AssertionError("issource %s gave %s, expected %s" %
                                     (f, repr(o), repr(expected)))


# What: Path traversal checks for NAME, CDIR and LINK tokens.
# Why: Client paths must not escape the per-job temp dir.
# From: Issue #93, Issue #95, Issue #100, Issue #289
class PathSafety_Case(SimpleDistCC_Case):
    # What: h_pathsafety each NAME, CDIR and link target.
    # Why: Relative link targets need a real jail, not text.
    def runtest(self):
        # What: NAME is safe only rooted at / with no ".." part.
        # Why: dcc_r_many_files() joins NAME under the job dir.
        name_cases = (
                 ( "/usr/include/stdio.h",  "safe" ),
                 ( "/a/b/c.h",              "safe" ),
                 ( "/",                     "safe" ),
                 # What: ".." inside a longer name is not traversal.
                 # Why: Only a whole ".." component climbs a level.
                 ( "/foo/..bar",            "safe" ),
                 ( "/foo/bar..",            "safe" ),
                 ( "/foo..bar/baz",         "safe" ),
                 # What: A NAME not rooted at / is unsafe.
                 # Why: Relative names resolve against the wrong dir.
                 ( "usr/include/stdio.h",   "unsafe" ),
                 ( "",                      "unsafe" ),
                 # What: A leading, inner or trailing ".." is unsafe.
                 # Why: Each one climbs out of the job directory.
                 ( "/../etc/passwd",        "unsafe" ),
                 ( "/foo/../../etc/passwd", "unsafe" ),
                 ( "/foo/..",               "unsafe" ),
                 ( "/..",                   "unsafe" ),
                )
        for name, expected_safety in name_cases:
            o, err = self.runcmd("h_pathsafety '%s'" % name)
            expected = ("%s %s\n" % (expected_safety, name))
            if o != expected:
                raise AssertionError("h_pathsafety %s gave %s, expected %s" %
                                     (repr(name), repr(o), repr(expected)))

        # What: CDIR may be absolute or relative, but no "..".
        # Why: cpp's temp dir is joined with the client's CDIR.
        cdir_cases = (
                 ( "/usr/local",            "safe" ),
                 ( "/home/user",            "safe" ),
                 ( "/",                     "safe" ),
                 # What: Relative CDIRs without ".." are safe.
                 # Why: Unlike NAME, CDIR may legitimately be relative.
                 ( "src",                   "safe" ),
                 ( "a/b/c",                 "safe" ),
                 ( "subdir/nested/dir",     "safe" ),
                 ( ".",                     "safe" ),
                 # What: ".." inside a longer name is not traversal.
                 # Why: Only a whole ".." component climbs a level.
                 ( "foo/..bar",             "safe" ),
                 ( "foo/bar..",             "safe" ),
                 ( "foo..bar/baz",          "safe" ),
                 ( "/foo/..bar",            "safe" ),
                 ( "/foo/bar..",            "safe" ),
                 ( "/..bar",                "safe" ),
                 # What: A leading ".." component is unsafe.
                 # Why: It climbs out before any other part applies.
                 ( "..",                    "unsafe" ),
                 ( "../etc/passwd",         "unsafe" ),
                 ( "/../etc/passwd",        "unsafe" ),
                 # What: An inner ".." component is unsafe.
                 # Why: It can climb past the job dir mid-path.
                 ( "a/../b",                "unsafe" ),
                 ( "a/../../c",             "unsafe" ),
                 ( "foo/../../etc/passwd",  "unsafe" ),
                 # What: A trailing ".." component is unsafe.
                 # Why: The final step still climbs a level.
                 ( "a/..",                  "unsafe" ),
                 ( "/a/..",                 "unsafe" ),
                 ( "a/b/..",                "unsafe" ),
                )
        for cdir, expected_safety in cdir_cases:
            o, err = self.runcmd("h_pathsafety --cdir '%s'" % cdir)
            expected = ("%s %s\n" % (expected_safety, cdir))
            if o != expected:
                raise AssertionError("h_pathsafety --cdir %s gave %s, expected %s" %
                                     (repr(cdir), repr(o), repr(expected)))

        # What: Absolute LINK targets follow the NAME rules.
        # Why: Relative targets are unvalidated by design here.
        # From: Issue #95
        link_target_cases = (
                 ( "/usr/include",          "safe" ),
                 ( "/a/b/c",                "safe" ),
                 ( "/",                     "safe" ),
                 # What: ".." inside a longer name is not traversal.
                 # Why: Only a whole ".." component climbs a level.
                 ( "/foo/..bar",            "safe" ),
                 ( "/foo/bar..",            "safe" ),
                 # What: A leading, inner or trailing ".." is unsafe.
                 # Why: Each one climbs out of the job directory.
                 ( "/../etc/passwd",        "unsafe" ),
                 ( "/foo/../../etc/passwd", "unsafe" ),
                 ( "/foo/..",               "unsafe" ),
                 ( "/..",                   "unsafe" ),
                )
        for link_target, expected_safety in link_target_cases:
            o, err = self.runcmd("h_pathsafety --link-target '%s'" % link_target)
            expected = ("%s %s\n" % (expected_safety, link_target))
            if o != expected:
                raise AssertionError("h_pathsafety --link-target %s gave %s, expected %s" %
                                     (repr(link_target), repr(o), repr(expected)))



# What: dcc_r_many_files() never writes through a symlink.
# Why: A later NFIL entry under a symlink NAME could escape.
# From: Issue #292
class SymlinkTraversal_Case(SimpleDistCC_Case):
    # What: Attack batch fails with 109; a benign batch passes.
    # Why: Drives the real receive path, not the string checks.
    def runtest(self):
        atk = os.path.join(self.tmpdir, "atk")
        jobdir = os.path.join(atk, "job")
        escape = os.path.join(atk, "escape")
        os.makedirs(jobdir)
        os.makedirs(escape)

        # What: Link /safe to ../escape, then send /safe/pwned.
        # Why: A relative target passes every string check.
        # From: PR #290
        o, err = self.runcmd("h_srvrpc attack '%s' ../escape" % jobdir)
        if o != "ret=109\n":
            raise AssertionError(
                "attack sequence not rejected: h_srvrpc gave %s (stderr: %s), "
                "expected 'ret=109\\n'" % (repr(o), repr(err)))

        # What: The first entry's symlink must exist.
        # Why: Proves the attack reached the nested-FILE step.
        safe = os.path.join(jobdir, "safe")
        if not os.path.islink(safe):
            raise AssertionError(
                "expected job/safe to have been created as a symlink; "
                "the attack never reached the nested-FILE step")
        # What: Nothing may land in the escape directory.
        # Why: A file there means the server followed the link.
        pwned = os.path.join(escape, "pwned")
        if os.path.exists(pwned):
            raise AssertionError(
                "PATH TRAVERSAL: nested FILE escaped the job directory and "
                "was written to %s" % pwned)

        # What: A benign nested batch must still succeed.
        # Why: The fix must not reject legitimate pump traffic.
        legjob = os.path.join(self.tmpdir, "leg", "job")
        os.makedirs(legjob)
        o, err = self.runcmd("h_srvrpc legit '%s'" % legjob)
        if o != "ret=0\n":
            raise AssertionError(
                "legit sequence rejected: h_srvrpc gave %s (stderr: %s), "
                "expected 'ret=0\\n'" % (repr(o), repr(err)))

        first = os.path.join(legjob, "a", "b", "c", "first.h")
        second = os.path.join(legjob, "a", "b", "c", "d", "second.h")
        mirror = os.path.join(legjob, "a", "mirror.h")
        with open(first) as f:
            if f.read() != "one":
                raise AssertionError("legit: %s has wrong contents" % first)
        with open(second) as f:
            if f.read() != "two":
                raise AssertionError("legit: %s has wrong contents" % second)
        # What: A leaf relative symlink must still be created.
        # Why: Pump mirrors use them with nothing nested below.
        if not os.path.islink(mirror):
            raise AssertionError(
                "legit: expected %s to be created as a symlink" % mirror)
        if os.readlink(mirror) != "../elsewhere/real.h":
            raise AssertionError(
                "legit: %s points at %s, expected '../elsewhere/real.h'"
                % (mirror, os.readlink(mirror)))


# What: distcc's reading of gcc command lines.
# Why: Mode, input and output decide local vs remote.
class ScanArgs_Case(SimpleDistCC_Case):
    # What: Check each command's mode, input and output.
    # Why: Table-driven so each argv rule has its own case.
    def runtest(self):
        cases = [("gcc -c hello.c", "distribute", "hello.c", "hello.o"),
                 ("gcc hello.c", "local"),
                 ("gcc -o /tmp/hello.o -c ../src/hello.c", "distribute", "../src/hello.c", "/tmp/hello.o"),
                 ("gcc -DMYNAME=quasibar.c bar.c -c -o bar.o", "distribute", "bar.c", "bar.o"),
                 ("gcc -ohello.o -c hello.c", "distribute", "hello.c", "hello.o"),
                 ("ccache gcc -c hello.c", "distribute", "hello.c", "hello.o"),

                 # What: The argv after -o is the output, even "-output".
                 # Why: dcc_scan_args() takes it without re-parsing.
                 # From: Issue #275
                 ("gcc -o -output -c foo.c", "distribute", "foo.c", "-output"),
                 ("gcc hello.o", "local"),
                 ("gcc -o hello.o hello.c", "local"),
                 ("gcc -o hello.o -c hello.s", "local"),
                 ("gcc -o hello.o -c hello.S", "local"),
                 ("gcc -fprofile-arcs -ftest-coverage -c hello.c", "local", "hello.c", "hello.o"),
                 ("gcc -S hello.c", "distribute", "hello.c", "hello.s"),
                 ("gcc -c -S hello.c", "distribute", "hello.c", "hello.s"),
                 ("gcc -S -c hello.c", "distribute", "hello.c", "hello.s"),
                 ("gcc -M hello.c", "local"),
                 ("gcc -ME hello.c", "local"),
                 ("gcc -MD -c hello.c", "distribute", "hello.c", "hello.o"),
                 ("gcc -MMD -c hello.c", "distribute", "hello.c", "hello.o"),

                 # What: Assembling to stdout (-o -) stays local.
                 # Why: Remote output cannot be streamed to stdout.
                 ("gcc -S foo.c -o -", "local"),
                 ("-S -o - foo.c", "local"),
                 ("-c -S -o - foo.c", "local"),
                 ("-S -c -o - foo.c", "local"),

                 # What: Joined -ofile form is parsed like -o file.
                 # Why: Both spellings are valid gcc syntax.
                 ("gcc -ofoo.o foo.c -c", "distribute", "foo.c", "foo.o"),
                 ("gcc -ofoo foo.o", "local"),

                 # What: Without -c the job links, so it stays local.
                 # Why: Only a compile-only job can be distributed.
                 ("foo.c -o foo.o", "local"),
                 ("foo.c -o foo.o -c", "distribute", "foo.c", "foo.o"),

                 # What: Assembler listing options keep the job local.
                 # Why: The listing file would be written remotely.
                 ("gcc -Wa,-alh,-a=foo.lst -c foo.c", "local"),
                 ("gcc -Wa,--MD -c foo.c", "local"),
                 ("gcc -Wa,-xarch=v8 -c foo.c", "distribute", "foo.c", "foo.o"),

                 # What: -frepo keeps the job local.
                 # Why: It writes .rpo files next to the source.
                 ("g++ -frepo foo.C", "local"),

                 ("gcc -xassembler-with-cpp -c foo.c", "local"),
                 ("gcc -x assembler-with-cpp -c foo.c", "local"),

                 ("gcc -specs=foo.specs -c foo.c", "distribute", "foo.c", "foo.o"),

                 # What: -dr keeps the job local.
                 # Why: It writes RTL dumps to a local file.
                 ("gcc -dr -c foo.c", "local"),
                 ]
        for tup in cases:
            self.checkScanArgs(*tup)

    # What: Run h_scanargs; fail on a wrong mode, input or output.
    # Why: Input/output are only defined for distributed jobs.
    def checkScanArgs(self, ccmd, mode, input=None, output=None):
        o, err = self.runcmd("h_scanargs %s" % ccmd)
        o = o[:-1]
        os = o.split()
        if mode != os[0]:
            self.fail("h_scanargs %s gave %s mode, expected %s" %
                      (ccmd, os[0], mode))
        if mode == 'distribute':
            if os[1] != input:
                self.fail("h_scanargs %s gave %s input, expected %s" %
                          (ccmd, os[1], input))
            if os[2] != output:
                self.fail("h_scanargs %s gave %s output, expected %s" %
                          (ccmd, os[2], output))


# What: Include server file lists are sorted.
# Why: A stable order keeps pump uploads deterministic.
class IncludeServerFileOrder_Case(SimpleDistCC_Case):
    # What: h_includesort must return the paths sorted.
    # Why: No error output is allowed alongside the result.
    def runtest(self):
        out, err = self.runcmd("h_includesort /tmp/z /tmp/a /tmp/m")
        self.assert_equal(err, "")
        self.assert_equal(out, "/tmp/a /tmp/m /tmp/z\n")


# What: State file writes stay readable through the monitor.
# Why: A torn write would show a half-written state.
class StateFileAtomicWrite_Case(SimpleDistCC_Case):
    # What: h_state atomic-write must print nothing at all.
    # Why: The C helper reports any torn read itself.
    def runtest(self):
        out, err = self.runcmd("h_state atomic-write")
        self.assert_equal(out, "")
        self.assert_equal(err, "")


# What: distcc's .d dependency file name calculation.
# Why: The name must match what gcc itself writes.
class DotD_Case(SimpleDistCC_Case):

    # What: Compare gcc's real .d file with dcc_get_dotd_info.
    # Why: Each case: command, dep glob, count, -MT target.
    def runtest(self):
        cases = [
          ("foo.c -o hello.o -MD", "*.d", 1, None),
          ("foo.c -o hello.. -MD", "*.d", 1, None),
          ("foo.c -o hello.bar.foo -MD", "*.d", 1, None),
          ("foo.c -o hello.o", "*.d", 0, None),
          ("foo.c -o hello.bar.foo -MD", "*.d", 1, None),
          ("foo.c -MD", "*.d", 1, None),
          ("foo.c -o hello. -MD", "*.d", 1, None),
          # What: No case for -o hello.D -MD -MT tootoo.
          # Why: Darwin 8.11 gcc writes no hello.d for hello.D.
          ("foo.c -o hello. -MD -MT tootoo",  "hello.*d", 1, "tootoo"),
          ("foo.c -o hello.o -MD -MT tootoo", "hello.*d", 1, "tootoo"),
          ("foo.c -o hello.o -MD -MF foobar", "foobar", 1, None),
           ]

        # What: Add C++ cases only if the compiler builds C++.
        # Why: They fail on an installation without C++ support.
        error_rc, _, _ = self.runcmd_unchecked("touch testtmp.cpp; " +
            self._cc + " -c testtmp.cpp -o /dev/null")
        if error_rc == 0:
          cases.extend([("foo.cpp -o hello.o", "*.d", 0, None),
                        ("foo.cpp -o hello", "*.d", 0, None)])

        # What: Unpack h_dotd's printed dict into a tuple.
        # Why: The C helper prints a Python literal.
        def _eval(out):
            map_out = eval(out)
            return (map_out['dotd_fname'],
                    map_out['needs_dotd'],
                    map_out['sets_dotd_target'],
                    map_out['dotd_target'])

        for (args, dep_glob, how_many, target) in cases:

            dotd_result = []
            # What: Compile with the case's args; collect the dep glob.
            # Why: gcc's own output is the reference for each name.
            class TempCompile_Case(Compilation_Case):
                # What: An empty main() program.
                # Why: Only the dependency file name matters.
                def source(self):
                      return """
int main(void) { return 0; }
"""
                # What: Take the source name from the case's args.
                # Why: Args start with the file to compile.
                def sourceFilename(self):
                    return args.split()[0]
                # What: Compile locally with the case's args.
                # Why: gcc, not distcc, defines the expected name.
                def compileCmd(self):
                    return self._cc + " -c " + args
                # What: Compile, then record files matching the glob.
                # Why: The outer test compares them with distcc's.
                def runtest(self):
                    self.compile()
                    glob_result = glob.glob(dep_glob)
                    dotd_result.extend(glob_result)

            ret = comfychair.runtest(TempCompile_Case, 0, subtest=1)
            if ret:
                raise AssertionError(
                    "Case (args:%s, dep_glob:%s, how_many:%s, target:%s)"
                    %  (args, dep_glob, how_many, target))
            self.assert_equal(len(dotd_result), how_many)
            if how_many == 1:
                expected_dep_file = dotd_result[0]

            # What: needs_dotd iff gcc wrote one; then names match.
            # Why: distcc must predict gcc's dependency file name.
            out, _err = self.runcmd("h_dotd dcc_get_dotd_info gcc -c %s" % args)
            dotd_fname, needs_dotd, sets_dotd_target, dotd_target = _eval(out)
            assert dotd_fname
            assert needs_dotd in [0,1]
            assert needs_dotd == how_many
            if needs_dotd:
                self.assert_equal(expected_dep_file, dotd_fname)

            self.assert_equal(sets_dotd_target == 1, target != None)
            if target:
                # What: With -MT given, dotd_target stays unset.
                # Why: The target already travels on the command line.
                self.assert_equal(dotd_target, "None")


        # What: DEPENDENCIES_OUTPUT sets the file and target.
        # Why: gcc honours this env var instead of -MD flags.
        try:
            os.environ["DEPENDENCIES_OUTPUT"] = "xxx.d yyy"
            out, _err = self.runcmd("h_dotd dcc_get_dotd_info gcc -c foo.c")
            dotd_fname, needs_dotd, sets_dotd_target, dotd_target = _eval(out)
            assert dotd_fname == "xxx.d"
            assert needs_dotd
            assert not sets_dotd_target
            assert dotd_target == "yyy"

            os.environ["DEPENDENCIES_OUTPUT"] = "zzz.d"
            out, _err = self.runcmd("h_dotd dcc_get_dotd_info gcc -c foo.c")
            dotd_fname, needs_dotd, sets_dotd_target, dotd_target = _eval(out)
            assert dotd_fname == "zzz.d"
            assert needs_dotd
            assert not sets_dotd_target
            assert dotd_target == "None"

        finally:
            del os.environ["DEPENDENCIES_OUTPUT"]


# What: Unit tests for compile.c helpers via h_compile.
# Why: Covers dcc_fresh_dependency_exists, discrepancy name.
class Compile_c_Case(SimpleDistCC_Case):

  # What: Return the name after "Checking dependency: ".
  # Why: h_compile traces each dependency it checks.
  def getDep(self, line):
      m_obj = re.search(r"Checking dependency: ((\w|[.])*)", line)
      assert m_obj, line
      return m_obj.group(1)

  # What: Check discrepancy names and dependency freshness.
  # Why: Runs the C functions with no client/server trip.
  def runtest(self):

      # What: Discrepancy file sits next to the server socket.
      # Why: A bare socket name has no directory, so NULL.
      os.environ['INCLUDE_SERVER_PORT'] = "abc/socket"
      out, err = self.runcmd(
              "h_compile dcc_discrepancy_filename")
      self.assert_equal(out, "abc/discrepancy_counter")

      os.environ['INCLUDE_SERVER_PORT'] = "socket"
      out, err = self.runcmd(
              "h_compile dcc_discrepancy_filename")
      self.assert_equal(out, "(NULL)")

      # What: Each .d text with the dependencies it names.
      # Why: Empty and target-only files must name none.
      dotd_cases = [("""
foo.o: foo\
bar.h bar.h notthisone.h bar.h\
""",
                     ["foobar.h", "bar.h"]),
                    (
                      """foo_foo  :\
bar_bar \
foo_bar""",
                      ["bar_bar", "foo_bar"]),
                    (":", []),
                    ("\n", []),
                    ("", []),
                    ("foo.o:", []),
                    ]

      for dotd_contents, deps in dotd_cases:
          for dep in deps:
              _Touch(dep)
          # What: Build start time: a whole second, 2s ahead.
          # Why: "%i" would truncate a float and shrink the margin.
          time_ref = int(time.time()) + 2
          # What: Wait until time_ref, polling every 0.1s.
          # Why: Finer polling never overshoots by a full second.
          while time.time() < time_ref:
              time.sleep(0.1)
          # What: Write the .d file now, at or after time_ref.
          # Why: It must not look older than the build start.
          with open("dotd", "w") as dotd_fd:
              dotd_fd.write(dotd_contents)
          # What: No dependency is fresh yet; all are checked.
          # Why: Every dep predates time_ref by construction.
          out, err = self.runcmd(
              "h_compile dcc_fresh_dependency_exists dotd '%s' %i" %
              ("*notthis*", time_ref))
          self.assert_equal(out.split()[1], "(NULL)");
          checked_deps = {}
          for line in err.split("\n"):
              # What: Parse only "Checking dependency:" trace lines.
              # Why: Other rs_trace() lines on this path are valid.
              if "Checking dependency:" in line:
                  checked_deps[self.getDep(line)] = 1
          deps_list = deps[:]
          checked_deps_list = list(checked_deps.keys())
          deps_list.sort()
          checked_deps_list.sort()
          self.assert_equal(checked_deps_list, deps_list)

          # What: Touch the last dep; it must be reported fresh.
          # Why: Its mtime is now past the build start time.
          if deps:
              _Touch(deps[-1])
              out, err = self.runcmd(
                  "h_compile dcc_fresh_dependency_exists dotd '' %i" %
                  time_ref)
              self.assert_equal(out.split()[1], deps[-1])


# What: Command lines that name no compiler at all.
# Why: distcc then uses an implicit compiler.
class ImplicitCompilerScan_Case(ScanArgs_Case):
    # What: Compile-only lines without a compiler distribute.
    # Why: The implicit compiler must not change the mode.
    def runtest(self):
        cases = [("-c hello.c",            "distribute", "hello.c", "hello.o"),
                 ("hello.c -c",            "distribute", "hello.c", "hello.o"),
                 ("-o hello.o -c hello.c", "distribute", "hello.c", "hello.o"),
                 ]
        for tup in cases:
            self.checkScanArgs(*tup)


# What: Extension extraction from file names.
# Why: Only the last suffix counts; none gives NULL.
class ExtractExtension_Case(SimpleDistCC_Case):
    # What: h_exten each name; compare the extension.
    # Why: Multi-dot and dot-only names are edge cases.
    def runtest(self):
        for f, e in (("hello.c", ".c"),
                     ("hello.cpp", ".cpp"),
                     ("hello.2.4.4.4.c", ".c"),
                     (".foo", ".foo"),
                     ("gcc", "(NULL)")):
            out, err = self.runcmd("h_exten '%s'" % f)
            assert out == e


# What: distccd with an out-of-range port.
# Why: It must refuse to start and leave no pidfile.
class DaemonBadPort_Case(SimpleDistCC_Case):
    # What: --port 80000 exits with EXIT_BAD_ARGUMENTS.
    # Why: Ports above 65535 cannot be bound.
    def runtest(self):
        self.runcmd(self.distccd() +
                    "--log-file=distccd.log --lifetime=10 --port 80000 "
                    "--allow 127.0.0.1 --enable-tcp-insecure",
                    EXIT_BAD_ARGUMENTS)
        self.assert_no_file("daemonpid.tmp")


# What: --enable-tcp-insecure works in any option position.
# Why: Option order must not change what is allowed.
class TcpInsecureOptionOrder_Case(SimpleDistCC_Case):
    # What: h_dopt tcp-insecure-order must print "ok".
    # Why: The C helper parses the option orders itself.
    def runtest(self):
        out, err = self.runcmd("h_dopt tcp-insecure-order")
        self.assert_equal(out.strip(), "ok")


# What: Invalid DISTCC_HOSTS values are rejected.
# Why: ParseHostSpec_Case covers the valid forms.
class InvalidHostSpec_Case(SimpleDistCC_Case):
    # What: Each bad spec makes h_hosts exit EXIT_BAD_HOSTSPEC.
    # Why: Blank, bare-@, empty-port forms must not parse.
    def runtest(self):
        for spec in ["", "    ", "\t", "  @ ", ":", "mbp@", "angry::", ":4200"]:
            self.runcmd(("DISTCC_HOSTS=\"%s\" " % spec) + self.valgrind()
                        + "h_hosts -v",
                        EXIT_BAD_HOSTSPEC)


# What: dcc_parse_hosts_env on a complex DISTCC_HOSTS.
# Why: Covers TCP, SSH, limits, options and comments.
class ParseHostSpec_Case(SimpleDistCC_Case):
    # What: h_hosts must print the expected parsed host list.
    # Why: The C wrapper prints one line per parsed host.
    def runtest(self):
        spec="""localhost 127.0.0.1 @angry   ted@angry
        \t@angry:/home/mbp/bin/distccd  angry:4204
        ipv4-localhost
        angry/44
        angry:300/44
        angry/44:300
        angry,lzo
        angry:3000,lzo    # some comment
        angry/44,lzo
        @angry,lzo#asdasd
        # oh yeah nothing here
        @angry:/usr/sbin/distccd,lzo
        localhostbutnotreally
        """

        expected="""16
   2 LOCAL
   4 TCP 127.0.0.1 3632
   4 SSH (no-user) angry (no-command)
   4 SSH ted angry (no-command)
   4 SSH (no-user) angry /home/mbp/bin/distccd
   4 TCP angry 4204
   4 TCP ipv4-localhost 3632
  44 TCP angry 3632
  44 TCP angry 300
  44 TCP angry 300
   4 TCP angry 3632
   4 TCP angry 3000
  44 TCP angry 3632
   4 SSH (no-user) angry (no-command)
   4 SSH (no-user) angry /usr/sbin/distccd
   4 TCP localhostbutnotreally 3632
"""
        out, err = self.runcmd(("DISTCC_HOSTS=\"%s\" " % spec) + self.valgrind()
                               + "h_hosts")
        assert out == expected, "expected %s\ngot %s" % (repr(expected), repr(out))


# What: DISTCC_SSH options survive repeated SSH connects.
# Why: The first connect must not consume the options.
class SecureShellCommandEnvironment_Case(SimpleDistCC_Case):
    # What: A fake ssh logs argv; both connects must match.
    # Why: Records exactly what distcc passes to ssh.
    def runtest(self):
        fake_ssh = os.path.abspath("fake-ssh")
        fake_ssh_log = os.path.abspath("fake-ssh.log")

        f = open(fake_ssh, "w")
        try:
            f.write("#!/bin/sh\n")
            f.write("printf '%%s\\n' \"$*\" >> %s\n" % _ShellSafe(fake_ssh_log))
        finally:
            f.close()
        os.chmod(fake_ssh, 0o700)

        os.environ["DISTCC_SSH"] = "%s --distcc-test-option" % fake_ssh
        self.runcmd("h_ssh repeat-env")

        f = open(fake_ssh_log)
        try:
            lines = f.read().splitlines()
        finally:
            f.close()

        expected = ("--distcc-test-option -l builduser buildhost distccd "
                    "--inetd --enable-tcp-insecure")
        self.assert_equal(lines, [expected, expected])


# What: Test distcc by really compiling, linking, running.
# Why: Subclasses vary source, options and expected output.
class Compilation_Case(WithDaemon_Case):
    # What: Start the daemon, then write source and header.
    # Why: Fixtures must exist before the client uploads them.
    def setup(self):
        WithDaemon_Case.setup(self)
        self.createSource()

    # What: Compile, link, then check the built program.
    # Why: The default flow most compile tests share.
    def runtest(self):
        self.compile()
        self.link()
        self.checkBuiltProgram()

    # What: Write and close the source and header files.
    # Why: Unclosed files may upload before they are flushed.
    def createSource(self):
        filename = self.sourceFilename()
        with open(filename, 'w') as f:
            f.write(self.source())
        filename = self.headerFilename()
        with open(filename, 'w') as f:
            f.write(self.headerSource())

    # What: Default source file name.
    # Why: Subclasses override it to test odd names.
    def sourceFilename(self):
        return "testtmp.c"

    # What: Default header file name.
    # Why: Subclasses override it to test odd names.
    def headerFilename(self):
        return "testhdr.h"

    # What: Default header content: empty.
    # Why: Only tests that include it need content.
    def headerSource(self):
        return ""

    # What: Run the compile; any stdout or stderr fails.
    # Why: A clean compile prints nothing at all.
    def compile(self):
        cmd = self.compileCmd()
        out, err = self.runcmd(cmd)
        if out != '':
            self.fail("compiler command %s produced output:\n%s" % (repr(cmd), out))
        if err != '':
            self.fail("compiler command %s produced error:\n%s" % (repr(cmd), err))

    # What: Run the link; any stdout or stderr fails.
    # Why: A clean link prints nothing at all.
    def link(self):
        cmd = self.linkCmd()
        out, err = self.runcmd(cmd)
        if out != '':
            self.fail("command %s produced output:\n%s" % (repr(cmd), repr(out)))
        if err != '':
            self.fail("command %s produced error:\n%s" % (repr(cmd), repr(err)))

    # What: Compile command: distcc without fallback, -c.
    # Why: A remote failure must fail, not compile locally.
    def compileCmd(self):
        return self.distcc_without_fallback() + \
               self._cc + " -o testtmp.o " + self.compileOpts() + \
               " -c %s" % (self.sourceFilename())

    # What: Extra compile options; none by default.
    # Why: Subclasses add the flags under test.
    def compileOpts(self):
        return ""

    # What: Link command through distcc.
    # Why: Links run locally; distcc must pass them through.
    def linkCmd(self):
        return self.distcc() + \
               self._cc + " -o testtmp testtmp.o " + self.libraries()

    # What: Extra -l link options; none by default.
    # Why: Subclasses that need libraries override it.
    def libraries(self):
        return ""

    # What: Fail if the compiler printed any message.
    # Why: Warnings and notes count as unexpected output.
    def checkCompileMsgs(self, msgs):
        if len(msgs) > 0:
            self.fail("expected no compiler messages, got \"%s\"" % msgs)

    # What: Run the built program; stderr must be empty.
    # Why: Running it proves the object was really built.
    def checkBuiltProgram(self):
        msgs, errs = self.runcmd("./testtmp")
        self.checkBuiltProgramMsgs(msgs)
        self.assert_equal(errs, '')

    # What: Accept any program output by default.
    # Why: Subclasses check the output they expect.
    def checkBuiltProgramMsgs(self, msgs):
        pass


# What: Build a hello-world program that works.
# Why: The baseline compile most other cases extend.
class CompileHello_Case(Compilation_Case):

    # What: Header defining HELLO_WORLD.
    # Why: Proves the header reaches the compile.
    def headerSource(self):
        return """
#define HELLO_WORLD "hello world"
"""

    # What: Program printing HELLO_WORLD from the header.
    # Why: Its output proves header and code both built.
    def source(self):
        return """
#include <stdio.h>
#include "%s"
int main(void) {
    puts(HELLO_WORLD);
    return 0;
}
""" % self.headerFilename()

    # What: The program must print "hello world".
    # Why: Anything else means a wrong build or header.
    def checkBuiltProgramMsgs(self, msgs):
        self.assert_equal(msgs, "hello world\n")


# What: Masquerade mode: distcc runs as a "gcc" symlink.
# Why: dcc_support_masquerade() must find the real gcc.
# From: Issue #275
class MasqueradeMode_Case(CompileHello_Case):

    # What: Symlink gcc to the built distcc, prepend to PATH.
    # Why: Mirrors update-distcc-symlinks at a small scale.
    def setup(self):
        CompileHello_Case.setup(self)
        distcc_path = None
        for d in os.environ['PATH'].split(':'):
            candidate = os.path.join(d, 'distcc')
            if os.access(candidate, os.X_OK):
                distcc_path = os.path.abspath(candidate)
                break
        if distcc_path is None:
            raise comfychair.NotRunError('could not find the built distcc '
                                         'binary on PATH')
        self.masq_dir = os.path.abspath('masquerade_bin')
        os.mkdir(self.masq_dir)
        os.symlink(distcc_path, os.path.join(self.masq_dir, 'gcc'))
        os.environ['PATH'] = self.masq_dir + ':' + os.environ['PATH']

    # What: Compile with plain "gcc", no "distcc" in it.
    # Why: Only the masquerade symlink may route it to distcc.
    def compileCmd(self):
        return ("gcc -o testtmp.o " + self.compileOpts() +
                " -c %s" % self.sourceFilename())


# What: A header file name containing a comma.
# Why: Commas also separate host options in specs.
class CommaInFilename_Case(CompileHello_Case):

    # What: Use foo1,2.h as the header name.
    # Why: The name must survive the remote round trip.
    def headerFilename(self):
      return 'foo1,2.h'


# What: #include of a macro-computed header name.
# Why: The include server must expand the macro first.
class ComputedInclude_Case(CompileHello_Case):

    # What: Build the header name with stringizing macros.
    # Why: A literal-only scan would miss this include.
    def source(self):
        return """
#include <stdio.h>
#define MAKE_HEADER(header_name) STRINGIZE(header_name.h)
#define STRINGIZE(x) STRINGIZE2(x)
#define STRINGIZE2(x) #x
#define HEADER MAKE_HEADER(testhdr)
#include HEADER
int main(void) {
    puts(HELLO_WORLD);
    return 0;
}
"""

# What: A backslash inside an unused macro branch.
# Why: Dead #if branches must not break include parsing.
class BackslashInMacro_Case(ComputedInclude_Case):
    # What: #if FALSE hides a macro ending in a backslash.
    # Why: Only the #else branch's header is really used.
    def source(self):
        return """
#include <stdio.h>
#if FALSE
  #define HEADER MAKE_HEADER(testhdr)
  #define MAKE_HEADER(header_name) STRINGIZE(foobar\\)
  #define STRINGIZE(x) STRINGIZE2(x)
  #define STRINGIZE2(x) #x
#else
  #define HEADER "testhdr.h"
#endif
#include HEADER
int main(void) {
    puts(HELLO_WORLD);
    return 0;
}
"""

# What: A header name containing a backslash.
# Why: On Unix it is one name, on Windows a subdirectory.
class BackslashInFilename_Case(ComputedInclude_Case):

    # What: Return subdir\testhdr.h, creating subdir.
    # Why: Works whichever way the platform reads it.
    def headerFilename(self):
      try:
        os.mkdir("subdir")
      except:
        pass
      return 'subdir\\testhdr.h'

    # What: Include the header via a macro with a backslash.
    # Why: The backslash must survive macro stringizing.
    def source(self):
        return """
#include <stdio.h>
#define HEADER MAKE_HEADER(testhdr)
#define MAKE_HEADER(header_name) STRINGIZE(subdir\\header_name.h)
#define STRINGIZE(x) STRINGIZE2(x)
#define STRINGIZE2(x) #x
#include HEADER
int main(void) {
    puts(HELLO_WORLD);
    return 0;
}
"""

# What: --include=/abs/path is rewritten for the server.
# Why: serve.c listed -include but not the --include= form.
# From: PR #416
class IncludeEqualsForceInclude_Case(CompileHello_Case):

    # What: Run only in pump mode.
    # Why: Plain mode resolves --include= on the client.
    def setup(self):
        if _server_options.find('cpp') == -1:
            raise comfychair.NotRunError(
                "--include= server-side rewriting only applies in pump "
                "mode (see --pump); in plain mode cpp runs client-side, "
                "so --include= is resolved locally before the server ever "
                "sees it, and clang/gcc legitimately warns 'argument "
                "unused during compilation' passing it to a compile-only "
                "invocation of an already-preprocessed .i file")
        CompileHello_Case.setup(self)

    # What: Program using HELLO_WORLD with no #include of it.
    # Why: Only --include= may supply it; failure is loud.
    def source(self):
        return """
#include <stdio.h>
int main(void) {
    puts(HELLO_WORLD);
    return 0;
}
"""

    # What: Force-include the header by absolute path.
    # Why: The absolute path is what the server must rewrite.
    def compileOpts(self):
        return "--include=%s" % os.path.abspath(self.headerFilename())


# What: --imacros=/abs/path is rewritten for the server.
# Why: serve.c and parse_command.py lacked --imacros=.
# From: PR #416
class ImacrosEqualsForceInclude_Case(CompileHello_Case):

    # What: Run only in pump mode.
    # Why: Plain mode resolves --imacros= on the client.
    def setup(self):
        if _server_options.find('cpp') == -1:
            raise comfychair.NotRunError(
                "--imacros= server-side rewriting only applies in pump "
                "mode (see --pump); in plain mode cpp runs client-side, "
                "so --imacros= is resolved locally before the server ever "
                "sees it, and clang/gcc legitimately warns 'argument "
                "unused during compilation' passing it to a compile-only "
                "invocation of an already-preprocessed .i file")
        CompileHello_Case.setup(self)

    # What: Program using HELLO_WORLD with no #include of it.
    # Why: Only --imacros= may supply it; failure is loud.
    def source(self):
        return """
#include <stdio.h>
int main(void) {
    puts(HELLO_WORLD);
    return 0;
}
"""

    # What: Pull in the header's macros by absolute path.
    # Why: The absolute path is what the server must rewrite.
    def compileOpts(self):
        return "--imacros=%s" % os.path.abspath(self.headerFilename())


# What: -isysroot /abs/path is rewritten for the server.
# Why: serve.c had no -isysroot or --sysroot= entry.
class SysrootAbsolutePath_Case(CompileHello_Case):

    # What: Run only in pump mode.
    # Why: Plain mode resolves the sysroot on the client.
    def setup(self):
        if _server_options.find('cpp') == -1:
            raise comfychair.NotRunError(
                "-isysroot server-side rewriting only applies in pump mode "
                "(see --pump); in plain mode cpp runs client-side, so the "
                "sysroot is resolved locally before the server ever sees it")
        CompileHello_Case.setup(self)

    # What: Any real, unpreprocessed C source.
    # Why: Server-side cpp only runs on a real .c file.
    def source(self):
        return "int main(void) { return 0; }\n"

    # What: Pass -isysroot with an absolute fake sysroot.
    # Why: Its path is what the server must rewrite.
    def compileOpts(self):
        return "-isysroot %s" % os.path.abspath("fake_sysroot")

    # What: Check the server log for the rewritten argv.
    # Why: Sysroot mirroring is a separate, clang-fragile issue.
    def runtest(self):
        fake_sysroot = os.path.abspath("fake_sysroot")
        os.makedirs(fake_sysroot)

        # What: Run the compile, ignoring its exit code.
        # Why: A header-less fake sysroot cannot really build.
        self.runcmd_unchecked(self.compileCmd())

        # What: Match -isysroot only on the "forking to execute" line.
        # Why: The raw, unrewritten argv is logged earlier too.
        log = self.waitForLogPattern(r"forking to execute.*-isysroot (\S+)", 10)
        m = re.search(r"forking to execute.*-isysroot (\S+)", log)
        rewritten = m.group(1)
        if rewritten == fake_sysroot:
            self.fail("sysroot path was not rewritten at all: %s" % rewritten)
        if not rewritten.endswith(fake_sysroot):
            self.fail("rewritten sysroot %r does not end with the original %r" %
                       (rewritten, fake_sysroot))


# What: -march=native resolves via the argv[0] path given.
# Why: A basename PATH search missed dispatchers like cc.
class MarchNativeDispatcherPath_Case(CompileHello_Case):

    # What: Build a "mycompiler" script off PATH that execs clang.
    # Why: Only a literal-path exec can find it.
    def setup(self):
        CompileHello_Case.setup(self)
        clang = self._find_compiler("clang")
        self.require(clang is not None,
                     "no clang found on $PATH to build the fake dispatcher from")
        # What: Skip if local clang rejects -march=native.
        # Why: Some arches refuse it, with or without the fix.
        probe_rc, _, probe_err = self.runcmd_unchecked(
            "%s -march=native -E -x c - < /dev/null > /dev/null" % clang)
        self.require(probe_rc == 0,
                     "local clang does not accept -march=native on this arch")
        # What: Skip if clang warns while resolving the flag.
        # Why: compile() fails on stderr; filtering would mask.
        self.require(probe_err == '',
                     "local clang's own -march=native resolution emits a "
                     "warning on this host (%r) -- skipping rather than "
                     "filtering it out of this test's warning-as-error "
                     "check" % probe_err)
        # What: Put it off PATH under a non-compiler name.
        # Why: A basename-only search must not find it by name.
        dispatch_dir = os.path.join(os.getcwd(), "not_on_path")
        os.mkdir(dispatch_dir)
        self.dispatcher_path = os.path.join(dispatch_dir, "mycompiler")
        with open(self.dispatcher_path, "w") as f:
            f.write("#!/bin/sh\nexec %s \"$@\"\n" % clang)
        os.chmod(self.dispatcher_path, 0o700)

    # What: Compile via the dispatcher's full path, no fallback.
    # Why: A broken resolution must fail, not compile locally.
    def compileCmd(self):
        return self.distcc_without_fallback() + \
               self.dispatcher_path + " -o testtmp.o -march=native " + \
               self.compileOpts() + " -c %s" % (self.sourceFilename())

    # What: Link with the same full-path dispatcher.
    # Why: The object must link with a consistent compiler.
    def linkCmd(self):
        return self.distcc() + \
               self.dispatcher_path + " -o testtmp testtmp.o " + self.libraries()

    # What: Seconds to wait for the daemon's log line.
    # Why: The client can return before the server logs.
    # From: Issue #300
    LOG_WRITE_TIMEOUT = 5

    # What: Build and run, then require COMPILE_OK in the log.
    # Why: A working binary can come from a local fallback.
    def runtest(self):
        CompileHello_Case.runtest(self)
        self.waitForLogPattern(r'COMPILE_OK', self.LOG_WRITE_TIMEOUT)


# What: Abstract base for non-C language compile tests.
# Why: Each language only needs its name and source.
class LanguageSpecific_Case(Compilation_Case):
    # What: NotRun unless a local test compile succeeds.
    # Why: The language's compiler may not be installed.
    def runtest(self):
        source = self.sourceFilename()
        lang = self.languageGccName()
        error_rc, _, _ = self.runcmd_unchecked(
            "touch " + source + "; " +
            "rm -f testtmp.o; " +
            self._cc + " -x " + lang + " " + self.compileOpts() +
                " -c " + source + " " + self.libraries() + " && " +
            "test -f testtmp.o" )
        if error_rc != 0:
            raise comfychair.NotRunError ('GNU ' + self.languageName() +
                                          ' not installed')
        else:
            Compilation_Case.runtest (self)

    # What: Source name: testtmp plus the language extension.
    # Why: The extension tells the compiler the language.
    def sourceFilename(self):
      return "testtmp" + self.extension()

    # What: Language name for gcc -x; subclasses must set it.
    # Why: The probe compile forces this language.
    def languageGccName(self):
      raise NotImplementedError

    # What: Human-readable language name; subclass sets it.
    # Why: Used in the NotRun message.
    def languageName(self):
      raise NotImplementedError

    # What: File extension with leading "."; subclass sets it.
    # Why: distcc picks the language by suffix.
    def extension(self):
      raise NotImplementedError


# What: Build and run a C++ program.
# Why: C++ needs its own suffix, headers and libstdc++.
class CPlusPlus_Case(LanguageSpecific_Case):

    # What: Language name for messages.
    # Why: Shown when the compiler is missing.
    def languageName(self):
      return "C++"

    # What: gcc -x name for C++.
    # Why: The probe compile forces C++.
    def languageGccName(self):
      return "c++"

    # What: Use the .cpp suffix.
    # Why: Any C++ suffix would do; .cpp is common.
    def extension(self):
      return ".cpp"

    # What: Link against libstdc++.
    # Why: iostream needs the C++ runtime.
    def libraries(self):
      return "-lstdc++"

    # What: Header defining MESSAGE.
    # Why: Proves the header reaches the compile.
    def headerSource(self):
        return """
#define MESSAGE "hello c++"
"""

    # What: Print MESSAGE with std::cout.
    # Why: Exercises a real C++ standard header.
    def source(self):
        return """
#include <iostream>
#include "testhdr.h"

int main(void) {
    std::cout << MESSAGE << std::endl;
    return 0;
}
"""

    # What: The program must print "hello c++".
    # Why: Proves the C++ build really ran.
    def checkBuiltProgramMsgs(self, msgs):
        self.assert_equal(msgs, "hello c++\n")


# What: Build and run an Objective-C program.
# Why: .m files must be distributed as Objective-C.
# From: Issue #275
class ObjectiveC_Case(LanguageSpecific_Case):

    # What: Language name for messages.
    # Why: Shown when the compiler is missing.
    def languageName(self):
      return "Objective-C"

    # What: gcc -x name for Objective-C.
    # Why: The probe compile forces Objective-C.
    def languageGccName(self):
      return "objective-c"

    # What: Use the .m suffix.
    # Why: .m is Objective-C's only suffix.
    def extension(self):
      return ".m"

    # What: Header defining MESSAGE.
    # Why: Proves the #import reaches the compile.
    def headerSource(self):
        return """
#define MESSAGE "hello objective-c"
"""

    # What: Print MESSAGE via #import, no ObjC runtime.
    # Why: Real OOP features would need -lobjc for one test.
    def source(self):
        return """
#import <stdio.h>
#import "testhdr.h"

/* Real ObjC OOP features (@interface, message dispatch) were
 * considered and declined (issue #275): they'd need the ObjC
 * runtime (-lobjc) linked in, a new dependency for a single test
 * case. This case already runs for real (confirmed live: OK on
 * macOS-latest CI, cleanly NOTRUN on Linux CI where GNU
 * Objective-C isn't installed) without it -- LanguageSpecific_Case's
 * own probe already gates this on plain "gcc/clang -x objective-c"
 * support, so it's not testing anything platform-specific real ObjC
 * syntax would add. */

int main(void) {
    puts(MESSAGE);
    return 0;
}
"""

# What: Build and run an Objective-C++ program.
# Why: .mm files must be distributed as Objective-C++.
# From: Issue #275
class ObjectiveCPlusPlus_Case(LanguageSpecific_Case):

    # What: Language name for messages.
    # Why: Shown when the compiler is missing.
    def languageName(self):
      return "Objective-C++"

    # What: gcc -x name for Objective-C++.
    # Why: The probe compile forces Objective-C++.
    def languageGccName(self):
      return "objective-c++"

    # What: Use the .mm suffix.
    # Why: distcc maps .mm to Objective-C++.
    def extension(self):
      return ".mm"

    # What: Link against libstdc++.
    # Why: iostream needs the C++ runtime.
    def libraries(self):
      return "-lstdc++"

    # What: Header defining MESSAGE.
    # Why: Proves the #import reaches the compile.
    def headerSource(self):
        return """
#define MESSAGE "hello objective-c++"
"""

    # What: Print MESSAGE with std::cout, no ObjC runtime.
    # Why: Real OOP features would need -lobjc for one test.
    def source(self):
        return """
#import <iostream>
#import "testhdr.h"

/* Same reasoning as ObjectiveC_Case above: real ObjC++ OOP features
 * were declined (issue #275), no new -lobjc dependency needed --
 * confirmed live on real CI as-is (OK on macOS-latest, clean NOTRUN
 * on Linux). */

int main(void) {
    std::cout << MESSAGE << std::endl;
    return 0;
}
"""

    # What: The program must print "hello objective-c++".
    # Why: Proves the Objective-C++ build really ran.
    def checkBuiltProgramMsgs(self, msgs):
        self.assert_equal(msgs, "hello objective-c++\n")


# What: Compile with -I/usr/include/ on the command line.
# Why: A system dir passed via -I must still resolve.
class SystemIncludeDirectories_Case(Compilation_Case):

    # What: Pass -I/usr/include/, or NotRun without sys/types.h.
    # Why: The test needs a real system header there.
    def compileOpts(self):
        if os.path.exists("/usr/include/sys/types.h"):
          return "-I/usr/include/"
        else:
          raise comfychair.NotRunError (
              "This test requires /usr/include/sys/types.h")

    # What: Header defining HELLO_WORLD.
    # Why: Proves the local header still wins.
    def headerSource(self):
        return """
#define HELLO_WORLD "hello world"
"""

    # What: Include "sys/types.h" plus the local header.
    # Why: Quoted sys/types.h must resolve via -I/usr/include.
    def source(self):
        return """
#include "sys/types.h"    /* Should resolve to /usr/include/sys/types.h. */
#include <stdio.h>
#include "testhdr.h"
int main(void) {
    uint val = 1u;
    puts(HELLO_WORLD);
    return val == 1 ? 0 : 1;
}
"""

    # What: The program must print "hello world".
    # Why: Proves both headers resolved and it built.
    def checkBuiltProgramMsgs(self, msgs):
        self.assert_equal(msgs, "hello world\n")


# What: C++ compile with -I/usr/include/sys.
# Why: "types.h" must resolve into a system subdirectory.
class CPlusPlus_SystemIncludeDirectories_Case(CPlusPlus_Case):

    # What: Pass -I/usr/include/sys, or NotRun without it.
    # Why: The test needs a real sys/types.h there.
    def compileOpts(self):
        if os.path.exists("/usr/include/sys/types.h"):
          return "-I/usr/include/sys"
        else:
          raise comfychair.NotRunError (
              "This test requires /usr/include/sys/types.h")

    # What: Header defining MESSAGE.
    # Why: Proves the local header still resolves.
    def headerSource(self):
        return """
#define MESSAGE "hello world"
"""

    # What: Include "types.h", the header, and stdio.h.
    # Why: "types.h" only exists via -I/usr/include/sys.
    def source(self):
        return """
#include "types.h"    /* Should resolve to /usr/include/sys/types.h. */
#include "testhdr.h"
#include <stdio.h>
int main(void) {
    puts(MESSAGE);
    return 0;
}
"""
    # What: The program must print "hello world".
    # Why: Proves the C++ build with -I really ran.
    def checkBuiltProgramMsgs(self, msgs):
        self.assert_equal(msgs, "hello world\n")


# What: distcc writes debug info gdb can use.
# Why: Server paths must be rewritten to the client's.
class Gdb_Case(CompileHello_Case):

    # What: Put the source in src/, creating it if needed.
    # Why: A subdirectory source tests path recording.
    def sourceFilename(self):
        try:
          os.mkdir("src")
        except:
          pass
        return "src/testtmp.c"

    # What: Compile and link command: cc -g.
    # Why: Subclasses add optimisation or compression.
    def compiler(self):
        return self._cc + " -g ";

    # What: Compile through distcc into obj/, no fallback.
    # Why: Only a remote compile tests the path rewrite.
    def compileCmd(self):
        os.mkdir("obj")
        return self.distcc_without_fallback() + self.compiler() + \
               " -o obj/testtmp.o -I. -c %s" % (self.sourceFilename())

    # What: Link into link/, failing on any output.
    # Why: Its local comp dir must not override the compile's.
    def link(self):
        os.mkdir('link')
        cmd = (self.distcc() + self.compiler() + self.build_id +
               " -o link/testtmp obj/testtmp.o")
        out, err = self.runcmd(cmd)
        if out != '':
            self.fail("command %s produced output:\n%s" % (repr(cmd), repr(out)))
        if err != '':
            self.fail("command %s produced error:\n%s" % (repr(cmd), repr(err)))

    # What: NotRun without gdb; pick a fixed build-id flag.
    # Why: A fixed build id makes both binaries comparable.
    def runtest(self):
        error_rc, _, _ = self.runcmd_unchecked("gdb --help")
        if error_rc != 0:
            raise comfychair.NotRunError ('gdb could not be found on path')

        # What: Try --build-id, then -Wl,--build-id, then none.
        # Why: Compilers differ in which spelling they accept.
        self.build_id = " --build-id=0x12345678 "
        error_rc, _, _ = self.runcmd_unchecked(self.compiler() +
            (self.build_id + " -o junk -I. %s" % self.sourceFilename()))
        if error_rc != 0:
          self.build_id = " -Wl,--build-id=0x12345678 "
          error_rc, _, _ = self.runcmd_unchecked(self.compiler() +
              (self.build_id + " -o junk -I. %s" % self.sourceFilename()))
          if error_rc != 0:
            self.build_id = ""

        CompileHello_Case.runtest (self)

    # What: gdb commands: break at main, run, step once.
    # Why: Stepping shows the source line gdb resolved.
    def gdbCommands(self):
        return 'break main\nrun\nnext\n'

    # What: gdb must find testtmp.c's source, here and in run/.
    # Why: Proves the compile dir in the debug info is right.
    def checkBuiltProgram(self):
        # What: Use testtmp.exe if it exists, else testtmp.
        # Why: Windows toolchains add an .exe suffix.
        if os.path.exists('link/testtmp.exe'):
            testtmp_exe = 'testtmp.exe'
        else:
            testtmp_exe = 'testtmp'

        # What: Run gdb with a --command file in batch mode.
        # Why: gdb --ex is not supported by older gdbs.
        with open('gdb_commands', 'w') as f:
            f.write(self.gdbCommands())
        out, errs = self.runcmd("gdb -nh --batch --command=gdb_commands "
                                "link/%s </dev/null" % testtmp_exe)
        # What: stderr must be empty or one known gdb quirk.
        # Why: Some gdb versions print these harmless messages.
        ignorable_error_messages = (
          'Failed to read a valid object file image from memory.\n',
          'warning: Lowest section in system-supplied DSO at 0xffffe000 is .hash at ffffe0b4\n',
          'warning: no loadable sections found in added symbol-file /usr/lib/debug/lib/ld-2.7.so\n',
          'warning: Could not load shared library symbols for linux-gate.so.1.\nDo you need "set solib-search-path" or "set sysroot"?\n',
        )
        if errs and errs not in ignorable_error_messages:
            self.assert_equal(errs, '')
        self.assert_re_search('puts\\(HELLO_WORLD\\);', out)
        self.assert_re_search('testtmp.c:[45]', out)

        # What: Repeat from run/ if cpp output records the pwd.
        # Why: Tests the compile dir field; gcc 3.3 omits it.
        os.mkdir('run')
        os.chdir('run')
        self.runcmd("cp ../link/%s ./%s" % (testtmp_exe, testtmp_exe))
        pump_mode = _server_options.find('cpp') != -1
        error_rc, _, _ = self.runcmd_unchecked(self.compiler() +
            " -g -E -I.. -c ../%s | grep `pwd` >/dev/null" %
            self.sourceFilename())
        gcc_preprocessing_preserves_pwd = (error_rc == 0)
        if gcc_preprocessing_preserves_pwd:
            out, errs = self.runcmd("gdb -nh --batch --command=../gdb_commands "
                                    "./%s </dev/null" % testtmp_exe)
            if errs and errs not in ignorable_error_messages:
                self.assert_equal(errs, '')
            self.assert_re_search('puts\\(HELLO_WORLD\\);', out)
            self.assert_re_search('testtmp.c:[45]', out)
        os.chdir('..')

        # What: Rebuild without distcc, strip both, compare bytes.
        # Why: distcc may only have changed the debug info.
        self.runcmd(self.compiler() + self.build_id + " -o obj/testtmp.o -I. -c %s" %
            self.sourceFilename())
        self.runcmd(self.compiler() + self.build_id + " -o link/testtmp obj/testtmp.o")
        self.runcmd("strip link/%s && strip run/%s" % (testtmp_exe, testtmp_exe))
        # What: Allow 16 differing bytes for Mach-O, 2 for PE.
        # Why: Mach-O embeds a UUID; PE differs in two places.
        is_macho = _IsMachO('link/%s' % testtmp_exe)
        if is_macho:
            acceptable_diffbytes = 16
        elif _IsPE('link/%s' % testtmp_exe):
            acceptable_diffbytes = 2
        else:
            acceptable_diffbytes = 0
        rc, msgs, errs = self.runcmd_unchecked("cmp -l link/%s run/%s"
                                               % (testtmp_exe, testtmp_exe))
        diff_lines = msgs.strip().splitlines()
        too_many_diffs = len(diff_lines) > acceptable_diffbytes
        # What: For Mach-O the diff must be one consecutive run.
        # Why: Only the UUID may differ, not 16 scattered bytes.
        # From: Issue #275
        non_consecutive_diffs = False
        if is_macho and diff_lines and not too_many_diffs:
            offsets = [int(line.split()[0]) for line in diff_lines]
            offsets.sort()
            non_consecutive_diffs = (
                offsets[-1] - offsets[0] + 1 != len(offsets))
        if (rc != 0 and
            (errs or too_many_diffs or non_consecutive_diffs)):
            # What: Re-run plain cmp to fail with its message.
            # Why: cmp's own output names the first differing byte.
            self.runcmd("cmp link/%s run/%s" % (testtmp_exe, testtmp_exe))

# What: Gdb_Case at -O1.
# Why: Optimisation reshapes the debug info distcc edits.
class GdbOpt1_Case(Gdb_Case):
    # What: Compile and link command: cc -g -O1.
    # Why: Only the optimisation level differs.
    def compiler(self):
        return self._cc + " -g -O1 ";

# What: Gdb_Case at -O2.
# Why: Optimisation reshapes the debug info distcc edits.
class GdbOpt2_Case(Gdb_Case):
    # What: Compile and link command: cc -g -O2.
    # Why: Only the optimisation level differs.
    def compiler(self):
        return self._cc + " -g -O2 ";

# What: Gdb_Case at -O3.
# Why: Optimisation reshapes the debug info distcc edits.
class GdbOpt3_Case(Gdb_Case):
    # What: Compile and link command: cc -g -O3.
    # Why: Only the optimisation level differs.
    def compiler(self):
        return self._cc + " -g -O3 ";

# What: True if obj has a compressed .debug or .zdebug.
# Why: Proves the assembler compressed, not just accepted it.
# From: Issue #398
def _readelf_has_compressed_debug(case, obj):
    rc, out, _ = case.runcmd_unchecked("readelf -SW %s" % obj)
    if rc != 0:
        return False
    for line in out.splitlines():
        if ".zdebug" in line:
            return True
        # What: A "C" in the flag column marks SHF_COMPRESSED.
        # Why: readelf -SW prints the flags as one column.
        if ".debug" in line and re.search(r" [A-Z]*C[A-Z]* ", line):
            return True
    return False

# What: True if this build can rewrite compressed debug info.
# Why: Without libelf those tests would fail, not test.
# From: Issue #398
def _build_can_rewrite_compressed_debug(case):
    for tool in ("readelf", "objcopy"):
        rc, _, _ = case.runcmd_unchecked("%s --version </dev/null" % tool)
        if rc != 0:
            return False
    probe = os.path.join(os.getcwd(), "libelf_probe_" + "p" * 40)
    os.mkdir(probe)
    with open(os.path.join(probe, "p.c"), "w") as f:
        f.write("int main(void){return 0;}\n")
    obj = os.path.join(probe, "p.o")
    # What: Keep comp_dir inline in .debug_info, then compress.
    # Why: Only the libelf path can rewrite it in there.
    rc, _, _ = case.runcmd_unchecked(
        "cd %s && %s -g -gz=zlib -gdwarf-4 -gstrict-dwarf "
        "-fno-merge-debug-strings -c p.c -o p.o" % (probe, case._cc))
    if rc != 0 or not _readelf_has_compressed_debug(case, obj):
        return False
    client = os.path.join(os.getcwd(), "lp")
    case.runcmd("h_fix_debug_info %s %s %s" % (obj, client, probe))
    dec = os.path.join(probe, "dec.o")
    case.runcmd("objcopy --decompress-debug-sections %s %s" % (obj, dec))
    _, dump, _ = case.runcmd_unchecked("readelf -p .debug_info %s" % dec)
    return client in dump

# What: Gdb_Case with SHF_COMPRESSED debug sections.
# Why: The server path rewrite must work compressed too.
# From: Issue #398
class GdbCompressedDebugInfo_Case(Gdb_Case):

    # What: Compile and link command: cc -g -gz=zlib.
    # Why: -gz=zlib makes the assembler compress debug info.
    def compiler(self):
        return self._cc + " -g -gz=zlib "

    # What: NotRun without libelf, -gz=zlib or real compression.
    # Why: Each missing piece would pass or fail spuriously.
    def runtest(self):
        if not _build_can_rewrite_compressed_debug(self):
            raise comfychair.NotRunError(
                'build has no libelf compressed-debug-section support')
        # What: NotRun if the toolchain rejects -gz=zlib.
        # Why: Mach-O, PE and old binutils cannot compress.
        error_rc, _, _ = self.runcmd_unchecked(
            self.compiler() + " -o junk -I. -c %s" % self.sourceFilename())
        if error_rc != 0:
            raise comfychair.NotRunError(
                'compiler/assembler does not support -gz=zlib')
        # What: NotRun if no section actually came out compressed.
        # Why: Else the compressed path is never exercised.
        if not _readelf_has_compressed_debug(self, "junk"):
            raise comfychair.NotRunError(
                '-gz=zlib accepted but produced no compressed debug section')
        Gdb_Case.runtest(self)

# What: dcc_fix_debug_info() rewrites inside .zdebug_*.
# Why: GNU-compressed sections need elf_compress_gnu().
# From: Issue #398
class FixDebugInfoGnuCompressed_Case(SimpleDistCC_Case):

    # What: Build a zlib-gnu fixture; run h_fix_debug_info.
    # Why: The harness makes the check deterministic, no gdb.
    def runtest(self):
        if not _build_can_rewrite_compressed_debug(self):
            raise comfychair.NotRunError(
                'build has no libelf compressed-debug-section support')

        # What: Compile in a long-named dir, comp_dir inline.
        # Why: zlib-gnu compresses .debug_info into .zdebug_info.
        server_dir = os.path.join(os.getcwd(), "srv_" + "d" * 40)
        os.mkdir(server_dir)
        with open(os.path.join(server_dir, "t.c"), "w") as f:
            f.write("int main(void){return 0;}\n")
        obj = os.path.join(server_dir, "t.o")
        rc, _, _ = self.runcmd_unchecked(
            "cd %s && %s -g -gdwarf-4 -gstrict-dwarf -fno-merge-debug-strings "
            "-Wa,--compress-debug-sections=zlib-gnu -c t.c -o t.o"
            % (server_dir, self._cc))
        if rc != 0:
            raise comfychair.NotRunError(
                "compiler/assembler does not support zlib-gnu debug compression")

        # What: NotRun unless a .zdebug_info section exists.
        # Why: Else the test passes without running the GNU path.
        rc, sects, _ = self.runcmd_unchecked("readelf -SW %s" % obj)
        if rc != 0 or ".zdebug_info" not in sects:
            raise comfychair.NotRunError(
                "toolchain did not emit a .zdebug_info section")

        # What: Rewrite server_dir to a shorter client path.
        # Why: The harness pads it with slashes to equal length.
        client_dir = os.path.join(os.getcwd(), "cl")
        self.runcmd("h_fix_debug_info %s %s %s" % (obj, client_dir, server_dir))

        # What: Decompress a copy; client path in, server path out.
        # Why: Proves the rewrite landed inside the section.
        dec = os.path.join(server_dir, "dec.o")
        self.runcmd("objcopy --decompress-debug-sections %s %s" % (obj, dec))
        _, dump, _ = self.runcmd_unchecked("readelf -p .debug_info %s" % dec)
        if client_dir not in dump:
            self.fail("client path not written into .zdebug_info section")
        if server_dir in dump:
            self.fail("server path still present in .zdebug_info after rewrite")

        # What: .zdebug_info must still be GNU-compressed.
        # Why: The rewrite recompresses in the original format.
        _, sects2, _ = self.runcmd_unchecked("readelf -SW %s" % obj)
        if ".zdebug_info" not in sects2:
            self.fail(".zdebug_info section lost its GNU compression")

# What: dcc_fix_debug_info() skips non-ELF or truncated input.
# Why: It must return 0, never crash or corrupt the file.
# From: Issue #398
class FixDebugInfoNonElf_Case(SimpleDistCC_Case):

    # What: Run h_fix_debug_info on a text file and a cut ELF.
    # Why: Needs no libelf; both paths share the skip.
    def runtest(self):
        server = os.path.join(os.getcwd(), "srv_" + "s" * 40)
        client = os.path.join(os.getcwd(), "cl")

        # What: A text file naming the server path stays unchanged.
        # Why: Only real ELF debug sections are ever rewritten.
        with open("not_elf.txt", "w") as f:
            f.write("not an ELF file, plain text mentioning %s here\n" % server)
        with open("not_elf.txt", "rb") as f:
            before = f.read()
        self.runcmd("h_fix_debug_info not_elf.txt %s %s" % (client, server))
        with open("not_elf.txt", "rb") as f:
            after = f.read()
        if before != after:
            self.fail("non-ELF input was modified by dcc_fix_debug_info")

        # What: The first 48 bytes of a real object must return 0.
        # Why: A malformed ELF header must be skipped, not crash.
        with open("t.c", "w") as f:
            f.write("int main(void){return 0;}\n")
        rc, _, _ = self.runcmd_unchecked(self._cc + " -g -c t.c -o real.o")
        if rc != 0:
            raise comfychair.NotRunError("could not build a probe object")
        with open("real.o", "rb") as rf:
            head = rf.read(48)
        with open("trunc.o", "wb") as wf:
            wf.write(head)
        self.runcmd("h_fix_debug_info trunc.o %s %s" % (client, server))

# What: The libelf rewrite also handles compressed ELF32.
# Why: gelf is class-independent; the raw path is not.
# From: Issue #398
class FixDebugInfoElf32Compressed_Case(SimpleDistCC_Case):

    # What: Build a compressed -m32 object, rewrite, inspect.
    # Why: NotRun without libelf, -m32 or real compression.
    def runtest(self):
        if not _build_can_rewrite_compressed_debug(self):
            raise comfychair.NotRunError(
                'build has no libelf compressed-debug-section support')
        server_dir = os.path.join(os.getcwd(), "srv32_" + "d" * 40)
        os.mkdir(server_dir)
        with open(os.path.join(server_dir, "t.c"), "w") as f:
            f.write("int main(void){return 0;}\n")
        obj = os.path.join(server_dir, "t.o")
        # What: comp_dir inline in .debug_info, 32-bit, -gz=zlib.
        # Why: Same fixture shape as the 64-bit case.
        rc, _, _ = self.runcmd_unchecked(
            "cd %s && %s -m32 -g -gz=zlib -gdwarf-4 -gstrict-dwarf "
            "-fno-merge-debug-strings -c t.c -o t.o" % (server_dir, self._cc))
        if rc != 0:
            raise comfychair.NotRunError("no working -m32 (32-bit toolchain absent)")
        rc, hdr, _ = self.runcmd_unchecked("readelf -h %s" % obj)
        if rc != 0 or "ELF32" not in hdr:
            raise comfychair.NotRunError("object is not ELF32")
        if not _readelf_has_compressed_debug(self, obj):
            raise comfychair.NotRunError("no SHF_COMPRESSED section on this m32 object")

        client_dir = os.path.join(os.getcwd(), "cl")
        self.runcmd("h_fix_debug_info %s %s %s" % (obj, client_dir, server_dir))

        dec = os.path.join(server_dir, "dec.o")
        self.runcmd("objcopy --decompress-debug-sections %s %s" % (obj, dec))
        _, dump, _ = self.runcmd_unchecked("readelf -p .debug_info %s" % dec)
        if client_dir not in dump:
            self.fail("client path not written into ELF32 compressed .debug_info")
        if server_dir in dump:
            self.fail("server path still present in ELF32 .debug_info after rewrite")
        if not _readelf_has_compressed_debug(self, obj):
            self.fail("ELF32 debug section lost its compression after rewrite")

# What: -fdebug-prefix-map= is rewritten for a remote distccd.
# Why: tweak_prefix_map_arguments_for_server() exists for it.
class GdbPrefixMap_Case(Gdb_Case):

    # What: cc -g with a prefix map and no recorded switches.
    # Why: Pre-GCC-6 put the map in DW_AT_producer (bug 69821).
    def compiler(self):
        return (self._cc + " -g -fdebug-prefix-map=%s=." % os.getcwd() +
                " -gno-record-gcc-switches")

    # What: Point gdb's source search at the cwd first.
    # Why: Mapped paths are relative to ".".
    def gdbCommands(self):
        return 'directory %s\n' % os.getcwd() + super().gdbCommands()

# What: Compile over an lzo-compressed connection.
# Why: The source must be large enough to use compression.
class CompressedCompile_Case(CompileHello_Case):

    # What: Print HELLO_WORLD with several system headers.
    # Why: More preprocessed text exercises compression.
    def source(self):
        return """
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "testhdr.h"
int main(void) {
    printf("%s\\n", HELLO_WORLD);
    return 0;
}
"""

    # What: Add ,lzo to the daemon's DISTCC_HOSTS entry.
    # Why: Turns on compression for this connection.
    def setupEnv(self):
        Compilation_Case.setupEnv(self)
        os.environ['DISTCC_HOSTS'] = (
            '127.0.0.1:%d,lzo' % self.server_port + _server_options)

# What: The joined -ofile spelling compiles remotely.
# Why: -otesttmp.o must be read as -o testtmp.o.
class DashONoSpace_Case(CompileHello_Case):
    # What: Compile with -otesttmp.o, no space.
    # Why: Exercises the joined -o form end to end.
    def compileCmd(self):
        return self.distcc_without_fallback() + \
               self._cc + " -otesttmp.o -c %s" % (self.sourceFilename())

    # What: NotRun on Solaris and OSF/1 toolchains.
    # Why: Their assemblers need a space after -o.
    def runtest(self):
        if sys.platform == 'sunos5':
            raise comfychair.NotRunError ('Sun assembler wants space after -o')
        elif sys.platform.startswith ('osf1'):
            raise comfychair.NotRunError ('GCC mips-tfile wants space after -o')
        else:
            CompileHello_Case.runtest (self)


# What: Compile to -o /dev/null remotely.
# Why: Writing the result to a device must still work.
class WriteDevNull_Case(CompileHello_Case):
    # What: Only compile; there is nothing to link or run.
    # Why: The output went to /dev/null.
    def runtest(self):
        self.compile()

    # What: Compile with -c -o /dev/null.
    # Why: distcc must not treat /dev/null as a normal file.
    def compileCmd(self):
        return self.distcc_without_fallback() + self._cc + \
               " -c -o /dev/null -c %s" % (self.sourceFilename())


# What: Compile two files from one command line, then link.
# Why: Multi-source lines must still build correctly.
class MultipleCompile_Case(Compilation_Case):
    # What: Start the daemon; write and close test1.c, test2.c.
    # Why: Both inputs must be flushed before compiling.
    def setup(self):
        WithDaemon_Case.setup(self)
        with open("test1.c", "w") as f:
            f.write("const char *msg = \"hello foreigner\";")
        with open("test2.c", "w") as f:
            f.write("""#include <stdio.h>

int main(void) {
   extern const char *msg;
   puts(msg);
   return 0;
}
""")

    # What: Compile both files in one line, then link them.
    # Why: Each object must come back under its own name.
    def runtest(self):
        self.runcmd(self.distcc()
                    + self._cc + " -c test1.c test2.c")
        self.runcmd(self.distcc()
                    + self._cc + " -o test test1.o test2.o")



# What: A failing #error in cpp.
# Why: The error text must reach the client's stderr.
class CppError_Case(CompileHello_Case):
    # What: Source consisting of one #error line.
    # Why: cpp itself must fail on it.
    def source(self):
        return '#error "not tonight dear"\n'

    # What: Exit 1, message on stderr, nothing on stdout.
    # Why: A remote cpp failure must look like a local one.
    def runtest(self):
        cmd = self.distcc() + self._cc + " -c testtmp.c"
        msgs, errs = self.runcmd(cmd, expectedResult=1)
        self.assert_re_search("not tonight dear", errs)
        self.assert_equal(msgs, '')


# What: An #include of a header that does not exist.
# Why: distcc must report cpp's failure, not hide it.
class BadInclude_Case(Compilation_Case):
    # What: Source including a missing header.
    # Why: Forces cpp to fail on the include.
    def source(self):
        return """#include <nosuchfilehere.h>
"""

    # What: Expect rc 1, or in pump mode gcc's own -MMD rc.
    # Why: gcc versions differ; pump always passes -MMD.
    def runtest(self):
        if _server_options.find('cpp') != -1:
            error_rc, _, _ = self.runcmd_unchecked(self._cc + " -MMD -E testtmp.c")
        else:
            error_rc = 1
        self.runcmd(self.distcc() + self._cc + " -o testtmp.o -c testtmp.c",
                    error_rc)


# What: Run cpp through distcc on text that is not C.
# Why: -E output must come back for any input.
class PreprocessPlainText_Case(Compilation_Case):
    # What: Clean env, write the source; no daemon.
    # Why: -E never goes remote, so no server is needed.
    def setup(self):
        self.stripEnvironment()
        self.createSource()
        self.initCompiler()

    # What: Plain text with #define and #if around it.
    # Why: cpp must select the "small foo!" branch.
    def source(self):
        return """#define FOO 3
#if FOO < 10
small foo!
#else
large foo!
#endif
/* comment ca? */
"""

    # What: Preprocess to a file, then read it back.
    # Why: NotRun in pump mode: the wrapper needs DISTCC_HOSTS.
    def runtest(self):
        if "cpp" in _server_options:
            raise comfychair.NotRunError('pump wrapper expects DISTCC_HOSTS')

        self.runcmd(self.distcc()
                    + self._cc + " -E testtmp.c -o testtmp.out")
        with open("testtmp.out") as f:
            out = f.read()
        # What: Search for "small foo!" rather than exact text.
        # Why: cpp versions differ in the whitespace they emit.
        self.assert_re_search("small foo!", out)

    # What: Nothing to tear down.
    # Why: This test starts no daemon.
    def teardown(self):
        pass


# What: Compile C source piped in on stdin.
# Why: "-" is not a source file, so it compiles locally.
# From: Issue #275
class CppFromStdin_Case(Compilation_Case):

    # What: A self-contained function with no #include.
    # Why: A quoted include has no defined base for stdin.
    def source(self):
        return "int foo(void) { return 0; }\n"

    # What: cat the source into "cc -x c -c - -o testtmp.o".
    # Why: Stdin input must still compile successfully.
    def runtest(self):
        cmd = ("cat %s | %s%s -x c -c -o testtmp.o -" %
               (self.sourceFilename(), self.distcc(), self._cc))
        self.runcmd(cmd)


# What: distccd --no-detach serves compiles in foreground.
# Why: It runs as our child, so startup must be watched.
class NoDetachDaemon_Case(CompileHello_Case):
    # What: Return the daemon log, or why it can't be read.
    # Why: Failure messages should show what the daemon said.
    def _readDaemonLog(self):
        try:
            with open(self.daemon_logfile, 'rt') as f:
                return f.read()
        except IOError as e:
            return "could not read daemon log: %s" % e

    # What: Exit status if the daemon already exited, else None.
    # Why: WNOHANG checks without blocking on a live daemon.
    def _collectDaemonStartupFailure(self):
        pid, status = os.waitpid(self.pid, os.WNOHANG)
        if not pid:
            return None
        if os.WIFEXITED(status):
            return os.WEXITSTATUS(status)
        return status

    # What: True if a fresh socket connects to the daemon.
    # Why: Some platforms keep a refused state on old sockets.
    def _canConnectToDaemon(self):
        sock = socket.socket()
        try:
            return sock.connect_ex(('127.0.0.1', self.server_port)) == 0
        finally:
            sock.close()

    # What: Spawn distccd --no-detach; retry up to 5 times.
    # Why: A port clash or slow bind must not fail the test.
    def startDaemon(self):
        max_start_attempts = 5
        attempts = 0
        while attempts < max_start_attempts:
            attempts += 1
            try:
                os.remove(self.daemon_pidfile)
            except OSError as e:
                if e.errno != errno.ENOENT:
                    raise

            # What: Listen on 127.0.0.1 only.
            # Why: The readiness probe connects to that address.
            cmd = (self.distccd() +
                   "--no-detach --daemon --verbose --log-file %s --pid-file %s "
                   "--port %d --listen 127.0.0.1 --allow 127.0.0.1 "
                   "--enable-tcp-insecure --sysroot %s" %
                   (_ShellSafe(self.daemon_logfile),
                    _ShellSafe(self.daemon_pidfile),
                    self.server_port,
                    _ShellSafe(self.daemon_sysroot)))
            self.pid = self.runcmd_background(cmd)

            # What: Wait for a connect, then for our own pidfile.
            # Why: Another listener on the port must not count.
            deadline = time.time() + 30
            retry = False
            while not self._canConnectToDaemon():
                result = self._collectDaemonStartupFailure()
                if result is not None:
                    if result == EXIT_BIND_FAILED:
                        self.server_port += 1
                        retry = True
                        break
                    self.fail("failed to start daemon: %d" % result)
                if time.time() > deadline:
                    self.log("distccd log before startup timeout:\n%s" %
                             self._readDaemonLog())
                    self.killDaemon()
                    self.server_port += 1
                    retry = True
                    break
                time.sleep(0.2)
            else:
                while not os.path.exists(self.daemon_pidfile):
                    result = self._collectDaemonStartupFailure()
                    if result is not None:
                        if result == EXIT_BIND_FAILED:
                            self.server_port += 1
                            retry = True
                            break
                        self.fail("failed to start daemon: %d" % result)
                    if time.time() > deadline:
                        self.log("distccd log before pidfile timeout:\n%s" %
                                 self._readDaemonLog())
                        self.killDaemon()
                        self.server_port += 1
                        retry = True
                        break
                    time.sleep(0.2)
                if retry:
                    continue
                self.add_cleanup(self.killDaemon)
                return
            if retry:
                continue
        self.log("distccd log after startup attempts:\n%s" %
                 self._readDaemonLog())
        self.fail("failed to start daemon after %d attempts" % max_start_attempts)

    # What: SIGTERM the pidfile's pid, then reap our child.
    # Why: That ends distccd, its children and the shell.
    def killDaemon(self):
        try:
            with open(self.daemon_pidfile, 'rt') as f:
                daemon_pid = int(f.read())
        except IOError:
            try:
                os.kill(self.pid, signal.SIGTERM)
                os.waitpid(self.pid, 0)
            except OSError:
                pass
            return
        os.kill(daemon_pid, signal.SIGTERM)

        pid, ret = os.waitpid(self.pid, 0)
        self.assert_equal(self.pid, pid)


# What: Root-only: autogroup nice after a --user drop.
# Why: Root is dropped before the write; it fails EPERM.
# From: Issue #77
class AutogroupNicenessPrivilegeDrop_Case(WithDaemon_Case):

    # What: Unprivileged account distccd drops to.
    # Why: nobody always exists; "distcc" mostly does not.
    DROP_USER = "nobody"
    # What: Negative niceness requested with --nice.
    # Why: Only a negative value needs CAP_SYS_NICE.
    NICE_VALUE = -5

    # What: Put the scratch tree under /tmp, not the checkout.
    # Why: Ancestor chmods must not touch a private $HOME.
    def _enter_rundir(self):
        self.basedir = os.getcwd()
        self.add_cleanup(self._restore_directory)
        self.rundir = tempfile.mkdtemp(prefix='distccd-autogroup-niceness-')
        self.tmpdir = os.path.join(self.rundir, 'tmp')
        os.makedirs(self.tmpdir)
        os.chdir(self.rundir)
        self.add_cleanup(self._remove_rundir)

    # What: Remove the /tmp scratch tree.
    # Why: Runs before the chdir back; basedir is absolute.
    def _remove_rundir(self):
        shutil.rmtree(self.rundir, ignore_errors=True)

    # What: NotRun unless root on Linux with autogroups on.
    # Why: Only then can the privilege drop be observed.
    def setup(self):
        self.require_root()
        if not sys.platform.startswith('linux'):
            raise comfychair.NotRunError(
                'autogroups are a Linux-only kernel feature')
        try:
            with open('/proc/sys/kernel/sched_autogroup_enabled', 'rt') as f:
                if f.read().strip() != '1':
                    raise comfychair.NotRunError(
                        'kernel autogroup scheduling is disabled '
                        '(sched_autogroup_enabled != 1)')
        except IOError:
            raise comfychair.NotRunError(
                'kernel has no sched_autogroup_enabled knob (autogroups '
                'unsupported on this kernel)')
        # What: Use SimpleDistCC_Case.setup, not WithDaemon_Case's.
        # Why: That would start the daemon without --user/--nice.
        SimpleDistCC_Case.setup(self)
        self.daemon_pidfile = os.path.join(os.getcwd(), "daemonpid.tmp")
        self.daemon_logfile = os.path.join(os.getcwd(), "distccd.log")
        self.daemon_sysroot = os.getcwd()
        self.server_port = DISTCC_TEST_PORT
        self.startDaemon()

    # What: Log owner and mode of path and every ancestor.
    # Why: Any ancestor without o+x blocks the dropped user.
    def _log_ancestor_permissions(self, path):
        p = os.path.abspath(path)
        while True:
            st = os.stat(p)
            self.log("ancestor permission check: %s uid=%d gid=%d mode=%o"
                      % (p, st.st_uid, st.st_gid, S_IMODE(st.st_mode)))
            parent = os.path.dirname(p)
            if parent == p:
                break
            p = parent

    # What: Put back each saved ancestor mode, newest first.
    # Why: No permission change may outlive the test run.
    def _restore_ancestor_modes(self, saved_modes):
        for p, original_mode in reversed(saved_modes):
            try:
                os.chmod(p, original_mode)
                self.log("restored mode %o on %s" % (original_mode, p))
            except OSError as e:
                # What: Log, do not fail, if a mode cannot be restored.
                # Why: The ancestor may already be gone at cleanup.
                self.log("could not restore mode on %s: %s" % (p, e))

    # What: Add o+x to path and ancestors; restore on cleanup.
    # Why: Opening a file needs exec on every ancestor dir.
    def _ensure_ancestors_traversable(self, path, uid, gid):
        changed = []
        p = os.path.abspath(path)
        while True:
            st = os.stat(p)
            mode = S_IMODE(st.st_mode)
            if not (mode & S_IXOTH):
                os.chmod(p, mode | S_IXOTH)
                changed.append((p, mode))
                self.log("chmod o+x on %s (was %o, owner uid=%d)"
                          % (p, mode, st.st_uid))
            parent = os.path.dirname(p)
            if parent == p:
                break
            p = parent
        if changed:
            self.add_cleanup(lambda: self._restore_ancestor_modes(changed))

    # What: Chown the daemon's dirs to DROP_USER, then start it.
    # Why: It drops root before opening its log and pidfile.
    def startDaemon(self):
        drop_pw = pwd.getpwnam(self.DROP_USER)

        self._log_ancestor_permissions(self.daemon_sysroot)
        self._ensure_ancestors_traversable(
            self.daemon_sysroot, drop_pw.pw_uid, drop_pw.pw_gid)

        old_tmpdir = os.environ['TMPDIR']
        daemon_tmpdir = old_tmpdir + "/daemon_tmp"
        os.mkdir(daemon_tmpdir)
        os.chown(daemon_tmpdir, drop_pw.pw_uid, drop_pw.pw_gid)
        os.environ['TMPDIR'] = daemon_tmpdir
        os.mkdir("daemon")
        os.chown("daemon", drop_pw.pw_uid, drop_pw.pw_gid)
        os.chdir("daemon")
        # What: Also chown daemon_sysroot to DROP_USER.
        # Why: The pidfile and log live there, still root-owned.
        os.chown(self.daemon_sysroot, drop_pw.pw_uid, drop_pw.pw_gid)
        try:
            while 1:
                cmd = self.daemon_command()
                result, out, err = self.runcmd_unchecked(cmd)
                if result == 0:
                    break
                elif result == EXIT_BIND_FAILED:
                    self.server_port += 1
                    continue
                else:
                    self.fail("failed to start daemon: %d" % result)
            self.add_cleanup(self.killDaemon)
        finally:
            os.environ['TMPDIR'] = old_tmpdir
            os.chdir("..")

    # What: distccd with --nice, --user and debug logging.
    # Why: Together they expose dparent.c's ordering gap.
    def daemon_command(self):
        return (self.distccd() +
                "--verbose --log-level debug --daemon --nice %d --user %s "
                "--lifetime=%d --log-file %s --pid-file %s --port %d "
                "--allow 127.0.0.1 --enable-tcp-insecure --sysroot %s"
                % (self.NICE_VALUE, self.DROP_USER, self.daemon_lifetime(),
                   _ShellSafe(self.daemon_logfile),
                   _ShellSafe(self.daemon_pidfile),
                   self.server_port,
                   _ShellSafe(self.daemon_sysroot)))

    # What: Seconds to wait for the autogroup warning.
    # Why: The pidfile exists before the child writes it.
    AUTOGROUP_WARNING_TIMEOUT = 15

    # What: Process nice < 0, EPERM logged, autogroup nice 0.
    # Why: Documents the known gap so it cannot regress.
    def runtest(self):
        with open(self.daemon_pidfile, 'rt') as f:
            pid = int(f.read())

        # What: The process niceness itself must be negative.
        # Why: main() set it as root, before any privilege drop.
        actual_niceness = os.getpriority(os.PRIO_PROCESS, pid)
        self.assert_(actual_niceness < 0,
                     "expected negative process niceness for pid %d, got %d"
                     % (pid, actual_niceness))

        # What: Wait for the EPERM warning on the autogroup write.
        # Why: It is logged last, so /proc is final after it.
        self.waitForLogPattern(
            r'autogroup nice -?\d+ failed: Operation not permitted',
            self.AUTOGROUP_WARNING_TIMEOUT)

        # What: Read /proc/<pid>/autogroup directly.
        # Why: Real OS state, not only the log line, is evidence.
        with open('/proc/%d/autogroup' % pid, 'rt') as f:
            autogroup_content = f.read()
        self.log("autogroup content for pid %d: %r" % (pid, autogroup_content))
        m = re.search(r'nice (-?\d+)', autogroup_content)
        self.assert_(m is not None,
                     "could not parse /proc/%d/autogroup: %r"
                     % (pid, autogroup_content))
        autogroup_nice = int(m.group(1))

        # What: The fresh autogroup must still be at nice 0.
        # Why: Known gap; a fix must update this test and doc.
        # From: Issue #77
        self.assert_equal(autogroup_nice, 0)


# What: Root-only: the compiler child runs as --user.
# Why: Reuses the autogroup case's root/chown setup.
# From: Issue #275
class UserPrivilegeDropFunctional_Case(AutogroupNicenessPrivilegeDrop_Case):

    # What: A fake compiler prints `id -u` via SOUT; check it.
    # Why: Proves the drop reaches the forked compiler child.
    def runtest(self):
        drop_pw = pwd.getpwnam(self.DROP_USER)

        compiler = os.path.abspath("uid_reporting_compiler")
        f = open(compiler, "w")
        try:
            f.write("#!/bin/sh\n"
                     "id -u\n"
                     "while [ $# -gt 0 ]; do\n"
                     "  if [ \"$1\" = \"-o\" ]; then shift; touch \"$1\"; fi\n"
                     "  shift\n"
                     "done\n")
        finally:
            f.close()
        # What: Chown the fake compiler to DROP_USER, mode 0700.
        # Why: The dropped child must exec it; world bits would leak.
        os.chown(compiler, drop_pw.pw_uid, drop_pw.pw_gid)
        os.chmod(compiler, 0o700)

        os.environ['DISTCC_HOSTS'] = '127.0.0.1:%d' % self.server_port
        os.environ['DISTCC_LOG'] = os.path.join(os.getcwd(), 'distcc.log')
        os.environ['DISTCC_VERBOSE'] = '1'
        # What: Write and close testtmp.i before distcc runs.
        # Why: The client uploads it; PyPy may defer a close.
        with open("testtmp.i", "wt") as f:
            f.write("int main() {}")

        out, errs = self.runcmd(self.distcc_without_fallback() + compiler +
                                " -c testtmp.i -o testtmp.o")
        reported_uid = int(out.strip())
        self.assert_(reported_uid != 0,
                     "compiler child ran as uid 0 (root) -- --user's "
                     "privilege drop did not reach it")
        self.assert_equal(reported_uid, drop_pw.pw_uid)


# What: Compile and link with no compiler named.
# Why: distcc must fall back to the implicit "cc".
class ImplicitCompiler_Case(CompileHello_Case):
    # What: Compile with "distcc -c testtmp.c".
    # Why: No compiler argument at all.
    def compileCmd(self):
        return self.distcc() + "-c testtmp.c"

    # What: Link with "distcc -o testtmp testtmp.o".
    # Why: Object-first order works too; this is the default.
    # From: Issue #275
    def linkCmd(self):
        return self.distcc() + "-o testtmp testtmp.o "

    # What: NotRun on HP-UX 10 or without a working cc.
    # Why: The implicit compiler must exist and be ANSI.
    def runtest(self):
        if sys.platform == 'hp-ux10':
            raise comfychair.NotRunError ('HP-UX bundled C compiler non-ANSI')
        error_rc, _, _ = self.runcmd_unchecked("cc -c testtmp.c")
        self.runcmd_unchecked("rm -f testtmp.o")
        if error_rc != 0:
            raise comfychair.NotRunError ('Cannot find working "cc"')
        else:
            CompileHello_Case.runtest (self)


# What: Non-ASCII source text survives the round trip.
# Why: The include server must handle UTF-8 content.
class Unicode_Case(Compilation_Case):
    # What: Print a string containing an emoji.
    # Why: Multi-byte UTF-8 stresses compression and parsing.
    def source(self):
        return """
#include <stdio.h>

int main(void) {
    puts("Unicode is hard! 😭");
    return 0;
}
"""

    # What: The program must print the emoji string intact.
    # Why: Any byte change shows up in the output.
    def checkBuiltProgramMsgs(self, msgs):
        self.assert_equal(msgs, "Unicode is hard! 😭\n")


# What: -D defines on the command line.
# Why: A quoted -D value must reach the preprocessor.
class DashD_Case(Compilation_Case):
    # What: Print the MESSAGE macro.
    # Why: It only exists via the -D option.
    def source(self):
        return """
#include <stdio.h>

int main(void) {
    printf("%s\\n", MESSAGE);
    return 0;
}
"""

    # What: Pass -DMESSAGE="hello DashD", shell-quoted.
    # Why: The command line goes through the shell.
    def compileOpts(self):
        return "'-DMESSAGE=\"hello DashD\"'"

    # What: The program must print "hello DashD".
    # Why: Proves the define arrived with its quotes.
    def checkBuiltProgramMsgs(self, msgs):
        self.assert_equal(msgs, "hello DashD\n")


# What: An empty #define named like a real header.
# Why: It must not break the include server's parsing.
class EmptyDefine_Case(Compilation_Case):
    # What: #define testhdr, then include str(testhdr.h).
    # Why: The macro name collides with the header's name.
    def source(self):
        return """
#include <stdio.h>

#define testhdr

#define str(x) #x
#include str(testhdr.h)

int main(void) {
    printf("%s\\n", "hello world");
    return 0;
}
"""

    # What: The program must print "hello world".
    # Why: Proves the include resolved and it built.
    def checkBuiltProgramMsgs(self, msgs):
        self.assert_equal(msgs, "hello world\n")



# What: -MD -MFfile -MTtarget together.
# Why: The custom target must land in the custom file.
class DashMD_DashMF_DashMT_Case(CompileHello_Case):

    # What: Ask for dotd_filename with target_name_42.
    # Why: Joined -MF/-MT forms must be honoured remotely.
    def compileOpts(self):
        return "-MD -MFdotd_filename -MTtarget_name_42"

    # What: Compile, then read the .d file it closed.
    # Why: The target name must be inside the file.
    def runtest(self):
        try:
          os.remove('dotd_filename')
        except OSError:
          pass
        self.compile();
        with open("dotd_filename") as f:
            dotd_contents = f.read()
        self.assert_re_search("target_name_42", dotd_contents)


# What: -MMD writes a dependency file remotely.
# Why: Bare -M is local; ScanArgs_Case covers it.
# From: Issue #275
class DashMMD_Case(CompileHello_Case):

    # What: Ask for -MMD into dotd_mmd_filename.
    # Why: -MD alone is covered by the case above.
    def compileOpts(self):
        return "-MMD -MFdotd_mmd_filename"

    # What: Compile; the .d file must name testtmp.o.
    # Why: Proves -MMD output came back from the server.
    def runtest(self):
        try:
            os.remove('dotd_mmd_filename')
        except OSError:
            pass
        self.compile()
        with open("dotd_mmd_filename") as f:
            dotd_contents = f.read()
        self.assert_re_search("testtmp.o", dotd_contents)


# What: -Wp,-MD,depsfile passed through to cpp.
# Why: The -Wp form hides -MD from a naive scan.
class DashWpMD_Case(CompileHello_Case):

    # What: Ask cpp for depsfile via -Wp,-MD.
    # Why: distcc must still return the dependency file.
    def compileOpts(self):
        return "-Wp,-MD,depsfile"

    # What: Compile; depsfile must list both headers.
    # Why: Proves the dependency file is complete.
    def runtest(self):
        try:
          os.remove('depsfile')
        except OSError:
          pass
        self.compile()
        with open('depsfile') as f:
            deps = f.read()
        self.assert_re_search(r"testhdr\.h", deps)
        self.assert_re_search(r"stdio\.h", deps)


# What: Protocol 5000: zstd with server-side cpp.
# Why: Forces ,zstd,cpp so it never negotiates lzo pump.
# From: Issue #101
class ZstdPumpCompile_Case(CompileHello_Case):

    # What: Request a .d file with -MD -MF.
    # Why: zstd DOTD uses a 2-int length, unlike LZO.
    def compileOpts(self):
        return "-MD -MFzstd_pump_test.d"

    # What: NotRun outside pump mode; set ,zstd,cpp hosts.
    # Why: ,cpp needs a running include server.
    def setup(self):
        if _server_options.find('cpp') == -1:
            raise comfychair.NotRunError(
                "zstd+pump (DCC_VER_5000) needs an actual pump-mode test run "
                "(see --pump); this run has no include server available")
        CompileHello_Case.setup(self)
        os.environ['DISTCC_HOSTS'] = (
            '127.0.0.1:%d,zstd,cpp' % self.server_port)

    # What: Compile; check the .d file and protover 5000.
    # Why: NotRun if this build has no zstd support.
    def runtest(self):
        out, unused_err = self.runcmd(self.distcc() + "--version")
        if 'Zstd compression support' not in out:
            raise comfychair.NotRunError(
                "this distcc build has no zstd support (configure "
                "--without-zstd)")
        try:
            os.remove('zstd_pump_test.d')
        except OSError:
            pass
        CompileHello_Case.runtest(self)

        # What: The .d file must exist and name testhdr.h.
        # Why: A bad DOTD decode can still report success.
        with open('zstd_pump_test.d') as f:
            deps = f.read()
        self.assert_re_search(r"testhdr\.h", deps)

        # What: The server log must show protover 5000.
        # Why: Rules out a silent fallback to another protocol.
        with open(self.daemon_logfile) as f:
            log = f.read()
        self.assert_re_search(
            r"accepted job with protover 5000 \(compr \d+, cpp_where \d+\)",
            log)


# What: Helpers for the split-DWARF pump protocol tests.
# Why: 600x sends the .dwo (DDWO) before the .d (DOTD).
# From: Issue #398
class SplitDwarfPumpMixin:

    # What: NotRun without pump mode, 600x support or .dwo.
    # Why: Each gap would make the assertions meaningless.
    def _require_pump_and_split_dwarf(self):
        if _server_options.find('cpp') == -1:
            raise comfychair.NotRunError(
                "split-dwarf pump needs an actual pump-mode test run (see "
                "--pump); this run has no include server available")
        # What: NotRun on a --disable-split-dwarf-pump build.
        # Why: The client then never selects protocol 600x.
        out, unused_err = self.runcmd(self.distcc() + "--version")
        if 'split-DWARF pump-mode support' not in out:
            raise comfychair.NotRunError(
                "this distcc build has no split-DWARF pump support "
                "(configure --disable-split-dwarf-pump)")
        # What: NotRun if -gsplit-dwarf makes no .dwo locally.
        # Why: Without one, there is no DDWO to test.
        rc, _, _ = self.runcmd_unchecked(
            self._cc + " -g -gsplit-dwarf -c %s -o sdprobe.o"
            % self.sourceFilename())
        produced = os.path.exists("sdprobe.dwo")
        for f in ("sdprobe.o", "sdprobe.dwo"):
            try:
                os.remove(f)
            except OSError:
                pass
        if rc != 0 or not produced:
            raise comfychair.NotRunError(
                "compiler produces no external .dwo for -gsplit-dwarf")

    # What: Check .dwo, .d file and the logged protover.
    # Why: Together they prove the 600x result stream.
    def _check_split_dwarf_results(self, depsfile, protover, want_dwo=True):
        if want_dwo:
            if not os.path.exists("testtmp.dwo") or \
               os.path.getsize("testtmp.dwo") == 0:
                self.fail("split-dwarf .dwo missing/empty after remote compile")
        # What: The .d file must still arrive after the DDWO.
        # Why: Reading DDWO must not swallow the rest.
        with open(depsfile) as f:
            deps = f.read()
        self.assert_re_search(r"testhdr\.h", deps)
        # What: The server log must show the exact protover.
        # Why: Rules out a fallback to another protocol.
        with open(self.daemon_logfile) as f:
            log = f.read()
        self.assert_re_search(
            r"accepted job with protover %d \(compr \d+, cpp_where \d+\)"
            % protover, log)


# What: Protocol 6000: LZO, server-side cpp, split DWARF.
# Why: Forces ,lzo,cpp so exactly 6000 is negotiated.
# From: Issue #398
class SplitDwarfLzoPumpCompile_Case(SplitDwarfPumpMixin, CompileHello_Case):

    # What: Name of this case's dependency file.
    # Why: Each 600x case checks its own .d file.
    _depsfile = "split_dwarf_lzo_test.d"

    # What: -g -gsplit-dwarf plus -MD into _depsfile.
    # Why: Makes the server send both DDWO and DOTD.
    def compileOpts(self):
        return "-g -gsplit-dwarf -MD -MF" + self._depsfile

    # What: Point DISTCC_HOSTS at ,lzo,cpp.
    # Why: Selects protocol 6000 for split DWARF.
    def setup(self):
        CompileHello_Case.setup(self)
        os.environ['DISTCC_HOSTS'] = '127.0.0.1:%d,lzo,cpp' % self.server_port

    # What: Clean old outputs, compile, check 6000 results.
    # Why: Stale .dwo or .d files would mask a failure.
    def runtest(self):
        self._require_pump_and_split_dwarf()
        for f in ("testtmp.dwo", self._depsfile):
            try:
                os.remove(f)
            except OSError:
                pass
        CompileHello_Case.runtest(self)
        self._check_split_dwarf_results(self._depsfile, 6000)


# What: Protocol 6001: zstd, server-side cpp, split DWARF.
# Why: Forces ,zstd,cpp so exactly 6001 is negotiated.
# From: Issue #398
class SplitDwarfZstdPumpCompile_Case(SplitDwarfPumpMixin, CompileHello_Case):

    # What: Name of this case's dependency file.
    # Why: Each 600x case checks its own .d file.
    _depsfile = "split_dwarf_zstd_test.d"

    # What: -g -gsplit-dwarf plus -MD into _depsfile.
    # Why: Makes the server send both DDWO and DOTD.
    def compileOpts(self):
        return "-g -gsplit-dwarf -MD -MF" + self._depsfile

    # What: Point DISTCC_HOSTS at ,zstd,cpp.
    # Why: Selects protocol 6001 for split DWARF.
    def setup(self):
        CompileHello_Case.setup(self)
        os.environ['DISTCC_HOSTS'] = '127.0.0.1:%d,zstd,cpp' % self.server_port

    # What: NotRun without zstd; compile, check 6001 results.
    # Why: Stale .dwo or .d files would mask a failure.
    def runtest(self):
        out, unused_err = self.runcmd(self.distcc() + "--version")
        if 'Zstd compression support' not in out:
            raise comfychair.NotRunError(
                "this distcc build has no zstd support (configure --without-zstd)")
        self._require_pump_and_split_dwarf()
        for f in ("testtmp.dwo", self._depsfile):
            try:
                os.remove(f)
            except OSError:
                pass
        CompileHello_Case.runtest(self)
        self._check_split_dwarf_results(self._depsfile, 6001)


# What: Protocol 6000 with an empty DDWO, then the DOTD.
# Why: A zero-length DDWO must not swallow what follows.
# From: Issue #398
class SplitDwarfEmptyDwoPump_Case(SplitDwarfPumpMixin, CompileHello_Case):

    # What: Name of this case's dependency file.
    # Why: Each 600x case checks its own .d file.
    _depsfile = "split_dwarf_empty_test.d"
    # What: Compile with clang instead of the suite's cc.
    # Why: Only clang's -gsplit-dwarf -g0 emits no .dwo.
    _cc_override = "clang"

    # What: Request split DWARF but -g0, plus -MD.
    # Why: Selects 6000 while producing no .dwo at all.
    def compileOpts(self):
        return "-g -gsplit-dwarf -g0 -MD -MF" + self._depsfile

    # What: Compile with clang through distcc, no fallback.
    # Why: A broken stream must fail, not compile locally.
    def compileCmd(self):
        return (self.distcc_without_fallback() + self._cc_override +
                " -o testtmp.o " + self.compileOpts() +
                " -c " + self.sourceFilename())

    # What: Link with clang through distcc.
    # Why: The same compiler must link the object.
    def linkCmd(self):
        return (self.distcc() + self._cc_override +
                " -o testtmp testtmp.o " + self.libraries())

    # What: Point DISTCC_HOSTS at ,lzo,cpp.
    # Why: Selects protocol 6000 for split DWARF.
    def setup(self):
        CompileHello_Case.setup(self)
        os.environ['DISTCC_HOSTS'] = '127.0.0.1:%d,lzo,cpp' % self.server_port

    # What: NotRun unless pump, 600x, clang and no .dwo hold.
    # Why: Otherwise no empty DDWO would be exercised.
    def runtest(self):
        if _server_options.find('cpp') == -1:
            raise comfychair.NotRunError(
                "split-dwarf pump needs an actual pump-mode test run (--pump)")
        out, unused_err = self.runcmd(self.distcc() + "--version")
        if 'split-DWARF pump-mode support' not in out:
            raise comfychair.NotRunError(
                "this distcc build has no split-DWARF pump support")
        rc, _, _ = self.runcmd_unchecked("command -v " + self._cc_override)
        if rc != 0:
            raise comfychair.NotRunError("clang not available")
        # What: Probe that this clang emits no .dwo under -g0.
        # Why: Else there is no empty DDWO to exercise.
        rc, _, _ = self.runcmd_unchecked(
            self._cc_override + " -g -gsplit-dwarf -g0 -c %s -o sdprobe.o"
            % self.sourceFilename())
        produced = os.path.exists("sdprobe.dwo")
        for f in ("sdprobe.o", "sdprobe.dwo"):
            try:
                os.remove(f)
            except OSError:
                pass
        if rc != 0 or produced:
            raise comfychair.NotRunError(
                "this clang still emits a .dwo under -g0; can't force empty DDWO")
        for f in ("testtmp.dwo", self._depsfile):
            try:
                os.remove(f)
            except OSError:
                pass
        CompileHello_Case.runtest(self)
        # What: No .dwo may appear, but the .d file must.
        # Why: The empty-DDWO skip must not end the stream.
        if os.path.exists("testtmp.dwo"):
            self.fail("unexpected .dwo for the -g0 empty-DDWO case")
        self._check_split_dwarf_results(self._depsfile, 6000, want_dwo=False)


# What: Sequential jobs fill hosts in DISTCC_HOSTS order.
# Why: dcc_lock_one() takes the first free slot per index.
# From: Issue #275
class HostSelectionAlgorithm_Case(CompileHello_Case):

    # What: Two one-slot daemons and a sleeping fake compiler.
    # Why: Job 1 must still hold host A's only slot.
    def setup(self):
        SimpleDistCC_Case.setup(self)
        self.slow_compiler = os.path.abspath("slow_compiler")
        f = open(self.slow_compiler, "w")
        try:
            f.write("#!/bin/sh\nsleep 3\n")
        finally:
            f.close()
        os.chmod(self.slow_compiler, 0o700)

        self.daemon_a_pidfile = os.path.join(os.getcwd(), "daemon_a.pid")
        self.daemon_a_logfile = os.path.join(os.getcwd(), "daemon_a.log")
        self.daemon_b_pidfile = os.path.join(os.getcwd(), "daemon_b.pid")
        self.daemon_b_logfile = os.path.join(os.getcwd(), "daemon_b.log")
        self.port_a = DISTCC_TEST_PORT
        self.port_b = DISTCC_TEST_PORT + 1

        self._start_daemon(self.port_a, self.daemon_a_pidfile,
                           self.daemon_a_logfile)
        self._start_daemon(self.port_b, self.daemon_b_pidfile,
                           self.daemon_b_logfile)
        self.add_cleanup(lambda: self._kill_daemon(self.daemon_a_pidfile))
        self.add_cleanup(lambda: self._kill_daemon(self.daemon_b_pidfile))

        os.environ['DISTCC_HOSTS'] = (
            '127.0.0.1:%d/1 127.0.0.1:%d/1' % (self.port_a, self.port_b))
        os.environ['DISTCC_LOG'] = os.path.join(os.getcwd(), 'distcc.log')
        os.environ['DISTCC_VERBOSE'] = '1'
        self.createSource()

    # What: Start one single-job distccd on port.
    # Why: --jobs 1 gives each host exactly one slot.
    def _start_daemon(self, port, pidfile, logfile):
        cmd = (self.distccd() +
               "--verbose --lifetime=60 --daemon --jobs 1 --log-file %s "
               "--pid-file %s --port %d --allow 127.0.0.1 "
               "--enable-tcp-insecure" %
               (_ShellSafe(logfile), _ShellSafe(pidfile), port))
        result, out, err = self.runcmd_unchecked(cmd)
        if result != 0:
            self.fail("failed to start daemon on port %d: %s" %
                      (port, err))

    # What: SIGTERM the daemon named in pidfile, if any.
    # Why: No pidfile means the daemon already stopped.
    def _kill_daemon(self, pidfile):
        try:
            with open(pidfile, 'rt') as f:
                pid = int(f.read())
        except IOError:
            return
        os.kill(pid, signal.SIGTERM)

    # What: Poll logfile for pattern; fail after timeout.
    # Why: Reopening shows output the daemon flushed since.
    def _waitForPattern(self, logfile, pattern, timeout):
        deadline = time.time() + timeout
        content = ""
        while True:
            try:
                with open(logfile) as f:
                    content = f.read()
            except IOError:
                content = ""
            if re.search(pattern, content):
                return content
            if time.time() > deadline:
                self.fail("timed out after %ds waiting for %r in %s, got:\n%s" %
                          (timeout, pattern, logfile, content))
            time.sleep(0.2)

    # What: Job 1 must run on host A, job 2 then on host B.
    # Why: Each daemon's own log shows who served which job.
    def runtest(self):
        job1_pid = self.runcmd_background(
            self.distcc_without_fallback() + self.slow_compiler +
            " -c testtmp.c -o job1.o")
        # What: Wait until host A's log shows job 1 running.
        # Why: Proves the first job took the first host.
        self._waitForPattern(self.daemon_a_logfile,
                             r"forking to execute.*slow_compiler", 10)

        # What: Run job 2; host B's log must show it.
        # Why: Host A's only slot is still held by job 1.
        self.runcmd(self.distcc_without_fallback() + self.slow_compiler +
                    " -c testtmp.c -o job2.o")
        with open(self.daemon_b_logfile) as f:
            daemon_b_log = f.read()
        self.assert_re_search(r"forking to execute.*slow_compiler",
                              daemon_b_log)

        os.waitpid(job1_pid, 0)


# What: distcc --scan-includes lists what would be sent.
# Why: Covers files, symlinks, dirs and system dirs.
class ScanIncludes_Case(CompileHello_Case):

    # What: Make testhdr.h a symlink; add a dir and a header.
    # Why: Each kind of entry must appear in the listing.
    def createSource(self):
      CompileHello_Case.createSource(self)
      self.runcmd("mv testhdr.h test_header.h")
      self.runcmd("ln -s test_header.h testhdr.h")
      self.runcmd("mkdir test_subdir")
      self.runcmd("touch test_another_header.h")

    # What: Header that includes via test_subdir/../.
    # Why: The directory must be listed though unused.
    def headerSource(self):
        return """
#define HELLO_WORLD "hello world"
#include "test_subdir/../test_another_header.h"
"""

    # What: Compile command with --scan-includes, no fallback.
    # Why: It must print the include list, not compile.
    def compileCmd(self):
        return self.distcc_without_fallback() + "--scan-includes " + \
               self._cc + " -o testtmp.o " + self.compileOpts() + \
               " -c %s" % (self.sourceFilename())

    # What: Pump: check each listed entry. Else: rc 100.
    # Why: Without ,cpp there is no include server to ask.
    def runtest(self):
        cmd = self.compileCmd()
        rc, out, err = self.runcmd_unchecked(cmd)
        with open('distcc.log') as f:
            log = f.read()
        pump_mode = _server_options.find('cpp') != -1
        if pump_mode:
          if err != '':
              self.fail("distcc command %s produced stderr:\n%s" % (repr(cmd), err))
          if rc != 0:
              self.fail("distcc command %s failed:\n%s" % (repr(cmd), rc))
          self.assert_re_search(
              r"FILE      /.*/ScanIncludes_Case/testtmp.c", out);
          self.assert_re_search(
              r"FILE      /.*/ScanIncludes_Case/test_header\.h", out);
          self.assert_re_search(
              r"FILE      /.*/ScanIncludes_Case/test_another_header\.h", out);
          self.assert_re_search(
              r"SYMLINK   /.*/ScanIncludes_Case/testhdr\.h", out);
          self.assert_re_search(
              r"DIRECTORY /.*/ScanIncludes_Case/test_subdir", out);
          self.assert_re_search(
              r"SYSTEMDIR /.*", out);
        else:
          self.assert_re_search(r"ERROR: '--scan_includes' specified, but "
                                "distcc wouldn't have used include server "
                                ".make sure hosts list includes ',cpp' option",
                                log)
          self.assert_equal(rc, 100)
          self.assert_equal(out, '')
          self.assert_equal(err, '')

# What: Pump mode creates dirs only used as foo/../bar.h.
# Why: Without them the include fails, so a build proves it.
class ForceDirectory_Case(CompileHello_Case):

    # What: Make testhdr.h a symlink; add a dir and a header.
    # Why: test_subdir holds no header but must exist remotely.
    def createSource(self):
      CompileHello_Case.createSource(self)
      self.runcmd("mv testhdr.h test_header.h")
      self.runcmd("ln -s test_header.h testhdr.h")
      self.runcmd("mkdir test_subdir")
      self.runcmd("touch test_another_header.h")

    # What: Header that includes via test_subdir/../.
    # Why: Only a real test_subdir lets the path resolve.
    def headerSource(self):
        return """
#define HELLO_WORLD "hello world"
#include "test_subdir/../test_another_header.h"
"""

# What: Compile a source given by absolute path.
# Why: Absolute names must map onto the server's tree.
class AbsSourceFilename_Case(CompileHello_Case):

    # What: Compile $PWD/testtmp.c through distcc.
    # Why: Uses the absolute path, not a relative one.
    def compileCmd(self):
        return (self.distcc()
                + self._cc
                + " -c -o testtmp.o %s/testtmp.c"
                % _ShellSafe(os.getcwd()))


# What: 100 sequential compiles against one daemon.
# Why: Catches leaks; 1000 runs cost more, prove no more.
class HundredFold_Case(CompileHello_Case):

    # What: Daemon --lifetime: 600s leak-safety net.
    # Why: 100 compiles run longer than the default allows.
    # From: Issue #379
    def daemon_lifetime(self):
        return 600

    # What: Compile the same file 100 times in a row.
    # Why: Any per-job leak or state bug adds up.
    def runtest(self):
        for unused_i in range(100):
            self.runcmd(self.distcc()
                        + self._cc + " -o testtmp.o -c testtmp.c")


# What: 50 compiles running at the same time.
# Why: The daemon must serve concurrent jobs correctly.
class Concurrent_Case(CompileHello_Case):
    # What: Daemon --lifetime: 600s leak-safety net.
    # Why: 50 parallel compiles can take about a minute.
    # From: Issue #379
    def daemon_lifetime(self):
        return 600

    # What: Start 50 compiles; each must exit with status 0.
    # Why: One failed child fails the whole test.
    def runtest(self):
        pids = {}
        for unused_i in range(50):
            kid = self.runcmd_background(self.distcc() +
                                         self._cc + " -o testtmp.o -c testtmp.c")
            pids[kid] = kid
        while len(pids):
            pid = next(iter(pids))
            pid, status = os.waitpid(pid, 0)
            if status:
                self.fail("child %d failed with status %#x" % (pid, status))
            del pids[pid]


# What: Compile and link a multi-megabyte C file.
# Why: Large uploads must survive the round trip.
class BigAssFile_Case(Compilation_Case):
    # What: Write 200000 global ints into testtmp.c.
    # Why: Big enough to matter, small for old machines.
    def createSource(self):
        with open("testtmp.c", 'wt') as f:
            f.write("int main() {}\n")
            for i in range(200000):
                f.write("int i%06d = %d;\n" % (i, i))

    # What: Compile, then link the big file through distcc.
    # Why: The object must come back intact to link.
    def runtest(self):
        self.runcmd(self.distcc() + self._cc + " -c %s" % "testtmp.c")
        self.runcmd(self.distcc() + self._cc + " -o testtmp testtmp.o")


    # What: Daemon --lifetime: 1500s leak-safety net.
    # Why: Inside validate.yml build_test's 15-minute timeout.
    # From: Issue #379
    def daemon_lifetime(self):
        return 1500



# What: A compiler that writes a 0-byte object.
# Why: An empty -o result must come back, not fail.
# From: Issue #275
class ZeroByteOutputCompiler_Case(Compilation_Case):

    # What: Write and close testtmp.i.
    # Why: The client uploads it; PyPy may defer a close.
    def createSource(self):
        with open("testtmp.i", "wt") as f:
            f.write("int main() {}")

    # What: A fake compiler touches its -o; check size 0.
    # Why: Simulates the empty output with a tiny script.
    def runtest(self):
        compiler = os.path.abspath("zero_byte_compiler")
        f = open(compiler, "w")
        try:
            f.write("#!/bin/sh\n"
                     "while [ $# -gt 0 ]; do\n"
                     "  if [ \"$1\" = \"-o\" ]; then shift; touch \"$1\"; fi\n"
                     "  shift\n"
                     "done\n")
        finally:
            f.close()
        os.chmod(compiler, 0o700)
        self.runcmd(self.distcc() + compiler + " -c testtmp.i -o testtmp.o", 0)
        self.assert_equal(os.path.getsize("testtmp.o"), 0)


# What: A compiler that always writes to stdout.
# Why: serve.c sends it as SOUT; the client prints it.
# From: Issue #275
class NastyCppWritesStdout_Case(Compilation_Case):

    # What: Write and close testtmp.i.
    # Why: The client uploads it; PyPy may defer a close.
    def createSource(self):
        with open("testtmp.i", "wt") as f:
            f.write("int main() {}")

    # What: The marker must reach the client's stdout.
    # Why: SOUT is sent whether or not the compile succeeds.
    def runtest(self):
        compiler = os.path.abspath("nasty_stdout_compiler")
        f = open(compiler, "w")
        try:
            f.write("#!/bin/sh\n"
                     "echo NASTY_STDOUT_MARKER\n"
                     "while [ $# -gt 0 ]; do\n"
                     "  if [ \"$1\" = \"-o\" ]; then shift; touch \"$1\"; fi\n"
                     "  shift\n"
                     "done\n")
        finally:
            f.close()
        os.chmod(compiler, 0o700)
        out, errs = self.runcmd(self.distcc() + compiler +
                                " -c testtmp.i -o testtmp.o")
        self.assert_re_search("NASTY_STDOUT_MARKER", out)


# What: A "compiler" that fails without reading input.
# Why: A server fifo open() must cope with interruption.
class BinFalse_Case(Compilation_Case):
    # What: Write a .i file so nothing is preprocessed.
    # Why: false ignores input; closing it is just hygiene.
    def createSource(self):
        with open("testtmp.i", "wt") as f:
            f.write("int main() {}")

    # What: distcc must return false's own exit status.
    # Why: Solaris and IRIX 6 false exits 255, others 1.
    def runtest(self):
        if sys.platform == 'sunos5' or \
        sys.platform.startswith ('irix6'):
            self.runcmd(self.distcc()
                        + "false -c testtmp.i", 255)
        else:
            self.runcmd(self.distcc()
                        + "false -c testtmp.i", 1)


# What: A "compiler" that succeeds without reading input.
# Why: A server fifo open() must cope with interruption.
class BinTrue_Case(Compilation_Case):
    # What: Write a .i file so nothing is preprocessed.
    # Why: true ignores input; closing it is just hygiene.
    def createSource(self):
        with open("testtmp.i", "wt") as f:
            f.write("int main() {}")

    # What: distcc must exit 0 like true itself.
    # Why: Success without output must still be success.
    def runtest(self):
        self.runcmd(self.distcc()
                    + "true -c testtmp.i", 0)


# What: A compiler killed by a signal.
# Why: dcc_critique_status() maps it to exit 128+signal.
# From: Issue #275
class CrashingCompiler_Case(Compilation_Case):

    # What: Write and close testtmp.i.
    # Why: The client uploads it; PyPy may defer a close.
    def createSource(self):
        with open("testtmp.i", "wt") as f:
            f.write("int main() {}")

    # What: A script SIGSEGVs itself; expect exit 139.
    # Why: No coreutils tool dies by a signal everywhere.
    def runtest(self):
        crasher = os.path.abspath("crashing_compiler")
        f = open(crasher, "w")
        try:
            f.write("#!/bin/sh\nkill -SEGV $$\n")
        finally:
            f.close()
        os.chmod(crasher, 0o700)
        self.runcmd(self.distcc() + crasher + " -c testtmp.i", 128 + 11)


# What: A client lost mid-job makes distccd kill the job.
# Why: dcc_collect_child() watches the client socket too.
class ClientDisconnectKillsServerChild_Case(WithDaemon_Case):

    # What: SIGKILL the client mid-compile; expect the kill log.
    # Why: A script that ignores argv sleeps; sleep(1) won't.
    def runtest(self):
        # What: Write and close testtmp.i.
        # Why: The client uploads it; PyPy may defer a close.
        with open("testtmp.i", "wt") as f:
            f.write("int main() {}")

        slow_compiler = os.path.abspath("slow_compiler")
        f = open(slow_compiler, "w")
        try:
            f.write("#!/bin/sh\nsleep 30\n")
        finally:
            f.close()
        os.chmod(slow_compiler, 0o700)

        # What: fork+exec distcc directly, not via a shell.
        # Why: The pid must be the client; a shell may fork again.
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

        # What: Wait until the server has forked the slow compiler.
        # Why: Killing earlier would race the job's start.
        self.waitForLogPattern(r"forking to execute.*slow_compiler", 10)

        # What: SIGKILL the client and reap it.
        # Why: An abrupt death mimics a crash or network drop.
        os.kill(client_pid, signal.SIGKILL)
        os.waitpid(client_pid, 0)

        # What: Wait up to 10s for "killing job" in the log.
        # Why: dcc_collect_child() polls the socket once a second.
        self.waitForLogPattern("Client fd disconnected, killing job", 10)


# What: -S overrides -c, as in gcc.
# Why: The implied output must be .s, never .o.
# From: Issue #275
class SBeatsC_Case(CompileHello_Case):
    # What: Compile with -c -S; expect testtmp.s, no testtmp.o.
    # Why: distcc must imply the output name like gcc does.
    def runtest(self):
        self.runcmd(self.distcc() +
                    self._cc + " -c -S testtmp.c")
        if os.path.exists("testtmp.o"):
            self.fail("created testtmp.o but should not have")
        if not os.path.exists("testtmp.s"):
            self.fail("did not create testtmp.s but should have")


# What: DISTCC_HOSTS names a host that does not exist.
# Why: distcc must fall back to compiling locally.
class NoServer_Case(CompileHello_Case):
    # What: Point DISTCC_HOSTS at an unresolvable name.
    # Why: No daemon is needed; the lookup must fail.
    def setup(self):
        self.stripEnvironment()
        os.environ['DISTCC_HOSTS'] = 'no.such.host.here' + _server_options
        self.distcc_log = 'distcc.log'
        os.environ['DISTCC_LOG'] = self.distcc_log
        self.createSource()
        self.initCompiler()

    # What: Compile; the log must say it ran locally.
    # Why: The fallback must be visible, not silent.
    def runtest(self):
        self.runcmd(self.distcc()
                    + self._cc + " -c -o testtmp.o testtmp.c")
        with open(self.distcc_log, 'r') as f:
            msgs = f.read()
        self.assert_re_search(r'failed to distribute.*running locally instead',
                              msgs)


# What: A bad pump host, then a good plain host.
# Why: That fallback path double-freed up to v3.4.
class MixedServerPumpFallback_Case(CompileHello_Case):
    # What: Hosts: an unresolvable ,lzo,cpp one, then ours.
    # Why: compile.c falls from remote to local cpp here.
    def setup(self):
        CompileHello_Case.setup(self)
        os.environ['DISTCC_HOSTS'] = f"no.such.host.here,lzo,cpp 127.0.0.1:{self.server_port}"
        self.distcc_log = 'distcc.log'
        os.environ['DISTCC_LOG'] = self.distcc_log
        self.createSource()
        self.initCompiler()

    # What: The log must show completion on 127.0.0.1.
    # Why: The usable server must win after the bad host.
    def runtest(self):
        self.runcmd(self.distcc()
                    + self._cc + " -c -o testtmp.o testtmp.c")
        with open(self.distcc_log, 'r') as f:
            msgs = f.read()
        self.assert_re_search(r'compile testtmp.c on 127.0.0.1:[0-9]* completed ok',
                              msgs)


# What: A refused host is marked for backoff.
# Why: backoff.c skips it in later runs via a timefile.
# From: Issue #275
class BackoffFromDownedHost_Case(CompileHello_Case):

    # What: List a closed port first, our daemon second.
    # Why: A free, closed port refuses fast, never times out.
    def setup(self):
        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        probe.bind(('127.0.0.1', 0))
        down_port = probe.getsockname()[1]
        probe.close()
        CompileHello_Case.setup(self)
        os.environ['DISTCC_HOSTS'] = ('127.0.0.1:%d 127.0.0.1:%d%s' %
            (down_port, self.server_port, _server_options))

    # What: Compile; the client log must mark a backoff.
    # Why: The mark is what persists across invocations.
    def runtest(self):
        self.compile()
        with open(os.environ['DISTCC_LOG']) as f:
            log = f.read()
        self.assert_re_search(r'mark .*backoff', log)


# What: Compile without -o.
# Why: distcc must imply testtmp.o like the compiler.
class ImpliedOutput_Case(CompileHello_Case):
    # What: Compile with plain "-c testtmp.c".
    # Why: No -o names the output.
    def compileCmd(self):
        return self.distcc() + self._cc + " -c testtmp.c"


# What: Compile a file that is not C at all.
# Why: The remote error must surface and leave no output.
class SyntaxError_Case(Compilation_Case):
    # What: Source that is plain text.
    # Why: The compiler must reject line 1.
    def source(self):
        return """not C source at all
"""

    # What: Expect a non-zero rc and an error at line 1.
    # Why: stdout must stay empty on a failed compile.
    def compile(self):
        rc, msgs, errs = self.runcmd_unchecked(self.compileCmd())
        self.assert_notequal(rc, 0)
        self.assert_re_search(r'testtmp.c:1:.*error', errs)
        self.assert_equal(msgs, '')

    # What: Compile, then require no object or program.
    # Why: A failed compile must not leave output behind.
    def runtest(self):
        self.compile()

        if os.path.exists("testtmp") or os.path.exists("testtmp.o"):
            self.fail("compiler produced output, but should not have done so")


# What: Compile with DISTCC_HOSTS empty.
# Why: It must build locally and warn that it did.
class NoHosts_Case(CompileHello_Case):
    # What: Empty DISTCC_HOSTS, expect the local-run warning.
    # Why: NotRun in pump mode: the wrapper needs DISTCC_HOSTS.
    def runtest(self):
        if "cpp" in _server_options:
            raise comfychair.NotRunError('pump wrapper expects DISTCC_HOSTS')

        # What: Blank out DISTCC_HOSTS and DISTCC_LOG.
        # Why: The fixture points them at the test daemon.
        os.environ['DISTCC_HOSTS'] = ''
        os.environ['DISTCC_LOG'] = ''
        self.runcmd('env')
        msgs, errs = self.runcmd(self.compileCmd())

        self.assert_re_search(r"Warning.*\$DISTCC_HOSTS.*can't distribute work",
                              errs)

    # What: Compile with local fallback enabled.
    # Why: With no hosts, only the fallback can build it.
    def compileCmd(self):
        return self.distcc_with_fallback() + \
               self._cc + " -o testtmp.o -c %s" % (self.sourceFilename())



# What: The recursion safeguard stops distcc calling itself.
# Why: A set _DISTCC_SAFEGUARD is fatal: EXIT_RECURSION.
# From: Issue #275
class RecursionSafeguard_Case(CompileHello_Case):

    # What: Safeguard=1, a closed port, empty DISTCC_LOG.
    # Why: Proves it fires before any connect, on stderr.
    def runtest(self):
        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        probe.bind(('127.0.0.1', 0))
        down_port = probe.getsockname()[1]
        probe.close()
        os.environ['DISTCC_HOSTS'] = '127.0.0.1:%d' % down_port
        os.environ['DISTCC_LOG'] = ''
        os.environ['_DISTCC_SAFEGUARD'] = '1'
        msgs, errs = self.runcmd(self.distcc_without_fallback() +
                                 self._cc + " -o testtmp.o -c testtmp.c",
                                 EXIT_RECURSION)
        self.assert_re_search("invoked itself recursively", errs)


# What: The compiler is missing on the server.
# Why: distccd must report it, not hang or crash.
class MissingCompiler_Case(CompileHello_Case):
    # What: Use a preprocessed .i source.
    # Why: The client then never runs the compiler itself.
    def sourceFilename(self):
        return "testtmp.i"

    # What: A trivial declaration.
    # Why: The content never reaches a compiler.
    def source(self):
        return """int foo;"""

    # What: "nosuchcc" must exit EXIT_COMPILER_MISSING.
    # Why: The server must say it failed to exec.
    def runtest(self):
        msgs, errs = self.runcmd(self.distcc_without_fallback()
                                 + "nosuchcc -c testtmp.i",
                                 expectedResult=EXIT_COMPILER_MISSING)
        self.assert_re_search(r'failed to exec', errs)


# What: Compile a source file that does not exist.
# Why: One error only; a local retry would print it twice.
# From: Issue #275
class NonexistentSourceFile_Case(CompileHello_Case):

    # What: Start the daemon but write no source file.
    # Why: testtmp.c must be missing for this test.
    def setup(self):
        WithDaemon_Case.setup(self)

    # What: Expect exit 1 and one "no such file" message.
    # Why: cc1 fails normally; pump mode takes another path.
    def runtest(self):
        if "cpp" in _server_options:
            raise comfychair.NotRunError(
                'pump mode intercepts a missing source file at the '
                'include-scanning stage, before it ever reaches the '
                'compiler -- a different code path than this test covers')
        msgs, errs = self.runcmd(self.distcc_without_fallback()
                                 + self._cc + " -o testtmp.o -c testtmp.c",
                                 expectedResult=1)
        self.assert_equal(len(re.findall(r'[Nn]o such file', errs)), 1)


# What: A missing /path/cc on the server fails loudly.
# Why: dcc_execvp() once ran a same-named PATH binary.
# From: PR #281
class PathQualifiedCompilerNotSubstituted_Case(CompileHello_Case):

    # What: Name of the substitute compiler on the daemon PATH.
    # Why: Distinctive, so nothing else can match it.
    MARKER_NAME = "distcc_test_execvp_marker_cc"

    # What: Use a preprocessed .i source.
    # Why: The missing compiler is never needed locally.
    def sourceFilename(self):
        return "testtmp.i"

    # What: A trivial declaration.
    # Why: The content never reaches a compiler.
    def source(self):
        return """int foo;"""

    # What: Create the marker compiler, then start the daemon.
    # Why: startDaemon() puts marker_dir on the daemon's PATH.
    def setup(self):
        self.marker_dir = os.path.join(self.tmpdir, "server_path_extra")
        os.mkdir(self.marker_dir)
        self.marker_script = os.path.join(self.marker_dir, self.MARKER_NAME)
        self.marker_ran_file = os.path.join(self.tmpdir, "marker_ran")
        with open(self.marker_script, "w") as f:
            f.write("#!/bin/sh\ntouch %s\nexit 0\n" %
                    _ShellSafe(self.marker_ran_file))
        os.chmod(self.marker_script, 0o700)
        CompileHello_Case.setup(self)

    # What: Start the daemon with marker_dir prepended to PATH.
    # Why: Only the server, never the client, may find it.
    def startDaemon(self):
        old_path = os.environ['PATH']
        os.environ['PATH'] = self.marker_dir + os.pathsep + old_path
        try:
            WithDaemon_Case.startDaemon(self)
        finally:
            os.environ['PATH'] = old_path

    # What: Expect EXIT_COMPILER_MISSING; the marker never ran.
    # Why: A substitute run would "succeed" with a wrong cc.
    def runtest(self):
        nonexistent_path = os.path.join(
            self.tmpdir, "nowhere_on_any_host", self.MARKER_NAME)
        msgs, errs = self.runcmd(
            self.distcc_without_fallback() + _ShellSafe(nonexistent_path) +
            " -c testtmp.i",
            expectedResult=EXIT_COMPILER_MISSING)
        self.assert_re_search(r'failed to exec', errs)
        if os.path.exists(self.marker_ran_file):
            self.fail("the substitute compiler on the daemon's $PATH ran "
                       "instead of failing loudly for the nonexistent, "
                       "directory-qualified compiler path")


# What: Compile a .s assembly file through distcc.
# Why: .s files are never distributed; this must still work.
class RemoteAssemble_Case(WithDaemon_Case):

    # What: Portable assembly defining msg as "hello world".
    # Why: Avoids @, which starts a comment on ARM.
    asm_source = """
        .file	"foo.c"
.globl msg
.section	.rodata
.LC0:
  .string	"hello world"
.data
  .align 4
  .type	 msg,object
  .size	 msg,4
msg:
  .long .LC0
"""

    # What: File name of the assembly fixture.
    # Why: The .s suffix keeps it from being preprocessed.
    asm_filename = 'test2.s'

    # What: Start the daemon; write and close the .s file.
    # Why: The assembler must read a fully written file.
    def setup(self):
        WithDaemon_Case.setup(self)
        with open(self.asm_filename, 'wt') as f:
            f.write(self.asm_source)

    # What: Assemble test2.s through distcc.
    # Why: distcc must hand .s files to the local assembler.
    def compile(self):
        self.runcmd(self.distcc() + self._cc + " -o test2.o -c test2.s")



# What: Preprocess and assemble a .S file locally.
# Why: .S needs cpp, but is never distributed either.
class PreprocessAsm_Case(WithDaemon_Case):
    # What: Assembly using a #define for the message.
    # Why: Only cpp can resolve MSG before assembling.
    asm_source = """
#define MSG "hello world"
gcc2_compiled.:
.globl msg
.section	.rodata
.LC0:
  .string	 MSG
.data
  .align 4
  .type	 msg,object
  .size	 msg,4
msg:
  .long .LC0
"""

    # What: Start the daemon; write and close test2.S.
    # Why: cpp must read a fully written file.
    def setup(self):
        WithDaemon_Case.setup(self)
        with open('test2.S', 'wt') as f:
            f.write(self.asm_source)

    # What: Build test2.S through distcc on linux2 only.
    # Why: The assembly syntax is system-specific.
    def compile(self):
        if sys.platform == 'linux2':
            self.runcmd(self.distcc()
                        + "-o test2.o -c test2.S")
        else:
            raise comfychair.NotRunError ('this test is system-specific')

    # What: Only compile; there is nothing to link.
    # Why: The object is never turned into a program.
    def runtest(self):
        self.compile()




# What: A .s file's .include is always resolved locally.
# Why: .s is never distributed; ENABLE_REMOTE_ASSEMBLE unset.
# From: Issue #275
class AssemblyIncludeLocalOnly_Case(SimpleDistCC_Case):

    # What: File name of the assembly source.
    # Why: The .s suffix keeps it local.
    asm_filename = 'test_include.s'
    # What: File name of the local-only include.
    # Why: It exists only in this test's scratch dir.
    inc_filename = 'local_only.inc'

    # What: Write the .inc and .s files; hosts: a closed port.
    # Why: Any connect attempt would fail the compile.
    def setup(self):
        SimpleDistCC_Case.setup(self)
        with open(self.inc_filename, 'wt') as f:
            f.write(".equ VALUE, 42\n")
        # What: Use only .globl/.data/.align/label/.long.
        # Why: Apple's clang rejects ELF-only .type and .size.
        with open(self.asm_filename, 'wt') as f:
            f.write(
                '.include "%s"\n'
                ".globl distcc_ng_test_marker\n"
                ".data\n"
                "  .align 4\n"
                "distcc_ng_test_marker:\n"
                "  .long VALUE\n" % self.inc_filename)

        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        probe.bind(('127.0.0.1', 0))
        down_port = probe.getsockname()[1]
        probe.close()
        os.environ['DISTCC_HOSTS'] = '127.0.0.1:%d' % down_port

    # What: Assemble without fallback; must succeed silently.
    # Why: Success with a dead host proves it stayed local.
    def runtest(self):
        msgs, errs = self.runcmd(self.distcc_without_fallback() +
                                  self._cc + " -o test_include.o -c %s" %
                                  self.asm_filename)
        self.assert_equal(msgs, '')
        self.assert_equal(errs, '')
        self.assert_equal(os.path.exists('test_include.o'), True)


# What: distcc honours the umask for its output.
# Why: Objects must get the mode a local compile gives.
class ModeBits_Case(CompileHello_Case):
    # What: Compile under umask 0; expect mode 0666.
    # Why: Any narrower mode means distcc forced its own.
    def runtest(self):
        self.runcmd("umask 0; distcc " + self._cc + " -c testtmp.c")
        self.assert_equal(S_IMODE(os.stat("testtmp.o")[ST_MODE]), 0o666)


# What: Stub that requires running as root.
# Why: Not run by default; marks the root-only convention.
class CheckRoot_Case(SimpleDistCC_Case):
    # What: NotRun unless the suite runs as root.
    # Why: require_root() raises NotRunError otherwise.
    def setup(self):
        self.require_root()


# What: Compile an empty source file.
# Why: As .i, so cpp cannot add a # line and pass falsely.
class EmptySource_Case(Compilation_Case):

    # What: Empty source text.
    # Why: Nothing at all must still compile.
    def source(self):
        return ''

    # What: Only compile; there is nothing to link.
    # Why: An empty object has no main to run.
    def runtest(self):
        self.compile()

    # What: rc must be 0 unless gcc hit its own ICE.
    # Why: GCC 3.4.x before .5 ICEs on empty input (bug 20239).
    def compile(self):
        rc, out, errs = self.runcmd_unchecked(self.distcc()
                    + self._cc + " -c %s" % self.sourceFilename())
        if not re.search("internal compiler error", errs):
          self.assert_equal(rc, 0)

    # What: Name the empty source testtmp.i.
    # Why: Preprocessed input skips cpp.
    def sourceFilename(self):
        return "testtmp.i"

# What: DISTCC_LOG points at an unwritable file.
# Why: distcc must warn and still compile.
class BadLogFile_Case(CompileHello_Case):
    # What: chmod 0 the log; expect rc 0 and a warning.
    # Why: A log failure must never fail the compile.
    def runtest(self):
        self.runcmd("touch distcc.log")
        self.runcmd("chmod 0 distcc.log")
        msgs, errs = self.runcmd("DISTCC_LOG=distcc.log " + \
                                 self.distcc() + \
                                 self._cc + " -c testtmp.c", expectedResult=0)
        self.assert_re_search("failed to open logfile", errs)


# What: The daemon refuses this client's address.
# Why: The compile must fall back locally with a warning.
class AccessDenied_Case(CompileHello_Case):
    # What: distccd allowing only 127.0.0.2.
    # Why: Our 127.0.0.1 client is then denied.
    def daemon_command(self):
        return (self.distccd()
                + "--verbose --lifetime=%d --daemon --log-file %s "
                  "--pid-file %s --port %d --allow 127.0.0.2 --enable-tcp-insecure "
                  "--sysroot %s"
                % (self.daemon_lifetime(),
                   _ShellSafe(self.daemon_logfile),
                   _ShellSafe(self.daemon_pidfile),
                   self.server_port,
                   _ShellSafe(self.daemon_sysroot)))

    # What: Compile with local fallback enabled.
    # Why: Denied, only the fallback can build it.
    def compileCmd(self):
        return self.distcc_with_fallback() + \
               self._cc + " -o testtmp.o -c %s" % (self.sourceFilename())


    # What: Compile; the log must say it failed to distribute.
    # Why: The fallback must be visible, not silent.
    def runtest(self):
        self.compile()
        with open('distcc.log') as f:
            errs = f.read()
        self.assert_re_search(r'failed to distribute', errs)


# What: IP mask matching for --allow.
# Why: A wrong match grants or denies the wrong clients.
class ParseMask_Case(comfychair.TestCase):
    # What: Cases of (mask, client, expected exit code).
    # Why: Covers exact, CIDR, bad width and bad syntax.
    values = [
        ('127.0.0.1', '127.0.0.1', 0),
        ('127.0.0.1', '127.0.0.0', EXIT_ACCESS_DENIED),
        ('127.0.0.1', '127.0.0.2', EXIT_ACCESS_DENIED),
        ('127.0.0.1/8', '127.0.0.2', 0),
        ('10.113.0.0/16', '10.113.45.67', 0),
        ('10.113.0.0/16', '10.11.45.67', EXIT_ACCESS_DENIED),
        ('10.113.0.0/16', '127.0.0.1', EXIT_ACCESS_DENIED),
        ('1.2.3.4/0', '4.3.2.1', 0),
        ('1.2.3.4/40', '4.3.2.1', EXIT_BAD_ARGUMENTS),
        ('1.2.3.4.5.6.7/8', '127.0.0.1', EXIT_BAD_ARGUMENTS),
        ('1.2.3.4/8', '4.3.2.1', EXIT_ACCESS_DENIED),
        ('192.168.1.64/28', '192.168.1.70', 0),
        ('192.168.1.64/28', '192.168.1.7', EXIT_ACCESS_DENIED),
        ]
    # What: h_parsemask each case; compare the exit code.
    # Why: The C helper runs the real mask parser.
    def runtest(self):
        for mask, client, expected in ParseMask_Case.values:
            cmd = "h_parsemask %s %s" % (mask, client)
            ret, msgs, err = self.runcmd_unchecked(cmd)
            if ret != expected:
                self.fail("%s gave %d, expected %d" % (cmd, ret, expected))


# What: ccache really hits through "distcc ccache <cc>".
# Why: ScanArgs only shows it distributes, not that it hits.
# From: Issue #275, Issue #442
class CcacheHitThroughDistcc_Case(CompileHello_Case):

    # What: Set a private CCACHE_DIR, then start the daemon.
    # Why: The daemon's ccache children inherit its start env.
    def setup(self):
        self.ccache_dir = os.path.abspath('ccache_test_dir')
        os.mkdir(self.ccache_dir)
        os.environ['CCACHE_DIR'] = self.ccache_dir
        # What: Enable ccache's debug log, before the daemon starts.
        # Why: A missing hit then fails with ccache's own reason.
        self.ccache_logfile = os.path.join(self.ccache_dir, 'ccache_debug.log')
        os.environ['CCACHE_DEBUG'] = '1'
        os.environ['CCACHE_LOGFILE'] = self.ccache_logfile
        CompileHello_Case.setup(self)
        self.runcmd_unchecked("ccache --version", skip_on_noexec=1)

    # What: Compile "ccache <cc>" with an absolute source path.
    # Why: ccache lstat()s the cpp path from the server's dir.
    def compileCmd(self):
        return (self.distcc_without_fallback() +
                "ccache " + self._cc + " -o testtmp.o " + self.compileOpts() +
                " -c %s" % os.path.abspath(self.sourceFilename()))

    # What: Compile twice; outside pump mode expect Hits >= 1.
    # Why: Pump's per-job server temp dir changes the hash key.
    # From: Issue #442
    def runtest(self):
        self.compile()
        self.compile()
        out, errs = self.runcmd("ccache -s")
        if "cpp" in _server_options:
            return
        if not re.search(r"Hits:\s+[1-9]", out):
            try:
                with open(self.ccache_logfile) as f:
                    debug_log = f.read()
            except IOError:
                debug_log = "(no ccache debug log found at %s)" % self.ccache_logfile
            self.fail("expected a real ccache hit, got:\n%s\n\n"
                      "ccache debug log (last 4000 chars):\n%s" %
                      (out, debug_log[-4000:]))


# What: Hosts come from $DISTCC_DIR/hosts, not the env.
# Why: The hosts file is the other host source distcc reads.
class HostFile_Case(CompileHello_Case):
    # What: Unset DISTCC_HOSTS; write our daemon to the file.
    # Why: Close it before distcc reads it.
    def setup(self):
        CompileHello_Case.setup(self)
        del os.environ['DISTCC_HOSTS']
        self.save_home = os.environ['HOME']
        os.environ['HOME'] = os.getcwd()
        with open(os.environ['DISTCC_DIR'] + '/hosts', 'w') as f:
            f.write('127.0.0.1:%d%s' %
                    (self.server_port, _server_options))

    # What: Restore HOME, then run the base teardown.
    # Why: Later tests need the real HOME back.
    def teardown(self):
        os.environ['HOME'] = self.save_home
        CompileHello_Case.teardown(self)


# What: HostFile_Case with $DISTCC_DIR unset.
# Why: Exercises dcc_get_top_dir()'s ~/.distcc fallback.
# From: Issue #275
class HostFileDistccDirUnset_Case(CompileHello_Case):

    # What: Unset both vars; write hosts to $HOME/.distcc.
    # Why: Every other test always has DISTCC_DIR set.
    def setup(self):
        CompileHello_Case.setup(self)
        del os.environ['DISTCC_HOSTS']
        del os.environ['DISTCC_DIR']
        self.save_home = os.environ['HOME']
        os.environ['HOME'] = os.getcwd()
        distcc_dir = os.path.join(os.environ['HOME'], '.distcc')
        os.mkdir(distcc_dir)
        with open(distcc_dir + '/hosts', 'w') as f:
            f.write('127.0.0.1:%d%s' %
                    (self.server_port, _server_options))

    # What: Restore HOME, then run the base teardown.
    # Why: Later tests need the real HOME back.
    def teardown(self):
        os.environ['HOME'] = self.save_home
        CompileHello_Case.teardown(self)


# What: Compile over IPv6 to a daemon on ::1.
# Why: Server-side IPv6 needs --enable-rfc2553, else NotRun.
# From: Issue #275
class IPv6Compile_Case(CompileHello_Case):

    # What: NotRun without ::1 or an RFC2553 distccd.
    # Why: Default builds cannot parse "::1" on the server.
    def setup(self):
        probe = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        try:
            probe.bind(('::1', 0))
        except OSError:
            raise comfychair.NotRunError('no IPv6 loopback on this host')
        finally:
            probe.close()
        # What: Probe distccd --listen ::1 in the foreground.
        # Why: The bind-retry loop would turn it into a failure.
        rc, out, err = self.runcmd_unchecked(
            self.distccd() + "--listen ::1 --allow ::1 --port 41999")
        if "can't parse internet address" in err:
            raise comfychair.NotRunError(
                'distccd was not built with --enable-rfc2553; '
                'IPv6 --listen/--allow is unavailable')
        CompileHello_Case.setup(self)

    # What: distccd listening on and allowing ::1 only.
    # Why: The connection must really go over IPv6.
    def daemon_command(self):
        return (self.distccd() +
                "--verbose --lifetime=%d --daemon --log-file %s "
                "--pid-file %s --port %d --listen ::1 --allow ::1 "
                "--enable-tcp-insecure --sysroot %s"
                % (self.daemon_lifetime(),
                   _ShellSafe(self.daemon_logfile),
                   _ShellSafe(self.daemon_pidfile),
                   self.server_port,
                   _ShellSafe(self.daemon_sysroot)))

    # What: Point DISTCC_HOSTS at [::1]:port.
    # Why: The bracketed form is the IPv6 hostspec syntax.
    def setupEnv(self):
        WithDaemon_Case.setupEnv(self)
        os.environ['DISTCC_HOSTS'] = ('[::1]:%d%s' %
          (self.server_port, _server_options))


# What: Compile against a --no-fork daemon.
# Why: dcc_nofork_parent() is a separate accept loop path.
# From: Issue #275
class NoForkDaemon_Case(CompileHello_Case):

    # What: distccd with --no-fork.
    # Why: One process serves each job itself, no prefork.
    def daemon_command(self):
        return (self.distccd() +
                "--verbose --lifetime=%d --daemon --no-fork --log-file %s "
                "--pid-file %s --port %d --allow 127.0.0.1 "
                "--enable-tcp-insecure --sysroot %s"
                % (self.daemon_lifetime(),
                   _ShellSafe(self.daemon_logfile),
                   _ShellSafe(self.daemon_pidfile),
                   self.server_port,
                   _ShellSafe(self.daemon_sysroot)))


# What: The server is killed mid-job; the client falls back.
# Why: An in-flight failure differs from a connect failure.
# From: Issue #275
class ServerKilledMidJob_Case(NoForkDaemon_Case):

    # What: SIGKILL the --no-fork daemon mid-compile.
    # Why: Only with --no-fork does the pidfile hold the socket.
    def runtest(self):
        # What: A compiler that sleeps, then touches its -o.
        # Why: The local re-run then leaves a real testtmp.o.
        slow_compiler = os.path.abspath("slow_compiler")
        f = open(slow_compiler, "w")
        try:
            f.write("#!/bin/sh\n"
                     "sleep 5\n"
                     "while [ $# -gt 0 ]; do\n"
                     "  if [ \"$1\" = \"-o\" ]; then shift; touch \"$1\"; fi\n"
                     "  shift\n"
                     "done\n")
        finally:
            f.close()
        os.chmod(slow_compiler, 0o700)

        # What: Use a preprocessed .i source.
        # Why: A .c would run the sleeping script locally as cpp.
        with open("testtmp.i", "wt") as f:
            f.write("int main() {}")

        client_pid = self.runcmd_background(
            self.distcc_with_fallback() + slow_compiler +
            " -o testtmp.o -c testtmp.i")

        self.waitForLogPattern(r"forking to execute.*slow_compiler", 10)

        with open(self.daemon_pidfile, 'rt') as f:
            daemon_pid = int(f.read())
        os.kill(daemon_pid, signal.SIGKILL)
        # What: Remove the pidfile after killing the daemon.
        # Why: killDaemon() would SIGTERM a dead pid and fail.
        os.remove(self.daemon_pidfile)

        exited_pid, waitstatus = os.waitpid(client_pid, 0)
        self.assert_equal(os.WIFSIGNALED(waitstatus), False)
        self.assert_equal(os.WEXITSTATUS(waitstatus), 0)
        self.assert_equal(os.path.exists("testtmp.o"), True)

        with open(os.environ['DISTCC_LOG']) as f:
            log = f.read()
        self.assert_re_search(r'failed to distribute.*running locally instead',
                              log)


# What: A real compile over distcc's SSH transport.
# Why: A private key-only sshd runs distccd --inetd.
# From: Issue #275
class SSHMode_Case(CompileHello_Case):

    # What: Start a 127.0.0.1 sshd whose PATH holds distccd.
    # Why: A non-login SSH session does not inherit our PATH.
    def setup(self):
        CompileHello_Case.setup(self)

        sshd_bin = shutil.which("sshd") or "/usr/sbin/sshd"
        keygen_bin = shutil.which("ssh-keygen")
        ssh_bin = shutil.which("ssh")
        if (not os.access(sshd_bin, os.X_OK) or not keygen_bin
                or not ssh_bin):
            raise comfychair.NotRunError(
                'sshd/ssh-keygen/ssh not found -- cannot test SSH mode')

        distccd_dir = None
        for d in os.environ['PATH'].split(':'):
            candidate = os.path.join(d, 'distccd')
            if os.access(candidate, os.X_OK):
                distccd_dir = os.path.dirname(os.path.abspath(candidate))
                break
        if distccd_dir is None:
            raise comfychair.NotRunError(
                'could not find the built distccd binary on PATH')

        sshdir = os.path.abspath("sshtest")
        os.mkdir(sshdir)

        host_key = os.path.join(sshdir, "host_key")
        self.runcmd("%s -t ed25519 -f %s -N '' -q" %
                    (keygen_bin, _ShellSafe(host_key)))

        client_key = os.path.join(sshdir, "client_key")
        self.runcmd("%s -t ed25519 -f %s -N '' -q" %
                    (keygen_bin, _ShellSafe(client_key)))

        authorized_keys = os.path.join(sshdir, "authorized_keys")
        shutil.copyfile(client_key + ".pub", authorized_keys)
        os.chmod(authorized_keys, 0o600)

        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        probe.bind(('127.0.0.1', 0))
        ssh_port = probe.getsockname()[1]
        probe.close()

        sshd_pidfile = os.path.join(sshdir, "sshd.pid")
        sshd_logfile = os.path.join(sshdir, "sshd.log")
        sshd_config = os.path.join(sshdir, "sshd_config")
        f = open(sshd_config, "w")
        try:
            f.write(
                "Port %d\n"
                "ListenAddress 127.0.0.1\n"
                "HostKey %s\n"
                "AuthorizedKeysFile %s\n"
                "PidFile %s\n"
                "UsePAM no\n"
                "StrictModes no\n"
                "PasswordAuthentication no\n"
                "ChallengeResponseAuthentication no\n"
                "PrintMotd no\n"
                "Subsystem sftp none\n"
                "SetEnv PATH=%s:/usr/local/bin:/usr/bin:/bin\n"
                % (ssh_port, host_key, authorized_keys, sshd_pidfile,
                   distccd_dir))
        finally:
            f.close()

        # What: Start sshd; it detaches once bound.
        # Why: So this command returns as soon as it listens.
        self.runcmd("%s -f %s -E %s" %
                    (sshd_bin, _ShellSafe(sshd_config),
                     _ShellSafe(sshd_logfile)))
        self._sshd_pidfile = sshd_pidfile
        self.add_cleanup(self.killSshd)

        # What: ssh options: our key, no host checks, LogLevel=ERROR.
        # Why: Hides the known-hosts notice, keeps real errors.
        os.environ['DISTCC_SSH'] = (
            "%s -p %d -i %s -o StrictHostKeyChecking=no "
            "-o UserKnownHostsFile=/dev/null -o BatchMode=yes "
            "-o LogLevel=ERROR"
            % (ssh_bin, ssh_port, client_key))
        os.environ['DISTCC_HOSTS'] = '@127.0.0.1'

    # What: SIGTERM sshd from its pidfile, if any.
    # Why: No pidfile means sshd already stopped.
    def killSshd(self):
        try:
            with open(self._sshd_pidfile, 'rt') as f:
                pid = int(f.read().strip())
        except IOError:
            return
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass


# What: lsdistcc finds the test daemon by host list.
# Why: Covers --help, explicit hosts and the %d pattern.
class Lsdistcc_Case(WithDaemon_Case):

    # What: lsdistcc command probing the daemon's port.
    # Why: -r sets the port to scan.
    def lsdistccCmd(self):
        return "lsdistcc -r%d" % self.server_port

    # What: Check --help, a host list, then 127.0.0.%d.
    # Why: Extra loopback addresses are used when they answer.
    def runtest(self):
        lsdistcc = self.lsdistccCmd()

        # What: --help prints usage on stdout and exits 1.
        # Why: That is lsdistcc's current, if odd, behaviour.
        rc, out, err = self.runcmd_unchecked(lsdistcc + " --help")
        self.assert_re_search("Usage:", out)
        self.assert_equal(err, "")
        self.assert_equal(rc, 1)

        # What: Ping 127.0.0.2 to see if it is a loopback too.
        # Why: Only some systems route all of 127.0.0.0/8 locally.
        rc, out, err = self.runcmd_unchecked("ping -c 3 -i 0.2 -w 1 127.0.0.2")
        multiple_loopback_addrs = (rc == 0)

        # What: List explicit hosts plus one invalid name.
        # Why: Only reachable daemons may be printed.
        out, err = self.runcmd(lsdistcc + " localhost 127.0.0.1 127.0.0.2 "
            + " anInvalidHostname")
        out_list = out.split()
        out_list.sort()
        expected = ["%s:%d" % (host, self.server_port) for host in
                    ["127.0.0.1", "127.0.0.2", "localhost"]]
        if multiple_loopback_addrs:
          self.assert_equal(out_list, expected)
        else:
            # What: Accept the list with or without 127.0.0.2.
            # Why: ping may lack -c/-i/-w even if it is loopback.
            if out_list != expected:
                del expected[1]
                self.assert_equal(out_list, expected)
        self.assert_equal(err, "")

        # What: Expand the 127.0.0.%d host pattern.
        # Why: lsdistcc numbers hosts from 1 upward.
        out, err = self.runcmd(lsdistcc + " 127.0.0.%d")
        self.assert_equal(err, "")
        self.assert_re_search("127.0.0.1:%d\n" % self.server_port, out)
        if multiple_loopback_addrs:
          self.assert_re_search("127.0.0.2:%d\n" % self.server_port, out)
          self.assert_re_search("127.0.0.3:%d\n" % self.server_port, out)
          self.assert_re_search("127.0.0.4:%d\n" % self.server_port, out)
          self.assert_re_search("127.0.0.5:%d\n" % self.server_port, out)

# What: distcc's getline() replacement.
# Why: Every buffer size must split lines identically.
class Getline_Case(comfychair.TestCase):
    # What: Cases of (input, line, rest, return value).
    # Why: Covers empty, newline-only and multi-line input.
    values = [
        ('', '', '', -1),
        ('\n', '\n', '', 1),
        ('\n\n', '\n', '\n', 1),
        ('\n\n\n', '\n', '\n\n', 1),
        ('a', 'a', '', 1),
        ('a\n', 'a\n', '', 2),
        ('foo', 'foo', '', 3),
        ('foo\n', 'foo\n', '', 4),
        ('foo\nbar\n', 'foo\n', 'bar\n', 4),
        ('foobar\nbaz', 'foobar\n', 'baz', 7),
        ('foo bar\nbaz', 'foo bar\n', 'baz', 8),
        ]
    # What: Run h_getline per case and buffer size.
    # Why: Small buffers force getline() to grow them.
    def runtest(self):
        for input, line, rest, retval in Getline_Case.values:
            for bufsize in [None, 0, 1, 2, 3, 4, 64, 10000]:
                if bufsize:
                    cmd = "printf '%s' | h_getline %s | cat -v" % (input,
                                                                   bufsize)
                    n = bufsize
                else:
                    cmd = "printf '%s' | h_getline | cat -v" % input
                    n = 0
                ret, msgs, err = self.runcmd_unchecked(cmd)
                self.assert_equal(ret, 0);
                self.assert_equal(err, '');
                msg_parts = msgs.split(',');
                self.assert_equal(msg_parts[0], "original n = %s" % n);
                self.assert_equal(msg_parts[1], " returned %s" % retval);
                self.assert_equal(msg_parts[2].startswith(" n = "), True);
                self.assert_equal(msg_parts[3], " line = '%s'" % line);
                self.assert_equal(msg_parts[4], " rest = '%s'\n" % rest);

# What: Every test case comfychair runs, in order.
# Why: The slow cases come last so failures show early.
tests = [
         CompileHello_Case,
         MarchNativeDispatcherPath_Case,
         CommaInFilename_Case,
         ComputedInclude_Case,
         BackslashInMacro_Case,
         BackslashInFilename_Case,
         IncludeEqualsForceInclude_Case,
         ImacrosEqualsForceInclude_Case,
         SysrootAbsolutePath_Case,
         CPlusPlus_Case,
         ObjectiveC_Case,
         ObjectiveCPlusPlus_Case,
         SystemIncludeDirectories_Case,
         CPlusPlus_SystemIncludeDirectories_Case,
         Gdb_Case,
         GdbOpt1_Case,
         GdbOpt2_Case,
         GdbOpt3_Case,
         GdbCompressedDebugInfo_Case,
         FixDebugInfoGnuCompressed_Case,
         FixDebugInfoNonElf_Case,
         FixDebugInfoElf32Compressed_Case,
         GdbPrefixMap_Case,
         Lsdistcc_Case,
         BadLogFile_Case,
         PathSafety_Case,
         ScanArgs_Case,
         SymlinkTraversal_Case,
         IncludeServerFileOrder_Case,
         StateFileAtomicWrite_Case,
         ParseMask_Case,
         DotD_Case,
         DashMD_DashMF_DashMT_Case,
         DashMMD_Case,
         Compile_c_Case,
         ImplicitCompilerScan_Case,
         StripArgs_Case,
         StartStopDaemon_Case,
         CompressedCompile_Case,
         DashONoSpace_Case,
         WriteDevNull_Case,
         CppError_Case,
         BadInclude_Case,
         PreprocessPlainText_Case,
         CppFromStdin_Case,
         NoDetachDaemon_Case,
         AutogroupNicenessPrivilegeDrop_Case,
         UserPrivilegeDropFunctional_Case,
         SBeatsC_Case,
         DashD_Case,
         EmptyDefine_Case,
         DashWpMD_Case,
         ZstdPumpCompile_Case,
         SplitDwarfLzoPumpCompile_Case,
         SplitDwarfZstdPumpCompile_Case,
         SplitDwarfEmptyDwoPump_Case,
         HostSelectionAlgorithm_Case,
         ScanIncludes_Case,
         ForceDirectory_Case,
         ZeroByteOutputCompiler_Case,
         NastyCppWritesStdout_Case,
         BinFalse_Case,
         BinTrue_Case,
         CrashingCompiler_Case,
         ClientDisconnectKillsServerChild_Case,
         VersionOption_Case,
         HelpOption_Case,
         BogusOption_Case,
         MultipleCompile_Case,
         CompilerOptionsPassed_Case,
         IsSource_Case,
         ExtractExtension_Case,
         ImplicitCompiler_Case,
         DaemonBadPort_Case,
         TcpInsecureOptionOrder_Case,
         AccessDenied_Case,
         NoServer_Case,
         MixedServerPumpFallback_Case,
         BackoffFromDownedHost_Case,
         InvalidHostSpec_Case,
         ParseHostSpec_Case,
         MasqueradeMode_Case,
         SecureShellCommandEnvironment_Case,
         ImpliedOutput_Case,
         SyntaxError_Case,
         NoHosts_Case,
         RecursionSafeguard_Case,
         MissingCompiler_Case,
         NonexistentSourceFile_Case,
         PathQualifiedCompilerNotSubstituted_Case,
         RemoteAssemble_Case,
         PreprocessAsm_Case,
         AssemblyIncludeLocalOnly_Case,
         ModeBits_Case,
         EmptySource_Case,
         CcacheHitThroughDistcc_Case,
         HostFile_Case,
         HostFileDistccDirUnset_Case,
         IPv6Compile_Case,
         NoForkDaemon_Case,
         ServerKilledMidJob_Case,
         SSHMode_Case,
         AbsSourceFilename_Case,
         Getline_Case,
         Unicode_Case,
         Concurrent_Case,
         HundredFold_Case,
         BigAssFile_Case]

# What: Unset CPATH before any test runs.
# Why: Some macOS Pythons set it; distcc then won't pump.
if "CPATH" in os.environ:
  del os.environ["CPATH"]

# What: Parse --valgrind/--lzo/--zstd/--pump, then run.
# Why: These options select how every test runs.
if __name__ == '__main__':
  while len(sys.argv) > 1 and sys.argv[1].startswith("--"):
    if sys.argv[1] == "--valgrind":
      _valgrind_command = "valgrind --quiet "
      del sys.argv[1]
    elif sys.argv[1].startswith("--valgrind="):
      _valgrind_command = sys.argv[1][len("--valgrind="):] + " "
      del sys.argv[1]
    elif sys.argv[1] == "--lzo":
      _server_options = ",lzo"
      del sys.argv[1]
    elif sys.argv[1] == "--zstd":
      _server_options = ",zstd"
      del sys.argv[1]
    elif sys.argv[1] == "--pump":
      _server_options = ",lzo,cpp"
      del sys.argv[1]

  # What: Raise the open-file soft limit to the hard limit.
  # Why: Some tests fork many children and need many fds.
  try:
      import resource
      (_, hard_limit) = resource.getrlimit(resource.RLIMIT_NOFILE)
      resource.setrlimit(resource.RLIMIT_NOFILE, (hard_limit, hard_limit))
  except (ImportError, ValueError):
      pass

  comfychair.main(tests)
