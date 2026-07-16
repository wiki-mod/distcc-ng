# Changelog

All notable changes to distcc-ng will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning continues distcc's own numbering (currently based on distcc 3.4),
with a `<version>-NG` suffix marking this fork's own releases — e.g. `3.5.0-NG`.
See `doc/release-versioning.md` for the full versioning and release process.

## [Unreleased]

### Added

- CI: `nightly-publish.yml` — a scheduled (and manually dispatchable) workflow
  that publishes a moving `nightly` channel from `current_dev`, but only after
  a full build + `make check` **and** the two-container distributed-compile
  end-to-end harness both pass (in-workflow `needs:` gate, so a failing build
  or a broken distribution path can never produce a published artifact). On
  success it builds the release packages and the container image, pushes
  `ghcr.io/wiki-mod/distcc-ng:nightly`, force-moves the single `nightly` git
  tag, and replaces the `nightly` GitHub pre-release (marked pre-release and
  never "latest"). This is a distinct, explicitly-unstable channel — it does
  not create, move, or depend on any `vX.Y.Z-NG` tag and leaves
  `package-release.yml`'s real-release path untouched. (#81)
- CI: on-demand (`workflow_dispatch`) and nightly (`schedule`) triggers for
  `c-build.yml`, so `current_dev`'s build health is checked continuously
  rather than only when a PR happens to touch it (schedule-triggered runs
  check out `current_dev`, since GitHub evaluates `schedule` only from the
  default branch). Plus a real two-container distributed-compile end-to-end
  job (`test/e2e/`): distcc-ng's own source tree is built across a distccd
  server + distcc client over a bridge network, in both plain and pump mode,
  with `DISTCC_FALLBACK=0` so a silent local fallback fails the build, and a
  distributed object is compared byte-for-byte against a local-only one.
  Distribution is independently confirmed from the server's own job log.
  Uses masquerade-whitelist mode (no `--enable-tcp-insecure`). (#32, #81)
- `AGENTS.md`/`CLAUDE.md`: repository governance and agent-workflow rules,
  adapted from wiki-mod/lancache-ng's established pattern — issue/PR
  tracking discipline, worktree-per-issue workflow, required validation
  (warnings-are-errors, real build/test verification), this fork's own
  comment-every-function convention, and release/compatibility-policy
  cross-references. (#82)
- CI: Trivy container vulnerability/secret scan on the built container
  images before they're pushed, matching wiki-mod/lancache-ng's real
  setup (severity HIGH/CRITICAL, ignore-unfixed, `.trivyignore.yaml`,
  fail-closed). (#52)
- CI: SPDX-format SBOM (Software Bill of Materials) generated for each
  built container image, uploaded as a workflow artifact. (#53)
- CI: `make`/`make check` in `c-build.yml` now build through `ccache`
  (installed via the existing package-install step), with the actual
  `ccache` object cache directory persisted across runs via
  `actions/cache` (explicit `CCACHE_DIR`, since ccache's own default
  cache location differs between Linux and macOS). (#54)
- Wire protocol version 4: optional zstd compression support alongside
  the existing LZO, plus `-gsplit-dwarf` support. Configure-time
  auto-detected (`PKG_CHECK_MODULES([ZSTD], [libzstd >= 1])`), builds
  fine without libzstd present (`AC_MSG_NOTICE([zstd support disabled])`,
  no hard dependency), per `doc/compatibility-policy.md`. Recovered and
  rebased from this fork's own prior (unmerged) `v3.4.1-zstd` release —
  originally distcc/distcc#232 by Shawn Landden. (fixes #67)

### Changed

- `doc/compatibility-policy.md`: Solaris, IRIX, HP-UX, and AIX are now
  explicitly out of scope for this fork's compatibility commitment
  (deliberate maintainer decision, not a silent narrowing) — these see no
  realistic usage today and were blocking legitimate modernization work.
  (#65)

## [3.5.1-NG] - 2026-07-16

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
- `doc/release-versioning.md`: a release is never published without a real
  `vX.Y.Z-NG` git tag behind it — no ad-hoc/manual-identifier releases,
  even from a `workflow_dispatch` test run. (#27)
- `doc/compatibility-policy.md`: this fork's explicit old-hardware/
  old-toolchain compatibility policy (prefer compiler-feature guards and
  configure-time optional detection over silently raising minimum
  requirements). (fixes #28, PR #29)
- Build-provenance attestation (`actions/attest-build-provenance`) for the
  `distcc`/`distccd` binaries built in CI. (fixes #38, PR #39)
- `.github/workflows/package-release.yml`, `scripts/build-release-packages.sh`,
  `docker/release/Dockerfile`: release automation building rpm/deb packages
  and a multi-arch (amd64 + arm64, natively via GitHub's free arm64
  public-repo runners) container image, on a real `v*` tag push or via a
  manual `workflow_dispatch` opt-in for testing. (fixes #44, PR #47)

### Changed

- Adopted this fork's own versioning scheme, `<version>-NG` (currently
  `3.5.1-NG`), continuing distcc's numbering rather than starting
  independently. (#15, #48)
- Enforce LF line endings repo-wide via `.gitattributes` (`* text=auto
  eol=lf`) so Windows checkouts no longer introduce CRLF into tracked files. (#16)
- `dcc_make_tmpnam`'s temp-file name suffix widened from 32 to 64 bits
  (16 hex digits instead of 8), using the fixed-width `uint64_t` already
  read from `/dev/urandom` in full rather than truncating it. (#19)
- CI: `actions/checkout`, `actions/upload-artifact`, `actions/download-artifact`,
  and `actions/attest-build-provenance` bumped to their latest major
  releases (were 3 majors behind on all four), dropping the now-EOL
  Node 20 runtime GitHub Actions was silently shimming them onto. (PR #47)
- `gh release create`/`gh release edit` now always pass `--latest`, so a
  real tagged release claims the "latest" slot instead of leaving a stale
  pre-fork release marked latest. (PR #47)

### Removed

- Dead `.travis.yml` (unreferenced anywhere in the repo; real CI runs on
  GitHub Actions) and `.github/FUNDING.yml` (pointed the Sponsor button at
  the upstream maintainer, not this fork). (fixes #30, PR #31)

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
- Stale upstream contact info replaced with this fork's own across all
  actively-shipped files: `INSTALL`, `README`/`README.md`, every man
  page's BUGS/SEE ALSO section, `doc/reporting-bugs.txt`,
  `include_server/setup.py`, and the RedHat packaging (`rpm.spec`,
  `init.d/distcc`) — fixes a real inconsistency where `distcc --version`'s
  bug-report string disagreed with what the man pages told users to do. (fixes #33, PR #34)
- `packaging/RedHat/rpm.spec`: `Version`/`Release` split into an RPM-safe
  numeric `Version` plus the `-NG` suffix folded into `Release` —
  rpm-version(7) forbids `-` in either field (it's the NVR separator), so
  `rpmbuild` rejected this fork's `-NG`-suffixed version outright.
  `%setup -n` corrected to match the real (hyphenated) dist-tarball
  directory name, and `update-distcc-symlinks` added to `%files` (it was
  installed but never listed, so `rpmbuild` refused to build). All three
  verified against real `rpmbuild`/CI runs, not just synthetic specs. (PR #37, #46, #47)
- `src/distcc.h`: `FALLTHROUGH`'s `__GNUC__ >= 7` check missed Clang
  (which defines `__GNUC__`, commonly as 4.x, but does support
  `__attribute__((fallthrough))` and does enforce
  `-Wimplicit-fallthrough` independently of GCC's version numbering) —
  silently regressed the #22 fix under Clang. Now checks
  `__has_attribute(fallthrough)` first. (PR #37, #46)
- `pump.in`: the SIGKILL escalation for a stuck include-server process
  only checked `ps -p PID`, which is also true for an unrelated process if
  the original pid was reused after the include server already exited.
  Now verifies the pid's command line before force-killing it. (PR #37, #46)
- `include_server/c_extensions/distcc_pump_c_extensions_module.c`:
  `ReadWithDeadline` used `select()`/`FD_SET` on an unbounded fd; `FD_SET`
  on a descriptor `>= FD_SETSIZE` writes past the `fd_set` bitmask.
  Replaced with `poll()`, which has no descriptor-number limit. (PR #37, #46)
