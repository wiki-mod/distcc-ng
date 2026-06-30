#!/usr/bin/env python3

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

"""Exercise include server handler with respect to exceptions and email.

To do this, we mock out socket servers, c_extensions, email handling, and even
ultimately the notion of an AssertionError.
"""

__author__ = "Nils Klarlund"

import os
import subprocess
import sys
import tempfile
import traceback
import unittest

import basics
import cache_basics
import parse_command
import statistics
import include_analyzer_memoizing_node
import include_server
import distcc_pump_c_extensions

NotCoveredError = basics.NotCoveredError

class IncludeServerTest(unittest.TestCase):

  def setUp(self):

    statistics.StartTiming()
    basics.opt_print_statistics = False
    basics.opt_debug_pattern = 1

  def tearDown(self):
    if basics.opt_print_statistics:
      statistics.EndTiming()
      statistics.PrintStatistics(self.include_analyzer)

  def CanonicalPaths(self, dirs):
    return set([ self.canonical_path.Canonicalize(f) for f in dirs ])

  def RetrieveCanonicalPaths(self, files):
    return set([ self.include_analyzer.realpath_map.string[f] for f in files ])

  def test_IncludeHandler_handle(self):
    self_test = self
    client_root_keeper = basics.ClientRootKeeper()
    old_RCwd = distcc_pump_c_extensions.RCwd
    distcc_pump_c_extensions.RCwd = None # to be set below
    old_RCwdTimeout = distcc_pump_c_extensions.RCwdTimeout
    distcc_pump_c_extensions.RCwdTimeout = None # to be set below
    old_RArgv = distcc_pump_c_extensions.RArgv
    distcc_pump_c_extensions.RArgv = None # to be set below
    old_RArgvTimeout = distcc_pump_c_extensions.RArgvTimeout
    distcc_pump_c_extensions.RArgvTimeout = None # to be set below
    old_XArgv = distcc_pump_c_extensions.XArgv
    distcc_pump_c_extensions.XArgv = lambda _, __: None
    old_StreamRequestHandler = (
      include_server.socketserver.StreamRequestHandler)

    class Mock_StreamRequestHandler(object):
      def __init__(self):
        self.rfile = lambda: None
        self.rfile.fileno = lambda: 27
        self.wfile = lambda: None
        self.wfile.fileno = lambda: 27

    include_server.socketserver.StreamRequestHandler = (
      Mock_StreamRequestHandler)

    include_analyzer = (
        include_analyzer_memoizing_node.
            IncludeAnalyzerMemoizingNode(client_root_keeper))

    class Mock_EmailSender(object):

      def __init(self):
        self.expect = lambda: None

      def MaybeSendEmail(self, fd, force=False, never=False):
        fd.seek(0)
        text = fd.read()
        self.expect(text, force, never)
        fd.close()
        raise

    mock_email_sender = include_analyzer.email_sender = Mock_EmailSender()

    include_handler = (
      include_server.DistccIncludeHandlerGenerator(include_analyzer)())

    # Wow, that was a lot of set-up. Now exercise the include server and
    # analyzer with an emphasis on triggering exceptions.

    # Exercise 1: non-existent translation unit.

    distcc_pump_c_extensions.RArgvTimeout = (
        lambda unused_self, unused_timeout: [ "gcc", "parse.c" ])
    distcc_pump_c_extensions.RCwdTimeout = (
        lambda unused_self, unused_timeout: os.getcwd())

    def Expect1(txt, force, never):
      self_test.assertTrue(
        "Include server not covering: " +
        "Could not find translation unit 'parse.c'" in txt, txt)
      self_test.assertEqual(never, True)

    mock_email_sender.expect = Expect1
    try:
      include_handler.handle()
    except NotCoveredError:
      pass
    else:
      raise AssertionError


    # Exercise 2: provoke assertion error in cache_basics by providing an
    # entirely false value of current directory as provided in RCwd.

    distcc_pump_c_extensions.RArgvTimeout = (
        lambda unused_self, unused_timeout: [ "gcc", "parse.c" ])
    distcc_pump_c_extensions.RCwdTimeout = (
        lambda unused_self, unused_timeout: "/")
    # The cwd will be changed because of false value.
    oldcwd = os.getcwd()

    # We must distinguish between provoked and erroneous exceptions. So, we
    # mock out, in a sense, the provoked assertion exception that we
    # expect. The variable got_here allows us to filter the provoked exception
    # away from unexpected ones.
    got_here = []

    def Expect2(txt, force, never):
      got_here.append(True)
      self_test.assertTrue("Include server internal error" in txt, txt)
      self_test.assertTrue("exceptions.AssertionError" in txt, txt)
      self_test.assertTrue("for translation unit 'parse.c'" in txt, txt)

      # This email should be sent.
      self_test.assertEqual(never, False)

    mock_email_sender.expect = Expect2
    try:
      include_handler.handle()
    except AssertionError:
      os.chdir(oldcwd)
      # Make sure that we're catching the induced AssertionError, not one
      # produced in Except2.
      self.assertTrue(got_here)
    else:
      raise AssertionError

    # Exercise 3: provoke a NotCoveredError due to an absolute #include.

    distcc_pump_c_extensions.RArgvTimeout = (
        lambda unused_self, unused_timeout:
            [ "gcc", "test_data/contains_abs_include.c" ])
    distcc_pump_c_extensions.RCwdTimeout = (
        lambda unused_self, unused_timeout: os.getcwd())

    def Expect3(txt, force, never):
      self_test.assertTrue(
        "Filepath must be relative but isn't: '/love/of/my/life'."
        in txt, txt)
      # Now check that this email is scheduled to not be sent.
      self_test.assertEqual(never, True)

    mock_email_sender.expect = Expect3
    try:
      include_handler.handle()
    except NotCoveredError:
      pass

    # Exercise 4: the request timer must already be active while the handler
    # reads the request from the client.
    timer_was_active = []

    def TimedOutRCwd(unused_self, unused_timeout):
      timer_was_active.append(include_analyzer.timer is not None)
      raise distcc_pump_c_extensions.Error(
          'Timed out reading include server request.')

    def Expect4(txt, force, never):
      self_test.assertTrue('Timed out reading include server request.' in txt,
                           txt)
      self_test.assertEqual(never, False)

    mock_email_sender.expect = Expect4
    distcc_pump_c_extensions.RCwdTimeout = TimedOutRCwd
    distcc_pump_c_extensions.RArgvTimeout = (
        lambda unused_self, unused_timeout: [ "gcc", "parse.c" ])
    try:
      include_handler.handle()
    except basics.NotCoveredTimeOutError:
      pass
    self.assertEqual(timer_was_active, [True])

    distcc_pump_c_extensions.RCwd = old_RCwd
    distcc_pump_c_extensions.RCwdTimeout = old_RCwdTimeout
    distcc_pump_c_extensions.RArgv = old_RArgv
    distcc_pump_c_extensions.RArgvTimeout = old_RArgvTimeout
    distcc_pump_c_extensions.XArgv = old_XArgv
    include_server.socketserver.StreamRequestHandler = (
      old_StreamRequestHandler)

  def test_Main_reports_setup_failure_without_hanging(self):
    """A pre-ready startup failure must not leave the parent blocked."""
    missing_root = tempfile.mkdtemp()
    missing_parent = os.path.join(missing_root, 'missing-parent')
    socket_path = os.path.join(missing_parent, 'socket')
    pid_file = tempfile.NamedTemporaryFile(delete=False)
    pid_file.close()
    try:
      result = subprocess.run(
          [sys.executable, 'include_server.py',
           '--port', socket_path, '--pid_file', pid_file.name, '-d1'],
          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
          timeout=5)
      self.assertNotEqual(result.returncode, 0)
      self.assertIn('Include server: exception occurred during startup.',
                    result.stderr)
    finally:
      try:
        os.unlink(pid_file.name)
      except OSError:
        pass
      try:
        os.rmdir(missing_root)
      except OSError:
        pass

  def test_IncludeServerPortReady_timeout_stops_child(self):
    """A startup timeout must not leave the forked child running."""
    port_ready = include_server._IncludeServerPortReady()
    old_timeout = port_ready.TIMEOUT_SECONDS
    port_ready.TIMEOUT_SECONDS = 0.1
    pid = os.fork()
    if pid == 0:
      try:
        sys.exit(0 if os.read(port_ready.read_fd, 1) else 0)
      except KeyboardInterrupt:
        sys.exit(1)
    try:
      self.assertRaises(SystemExit, port_ready.Acquire, pid)
    finally:
      port_ready.TIMEOUT_SECONDS = old_timeout
      try:
        os.kill(pid, 0)
      except OSError:
        pass
      else:
        os.kill(pid, 9)
        os.waitpid(pid, 0)

unittest.main()
