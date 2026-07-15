# Changelog

All notable changes to distcc-ng will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning continues distcc's own numbering (currently based on distcc 3.4),
with a `<version>-NG` suffix marking this fork's own releases — e.g. `3.5.0-NG`.

## [Unreleased]

### Added

- GitHub issue and pull request templates (`.github/pull_request_template.md`,
  `.github/ISSUE_TEMPLATE/{bug_report,feature_request}.md`).
- Regression coverage for `distccd` option-order parsing around
  `--enable-tcp-insecure` and `--inetd` (`TcpInsecureOptionOrder_Case`).
- Regression coverage isolating no-detach daemon child process waits in the
  test harness (`NoDetachDaemon_Case`).

### Changed

- Enforce LF line endings repo-wide via `.gitattributes` (`* text=auto
  eol=lf`) so Windows checkouts no longer introduce CRLF into tracked files.

### Fixed

- `pump`: resolve the installed include server path via Python's own
  `sysconfig` install paths instead of assuming a fixed location.
- `ssh`: preserve `DISTCC_SSH` options across Secure Shell connections.
- `strip`: drop `-iquote` from arguments sent to the remote compiler.
- `distccd`: fix `stats` pruning of old compile entries (job-limit overflow).
- `pump`: stabilize include-scan state updates (header prescan race).
- `pump`: fail closed instead of hanging when the include server stalls
  (include-server deadlock).
