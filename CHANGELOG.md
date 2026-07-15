# Changelog

All notable changes to distcc-ng will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning continues distcc's own numbering (currently based on distcc 3.4),
with a `<version>-NG` suffix marking this fork's own releases — e.g. `3.5.0-NG`.
See `doc/release-versioning.md` for the full versioning and release process.

## [Unreleased]

### Added

- GitHub issue and pull request templates (`.github/pull_request_template.md`,
  `.github/ISSUE_TEMPLATE/{bug_report,feature_request}.md`). (#17)
- Regression coverage for `distccd` option-order parsing around
  `--enable-tcp-insecure` and `--inetd` (`TcpInsecureOptionOrder_Case`). (#5)
- Regression coverage isolating no-detach daemon child process waits in the
  test harness (`NoDetachDaemon_Case`). (#8)
- `doc/release-versioning.md` and `scripts/check-release-version.sh`,
  documenting the fork's manual, maintainer-driven versioning process and
  enforcing (fail-closed) that a release tag isn't reused and matches
  `configure.ac`. (#15)

### Changed

- Adopted this fork's own versioning scheme, `<version>-NG` (currently
  `3.5.0-NG`), continuing distcc's numbering rather than starting
  independently. (#15)
- Enforce LF line endings repo-wide via `.gitattributes` (`* text=auto
  eol=lf`) so Windows checkouts no longer introduce CRLF into tracked files. (#16)
- `dcc_make_tmpnam`'s temp-file name suffix widened from 32 to 64 bits
  (16 hex digits instead of 8), using the fixed-width `uint64_t` already
  read from `/dev/urandom` in full rather than truncating it. (#19)

### Fixed

- `pump`: resolve the installed include server path via Python's own
  `sysconfig` install paths instead of assuming a fixed location. (#1)
- `ssh`: preserve `DISTCC_SSH` options across Secure Shell connections. (#2)
- `strip`: drop `-iquote` from arguments sent to the remote compiler. (#3)
- `distccd`: fix `stats` pruning of old compile entries (job-limit overflow). (#4)
- `pump`: stabilize include-scan state updates (header prescan race). (#6)
- `pump`: fail closed instead of hanging when the include server stalls
  (include-server deadlock). (#7)
- `include_server/setup.py`: sanitize `DISTCC_VERSION` for PEP 440 so the
  `-NG` fork suffix (and the preexisting `unknown` fallback) no longer
  breaks the include-server build with `packaging.version.InvalidVersion`. (#18)
- `ssh`: `dcc_ssh_connect`'s `const int max_ssh_args` made `ssh_args`/
  `child_argv` technically variable-length arrays, silently accepted by GCC
  but rejected by Clang under `-Werror` — broke every macOS build. Now a
  real compile-time constant (`enum`). (fixes #20, PR #21)
- `tempfile`: `dcc_make_tmpnam` drew its name suffix from a shift-XOR mix of
  `getpid()`/`tv_usec`/`tv_sec` that collapsed to well under 32 bits of
  real entropy under concurrent load, producing 40-98% same-burst
  collision rates at realistic `-jN` distcc/distccd/pump concurrency (log
  noise, not data loss — the existing `EEXIST` retry always produced a
  unique name, just slowly and noisily). Now draws from `/dev/urandom`,
  with a guaranteed-progress fallback if that's unavailable. (fixes #12, PR #19)
- `util.c`/`stats.c`: comment-based `/* fallthrough */` suppression of
  `-Wimplicit-fallthrough` doesn't survive distcc's client-side
  preprocessing (comments are stripped before the preprocessed source is
  shipped to the compile server), so real distributed builds hit a
  genuine, reproducible remote compile failure on these two files —
  silently masked by distcc's retry-locally-on-discrepancy fallback, so
  the overall build still exited 0. Root-caused and fixed by using
  `__attribute__((fallthrough))` instead, which survives preprocessing. (fixes #22, PR #23)
- `compile`: an unchecked `readlinkat()` return value used directly as a
  negative array index in `dcc_rewrite_generic_compiler`, a potential
  stack out-of-bounds write triggerable by an `/etc/alternatives`
  TOCTOU race. (fixes #13, PR #24)
- `exec`: `dcc_execvp_cyg` (Cygwin) built its child command line with an
  unbounded `strcat` loop into a fixed 261-byte buffer, overflowing on any
  compiler invocation whose combined arguments exceeded that. Buffer is
  now sized to fit the actual arguments. (fixes #14, PR #25)
