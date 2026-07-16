# Changelog

All notable changes to distcc-ng will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning continues distcc's own numbering (currently based on distcc 3.4),
with a `<version>-NG` suffix marking this fork's own releases — e.g. `3.5.0-NG`.
See `doc/release-versioning.md` for the full versioning and release process.

<!-- insertion marker -->

## [Unreleased]

### Security

- Fixed 10 of 11 `cpp/world-writable-file-creation` CodeQL alerts
  (`src/bulk.c`, `src/daemon.c`, `src/dparent.c`, `src/compile.c`,
  `src/dotd.c`, `src/state.c`, `src/zeroconf.c`) by replacing hardcoded
  `0666` `open()` modes with explicit least-privilege modes (`0600`, or
  `0644` for the daemon's world-readable pid file), and by switching two
  `fopen()`-based file creations (which always create at the
  umask-modified `0666` default) to `open()`+`fdopen()` with an explicit
  mode. One instance (`src/lock.c`'s lock-slot file) was deliberately left
  at `0666`, since a code comment already documents this as intentional
  support for a shared, multi-user `DISTCC_DIR`/lock directory — tightening
  it would break that deployment. (#157)
- Fixed 5 `cpp/unbounded-write` CodeQL alerts (`src/argutil.c`, `src/compile.c`,
  `src/include_server_if.c`, `src/lsdistcc.c`, `src/serve.c`) by replacing
  `strcpy`/`sprintf`/`strcat` calls with bounded equivalents (`memcpy` with an
  explicit length, `snprintf`, `strncat`) at each flagged call site. Also
  resolves the `cpp/unsafe-strcat` alert on the same `src/lsdistcc.c:891` line.
  (#145, #148)

### Fixed

- **CI: concurrency/cancel-in-progress gates** (#150): Added `concurrency:` blocks
  to all GitHub Actions workflows to prevent redundant runner-minute waste on
  superseded CI runs. Pure CI/test workflows (`c-build.yml`, `actionlint.yml`,
  `changelog-check.yml`, `release-drafter.yml`, `master-heartbeat.yml`) safely
  use `cancel-in-progress: true` to cancel older runs when a newer commit
  supersedes them. Publish-ish workflows (`nightly-publish.yml`,
  `package-release.yml`) use `cancel-in-progress: false` to queue overlapping
  triggers instead, preventing race conditions during Docker pushes and tag
  creation.
- **CI: build+test gate for real releases** (#150): Added mandatory `build_check`
  and `distributed_e2e` jobs to `package-release.yml` so tagged releases cannot
  proceed without passing the full build and e2e-validation suite first.
  Previously, a tagged commit that never passed `make check` could still be
  packaged and published. The pattern mirrors the existing gates in
  `nightly-publish.yml`.
- **code quality**: suppressed `github-code-quality[bot]` findings (unclosed files,
  bare except blocks, empty exception handlers). Fixed unclosed `open()` calls in
  `test/testdistcc.py` by wrapping them in `with` statements. Narrowed bare
  `except:` in `include_server/include_server.py` startup to `except Exception:`
  so `SystemExit` and `KeyboardInterrupt` propagate. Added explanatory comments
  to intentional exception suppressions. Narrowed `OSError` handling in pidfile
  cleanup to only suppress `ENOENT` (file already gone) and re-raise other errors.
  All changes are behavior-preserving. (#109)
- **pump mode**: unified distcc+pump host-list support (fixes #87). pump.in's
  manual-DISTCC_HOSTS code path now auto-appends `,cpp,lzo` to hosts that don't
  already specify `,cpp`, mirroring the behavior of the auto-discovery path.
  This allows a single host-list entry (e.g. `distccd-server:3632` or
  `distccd-server:3632,lzo`) to work correctly under both plain distcc
  (which gracefully falls back to client-side preprocessing if no include-server
  is running) and pump mode (which requires server-side preprocessing).
  Previously, users needed two separate entries with different formats,
  causing hard failures or silent behavior differences in real deployments. (#87)

### Added

- CI: fully automated changelog chain, replacing the earlier git-cliff-based
  approach (removes `cliff.toml`, #113/#118). `release-drafter` (#120)
  automatically maintains a draft GitHub Release, refreshed on every push to
  `current_dev` (no manual trigger, unlike `gh release create
  --generate-notes`), categorized by PR label (`security`/`fixed`/`added`/
  `documentation`) auto-assigned from the PR title via an autolabeler, with
  entries in `#N | title` format. Once a maintainer publishes that release
  (the existing manual release-cut step, unchanged), a new workflow
  (`changelog-update-on-release.yml`) inserts its notes into `CHANGELOG.md`
  via `changelog-updater-action` and commits the result via
  `git-auto-commit-action` — no manual generator run needed anymore. New
  `security` label. Note: inactive (the `update_release_draft` check stays
  red) until `current_dev` is first promoted to `master`, since
  release-drafter's config-loading is hardcoded to the default branch — not
  a bug, self-resolves on the next promotion. (fixes #120, fixes #122)
- CI: automatic failure tracking for the scheduled pipelines. A shared
  composite action (`.github/actions/nightly-status`) files or updates a single
  standing `nightly-broken` GitHub issue when the nightly publish or the weekly
  heartbeat fails — reusing the same open issue across consecutive failures
  rather than opening a new one each run — and closes it automatically on the
  next success. Wired as an `if: always()` reporting job in both workflows so
  it fires even when a gate fails and later jobs are skipped. Both pipelines
  feed the one standing issue (per this design), which self-corrects: a success
  closes it and the next real failure re-files it. (#81)
- CI: `master-heartbeat.yml` — a weekly (and manually dispatchable) heartbeat
  that builds ccache's own source (pinned to `v4.13.6`, a representative
  third-party C/C++ CMake project) fully distributed across the same
  two-container distccd/distcc harness, as a heavier real-world validation
  than the distcc-ng self-compile and independent of whether `master` changed.
  The `test/e2e/` orchestrator was generalized (`E2E_CLIENT_SCRIPT` /
  `E2E_MIN_REMOTE_JOBS`) so one proven harness drives both the nightly
  self-compile and this heartbeat. (Per-push `master` health is already covered
  by `c-build.yml`'s existing push trigger + its `distributed_e2e` job.) (#81)
- CI: `repro_issue87` job in `c-build.yml` + `test/e2e/repro-hostlist-issue87.sh`
  — an investigation-only, `continue-on-error` job reproducing (for real,
  via the existing distcc+pump e2e harness) the failure modes behind #87
  (distcc and pump currently need two different host-list entries). Added
  as a job in the already-registered `c-build.yml` rather than a new
  workflow file, since a brand-new workflow file isn't recognized by the
  Actions API until it exists on the default branch (the same structural
  limit already hit in #81). Not part of the merge gate; to be removed
  once #87's real fix lands. (#87)
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

### Security

- `distccd`: reject a client-supplied `CDIR` (current working directory,
  `dcc_r_cwd()` in `src/srvrpc.c` → `make_temp_dir_and_chdir_for_cpp()` in
  `src/serve.c`) that contains a `..` path component, before it is
  concatenated onto the server's per-job temp directory for the `chdir()`
  call. Previously unvalidated, a crafted `CDIR` (e.g., `../../etc`) could
  walk the resulting path outside that temp directory, allowing the server to
  change into (and create) arbitrary subdirectories — discovered during #100
  triage of CodeQL path-injection alerts. This closes the `CDIR` traversal
  vector; it parallels the earlier `NAME` validation fix (see #93). (fixes #100)
- `distccd`: reject a client-supplied `NAME` (`dcc_r_many_files()`,
  `src/srvrpc.c`) that isn't rooted at `/` or contains a `..` path
  component, before it is concatenated onto the server's per-job temp
  directory. Previously unvalidated (a pre-existing `FIXME` acknowledged
  the gap), a crafted `NAME` could walk the resulting path outside that
  temp directory — the location a `FILE` gets written to, or a `LINK`
  entry's own symlink gets created at — flagged by CodeQL on PR #37. This
  closes the direct-`NAME` traversal vector; it does **not** close
  traversal via a `LINK` entry's separate `link_target` (the symlink's
  target, as opposed to its own location), which is deliberately left
  unvalidated: unlike `NAME`, the include-server's own mirroring logic
  legitimately relies on a leading `..` there (see
  `_MakeLinkFromMirrorToRealLocation` in
  `include_server/compiler_defaults.py`). Fixing that needs a
  corresponding include-server change first and remains open, tracked
  separately (#95) — a malicious `link_target` could still place a
  symlink that a later, textually-clean `NAME` resolves through. New
  `h_pathsafety` unit-test binary. (fixes #93)

### Fixed

- CI: the nightly publish now stamps the container image (`VCS_REF`) and the
  release notes with the `current_dev` commit actually built, not `master`'s
  tip. Under `schedule`/`workflow_dispatch` the workflow is evaluated from the
  default branch, so `github.sha` is `master`; the job checks out `current_dev`,
  so the built commit is resolved explicitly with `git rev-parse HEAD`. For the
  same reason, `c-build.yml` no longer emits a build-provenance attestation on
  scheduled runs, where it would otherwise tie `current_dev` binaries to
  `master`'s SHA. (#81)

### Changed

- Changelog tooling: replaced `git-changelog` with `git-cliff` for better
  narrative support. Unlike `git-changelog` which only renders commit subject
  lines, `git-cliff` exposes full commit body text in its Tera template
  context — this allows changelog entries to capture the complete "why"
  narrative from squash-merge commit bodies. Configuration moved from
  `.git-changelog.toml` to `cliff.toml` (see `CLAUDE.md`'s "Changelog
  Maintenance" section for updated workflow). (fixes #106)
- `AGENTS.md`: rebasing a branch with its own unique commits now requires
  a throwaway-worktree rebase + `git range-diff` check before pushing the
  real branch, to catch silent content drift from conflict resolution —
  a clean `git rebase` exit code alone isn't proof the result is right.
  Branches that are just a stale pointer to an ancestor of the new base
  (no unique commits) update via a plain fast-forward instead, which has
  no rebase/drift risk at all. (#90)
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
