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

"""distcc test suite, using comfychair

This script is called with $PATH pointing to the appropriate location
for the built (or installed) programs to be tested.

Options:
  --valgrind[=command]    Run the tests under valgrind.
                          Every program invocation will be prefixed
                          with the valgrind command, which defaults to
                          "valgrind --quiet".
  --lzo                   Run the server tests with lzo compression enabled.
  --zstd                  Run the server tests with Zstandard compression enabled.
  --pump                  Run the server tests with remote preprocessing
                          enabled.
Example:
  PATH="`pwd`:$PATH"
  python test/testdistcc.py --valgrind="valgrind --quiet --num-callers=20"
"""


# There are pretty strong hierarchies of test cases: ones to do with
# running a daemon, compiling a file and so on.  This nicely maps onto
# a hierarchy of object classes.

# It seems to work best if an instance of the class corresponds to an
# invocation of a test: this means each method runs just once and so
# object state is not very useful, but nevermind.

# Having a complicated patterns of up and down-calls within the class
# methods seems to make things more complicated.  It may be better if
# abstract superclasses just provide methods that can be called,
# rather than establishing default behaviour.

# TODO: Some kind of direct test of the host selection algorithm.

# TODO: Test host files containing \r.

# TODO: Test that ccache correctly caches compilations through distcc:
# make up a random file so it won't hit, then compile once and compile
# twice and examine the log file to make sure we got a hit.  Also
# check that the binary works properly.

# TODO: Test cpp from stdin

# TODO: Do all this with malloc debugging on.

# TODO: Redirect daemon output to a file so that we can more easily
# check it.  Is there a straightforward way to test that it's also OK
# when send through syslogd?

# TODO: Check behaviour when children are killed off.

# TODO: Test compiling over IPv6

# TODO: Argument scanning tests should be run with various hostspecs,
# because that makes a big difference to how the client handles them.

# TODO: Test that ccache gets hits when calling distcc.  Presumably
# this is skipped if we can't find ccache.  Need to parse `ccache -s`.

# TODO: Set TMPDIR to be inside the working directory, and perhaps
# also set DISTCC_SAVE_TEMPS.  Might help for debugging.

# Check that without DISTCC_SAVE_TEMPS temporary files are cleaned up.

# TODO: Perhaps redirect stdout, stderr to a temporary file while
# running?  Use os.open(), os.dup2().

# TODO: Test crazy option arguments like "distcc -o -output -c foo.c"

# TODO: Add test harnesses that just exercise the bulk file transfer
# routines.

# TODO: Test -MD, -MMD, -M, etc.

# TODO: Test using '.include' in an assembly file, and make sure that
# it is resolved on the client, not on the server.

# TODO: Run "sleep" as a compiler, then kill the client and make sure
# that the server and "sleep" promptly terminate.

# TODO: Perhaps have a little compiler that crashes.  Check that the
# signal gets properly reported back.

# TODO: Have a little compiler that takes a very long time to run.
# Try interrupting the connection and see if the compiler is cleaned
# up in a reasonable time.

# TODO: Try to build a nonexistent source file.  Check that we only
# get one error message -- if there were two, we would incorrectly
# have tried to build the program both remotely and locally.

# TODO: Test compiling a 0-byte source file.  This should be allowed.

# TODO: Test a compiler that produces 0 byte output.  I don't know an
# easy way to get that out of gcc aside from the Apple port though.

# TODO: Test a compiler that sleeps for a long time; try killing the
# server and make sure it goes away.

# TODO: Test scheduler.  Perhaps run really slow jobs to make things
# deterministic, and test that they're dispatched in a reasonable way.

# TODO: Test generating dependencies with -MD.  Possibly can't be
# done.

# TODO: Test a nasty cpp that always writes to stdout regardless of
# -o.

# Giving up privilege using --user is now covered, root-only, by
# AutogroupNicenessPrivilegeDrop_Case below: GitHub Actions runners give
# real root via sudo on a real Linux kernel, so the "may need root
# privileges" limitation that deferred this for 15+ years no longer
# applies for at least this one --user scenario.

# TODO: Test that recursion safeguard works.

# TODO: Test masquerade mode.  Requires us to create symlinks in a
# special directory on the path.

# TODO: Test SSH mode.  May need to skip if we can't ssh to this
# machine.  Perhaps provide a little null-ssh.

# TODO: Test path stripping.

# TODO: Test backoff from downed hosts.

# TODO: Check again in --no-prefork mode.

# TODO: Test lzo is parsed properly

# TODO: Test with DISTCC_DIR set, and not set.

# TODO: Using --lifetime does cause sporadic failures.  Ensure that
# teardown kills all daemon processes and then stop using --lifetime.


import time, sys, os, glob, re, socket, errno
import signal, os.path, pwd, tempfile, shutil
import comfychair

from stat import *                      # this is safe

EXIT_DISTCC_FAILED           = 100
EXIT_BAD_ARGUMENTS           = 101
EXIT_BIND_FAILED             = 102
EXIT_CONNECT_FAILED          = 103
EXIT_COMPILER_CRASHED        = 104
EXIT_OUT_OF_MEMORY           = 105
EXIT_BAD_HOSTSPEC            = 106
EXIT_COMPILER_MISSING        = 110
EXIT_ACCESS_DENIED           = 113

DISTCC_TEST_PORT             = 42000

_cc                          = None     # full path to gcc
_valgrind_command            = "" # Command to invoke valgrind (or other
                                  # similar debugging tool).
                                  # e.g. "valgrind --quiet --num-callsers=20 "
_server_options              = "" # Distcc host options to use for the server.
                                  # Should be "", ",lzo", or ",lzo,cpp".

def _ShellSafe(s):
    '''Returns a version of s that will be interpreted literally by the shell.'''
    return "'" + s.replace("'", "'\"'\"'") + "'"

# Some tests only make sense for certain object formats
def _FirstBytes(filename, count):
    '''Returns the first count bytes from the given file.'''
    f = open(filename, 'rb')
    try:
        return f.read(count)
    finally:
        f.close()

def _IsElf(filename):
    '''Given a filename, determine if it's an ELF object file or
    executable.  The magic number used ('\177ELF' at file-start) is
    taken from /usr/share/file/magic on an ubuntu machine.
    '''
    contents = _FirstBytes(filename, 5)
    return contents.startswith(b'\177ELF')

def _IsMachO(filename):
    '''Given a filename, determine if it's an Mach-O object file or
    executable.  The magic number used ('0xcafebabe' or '0xfeedface')
    is taken from /usr/share/file/magic on an ubuntu machine.
    '''
    contents = _FirstBytes(filename, 10)
    return (contents.startswith(b'\xCA\xFE\xBA\xBE') or
            contents.startswith(b'\xFE\xED\xFA\xCE') or
            contents.startswith(b'\xCE\xFA\xED\xFE') or
            # The magic file says '4-bytes (BE) & 0xfeffffff ==
            # 0xfeedface' and '4-bytes (LE) & 0xfffffffe ==
            # 0xfeedface' are also mach-o.
            contents.startswith(b'\xFF\xED\xFA\xCE') or
            contents.startswith(b'\xCE\xFA\xED\xFF'))

def _IsPE(filename):
    '''Given a filename, determine if it's a Microsoft PE object file or
    executable.  The magic number used ('MZ') is taken from
    /usr/share/file/magic on an ubuntu machine.
    '''
    contents = _FirstBytes(filename, 5)
    return contents.startswith(b'MZ')

def _Touch(filename):
    '''Update the access and modification time of the given file,
    creating an empty file if it does not exist.
    '''
    f = open(filename, 'a')
    try:
        os.utime(filename, None)
    finally:
        f.close()


class SimpleDistCC_Case(comfychair.TestCase):
    '''Abstract base class for distcc tests'''
    def setup(self):
        self.stripEnvironment()
        self.initCompiler()

    def initCompiler(self):
        self._cc = self._get_compiler()

    def stripEnvironment(self):
        """Remove all DISTCC variables from the environment, so that
        the test is not affected by the development environment."""
        for key in list(os.environ.keys()):
            if key[:7] == 'DISTCC_':
                # NOTE: This only works properly on Python 2.2: on
                # earlier versions, it does not call unsetenv() and so
                # subprocesses may get confused.
                del os.environ[key]
        os.environ['TMPDIR'] = self.tmpdir
        ddir = os.path.join(self.tmpdir, 'distccdir')
        os.mkdir(ddir)
        os.environ['DISTCC_DIR'] = ddir

    def valgrind(self):
        return _valgrind_command;

    def distcc(self):
        if "cpp" not in _server_options:
            return self.valgrind() + "distcc "
        else:
            return "DISTCC_TESTING_INCLUDE_SERVER=1 " + self.valgrind() + "distcc "


    def distccd(self):
        return self.valgrind() + "distccd "

    def distcc_with_fallback(self):
        return "DISTCC_FALLBACK=1 " + self.distcc()

    def distcc_without_fallback(self):
        return "DISTCC_FALLBACK=0 " + self.distcc()

    def _get_compiler(self):
        cc = self._find_compiler("cc")
        if self.is_clang(cc):
            return self._find_compiler("clang")
        elif self.is_gcc(cc):
            return self._find_compiler("gcc")
        raise AssertionError("Unknown compiler")

    def _find_compiler(self, compiler):
        for path in os.environ['PATH'].split (':'):
            abs_path = os.path.join (path, compiler)

            if os.path.isfile (abs_path):
                return abs_path
        return None

    def is_gcc(self, compiler):
        out, err = self.runcmd(compiler + " --version")
        if re.search('Free Software Foundation', out):
            return True
        return False

    def is_clang(self, compiler):
        out, err = self.runcmd(compiler + " --version")
        if re.search('clang', out):
            return True
        return False


class WithDaemon_Case(SimpleDistCC_Case):
    """Start the daemon, and then run a command locally against it.

The daemon doesn't detach until it has bound the network interface, so
as soon as that happens we can go ahead and start the client."""

    def setup(self):
        SimpleDistCC_Case.setup(self)
        self.daemon_pidfile = os.path.join(os.getcwd(), "daemonpid.tmp")
        self.daemon_logfile = os.path.join(os.getcwd(), "distccd.log")
        self.daemon_sysroot = os.getcwd()
        self.server_port = DISTCC_TEST_PORT # random.randint(42000, 43000)
        self.startDaemon()
        self.setupEnv()

    def setupEnv(self):
        os.environ['DISTCC_HOSTS'] = ('127.0.0.1:%d%s' %
          (self.server_port, _server_options))
        os.environ['DISTCC_LOG'] = os.path.join(os.getcwd(), 'distcc.log')
        os.environ['DISTCC_VERBOSE'] = '1'


    def teardown(self):
        SimpleDistCC_Case.teardown(self)


    def killDaemon(self):
        try:
            pid = int(open(self.daemon_pidfile, 'rt').read())
        except IOError:
            # the daemon probably already exited, perhaps because of a timeout
            return
        os.kill(pid, signal.SIGTERM)

        # We can't wait on it, because it detached.  So just keep
        # pinging until it goes away.
        while 1:
            try:
                os.kill(pid, 0)
            except OSError:
                break
            time.sleep(0.2)


    def daemon_command(self):
        """Return command to start the daemon"""
        return (self.distccd() +
                "--verbose --lifetime=%d --daemon --log-file %s "
                "--pid-file %s --port %d --allow 127.0.0.1 --enable-tcp-insecure "
		"--sysroot %s"
                % (self.daemon_lifetime(),
                   _ShellSafe(self.daemon_logfile),
                   _ShellSafe(self.daemon_pidfile),
                   self.server_port,
                   _ShellSafe(self.daemon_sysroot)))

    def daemon_lifetime(self):
        # Enough for most tests, even on a fairly loaded machine.
        # Might need more for long-running tests.
        return 60

    def startDaemon(self):
        """Start a daemon in the background, return its pid"""
        # The daemon detaches once it has successfully bound the
        # socket, so if something goes wrong at startup we ought to
        # find out straight away.  If it starts successfully, then we
        # can go ahead and try to connect.
        # We run the daemon in a 'daemon' subdirectory to make
        # sure that it has a different directory than the client.
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

class StartStopDaemon_Case(WithDaemon_Case):
    def runtest(self):
        pass


class VersionOption_Case(SimpleDistCC_Case):
    """Test that --version returns some kind of version string.

    This is also a good test that the programs were built properly and are
    executable."""
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


class HelpOption_Case(SimpleDistCC_Case):
    """Test --help is reasonable."""
    def runtest(self):
        for prog in 'distcc', 'distccd':
            out, err = self.runcmd(prog + " --help")
            self.assert_re_search("Usage:", out)


class BogusOption_Case(SimpleDistCC_Case):
    """Test handling of --bogus-option.

    Now that we support implicit compilers, this is passed to gcc,
    which returns a non-zero status."""
    def runtest(self):
        # Disable the test in pump mode since the pump wrapper fails
        # before we can run distcc.
        if "cpp" in _server_options:
            raise comfychair.NotRunError('pump wrapper expects DISTCC_HOSTS')

        error_rc, _, _ = self.runcmd_unchecked(self._cc + " --bogus-option")
        assert error_rc != 0
        self.runcmd(self.distcc() + self._cc + " --bogus-option", error_rc)
        self.runcmd(self.distccd() + self._cc + " --bogus-option",
                    EXIT_BAD_ARGUMENTS)


class CompilerOptionsPassed_Case(SimpleDistCC_Case):
    """Test that options following the compiler name are passed to the compiler."""
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


class StripArgs_Case(SimpleDistCC_Case):
    """Test local-only preprocessor arguments are removed"""
    def runtest(self):
        cases = (("gcc -c hello.c", "gcc -c hello.c"),
                 ("cc -Dhello hello.c -c", "cc hello.c -c"),
                 ("gcc -g -O2 -W -Wall -Wshadow -Wpointer-arith -Wcast-align -c -o h_strip.o h_strip.c",
                  "gcc -g -O2 -W -Wall -Wshadow -Wpointer-arith -Wcast-align -c -o h_strip.o h_strip.c"),
                 # invalid but should work
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

                 # New options stripped in 0.11
                 ("cc -o nsinstall.o -c -DOSTYPE=\"Linux2.4\" -DOSARCH=\"Linux\" -DOJI -D_BSD_SOURCE -I../dist/include -I../dist/include -I/home/mbp/work/mozilla/mozilla-1.1/dist/include/nspr -I/usr/X11R6/include -fPIC -I/usr/X11R6/include -Wall -W -Wno-unused -Wpointer-arith -Wcast-align -pedantic -Wno-long-long -pthread -pipe -DDEBUG -D_DEBUG -DDEBUG_mbp -DTRACING -g -I/usr/X11R6/include -include ../config-defs.h -DMOZILLA_CLIENT -Wp,-MD,.deps/nsinstall.pp nsinstall.c",
                  "cc -o nsinstall.o -c -fPIC -Wall -W -Wno-unused -Wpointer-arith -Wcast-align -pedantic -Wno-long-long -pthread -pipe -g nsinstall.c"),

                 # -x is stripped (both two-word and combined forms) so a
                 # remote compile of an already-preprocessed file doesn't
                 # corrupt debug info (issue #79)
                 ("gcc -x c++ -g -std=c++17 -c hello.ii -o hello.o",
                  "gcc -g -std=c++17 -c hello.ii -o hello.o"),
                 ("g++ -xc++ -g -c hello.ii -o hello.o",
                  "g++ -g -c hello.ii -o hello.o"),
                 ("gcc -xobjective-c++ -g -c hello.mii -o hello.o",
                  "gcc -g -c hello.mii -o hello.o"),

                 # A token introduced by "-Xclang" is verbatim clang cc1
                 # payload and must survive stripping even when it looks like
                 # a local-only flag: the -target-feature disable values
                 # "-lwp"/"-xop" (produced by -march=native resolution)
                 # otherwise match the "-l<lib>"/"-x<lang>" strip prefixes and
                 # are silently dropped, corrupting the "-Xclang -target-feature
                 # -Xclang <value>" quadruple the remote clang then rejects.
                 ("clang -Xclang -target-feature -Xclang -lwp -c hello.c -o hello.o",
                  "clang -Xclang -target-feature -Xclang -lwp -c hello.c -o hello.o"),
                 ("clang -Xclang -target-feature -Xclang -xop -c hello.c -o hello.o",
                  "clang -Xclang -target-feature -Xclang -xop -c hello.c -o hello.o"),
                 # A bare (non-"-Xclang") token keeps its existing meaning:
                 # "-lwp" is still treated as a "-l" link flag and stripped.
                 ("clang -lwp -c hello.c -o hello.o",
                  "clang -c hello.c -o hello.o"),
                 )
        for cmd, expect in cases:
            o, err = self.runcmd("h_strip %s" % cmd)
            if o[-1] == '\n': o = o[:-1]
            self.assert_equal(o, expect)


class Stats_Case(SimpleDistCC_Case):
    """Test distccd statistics list maintenance."""
    def runtest(self):
        out, err = self.runcmd("h_stats prune-old-head")
        self.assert_equal(out.strip(), "ok")


class IsSource_Case(SimpleDistCC_Case):
    def runtest(self):
        """Test distcc's method for working out whether a file is source"""
        cases = (( "hello.c",          "source",       "not-preprocessed" ),
                 ( "hello.cc",         "source",       "not-preprocessed" ),
                 ( "hello.cxx",        "source",       "not-preprocessed" ),
                 ( "hello.cpp",        "source",       "not-preprocessed" ),
                 ( "hello.c++",        "source",       "not-preprocessed" ),
                 # ".m" is Objective-C; ".M" and ".mm" are Objective-C++
                 ( "hello.m",          "source",       "not-preprocessed" ),
                 ( "hello.M",          "source",       "not-preprocessed" ),
                 ( "hello.mm",         "source",       "not-preprocessed" ),
                 # ".mi" and ".mii" are preprocessed Objective-C/Objective-C++.
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


class PathSafety_Case(SimpleDistCC_Case):
    def runtest(self):
        """Test dcc_name_has_path_traversal(), dcc_cdir_has_path_traversal(),
        and dcc_absolute_link_target_has_path_traversal(), which guard the
        NAME, CDIR, and (partially) LINK tokens respectively.

        NAME validation guards dcc_r_many_files() (src/srvrpc.c) against a
        client-supplied path that could escape the server's per-job temp
        directory (issue #93).

        LINK-target validation (absolute-style link_target only) guards the
        same function's symlink-creation path against the same "/../ "
        escape shape (issue #95) -- a relative link_target is deliberately
        left unvalidated; see pathsafety.h's own comment on
        dcc_absolute_link_target_has_path_traversal() for why that residual
        case needs a real containment boundary (issue #289), not a text
        check, to close properly.

        CDIR validation guards make_temp_dir_and_chdir_for_cpp() (src/serve.c)
        against a client-supplied current working directory that could allow
        directory traversal when concatenated with the server's temp directory
        (CDIR path-traversal issue found during #100 triage).
        """
        # Test dcc_name_has_path_traversal() behavior (NAME token):
        # Safe: rooted at '/', no ".." component anywhere.
        name_cases = (
                 ( "/usr/include/stdio.h",  "safe" ),
                 ( "/a/b/c.h",              "safe" ),
                 ( "/",                     "safe" ),
                 # A ".." that is part of a longer name, not a path
                 # component of its own, must NOT be rejected.
                 ( "/foo/..bar",            "safe" ),
                 ( "/foo/bar..",            "safe" ),
                 ( "/foo..bar/baz",         "safe" ),
                 # Unsafe: not rooted at '/'.
                 ( "usr/include/stdio.h",   "unsafe" ),
                 ( "",                      "unsafe" ),
                 # Unsafe: ".." as a leading, embedded, or trailing
                 # path component.
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

        # Test dcc_cdir_has_path_traversal() behavior (CDIR token):
        # Safe: absolute paths without "..", relative paths without "..".
        cdir_cases = (
                 # Safe: absolute paths without ".."
                 ( "/usr/local",            "safe" ),
                 ( "/home/user",            "safe" ),
                 ( "/",                     "safe" ),
                 # Safe: relative paths without ".." (CDIR allows relative paths)
                 ( "src",                   "safe" ),
                 ( "a/b/c",                 "safe" ),
                 ( "subdir/nested/dir",     "safe" ),
                 ( ".",                     "safe" ),
                 # A ".." that is part of a longer name, not a path
                 # component of its own, must NOT be rejected.
                 ( "foo/..bar",             "safe" ),
                 ( "foo/bar..",             "safe" ),
                 ( "foo..bar/baz",          "safe" ),
                 ( "/foo/..bar",            "safe" ),
                 ( "/foo/bar..",            "safe" ),
                 # Edge case: "/..bar" is NOT a traversal — ".." is just part
                 # of the directory name, not a path component by itself.
                 # Unlike "/..", which would be traversal, "/..bar" is safe.
                 ( "/..bar",                "safe" ),
                 # Unsafe: ".." as a leading, embedded, or trailing
                 # path component (leading).
                 ( "..",                    "unsafe" ),
                 ( "../etc/passwd",         "unsafe" ),
                 ( "/../etc/passwd",        "unsafe" ),
                 # Unsafe: ".." as an embedded path component.
                 ( "a/../b",                "unsafe" ),
                 ( "a/../../c",             "unsafe" ),
                 ( "foo/../../etc/passwd",  "unsafe" ),
                 # Unsafe: ".." as a trailing path component.
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

        # Test dcc_absolute_link_target_has_path_traversal() behavior
        # (LINK token's link_target, absolute-style only -- issue #95).
        # Only closes the absolute-target case (same "/../ " shape as NAME);
        # a relative link_target is deliberately not validated at all (see
        # pathsafety.h's own comment on dcc_absolute_link_target_has_path_traversal()
        # for why), so no relative cases are exercised here.
        link_target_cases = (
                 # Safe: rooted at '/', no ".." component anywhere.
                 ( "/usr/include",          "safe" ),
                 ( "/a/b/c",                "safe" ),
                 ( "/",                     "safe" ),
                 # A ".." that is part of a longer name, not a path
                 # component of its own, must NOT be rejected.
                 ( "/foo/..bar",            "safe" ),
                 ( "/foo/bar..",            "safe" ),
                 # Unsafe: ".." as a leading, embedded, or trailing
                 # path component.
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



class SymlinkTraversal_Case(SimpleDistCC_Case):
    """End-to-end regression for issue #292: distccd's multi-file receive
    (dcc_r_many_files() in src/srvrpc.c) must not follow a symlink sitting at
    an intermediate NAME component when materializing a later entry in the
    same NFIL batch.

    Unlike PathSafety_Case (which exercises the NAME/CDIR/LINK-target *string*
    checks in isolation), this drives the real dcc_r_many_files() code path
    via the h_srvrpc harness, feeding it the exact escape sequence from the
    issue: entry 1 creates a symlink NAME "/safe" with a relative,
    deliberately-unvalidated target pointing at a sibling directory, then
    entry 2 sends a FILE whose NAME "/safe/pwned" is nested underneath that
    symlink. A vulnerable server follows the symlink and writes outside the
    job directory; the fixed server rejects entry 2 with EXIT_PROTOCOL_ERROR
    (109) and nothing lands in the escape target.
    """
    def runtest(self):
        # --- Malicious sequence: must be rejected, must not escape. ---
        atk = os.path.join(self.tmpdir, "atk")
        jobdir = os.path.join(atk, "job")
        escape = os.path.join(atk, "escape")
        os.makedirs(jobdir)
        os.makedirs(escape)

        # From jobdir, "../escape" resolves to the sibling escape dir; the
        # symlink target is relative, so it passes every current string
        # check (this is exactly the case #290 leaves unvalidated).
        o, err = self.runcmd("h_srvrpc attack '%s' ../escape" % jobdir)
        if o != "ret=109\n":
            raise AssertionError(
                "attack sequence not rejected: h_srvrpc gave %s (stderr: %s), "
                "expected 'ret=109\\n'" % (repr(o), repr(err)))

        # The first entry's leaf symlink must exist (proving the test really
        # reached the vulnerable second step, not bailed out earlier)...
        safe = os.path.join(jobdir, "safe")
        if not os.path.islink(safe):
            raise AssertionError(
                "expected job/safe to have been created as a symlink; "
                "the attack never reached the nested-FILE step")
        # ...and the escape target must be empty: the nested FILE must NOT
        # have been written through the symlink.
        pwned = os.path.join(escape, "pwned")
        if os.path.exists(pwned):
            raise AssertionError(
                "PATH TRAVERSAL: nested FILE escaped the job directory and "
                "was written to %s" % pwned)

        # --- Benign nested sequence: must still succeed. ---
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
        if open(first).read() != "one":
            raise AssertionError("legit: %s has wrong contents" % first)
        if open(second).read() != "two":
            raise AssertionError("legit: %s has wrong contents" % second)
        # A leaf mirror-style relative symlink (nothing nested under it) is
        # legitimate pump traffic and must be created, not rejected.
        if not os.path.islink(mirror):
            raise AssertionError(
                "legit: expected %s to be created as a symlink" % mirror)
        if os.readlink(mirror) != "../elsewhere/real.h":
            raise AssertionError(
                "legit: %s points at %s, expected '../elsewhere/real.h'"
                % (mirror, os.readlink(mirror)))


class ScanArgs_Case(SimpleDistCC_Case):
    '''Test understanding of gcc command lines.'''
    def runtest(self):
        cases = [("gcc -c hello.c", "distribute", "hello.c", "hello.o"),
                 ("gcc hello.c", "local"),
                 ("gcc -o /tmp/hello.o -c ../src/hello.c", "distribute", "../src/hello.c", "/tmp/hello.o"),
                 ("gcc -DMYNAME=quasibar.c bar.c -c -o bar.o", "distribute", "bar.c", "bar.o"),
                 ("gcc -ohello.o -c hello.c", "distribute", "hello.c", "hello.o"),
                 ("ccache gcc -c hello.c", "distribute", "hello.c", "hello.o"),
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

                 # Assemble to stdout (thanks Alexandre).
                 ("gcc -S foo.c -o -", "local"),
                 ("-S -o - foo.c", "local"),
                 ("-c -S -o - foo.c", "local"),
                 ("-S -c -o - foo.c", "local"),

                 # dasho syntax
                 ("gcc -ofoo.o foo.c -c", "distribute", "foo.c", "foo.o"),
                 ("gcc -ofoo foo.o", "local"),

                 # tricky this one -- no dashc
                 ("foo.c -o foo.o", "local"),
                 ("foo.c -o foo.o -c", "distribute", "foo.c", "foo.o"),

                 # Produce assembly listings
                 ("gcc -Wa,-alh,-a=foo.lst -c foo.c", "local"),
                 ("gcc -Wa,--MD -c foo.c", "local"),
                 ("gcc -Wa,-xarch=v8 -c foo.c", "distribute", "foo.c", "foo.o"),

                 # Produce .rpo files
                 ("g++ -frepo foo.C", "local"),

                 ("gcc -xassembler-with-cpp -c foo.c", "local"),
                 ("gcc -x assembler-with-cpp -c foo.c", "local"),

                 ("gcc -specs=foo.specs -c foo.c", "distribute", "foo.c", "foo.o"),

                 # Fixed in 2.18.4 -- -dr writes rtl to a local file
                 ("gcc -dr -c foo.c", "local"),
                 ]
        for tup in cases:
            self.checkScanArgs(*tup)

    def checkScanArgs(self, ccmd, mode, input=None, output=None):
        o, err = self.runcmd("h_scanargs %s" % ccmd)
        o = o[:-1]                      # trim \n
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


class IncludeServerFileOrder_Case(SimpleDistCC_Case):
    """Test deterministic include server file ordering."""
    def runtest(self):
        out, err = self.runcmd("h_includesort /tmp/z /tmp/a /tmp/m")
        self.assert_equal(err, "")
        self.assert_equal(out, "/tmp/a /tmp/m /tmp/z\n")


class StateFileAtomicWrite_Case(SimpleDistCC_Case):
    """Test that state writes remain readable through the monitor."""
    def runtest(self):
        out, err = self.runcmd("h_state atomic-write")
        self.assert_equal(out, "")
        self.assert_equal(err, "")


class DotD_Case(SimpleDistCC_Case):
    '''Test the mechanism for calculating .d file names'''

    def runtest(self):
        # Each case specifies:
        #
        # - A compilation command.
        #
        # - A glob expression supposed to match exactly one file, the dependency
        #   file (which is not always a .d file, btw). The glob expression is
        #   our human intuition, based on our reading of the gcc manual pages,
        #   of the range of possible dependency names actually produced.
        #
        # - Whether 0 or 1 such dependency files exist.
        #
        # - The expected target name (or None).
        #

        # The dotd_name is thus divined by examination of the compilation
        # directory where we actually run gcc.

        cases = [
          ("foo.c -o hello.o -MD", "*.d", 1, None),
          ("foo.c -o hello.. -MD", "*.d", 1, None),
          ("foo.c -o hello.bar.foo -MD", "*.d", 1, None),
          ("foo.c -o hello.o", "*.d", 0, None),
          ("foo.c -o hello.bar.foo -MD", "*.d", 1, None),
          ("foo.c -MD", "*.d", 1, None),
          ("foo.c -o hello. -MD", "*.d", 1, None),
# The following test case fails under Darwin Kernel Version 8.11.0. For some
# reason, gcc refuses to produce 'hello.d' when the object file is named
# 'hello.D'.
#         ("foo.c -o hello.D -MD -MT tootoo", "hello.*d", 1, "tootoo"),
          ("foo.c -o hello. -MD -MT tootoo",  "hello.*d", 1, "tootoo"),
          ("foo.c -o hello.o -MD -MT tootoo", "hello.*d", 1, "tootoo"),
          ("foo.c -o hello.o -MD -MF foobar", "foobar", 1, None),
           ]

        # These C++ cases fail if your gcc installation doesn't support C++.
        error_rc, _, _ = self.runcmd_unchecked("touch testtmp.cpp; " +
            self._cc + " -c testtmp.cpp -o /dev/null")
        if error_rc == 0:
          cases.extend([("foo.cpp -o hello.o", "*.d", 0, None),
                        ("foo.cpp -o hello", "*.d", 0, None)])

        def _eval(out):
            map_out = eval(out)
            return (map_out['dotd_fname'],
                    map_out['needs_dotd'],
                    map_out['sets_dotd_target'],
                    map_out['dotd_target'])

        for (args, dep_glob, how_many, target) in cases:

            # Determine what gcc says.
            dotd_result = []  # prepare for some imperative style value passing
            class TempCompile_Case(Compilation_Case):
                def source(self):
                      return """
int main(void) { return 0; }
"""
                def sourceFilename(self):
                    return args.split()[0]
                def compileCmd(self):
                    return self._cc + " -c " + args
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

            # Determine what dcc_get_dotd_info says.
            out, _err = self.runcmd("h_dotd dcc_get_dotd_info gcc -c %s" % args)
            dotd_fname, needs_dotd, sets_dotd_target, dotd_target = _eval(out)
            assert dotd_fname
            assert needs_dotd in [0,1]
            # Assert that "needs_dotd == 1" if and only if "how_many == 1".
            assert needs_dotd == how_many
            # Assert that "needs_dotd == 1" implies names by gcc and our routine
            # are the same.
            if needs_dotd:
                self.assert_equal(expected_dep_file, dotd_fname)

            self.assert_equal(sets_dotd_target == 1, target != None)
            if target:
                # A little convoluted: because target is set in command line,
                # and the command line is passed already, the dotd_target is not
                # set.
                self.assert_equal(dotd_target, "None")


        # Now some fun with DEPENDENCIES_OUTPUT variable.
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


class Compile_c_Case(SimpleDistCC_Case):
  """Unit tests for source file 'compile.c.'

  Currently, only the functions dcc_fresh_dependency_exists() and
  dcc_discrepancy_filename() are tested.
  """

  def getDep(self, line):
      """Parse line to yield dependency name. From say:
          "src/h_compile.c[21010] (dcc_fresh_dependency_exists) Checking dependency: bar_bar"
         return "bar_bar".
      """
      m_obj = re.search(r"Checking dependency: ((\w|[.])*)", line)
      assert m_obj, line
      return m_obj.group(1)

  def runtest(self):

      # Test dcc_discrepancy_filename
      # ********************************
      os.environ['INCLUDE_SERVER_PORT'] = "abc/socket"
      out, err = self.runcmd(
              "h_compile dcc_discrepancy_filename")
      self.assert_equal(out, "abc/discrepancy_counter")

      os.environ['INCLUDE_SERVER_PORT'] = "socket"
      out, err = self.runcmd(
              "h_compile dcc_discrepancy_filename")
      self.assert_equal(out, "(NULL)")

      # os.environ will be cleaned out at start of next test.

      # Test dcc_fresh_dependency_exists
      # ********************************
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
          # Now postulate the time that is the beginning of build. This time
          # is after that of all the dependencies. time_ref is computed as an
          # already-rounded whole integer (not a float) with a 2-second safety
          # margin: dcc_fresh_dependency_exists() compares the .d file's real
          # (integer) mtime against reference_time, and this value is later
          # passed to the C harness via "%i" formatting. Passing a float here
          # and letting "%i" truncate it towards zero silently shrinks the
          # intended margin -- under CI load (this suite runs twice per job),
          # that shrunk margin has been observed to let the .d file's mtime
          # land at or below the truncated reference_time, tripping the
          # dcc_fresh_dependency_exists() "old dotd file" trace instead of
          # the expected freshness result. Computing an integer margin up
          # front removes the truncation surprise entirely and adds a full
          # extra second of headroom against scheduling jitter.
          time_ref = int(time.time()) + 2
          # Let real-time advance to time_ref, polling finely so we don't
          # overshoot by up to a full second per iteration.
          while time.time() < time_ref:
              time.sleep(0.1)
          # Create .d file now, so that it appears to be no older than
          # time_ref.
          dotd_fd = open("dotd", "w")
          dotd_fd.write(dotd_contents)
          dotd_fd.close()
          # Check: no fresh files here!
          out, err = self.runcmd(
              "h_compile dcc_fresh_dependency_exists dotd '%s' %i" %
              ("*notthis*", time_ref))
          self.assert_equal(out.split()[1], "(NULL)");
          checked_deps = {}
          for line in err.split("\n"):
              # Only feed lines carrying the expected marker to getDep():
              # dcc_fresh_dependency_exists() can legitimately emit other
              # rs_trace() lines on this path (e.g. "old dotd file ...",
              # "could not stat ..."), which getDep()'s regex was never
              # meant to parse. Filtering here keeps getDep()'s internal
              # assert a true invariant instead of a fragile assumption
              # that every non-blank line matches.
              if "Checking dependency:" in line:
                  checked_deps[self.getDep(line)] = 1
          deps_list = deps[:]
          checked_deps_list = list(checked_deps.keys())
          deps_list.sort()
          checked_deps_list.sort()
          self.assert_equal(checked_deps_list, deps_list)

          # Let's try to touch, say the last dep file. Then, we should expect
          # the name of that very file as the output because there's a fresh
          # file.
          if deps:
              _Touch(deps[-1])
              out, err = self.runcmd(
                  "h_compile dcc_fresh_dependency_exists dotd '' %i" %
                  time_ref)
              self.assert_equal(out.split()[1], deps[-1])


class ImplicitCompilerScan_Case(ScanArgs_Case):
    '''Test understanding of commands with no compiler'''
    def runtest(self):
        cases = [("-c hello.c",            "distribute", "hello.c", "hello.o"),
                 ("hello.c -c",            "distribute", "hello.c", "hello.o"),
                 ("-o hello.o -c hello.c", "distribute", "hello.c", "hello.o"),
                 ]
        for tup in cases:
            # NB use "apply" rather than new syntax for compatibility with
            # venerable Pythons.
            self.checkScanArgs(*tup)


class ExtractExtension_Case(SimpleDistCC_Case):
    def runtest(self):
        """Test extracting extensions from filenames"""
        for f, e in (("hello.c", ".c"),
                     ("hello.cpp", ".cpp"),
                     ("hello.2.4.4.4.c", ".c"),
                     (".foo", ".foo"),
                     ("gcc", "(NULL)")):
            out, err = self.runcmd("h_exten '%s'" % f)
            assert out == e


class DaemonBadPort_Case(SimpleDistCC_Case):
    def runtest(self):
        """Test daemon invoked with invalid port number"""
        self.runcmd(self.distccd() +
                    "--log-file=distccd.log --lifetime=10 --port 80000 "
                    "--allow 127.0.0.1 --enable-tcp-insecure",
                    EXIT_BAD_ARGUMENTS)
        self.assert_no_file("daemonpid.tmp")


class TcpInsecureOptionOrder_Case(SimpleDistCC_Case):
    def runtest(self):
        """Test --enable-tcp-insecure is honored in different positions."""
        out, err = self.runcmd("h_dopt tcp-insecure-order")
        self.assert_equal(out.strip(), "ok")


class InvalidHostSpec_Case(SimpleDistCC_Case):
    def runtest(self):
        """Test various invalid DISTCC_HOSTS

        See also test_parse_host_spec, which tests valid specifications."""
        for spec in ["", "    ", "\t", "  @ ", ":", "mbp@", "angry::", ":4200"]:
            self.runcmd(("DISTCC_HOSTS=\"%s\" " % spec) + self.valgrind()
                        + "h_hosts -v",
                        EXIT_BAD_HOSTSPEC)


class ParseHostSpec_Case(SimpleDistCC_Case):
    def runtest(self):
        """Check operation of dcc_parse_hosts_env.

        Passes complex environment variables to h_hosts, which is a C wrapper
        that calls the appropriate tests."""
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


class SecureShellCommandEnvironment_Case(SimpleDistCC_Case):
    """Check that DISTCC_SSH options survive repeated Secure Shell connects."""
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


class Compilation_Case(WithDaemon_Case):
    '''Test distcc by actually compiling a file'''
    def setup(self):
        WithDaemon_Case.setup(self)
        self.createSource()

    def runtest(self):
        self.compile()
        self.link()
        self.checkBuiltProgram()

    def createSource(self):
        filename = self.sourceFilename()
        f = open(filename, 'w')
        f.write(self.source())
        f.close()
        filename = self.headerFilename()
        f = open(filename, 'w')
        f.write(self.headerSource())
        f.close()

    def sourceFilename(self):
        return "testtmp.c"              # default

    def headerFilename(self):
        return "testhdr.h"              # default

    def headerSource(self):
        return ""                       # default

    def compile(self):
        cmd = self.compileCmd()
        out, err = self.runcmd(cmd)
        if out != '':
            self.fail("compiler command %s produced output:\n%s" % (repr(cmd), out))
        if err != '':
            self.fail("compiler command %s produced error:\n%s" % (repr(cmd), err))

    def link(self):
        cmd = self.linkCmd()
        out, err = self.runcmd(cmd)
        if out != '':
            self.fail("command %s produced output:\n%s" % (repr(cmd), repr(out)))
        if err != '':
            self.fail("command %s produced error:\n%s" % (repr(cmd), repr(err)))

    def compileCmd(self):
        """Return command to compile source"""
        return self.distcc_without_fallback() + \
               self._cc + " -o testtmp.o " + self.compileOpts() + \
               " -c %s" % (self.sourceFilename())

    def compileOpts(self):
        """Returns any extra options to pass when compiling"""
        return ""

    def linkCmd(self):
        """Return command to link object files"""
        return self.distcc() + \
               self._cc + " -o testtmp testtmp.o " + self.libraries()

    def libraries(self):
        """Returns any '-l' options needed to link the program."""
        return ""

    def checkCompileMsgs(self, msgs):
        if len(msgs) > 0:
            self.fail("expected no compiler messages, got \"%s\"" % msgs)

    def checkBuiltProgram(self):
        '''Check compile/link results.  By default, just try to execute.'''
        msgs, errs = self.runcmd("./testtmp")
        self.checkBuiltProgramMsgs(msgs)
        self.assert_equal(errs, '')

    def checkBuiltProgramMsgs(self, msgs):
        pass


class CompileHello_Case(Compilation_Case):
    """Test the simple case of building a program that works properly"""

    def headerSource(self):
        return """
#define HELLO_WORLD "hello world"
"""

    def source(self):
        return """
#include <stdio.h>
#include "%s"
int main(void) {
    puts(HELLO_WORLD);
    return 0;
}
""" % self.headerFilename()

    def checkBuiltProgramMsgs(self, msgs):
        self.assert_equal(msgs, "hello world\n")


class CommaInFilename_Case(CompileHello_Case):

    def headerFilename(self):
      return 'foo1,2.h'


class ComputedInclude_Case(CompileHello_Case):

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

class BackslashInMacro_Case(ComputedInclude_Case):
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

class BackslashInFilename_Case(ComputedInclude_Case):

    def headerFilename(self):
      # On Windows, this filename will be in a subdirectory.
      # On Unix, it will be a filename with an embedded backslash.
      try:
        os.mkdir("subdir")
      except:
        pass
      return 'subdir\\testhdr.h'

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

class MarchNativeDispatcherPath_Case(CompileHello_Case):
    """-march=native must resolve using the compiler binary actually invoked,
    not a basename re-resolved via a fresh PATH search.

    Regression test for arg.c's dcc_resolve_march_native(): argv[0] here is
    an explicit path to a dispatcher script that is NOT named "clang" (and
    lives in a directory that is deliberately not on $PATH), but the script
    execs the real local clang underneath -- mirroring macOS's "cc", which
    is a small dispatch binary rather than a symlink, and any other
    non-obviously-named compiler wrapper.

    Before the fix, dcc_resolve_march_native() stripped argv[0] down to its
    basename and ran execlp() on that basename alone; since the dispatcher's
    own basename is not on $PATH here, that lookup fails, "-march=native"
    is left unresolved, and the existing hard-fail-to-local path silently
    routes the whole compile through a local fallback instead of
    distributing it. After the fix, execlp() is handed argv[0] unchanged,
    so a path containing '/' is executed literally (no PATH search) --
    the dispatcher runs for real, "-march=native" resolves to concrete
    clang flags, and the compile distributes normally.

    A real remote distribution (not just "the resulting binary works",
    which a silent local fallback would also produce) is confirmed by
    grepping the daemon's own independent log for a COMPILE_OK entry, per
    doc/verification-checklist.md section 3's real-two-host evidence bar --
    a trace line or a working binary alone cannot tell these two cases
    apart."""

    def setup(self):
        # Builds the fake dispatcher fixture described in the class
        # docstring: a real, non-"clang"-named executable script that execs
        # the real local clang, placed outside $PATH so a basename-only
        # lookup (the pre-fix bug) cannot find it by name alone.
        CompileHello_Case.setup(self)
        clang = self._find_compiler("clang")
        self.require(clang is not None,
                     "no clang found on $PATH to build the fake dispatcher from")
        # -march=native's acceptance is itself arch/compiler-dependent (e.g.
        # some clang/AArch64 combinations reject it outright). If the local
        # clang doesn't accept it at all, dcc_resolve_march_native()'s probe
        # fails regardless of this fix, the compile falls through to a local
        # gcc/clang invocation of "-march=native" that ALSO errors there --
        # a real compile failure, not a clean skip -- so this must be
        # checked before relying on the flag being usable at all here.
        probe_rc, _, probe_err = self.runcmd_unchecked(
            "%s -march=native -E -x c - < /dev/null > /dev/null" % clang)
        self.require(probe_rc == 0,
                     "local clang does not accept -march=native on this arch")
        # Some hosts' clang legitimately emits its own warning while
        # resolving "-march=native" (seen: "invalid feature combination:
        # +avx10.1-256; will be promoted to avx10.1-512") -- this is the
        # SYSTEM/dispatcher clang commenting on its own flag resolution,
        # not a diagnostic about distcc-ng's source, but this test's
        # compile() (inherited, unmodified) fails on any non-empty stderr,
        # same as every other compile in this suite. Silently filtering a
        # known warning pattern out of that check (tried once, reverted)
        # would weaken the warnings-are-errors discipline for exactly the
        # cases where a real regression could hide behind a real one; skip
        # cleanly instead of degrading what "pass" means for this test.
        self.require(probe_err == '',
                     "local clang's own -march=native resolution emits a "
                     "warning on this host (%r) -- skipping rather than "
                     "filtering it out of this test's warning-as-error "
                     "check" % probe_err)
        # Deliberately not on $PATH and deliberately not named anything
        # containing "clang"/"gcc"/"cc" -- a basename-only PATH search (the
        # pre-fix behavior) must not be able to resolve this by name alone.
        dispatch_dir = os.path.join(os.getcwd(), "not_on_path")
        os.mkdir(dispatch_dir)
        self.dispatcher_path = os.path.join(dispatch_dir, "mycompiler")
        f = open(self.dispatcher_path, "w")
        f.write("#!/bin/sh\nexec %s \"$@\"\n" % clang)
        f.close()
        os.chmod(self.dispatcher_path, 0o700)

    def compileCmd(self):
        # Invokes the dispatcher by its full path (not a bare name), with
        # DISTCC_FALLBACK disabled so a broken -march=native resolution
        # surfaces as a hard failure instead of a silently-successful local
        # compile that would mask the exact regression this test targets.
        return self.distcc_without_fallback() + \
               self.dispatcher_path + " -o testtmp.o -march=native " + \
               self.compileOpts() + " -c %s" % (self.sourceFilename())

    def linkCmd(self):
        # Link step doesn't exercise -march=native resolution itself, but
        # must still invoke the same full-path dispatcher as compileCmd()
        # so the produced object file links against a consistent compiler.
        return self.distcc() + \
               self.dispatcher_path + " -o testtmp testtmp.o " + self.libraries()

    def runtest(self):
        # A working binary alone can't distinguish a real remote
        # distribution from a silent local fallback (both produce a valid
        # testtmp) -- grepping the daemon's own independent log for
        # COMPILE_OK is the actual proof the compile was distributed, per
        # doc/verification-checklist.md section 3's real-two-host evidence
        # bar.
        CompileHello_Case.runtest(self)
        daemon_log = open(self.daemon_logfile).read()
        self.assert_re_search(r'COMPILE_OK', daemon_log)


class LanguageSpecific_Case(Compilation_Case):
    """Abstract base class to test building non-C programs."""
    def runtest(self):
        # Don't try to run the test if the language's compiler is not installed
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

    def sourceFilename(self):
      return "testtmp" + self.extension()

    def languageGccName(self):
      """Language name suitable for use with 'gcc -x'"""
      raise NotImplementedError

    def languageName(self):
      """Human-readable language name."""
      raise NotImplementedError

    def extension(self):
      """Filename extension, with leading '.'."""
      raise NotImplementedError


class CPlusPlus_Case(LanguageSpecific_Case):
    """Test building a C++ program."""

    def languageName(self):
      return "C++"

    def languageGccName(self):
      return "c++"

    def extension(self):
      return ".cpp"  # Could also use ".cc", ".cxx", etc.

    def libraries(self):
      return "-lstdc++"

    def headerSource(self):
        return """
#define MESSAGE "hello c++"
"""

    def source(self):
        return """
#include <iostream>
#include "testhdr.h"

int main(void) {
    std::cout << MESSAGE << std::endl;
    return 0;
}
"""

    def checkBuiltProgramMsgs(self, msgs):
        self.assert_equal(msgs, "hello c++\n")


class ObjectiveC_Case(LanguageSpecific_Case):
    """Test building an Objective-C program."""

    def languageName(self):
      return "Objective-C"

    def languageGccName(self):
      return "objective-c"

    def extension(self):
      return ".m"

    def headerSource(self):
        return """
#define MESSAGE "hello objective-c"
"""

    def source(self):
        return """
#import <stdio.h>
#import "testhdr.h"

/* TODO: use objective-c features. */

int main(void) {
    puts(MESSAGE);
    return 0;
}
"""

class ObjectiveCPlusPlus_Case(LanguageSpecific_Case):
    """Test building an Objective-C++ program."""

    def languageName(self):
      return "Objective-C++"

    def languageGccName(self):
      return "objective-c++"

    def extension(self):
      return ".mm"

    def libraries(self):
      return "-lstdc++"

    def headerSource(self):
        return """
#define MESSAGE "hello objective-c++"
"""

    def source(self):
        return """
#import <iostream>
#import "testhdr.h"

/* TODO: use Objective-C features. */

int main(void) {
    std::cout << MESSAGE << std::endl;
    return 0;
}
"""

    def checkBuiltProgramMsgs(self, msgs):
        self.assert_equal(msgs, "hello objective-c++\n")


class SystemIncludeDirectories_Case(Compilation_Case):
    """Test -I/usr/include/sys"""

    def compileOpts(self):
        if os.path.exists("/usr/include/sys/types.h"):
          return "-I/usr/include/"
        else:
          raise comfychair.NotRunError (
              "This test requires /usr/include/sys/types.h")

    def headerSource(self):
        return """
#define HELLO_WORLD "hello world"
"""

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

    def checkBuiltProgramMsgs(self, msgs):
        self.assert_equal(msgs, "hello world\n")


class CPlusPlus_SystemIncludeDirectories_Case(CPlusPlus_Case):
    """Test -I/usr/include/sys for a C++ program"""

    def compileOpts(self):
        if os.path.exists("/usr/include/sys/types.h"):
          return "-I/usr/include/sys"
        else:
          raise comfychair.NotRunError (
              "This test requires /usr/include/sys/types.h")

    def headerSource(self):
        return """
#define MESSAGE "hello world"
"""

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
    def checkBuiltProgramMsgs(self, msgs):
        self.assert_equal(msgs, "hello world\n")


class Gdb_Case(CompileHello_Case):
    """Test that distcc generates correct debugging information."""

    def sourceFilename(self):
        try:
          os.mkdir("src")
        except:
          pass
        return "src/testtmp.c"

    def compiler(self):
        """Command for compiling and linking."""
        return self._cc + " -g ";

    def compileCmd(self):
        """Return command to compile source"""
        os.mkdir("obj")
        return self.distcc_without_fallback() + self.compiler() + \
               " -o obj/testtmp.o -I. -c %s" % (self.sourceFilename())

    def link(self):
        """
        We do the linking in a subdirectory, so that the 'compilation
        directory' field of the debug info set by the link step (which
        will be done locally, not remotely) does NOT influence the
        behaviour of gdb.  We want gdb to use the 'compilation directory'
        value set by the compilation.
        """
        os.mkdir('link')
        cmd = (self.distcc() + self.compiler() + self.build_id +
               " -o link/testtmp obj/testtmp.o")
        out, err = self.runcmd(cmd)
        if out != '':
            self.fail("command %s produced output:\n%s" % (repr(cmd), repr(out)))
        if err != '':
            self.fail("command %s produced error:\n%s" % (repr(cmd), repr(err)))

    def runtest(self):
        # Don't try to run the test if gdb is not installed
        error_rc, _, _ = self.runcmd_unchecked("gdb --help")
        if error_rc != 0:
            raise comfychair.NotRunError ('gdb could not be found on path')

        # Test if the compiler supports --build-id=0xNNN.
        # If so, we need to use it for this test.
        # If not, try the alternative syntax -Wl,--build-id=0xNNN instead.
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

    def gdbCommands(self):
        return 'break main\nrun\nnext\n'

    def checkBuiltProgram(self):
        # On windows, the binary may be called testtmp.exe.  Check both
        if os.path.exists('link/testtmp.exe'):
            testtmp_exe = 'testtmp.exe'
        else:
            testtmp_exe = 'testtmp'

        # Run gdb and verify that it is able to correctly locate the
        # testtmp.c source file.  We write the gdb commands to a file
        # and run them via gdb --command.  (The alternative, to specify
        # the gdb commands directly on the commandline using gdb --ex,
        # is not as portable since only newer gdb's support it.)
        f = open('gdb_commands', 'w')
        f.write(self.gdbCommands())
        f.close()
        out, errs = self.runcmd("gdb -nh --batch --command=gdb_commands "
                                "link/%s </dev/null" % testtmp_exe)
        # Normally we expect the stderr output to be empty.
        # But, due to gdb bugs, some versions of gdb will produce a
        # (harmless) error or warning message.
        # In these cases, we can safely ignore the message.
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

        # Now do the same, but in a subdirectory.  This tests that the
        # "compilation directory" field of the object file is set
        # correctly.
        # If we're in pump mode, this test should only be run on ELF
        # binaries, which are the only ones we rewrite at this time.
        # If we're not in pump mode, this test should only be run
        # if gcc's preprocessing output stores the pwd (this is true
        # for gcc 4.0, but false for gcc 3.3).
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

        # Now recompile and relink the executable using ordinary
        # gcc rather than distcc; strip both executables;
        # and check that the executable generated with ordinary
        # gcc is bit-for-bit identical to the executable that was
        # generated by distcc.  This is just to double-check
        # that we didn't modify anything other than the ".debug_info"
        # section.
        self.runcmd(self.compiler() + self.build_id + " -o obj/testtmp.o -I. -c %s" %
            self.sourceFilename())
        self.runcmd(self.compiler() + self.build_id + " -o link/testtmp obj/testtmp.o")
        self.runcmd("strip link/%s && strip run/%s" % (testtmp_exe, testtmp_exe))
        # On newer versions of Linux, this works only because we pass
        # --build-id=0x12345678.
        # On OS X, the strict bit-by-bit comparison will fail, because
        # mach-o format includes a unique UUID which will differ
        # between the two testtmp binaries.  For Microsoft PE output,
        # I've seen binaries differ in two places, though I don't know
        # why (timestamp?).  We do the best we can in those cases.
        if _IsMachO('link/%s' % testtmp_exe):
            # TODO(csilvers): we can do better (make sure all 16 bytes are
            # consecutive, or even parse Mach-O to remove the UUID first).
            acceptable_diffbytes = 16
        elif _IsPE('link/%s' % testtmp_exe):
            acceptable_diffbytes = 2
        else:
            acceptable_diffbytes = 0
        rc, msgs, errs = self.runcmd_unchecked("cmp -l link/%s run/%s"
                                               % (testtmp_exe, testtmp_exe))
        if (rc != 0 and
            (errs or len(msgs.strip().splitlines()) > acceptable_diffbytes)):
            # Just do the cmp again to give a good error message
            self.runcmd("cmp link/%s run/%s" % (testtmp_exe, testtmp_exe))

class GdbOpt1_Case(Gdb_Case):
    def compiler(self):
        """Command for compiling and linking."""
        return self._cc + " -g -O1 ";

class GdbOpt2_Case(Gdb_Case):
    def compiler(self):
        """Command for compiling and linking."""
        return self._cc + " -g -O2 ";

class GdbOpt3_Case(Gdb_Case):
    def compiler(self):
        """Command for compiling and linking."""
        return self._cc + " -g -O3 ";

class GdbPrefixMap_Case(Gdb_Case):
    """Test that -fdebug-prefix-map= paths are rewritten correctly by a
    distccd running in a different directory than the client (this is
    exactly the scenario tweak_prefix_map_arguments_for_server() exists
    for)."""

    def compiler(self):
        """Command for compiling and linking."""
        # Before GCC 6, the -fdebug-prefix-map=... option was recorded in the
        # DW_AT_producer section: https://gcc.gnu.org/bugzilla/show_bug.cgi?id=69821
        # Here, use -gno-record-gcc-switches so that we do not see
        # "replaced 1 occurrences of" from dcc_fix_debug_info in distccd.log.
        # We could check this automatically, but it doesn't add much value.
        return (self._cc + " -g -fdebug-prefix-map=%s=." % os.getcwd() +
                " -gno-record-gcc-switches")

    def gdbCommands(self):
        return 'directory %s\n' % os.getcwd() + super().gdbCommands()

class CompressedCompile_Case(CompileHello_Case):
    """Test compilation with compression.

    The source needs to be moderately large to make sure compression and mmap
    is turned on."""

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

    def setupEnv(self):
        Compilation_Case.setupEnv(self)
        os.environ['DISTCC_HOSTS'] = (
            '127.0.0.1:%d,lzo' % self.server_port + _server_options)

class DashONoSpace_Case(CompileHello_Case):
    def compileCmd(self):
        return self.distcc_without_fallback() + \
               self._cc + " -otesttmp.o -c %s" % (self.sourceFilename())

    def runtest(self):
        if sys.platform == 'sunos5':
            raise comfychair.NotRunError ('Sun assembler wants space after -o')
        elif sys.platform.startswith ('osf1'):
            raise comfychair.NotRunError ('GCC mips-tfile wants space after -o')
        else:
            CompileHello_Case.runtest (self)


class WriteDevNull_Case(CompileHello_Case):
    def runtest(self):
        self.compile()

    def compileCmd(self):
        return self.distcc_without_fallback() + self._cc + \
               " -c -o /dev/null -c %s" % (self.sourceFilename())


class MultipleCompile_Case(Compilation_Case):
    """Test compiling several files from one line"""
    def setup(self):
        WithDaemon_Case.setup(self)
        open("test1.c", "w").write("const char *msg = \"hello foreigner\";")
        open("test2.c", "w").write("""#include <stdio.h>

int main(void) {
   extern const char *msg;
   puts(msg);
   return 0;
}
""")

    def runtest(self):
        self.runcmd(self.distcc()
                    + self._cc + " -c test1.c test2.c")
        self.runcmd(self.distcc()
                    + self._cc + " -o test test1.o test2.o")



class CppError_Case(CompileHello_Case):
    """Test failure of cpp"""
    def source(self):
        return '#error "not tonight dear"\n'

    def runtest(self):
        cmd = self.distcc() + self._cc + " -c testtmp.c"
        msgs, errs = self.runcmd(cmd, expectedResult=1)
        self.assert_re_search("not tonight dear", errs)
        self.assert_equal(msgs, '')


class BadInclude_Case(Compilation_Case):
    """Handling of error running cpp"""
    def source(self):
        return """#include <nosuchfilehere.h>
"""

    def runtest(self):
        if _server_options.find('cpp') != -1:
            # Annoyingly, different versions of gcc are inconsistent
            # in how they treat a non-existent #include file when
            # invoked with "-MMD": some versions treat it as an error
            # (rc 1), some as a warning (rc 0).  When distcc is
            # responsible for preprocessing (_server_options includes
            # 'cpp'), we need to figure out which our gcc does, in
            # order to verify distcc is doing the same thing.
            # FIXME(klarlund): this is arguably a bug in gcc, and it
            # is exacerbated by distcc's pump mode because we always
            # pass -MMD, even when the user didn't.  TODO(klarlund):
            # change error_rc back to 1 once that FIXME is fixed.
            error_rc, _, _ = self.runcmd_unchecked(self._cc + " -MMD -E testtmp.c")
        else:
            error_rc = 1
        self.runcmd(self.distcc() + self._cc + " -o testtmp.o -c testtmp.c",
                    error_rc)


class PreprocessPlainText_Case(Compilation_Case):
    """Try using cpp on something that's not C at all"""
    def setup(self):
        self.stripEnvironment()
        self.createSource()
        self.initCompiler()

    def source(self):
        return """#define FOO 3
#if FOO < 10
small foo!
#else
large foo!
#endif
/* comment ca? */
"""

    def runtest(self):
        # Disable the test in pump mode since the pump wrapper fails
        # before we can run distcc.
        if "cpp" in _server_options:
            raise comfychair.NotRunError('pump wrapper expects DISTCC_HOSTS')

        # -P means not to emit linemarkers
        self.runcmd(self.distcc()
                    + self._cc + " -E testtmp.c -o testtmp.out")
        out = open("testtmp.out").read()
        # It's a bit hard to know the exact value, because different versions of
        # GNU cpp seem to handle the whitespace differently.
        self.assert_re_search("small foo!", out)

    def teardown(self):
        # no daemon is run for this test
        pass


class NoDetachDaemon_Case(CompileHello_Case):
    """Test the --no-detach option."""
    def _readDaemonLog(self):
        try:
            with open(self.daemon_logfile, 'rt') as f:
                return f.read()
        except IOError as e:
            return "could not read daemon log: %s" % e

    def _collectDaemonStartupFailure(self):
        pid, status = os.waitpid(self.pid, os.WNOHANG)
        if not pid:
            return None
        if os.WIFEXITED(status):
            return os.WEXITSTATUS(status)
        return status

    def _canConnectToDaemon(self):
        # Some platforms keep a refused connection state on a socket.  Use a
        # fresh socket for each readiness probe so later daemon readiness is
        # observed correctly.
        sock = socket.socket()
        try:
            return sock.connect_ex(('127.0.0.1', self.server_port)) == 0
        finally:
            sock.close()

    def startDaemon(self):
        max_start_attempts = 5
        attempts = 0
        while attempts < max_start_attempts:
            attempts += 1
            try:
                os.remove(self.daemon_pidfile)
            except OSError as e:
                # Ignore ENOENT (pidfile already gone, expected on first iteration)
                if e.errno != errno.ENOENT:
                    raise

            # Bind to the same loopback address family that this test probes.
            cmd = (self.distccd() +
                   "--no-detach --daemon --verbose --log-file %s --pid-file %s "
                   "--port %d --listen 127.0.0.1 --allow 127.0.0.1 "
                   "--enable-tcp-insecure --sysroot %s" %
                   (_ShellSafe(self.daemon_logfile),
                    _ShellSafe(self.daemon_pidfile),
                    self.server_port,
                    _ShellSafe(self.daemon_sysroot)))
            self.pid = self.runcmd_background(cmd)

            # Wait until the server is ready for connections, while also
            # collecting early startup failures from the no-detach process.
            # The pidfile check avoids accepting an unrelated listener on the
            # same port when the daemon exits with EXIT_BIND_FAILED.
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

    def killDaemon(self):
        # Terminate the process specified by the pidfile.  That should kill
        # the distccd process, any child distccd processes and the shell
        # process used to launch distccd.
        try:
            with open(self.daemon_pidfile, 'rt') as f:
                daemon_pid = int(f.read())
        except IOError:
            try:
                os.kill(self.pid, signal.SIGTERM)
                os.waitpid(self.pid, 0)
            except OSError:
                # Process may already be gone, ignore
                pass
            return
        os.kill(daemon_pid, signal.SIGTERM)

        pid, ret = os.waitpid(self.pid, 0)
        self.assert_equal(self.pid, pid)


class AutogroupNicenessPrivilegeDrop_Case(WithDaemon_Case):
    """Root-only: negative autogroup niceness after a --user privilege drop.

    Exercises a real scenario found by automated review: distccd started
    as root with a negative --nice value and --user set to an unprivileged
    account. main()'s nice(opt_niceness) in src/daemon.c runs while still
    root and succeeds, but dcc_set_autogroup_niceness() (src/dparent.c)
    only runs much later, from dcc_detach() after setsid(), by which point
    dcc_discard_root() has already permanently dropped root/CAP_SYS_NICE.
    The kernel's proc_sched_autogroup_set_nice() rejects a negative
    autogroup nice write without that capability, so the write fails with
    EPERM: a real, currently-unfixed, non-fatal (rs_log_warning only) gap.
    This test does not fix the ordering -- see
    support-upstream/issue-077-autogroup-niceness.md for why: retaining
    CAP_SYS_NICE across the privilege drop is a nontrivial,
    security-sensitive change to src/setuid.c that hasn't been signed off
    on. This test only documents that the gap is real, is actually
    surfaced as a warning (not silently swallowed), and does not regress.

    Root and Linux are both required to observe this at all: autogroups are
    a Linux-only scheduler feature (gated by HAVE_LINUX in
    dcc_set_autogroup_niceness() itself), and only a real root-started
    distccd can exercise dcc_discard_root()'s privilege drop in the first
    place -- see the 15+-year-old TODO this replaces, above, and
    test/comfychair.py's require_root()/CheckRoot_Case for the existing
    skip-unless-root convention this follows. `make check` itself must be
    invoked as root (e.g. `sudo make check`) for this case to actually run;
    it does not shell out to sudo per-command itself.
    """

    # "nobody" is a real, always-present unprivileged Linux account -- no
    # dedicated test user needs to be created for this, unlike opt_user's
    # own default of "distcc" (which does not exist on most systems and
    # would just fall back to "nobody" anyway, see src/setuid.c's
    # dcc_preferred_user()).
    DROP_USER = "nobody"
    NICE_VALUE = -5

    def _enter_rundir(self):
        """Root the scratch directory under /tmp instead of comfychair's
        default '<checkout>/_testtmp/<class name>'.

        This test needs real root to run, so every directory it creates
        starts out root-owned; granting a dropped-privilege account
        traversal permission on those directories' ancestors (see
        _ensure_ancestors_traversable() below) would, under the checkout's
        own location, mean touching whatever the checkout happens to sit
        under -- a developer's private $HOME at mode 0700, for instance --
        which would be a persistent, unintended host-permission change
        reaching outside this test's own scratch tree. /tmp is expected to
        already be world-traversable (mode 1777) on any normal Linux distro
        or CI runner, so rooting the scratch tree there instead means the
        ancestor-traversal logic below almost never needs to touch anything
        this test doesn't itself own and remove again on cleanup.
        """
        self.basedir = os.getcwd()
        self.add_cleanup(self._restore_directory)
        self.rundir = tempfile.mkdtemp(prefix='distccd-autogroup-niceness-')
        self.tmpdir = os.path.join(self.rundir, 'tmp')
        os.makedirs(self.tmpdir)
        os.chdir(self.rundir)
        self.add_cleanup(self._remove_rundir)

    def _remove_rundir(self):
        """Cleanup for _enter_rundir()'s tempfile.mkdtemp() scratch tree.

        Cleanups run in LIFO order (test/comfychair.py's apply_cleanups()),
        so this runs before _restore_directory's chdir back to basedir --
        i.e. while the process's cwd is still (the now-deleted) rundir.
        That is harmless on Linux: unlinking a directory tree doesn't
        depend on any process's cwd being inside it, and the next cleanup
        step chdir()s via the absolute self.basedir path, not a relative
        one, so it does not depend on the old cwd resolving to anything."""
        shutil.rmtree(self.rundir, ignore_errors=True)

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
        # Deliberately calls SimpleDistCC_Case.setup(), not
        # WithDaemon_Case.setup(): the latter starts the daemon with the
        # default daemon_command() immediately, before this class's
        # overridden daemon_command() (with --user/--nice) would apply.
        SimpleDistCC_Case.setup(self)
        self.daemon_pidfile = os.path.join(os.getcwd(), "daemonpid.tmp")
        self.daemon_logfile = os.path.join(os.getcwd(), "distccd.log")
        self.daemon_sysroot = os.getcwd()
        self.server_port = DISTCC_TEST_PORT
        self.startDaemon()

    def _log_ancestor_permissions(self, path):
        """Log owner/mode of `path` and every ancestor directory, up to the
        filesystem root.

        Purely diagnostic (no side effect): opening a file requires execute
        (traversal) permission on *every* ancestor directory in its path,
        not just write permission on the immediate parent -- so a chown of
        the leaf test directory alone can still leave the daemon unable to
        reach it if some ancestor (e.g. a CI runner's own home directory,
        commonly mode 0750 and thus closed to an unrelated "other" account
        like nobody) blocks traversal. Logged unconditionally so a real
        failure here shows the actual stat data instead of requiring a
        second guess-and-rerun round trip.
        """
        p = os.path.abspath(path)
        while True:
            st = os.stat(p)
            self.log("ancestor permission check: %s uid=%d gid=%d mode=%o"
                      % (p, st.st_uid, st.st_gid, S_IMODE(st.st_mode)))
            parent = os.path.dirname(p)
            if parent == p:
                break
            p = parent

    def _restore_ancestor_modes(self, saved_modes):
        """Cleanup counterpart to _ensure_ancestors_traversable(): put back
        the exact original mode on every ancestor directory this test
        changed, so no permission change outlives the test run.

        `saved_modes` is a list of (path, original_mode) pairs, in the
        order they were changed; restored in reverse so a directory is
        never left transiently unreachable partway through (not that it
        matters much for a mode-only change, but it mirrors how the
        original chmod walk proceeded)."""
        for p, original_mode in reversed(saved_modes):
            try:
                os.chmod(p, original_mode)
                self.log("restored mode %o on %s" % (original_mode, p))
            except OSError as e:
                # Best-effort: a missing ancestor (e.g. already removed by
                # _remove_rundir()) or a permission race is not worth
                # failing the test over at cleanup time.
                self.log("could not restore mode on %s: %s" % (p, e))

    def _ensure_ancestors_traversable(self, path, uid, gid):
        """Grant `uid`/`gid` search (execute) permission on `path` and every
        ancestor directory, up to the filesystem root.

        Only adds the "other execute" bit where it is missing (a minimal
        traversal grant -- existing read/write bits, and anything else
        "other" could already do, are left untouched); does not touch
        ownership of ancestors above the test's own directories, since
        chown-ing e.g. a CI runner's home directory would reach well beyond
        what this test needs or should touch. This exists because a
        directory-level chown() (see below) is not sufficient on its own:
        Unix requires execute permission on *every* ancestor directory to
        open a file deep inside it, not just write permission on the
        immediate parent. _enter_rundir() roots this test's own directories
        under /tmp specifically so this loop normally has nothing to do
        for anything above them, but if it ever does (e.g. a nonstandard
        $TMPDIR), every change it makes is recorded and restored via a
        cleanup registered here -- this must never be a permanent host
        permission change, only a change scoped to this test run.
        """
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

    def startDaemon(self):
        """Root-only variant of WithDaemon_Case.startDaemon().

        distccd drops privileges to self.DROP_USER (dcc_discard_root())
        *before* opening its log file and writing its pidfile (src/daemon.c's
        own comment: "Discard privileges before opening log so that if it's
        created, it has the right ownership") -- but every directory here was
        just created by this test process while still root (running under
        `sudo make ... single-test`), so the dropped-privilege process can't
        write into any of them without help. Two distinct fixes are needed,
        not one: chown() the specific directories distccd actually needs to
        write into (the TMPDIR-derived working directory, and the
        comfychair-provided per-test directory holding the pidfile/log-file)
        to the drop user; and separately, grant traversal (execute)
        permission on every ancestor directory up to the filesystem root,
        since a CI runner's own home directory (this test's whole directory
        tree lives under it) is commonly mode 0750 and blocks an unrelated
        account like nobody from reaching anything under it at all, no
        matter what the leaf directories are chowned to. Same class of
        gotcha as doc/verification-checklist.md section 9's root-owned bind
        mount note, just triggered by sudo instead of a Docker mount.
        """
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
        # self.daemon_pidfile/self.daemon_logfile are absolute paths under
        # self.daemon_sysroot (the directory this test case started in,
        # before the chdir above) -- that directory is still root-owned too.
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

    def daemon_command(self):
        """Root, negative --nice, and --user together are what makes the
        privilege-drop-before-autogroup-write ordering in dparent.c
        actually observable; --log-level debug is needed to capture the
        trace/warning lines this test also checks."""
        return (self.distccd() +
                "--verbose --log-level debug --daemon --nice %d --user %s "
                "--lifetime=%d --log-file %s --pid-file %s --port %d "
                "--allow 127.0.0.1 --enable-tcp-insecure --sysroot %s"
                % (self.NICE_VALUE, self.DROP_USER, self.daemon_lifetime(),
                   _ShellSafe(self.daemon_logfile),
                   _ShellSafe(self.daemon_pidfile),
                   self.server_port,
                   _ShellSafe(self.daemon_sysroot)))

    # How long to wait for the detached child to actually reach
    # dcc_set_autogroup_niceness() before giving up. dcc_detach()'s parent
    # process exits (_exit(0)) immediately after fork(), well before the
    # child calls setsid()/dcc_set_autogroup_niceness() -- so the pidfile
    # existing (which is all startDaemon() waits for) does not mean the
    # autogroup write has happened yet. 15s is generous for a single fork
    # and a couple of syscalls even on a heavily loaded CI runner; this is
    # a wait-for-condition poll, not a fixed sleep, so it normally returns
    # in well under a second.
    AUTOGROUP_WARNING_TIMEOUT = 15

    def _waitForLogPattern(self, pattern, timeout):
        """Poll self.daemon_logfile for `pattern`, up to `timeout` seconds.

        Needed because the event being waited for (dcc_set_autogroup_niceness()
        actually running and logging its result) happens in a forked child
        well after this test's startDaemon() already returned -- a single
        one-shot read right after startDaemon() can race a slow/contended
        CI runner and either miss a warning that is logged a moment later,
        or (worse) read /proc/<pid>/autogroup before the write it's
        checking has even happened. Returns the full log content once
        `pattern` is found; fails the test with the log seen so far if the
        timeout is reached without a match.
        """
        deadline = time.time() + timeout
        log_contents = ""
        while True:
            try:
                with open(self.daemon_logfile, 'rt') as f:
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

    def runtest(self):
        pid = int(open(self.daemon_pidfile, 'rt').read())

        # Confirm the plain per-process niceness genuinely is negative --
        # i.e. main()'s nice(opt_niceness), run while still root before
        # dcc_discard_root(), really did succeed. If this were not
        # negative, the autogroup-write failure checked below would be
        # unsurprising for the wrong reason. Safe to check immediately:
        # this value is set in main(), long before dcc_detach() forks.
        actual_niceness = os.getpriority(os.PRIO_PROCESS, pid)
        self.assert_(actual_niceness < 0,
                     "expected negative process niceness for pid %d, got %d"
                     % (pid, actual_niceness))

        # Wait for the actual autogroup-write attempt to be logged before
        # reading anything else: by the time this warning is written,
        # dcc_set_autogroup_niceness()'s fopen/fprintf/fclose sequence has
        # already completed (the log call is the last thing that function
        # does), so this doubles as the synchronization point for the
        # /proc read below, not just a check on its own.
        log_contents = self._waitForLogPattern(
            r'autogroup nice -?\d+ failed: Operation not permitted',
            self.AUTOGROUP_WARNING_TIMEOUT)

        # Read /proc/<pid>/autogroup DIRECTLY, per
        # doc/verification-checklist.md's baseline item on reading real OS
        # state rather than trusting a trace/log line as sufficient
        # evidence on its own.
        with open('/proc/%d/autogroup' % pid, 'rt') as f:
            autogroup_content = f.read()
        self.log("autogroup content for pid %d: %r" % (pid, autogroup_content))
        m = re.search(r'nice (-?\d+)', autogroup_content)
        self.assert_(m is not None,
                     "could not parse /proc/%d/autogroup: %r"
                     % (pid, autogroup_content))
        autogroup_nice = int(m.group(1))

        # This is the actual, currently-accepted limitation (see
        # support-upstream/issue-077-autogroup-niceness.md): setsid()
        # (called from dcc_detach(), just before
        # dcc_set_autogroup_niceness()) always allocates a fresh autogroup
        # starting at nice 0, and the negative-nice write that would change
        # that is rejected by the kernel because CAP_SYS_NICE is already
        # gone by this point. If this assertion ever fails because the
        # autogroup shows the real negative value instead, the ordering bug
        # has been fixed and this test (and the support-upstream doc) need
        # updating to match, not silencing.
        self.assert_equal(autogroup_nice, 0)


class ImplicitCompiler_Case(CompileHello_Case):
    """Test giving no compiler works"""
    def compileCmd(self):
        return self.distcc() + "-c testtmp.c"

    def linkCmd(self):
        # FIXME: Mozilla uses something like "distcc testtmp.o -o testtmp",
        # but that's broken at the moment.
        return self.distcc() + "-o testtmp testtmp.o "

    def runtest(self):
        if sys.platform == 'hp-ux10':
            raise comfychair.NotRunError ('HP-UX bundled C compiler non-ANSI')
        # We can't run if cc is not installed on the system (maybe only gcc is)
        error_rc, _, _ = self.runcmd_unchecked("cc -c testtmp.c")
        self.runcmd_unchecked("rm -f testtmp.o")   # clean up the 'cc' output
        if error_rc != 0:
            raise comfychair.NotRunError ('Cannot find working "cc"')
        else:
            CompileHello_Case.runtest (self)


class Unicode_Case(Compilation_Case):
    """Check unicode compression works OK in include_server"""
    def source(self):
        return """
#include <stdio.h>

int main(void) {
    puts("Unicode is hard! 😭");
    return 0;
}
"""

    def checkBuiltProgramMsgs(self, msgs):
        self.assert_equal(msgs, "Unicode is hard! 😭\n")


class DashD_Case(Compilation_Case):
    """Test preprocessor arguments"""
    def source(self):
        return """
#include <stdio.h>

int main(void) {
    printf("%s\\n", MESSAGE);
    return 0;
}
"""

    def compileOpts(self):
        # quoting is hairy because this goes through the shell
        return "'-DMESSAGE=\"hello DashD\"'"

    def checkBuiltProgramMsgs(self, msgs):
        self.assert_equal(msgs, "hello DashD\n")


class EmptyDefine_Case(Compilation_Case):
    """
    This test validates that empty definitions don't break the include_server
    even when they share the same name as a real header.
    """
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

    def checkBuiltProgramMsgs(self, msgs):
        self.assert_equal(msgs, "hello world\n")



class DashMD_DashMF_DashMT_Case(CompileHello_Case):
    """Test -MD -MFfoo -MTbar"""

    def compileOpts(self):
        return "-MD -MFdotd_filename -MTtarget_name_42"

    def runtest(self):
        try:
          os.remove('dotd_filename')
        except OSError:
          pass
        self.compile();
        dotd_contents = open("dotd_filename").read()
        self.assert_re_search("target_name_42", dotd_contents)


class DashWpMD_Case(CompileHello_Case):
    """Test -Wp,-MD,depfile"""

    def compileOpts(self):
        return "-Wp,-MD,depsfile"

    def runtest(self):
        try:
          os.remove('depsfile')
        except OSError:
          pass
        self.compile()
        deps = open('depsfile').read()
        self.assert_re_search(r"testhdr\.h", deps)
        self.assert_re_search(r"stdio\.h", deps)

class ScanIncludes_Case(CompileHello_Case):
    """Test --scan-includes"""

    def createSource(self):
      CompileHello_Case.createSource(self)
      self.runcmd("mv testhdr.h test_header.h")
      self.runcmd("ln -s test_header.h testhdr.h")
      self.runcmd("mkdir test_subdir")
      self.runcmd("touch test_another_header.h")

    def headerSource(self):
        return """
#define HELLO_WORLD "hello world"
#include "test_subdir/../test_another_header.h"
"""

    def compileCmd(self):
        return self.distcc_without_fallback() + "--scan-includes " + \
               self._cc + " -o testtmp.o " + self.compileOpts() + \
               " -c %s" % (self.sourceFilename())

    def runtest(self):
        cmd = self.compileCmd()
        rc, out, err = self.runcmd_unchecked(cmd)
        log = open('distcc.log').read()
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

class ForceDirectory_Case(CompileHello_Case):
    """
    Test that the forcing_technique properly creates directories even if
    no headers are used in them (i.e. #include foo/../bar.h creates foo)

    Note that its sufficient to assert that the compile succeeds under
    pump-mode; if the technique wasn't working, it would be a compilation error
    """

    def createSource(self):
      CompileHello_Case.createSource(self)
      self.runcmd("mv testhdr.h test_header.h")
      self.runcmd("ln -s test_header.h testhdr.h")
      self.runcmd("mkdir test_subdir")
      self.runcmd("touch test_another_header.h")

    def headerSource(self):
        return """
#define HELLO_WORLD "hello world"
#include "test_subdir/../test_another_header.h"
"""

class AbsSourceFilename_Case(CompileHello_Case):
    """Test remote compilation of files with absolute names."""

    def compileCmd(self):
        return (self.distcc()
                + self._cc
                + " -c -o testtmp.o %s/testtmp.c"
                % _ShellSafe(os.getcwd()))


class HundredFold_Case(CompileHello_Case):
    """Try repeated simple compilations.

    This used to be a ThousandFold_Case -- but that slowed down testing
    significantly.  It's unclear that testing a 1000 times is much better than
    doing it a 100 times.
    """

    def daemon_lifetime(self):
        return 120

    def runtest(self):
        for unused_i in range(100):
            self.runcmd(self.distcc()
                        + self._cc + " -o testtmp.o -c testtmp.c")


class Concurrent_Case(CompileHello_Case):
    """Try many compilations at the same time"""
    def daemon_lifetime(self):
        return 120

    def runtest(self):
        # may take about a minute or so
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


class BigAssFile_Case(Compilation_Case):
    """Test compilation of a really big C file

    This will take a while to run"""
    def createSource(self):
        """Create source file"""
        f = open("testtmp.c", 'wt')

        # We want a file of many, which will be a few megabytes of
        # source.  Picking the size is kind of hard -- something that
        # will properly exercise distcc may be too big for small/old
        # machines.

        f.write("int main() {}\n")
        for i in range(200000):
            f.write("int i%06d = %d;\n" % (i, i))
        f.close()

    def runtest(self):
        self.runcmd(self.distcc() + self._cc + " -c %s" % "testtmp.c")
        self.runcmd(self.distcc() + self._cc + " -o testtmp testtmp.o")


    def daemon_lifetime(self):
        return 300



class BinFalse_Case(Compilation_Case):
    """Compiler that fails without reading input.

    This is an interesting case when the server is using fifos,
    because it has to cope with the open() on the fifo being
    interrupted.

    distcc doesn't know that 'false' is not a compiler, but it does
    need a command line that looks like a compiler invocation.

    We have to use a .i file so that distcc does not try to preprocess it.
    """
    def createSource(self):
        open("testtmp.i", "wt").write("int main() {}")

    def runtest(self):
        # On Solaris and IRIX 6, 'false' returns exit status 255
        if sys.platform == 'sunos5' or \
        sys.platform.startswith ('irix6'):
            self.runcmd(self.distcc()
                        + "false -c testtmp.i", 255)
        else:
            self.runcmd(self.distcc()
                        + "false -c testtmp.i", 1)


class BinTrue_Case(Compilation_Case):
    """Compiler that succeeds without reading input.

    This is an interesting case when the server is using fifos,
    because it has to cope with the open() on the fifo being
    interrupted.

    distcc doesn't know that 'true' is not a compiler, but it does
    need a command line that looks like a compiler invocation.

    We have to use a .i file so that distcc does not try to preprocess it.
    """
    def createSource(self):
        open("testtmp.i", "wt").write("int main() {}")

    def runtest(self):
        self.runcmd(self.distcc()
                    + "true -c testtmp.i", 0)


class SBeatsC_Case(CompileHello_Case):
    """-S overrides -c in gcc.

    If both options are given, we have to make sure we imply the
    output filename in the same way as gcc."""
    # XXX: Are other compilers the same?
    def runtest(self):
        self.runcmd(self.distcc() +
                    self._cc + " -c -S testtmp.c")
        if os.path.exists("testtmp.o"):
            self.fail("created testtmp.o but should not have")
        if not os.path.exists("testtmp.s"):
            self.fail("did not create testtmp.s but should have")


class NoServer_Case(CompileHello_Case):
    """Invalid server name"""
    def setup(self):
        self.stripEnvironment()
        os.environ['DISTCC_HOSTS'] = 'no.such.host.here' + _server_options
        self.distcc_log = 'distcc.log'
        os.environ['DISTCC_LOG'] = self.distcc_log
        self.createSource()
        self.initCompiler()

    def runtest(self):
        self.runcmd(self.distcc()
                    + self._cc + " -c -o testtmp.o testtmp.c")
        msgs = open(self.distcc_log, 'r').read()
        self.assert_re_search(r'failed to distribute.*running locally instead',
                              msgs)


class MixedServerPumpFallback_Case(CompileHello_Case):
    """
    Invalid server name with pump attributes with a fallback to a good server without

    This covers the codepath in compile.c where the first host is a remote cpp
    but fails and goto choose_host falls back to local cpp (which had a double free
    on exit up to and including v3.4)
    """
    def setup(self):
        CompileHello_Case.setup(self)
        os.environ['DISTCC_HOSTS'] = f"no.such.host.here,lzo,cpp 127.0.0.1:{self.server_port}"
        self.distcc_log = 'distcc.log'
        os.environ['DISTCC_LOG'] = self.distcc_log
        self.createSource()
        self.initCompiler()

    def runtest(self):
        self.runcmd(self.distcc()
                    + self._cc + " -c -o testtmp.o testtmp.c")
        msgs = open(self.distcc_log, 'r').read()
        self.assert_re_search(r'compile testtmp.c on 127.0.0.1:[0-9]* completed ok',
                              msgs)


class ImpliedOutput_Case(CompileHello_Case):
    """Test handling absence of -o"""
    def compileCmd(self):
        return self.distcc() + self._cc + " -c testtmp.c"


class SyntaxError_Case(Compilation_Case):
    """Test building a program containing syntax errors, so it won't build
    properly."""
    def source(self):
        return """not C source at all
"""

    def compile(self):
        rc, msgs, errs = self.runcmd_unchecked(self.compileCmd())
        self.assert_notequal(rc, 0)
        self.assert_re_search(r'testtmp.c:1:.*error', errs)
        self.assert_equal(msgs, '')

    def runtest(self):
        self.compile()

        if os.path.exists("testtmp") or os.path.exists("testtmp.o"):
            self.fail("compiler produced output, but should not have done so")


class NoHosts_Case(CompileHello_Case):
    """Test running with no hosts defined.

    We expect compilation to succeed, but with a warning that it was
    run locally."""
    def runtest(self):
        # Disable the test in pump mode since the pump wrapper fails
        # before we can run distcc.
        if "cpp" in _server_options:
            raise comfychair.NotRunError('pump wrapper expects DISTCC_HOSTS')

        # WithDaemon_Case sets this to point to the local host, but we
        # don't want that.  Note that you cannot delete environment
        # keys in Python1.5, so we need to just set them to the empty
        # string.
        os.environ['DISTCC_HOSTS'] = ''
        os.environ['DISTCC_LOG'] = ''
        self.runcmd('env')
        msgs, errs = self.runcmd(self.compileCmd())

        # We expect only one message, a warning from distcc
        self.assert_re_search(r"Warning.*\$DISTCC_HOSTS.*can't distribute work",
                              errs)

    def compileCmd(self):
        """Return command to compile source and run tests"""
        return self.distcc_with_fallback() + \
               self._cc + " -o testtmp.o -c %s" % (self.sourceFilename())



class MissingCompiler_Case(CompileHello_Case):
    """Test compiler missing from server."""
    # Another way to test this would be to break the server's PATH
    def sourceFilename(self):
        # must be preprocessed, so that we don't need to run the compiler
        # on the client
        return "testtmp.i"

    def source(self):
        return """int foo;"""

    def runtest(self):
        msgs, errs = self.runcmd(self.distcc_without_fallback()
                                 + "nosuchcc -c testtmp.i",
                                 expectedResult=EXIT_COMPILER_MISSING)
        self.assert_re_search(r'failed to exec', errs)



class RemoteAssemble_Case(WithDaemon_Case):
    """Test remote assembly of a .s file."""

    # We have a rather tricky method for testing assembly code when we
    # don't know what platform we're on.  I think this one will work
    # everywhere, though perhaps not.
    # We don't use @ because that starts comments for ARM.
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

    asm_filename = 'test2.s'

    def setup(self):
        WithDaemon_Case.setup(self)
        open(self.asm_filename, 'wt').write(self.asm_source)

    def compile(self):
        # Need to build both the C file and the assembly file
        self.runcmd(self.distcc() + self._cc + " -o test2.o -c test2.s")



class PreprocessAsm_Case(WithDaemon_Case):
    """Run preprocessor locally on assembly, then compile locally."""
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

    def setup(self):
        WithDaemon_Case.setup(self)
        open('test2.S', 'wt').write(self.asm_source)

    def compile(self):
        if sys.platform == 'linux2':
            self.runcmd(self.distcc()
                        + "-o test2.o -c test2.S")
        else:
            raise comfychair.NotRunError ('this test is system-specific')

    def runtest(self):
        self.compile()




class ModeBits_Case(CompileHello_Case):
    """Check distcc obeys umask"""
    def runtest(self):
        self.runcmd("umask 0; distcc " + self._cc + " -c testtmp.c")
        self.assert_equal(S_IMODE(os.stat("testtmp.o")[ST_MODE]), 0o666)


class CheckRoot_Case(SimpleDistCC_Case):
    """Stub case that checks this is run by root.  Not used by default."""
    def setup(self):
        self.require_root()


class EmptySource_Case(Compilation_Case):
    """Check compilation of empty source file

    It must be treated as preprocessed source, otherwise cpp will
    insert a # line, which will give a false pass.

    This test fails with an internal compiler error in GCC 3.4.x for x < 5
    (see http://gcc.gnu.org/bugzilla/show_bug.cgi?id=20239
    [3.4 Regression] ICE on empty preprocessed input).
    But that's gcc's problem, not ours, so we make this test pass
    if gcc gets an ICE."""

    def source(self):
        return ''

    def runtest(self):
        self.compile()

    def compile(self):
        rc, out, errs = self.runcmd_unchecked(self.distcc()
                    + self._cc + " -c %s" % self.sourceFilename())
        if not re.search("internal compiler error", errs):
          self.assert_equal(rc, 0)

    def sourceFilename(self):
        return "testtmp.i"

class BadLogFile_Case(CompileHello_Case):
    def runtest(self):
        self.runcmd("touch distcc.log")
        self.runcmd("chmod 0 distcc.log")
        msgs, errs = self.runcmd("DISTCC_LOG=distcc.log " + \
                                 self.distcc() + \
                                 self._cc + " -c testtmp.c", expectedResult=0)
        self.assert_re_search("failed to open logfile", errs)


class AccessDenied_Case(CompileHello_Case):
    """Run the daemon, but don't allow access from this host.

    Make sure that compilation falls back to localhost with a warning."""
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

    def compileCmd(self):
        """Return command to compile source and run tests"""
        return self.distcc_with_fallback() + \
               self._cc + " -o testtmp.o -c %s" % (self.sourceFilename())


    def runtest(self):
        self.compile()
        errs = open('distcc.log').read()
        self.assert_re_search(r'failed to distribute', errs)


class ParseMask_Case(comfychair.TestCase):
    """Test code for matching IP masks."""
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
    def runtest(self):
        for mask, client, expected in ParseMask_Case.values:
            cmd = "h_parsemask %s %s" % (mask, client)
            ret, msgs, err = self.runcmd_unchecked(cmd)
            if ret != expected:
                self.fail("%s gave %d, expected %d" % (cmd, ret, expected))


class HostFile_Case(CompileHello_Case):
    def setup(self):
        CompileHello_Case.setup(self)
        del os.environ['DISTCC_HOSTS']
        self.save_home = os.environ['HOME']
        os.environ['HOME'] = os.getcwd()
        # DISTCC_DIR is set to 'distccdir'
        open(os.environ['DISTCC_DIR'] + '/hosts', 'w').write('127.0.0.1:%d%s' %
            (self.server_port, _server_options))

    def teardown(self):
        os.environ['HOME'] = self.save_home
        CompileHello_Case.teardown(self)


class Lsdistcc_Case(WithDaemon_Case):
    """Check lsdistcc"""

    def lsdistccCmd(self):
        """Return command to run lsdistcc"""
        return "lsdistcc -r%d" % self.server_port

    def runtest(self):
        lsdistcc = self.lsdistccCmd()

        # Test "lsdistcc --help" output is reasonable.
        # (Note: "lsdistcc --help" ought to return exit status 0, really,
        # but currently it returns 1, so that's what we test for.)
        rc, out, err = self.runcmd_unchecked(lsdistcc + " --help")
        self.assert_re_search("Usage:", out)
        self.assert_equal(err, "")
        self.assert_equal(rc, 1)

        # On some systems, 127.0.0.* are all loopback addresses.
        # On other systems, only 127.0.0.1 is a loopback address.
        # The lsdistcc test is more effective if we can use 127.0.0.2 etc.
        # but that only works on some systems, so we need to check whether
        # if will work.  The ping command is not very portable, but that
        # doesn't matter; if it fails, we just won't test quite as much as
        # we would if it succeeds.  So long as it succeeds on Linux, we'll
        # get good enough test coverage.
        rc, out, err = self.runcmd_unchecked("ping -c 3 -i 0.2 -w 1 127.0.0.2")
        multiple_loopback_addrs = (rc == 0)

        # Test "lsdistcc host1 host2 host3".
        out, err = self.runcmd(lsdistcc + " localhost 127.0.0.1 127.0.0.2 "
            + " anInvalidHostname")
        out_list = out.split()
        out_list.sort()
        expected = ["%s:%d" % (host, self.server_port) for host in
                    ["127.0.0.1", "127.0.0.2", "localhost"]]
        if multiple_loopback_addrs:
          self.assert_equal(out_list, expected)
        else:
            # It may be that 127.0.0.2 isn't a loopback address, or it
            # may be that it is, but ping doesn't support -c or -i or
            # -w.  So be happy if 127.0.0.2 is there, or if it's not.
            if out_list != expected:
                del expected[1] # remove 127.0.0.2
                self.assert_equal(out_list, expected)
        self.assert_equal(err, "")

        # Test "lsdistcc host%d".
        out, err = self.runcmd(lsdistcc + " 127.0.0.%d")
        self.assert_equal(err, "")
        self.assert_re_search("127.0.0.1:%d\n" % self.server_port, out)
        if multiple_loopback_addrs:
          self.assert_re_search("127.0.0.2:%d\n" % self.server_port, out)
          self.assert_re_search("127.0.0.3:%d\n" % self.server_port, out)
          self.assert_re_search("127.0.0.4:%d\n" % self.server_port, out)
          self.assert_re_search("127.0.0.5:%d\n" % self.server_port, out)

class Getline_Case(comfychair.TestCase):
    """Test getline()."""
    values = [
        # Input, Line, Rest, Retval
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

# All the tests defined in this suite
tests = [
         CompileHello_Case,
         MarchNativeDispatcherPath_Case,
         CommaInFilename_Case,
         ComputedInclude_Case,
         BackslashInMacro_Case,
         BackslashInFilename_Case,
         CPlusPlus_Case,
         ObjectiveC_Case,
         ObjectiveCPlusPlus_Case,
         SystemIncludeDirectories_Case,
         CPlusPlus_SystemIncludeDirectories_Case,
         Gdb_Case,
         GdbOpt1_Case,
         GdbOpt2_Case,
         GdbOpt3_Case,
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
         NoDetachDaemon_Case,
         AutogroupNicenessPrivilegeDrop_Case,
         SBeatsC_Case,
         DashD_Case,
         EmptyDefine_Case,
         DashWpMD_Case,
         ScanIncludes_Case,
         ForceDirectory_Case,
         BinFalse_Case,
         BinTrue_Case,
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
         InvalidHostSpec_Case,
         ParseHostSpec_Case,
         SecureShellCommandEnvironment_Case,
         ImpliedOutput_Case,
         SyntaxError_Case,
         NoHosts_Case,
         MissingCompiler_Case,
         RemoteAssemble_Case,
         PreprocessAsm_Case,
         ModeBits_Case,
         EmptySource_Case,
         HostFile_Case,
         AbsSourceFilename_Case,
         Getline_Case,
         Unicode_Case,
         # slow tests below here
         Concurrent_Case,
         HundredFold_Case,
         BigAssFile_Case]

# On macOS, certain python installations set CPATH. distcc refuses to pump if
# it is set (src/compile.c), so unset it here so that pump tests run as expected
if "CPATH" in os.environ:
  del os.environ["CPATH"]

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

  # Some of these tests need lots of file descriptors (especially to fork),
  # but sometimes the os only supplies a few.  Try to raise that if we can.
  try:
      import resource
      (_, hard_limit) = resource.getrlimit(resource.RLIMIT_NOFILE)
      resource.setrlimit(resource.RLIMIT_NOFILE, (hard_limit, hard_limit))
  except (ImportError, ValueError):
      pass

  comfychair.main(tests)
