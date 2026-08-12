# Changelog

All notable changes to distcc-ng will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning continues distcc's own numbering (currently based on distcc 3.4),
with a `<version>-NG` suffix marking this fork's own releases — e.g. `3.5.0-NG`.
See `doc/release-versioning.md` for the full versioning and release process.

<!-- insertion marker -->

## [Unreleased]

### Fixed

- **`test/testdistcc.py`**: closed every bare `open(...).read()` and
  `open(...).write()` handle in the file, expanding issue #460 Finding 3's
  original 10 reported sites into a complete same-file sweep. Writes now
  finish before later test steps can observe their fixtures, without relying
  on CPython's prompt reference-count finalization; reads use deterministic
  ownership too. Added function-level rationale to the modified methods.

- **`include_server/parse_command.py`**: pump mode's include server can now
  see through a `ccache` wrapper (issue #442). `ParseCommandArgs()` used to
  take `args[0]` literally as "the compiler" -- fed `ccache /bin/gcc ...`,
  it set `compiler="ccache"` and then misparsed the real compiler path as
  an extra file name, raising `NotCoveredError` ("Could not locate name of
  translation unit") that surfaced to the client as "include server gave
  up analyzing" (a hard failure under `DISTCC_FALLBACK=0`). Fixed by
  skipping a leading `ccache` wrapper before treating `args[0]` as the
  compiler, mirroring how `src/arg.c`'s `dcc_scan_args()` already treats
  `ccache <cc> ...` as an ordinary, distributable command on the C client
  side. `CcacheHitThroughDistcc_Case` (`test/testdistcc.py`) now exercises
  this for real under pump mode instead of skipping. A real ccache cache
  *hit* under pump mode remains a separate, still-open gap (distccd's
  server-side cpp reconstructs the client tree under a fresh
  `mkdtemp()`'d directory on every job, varying the absolute source path
  ccache hashes on) -- not part of this fix.

- **`docker/verify/Dockerfile`**: the buildtools verification image now installs
  `openssh-server`/`openssh-client` (issue #275/#440). `SSHMode_Case`
  (`test/testdistcc.py`) already runs for real on this project's actual CI
  (`ubuntu-latest`/`macOS-latest` ship both preinstalled) -- this image was
  the one environment where it still silently `NOTRUN`-skipped, purely
  because openssh wasn't installed here, not by deliberate design. A real
  build-time self-test (start a real ephemeral `sshd`, connect with a real
  `ssh` client, run a real remote command) proves the same mechanism works
  in this image too, matching the file's existing "real functional test,
  not just `--version`" convention for every other tool.

- **`pump.in`**: two `ShutDown()` process-liveness/identity bugs (issue #401,
  split out from PR #400's review).
  - **BSD/macOS `ps` fallback could miss a genuinely alive include
    server.** `IncludeServerPidLooksRight()`'s non-`/proc` fallback called
    plain `ps -o pid,args` with no process-selection flag; on BSD/macOS
    `ps`, that silently omits a process with no controlling terminal --
    exactly how the include server is started. Confirmed live on a real
    `macOS-latest` GitHub Actions runner (not a PTY simulation): a
    backgrounded, tty-less test child was `NOTFOUND` by the bare call, but
    found by both `-A` and `-x`. Without this, a perfectly healthy include
    server could be misreported as "doesn't look right", which callers
    then read as "already gone, don't signal it" -- leaking it as an
    unreaped orphan instead of shutting it down. Fixed by trying
    `ps -A -o pid,args` first; the existing `-o pid,args`/bare `ps`
    fallbacks stay for a `ps` that rejects `-A`.
  - **The pre-SIGTERM send had no identity guard, only the SIGKILL
    escalation did.** `pump --startup`/`pump --shutdown` are two separate
    process invocations connected only by `$INCLUDE_SERVER_PID` in the
    environment, so real wall-clock time can pass in which the real
    include server exits and the OS recycles its pid for an unrelated
    process before `--shutdown` runs -- and SIGTERM is just as fatal to
    that unrelated process as SIGKILL. `IncludeServerPidLooksRight()` is
    now checked before the SIGTERM send too, not just the SIGKILL
    escalation. New regression test
    `test/pump_shutdown_pid_identity_test.py` hands `pump --shutdown` the
    pid of a real, unrelated running process and asserts it survives.
- **Packaging (issue #412)**: this fork's `.rpm`/`.deb` packages installed
  under the exact same paths as the real, independently-packaged `distcc`
  (and, on Fedora/RHEL, the separately-named `distcc-server`), guaranteeing
  a file collision on install rather than a version-skew warning --
  co-installing both was never actually possible, just silently broken.
  - `configure.ac`'s `AC_INIT` package name changed from `distcc` to
    `distcc-ng`. Binary names (`distcc`, `distccd`, `pump`) are unchanged
    -- this only renames the *package*, the same pattern as `syslog-ng`
    shipping a binary still literally called `syslog`.
    `scripts/check-release-version.sh`'s version-parsing regex updated to
    match.
  - `packaging/RedHat/rpm.spec`: added `Conflicts:`/`Obsoletes:` against
    the real `distcc` (client subpackage) and `distcc-server` (server
    subpackage, the real Fedora/RHEL name -- confirmed live via
    `dnf repoquery`) packages, alongside the existing `Provides:` lines.
    Verified live in a throwaway Fedora container, both install orders:
    `rpm -U` over an installed real `distcc` cleanly obsoletes it; a plain
    `rpm -i` of real `distcc` over an installed `distcc-ng` is correctly
    rejected.
  - `packaging/deb.sh`: `alien` does not carry `Provides`/`Conflicts`/
    `Obsoletes` from the source RPM into the generated `.deb`'s control
    file at all (confirmed by reading `Alien::Package::Deb::prep()` in
    alien's own source). Added a post-processing step patching
    `Conflicts: distcc` / `Replaces: distcc` into every `.deb` this script
    produces -- Debian's real `distcc` package is a single unified
    client+server package (confirmed live via packages.debian.org), so
    both this fork's client- and server-derived `.deb`s need to conflict
    with the same real package name, unlike the RPM side's two distinct
    names. Also found and fixed the same latent bug in this file's own
    pre-existing cleanup line while wiring this up: both it and the new
    patching loop originally tried to match generated `.deb` filenames
    by embedding `$PACKAGE`/`$VERSION` in a glob, but `alien` rewrites
    the RPM version string into Debian's own syntax (e.g. `3.7.0-NG` ->
    `3.7.0-1.NG`), so `$VERSION` never appears as a literal substring of
    the real filename -- confirmed live (a real CI dispatch of this
    script failed with `dpkg-deb: error: failed to read archive ...
    No such file or directory` before this fix). Both now match a bare
    `*.deb` instead.

- **`.github/workflows/openssf-baseline-recheck.yml`**: `check_br07()`
  (OSPS-BR-07.01, secret scanning + push protection) reads
  `repos/{repo}`'s `security_and_analysis` field, which GitHub only
  returns for a token with admin access to the repo -- `github.token`
  never qualified regardless of the job's own `permissions:` block
  (confirmed live, 2026-08-05: the field was absent, not null, from the
  response for both `github.token` and the existing
  `PROJECT_AUTOMATION_PAT`). `GHCR_PACKAGE_DELETE_PAT` now also carries
  `repo` scope for this reason; the whole script (comment posting
  included) runs as that token instead. `issues: write` dropped from the
  job's `permissions:` block since it no longer affects anything once
  `GH_TOKEN` is the PAT (issue #312).

- **`nightly-publish.yml`**: its packaging apt list was missing
  `libseccomp-dev`, which `package-release.yml`'s own list already had --
  the two had silently drifted (exactly the risk issue #362 item 6
  warns about). `libseccomp` is an optional, auto-detected dependency
  (`configure.ac`'s `--with-seccomp`, `PKG_CHECK_MODULES([SECCOMP],
  [libseccomp >= 2.4], ...)`), so the gap never failed a build -- it
  silently built nightly binaries without the seccomp sandbox instead.
  Fixed by consolidating both workflows onto one shared list (see
  `.github/actions/install-packaging-deps/`, item 6 below) that includes
  it; nightly builds now also get the seccomp sandbox. Deliberate
  behavior change, not incidental to the consolidation.

### Added

- **`test/testdistcc.py`**: real new test coverage for two more of issue
  #275's longstanding header-block `TODO`s.
  - `HostSelectionAlgorithm_Case`: direct test of `src/where.c`'s
    `dcc_lock_one()`. Read the function in full (the issue's own explicit
    prerequisite) before concluding anything: it scans slot index 0, then
    1, ..., trying every configured host in `DISTCC_HOSTS` list order at
    each index and taking the first with a free slot -- fully
    deterministic for *sequential* dispatch (concurrent dispatch under
    real load additionally depends on which process's `flock()` the
    kernel grants first, which cannot be made deterministic and this test
    doesn't attempt to cover). Starts two real `distccd` instances with
    one job slot each and a sleeping fake compiler so the first job's
    lock stays held while the second is dispatched, confirming via each
    daemon's own log which one actually served which compile.
  - `MasqueradeMode_Case`: symlinks "gcc" to the just-built `distcc`
    binary in a test-local directory, prepends that directory to `PATH`,
    and invokes "gcc" directly (no "distcc" anywhere in the command
    line). Confirmed by reading `src/climasq.c`'s
    `dcc_support_masquerade()` in full: it finds the `PATH` component
    containing the symlink actually exec'd, strips everything up to and
    including it, and re-resolves the same basename against what's left
    of `PATH` -- the real compiler is found instead of looping back into
    distcc itself.
- **`test/testdistcc.py`**: real new test coverage for seven of issue #275's
  longstanding header-block `TODO`s, rather than only re-triaging them.
  - `NoForkDaemon_Case`: recheck against a `--no-fork` daemon (the
    header-block TODO's stale "--no-prefork" name for the real flag) --
    `src/dparent.c`'s `dcc_nofork_parent()` is a genuinely different
    single-process accept loop from the normal preforked worker-pool
    model, previously never exercised by any test.
  - `BackoffFromDownedHost_Case`: lists a real-but-nothing-listening TCP
    port first and a real daemon second. Confirms `src/backoff.c`'s
    `dcc_disliked_host()` marks the down host via a timefile (checked in
    the client's own trace log), the actual cross-invocation backoff
    persistence mechanism -- distinct from the existing
    `MixedServerPumpFallback_Case`, which only covers a same-invocation
    DNS-failure fallback and never touches `backoff.c` at all.
  - The "Test path stripping" TODO removed as already resolved:
    `GdbPrefixMap_Case` already exercises `tweak_prefix_map_arguments_for_server()`
    (`src/serve.c`, landed closing issue #76) end-to-end -- a third
    instance of the same "feature landed, header comment never removed"
    pattern already found and fixed twice earlier in this same issue.
  - `IPv6Compile_Case`: a real compile over `[::1]`, both `distccd --listen`
    and the client's `[addr]:port` hostspec syntax. Both were already
    address-family-agnostic (`getaddrinfo()`/`AF_UNSPEC` in `src/srvnet.c`
    and `src/access.c`; `src/hosts.c`'s `dcc_parse_tcp_host()` already
    strips the brackets) -- this was purely an untested path, and
    `src/hosts.c`'s own top-of-file doc comment ("IPv6 literals are not
    supported yet") was stale and corrected in the same change. Skips
    cleanly if the host has no IPv6 loopback.
  - `CppFromStdin_Case`: compiles `gcc -x c -c -o testtmp.o -` with real
    source piped through stdin. `src/arg.c`'s `dcc_scan_args()` never
    recognizes a bare `-` as source (`dcc_is_source()` matches only by
    extension), so this exercises its "no visible input file" local-only
    path -- a real, deliberate fallback, not a bug, but previously
    completely untested.
  - `NonexistentSourceFile_Case`: compiles a source file that was never
    created and asserts exactly one "no such file" error is reported --
    the original TODO's concern was a local-fallback retry after the
    remote failure silently doubling the same error message.
  - `HostFileDistccDirUnset_Case`: same coverage as `HostFile_Case`, but
    with `$DISTCC_DIR` itself unset, exercising `src/tempfile.c`'s
    `dcc_get_top_dir()` `~/.distcc` fallback -- every other test always
    has `DISTCC_DIR` set via `stripEnvironment()`, so this path was never
    otherwise reached.
  - `ScanArgs_Case` gained a case for `gcc -o -output -c foo.c` (an output
    filename that itself looks like a flag) -- confirmed via `src/arg.c`'s
    `dcc_scan_args()` that a bare `-o` unconditionally takes the next argv
    as the output, so this was already handled correctly, just untested.
  - Declined, with reasoning recorded in the comment: "argument scanning
    tests should be run with various hostspecs" -- `dcc_scan_args()` takes
    only the compiler argv, never a hostspec, so the classification cannot
    vary by hostspec in the current architecture; a hostspec-varying test
    would be a structural no-op.
- **`test/testdistcc.py`**: new `SSHMode_Case` (issue #275), the last
  originally-open TODO with an existing, provably real implementation --
  `src/ssh.c`'s `dcc_ssh_connect()`/`src/hosts.c`'s `dcc_parse_ssh_host()`
  (`"@host"` SSH-mode hostspec, `DCC_MODE_SSH`) had zero test coverage
  beyond `SecureShellCommandEnvironment_Case`'s fake-`ssh`-script argv
  check, which never actually connects or runs a real `distccd`. This
  test starts a real, ephemeral, key-only, non-root `sshd` on
  `127.0.0.1` and distributes a real compile to a real
  `distccd --inetd` spawned fresh by that `sshd` for the SSH session --
  the same mechanism a real SSH-mode deployment uses. `distccd` is found
  purely via the SSH session's own `$PATH`, which a fresh non-login SSH
  session does not inherit from the test process, so `sshd_config` needs
  its own `SetEnv PATH=...` pointed at the built binaries' directory.
  Deliberately not added to any shared CI apt list: `openssh-server`/
  `openssh-client` were installed by hand on a real host for the initial
  live verification, so no new CI dependency was introduced on purpose.
  In practice the test runs for real on every GitHub Actions run anyway
  -- `sshd`/`ssh-keygen`/`ssh` are already preinstalled on the
  `ubuntu-latest`/`macOS-latest` runner images this project's CI uses,
  confirmed live (`SSHMode_Case OK` on both, real `sshd`/`ssh-keygen`
  file access independently logged by Harden Runner). It only skips
  cleanly (`NotRunError`) in environments that genuinely lack those
  tools, such as this project's own local buildtools container.
- **`test/testdistcc.py`**: `AssemblyIncludeLocalOnly_Case` and
  `ServerKilledMidJob_Case` (issue #275), the last two originally-open
  header-block `TODO`s.
  - `AssemblyIncludeLocalOnly_Case`: proves a `.s` file's `.include` is
    always resolved locally, never mis-resolved server-side.
    `src/filename.c`'s own top-of-file comment states the design ("As of
    0.10, .s and .S files are never distributed, because they might
    contain '.include' pseudo-operations"), and `dcc_is_source()`/
    `dcc_is_preprocessed()` confirm it's still true: both gate `.s`/`.S`
    recognition behind `ENABLE_REMOTE_ASSEMBLE`, a macro never defined
    anywhere in this project's build. Proven the same way
    `RecursionSafeguard_Case` proves "never touches the network":
    `DISTCC_HOSTS` points at nothing listening, `DISTCC_FALLBACK=0`, and
    the compile still succeeds.
  - `ServerKilledMidJob_Case`: kills the daemon (not the client) mid-job
    via `SIGKILL` and confirms the client falls back locally by default
    -- the mirror image of the existing `ClientDisconnectKillsServerChild_Case`.
    Deliberately built on a `--no-fork` daemon: in the default preforked
    model, the pidfile's pid is only the accept()-dispatching parent, not
    the worker process actually holding an already-accepted connection,
    so killing it wouldn't touch an in-flight job at all. Exercises a
    fallback trigger point (`dcc_compile_remote()` failing after the job
    was already dispatched) that `NoServer_Case`/`BackoffFromDownedHost_Case`
    never reach, since those only ever fail at `connect()` time. Two real
    bugs found live before this passed: using `.c` instead of an
    already-preprocessed `.i` source stalled the client's own upload for
    the fake sleeping compiler's full sleep window (`dcc_cpp_maybe()` runs
    it locally as `-E` first); the fake compiler never created any output
    file, so the local-fallback re-run left no object file behind either.
- **`.github/actions/harden-runner/`**: new composite action consolidating
  17 verbatim copies of the Harden Runner step (issue #362 item 1) across
  `c-build.yml`, `e2e-image-build.yml`, `ghcr-cleanup.yml`,
  `nightly-publish.yml`, `package-release.yml`, `verify-image-build.yml`.
  Previously thought structurally blocked (a local composite action
  requires `actions/checkout` to already have run, but Harden Runner must
  remain the job's genuinely first step) -- unblocked by GitHub's new `$/`
  self-repository `uses:` syntax (Changelog, 2026-07-30), which resolves
  with no checkout required. Verified empirically against this repo's own
  runners before rolling out (see issue #362's tracking comment for the
  live evidence). New `.github/actionlint.yaml` suppresses actionlint's
  current false positive on `$/` (not yet recognized upstream, tracked at
  rhysd/actionlint#711), scoped to only `$/`-prefixed references so a
  genuinely unpinned action elsewhere is still caught. The pinned
  `step-security/harden-runner` SHA now only needs bumping in one place
  instead of 17.
- **Harden Runner egress audit added to previously-uncovered jobs** (issue
  #361), a distinct gap from item 1 above: that item only consolidated the
  17 jobs that already had the step duplicated inline, while a systematic
  audit found 25 of 41 jobs across 14 workflow files had no Harden Runner
  step at all, including several holding real write scopes or a long-lived
  PAT. Added as the first step to: `nightly-publish.yml`'s `build_check`,
  `distributed_e2e`, `publish`, `report`; `changelog-update-on-release.yml`'s
  `update_changelog`; all three `master-heartbeat.yml` jobs; `c-build.yml`'s
  `changes`, `popt_fallback_build`, `popt_vendor_check`; `codeql.yml`'s
  `changes`; `add-to-project.yml`'s PAT-consuming job;
  `openssf-baseline-recheck.yml`'s `recheck` (now runs as
  `GHCR_PACKAGE_DELETE_PAT`, added after this issue's own table was written,
  same "consumes a real long-lived secret" criterion); and
  `e2e-image-build.yml`'s `report` (found applying the same fix already
  made to the other two `report` jobs above, per AGENTS.md rule 73's
  same-error-class sweep). Caveat 2 (whether the existing, OS-unguarded
  Harden Runner step silently no-ops or warns on `c-build.yml`'s
  `make_check (macOS-latest)` leg) resolved with a real run log: it
  installs a full macOS system extension (network filter, DNS proxy,
  process monitor) and completes with `outcome=success`, no warning --
  safe to copy the same unguarded pattern elsewhere. Deliberately excluded,
  each with its own one-line comment: `osv-scanner.yml`'s two jobs
  (`uses:`-only reusable-workflow calls, no step list to prepend to --
  caveat 1) and the remaining lint/label-only jobs across `actionlint.yml`,
  `changelog-check.yml`, `codeql.yml`'s `analyze`, `release-drafter.yml`,
  `scorecard.yml`, `clusterfuzzlite-pr.yml`, `labeler.yml` (caveat 3 --
  short-job runtime roughly doubles for a step that adds little here,
  left as an explicit maintainer decision rather than bundled in).
  `egress-policy` stays `audit` everywhere; no move to block mode.
- **`.github/actions/changed-files/`**: new composite action consolidating
  the duplicated changed-file diff computation shared by `c-build.yml`'s
  and `codeql.yml`'s own `changes` jobs (issue #362 item 2) -- the same
  event-type base-SHA selection, the `workflow_dispatch`/`schedule`
  force-all branch, and the fail-open guard for an un-diffable
  before/base SHA. Each caller keeps its own, genuinely different
  classification logic (one relevance boolean vs. three per-language
  ones, plus `codeql.yml`'s master-ruleset force-all check) layered on
  top of the shared `forced`/`changed_files` outputs. Uses the `$/`
  self-repository syntax (see the Harden Runner consolidation, issue
  #362 item 1, for the full rationale and `actionlint.yaml` suppression
  this also needs).
- **`.github/actions/ghcr-login/`**: new composite action consolidating 6
  verbatim `docker login ghcr.io` steps (issue #362 item 3) across
  `e2e-image-build.yml`, `ghcr-cleanup.yml`, `nightly-publish.yml`,
  `package-release.yml` (x2), `verify-image-build.yml`. Takes the token
  as an input rather than hardcoding `github.token`, since
  `ghcr-cleanup.yml` logs in with `GHCR_PACKAGE_DELETE_PAT` (a classic
  PAT with `delete:packages`) while every other caller uses the default
  token. Uses the `$/` self-repository syntax (see issue #362 item 1 for
  the full rationale and `actionlint.yaml` suppression this also needs).
- **`.github/actions/install-build-deps/`**, **`install-packaging-deps/`**,
  **`ccache-cache/`**: new composite actions consolidating the duplicated
  apt package lists and ccache `actions/cache` setup shared by
  `c-build.yml`, `nightly-publish.yml`, and `package-release.yml`
  (issue #362 items 6/7). `install-build-deps` takes an optional `brew`
  input so `c-build.yml`'s matrixed macOS/Linux step (which needs both
  `apt:` and `brew:` in one call) can still pass its own Homebrew list
  through unchanged.
- **`.github/actions/build-and-check/`**: new composite action
  consolidating the 5-of-7-steps-identical `build_check` job body shared
  by `nightly-publish.yml` and `package-release.yml` (issue #362 item 4)
  -- install deps, ccache + autom4te.cache setup, `autogen.sh`,
  `configure`, `make`, `make check`. Checkout (ref differs per caller)
  and Harden Runner (presence differs -- both jobs are pure local
  build/test with no GitHub API or registry write either way, so this is
  a per-caller call, not something the action should decide) stay with
  each caller. The autom4te.cache caching that only `package-release.yml`
  had is now always applied (see the `Fixed` entry for the apt-list
  asymmetry item 4 also resolves, same principle).
- **`.github/actions/distributed-e2e-test/`**: new composite action
  consolidating the identical "checkout, then run
  `test/e2e/run-e2e.sh`" job shared by `c-build.yml`,
  `nightly-publish.yml`, and `package-release.yml`'s own
  `distributed_e2e` jobs (issue #362 item 5). `master-heartbeat.yml`'s
  own `run-e2e.sh` call is deliberately not touched -- it sets
  step-level `env:` overrides (`E2E_CLIENT_SCRIPT`, `E2E_MAX_ATTEMPTS`,
  etc.) that a composite action's internal steps would not inherit.
- **`.github/workflows/ghcr-cleanup.yml`** + **`.github/scripts/ghcr-cleanup.sh`**:
  new manual (`workflow_dispatch`-only for now) cleanup for this repo's own
  GHCR container packages (`distcc-ng`, `-pump`, `-nightly`, `-buildtools`,
  `-e2e`, individually selectable or all at once). Deletes untagged
  versions beyond the 3 most recently created (kept as a rollback
  fallback -- `distcc-ng-nightly` moves a single floating `latest` tag
  daily, so each previous build becomes untagged the moment a new one
  lands; deleting all of them immediately would leave no fallback if the
  newest nightly turns out broken) and old disposable `manual-N`
  test-build tags from `package-release.yml` beyond the two most recent
  run numbers, guarded by a `dry_run` input (default `true`) that only
  lists candidates without deleting anything. Before treating a version
  as safely deletable, the
  script re-resolves every currently-tagged reference's manifest and skips
  any digest still referenced as a platform-specific child of a live
  multi-arch manifest list, rather than trusting that this repo's own
  pipeline always tags children explicitly (verified true today, but not
  re-checked here as a standing guarantee). Deleting a package version
  requires a classic PAT with `delete:packages` (the default `GITHUB_TOKEN`
  cannot do this regardless of the `packages: write` permission, same
  constraint already documented for `wiki-mod/lancache-ng`'s own
  `GHCR_PACKAGE_DELETE_PAT`); this workflow reads that same secret name,
  which must be created for this repo separately. Motivated by live GHCR
  state at the time of writing: `distcc-ng-nightly` had 21 of 22 versions
  untagged, `distcc-ng` had 26 of 91.
- **`test/testdistcc.py`**: new `ClientDisconnectKillsServerChild_Case`,
  covering two longstanding TODOs at once (both describe the same
  underlying mechanism): a client disconnecting mid-job (`src/exec.c`'s
  `dcc_collect_child()`) now has a real, direct test -- start a job with
  `sleep` as the "compiler" (distcc doesn't check argv[0] is a real
  compiler), `SIGKILL` the client mid-compile, and confirm from the
  server's own log that it noticed the disconnect and killed the
  compiler child.
- **`.github/workflows/c-build.yml`**: new opt-in `sanitizer_check` job
  (ASan/UBSan, `workflow_dispatch`/`schedule` only, never on push/PR) per
  #266's recommendation -- `ASAN_OPTIONS=detect_leaks=0` so the
  already-triaged, accepted process-lifetime allocation pattern (PR #352)
  doesn't get re-reported as noise on every run; catches new memory-safety
  and UB regressions going forward instead. Also `-fno-sanitize=alignment`:
  bundled `lzo/minilzo.c`'s own memops macros deliberately do unaligned
  loads/stores as a real, permanent optimization -- this job's first live
  run failed `CompressedCompile_Case` purely on 60 UBSan misaligned-access
  reports there, no other category, so that one check is scoped out rather
  than disabling UBSan wholesale.
- **`.github/workflows/package-release.yml`**: `publish_manifest` now also
  moves a floating `:latest` tag to each release's container images
  (`ghcr.io/wiki-mod/distcc-ng` and `-pump`), alongside the existing
  immutable `<version>-NG` tag -- only on a real tag push, never on a
  manual/`workflow_dispatch` test build. Previously no `:latest` tag
  existed for the release images at all (maintainer decision, 2026-07-30:
  this absence was itself an undiscussed choice by an earlier session, not
  an intentional policy -- `doc/release-versioning.md`'s "no release may
  ever be untagged" rule governs the GitHub Release/version tag, not
  whether an *additional* convenience pointer may also exist).
- **`AGENTS.md`**: added rule 77 -- when multiple findings share the same
  origin (the same PR review cycle, the same file, the same underlying
  mechanism), file them as one issue with clearly separated sections
  instead of splitting them across separate issues, unless they genuinely
  need independent verification environments or independent fix efforts.
  Motivated by #401 and #402 having been filed as two separate issues for
  the same `pump.in` `ShutDown()` PR #400 review cycle; #402 was folded
  back into #401 and closed.
- **`doc/release-checklist.md`**: new document gathering what must actually
  be true before a release ships, distinct from `doc/release-versioning.md`
  (the tagging/branching mechanics) and `doc/verification-checklist.md`
  (per-change-category verification). States its own founding principle up
  front: a green build proves nothing about correctness or safety -- issue
  #360's own release-artifact seccomp regression shipped silently through
  a build matrix that was green the entire time.

### Documentation

- **`test/testdistcc.py`**: second atomic pass over issue #275's remaining
  header-block `TODO`s, each checked individually against the live source
  (not sampled or trusted from a prior pass). Two fully resolved, removed:
  "Have a little compiler that takes a very long time to run... try
  interrupting the connection" (`ClientDisconnectKillsServerChild_Case`,
  landed via PR #417, already covers this exact scenario -- the comment
  was never removed at the time); "Test lzo is parsed properly"
  (`CompressedCompile_Case` already does a real functional round-trip
  compile through `,lzo`, plus `--lzo` runs the entire suite under lzo
  compression and several hostspec-parsing tests already exercise `,lzo`
  tokens). Two narrowed rather than removed, since only half of what they
  describe is actually covered: the daemon-output-redirect TODO (every
  daemon-based test already redirects to a file via `--log-file` and polls
  it with `waitForLogPattern()`, and `BadLogFile_Case` covers the failure
  case -- only the "also OK through syslogd" half remains open); the
  `DISTCC_DIR` TODO (`HostFile_Case` already covers the *set* case --
  every test's `stripEnvironment()` sets it unconditionally -- but no test
  ever exercises it *unset*). Also removed the `TMPDIR`/`DISTCC_SAVE_TEMPS`
  TODO, flagged as stale-and-removable back on 2026-07-21 but never
  actually removed until now -- caught only by going back and re-checking
  the *already-triaged* items too, not just the ones still marked open.
- **`test/testdistcc.py`**: removed three stale header-block `TODO`s
  (issue #275) confirmed already covered by current code, re-verified
  against the live source rather than trusted from an earlier pass:
  host files containing `\r` (`src/hosts.c`'s `dcc_dup_part()` calls and
  its line-reading loop already include `\r` in every delimiter set),
  compiling a 0-byte source file (`EmptySource_Case`), and dependency
  generation with `-MD` (`DashMD_DashMF_DashMT_Case`/`DashWpMD_Case`).
  The broader "-MD, -MMD, -M, etc." TODO is narrowed rather than removed
  outright: `-MMD` and bare `-M` dependency generation still have no real
  test coverage (only incidental touches -- an argument-scan
  classification test and an unrelated `error_rc` workaround test --
  neither verifies generated `.d` file contents for either flag).
- **`support-upstream/`**: retroactively added the mandatory upstream-
  relevance writeups for PRs #415-#419 (missed at the time each PR was
  opened) -- the `--lifetime` test-daemon timing fix, the `--include=`/
  `--imacros=`/`-isysroot`/`--sysroot=` server-side pump-mode rewriting
  gaps, and the `runcmd_background()` shell-exec-vs-fork hazard. All
  five confirmed present in upstream's own live source at commit
  `8d569d19`; one (the shell-exec hazard) cross-references upstream's
  own prior, narrower fix for the same root cause (PR #548).
- **`doc/verification-checklist.md`**: Section 9's rootless-Docker note
  corrected -- it previously claimed rootless Docker "was not empirically
  tested" and that "GitHub-hosted runners don't offer a rootless Docker
  daemon to test it against anyway," both since found false (#286): a real
  two-container e2e (187 remote compiles), a real `make check` parity
  check (142/16/0, `diff`-identical to the existing `--user` approach),
  and a direct GitHub Actions probe all confirm rootless Docker works,
  including on `ubuntu-latest`, with two extra `sudo`-requiring setup
  steps. Conclusion recorded: not adopted for this repo's actual CI (no
  isolation benefit worth the per-job setup cost on ephemeral,
  single-tenant runners), kept as a documented option for a future
  self-hosted runner. Also corrected the stale "138 OK" baseline citation
  to the current 142/16/0 count (test suite grew by one case, PR #406,
  since that number was first recorded).
- **`doc/verification-checklist.md`**: three further findings from real
  verification of #360/PR #408, added to Section 2 and Section 3a. (1) A
  concrete technique for a real seccomp negative test: a marker binary
  calling a denylisted syscall (`ptrace`), installed under the name the
  client actually sends server-side, not the name the user typed --
  `dcc_gcc_rewrite_fqn()` rewrites a bare `gcc` to the target triplet
  before the request is sent, so a marker at the literal typed name is
  silently never invoked. (2) How to verify a new hard dependency (e.g.
  `libseccomp`) got correctly auto-declared on a real built `.rpm`/`.deb`,
  not just detected by `configure` -- `rpm -qp --requires`/`dpkg-deb -I`
  against a real CI-built artifact, obtainable without a real tag via
  `gh workflow run package-release.yml -f publish_container=false`. (3) A
  `gh run download` gotcha when an artifact's zip contains a same-named
  file/directory collision -- fetch the raw zip via `gh api
  .../artifacts/<id>/zip` instead.
- **`doc/verification-checklist.md`**: three findings from real cross-
  container verification of #287/PR #406 and #286/PR #405, added to
  Section 3a and Section 9. (1) The daemon's compiler-name whitelist
  rejects an absolute/directory-qualified compiler name before
  `dcc_execvp()`'s own fallback is ever reached, unless
  `--enable-tcp-insecure`/`DISTCC_CMDLIST` is set -- a change touching
  `dcc_execvp()` needs both configurations tested, not just one. (2) A
  reusable real two-container technique for compiler-identity bugs: a
  same-named "marker" substitute compiler placed earlier on the
  *server's* own `$PATH`, verified via the server's own log plus a
  sentinel file, not the client's exit code alone. (3) `make check`'s
  `maintainer-check-no-set-path` re-run can fail with `distccd: not
  found` on some Docker hosts (confirmed reproducing identically on a
  clean `current_dev` checkout, not caused by either PR, and not
  reproducing in this repo's own GitHub Actions `make_check` job) --
  root cause not determined, documented as a known, unresolved
  host-specific quirk rather than a code defect.
- **`README.md`**: added a "Quick start (Docker)" section -- previously had
  zero mention of the published GHCR images at all, despite this fork
  publishing three separate images (`distcc-ng`, `distcc-ng-pump`,
  `distcc-ng-nightly`). References the real `:latest` tag added to the
  release images by #389.
- **`doc/docker.md`**: updated its release-image pull examples for #389's
  new `:latest` tag on `distcc-ng`/`distcc-ng-pump` (current stable
  release), alongside the existing immutable `<version>-NG` tags.
- **`doc/verification-checklist.md`**: new Section 9 entry documenting a
  real `distccd`-side bug found evaluating Alpine support (#398):
  `src/fix_debug_info.c`'s `dcc_fix_debug_info()` does a raw byte
  search-and-replace on ELF debug sections to rewrite the server-side
  compilation directory back to the client-side path, assuming the
  path string is still present byte-for-byte in the section's raw,
  uncompressed bytes -- not that the section itself is plain text
  (`.debug_info`/`.debug_line_str` are structured binary DWARF data
  even uncompressed; the search-and-replace deliberately scans that
  binary buffer without parsing it). On a real, current `alpine:latest`
  (3.24.1, `gcc (Alpine) 15.2.0`), `.debug_line_str` gets the
  `SHF_COMPRESSED` flag set once the baked-in compilation-directory
  string is long enough to cross a compression-worthwhile size threshold
  -- confirmed via `gcc -### -gz -g -c <file>` (a real source file is
  required for this trace) that GCC dispatches this to
  `as --compress-debug-sections=zlib`, i.e. the assembler decides and
  performs the compression, not gcc itself. Confirmed size-dependent -- a
  short test path can misleadingly appear fine, while a realistic
  distccd compile-working-directory path (formed by
  `make_temp_dir_and_chdir_for_cpp()` in `src/serve.c`, not
  `dcc_make_tmpnam()`, which only names individual files) reliably
  triggers it. The search string is genuine plain text once decompressed,
  but never appears in the section's raw compressed bytes, so the rewrite
  finds zero occurrences -- non-fatal and traced (`rs_trace()` logs it
  under `distccd --verbose`), not silent -- and
  `Gdb_Case`/`GdbOpt1-3_Case` fail in pump mode on Alpine as a result. A
  real, current Debian 13 container (a different gcc version on a
  different distro/container, not a controlled same-compiler comparison;
  Debian's own repos, including trixie-backports, top out at gcc-14 --
  no gcc-15 package exists there as of this writing) produces
  uncompressed debug sections at the same path lengths instead --
  `-gz=none` on the same Alpine gcc also removes the compression flag,
  but this only shows the assembler flag controls compression, not that
  the GCC version specifically is the cause (not tested with matched GCC
  versions across platforms); described as toolchain/distro-configuration
  -dependent rather than attributed to a specific cause. Not yet fixed as
  of this entry -- documented so the finding isn't rediscovered from
  scratch; see #398 for the full analysis and fix-direction discussion.

### Security

- **`.github/workflows/verify-image-build.yml`**: the "Real distcc-ng
  build+test inside the image" and "ccache + Redis remote-storage
  self-test" steps no longer run any part of `docker/verify`-based
  verification as root (#286). Previously both ran the actual build+test
  as container root, `chown -R`'d the bind-mounted checkout to the
  image's non-root `verify` user, then dropped to that user via `su` --
  a real, working fix (#264) for a uid mismatch between the runner's
  checkout and the image's baked-in user, but root access was never
  actually required for the mismatch itself. Replaced with
  `docker run --user "$(id -u):$(id -g)"` plus an explicit
  container-internal `-e HOME=...` -- no root, no `chown`, no `su`,
  anywhere in this workflow. Confirmed via three real CI runs (baseline
  root+chown+su vs. a build-arg-uid-match alternative vs. this `--user`
  approach) that all three produce identical results (138 OK, 16 NOTRUN,
  0 FAIL, byte-identical NOTRUN sets including root-gated tests like
  `Unicode_Case` correctly still skipping); `--user` was chosen over the
  build-arg alternative because it needs no image rebuild and works
  directly against the already-published `distcc-ng-buildtools:latest`
  image. `doc/verification-checklist.md` section 9 and `CONTRIBUTING.md`
  updated to describe the new pattern and its real `HOME` requirement
  (an early attempt pointed `HOME` at a host path never bind-mounted
  into the container, producing a real `ccache: error: Permission
  denied` -- fixed by using a container-internal path instead).
- **`docker/release/Dockerfile`** and **`.github/workflows/package-release.yml`**:
  every real, published `distccd` artifact -- the `distcc-ng`/`distcc-ng-pump`/
  `distcc-ng-nightly` container images and the `.rpm`/`.deb` packages built by
  the release workflow -- previously built with `HAVE_SECCOMP` never defined,
  so the seccomp sandbox for remote compiler processes (`src/sandbox-seccomp.c`)
  compiled out entirely and the daemon logged a warning about it on every
  startup (#360). Neither `docker/release/Dockerfile`'s build stage nor
  `package-release.yml`'s own `apt` dependency list ever installed
  `libseccomp-dev` -- confirmed by a real before/after build+run comparison
  (baseline logs `Warning: built without libseccomp support...`, fixed build
  logs `seccomp sandbox enabled for remote compiler processes`) and a real
  compile through the fixed image. Swept for the same gap across every other
  release-relevant file per AGENTS.md rule 73: `docker/verify/Dockerfile`,
  `test/e2e/Dockerfile`, and `test/e2e-full/Dockerfile` already had
  `libseccomp-dev`; `package-release.yml`'s `apt` list (used to build the real
  `.rpm`/`.deb` release packages via `scripts/build-release-packages.sh`) did
  not and is fixed in the same change.

### Fixed

- **`.github/workflows/codeql.yml`**: master's branch ruleset has a native
  "Require code scanning results" rule (`code_scanning_tools: CodeQL,
  alerts_threshold: all`), a second, independent mechanism from the
  `required_status_checks` list that already required the three
  `Analyze (c-cpp/python/actions)` check-runs to exist. This job's
  per-language path filter (added for #267/#336's own reason -- avoid a
  full C build + scan on doc/workflow-only diffs) satisfies the check-run
  requirement with a green skip, but a skipped language never calls
  `codeql-action/analyze`, so it never uploads a SARIF result either --
  which the native rule treats as unsatisfied regardless of the
  check-run's own conclusion, blocking merge with "Code scanning is still
  expecting N results from CodeQL". Confirmed live on PR #426 (a
  `.github/workflows` + `CHANGELOG.md`-only diff against master):
  permanently merge-blocked this way even with all three `Analyze` checks
  green. Fixed by forcing all three languages relevant whenever the
  target branch is `master`, regardless of what actually changed --
  `current_dev` has no such ruleset rule and keeps the real path-filtered
  optimization.
- **`scripts/check-pr-tracking-metadata.sh`**: the project-board GraphQL
  query (and the response-count check just below it) built a `python3 -c`
  program by interpolating shell values straight into the Python source
  text, with `pr_number`/`project_number` landing as bare literals rather
  than string literals -- a non-numeric value produced a Python
  `SyntaxError` instead of a clear error, and in the worst case a crafted
  value would execute as Python. `pr_number` comes from `PR_NUMBER`,
  which was only ever checked for presence (`:?`), never for shape.
  Fixed both instances by passing `project_owner`/`pr_number`/`repo_name`/
  `project_number` through the environment and reading them via
  `os.environ` inside the Python program instead, which removes the
  interpolation entirely, and added an explicit `PR_NUMBER`
  positive-integer validation alongside the existing `:?` presence check
  so a bad value now fails with a readable `::error::` message naming the
  variable. Severity is low: `changelog-check.yml`'s `workflow_dispatch`
  input can set an arbitrary-string `PR_NUMBER` for the `require_changelog`
  job in the same file, but (verified while fixing this) the
  `pr_tracking_metadata` job that actually runs this script is gated to
  `pull_request` events only and always sources `PR_NUMBER` from
  `github.event.pull_request.number`, which is always an integer -- so
  this is a hardening fix for a latent footgun and a defense against a
  future workflow change, not a live path today. (#364)
- **`.github/workflows/package-release.yml`**: `publish_manifest` derived the
  digest-artifact pattern it downloads from its own `github.run_attempt`,
  while `build_container` (a different job) uploaded using ITS OWN
  `github.run_attempt`. On a real "Re-run failed jobs" -- where
  `build_container` already succeeded and is therefore not re-run, but
  `run_attempt` still increments for the jobs that are -- the two numbers
  diverged and `publish_manifest` could never find the artifacts again,
  making a real tagged release's manifest step permanently unrecoverable via
  the normal retry path. Same error class as PR #354's `7207b01` fix for
  `e2e-image-build.yml`; found by extending that sweep to the rest of the
  repository (#363). Fix: the attempt number is now resolved once, as a job
  output of the existing non-matrixed `setup` job (already a `needs:` of
  both `build_container` and `publish_manifest`), and both producer and
  consumer read `needs.setup.outputs.run_attempt` instead of re-evaluating
  `github.run_attempt` in their own job context. Confirmed empirically
  (scratch probe, PR #423, closed unmerged) that a not-re-run job's outputs
  do survive into a later attempt via the `needs` context -- see the code
  comment on `setup`'s `run_attempt` output for the real run URL and log
  evidence, which resolves the same open question PR #354 had left
  unverified.
- **`.github/scripts/openssf-baseline-recheck.sh`**: `check_br01()` flagged
  OSPS-BR-01 as NotMet on two real false positives -- any `pull_request_target`
  trigger at all (even `labeler.yml`/`add-to-project.yml`, which never check
  out or run anything from the fork, so carry none of the real risk), and a
  pure explanatory comment in `changelog-check.yml` that only mentions
  `github.event.pull_request.title`, never actually interpolates it. Now only
  counts `pull_request_target` as risky when the same file also references
  the PR's own head ref/sha (the actual dangerous combination), and strips
  whole-line comments before searching for real interpolation. Re-verified
  live against this repo's actual state (2026-08-05): now correctly reports
  Met, and a constructed genuinely-risky pattern still correctly reports
  NotMet.
- **`src/serve.c`**: `-isysroot`/`--sysroot=` had no entry at all in
  `tweak_include_arguments_for_server()`'s `include_options[]` -- the
  include server already accounts for a client sysroot when deciding
  which absolute system-include directories to mirror to the server, so
  header content landed in the right place, but the compile command
  sent to the server still named the client's own un-mirrored absolute
  sysroot path, so the server compiler looked for headers there instead
  of where they actually got mirrored to. Found via the same sweep that
  found `--imacros=`'s gap, after fixing `--include=` (#416).
- **`src/serve.c`, `include_server/parse_command.py`**: `--imacros=/path`
  (GCC/Clang's combined form of `-imacros`) had the exact same gap just
  fixed for `--include=` -- missing from both `tweak_include_arguments_
  for_server()`'s `include_options[]` and `parse_command.py`'s
  `CPP_OPTIONS_APPEARING_AS_ASSIGNMENTS`. Found via a deliberate sweep
  for the same bug pattern elsewhere after fixing `--include=` (#416).
- **`src/serve.c`, `include_server/parse_command.py`**: `--include=/path`
  (GCC/Clang's combined-form force-include flag) was not recognized by
  either the server-side argument rewriter (`tweak_include_arguments_for_
  server()`'s `include_options[]` had `-include` but not `--include=`) or
  the include server's own option parser (`CPP_OPTIONS_APPEARING_AS_
  ASSIGNMENTS` had `--sysroot` but not `--include`) -- so a header pulled
  in only via `--include=/absolute/client/path` was never mirrored to the
  server and its path was never rewritten to the server's root_dir in pump
  mode, causing a real "file not found" server-side. Found compiling a
  real `-sys` crate (`aws-lc-sys`/BoringSSL) through pump mode.
- **`test/testdistcc.py`**: `daemon_lifetime()` (default 60s, up to 300s for
  `BigAssFile_Case`) is a hard `alarm()`-based cutoff that kills the test
  daemon once it expires, regardless of whether a test is still using it --
  a slow/loaded CI runner could outrun it, killing the daemon mid-test
  before `killDaemon()`'s own `SIGTERM` teardown got a chance to run
  (#379). Since `killDaemon()` already reliably tears the daemon down via
  `SIGTERM` at the end of every test, the alarm is only meant as a
  leak-safety net for the abnormal case where teardown itself never runs --
  raised 5x across the board (60s/120s/300s -> 300s/600s/1500s) so it no
  longer races a normal, still-running test.
- **`test/e2e-full/docker-compose.yml`**: added `init: true` to both
  `ng-node` and `native-node` services -- neither declared a real init, so
  PID 1 was `sleep infinity`, which never reaps a reparented child.
  `run-bidirectional-e2e.sh` starts and `pkill`s `distccd` in place, once
  per leg, inside the same long-lived container across all four legs
  (direction A/B x plain/pump) -- the same gotcha `doc/verification-
  checklist.md` section 9 already documents (originally fixed for
  `verify-image-build.yml` via PR #375/#377, but this file predates that
  sweep by a week and was never checked afterward). Confirmed live running
  the harness's real Samba workload: 4 `[distccd] <defunct>` zombies per
  container without the fix, 0 with it (#264, #413).
- **`test/e2e-full/run-bidirectional-e2e.sh`**: `DAEMON_JOBS` default
  changed from a hardcoded `4` to `$(nproc)`, matching the variable's own
  doc comment ("distccd --jobs value (default: nproc)"), which the code
  never actually implemented -- was silently capping the server side below
  the client's own `$(nproc)`-scoped build parallelism (#264, #413).
- **`pump.in`**: `IncludeServerAlive()` used `ps -p PID` as its liveness
  check, which BusyBox's `ps` (Alpine's default `/bin/sh` userland) does
  not implement at all -- always failing, so `ShutDown()` never sent the
  include server SIGTERM on any BusyBox-based system. The include server
  (resident by design) then ran forever as an orphan, holding open
  whatever stdout/stderr it inherited, hanging any caller reading
  `pump`'s output through a pipe. Replaced with `kill -0` (POSIX-standard,
  no `ps` dependency); the SIGKILL-escalation's PID-recycling safety check
  now reads `/proc/$pid/cmdline` directly on Linux instead of `ps -p ...
  -o args=`, falling back to the previous `ps`-based check on non-Linux
  platforms. Found and verified via a real Alpine 3.20 vs. Debian 13
  container comparison (#398). Two further BusyBox-specific gaps in the
  same code path were found and fixed in the same change: (1) the zombie
  check in `IncludeServerAlive()` used `ps -o state= -p`, which BusyBox
  also rejects outright, so a zombied include server was misreported
  alive for the full SIGTERM/SIGKILL wait timeouts -- fixed by reading
  the state character from `/proc/$pid/stat` directly (a new `ProcState()`
  helper) whenever `/proc` is available; (2) `IncludeServerPidLooksRight()`'s
  non-`/proc` fallback still called `ps -p ... -o args=`, reintroducing the
  same BusyBox-incompatible pattern -- replaced with `ps -o pid,args` (no
  `-p`, which BusyBox still rejects) to force full-argv output (needed
  since the include server's short command name is just its interpreter,
  e.g. `python3`, not `include_server`), falling back to plain unadorned
  `ps` only if `-o` itself isn't supported (e.g. Cygwin), grepped for the
  pid as the leading field; a zero-data-row result from either form is
  treated as "no identity information available" rather than a genuine
  rejection, to avoid recreating the original leak on a truly procfs-less
  system. All reproduced and verified against real Alpine 3.20/BusyBox and
  Debian 13/GNU-procps containers: a deterministically-created zombie
  process, a fake include_server-named process to exercise the ps-fallback
  identity check, a genuinely procfs-less environment (`umount /proc`),
  and a real python3 process whose comm name lacks "include_server" while
  its argv contains it.
- **`test/testdistcc.py`**: `MarchNativeDispatcherPath_Case` read the daemon
  log for a `COMPILE_OK` line exactly once, right after the compile
  subprocess exited -- an intermittent CI failure (#300) showed this can
  race the daemon's own log write for that same compile. Replaced with a
  new shared `WithDaemon_Case.waitForLogPattern()` poll helper (moved out
  of `AutogroupNicenessPrivilegeDrop_Case`'s previously-private copy, no
  behavior change there), bounded at 5s. Verified with 10 consecutive runs
  of the affected test, all green.
- **`.github/workflows/c-build.yml`**: the coverage job's job-summary step
  still called `lcov --list` with the deprecated `lcov_branch_coverage` RC
  name, missed when the job's other three `lcov` invocations were already
  switched to `branch_coverage` -- every relevant coverage run was emitting
  a deprecation warning here.
- **`docker/verify/Dockerfile`**: the `actionlint-builder` stage's `RUN set
  -euo pipefail; ...` had no `SHELL` override, so it executed via Docker's
  default `/bin/sh` -- dash on this Debian-based `golang:latest` image,
  which rejects the bash-only `-o pipefail` and failed the entire stage.
  There is no pipe in that command, so switched to `set -eu` (POSIX,
  dash-compatible) instead of adding a `SHELL` directive. This meant the
  `distcc-ng-buildtools` image could not be rebuilt from scratch at all.
- **`.github/workflows/verify-image-build.yml`**: its own `make check`
  invocation used the same `su`/`bash` PID-1 pattern documented in
  `doc/verification-checklist.md` (PR #375) without `--init` -- `distccd
  --daemon`'s `dcc_detach()` reparents each killed daemon to PID 1, `su`
  never reaps it, and `test/testdistcc.py`'s own teardown poll
  (`os.kill(pid, 0)` after `SIGTERM`, since it can't `wait()` a detached
  daemon) can then spin forever with nothing to reap the zombie -- a real,
  silent hang in this recurring CI job, not just an ad-hoc local run.
  Added `--init` so a real init (`tini`) reaps those zombies.

- **`.github/workflows/e2e-image-build.yml`**: `report`'s eligibility now
  derives directly from `github.event_name`/`github.ref` instead of
  `build_and_selftest`'s `publish_eligible` job output, so a run that fails
  before that output is ever produced (Harden Runner, checkout, identity
  resolution) still reaches `report` instead of being silently skipped.
  `publish` now also checks build recency before moving the `:latest` tag:
  it reads the currently-published `:latest` version's own paired immutable
  `SHA-DATE-RUN_ID-RUN_ATTEMPT` tag(s) from the GHCR package API, and
  compares the *built commit* against that published commit via real commit
  ancestry on `current_dev` (not `github.run_id` ordering alone -- a
  scheduled run's checkout resolves to `current_dev`'s tip at execution
  time, not at trigger time, so a run created earlier can still end up
  building a genuinely newer commit than a later-triggered run finished
  first). `(run_id, run_attempt)` is used only to break a tie between two
  builds of the identical commit, since the base image and apt sources are
  both deliberately mutable and two builds of the same commit are not
  guaranteed byte-identical. A genuine GHCR lookup failure (anything other
  than a real 404 for a never-yet-published package) fails the step
  outright rather than defaulting to "no prior publish". The immutable
  per-run tag is still pushed unconditionally either way. The published
  tag's SHA is now resolved and validated as its own statement before any
  comparison runs, instead of directly inside an `elif` condition -- inside
  an `if`/`elif` test, a failing command is exempt from `set -e`, so an
  unresolvable published SHA (e.g. an ambiguous short prefix once history
  grows) previously fell through silently as "not newer" and left `:latest`
  stale instead of failing loudly; the same fix applies to the
  `git merge-base --is-ancestor` call, whose exit status is now checked
  explicitly so a real error is distinguished from a genuine "not an
  ancestor" result.

- **`.github/labeler.yml`**: the `documentation` label matched `**/*.md`,
  which included `CHANGELOG.md` -- since almost every PR touches that
  file (`changelog-check.yml`'s own requirement), `documentation` was
  firing on nearly every PR regardless of what it actually changed.
  Excluded `CHANGELOG.md` explicitly (without suppressing the label for a
  genuine documentation PR that also updates its `CHANGELOG.md` entry, the
  routine case); `doc/**` and other real `.md` files (README, etc.) are
  unaffected.

- **`src/cleanup.c`**: `dcc_add_cleanup()`'s first call passed a `NULL`
  source pointer to `memcpy()` at a zero length -- technically undefined
  behavior (libc declares `memcpy()`'s source parameter `nonnull`), flagged
  by UBSan on the first cleanup registration in any real compile or daemon
  session (not simple early-exit invocations like `--version`/`--help`,
  which never reach this code path) (#266). Harmless in
  practice (a zero-length copy never dereferences anything), but now
  skipped outright when `cleanups_size == 0` rather than relying on that.

### Added

- **`doc/verification-checklist.md`**: new Section 9 entry documenting a
  container-based `make check` hang caused by zombie accumulation, not a
  distcc-ng code bug -- `distccd --daemon`'s `dcc_detach()`
  (`src/dparent.c`) correctly daemonizes via `fork()` + immediate parent
  `_exit(0)` + `setsid()` (the standard, intentional Unix daemon pattern,
  borrowed from rsync), which reparents it to whatever process is PID 1.
  A `su`-based non-root drop (the pattern this same section's other two
  entries use) makes `su` that PID 1, and `su` never reaps a reparented
  zombie -- `test/testdistcc.py`'s `WithDaemon_Case.killDaemon()` can't
  `wait()` a detached daemon, so it sends `SIGTERM` and polls
  `os.kill(pid, 0)` in a loop until that raises `ESRCH`; a zombie still
  has a live PID entry, so the poll keeps succeeding and the loop spins
  forever with nothing to reap it: a real, silent hang (near-zero CPU, no
  error output) indistinguishable from a slow test. Fix is `--init` on
  the `docker run` invocation (real `tini`
  as PID 1); confirmed live cutting the 3.6.3-NG release (killed the
  hung run, reproduced the zombie tree via `ps auxf`, re-ran clean).
  Section 8 also gained a matching cleanup check for `<defunct>`
  entries.

- **`src/util.c`**: added real `assert()` invariant checks to `str_endswith()`,
  `str_startswith()`, and `argv_contains()` -- each already implicitly assumed
  its pointer arguments were non-NULL (an unguarded `strlen()`/`strcmp()` on a
  NULL argument was already undefined behavior), so this converts an
  undiagnosable crash into a clear, attributable assertion failure rather than
  changing behavior for any correct caller. Motivated by the OpenSSF Best
  Practices Badge `dynamic_analysis_enable_assertions` criterion; the codebase
  already used `assert()` elsewhere (e.g. `src/compile.c:135`, `src/arg.c:869`,
  `src/fix_debug_info.c:245`), so this adds coverage to these three specific
  string/argv helpers rather than introducing the technique from scratch.
  Verified with a real `make check` run (all cases OK/expected-NOTRUN, no new
  failures).

- **`.github/workflows/c-build.yml`**: new `coverage` job builds the real test
  suite with gcov instrumentation (`--coverage -O0`), captures statement/branch
  C coverage via `lcov` (excluding vendored `lzo/` and the `check_PROGRAMS`
  C test drivers, `src/h_*.c`), separately captures Python coverage for
  `include_server/*.py` (a real, substantial production component, not a
  peripheral tool -- excluding it would understate what "most of the code"
  actually covers) via a coverage-recording `PYTHON` wrapper script generated
  at job runtime (a real single-token executable, since Makefile.in passes
  `$(PYTHON)` as one token to code that forwards it straight to `subprocess`
  as an executable name -- a multiword override fails outright), and publishes
  both reports without any third-party service: a table in the job summary
  (`$GITHUB_STEP_SUMMARY`) plus the full `coverage.info`/`coverage-python.xml`
  as a `coverage-reports` build artifact. GitHub's own native "Code Quality"
  coverage feature was checked and ruled out -- it requires GitHub
  Enterprise Cloud/Team, not available on this org's Free plan (confirmed
  via `gh api orgs/<org>`). Codecov was tried first (tokenless upload for a
  public repo) but rejected outright by Codecov itself
  (`"Token required - not valid tokenless upload"`) and, independent of
  that, is not something to route third-party coverage data through
  without deliberate opt-in -- reverted in favor of the GitHub-native
  approach above. Also reruns `AutogroupNicenessPrivilegeDrop_Case` under
  `sudo` before lcov captures (mirroring `make_check`'s own pattern for that
  root-only case), and installs `libseccomp-dev`/`--with-seccomp` so the real
  `HAVE_SECCOMP` sandbox path is included. Three separate `lcov --remove`
  patterns (`popt/`, `test/`, `/usr/*`) turned out to be dead on arrival --
  none ever matched anything this job's own build produces -- caught via
  real CI runs and removed rather than suppressed with `--ignore-errors
  unused` (AGENTS.md rule 76, added because of this). Motivated by the
  OpenSSF Best Practices Badge `test_most` criterion; without an
  auto-detected Coveralls/Codecov badge, that criterion is met with a manual
  justification linking to a real CI run instead. Separate job from
  `make_check`, since gcov instrumentation changes what's being measured and
  this job's coverage report is not itself a pass/fail gate; redirects to
  `current_dev` on the nightly schedule run, matching
  `make_check`/`distributed_e2e`'s own redirect.

- **`src/util.c`**: documented `argv_contains()` as unused dead code. A
  current-tree recursive grep (`grep -Ri "argv_contains"`) only confirms no
  caller exists *today*; the stronger claim that none has existed since the
  function's original 2008 import was verified with `git log --oneline -S
  "argv_contains(" --` restricted to this branch's own ancestry (not `--all`,
  which also pulls in unrelated remote-tracking history) -- every match is
  either the 2008 initial import or a later pure file-move commit, never a
  commit that adds a call site. Also brought `dcc_exit()`/`str_endswith()`/
  `str_startswith()`'s comments up to this fork's convention while the file
  was already open for this change.

- **`doc/ci-workflows.md`**: a maintained map of the full `.github/workflows/*.yml`
  landscape -- per-file triggers/jobs/outputs, a cross-reference matrix (shared
  composite actions, the GHCR image namespace, path-filter overlaps, dangling
  outputs), a schedule-collision table, and a branch-dormancy note, produced
  from a full read-through of every workflow/action/config file rather than a
  pattern-based scan (#356). Surfaced two real, previously-undocumented issues
  along the way, tracked separately rather than fixed here: a cron collision
  between `openssf-baseline-recheck.yml` and `scorecard.yml` (both 06:00 UTC
  whenever the 1st/15th falls on a Sunday), and a stale `release.yml` exclusion
  in `actionlint.yml`'s lint-target list that currently matches no real file.

- **`.github/workflows/e2e-image-build.yml`, `test/e2e/Dockerfile`,
  `test/e2e/README.md`**: the two-container distributed-compile e2e test
  image (used by `c-build.yml`'s per-push gate and `master-heartbeat.yml`'s
  weekly ccache heartbeat) is now built, validated via a real embedded
  self-test (a distcc-through-distccd compile checked against the daemon's
  own log), and published to GHCR as `distcc-ng-e2e:latest` -- the actual
  test workflows don't pull it yet (a deliberately separate follow-up, see
  `test/e2e/README.md`). Rebuilt daily (deliberately unpinned base image,
  unlike this fork's other two images) so it always carries the latest
  Debian trixie-slim security/backport updates, acting as an early-warning
  canary for an upstream package update
  breaking this project's build.

- **`.github/workflows/master-heartbeat.yml`, `test/e2e/control-build.sh`,
  `test/e2e/run-e2e.sh`**: two diagnostic/robustness additions to the weekly
  ccache-distributed heartbeat, motivated by issue #263 (a real heartbeat
  failure that took real effort to trace back to a compiler-version problem
  rather than a distcc-ng bug). (1) A new `ccache_control_build` job builds
  the same pinned ccache source directly with the same image's plain
  compiler, entirely independent of distcc/distccd (no daemon, no launcher,
  no network hop), and writes a classification note to the job summary; it
  never gates `ccache_heartbeat`'s own result (the `report` job still keys
  exclusively off `needs.ccache_heartbeat.result`), so a real distcc bug can
  never be masked by a green control build. (2) `run-e2e.sh` gained an
  optional `E2E_MAX_ATTEMPTS` retry loop (default `1`, i.e. unchanged
  behavior for `c-build.yml`'s per-push `distributed_e2e` job) so the weekly
  heartbeat can ride out a one-off network/container flake; a failure that
  reproduces on every attempt still exits non-zero. Both the heartbeat build
  and the new control build read the pinned ccache tag from a single
  workflow-level `CCACHE_HEARTBEAT_TAG` so they can never silently drift onto
  different ccache revisions.

- **`AGENTS.md`**: added rule 75 -- investigate to full depth on the first
  pass, not only after the maintainer pushes back a second time. A status
  or effort question must be answered by reading the relevant PR/issue body
  in full, checking for any "follow-up"/"out of scope" section in that PR's
  own text, and cross-referencing information already surfaced earlier in
  the same session, rather than treating each question as if starting from
  zero context. Also trimmed the "Live incident"/personal-commentary
  parentheticals out of rules 66, 70, 72, 73, and 74 -- rule text is
  normative only; that kind of narrative belongs in a PR/commit description
  or this project's own memory system, not in the governance file itself.

- **`AGENTS.md`**: added rule 76 -- do not add defensive/precautionary code
  (an exclusion pattern, a fallback branch, a compatibility shim, an extra
  flag) by copying it from a similar existing case without confirming it
  actually applies to the specific configuration being written; an
  inapplicable pattern must be left out, not kept "just in case" and then
  paired with a suppression flag once a tool complains about it (which
  would also violate rule 66).

- **`AGENTS.md`**: extended rule 62 -- a claim that a bug or vulnerability
  exists in code, especially external/upstream code not under this repo's
  control, now additionally requires tracing the complete relevant call
  path (not just the single line or function that looks wrong) and a real
  empirical reproduction wherever one is feasible, before being treated as
  confirmed. A `security`-labeled issue is held to this bar strictly.

### Fixed

- **`test/e2e/client-heartbeat.sh`, `test/e2e/control-build.sh`**: the weekly
  ccache-distributed heartbeat (#263) failed building `argprocessing.cpp`,
  and (once that was worked around) `core/statistics.cpp` too. Confirmed via
  a real reproduction on an independent host (not WSL2) that both failures
  are real GCC 12.2.0 (Debian bookworm) false positives
  (`-Wmaybe-uninitialized` on a deeply-inlined `tl::expected`/
  `std::optional<core::Statistic>` chain, then `-Wrestrict` with
  obviously-impossible offsets) -- reproducing identically with a plain
  local compile (`control-build.sh`, entirely independent of distcc), so
  this was never a distcc-ng distribution bug. Root cause: ccache's own
  CMake build auto-enables "dev mode" (and with it, `-Werror`) whenever it's
  built from a git checkout -- exactly how both scripts build it. Both
  scripts now pass two specific, named CMake overrides
  (`-Wno-error=maybe-uninitialized -Wno-error=restrict`) instead of
  disabling ccache's `-Werror` wholesale, so this heartbeat still catches a
  real distcc-specific bug that happened to manifest as some other warning
  class -- only the two diagnosed false positives are silenced. Verified with a
  full real run of the two-container heartbeat harness: 75 remote jobs
  completed successfully.

- **`src/remote.c`, `src/util.c`**: `dcc_check_unsupported_directives()`
  misreported a misleading `getline failed: Resource temporarily
  unavailable` warning on plain end-of-file, not just on a genuine read
  error. `getline()` returns -1 for both cases and does not guarantee
  `errno` is reset to 0 on the EOF path, so a stale `errno` left over from
  an unrelated earlier syscall in the same process (e.g. this same
  client's own non-blocking network I/O) could be misattributed to this
  read. Root-caused live via issue #263's `ccache_heartbeat` failure and
  confirmed against the original upstream review (distcc/distcc#461): a v1
  `errno = 0;` reset was removed in review for stylistic reasons only, no
  technical justification (see AGENTS.md rule 72). `ferror(cpp_f)` alone
  is not sufficient: this project's `util.c` compat `getline()` (used when
  the system lacks its own, `#ifndef HAVE_GETLINE`) can fail via
  `realloc()` without ever touching the `FILE` stream, so plain EOF and an
  allocation failure look identical to `ferror()` there. Fixed by (1)
  resetting `errno = 0` immediately before the loop so any nonzero value
  seen afterwards is known to be fresh, then checking `ferror(cpp_f) ||
  errno != 0`, and (2) having `util.c`'s compat `getline()` set
  `errno = ENOMEM` explicitly on its allocation-failure path instead of
  relying only on `realloc()`'s own side effect. Verified against glibc's
  real `getline()` that `errno` stays 0 across a clean EOF on large
  (multi-MB, multi-refill) files, so the added `errno` check does not
  reintroduce a false positive. Purely a misleading-log-message fix --
  `ret` (whether to recompile locally) was unaffected either way, so this
  never masked or caused a real failure.

- **`.github/workflows/c-build.yml`, `.github/workflows/actionlint.yml`**: a
  doc-only PR (e.g. README.md) could never merge into `master`, because
  master's branch ruleset requires `make_check (ubuntu-latest/macOS-latest)`,
  `Bundled popt fallback build`, `Vendored popt/ version and compile check`,
  `Distributed compile E2E (2-container)`, and `action-lint` to pass -- but
  those workflows' own `paths-ignore`/`paths` filters meant the check-runs
  never even started on a docs-only diff, and GitHub blocks a merge on a
  required check that never ran, not just one that fails. Confirmed live on
  PR #336. `c-build.yml` gained a cheap `changes` job (plain `git diff
  --name-only`, no third-party action) that the four heavy jobs now depend
  on and skip (not: never start) when nothing outside `**/*.md`/`doc/**`
  changed; `workflow_dispatch`/`schedule` always force a full run.
  `actionlint.yml` simply dropped its path filter entirely -- both its jobs
  are cheap enough to just always run.

- **`.github/workflows/c-build.yml`**: the `make_check` fix above (job-level
  `if:`) turned out to be incomplete -- confirmed live on PR #336 again,
  after the first fix (#337) had already merged. A matrixed job's `if:` is
  evaluated *before* the matrix expands, so a false condition collapses
  both legs into one plain `make_check` check-run instead of the two exact
  contexts (`make_check (ubuntu-latest)`, `make_check (macOS-latest)`)
  master's ruleset actually requires -- silently reproducing the "required
  check never existed" problem one layer deeper. Moved the `if:` from the
  job down to every individual step instead, which keeps the matrix
  expansion (and both named check-runs) intact while still skipping all
  real work on a docs-only diff. The other three gated jobs
  (`popt_fallback_build`, `popt_vendor_check`, `distributed_e2e`) are not
  matrixed and were unaffected.

### Changed

- **`.github/workflows/codeql.yml`**: `Analyze (c-cpp)`, `Analyze (python)`,
  and `Analyze (actions)` are also required status checks, but unlike
  `c-build.yml`/`action-lint`, this workflow never had a path filter --
  every PR ran a full C build plus all three CodeQL language scans, even
  a README-only change. Not merge-blocking (no filter means the checks
  always existed), just wasteful. Added a `changes` job computing one
  relevant/not-relevant flag per language (c-cpp: `src/`, `lzo/`, `popt/`,
  `include_server/c_extensions/`, `test/fuzz/`, `m4/`, `configure.ac`,
  `Makefile.in`, `autogen.sh`, or any `.c`/`.h`/`.cc`/`.cpp`; python:
  `include_server/`, `test/`, or any `.py`; actions:
  `.github/workflows/`, `.github/actions/`). Each matrix leg reads its own
  language's flag via a per-step `gate` step (same job-level-`if`-collapses-
  the-matrix pitfall as `make_check`, refs the `Fixed` entry above --
  avoided the same way, by gating steps instead of the job).
  `workflow_dispatch`/`schedule` always force a full scan.

### Added

- **ClusterFuzzLite integration** (`.clusterfuzzlite/`, `test/fuzz/fuzz_rpc_argv.c`,
  `.github/workflows/clusterfuzzlite-pr.yml`): fuzzes `src/rpc.c`'s
  `dcc_r_argv()` (the untrusted-peer argument-list parser) via libFuzzer
  on every PR touching `src/**`. Closes Scorecard's `FuzzingID` finding
  (refs #267). OSS-Fuzz itself was evaluated and rejected -- it requires
  "a significant user base and/or [being] critical to the global IT
  infrastructure" to be accepted, which a young fork does not realistically
  meet; ClusterFuzzLite has no such gate. Scoped to PR-triggered fuzzing
  only for now -- scheduled/batch continuous fuzzing needs a separate
  corpus-storage repository, a bigger follow-on decision not bundled here.

### Security

- **Bumped 10 pinned GitHub Actions across `.github/workflows/*.yml`**
  (Dependabot, PR #343): `actions/checkout` v5.0.0/v7.0.0 -> v7.0.1,
  `actions/cache` v4 -> v6.1.0, `actions/labeler` v6.2.0 -> v7.0.0,
  `stefanzweifel/git-auto-commit-action` v5.2.0 -> v7.2.0,
  `release-drafter/release-drafter` (+ its `autolabeler`) v7.5.1 -> v7.6.0,
  `ossf/scorecard-action` v2.4.3 -> v2.4.4, and `github/codeql-action`
  (`init`/`analyze`/`upload-sarif`) v3 -> v4.37.3. Reviewed per AGENTS.md
  rule 74 rather than merged on CI-green alone: each new pinned SHA was
  resolved against its upstream repo's own tag refs, and each dependency's
  release notes were checked for anything breaking -- none required an
  actual workflow change (the only real breaking requirement across all
  six repos, Node.js 24, is already satisfied by this repo's
  GitHub-hosted-only runners). The `codeql-action` bump's own inline
  version comment was left stale at `# v3` by Dependabot despite the SHA
  genuinely moving to v4.37.3 (confirmed against `codeql-action`'s own
  `v4` tag) -- corrected as part of this review, in `codeql.yml` and
  `scorecard.yml`.

- **`.github/workflows/actionlint.yml`** (renamed to reflect its now-broader
  scope): added a new `shellcheck` job linting this repo's own real shell
  scripts (`scripts/*.sh`), using the same pinned `distcc-ng-buildtools`
  image and plain `docker run` invocation as the existing `action-lint`
  job. `shellcheck` was installed into that image by #332 but never
  actually wired into a CI job -- this was the last remaining gap
  identified in the best-practices-driven CI audit (refs #267).

- **`.github/workflows/actionlint.yml`**: replaced the `curl <script> |
  bash` actionlint install with the pinned `distcc-ng-buildtools` image
  (#332), resolving Scorecard's `PinnedDependenciesID` finding
  ("downloadThenRun not pinned by hash", refs #222/#267). Also removed an
  unused `pull-requests: write` permission -- the job never comments on or
  labels a PR, same class of over-grant as #324's `osv-scanner.yml` fix.

- **`docker/verify/Dockerfile`**: added `actionlint` (built from source and
  version-pinned, v1.7.12 -- avoids stale Go-stdlib CVEs in the official
  static release binary, same rationale/version as `wiki-mod/lancache-ng`'s
  own build-tools image), plus `shellcheck` and `jq`, each with a real
  build-time self-test (a deliberately broken script/workflow/JSON doc).
  Groundwork for closing Scorecard's `PinnedDependenciesID` finding
  (refs #222/#267) in `.github/workflows/actionlint.yml` -- done as a
  separate, follow-on change once this image's new `:latest` is actually
  published (publish only happens on push to `current_dev`, not on this
  PR itself).

- **PR title Conventional-Commit lint**, adapted from `wiki-mod/lancache-ng`'s
  own AG-GH-018/`check-pr-title-convention.sh`. New `pr_title_convention`
  job in `.github/workflows/changelog-check.yml` validates a PR title
  against AGENTS.md rule 71's taxonomy (`feat`/`fix`/`security`/`docs`/etc.,
  with a documented scope list). Currently `warn`-only
  (`PR_TITLE_LINT_MODE` repository variable) since almost none of this
  repo's real PR-title history already follows the convention -- unlike
  `lancache-ng`'s own audit, where most already did. Closes #307.

- **PR tracking-metadata enforcement, path-based auto-labeling, and
  project-board automation**, adapted from `wiki-mod/lancache-ng`'s own
  AG-GH-008/`labeler.yml`/`add-to-project.yml`:
  - `.github/workflows/changelog-check.yml` gained a new
    `pr_tracking_metadata` job enforcing rule 3 (a PR must carry at least
    one label and a milestone, and -- once `PROJECT_AUTOMATION_PAT` is
    configured -- be on the project board) as a real, blocking CI check,
    not just a written convention. This is the actual root-cause fix for
    issue #50's class of problem (CHANGELOG.md went unmaintained for ~10
    merged PRs before anyone noticed); `require_changelog`'s file-touch
    check stays alongside it rather than being replaced.
  - `.github/labeler.yml` + `.github/workflows/labeler.yml`: path-based
    auto-labeling (documentation, ci, packaging, pump, seccomp, zstd,
    config) using this repo's real, existing label set.
  - `.github/workflows/add-to-project.yml`: auto-adds new issues/PRs to
    the distcc-ng project board (https://github.com/orgs/wiki-mod/projects/11),
    skipped gracefully (not failed) until `PROJECT_AUTOMATION_PAT` is
    configured as a repository secret.
  - `scripts/check-pr-tracking-metadata.sh`: the check script itself,
    adapted to run directly on GitHub-hosted `ubuntu-latest` (no
    container needed, unlike lancache-ng's self-hosted-runner original).

### Documentation

- **`AGENTS.md`**: rule 24 amended -- a deferral (leaving a review-thread
  finding unresolved with only an explanation, rather than fixed) is not
  itself a decision. The explanation must be put to the maintainer as an
  explicit approval question, even when only reporting status, and must
  keep being surfaced as an outstanding decision until an explicit answer
  is given -- not presented as already approved, and not left for the
  maintainer to discover unprompted. Found necessary on PR #354: a
  delegated agent posted a sound deferral explanation on two review
  threads and correctly left them unresolved per the rule's letter, but
  never put the deferral itself to the maintainer as a question -- it was
  only reported afterward as an already-settled fact.
- **`AGENTS.md`**: rule 3 rewritten to cover PRs as well as issues (labels,
  Milestone, Project-board — previously issue-only) and to reference the
  new CI enforcement above. Added rule 70 -- a `release/X.Y.Z-NG` branch
  must never be patched live once cut; any fix found while verifying it
  goes through `current_dev` normally, then the release branch is re-cut
  fresh. Found necessary after the 3.6.1-NG release's matrix-bug and
  testdistcc.py fixes were patched directly on `release/3.6.1-NG`, silently
  leaving `current_dev` behind `master`. Also clarified rule 4: a
  standalone PR does not require an issue opened first.
- **`.github/pull_request_template.md`**: relaxed the "Linked Issues"
  section to explicitly say a standalone PR doesn't need an issue,
  matching rule 4's clarification.
- **`AGENTS.md`**: added rule 72 -- before proposing a fix for something
  that looks like a bug in existing code, verify it isn't a deliberate,
  consistent design choice (check the pattern's history/upstream PR
  review discussion, and whether it repeats consistently elsewhere in the
  codebase) before concluding it's a defect. Found necessary while
  investigating issue #263's `ccache_heartbeat` failure: an `errno`-after-
  `getline()` check in `src/remote.c` turned out to be a real bug (its
  original `errno = 0;` reset was removed in distcc/distcc#461's review
  for stylistic reasons only, no technical justification), but a second
  suspected issue in the same file (`gettimeofday()`'s warn-and-continue
  handling) turned out to be a deliberate, project-wide convention used
  identically in every other `gettimeofday()` call across the codebase.
- **`AGENTS.md`**: added rule 73 -- when treating a found bug as an error
  class to sweep for elsewhere, the minimum scope for that sweep is the
  whole file the bug was found in, not just a `grep` for the identical
  pattern or line shape. Companion to rule 72: reading the whole
  `src/remote.c` file end-to-end (not just grepping for the exact
  `errno`-after-`getline()` shape) is what surfaced the `gettimeofday()`
  pattern as worth checking in the first place.
- **`AGENTS.md`**: added rule 74 -- a Dependabot (or any automated)
  dependency-bump PR must be reviewed before merging, not merged on
  CI-green alone: verify the new pinned SHA against the upstream repo's
  own tag refs, keep the `# vX.Y.Z` comment accurate, read the actual
  release notes for the version range crossed, and explicitly decide
  whether anything breaking/deprecated requires a change to how this repo
  uses the dependency. Found necessary reviewing PR #342/#343 (10 bundled
  GitHub Actions bumps): `github/codeql-action`'s bump was a real v3->v4
  major-version jump, but the diff's own inline comment still read `# v3`
  -- fixed directly on both PRs' branches as part of this review.

- **`CONTRIBUTING.md`**: added an explicit statement that a behavior-changing
  or bug-fixing PR should add or update an automated test in
  `test/testdistcc.py`, with an honest escape hatch for changes that
  genuinely aren't testable that way (documentation-only, etc.). Closes
  `OSPS-QA-06.03` (refs #267) — a real gap found while re-verifying Baseline
  Level 3 status against current `master` state rather than trusting an
  earlier recollection.

- **`CLAUDE.md`**: added a "Key Design Decisions" bullet documenting the
  protocol-version numbering policy from issue #304 -- versions 0-3999
  reserved exclusively for whatever upstream `distcc/distcc` itself ever
  defines, every fork-specific protocol extension numbered from 4000+
  instead, applying to zstd's existing `DCC_VER_4000`/`DCC_VER_5000` and to
  every future fork protocol extension including the planned native TLS
  transport (#248). This was the last of #304's six required follow-up
  actions; the other five (the `DCC_VER_4`/`DCC_VER_5` renumbering itself,
  the `doc/protocol-4000.txt`/`doc/protocol-5000.txt` renames, and the
  `man/distcc.1` zstd documentation) were already done in earlier PRs.

- **`README.md`**: added the OpenSSF Baseline badge alongside the existing
  Best Practices badge. `master` had picked up a Baseline-only swap during
  an earlier release cut without going back through `current_dev`; both
  badges now show on both branches instead of one replacing the other.

### Security

- **`.github/workflows/osv-scanner.yml`**: dropped the redundant top-level
  `security-events: write` (and `actions: read`) permission grant — both
  jobs (`scan-pr`, `scan-scheduled`) are mutually exclusive `if:`-gated and
  already declare their own full job-level permissions block for the
  reusable workflow they call, so nothing actually relied on the top-level
  grant. Top-level floor is now `contents: read` only. Resolves Scorecard's
  `TokenPermissionsID` finding #145 ("topLevel 'security-events' permission
  set to 'write'") — refs #222/#267.

### Security

- **`src/exec.c`**: `dcc_execvp()` no longer silently retries a failed
  exec of a directory-qualified `argv[0]` (absolute, or relative with a
  `/`) with a second `execvp()` on just its basename, letting the
  exec'ing host's own `$PATH` resolve a substitute. This ran identically
  on `distcc`'s local exec paths and on `distccd`'s exec of a compiler
  chosen by a remote client; on a server whose toolchain layout differs
  from wherever `argv[0]` was originally resolved, the fallback could
  silently run a *different* same-named compiler than the one actually
  selected, with no error and no signal to the client that a
  substitution happened -- more likely to be exercised in practice since
  #281's directory-preserving cross-compile resolution. A bare-basename
  `argv[0]` is unaffected: POSIX `execvp()` already performs a full
  `$PATH` search for it in the very first call, so there was never a
  narrower name left to retry with in that case. Now any exec failure
  fails loudly (`EXIT_COMPILER_MISSING`), which the client's existing
  remote-compile-failure handling already turns into a logged warning
  plus an automatic local retry (`DISTCC_FALLBACK=1`, the default) or a
  clear hard failure (`DISTCC_FALLBACK=0`) -- never a silent
  wrong-compiler "success." Refs #287.

## [3.6.1-NG] - 2026-07-23

### Fixed

- **`.github/workflows/package-release.yml`**: `build_container`'s matrix
  had `variant: [plain, pump]` with a separate `include` list specifying
  only `platform`/`runs_on` (no `variant` key) — since GitHub Actions only
  merges an `include` entry into an existing combination when it shares a
  matching axis key, an entry with none of the original axis keys instead
  overwrites the added key for *every* generated job, in list order. The
  last entry (`arm64`) therefore won for every job, silently making
  `amd64` — documented as the required leg — never build at all. Caught
  live: this PR's own `publish_manifest` job failed with
  `digest-plain-amd64.txt: No such file or directory`, since no amd64 leg
  had ever run to produce it. Fixed by making `platform: [amd64, arm64]` a
  real matrix axis, so `include` entries attach `runs_on` per matching
  platform instead of overwriting each other.
- **`test/testdistcc.py`**: addressed 9 code-quality findings raised by
  this PR's own review (unclosed file handles in `open(...).read()`
  one-liners and a couple of `open()`/`write()`/`close()` sequences not
  guarded against an exception between them; an unused `log_contents`
  local; an empty `except OSError: pass` with no explanatory comment).
  All file opens now use `with`; the unused variable was removed since
  the call's only purpose was the wait side-effect; the empty except got
  a one-line comment explaining it's best-effort cleanup of a possible
  leftover file. No behavioral change.

### Removed

- **`doc/web/`**: deleted the old, conserved upstream distcc project website
  (index/FAQ/benchmark/results/scenarios/security pages, man-page HTML
  mirrors, and static assets) — historical project marketing/docs content
  this fork doesn't maintain or serve. `master` already had this removed
  directly; this brings `current_dev` in line with it.
- **`Makefile.in`'s `man-html`/`upload-man`/`upload-dist` targets,
  `packaging/googlecode_upload.py`**: dead maintainer-only upstream
  tooling found while removing `doc/web/` — `man-html`/`upload-man`
  directly wrote into (and `svn commit`'d) the now-deleted `doc/web/man/`,
  and `upload-dist` called `googlecode_upload.py` to upload release
  tarballs to Google Code, which shut down in 2016. None of this fork's
  own release process (`.github/workflows/package-release.yml`, GHCR)
  uses any of it.

### Added

- **`scripts/run-tests.sh`** (new): a dev-convenience wrapper that runs the
  real verification steps (`./autogen.sh`, `./configure PYTHON=python3` with
  pass-through for extra configure args, `make`, `make check`) in order,
  fails fast and loud on any step's non-zero exit or on a compiler warning
  (AGENTS.md rule 31), and parses `make check`'s comfychair-based
  `test/testdistcc.py` output into a concise OK/NOTRUN/FAILED summary
  instead of requiring a manual `tail`/`grep` of the log. Does not replace
  `make check` or `test/testdistcc.py` itself (refs #238).
- **`.github/workflows/package-release.yml`**: `build_packages` now generates
  a real SPDX SBOM (via `anchore/sbom-action`) for the released source
  tarball, uploaded both as a workflow artifact and as an additional
  GitHub Release asset alongside the existing `.tar.gz`/`.tar.bz2`/`.rpm`/
  `.deb` files, and covered by the same build-provenance attestation.
  Closes `OSPS-QA-02.02` (refs #267).
- **`.github/workflows/osv-scanner.yml`** (new file, refs #267): adds
  `google/osv-scanner-action`'s reusable workflows as a real-time SCA gate
  on pull requests, pushes to `current_dev`/`master`, and a weekly schedule
  — checking every pinned GitHub Actions dependency against OSV.dev's
  advisory database. Closes `OSPS-VM-05.03`'s automated-enforcement
  requirement for the one dependency ecosystem this project's C/autoconf
  build actually has a manifest for (GitHub Actions); the C library
  dependencies (`libzstd`, `libpopt`, `libavahi-client`, `libseccomp`)
  remain outside any SCA tool's reach, consistent with
  `doc/compatibility-policy.md`'s existing Dependency management policy
  section.
- **`doc/threat-model.md`** (new): a real threat model and attack-surface
  analysis — actors, trust boundaries, the wire-protocol parsers' concrete
  fixed-vulnerability history (#95/#292/#293), the seccomp sandbox's
  fail-open/fail-closed boundary, and the residual risk if `distccd` is
  ever exposed beyond a trusted LAN. Closes `OSPS-SA-03.02` (refs #267),
  linked from `doc/security-assessment.md`.
- **`doc/distcc-ng.openvex.json`** (new): a real [OpenVEX](https://github.com/openvex/spec)
  document covering all 30 of this repository's currently-dismissed CodeQL
  alerts (19 `not_affected` with a machine-readable justification, 11
  `under_investigation` where the dismissal comment itself says final
  triage under issue #143 isn't finished). Closes `OSPS-VM-04.02` (refs
  #267) with this project's real dismissed-alert history, not a fabricated
  "nothing to report" placeholder.
- **`SECURITY.md`**: new "Dependency vulnerability (SCA) policy" section
  documenting the critical/high-blocks-a-release, medium/low-tracked-only
  threshold and the same GitHub-Actions-only coverage honesty as above;
  new "Dismissed-alert transparency" note pointing at
  `doc/distcc-ng.openvex.json`. Closes `OSPS-VM-05.01`/`OSPS-VM-05.02`
  (refs #267).

### Documentation

- **`doc/verification-checklist.md`**: added a third container-verification
  gotcha to section 9 — Docker's default root capability set lacks
  `CAP_SYS_NICE`, so a root-only test exercising `nice(2)` with a negative
  value (`AutogroupNicenessPrivilegeDrop_Case`) fails with an
  "Operation not permitted" error that reads identically to a real code
  regression unless `--cap-add=SYS_NICE` is added explicitly. Found while
  verifying the 3.6.1-NG release.
- **`SECURITY.md`**: added a Secrets and Credentials Policy section (GitHub
  Actions secrets are the only secret material in use; least-privilege
  workflow permissions per #308; `secret_scanning` +
  `secret_scanning_push_protection` both enabled, verified live), a Verifying
  Release Artifacts section documenting the `gh attestation verify` command
  for checking a release asset's Sigstore build-provenance attestation, and
  an explicit statement of this project's zero-tolerance CodeQL alert
  remediation threshold (`alerts_threshold: "all"` on the
  `distcc-ng-default` repository ruleset). Closes three small documentation
  gaps (`OSPS-BR-07.02`, `OSPS-DO-03.01`/`OSPS-DO-03.02`, `OSPS-VM-06.01`)
  identified while working toward OpenSSF Best Practices Baseline Level 3
  (refs #267).

### Fixed

- **`Makefile.in`**: removed the stale `AUTHORS` entry from `pkgdoc_DOCS` —
  `AUTHORS` was deleted from the repo in an earlier commit, but `Makefile.in`
  still listed it, breaking `make install-doc`/`make dist`/anything that
  runs `make install` (`make: *** No rule to make target 'AUTHORS', needed
  by 'install-doc'. Stop.`) — caught live by this PR's own
  "Distributed compile E2E" CI check once `required_status_checks` made it
  a real merge gate.

### Documentation

- **`CONTRIBUTING.md`** (new): a contributor guide covering project scope,
  before-you-start expectations, PR/issue-linking conventions, changelog
  and comment-style expectations, local verification (build+test,
  `actionlint`, the `distcc-ng-buildtools` container), release process,
  and how to report security issues. Adapted from sister repo
  `wiki-mod/lancache-ng`'s own `CONTRIBUTING.md`, substituting distcc-ng's
  actual mechanisms throughout rather than copying lancache-ng-specific
  ones. Closes the `OSPS-GV-03.02` gap from issue #267's OpenSSF Best
  Practices Baseline review.
- **`README`, `README.pump` removed; `README.md` is now the single root
  README** (refs #316): `README` was a stale, already-diverged duplicate of
  `README.md` (missing this fork's own URL/Security/Licence/Resources
  sections); `README.pump`'s real technical content (include-server header
  analysis, absolute-include-path handling via inserted `#line` directives,
  build flow, performance characteristics) was folded into `README.md` as a
  new `## Pump mode` section rather than summarized away. Updated
  `Makefile.in`'s `pkgdoc_DOCS` and `INSTALL`'s cross-reference accordingly;
  verified for real that `README.md` (not the removed files) is what
  actually ships in `make dist`/`make install-doc` output.
- **`doc/security-assessment.md`** (new): a minimal index/pointer document
  (trust model, actors, known risk history, upstream context) linking to
  existing docs (`SECURITY.md`, `doc/protocol-*.txt`,
  `doc/tls-transport-design.md`, `doc/seccomp-sandbox.md`) rather than
  restating their content. Closes the `OSPS-SA-01.01`/`OSPS-SA-03.01` gap
  from issue #267's OpenSSF Best Practices Baseline review.
- **`README.md`**: added the OpenSSF Best Practices (Baseline) badge, linking
  the project's public submission at bestpractices.dev. Refs #267.

### Security

- **OSSF Scorecard: remaining `PinnedDependenciesID`/`TokenPermissionsID`
  findings from #267** (`.github/workflows/verify-image-build.yml`,
  `test/e2e/Dockerfile`, `.github/workflows/c-build.yml`, `codeql.yml`,
  `nightly-publish.yml`, `package-release.yml`) — refs #267 (not all of
  #267's findings are addressed; see that issue for the remaining
  maintainer-decision items).
  - `verify-image-build.yml`'s two remaining floating `actions/checkout@v7`
    references pinned to `9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0` (`#
    v7.0.0`, live-verified against the GitHub API at pin time), matching the
    SHA every other workflow file in this repo already uses.
  - `test/e2e/Dockerfile`'s `ARG DEBIAN_IMAGE` default pinned from the
    floating `debian:bookworm-slim` tag to its real digest
    (`sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818`,
    live-verified against Docker Hub's registry API), matching the existing
    digest-pin precedent already used by `docker/release/Dockerfile` and
    `docker/verify/Dockerfile`'s own `DEBIAN_IMAGE` defaults.
  - `TokenPermissionsID` least-privilege pass: `c-build.yml` was missing a
    top-level `permissions:` block entirely (every job already had its own
    minimal block, so this is a defense-in-depth default, not a behavior
    change); `codeql.yml` had `security-events: write` at the top level
    instead of scoped to the one job that needs it; `nightly-publish.yml`'s
    and `package-release.yml`'s top-level blocks granted `contents: write`/
    `packages: write`/`id-token: write`/`attestations: write` to every job
    in each file regardless of whether that job's own steps ever used them
    (e.g. pure build/test gate jobs that only check out and run `make
    check` or a local e2e script) — both files' top-level blocks demoted to
    `contents: read`, with each job now declaring only the specific write
    scope(s) its own steps actually call (GHCR push needs `packages:
    write`; `gh release`/tag operations need `contents: write`; build
    provenance attestation needs `id-token: write` + `attestations:
    write`).
- **OSSF Scorecard: `DependencyUpdateToolID` finding from #267** — added
  `.github/dependabot.yml`, covering the `github-actions` ecosystem (the
  only ecosystem with anything to manage: `include_server/setup.py` has no
  external Python dependencies, and the C library dependencies are detected
  via `configure.ac`'s autoconf/`PKG_CHECK_MODULES` checks, which have no
  package-manager-native manifest for Dependabot to parse) plus a `docker`
  ecosystem entry for `docker/release/Dockerfile` and `docker/verify/Dockerfile`'s
  already-pinned base image digests. Each ecosystem is duplicated once per
  `target-branch` (`master` and `current_dev`), since Dependabot's own
  `target-branch` key accepts exactly one branch and silently defaults to
  the repo's default branch (`master`) when omitted — refs #267.

### Documentation

- **`doc/compatibility-policy.md`: dependency management policy** (refs
  #267, OpenSSF Baseline `OSPS-DO-06.01`): new "Dependency management
  policy" section documenting how this fork selects, obtains, and tracks
  its GitHub Actions, C library, Python, and vendored-code dependencies,
  including the maintainer's reasoning for why vendored code like `lzo/`'s
  minilzo is reviewed manually rather than replaced (upstream `distcc/distcc`
  itself vendors the identical implementation).
- **`AGENTS.md`: "Project Roles" section** (refs #267, OpenSSF Baseline
  `OSPS-GV-01.01`/`OSPS-GV-01.02`): documents the project's actual
  membership — the sole human maintainer (`djdomi`, with exclusive access
  to sensitive resources) and AI coding agents operating under this file's
  governance with no standing write access beyond what a task explicitly
  delegates.
- **`SECURITY.md`** (new, refs #267): security-vulnerability reporting policy —
  private disclosure via GitHub Security Advisories, a supported-versions
  table tied to `doc/release-versioning.md`'s `-NG` scheme, and a "Known
  Security Tradeoffs and Design Decisions" section documenting this project's
  intentional trust-boundary choices (LAN-oriented deployment model,
  seccomp sandboxing as defense-in-depth rather than a hard guarantee,
  TLS transport not yet implemented — see `doc/tls-transport-design.md`).
  Closes the `SecurityPolicyID`/`OSPS-VM-02.01` gap identified while
  triaging OSSF Scorecard findings (#267) and preparing the project's
  OpenSSF Best Practices (Baseline) badge submission.

### Added

- **`.github/workflows/openssf-baseline-recheck.yml`** (new, refs #267,
  #312): recurring re-verification of the OpenSSF Best Practices Baseline
  criteria (bestpractices.dev project 13760) that are checkable from live
  repo/org state — the repo ruleset's `pull_request`/`deletion` rules,
  workflow-trigger and permission greps, GitHub secret-scanning status,
  absence of tracked binary artifacts, `SECURITY.md`/dependency-policy/
  project-roles doc presence — so drift (an action becoming unpinned again,
  a ruleset rule removed, secret scanning disabled) is caught between manual
  self-assessments. Runs on the 1st and 15th of each month (a practical
  fixed-day approximation of a 14-day cadence, since cron has no native
  "every N days" primitive) plus `workflow_dispatch`, and posts/updates a
  single marker-tagged status comment on #312 with a per-baseline-level
  breakdown, an explicit REGRESSED callout for anything that was previously
  confirmed Met and no longer is, and ready-to-click bestpractices.dev
  proposal links for whatever currently verifies as Met. Never writes to
  bestpractices.dev itself — that platform's badge-criteria-update mechanism
  is a URL-query-parameter form meant to be opened and submitted by a
  logged-in human, with no API/headless write path.

- **Protocol version 5000: Zstandard compression with server-side cpp (pump
  mode)** (`src/distcc.h`, `src/hosts.c`) — closes the combination gap left
  by protocol versions 1-4: a host specification requesting both `,cpp`
  (pump mode) and `,zstd` previously failed to resolve to any protocol
  version at all ("invalid host options"). `dcc_get_protover_from_features()`
  / `dcc_get_features_from_protover()` (`src/hosts.c`) now recognize this
  combination as `DCC_VER_5000`. Numbered 5000, not 5, per issue #304's
  numbering policy decided during this same review: versions 0-3 are
  reserved exclusively for whatever upstream `distcc/distcc` itself defines,
  and every fork-specific protocol extension (this one, and future ones
  like #248's planned TLS transport) gets its own number starting at
  4000+, so this fork's own additions can never collide with a future
  upstream protocol version in the low range. Fixed two real interaction
  bugs found while wiring the two previously-independent features together
  (`src/serve.c`, `src/clirpc.c`): the header-closure transfer
  (`NFIL`/`NAME`/`FILE`, always LZO-compressed by the include-server
  regardless of the negotiated wire protocol) was at risk of being fed
  through zstd decompression instead once the top-level negotiated
  compression became zstd; and the client's `DOTD` (dependency-file) read
  assumed LZO's single-int length format unconditionally, which would
  desync once `DOTD` is zstd-compressed and needs the 2-int
  compressed/uncompressed length format. Split dwarf (`DDWO`) is
  deliberately *not* extended to this version — see `doc/protocol-5000.txt`
  and `src/distcc.h`'s `DCC_VER_5000` comment for why. Also hardened
  `src/hosts.c`'s and `src/srvrpc.c`'s protocol-version validation to
  reject the (now real, since 5000 leaves a gap above 4) unassigned-version
  range explicitly, rather than relying on a simple upper-bound check that
  the gap would otherwise slip through. See `doc/protocol-5000.txt` for the
  full wire-format description and `test/testdistcc.py`'s new
  `ZstdPumpCompile_Case` for real daemon+compile test coverage of this
  combination. Refs #101, #304.

### Changed

- **BREAKING: `DCC_VER_4` (zstd + client-side cpp) renumbered to
  `DCC_VER_4000`** (`src/distcc.h`, `src/hosts.c`, `src/serve.c`,
  `src/clirpc.c`, `src/srvrpc.c`, `src/bulk.c`, `doc/protocol-4000.txt`) —
  per issue #304's numbering policy: protocol versions 0-3 are reserved
  exclusively for whatever upstream `distcc/distcc` itself defines
  (verified against upstream's actual current source to top out at
  `DCC_VER_3`), and every fork-specific protocol extension (this one, and
  future ones such as #248's planned TLS transport) gets its own number
  starting at 4000+, so this fork's own additions can never collide with
  a future upstream protocol version. This is a real wire-protocol
  incompatibility with any distcc-ng build predating this change that
  still uses `,zstd` -- done now deliberately, while real-world adoption
  of zstd is still effectively zero, since this is the cheapest point at
  which to make this breaking change. Also hardened `src/hosts.c`'s and
  `src/srvrpc.c`'s protocol-version validation: with a gap between 3 and
  4000, a simple upper-bound check could no longer reject an unknown
  value in that gap -- both now explicitly check against the known set of
  versions instead. Verified for real: full build with `-Wall -Werror`
  and `make check` both exit 0/pass on a real host, zstd-enabled and
  `--without-zstd` builds alike.

### Removed

- **`ChangeLog`, `NEWS`** (root-level, not `CHANGELOG.md`): deleted as old
  upstream history this fork doesn't carry forward — `ChangeLog` was a
  frozen, auto-generated commit log last touched 2011; `NEWS` was upstream's
  own curated release notes, last touched 2025-01-25 and superseded by
  `CHANGELOG.md` as the one changelog going forward. `Makefile.in`'s
  `pkgdoc_DOCS`/`dist_extra` lists and the `dist` target's separate
  `$(distnews)` copy step (which unconditionally `cp`'d `NEWS` alongside
  the release tarball) updated accordingly, so `make install-doc`/
  `make dist` don't break looking for either file. Verified for real: a
  full build, `make check`, `make install-doc`, and `make dist` all still
  exit 0 on a real host with both files removed.

- **`m4/pkg.m4`** (an 18-year-old vendored copy of pkg-config's autoconf
  macro) and the now-empty `m4/` directory: verified dead before removal —
  renaming the file away entirely and re-running `./autogen.sh &&
  ./configure PYTHON=python3 --with-auth` produced an identical
  `aclocal.m4` and identical pkg-config/zstd/seccomp detection, because
  `aclocal` picks up the system's own `/usr/share/aclocal/pkg.m4` (from the
  `pkg-config` package) instead. `configure.ac`'s
  `AC_CONFIG_MACRO_DIRS([m4])`, `autogen.sh`'s `-I m4` flag, and
  `Makefile.in`'s `dist_dirs` entry removed accordingly. Verified for real:
  `autogen.sh`, `configure`, a full build with `-Wall -Werror`, `make
  check`, `make install-doc`, and `make dist` all still exit 0 with `m4/`
  gone.

- **`--with-gnome`** (`configure.ac`, `src/mon-gnome.c`'s `WITH_GNOME`
  include guard, `INSTALL`): removed as unsupported — it required
  `libgnome-3.0`/`libgnomeui-3.0`, packages that don't exist in any current
  Linux distribution (dropped entirely, not versioned to 3.0, during the
  GNOME 2 → 3 transition around 2010/2011); `configure
  PYTHON=python3 --with-gnome` failed hard (`configure: error: libgnome-3.0
  was not found by pkg-config`, verified for real on a current host).
  `--with-gtk` (plain GTK3, no GNOME desktop-integration libraries) is the
  one remaining, actually-working way to build `distccmon-gnome` — verified
  for real: builds and links cleanly against `gtk+-3.0` 3.24.49 both before
  and after this change.

- **`docker/base/`, `docker/compilers/`, `docker/build.sh`**: the original
  upstream compiler-compatibility test harness (built distcc against
  gcc-4.8/gcc-5/clang-3.8 on Ubuntu 16.04 Xenial). Not referenced by any
  `.github/workflows/*.yml` — a manual-only tool, last touched in 2018
  (pre-fork, Travis-CI era). Verified it still technically builds (real
  `docker build` on a current host, `docker/base/Dockerfile` still pulls
  and installs cleanly against Xenial's archive) but decided to drop it as
  unmaintained, CI-disconnected cruft rather than keep updating it.

### Documentation

- **`doc/docker.md`** (new): consolidates what used to be three separate
  READMEs scattered across `docker/README.md`, `docker/release/README.md`,
  and `docker/verify/README.md` into one page under `doc/`, alongside this
  fork's other topic docs (`doc/compatibility-policy.md`,
  `doc/release-versioning.md`, etc.) instead of duplicating the pattern of
  a README per subdirectory.

### Added

- **`docker/release/Dockerfile`, `.github/workflows/package-release.yml`** (#181):
  established `distcc-ng-pump` as a separately-published, actively-maintained
  container variant with pump mode (the Python include-server + `pump`
  wrapper) built in — the currently-active release image had none at all,
  a real, previously-unnoticed gap (the last pump-capable image was a
  frozen, pre-`-NG` `3.4.1` relic, since renamed to a legacy suffix per
  #40). New `runtime-pump` Dockerfile stage reuses the exact same compiled
  build-stage artifacts as the plain image (pump mode is built by default,
  nothing needed to be recompiled) via `make install DESTDIR=/out-pump` --
  deliberately not a manual file-by-file copy, since `pump`'s own install
  step needs to record where `include_server.py` ends up so the installed
  wrapper can find it (`Makefile.in`'s `install-include-server` target).
  `package-release.yml`'s `build_container`/`publish_manifest` jobs gained
  a `variant: [plain, pump]` matrix dimension (alongside the existing
  `amd64`/`arm64` platform one), each variant getting its own image base,
  Trivy scan, SBOM, and multi-arch manifest -- published as the separate
  `ghcr.io/wiki-mod/distcc-ng-pump` package (matching this repo's existing
  `distcc-ng-nightly`/`distcc-ng-buildtools` separate-package precedent for
  build variants, not a tag suffix on the same package). Verified for
  real: both `runtime` and `runtime-pump` targets built and ran on a real
  Docker host, and a genuine two-container pump-mode distributed compile
  (client `pump distcc gcc -c` against a `distccd` server, both containers
  built from the new image, `DISTCC_FALLBACK=0` so a real distribution
  failure couldn't silently fall back to local) completed with the real
  wire-protocol trace showing server-side compilation (`exec on
  pump-server,cpp,lzo`), the real symlink-mirroring mechanism from
  issues #95/#292 in action, and a working resulting binary.
- **`.github/workflows/{actionlint,codeql,changelog-check,changelog-update-on-release,release-drafter}.yml`**:
  added `workflow_dispatch` to the 5 of 11 workflow files that had no manual
  trigger at all. `actionlint.yml`/`codeql.yml` needed no other change
  (event-independent). `changelog-check.yml` and
  `changelog-update-on-release.yml` hard-depend on `github.event.pull_request`/
  `github.event.release` context that doesn't exist on a manual dispatch, so
  each gets required `workflow_dispatch` inputs (`pr_number`; `tag_name`/
  `release_notes`) instead of silently running with empty values.
  `release-drafter.yml`'s `update_release_draft` job (safe/idempotent to
  re-run manually) now also matches `workflow_dispatch`; its `auto_label`
  job stays `pull_request`-only, since it needs a real PR event to know
  which PR to label. Verified with a real `actionlint` binary (not just
  YAML syntax) against all workflow files.
- **`.github/workflows/verify-image-build.yml`/`docker/verify/README.md`**
  (#264): added a `ccache + Redis remote-storage self-test` step (plus an
  ephemeral, CI-local `redis:alpine` `services:` container) to the
  `build_and_selftest` job, proving ccache's `CCACHE_REMOTE_STORAGE`
  integration — per the maintainer, the single most common real-world
  ccache deployment shape — actually round-trips a real cache hit through
  Redis. Two separate, fresh `docker run` invocations compile the same real
  source file (`src/dopt.o`, via this repo's own Makefile with
  `CC="ccache gcc"`); the second invocation's container has no local
  on-disk ccache dir, so a reported hit there can only have come from
  Redis. Unrelated to and never referencing the maintainer's own real
  `CCACHE_REMOTE_STORAGE` repo secret (a private LAN Redis instance
  unreachable from GitHub-hosted runners). `docker/verify/README.md`
  documents pointing the published image at a user's own Redis instance at
  `docker run` time.
- **`docker/verify/Dockerfile`** (#264): added `dnsutils` (`dig`/`nslookup`/
  `host`) for diagnosing DNS resolution issues (a `DISTCC_HOSTS` entry, an
  `--allow` netrange, or a Redis remote-storage hostname that won't
  resolve). Gets a real functional build-time self-test (resolving the same
  Debian mirror host `apt-get install` already reached, not just a
  `--version` check), since DNS resolution only needs network access
  (already available to a `docker build` `RUN` step), unlike the
  ptrace-dependent tools above which need a runtime capability `docker
  build` can't grant.
- **`docker/verify/Dockerfile`/`docker/verify/selftest-ptrace.sh`** (#264):
  added `python3-dbg` (debug build + gdb helper macros) for debugging the
  Python-based include_server and its C extension
  (`include_server/c_extensions/`) together under `gdb` (`py-bt`/`py-list`).
  Gets a real functional runtime self-test in `selftest-ptrace.sh`: `gdb`
  launches `python3-dbg` as its own child (breaking on CPython's
  `time_sleep` C function, then running `py-bt`), checked for the actual
  Python frame name in the output, rather than an existence check --
  matching this script's existing gdb/strace/ltrace tests' "trace your own
  child" shape. An earlier version instead attached via `gdb -p <pid>` to
  an already-running sibling process and failed in real CI with "ptrace:
  Operation not permitted" even under `--cap-add=SYS_PTRACE`: Yama's
  default `ptrace_scope=1` only allows attaching to a process's own
  descendants (a sibling launched independently isn't one), so this was
  corrected to the same self-tracing shape used elsewhere in this script.
  `pdb` (Python's own built-in debugger) needs no extra package, already
  ships inside plain `python3`.
- **`.github/workflows/verify-image-build.yml`/`docker/verify/`** (#264):
  publish the verification/debug container to GHCR as
  `distcc-ng-buildtools:latest` (plus a short-SHA tag per publish) on every
  push to `current_dev` that touches `docker/verify/**`, and on manual
  `workflow_dispatch` — never from a pull request. Previously this image
  could only be built locally; pulling and starting the published image is
  now the entire setup step, matching issue #264's own "pre-built, fully
  self-contained" requirement. `docker/verify/README.md` updated with the
  pull instructions.
- **`src/dparent.c`** (#77, ported from upstream's still-open
  [distcc/distcc#468](https://github.com/distcc/distcc/pull/468)): set the
  daemon's Linux autogroup niceness (via `/proc/self/autogroup`) right after
  `setsid()` succeeds, Linux-only (`#ifdef HAVE_LINUX`). Without this, on an
  autogroup-enabled kernel `setsid()` allocates a fresh autogroup at
  niceness 0, which silently neutralizes the daemon's own `nice(2)` value
  across sessions (it only ranks the daemon's own tasks against each other,
  not against unrelated foreground sessions) — this makes the existing
  niceness setting actually take effect against other sessions on the
  host, as intended for a background compile-farm daemon. Unlike upstream
  PR #468's own diff, the autogroup value is read back via
  `getpriority(PRIO_PROCESS, 0)` **after** `main()`'s `nice(opt_niceness)`
  call, rather than reusing the raw `-N`/`--nice` option value directly:
  `-N` is documented as an increment on top of any inherited niceness, and
  `nice(2)` itself clamps the result to `[-20,19]`, so the raw option value
  can diverge from the daemon's real final niceness in either direction
  (`-N 20` clamps down to 19; an already-niced parent shell plus `-N 5`
  adds up to more than 5) — reading the actual post-clamp value avoids
  both cases structurally. Missing autogroup support (`ENOENT`, e.g. older
  kernels or `CONFIG_SCHED_AUTOGROUP=n`) is treated as expected and silent;
  any other failure is a non-fatal warning, matching the existing
  `nice(2)` failure handling in `daemon.c`.

- **`docker/verify/Dockerfile`, `docker/verify/selftest-ptrace.sh`,
  `docker/verify/README.md`, `.github/workflows/verify-image-build.yml`**
  (#273, refs #264): pre-built, fully self-contained build+debug+verification container
  image. Sized against Samba's real Debian `Build-Depends` (51 distinct
  packages vs. Apache httpd's 20 — Samba found to have the larger/more
  demanding dependency surface, see the issue #264 research comment),
  covering distcc-ng's own toolchain (`libpopt-dev`, `libavahi-client-dev`,
  `python3-dev`, `libzstd-dev`, `libseccomp-dev`, `ccache`, `gdb`), a
  Samba-sized library set (Kerberos, LDAP, GnuTLS, PAM, systemd, ICU, LMDB,
  Ceph/RADOS, io_uring, etc.), debug tools (`gdb`, `strace`, `ltrace`), a
  sanitizer/memory-debug toolchain (ASan/UBSan via gcc, `valgrind`),
  `binutils` (`objdump`/`readelf`/`nm`/`addr2line`), and search/inspection
  tools (`ripgrep`, `grep`, `less`). Every tool gets a real build-time (or,
  for the ptrace-dependent gdb/strace/ltrace, a separate runtime) functional
  self-test, not just an `apt-get install` exit-code check. Not yet
  published to GHCR — see the introducing PR for a sketched, not-yet-
  implemented publish-pipeline design.
- **`src/serve.c`** (#76): `tweak_arguments_for_server()` now also rewrites
  the `-ffile-prefix-map=`/`-fmacro-prefix-map=`/`-fdebug-prefix-map=`/
  `-fprofile-prefix-map=` compiler options' absolute `OLD` path, prepending
  the server-side mirror's `root_dir` the same way it already does for `-I`-
  style include options and the source file argument. Without this, a
  distributed compile using these reproducible-build flags never actually
  got the path substitution the client asked for, since the compiler on the
  server never saw a build path matching what these options declared as
  `OLD`. Ported directly from upstream's own open (unmerged) fix,
  distcc/distcc#459; added `GdbPrefixMap_Case` to `test/testdistcc.py` to
  cover it, adapted from the same upstream PR's test.
- **`test/e2e-full/`, `.github/workflows/nightly-publish.yml`** (refs #264):
  full bidirectional native-compatibility distributed-build E2E test,
  designed across issue #264's later comments — distinct from `test/e2e/`'s
  existing quick two-container check, which is unchanged. Two containers
  (a throwaway one built fresh from the checkout under test, and a stable
  one carrying Debian's own packaged `distcc`/`distcc-pump`, pinned to the
  same Debian release as `docker/release/Dockerfile`'s base image) exercise
  both directions (this fork's client against the native server, and the
  native client against this fork's server) in both plain and pump mode,
  building a real, substantial third-party project (Samba by default,
  Apache httpd present but flagged off via `WORKLOAD=apache`). Success is
  the server's own log showing at least as many real `COMPILE_OK` entries
  as the build actually produced object files for, with
  `DISTCC_FALLBACK=0` throughout. New `full_bidirectional_e2e` job in
  `nightly-publish.yml` (`workflow_dispatch`-only, targets whatever branch
  it's dispatched against — `current_dev` in real use), scoped to a bounded
  real Samba subset (`WAF_TARGETS`) to fit a GitHub-hosted runner's time
  budget; the full, unrestricted build is intended to run on the project's
  own Docker hosts (see `test/e2e-full/README.md`). A weekly schedule
  (Fridays 02:00 CET, Apache as the lighter workload) is written into the
  workflow but commented out, not armed, pending a separate decision.
  Verified for real on an independent Docker host (not WSL2): both images
  build, both plain-mode directions and both pump-mode directions each
  completed a real distributed compile with the server's own log showing
  the expected `COMPILE_OK` count — see the introducing PR for the full
  command/log evidence. Also found and worked around, empirically, two
  real snags along the way: Debian's `distcc-pump` needs an explicit
  `,cpp,lzo` `DISTCC_HOSTS` suffix (unlike this fork's own `pump` wrapper's
  issue #87 auto-append) and its own `--shutdown` handshake hangs under a
  non-interactive `docker exec` (reproducing this fork's own
  `support-upstream/issue-007-pump-fail-closed.md` finding), worked around
  with a bounded `timeout` since these containers are torn down after each
  run regardless.

### Fixed

- **`test/testdistcc.py`**: `PathSafety_Case` (the NAME/CDIR/LINK-target
  path-traversal unit tests, most recently extended in #290's fix for
  #95) was defined but never added to the top-level `tests` list that
  `make check`/a plain `testdistcc.py` run actually iterates over --
  found while implementing #292's follow-up fix. It could still be run
  directly by name (`onetest.py PathSafety_Case`), which is how earlier
  verification in this session appeared to pass, but a full `make check`
  silently never exercised it. Now registered; confirmed running (and
  passing) in both the non-pump and pump `make check` runs.
- **`include_server/setup.py`**: the include-server's separate Python
  C-extension build was showing both `-O2` and `-O3` on the same `gcc`
  invocation (#229's follow-up gap). `Makefile.in` forwards
  `CFLAGS="$(CFLAGS) $(PYTHON_CFLAGS)"` (now `-O3 ...`) into `setup.py`'s
  environment, but `setuptools`/`distutils`' own `customize_compiler()`
  *appends* that environment `CFLAGS` after Python's own sysconfig-baked
  default (`-O2` on every tested build) rather than replacing it — gcc's
  own "last flag wins" rule made the resulting build correct in practice,
  but left a confusing double-optimization-level line in the build log
  (confirmed live in real GitHub Actions runs of both `c-build.yml` and
  `package-release.yml` on `current_dev`). Fixed by patching
  `sysconfig.get_config_vars()`'s `CFLAGS`/`OPT`/`LDSHARED` entries (only
  the literal `-O2` substring, mirroring `configure.ac`'s own approach) at
  `setup.py` module-import time, before `setuptools.setup()` runs.
  Verified against the actual CPython/setuptools versions this project's
  CI uses (Python 3.11/3.12, setuptools' vendored `_distutils`), and that
  the built extension still passes its own functional test
  (`include_server/c_extensions_test.py`).

### Fixed

- **`src/compile.c`** (#281, refs #78): `dcc_add_clang_target()` and
  `dcc_gcc_rewrite_fqn()` now match the compiler's *basename*
  (`dcc_find_basename(argv[0])`) instead of comparing `argv[0]` directly,
  so cross-compilation auto-detection (clang's `-target` flag, gcc's
  fully-qualified-name rewrite) now fires when the compiler is invoked by
  a full or relative path (e.g. `/usr/bin/gcc-11`, `/usr/bin/clang-19`),
  not only by a bare `$PATH` name. `dcc_gcc_rewrite_fqn()`'s rewritten
  command name is now also built from the basename, fixing a related bug
  where it previously would have embedded the caller's full original path
  into the new command name. Ported and independently re-verified against
  upstream's own open, unmerged distcc/distcc#491.

### Security

- **`src/srvrpc.c`, `src/bulk.c`** (#293, refs #292, #95): close the
  server-side path-traversal write-escape in `distccd`'s multi-file receive
  (`dcc_r_many_files()`) that #95's string check could not reach. A malicious
  client could send one `NFIL` batch whose first entry creates a symlink at a
  chosen `NAME` (with a relative, deliberately unvalidated `LINK` target) and
  whose second entry's `NAME` is nested under that symlink; the old
  plain-string `mkdir()`/`open()`/`symlink()` calls transparently followed the
  intermediate symlink, letting the write land anywhere `distccd` could write
  (CWE-59). Neither `NAME` contains `..`, so `dcc_name_has_path_traversal()`
  never saw it. `dcc_r_many_files()` now opens the job directory once and
  resolves every `NAME` component-by-component relative to that fd with
  `O_NOFOLLOW` throughout (new `dcc_open_parent_beneath()`), rejecting any
  intermediate component that resolves to a symlink or non-directory with
  `EXIT_PROTOCOL_ERROR`; the `FILE` leaf is created with
  `openat(..., O_NOFOLLOW)` (new `dcc_r_file_beneath()`, preserving the
  binutils-compat unlink-first-if-non-empty behaviour via `fstatat`/`unlinkat`)
  and the `LINK` leaf with `symlinkat()`. Legitimate pump mirroring is
  unaffected — `include_server/mirror_path.py` never nests a later entry
  beneath a symlink it created in the same batch. A new `h_srvrpc` test harness
  drives the real `dcc_r_many_files()` with the exact malicious sequence as an
  end-to-end regression test. Also adds `distccd --job-file-mode MODE`
  (octal, default `0600`): permission bits for these per-job input files.
  They're created and later read by the same daemon process/uid throughout
  a job's lifetime (`dcc_discard_root()` only ever runs once, at startup,
  before any connection is accepted), so `0600` is sufficient by default;
  configurable (e.g. `0660`) for sites that want an operator in the same
  group to inspect a running job's files. `dcc_r_many_files()`/
  `dcc_r_file_beneath()` take the mode as a parameter rather than reading
  the global directly, since `src/srvrpc.c`/`src/bulk.c` are also linked
  into the `distcc` client binary and, separately, into the include-server's
  own Python C extension (`include_server/setup.py`) — neither links
  `src/dopt.c` (distccd-only option parsing). Verified for real (not just
  reasoned about): with `--job-file-mode=0600`, files created on disk
  actually show `600`, confirmed via `stat` on a real host before this was
  made the default.
- **`src/srvrpc.c`/`src/pathsafety.c`** (#95): reject an absolute-style LINK
  token's `link_target` containing a `..` path component in
  `dcc_r_many_files()`, closing a server-side arbitrary-file-write primitive:
  a malicious distcc client could previously send a `LINK` token whose target
  escaped the server's per-job temp directory once concatenated with it (the
  same risk already guarded against for `NAME` tokens, but not for
  `link_target`). Partial fix — a *relative* `link_target` is deliberately
  left unvalidated, since the include-server's own legitimate mirroring
  symlinks (`_MakeLinkFromMirrorToRealLocation()`) use the identical
  "leading `../` run + clean remainder" shape an attacker-supplied one would,
  so a text-only check can't distinguish them. That residual case turned out
  to be independently exploitable without any absolute or otherwise
  suspicious `link_target` at all (a relative-target `LINK` plus a nested
  `NAME`/`FILE` sequence bypasses ordinary path-component symlink following
  in `mkdir()`/`open()`) -- tracked as its own fix in #292, not this partial
  string check, with #289's containment boundary remaining valuable as
  separate defense-in-depth.
- **`src/serve.c`** (found while reviewing #95/#292): capture
  `dcc_r_many_files()`/`dcc_set_output()`/`tweak_arguments_for_server()`'s
  return values into `ret` in `dcc_run_job()`'s multi-file branch instead of
  only using them for `||`-chain truthiness. A rejection (e.g.
  `dcc_r_many_files()`'s `EXIT_PROTOCOL_ERROR`) still aborted the connection
  correctly either way, but `ret` was left at its prior successful value,
  so `out_cleanup`'s `switch(ret)` misclassified the job in stats (fell to
  the default case instead of `STATS_REJ_BAD_REQ`) and the function itself
  reported success. Monitoring-visibility bug, not a security bypass.
- **`.github/workflows/{actionlint,c-build,changelog-update-on-release,codeql}.yml`**
  (#267): pin the remaining 12 action references still using mutable
  version tags (`actions/checkout@v7`, `actions/cache@v4`,
  `actions/attest-build-provenance@v4`, `github/codeql-action/{init,analyze}@v3`)
  to full 40-character commit SHAs, found via a repo-wide re-sweep after
  PR #270's pass missed these (Scorecard's own scan apparently doesn't
  flag every occurrence of an already-partially-pinned action). All 15
  distinct actions used anywhere in this repo are now SHA-pinned; verified
  each SHA by dereferencing the real tag ref live via the GitHub API (not
  assumed from memory), including correctly handling annotated tags whose
  `git/refs/tags/<tag>` response points at the tag *object*, not the
  commit (a mistake PR #270 itself made twice before being caught in
  review — see that PR's history).
- **`src/compile.c`** (#268): eliminate the stat-then-open TOCTOU pattern in
  `dcc_fresh_dependency_exists()` (CodeQL alert #3, `cpp/toctou-race-condition`).
  #256/#257 already fixed this alert's *consequence* (a 1-byte heap NUL
  overflow reachable if the `.d` file grew between the `stat()` and the
  read), but the flagged pattern itself — a `stat(dotd_fname, ...)` followed
  by a separate `fopen(dotd_fname, "r")`, two syscalls that can each
  independently resolve the same path to a different underlying file —
  remained. Restructured to `fopen()` first, then `fstat(fileno(fp), ...)`
  on the already-open descriptor (already idiomatic in this codebase, see
  `src/config-parser.c`), so the freshness/size check and the subsequent
  read are guaranteed to describe the exact same open file. No behavioral
  change for any existing caller.
- **GitHub Actions and base-image references pinned to commit SHAs** (#267):
  all `.github/workflows/*.yml` steps now use full 40-character commit SHAs
  (`actions/checkout@9c091bb... # v7`) instead of mutable version tags
  (`v7`), addressing OSSF Scorecard's `PinnedDependenciesID` finding (18
  Action references). Docker base images in Dockerfiles remain unpinned due
  to unavailability of registry digest lookup in this environment; those will
  be addressed in a follow-up.

### Fixed

- **`include_server/setup.py`**: the include-server's separate Python
  C-extension build was showing both `-O2` and `-O3` on the same `gcc`
  invocation (#229's follow-up gap). `Makefile.in` forwards
  `CFLAGS="$(CFLAGS) $(PYTHON_CFLAGS)"` (now `-O3 ...`) into `setup.py`'s
  environment, but `setuptools`/`distutils`' own `customize_compiler()`
  *appends* that environment `CFLAGS` after Python's own sysconfig-baked
  default (`-O2` on every tested build) rather than replacing it — gcc's
  own "last flag wins" rule made the resulting build correct in practice,
  but left a confusing double-optimization-level line in the build log
  (confirmed live in real GitHub Actions runs of both `c-build.yml` and
  `package-release.yml` on `current_dev`). Fixed by patching
  `sysconfig.get_config_vars()`'s `CFLAGS`/`OPT`/`LDSHARED` entries (only
  the literal `-O2` substring, mirroring `configure.ac`'s own approach) at
  `setup.py` module-import time, before `setuptools.setup()` runs.
  Verified against the actual CPython/setuptools versions this project's
  CI uses (Python 3.11/3.12, setuptools' vendored `_distutils`), and that
  the built extension still passes its own functional test
  (`include_server/c_extensions_test.py`).

### Changed

- **Default build optimization level raised from `-O2` to `-O3`, everywhere**
  (dev builds, CI, and packaged releases alike), not just a release-only
  build path (#229). `-O2` was never an explicit setting in this repo's own
  build files — it came from autoconf's `AC_PROG_CC` default (`-g -O2` when
  the caller hadn't already set `CFLAGS`); `configure.ac` now rewrites that
  default's `-O2` to `-O3` right after `AC_PROG_CC`, leaving an explicit
  caller-supplied `CFLAGS` (e.g. `CFLAGS=-O1 ...`) untouched. Verified with
  a real side-by-side comparison: both optimization levels build clean with
  zero new `-Werror` warnings, `make check` passes identically at both
  (same pass count, same wall time), a full AddressSanitizer/UndefinedBehaviorSanitizer
  run found no UB or leak difference between the two levels (the one real,
  pre-existing latent-UB finding it surfaced, `src/cleanup.c`'s
  zero-length `memcpy` from a still-`NULL` pointer, is identical under
  both), compile-time overhead is within run-to-run noise for this
  codebase's size, and a real distributed-compile benchmark (real
  `distcc`/`distccd` pair, real network hop, verified via the daemon's own
  log) showed no meaningful runtime win either way -- expected, since
  distcc/distccd's own runtime is dominated by network I/O rather than the
  CPU work `-O3` optimizes.
- **`docker/release/Dockerfile`, `packaging/RedHat/rpm.spec`**: aligned the
  `distcc` service user's lifecycle with Debian's own real `distcc`
  package (verified live on a host running it, 2026-07-22). The Docker
  image's `useradd` no longer creates a home directory (`--no-create-home
  --home-dir /nonexistent`, matching Debian's own `adduser --system --home
  /nonexistent --no-create-home`) — the unprivileged daemon process never
  needs a writable home. The RPM spec's `%postun` no longer deletes the
  `distcc` user/group on Debian-based purge (`deluser`/`delgroup`
  removed): Debian's own package's `postrm` never does this either (it
  removes `/etc/default/distcc`, log files, and the pid file on purge, but
  keeps the system user), so this fork has no reason to be stricter than
  the package it forked from.

### Fixed

- **`src/arg.c`** (#280): `dcc_resolve_march_native()` now execs the
  actually-invoked compiler binary (`argv[0]` unchanged) instead of a
  basename stripped from it and re-resolved via a fresh `PATH` search.
  Previously, an explicit compiler path (e.g. `distcc /opt/x/cc ...`, or a
  masquerade symlink already resolved to one) was reduced to its basename
  before `execlp()`, which could silently exec a *different* binary than
  the one actually invoked, or fail to resolve at all if that basename
  wasn't separately on `PATH` -- either way, `-march=native` silently fell
  back to a local-only compile instead of distributing. `is_clang` family
  detection itself was already correct (fixed via #245); only the exec
  target was still basename-only. Added a targeted regression test
  (`MarchNativeDispatcherPath_Case` in `test/testdistcc.py`) using a
  non-"clang"-named dispatcher script at an explicit, not-on-`PATH`
  location; verified both in the test suite and via a real two-host
  distributed compile (separate client/server hosts), confirming a
  `COMPILE_OK` entry in the server's own independent log both times, and
  confirming the pre-fix code silently compiled locally with zero server
  log activity for the identical command.
- **`Makefile.in`** (#280): removed a duplicate `h_dopt@EXEEXT@:` target
  recipe (one of two identical, back-to-back definitions), which was
  making every clean build emit a spurious GNU make "overriding recipe for
  target" warning.
- **`.github/workflows/release-drafter.yml`** (#280): added
  `pull-requests: read` to the `update_release_draft` job's permissions
  block, which had been overridden down to `contents: write` only by the
  job-level block -- Release Drafter needs read access to merged-PR
  metadata to build its draft notes.
- **`.github/workflows/scorecard.yml`** (#280): added `contents: read` to
  the `analysis` job's permissions block, which had replaced the
  workflow-level `read-all` with `security-events: write` and
  `id-token: write` only, leaving `actions/checkout` without read access
  on a token-scope-enforcing repo.
- **`.github/workflows/package-release.yml`** (#280): the arm64 container
  matrix leg is documented as best-effort but had no `continue-on-error`,
  so `fail-fast: false` alone did not stop an arm64 failure from blocking
  the release-gating jobs downstream (`publish_manifest`,
  `publish_github_release`). Added `continue-on-error` scoped to the arm64
  leg, and made the multi-arch manifest step probe the registry for the
  arm64 tag first, falling back to an amd64-only manifest rather than
  failing the whole release when the best-effort arch is unavailable.

### Security

- **`.github/workflows/nightly-publish.yml`** (#280): added
  `--repo wiki-mod/distcc-ng` to the three `gh release` invocations
  (`view`/`delete`/`create`) in the tag-move-and-republish step, which were
  previously relying on `gh`'s ambient default-repo resolution -- per
  AGENTS.md rule 18, every `gh` command in this repo must pass `--repo`
  explicitly to prevent it from ever targeting the wrong repository.

### Removed

- **`doc/web/`**: deleted the old, conserved upstream distcc project
  website (index/FAQ/benchmark/results/scenarios/security pages, man-page
  HTML mirrors, and static assets) — historical project marketing/docs
  content this fork doesn't maintain or serve.

- **`Makefile.in`'s `man-html`/`upload-man`/`upload-dist` targets,
  `packaging/googlecode_upload.py`**: dead maintainer-only upstream
  tooling found while removing `doc/web/` — `man-html`/`upload-man`
  directly wrote into (and `svn commit`'d) the now-deleted
  `doc/web/man/`, and `upload-dist` called `googlecode_upload.py` to
  upload release tarballs to Google Code, which shut down in 2016. None
  of this fork's own release process (`.github/workflows/package-release.yml`,
  GHCR) uses any of it.

## [3.6.0-NG] - 2026-07-19

### Security

- **`src/compile.c`** (#256): fix a 1-byte heap NUL overflow in
  `dcc_fresh_dependency_exists()` (`cpp/toctou-race-condition`, CodeQL alert
  #3). `dep_name` was allocated with exactly the `.d` file's `stat()`-time
  size, but the dependency-name copy loop's terminator write
  (`dep_name[i] = '\0'`) is not itself bounds-checked against that size —
  only the content-byte writes are. If the `.d` file grows between the
  `stat()` and the read (a real TOCTOU window, not a hypothetical one), `i`
  can reach the buffer size and the terminator write lands one byte past
  the allocation. Fixed with `malloc(dotd_fname_size + 1)`, reserving the
  terminator slot so every `i` the loop can produce stays in-bounds — no
  behavioral change otherwise. Client-only (`compile.o` is never linked
  into `distccd`), low severity (requires local write access to the `.d`
  file within the race window), but a genuine memory-safety defect.
  Verified with a clean `-Werror` build, the full `make check` suite, and
  an AddressSanitizer build with a `stat()`-interposed harness that
  deterministically forces the race (undersized `stat()` result vs. the
  file's real on-disk content) — heap-buffer-overflow before the fix,
  clean after.
- **`.github/workflows/`** (#222): supply-chain hardening of the CI workflow
  files flagged by CodeQL. Pinned the five unpinned third-party action refs
  to a full commit SHA with a `# vX.Y.Z` comment, matching this repo's own
  existing pinning convention (`ConorMacBride/install-package@v1` in
  `c-build.yml` and twice in `package-release.yml`;
  `stefanzweifel/changelog-updater-action@v1` and
  `stefanzweifel/git-auto-commit-action@v5` in
  `changelog-update-on-release.yml`) — clears the six `actions/unpinned-tag`
  alerts (#40/#44/#45/#46/#48). Added a minimal `permissions: {contents:
  read}` block to `c-build.yml`'s `distributed_e2e` job (it only reads the
  repo and runs a local e2e script), clearing the
  `actions/missing-workflow-permissions` alert (#74). GitHub-owned
  `actions/*` and `github/codeql-action/*` refs are intentionally left on
  their major-version tags — CodeQL does not flag them and the repo already
  treats them as trusted first-party.
- **`src/ssh.c`** (#143, Group H): sanity-check the resolved SSH transport
  command before it becomes `argv[0]` to `execvp()`
  (`cpp/uncontrolled-process-operation`, CodeQL high, alert #10). A new
  `dcc_ssh_cmd_is_sane()` helper, called in `dcc_ssh_connect()` before
  fork/exec, rejects an empty command token or one beginning with `-` (an
  obviously-malformed value such as `-oProxyCommand=…`), returning a clean
  `EXIT_DISTCC_FAILED` instead of failing deep inside the forked child.
  This is client-side hardening (`ssh.o` is linked into `distcc` only, runs
  as the invoking user, no privilege boundary): deliberately **not** an
  absolute-path requirement — `execvp()`'s own `$PATH` search is atomic at
  exec time (no TOCTOU window, unlike the `compile.c` pre-resolve path), and
  a bare `DISTCC_SSH="ssh"` relying on that search is the intended usage.
  Verified against the real client binary: the rejection path fires with a
  clear error, while `DISTCC_SSH="ssh"` and whitespace-only values behave
  exactly as before.
- **`src/lsdistcc.c`, `src/climasq.c`** (#143): eliminate unbounded
  `sprintf` writes from caller-controlled input (`cpp/unbounded-write`,
  CodeQL critical). `lsdistcc`'s `generate_query()` formatted the `-p`
  compiler-name argument into the fixed `char canned_query[1000]` global
  with `sprintf` — a real overflow with a long compiler name; now
  `snprintf(…, sizeof …)` with an added bounds guard on the following binary
  `memcpy` (protocol 2/3). The masquerade `sprintf(buf + len, "/%s", …)`
  idiom in `dcc_support_masquerade()` (climasq.c) is made explicitly bounded
  with `snprintf`. Verified with an AddressSanitizer before/after overflow
  reproduction, the full `make check` suite, and a real masquerade-symlink
  distributed compile (Apache httpd, local + LAN hosts, plain and pump).

- **`src/util.c`** (#143): defence-in-depth for two `cpp/missing-check-scanf`
  CodeQL alerts (Group G) in `dcc_get_proc_meminfo_mem_available()` and
  `dcc_get_disk_io_stats()`. Independent control-flow analysis confirmed both
  are false positives — the flagged reads are guarded by the `(f)scanf`
  return check on every reachable path — so this is not a fix for a reachable
  bug. The flagged locals (`value`/`unit`, `minor`/`dev`) are now initialised
  at declaration with WHY-comments, keeping the functions safe against a
  future refactor of the guard and silencing the analysis-confirmed false
  positives. No behavioural change.

### Fixed

- **`src/strip.c`, `src/arg.c`** (#246): a token introduced by `-Xclang`
  is now treated as opaque clang cc1 payload by every argv scanner that
  sees the resolved argv — passed through verbatim by
  `dcc_strip_local_args()` and `dcc_strip_dasho()`, skipped by
  `dcc_scan_args()` (server re-scan + pump mode) — instead of being
  matched against distcc's own flag-prefix tests. The `-march=native`
  clang resolution (#73/#175)
  emits `-Xclang -target-feature -Xclang <value>` quadruples, and the
  disable values `-lwp`/`-xop` (present on any modern non-Bulldozer CPU)
  collided with `dcc_strip_local_args()`'s `-l<lib>`/`-x<lang>` strip
  prefixes and were silently dropped client-side, turning the quadruple
  into a malformed triple the remote clang rejected with
  `COMPILE_ERROR`. The same value, once transmitted, also tripped
  `dcc_scan_args()`'s `-x` check on the server (which re-scans a received
  argv with no native flag, so it has no ignore-range protection).
  Verified end-to-end with a real two-container and a real
  two-physical-host distributed clang `-march=native` compile
  (server-log `COMPILE_OK`), plus new `StripArgs_Case` regression cases;
  gcc `-march=native` (bare `-m*` tokens, never `-Xclang`-wrapped)
  confirmed unaffected.
- **`src/strip.c`** (#79): `dcc_strip_local_args()` now strips the `-x`
  flag (both `-x <lang>` and combined `-xc++`-style forms) before
  sending an already-preprocessed compile (`.ii`/`.mi`/`.mii`) to a
  remote host. GCC honors an explicit `-x` override over the input
  file's embedded `#line` directives, which corrupted DWARF debug info
  — confirmed via a real before/after `readelf --debug-dump=info`
  comparison: with `-x` present, the compile unit's `DW_AT_name` was the
  ephemeral remote temp path (e.g. `distccd_12345.ii`); with it
  stripped, `DW_AT_name` is the real original source path. Ported from
  upstream distcc/distcc#577.
- **`src/arg.c`, `src/compile.c`** (#227): compiler family (gcc vs.
  clang) was trusted from `argv[0]`'s basename alone in three places,
  misclassifying a dispatcher (e.g. macOS's `cc`) invoked under a name
  that says nothing about which compiler it actually runs.
  `dcc_resolve_march_native()`'s `is_clang` detection now reads the
  actual `-cc1` backend invocation its existing `-v -E` probe already
  captures instead of guessing from the name; the same function's
  GCC-branch token filter now keeps only the resolved `-m*` flags
  instead of forwarding every driver-internal token unfiltered; and
  `dcc_rewrite_generic_compiler()`'s non-symlink dispatcher case (a
  long-standing `TODO`) is completed with a new `dcc_probe_is_clang()`
  helper that asks the binary itself via `--version`. Verified end-to-end
  against real gcc/clang across a real two-container network hop and
  against an independently-built stock `distcc`/`distccd`.

### Added

- **`doc/verification-checklist.md` section 7**: input/argument
  validation checklist (CLI argument parsing, config value parsing,
  format strings) — prompted by issue #226's `lsdistcc` format-string
  fix having no matching section to verify against. Cleanup renumbered
  from section 7 to section 8.
- **`AGENTS.md` rule 60**: a delegated agent doing non-trivial work must post
  a dated progress comment on its issue/PR at least every 5 minutes of
  active work, not only at real milestones (extends rule 10) — a
  heartbeat when there's no new finding yet, rather than staying silent
  through a long-running build/test step.
- **`/etc/distcc/distcc.conf`** (#207): new client-side config file, sharing
  the same `key = value` parser as the daemon's config (now factored out
  into `src/config-parser.c`). First setting: `local-lto` (bool, default
  `false`) — controls whether `-flto`/`-flto=` compiler invocations are
  forced local-only (this fork's prior #74/#204 behavior) or distributed
  normally (upstream's current, evidence-based default — see
  `support-upstream/issue-074-lto-distribution-revert.md`). Overridable
  per-invocation via `DISTCC_LOCAL_LTO`, which takes precedence over the
  file in both directions.
- **`/etc/distcc/distccd.conf`** (#207): renamed from
  `/etc/distcc/seccomp.conf` now that a second, non-seccomp daemon
  setting exists conceptually (even though this specific PR only touches
  the client side) — no back-compat shim, since no real deployment of
  the old name predates this rename.

- **`doc/verification-checklist.md`**: a reusable checklist template for
  recording what was actually checked before a change lands, covering
  permission/file-mode changes, sandbox/seccomp changes, distribution/
  scheduling behavior changes, external-host compatibility, downloaded-
  artifact integrity, and cleanup — each with concrete "what counts as
  real evidence" bullet points, not just "make check passed". `AGENTS.md`
  rule 37 now points changes in these areas at it. (#202)
- **`doc/verification-checklist.md` section 4**: now requires both
  directions of the default-vs-fork compatibility matrix, not just one —
  a real independently-built `distccd` against our client (already
  required) *and* a real independently-built `distcc` against our
  `distccd` (previously missing). Prompted by #225, which turned out to
  be exactly this shape of one-directional-tested-but-broken-the-other-
  way bug. (#232)
- **`src/arg.c`: skip distributing `-flto`/`-flto=`-style compiler invocations**
  (#74) — LTO defers the bulk of the optimization work to link time, so
  distributing the per-translation-unit compile step wastes network/
  scheduling overhead for no benefit, and some LTO intermediate
  representations aren't valid standalone object files, so a remote
  invocation could produce an unusable result. `dcc_scan_args()` now
  recognizes `-flto` and `-flto=<value>` alongside the existing
  `-march=native`/`-mtune=native` local-fallback checks and routes these
  invocations to local-only compilation instead of attempting a remote
  dispatch. Ports upstream distcc/distcc#413.

### Security

- **Three locally-reproducible logic bugs found in a security sweep**
  (#226): `src/sandbox-seccomp.c`'s built-in-denylist loop stored
  `dcc_seccomp_resolve()`'s return value uncritically, unlike the
  `extra_deny` loop 15 lines below in the same function — an
  unresolvable built-in syscall name reached `seccomp_rule_add(...,
  -1, ...)`, breaking seccomp setup for every compile instead of just
  skipping that one syscall; now warns and skips, mirroring the
  existing `extra_deny` guard. `src/lsdistcc.c`'s `get_thename()` only
  checked that its caller-supplied format string contained `%d`
  somewhere before passing it to `snprintf()` as the format argument —
  a format like `%d%s%s%s%n` passed that guard and then read/wrote out
  of bounds processing specifiers with no corresponding arguments; now
  rejected unless it contains exactly one integer conversion and no
  other `%` specifier. `src/serve.c`'s `-specs=` argument loop called
  `alloca()` once per matching argument — `alloca()`'s allocation is
  only freed when the enclosing function returns, not each loop
  iteration, so a compile command with many `-specs=` arguments
  accumulated unbounded, unfreed stack allocations; now uses
  `malloc()`/`free()`, freed each iteration. Verified with real
  before/after evidence per bug: an injected unresolvable syscall name
  now logs one startup warning instead of refusing every compile; an
  AddressSanitizer-instrumented pre-fix `lsdistcc` crashes (SEGV) on a
  crafted format string that the post-fix binary rejects cleanly; a
  real compile with 3000 `-specs=` arguments against a
  stack-limited `distccd` crashed the worker (signal 11) before the fix
  and completed cleanly (`sig:0 core:0`) after. `make check` passes
  with all three fixes applied together.

- **Protocol version 4 (zstd) could silently misconfigure a non-zstd
  `distccd`** (#225): `src/hosts.c`'s `dcc_get_features_from_protover()`
  mapped protover 4 to `DCC_COMPRESS_ZSTD` unconditionally, regardless of
  whether the running binary actually has zstd support compiled in. A peer
  claiming protover 4 against a non-zstd build could reach
  `src/bulk.c`'s send path with an uninitialized buffer (sibling of #224's
  finding), and separately `src/serve.c` never checked this function's own
  return value, so its existing rejection paths had no real effect on the
  connection. Fixed by rejecting protover 4 outright under `#ifndef
  HAVE_ZSTD` (a silent fallback to a different compression wasn't a safe
  option either -- LZO and zstd use different wire token formats, and the
  client commits to one before the server could object) plus making
  `serve.c` actually check and act on the rejection, plus a defense-in-depth
  fallback directly in `bulk.c`. Verified with a real zstd-capable client
  against a real `--without-zstd`-built `distccd`: now rejected immediately
  (`time:0ms`) with a clear log message, before any argv or file data is
  exchanged. `make check` passes with zero regressions on both
  `--without-zstd` and normal zstd-enabled builds.

- **Unbounded allocation size from wire-protocol input** (#224): `src/rpc.c`'s
  `dcc_r_str_alloc()` (backing every string field read off the network --
  every `argv[i]`, filename, symlink target) and `dcc_r_argv()`'s argument
  count had no upper bound before allocating, letting a corrupted or hostile
  peer claim an arbitrary length/count and force an unbounded
  `malloc()`/`calloc()`. Propagated into `src/compress-zstd.c`'s and
  `src/compress-lzox1.c`'s bulk-transfer receivers (same missing bound on
  `in_len`/`uncompr_size`), including a wrap-to-zero-then-infinite-retry-loop
  edge case in the zstd path and a 32-bit multiplication overflow in the LZO
  path's output-size estimate (`8 * in_len`, previously flagged with its own
  "make sure this doesn't overflow" FIXME comment). Fixed with three new
  sanity ceilings (`DCC_MAX_RPC_STRING_LEN` 16 MiB, `DCC_MAX_RPC_ARGC` 65536,
  `DCC_MAX_BULK_FILE_LEN` 1 GiB -- generous enough that no legitimate request
  is ever affected) plus fixing `dcc_r_str_alloc()`'s pre-existing
  unchecked-`malloc()`-failure bug found while touching the same function.
  Verified with a real before/after crafted-protocol test against two
  parallel-built `distccd` instances: an oversized `ARGC` claim that
  previously either raced glibc's own `calloc()` overflow check or held a
  worker + ~800MB allocated for the life of the connection is now rejected
  in under a millisecond with a clear log message, with zero regression on
  `make check`'s real large-file (`BigAssFile_Case`) and compressed-compile
  (`CompressedCompile_Case`) tests. Confirmed still present in
  `distcc/distcc`'s current upstream source (`src/rpc.c`, `src/compress.c`)
  -- see `support-upstream/issue-224-unbounded-rpc-allocation.md`.

- Fixed 8 of 11 `cpp/world-writable-file-creation` CodeQL alerts
  (`src/daemon.c`, `src/dparent.c`, `src/compile.c`, `src/dotd.c`,
  `src/state.c`, `src/zeroconf.c`) by replacing hardcoded `0666` `open()`
  modes with explicit least-privilege modes (`0664` for the daemon's own
  log file — kept world-*readable*, since it's routinely read by
  operators/monitoring tooling on a shared build host, matching what the
  RPM/deb packaging's postinstall script already sets up; only the
  world-*write* bit, the actual CodeQL complaint, is dropped — `0600` for
  files with no legitimate external reader, or `0644` for files read
  cross-user by design: the daemon's pid file, the process state
  directory read by `distccmon-*`, and zeroconf's discovered-host file),
  and by switching two `fopen()`-based file creations (which always create
  at the umask-modified `0666` default) to `open()`+`fdopen()` with an
  explicit mode. Three instances deliberately left unchanged, each with a
  documented reason rather than silently tightened: `src/lock.c`'s
  lock-slot file (shared, multi-user `DISTCC_DIR`/lock-directory support),
  `src/bulk.c`'s received-compile-output file (must match local-compile
  permissions — `test/testdistcc.py`'s `ModeBits_Case` asserts this), and
  `src/traceenv.c`'s trace-env file (same "don't tighten without a concrete
  reason" reasoning). (#157)

### Fixed

- **Release packages built without zstd support** (#234): `scripts/build-release-packages.sh`
  explicitly passed `--without-zstd` to `configure` (adopted from an older
  workflow via #44, predating zstd being a maintained fork feature, never
  revisited), and even without that flag, `package-release.yml`'s
  `build_packages` job and `nightly-publish.yml`'s `publish` job never
  installed `libzstd-dev`, so auto-detection would have silently degraded
  anyway. `docker/release/Dockerfile` had the identical problem (missing
  `libzstd-dev` at build time and `libzstd1` at runtime, plus a stale image
  label literally documenting "without zstd support"). Fixed all four sites;
  verified by extracting the real built `.deb` package and confirming
  `distccd` is actually linked against `libzstd.so.1`.
- **`Makefile.in`: `config-parser.c`/`.h` and `client-config.c`/`.h` missing
  from `SRC`/`HEADERS`** (#220): these two files (added by #207/#208) were
  correctly listed in the `common_obj`/`distcc_obj` build-object lists used
  by the normal `make` build, but never added to the `SRC`/`HEADERS`
  variables `make dist` uses to build the source tarball packaging consumes.
  `./configure && make && make check` (what CI runs) built fine regardless,
  but any downstream RPM/deb/nightly build extracting and rebuilding from
  the `make dist` tarball failed with `client-config.h: No such file or
  directory` — discovered via a real nightly-publish run failing on
  `master` right after #201 merged.
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

- **Nightly container image moved to its own package**, `distcc-ng-nightly:latest`
  (#199), instead of a `:nightly` tag on the same `distcc-ng` package used for
  real, versioned releases. Keeps the unstable rolling nightly build clearly
  separated from tagged releases. The `nightly` git tag and the "distcc-ng
  nightly" GitHub pre-release are unaffected — only the container image's
  package name changed.

### Fixed

- **`distccd` kept warning about the masquerade whitelist even when
  `DISTCC_CMDLIST` was already set** (#75): `dcc_warn_masquerade_whitelist()`
  (`src/daemon.c`) always emitted its "set up masquerade or pass
  --enable-tcp-insecure" warning, regardless of whether the operator had
  already opted in via `DISTCC_CMDLIST` — a documented, explicit whitelist
  env var (see `dcc_remap_compiler()` in `src/serve.c`) that makes an empty
  masquerade directory expected, not a misconfiguration. The warning now
  returns early when `DISTCC_CMDLIST` is set, and mentions the variable in
  its text for operators who haven't set it yet. Ports upstream
  distcc/distcc#445.

- **Flaky `Compile_c_Case` test race under CI load** (#196):
  `test/testdistcc.py`'s `Compile_c_Case.runtest()` computed its
  `dcc_fresh_dependency_exists()` reference timestamp as `time.time() + 1`
  and passed it to the C test harness via `"%i"` string formatting, which
  silently truncates the float towards zero rather than rounding — shrinking
  the intended one-second safety margin. Under CI load (this suite runs
  twice per job: once for `make check`, once for
  `maintainer-check-no-set-path`), scheduling jitter could occasionally
  close that margin enough for the `.d` test file's real mtime to land at
  or below the truncated reference time, tripping
  `dcc_fresh_dependency_exists()`'s legitimate "old dotd file" trace line.
  `getDep()`'s caller then blindly asserted every non-blank stderr line
  matched the `"Checking dependency: ..."` pattern, turning that legitimate
  trace line into a hard test failure. Fixed both angles: `time_ref` is now
  computed as an already-rounded integer with a 2-second margin (polling the
  busy-wait at 0.1s instead of 1s granularity, removing the truncation
  surprise and adding real headroom), and the stderr-parsing loop now only
  feeds lines containing `"Checking dependency:"` to `getDep()`, instead of
  every non-blank line.

- **`pump.in`'s `ShutDown()` could misjudge a zombie include-server process as
  still running** (#71), because it only checked liveness with `ps -p PID`,
  which reports true for a zombie ('Z' state) process too. A zombie can never
  receive or act on another signal and won't actually be reaped until this
  script itself exits, so the old check could waste a full SIGTERM-then-SIGKILL
  escalation cycle waiting on a process that will never respond again (in the
  worst case, deadlocking a caller that itself waits on this script to exit
  before reaping the zombie). Added an `IncludeServerAlive()` helper that also
  checks `ps -o state=` for `Z` and treats a zombie as already gone. The
  `-o state=` header-suppression syntax (as opposed to GNU-only `--no-headers`)
  is honored by both GNU procps and BSD/macOS `ps`, and falls back to the
  previous behavior if the state check can't be read for any reason. Ported
  from upstream distcc/distcc#324.

### Security

- Fixed 6 `cpp/path-injection` CodeQL alerts (`src/compile.c`, `src/serve.c`,
  `src/srvrpc.c`, `src/traceenv.c`) by validating environment-variable-derived
  filenames (`DEPENDENCIES_OUTPUT`/`-MF`, the `INCLUDE_SERVER_PORT`-derived
  discrepancy filename, `DISTCC_CMDLIST`, `DISTCC_LOG`) with a new
  `dcc_sane_env_path()` helper before they reach `open()`/`fopen()`, rejecting
  empty, oversized, or control-character-laden values. The `src/srvrpc.c:158`
  instance was already resolved by the earlier `dcc_name_has_path_traversal()`
  fix (#93/#94) and needed no further change. `src/traceenv.c`'s log-file
  `open()` call keeps its long-standing `0666` mode unchanged (maintainer
  call: not tightening permissions that have worked this way for 25+ years
  without a concrete reason, same principle as `src/lock.c`, see #157/#159)
  — the accompanying `cpp/world-writable-file-creation` alert on that line
  is intentionally left open, not fixed by this change. (#151)

### Added

- **`support-upstream/` folder** (#184) — passive, read-only documentation of
  real bugs found in this fork's work that also affect upstream
  distcc/distcc's own independently-maintained source. Since this fork
  cannot open issues/PRs against upstream (upstream doesn't accept
  AI-assisted contributions), each entry cites the exact upstream file:line,
  before/after code, and empirical verification evidence for an upstream
  maintainer to read if they ever choose to. First entry documents issue #12
  (weak temp-file name entropy in `dcc_make_tmpnam`), confirmed still
  present in upstream's live source.
- **CI: `step-security/harden-runner` added as the first step of every job in
  `c-build.yml` and `package-release.yml`**, in `egress-policy: audit` mode
  (log-only, blocks nothing) (#58). It monitors/logs each job's outbound
  network traffic so a compromised third-party action elsewhere in the
  workflow's dependency chain would show up in the audit log.
  `changelog-check.yml`, `actionlint.yml`, `master-heartbeat.yml`, and
  `nightly-publish.yml` are not covered. Audit mode is the intended
  permanent state for this trial, not a stepping stone to `block` — kept
  log-only so it stays purely observational.
- **Trial CI job running OpenSSF Scorecard** (`.github/workflows/scorecard.yml`)
  (#57) — publishes results only to this repo's own code-scanning alerts for
  now (`publish_results: false`); making the score publicly visible on the
  OpenSSF Scorecard site is a separate decision left for the maintainer.

- **`configure` falls back to a bundled popt when system libpopt is
  unavailable** (#63) — `PKG_CHECK_MODULES(POPT, [popt >= 1.7])` previously
  had no fallback, so `configure` failed outright on minimal containers,
  embedded/cross-compilation environments, or older/unusual distros without
  a packaged popt. `configure.ac` now tries the system library first and,
  if it isn't found, builds a bundled copy from `popt/` instead of erroring
  out, mirroring this fork's existing zstd configure-time optional-detection
  pattern. New `--with-system-popt`/`--without-system-popt` configure flags
  force one path or the other when needed.
  - The bundled `popt/` tree is vendored from popt's own real,
    actively-maintained upstream project
    ([rpm-software-management/popt](https://github.com/rpm-software-management/popt)),
    pinned to its `popt-1.19-release` tag (2022-06-07). An earlier version
    of this change instead recovered a copy from `distcc/distcc`'s own git
    history (the commit right before upstream's own maintainers deleted it),
    which turned out to be libpopt 1.7 — a snapshot from roughly 1998-2001,
    20+ years and multiple major versions behind any current
    system-installed popt (Debian/Ubuntu ship ~1.16-1.19 today). Replaced
    with the real 1.19 release before merging once that version gap was
    flagged, to avoid the bundled fallback path silently missing two
    decades of upstream bugfixes relative to the system-popt path it
    substitutes for.
  - New CI job `popt_vendor_check` compiles the vendored `popt/*.c` directly
    under this project's own `-Wall -Wextra -Werror` (plus the same
    `-Wno-unused`/`-Wno-unused-parameter` exemption the real build applies
    to third-party code — even the unmodified 1.19 source needs it) and
    checks a version marker/fingerprint, to catch an accidental future
    regression back to the stale 1.7 tree even if it would otherwise still
    compile cleanly.

### Security

- **`distccd`: optional Linux seccomp sandbox for compiler child processes**
  (#68, porting the idea behind upstream distcc/distcc#233, which was
  never merged and could not be ported as-is). Previously, a remote
  client's compile job ran with the daemon's full process privileges;
  a compromised or malicious client could have the "compiler" process
  attempt anything the daemon's own privileges allowed. `distccd` now
  installs a Linux seccomp syscall denylist (`src/sandbox-seccomp.c`) in
  the forked child immediately before it execs the client-supplied
  compiler, blocking syscalls no legitimate compiler invocation needs
  (kernel/module loading, `mount`/`reboot`, `ptrace`, raw I/O port access,
  kernel keyring/eBPF/perf, host clock/hostname changes). This is a
  denylist, not the allowlist upstream's PR attempted: enumerating every
  syscall every compiler (gcc, clang, cross-compilers, and their cc1/as/
  ld/collect2/LTO sub-processes) legitimately needs is not something that
  can be verified by local testing, and a too-narrow allowlist silently
  breaks real builds. Treat this as defense-in-depth layered on top of
  the existing compiler whitelist and unsafe-option checks in
  `src/serve.c`, not as the sole boundary between a hostile client and
  the host. Fails open: if libseccomp isn't available at build time, or
  filter installation fails at runtime (unsupported/misconfigured
  kernel), `distccd` logs a warning and runs the compile unsandboxed
  rather than refusing every remote job on that host — this is a
  hardening layer, and an availability regression across an entire host
  would be a worse outcome than the marginal loss of defense-in-depth.
  Optional dependency (`libseccomp`, configure-time detected via
  `PKG_CHECK_MODULES`, `--with-seccomp`/`--without-seccomp`), degrading
  gracefully when absent, following the same pattern as the existing
  optional zstd support — no new hard build dependency.
- **`distccd` seccomp sandbox: runtime config file, `/etc/distcc/seccomp.conf`**
  (#192, follow-up on #68/#171) — makes three previously hardcoded
  behaviors admin-configurable without a rebuild, per the maintainer's
  review of the original PR's open questions. New minimal `key = value`
  parser (`src/sandbox-config.c`), read once at daemon startup: `enabled`
  (master on/off switch for the sandbox, default `true`), `deny-network`
  (additionally denies `socket`/`connect`/`sendto`/`recvfrom`/`bind`/
  `listen`/`accept`/`accept4`/`socketpair`/`sendmsg`/`recvmsg`/`sendmmsg`/
  `recvmmsg`/`shutdown` in the sandboxed compiler child, default `false`),
  `fail-open` (whether a sandbox-install failure lets the compile proceed
  unsandboxed or refuses it, default `true`, unchanged from #171's
  original behavior), `extra-deny`/`allow-override` (comma-separated
  syscall names to add to/remove from the built-in denylist; every
  actual removal is logged by name at startup). The file is optional —
  absent, empty, or comment-only all fall back to the documented
  defaults, not an error. A world-writable config file logs a warning
  (matching this codebase's existing world-writable-file finding class,
  #157/#158) but is still used. Fail-closed refuses a compile via the
  same ordinary failure path an actual compiler error already takes
  (`EXIT_DISTCC_FAILED` from the forked child), not a new ad hoc failure
  mode. See `doc/seccomp-sandbox.md` for the full config reference,
  including why a same-subnet-only network restriction is explicitly out
  of scope (seccomp/BPF cannot inspect `connect()`'s `sockaddr*`
  contents). Config-file-only for this pass — matching `distccd`
  command-line flags are a documented, deferred follow-up, not an
  oversight (see the doc for why).

### Removed

- **`bench/` macro-benchmark tool** (#182) — last touched 2008, Python 2,
  required a manually-configured real distcc farm and downloaded 15-20+
  year old open-source project tarballs from largely-dead mirrors. No
  longer has any ongoing relevance to this fork.

### Changed

- Raised `dcc_lock_one()`'s per-scan slot-index cap in `src/where.c` from
  10000 to 50000 (#72), porting upstream distcc/distcc#349. This only
  affects hosts configured with an unusually large `n_slots`: the scan now
  reaches slot indices between 10000 and 50000 in a single pass instead of
  needing an extra pause-and-rescan cycle to get there. No other behavior
  change — the loop never gives up and fails a build when the cap is hit
  either way, it always falls through to a paced rescan.
- **`dcc_mkdir()` failed with `ENOENT` when a parent directory was
  missing** (#179) — `dcc_get_top_dir()`/`dcc_get_subdir()` build paths
  like `$HOME/.distcc` via `dcc_mkdir()`, which previously did a single
  non-recursive `mkdir()`. If `$HOME` (or `DISTCC_DIR`'s parent) didn't
  already exist — e.g. a minimal container or sandboxed build worker —
  this failed outright instead of creating the missing parent(s).
  `dcc_mkdir()` now reuses the existing `dcc_mk_tmp_ancestor_dirs()`
  helper to create any missing ancestors first, giving it real
  `mkdir -p` semantics. Found via a real overnight cross-project
  evaluation of distcc-ng against wiki-mod/lancache-ng's
  sccache+distcc-dist build pipeline
  ([lancache-ng#919](https://github.com/wiki-mod/lancache-ng/issues/919)).

### Added

- **Auto-resolve `-march=native`/`-mtune=native`/`-mcpu=native` compiler
  flags instead of hard-failing** (#73, porting the corrected rebase of
  upstream distcc/distcc#350, distcc/distcc#384). These flags previously
  forced the whole compilation to run locally, since "native" is only
  meaningful on the machine actually doing the codegen and shipping it
  unresolved to a remote compile server could silently miscompile for the
  *server's* CPU instead of the client's. `dcc_resolve_march_native()`
  (`src/arg.c`) now asks the local compiler what "native" concretely
  expands to (via `<compiler> -v -E -x c -march=native ... -`, scraping
  the resolved flags off gcc/clang's verbose cc1 invocation) and ships the
  concrete, resolved flags remotely instead — working across both gcc and
  clang (clang's flags are wrapped in `-Xclang`, since its driver won't
  accept raw cc1-level flags directly). If local resolution fails for any
  reason (unsupported compiler, unexpected output, subprocess failure),
  the client falls back to the existing safe behavior of hard-failing the
  distribution attempt, exactly as before this feature existed — a
  compilation is never shipped remotely with an unresolved "native" flag.

## [3.5.1.1-NG] - 2026-07-16

### Fixed

- **CI: `package-release.yml`'s `publish_github_release` job failed on every
  real tag push** (#162) — discovered live during the v3.5.1-NG release cut.
  The job had no `actions/checkout` step and its `gh release`
  create/view/upload/edit calls didn't pass `--repo`, so `gh` tried (and
  failed) to infer the target repo from a nonexistent local git checkout.
  Packages and the container image were still built and pushed correctly;
  only the final GitHub Release page/asset-upload step failed. Added
  explicit `--repo` to all four `gh release` invocations, matching this
  repo's own standing rule (always pass `--repo` explicitly).
- **`v3.5.1-NG` itself is a permanently incomplete release** as a direct
  result of the above bug: the tag, packages, and multi-arch container image
  were all built and published correctly, but no GitHub Release page was
  ever created, and per this fork's tag-immutability policy that tag can
  never be moved or reused. This `3.5.1.1-NG` release exists solely to
  re-cut a complete, correctly-published release with the fix applied; it
  carries no other functional changes over `3.5.1-NG`.

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
- Wire protocol version 4: optional zstd compression support alongside
  the existing LZO, plus `-gsplit-dwarf` support. Configure-time
  auto-detected (`PKG_CHECK_MODULES([ZSTD], [libzstd >= 1])`), builds
  fine without libzstd present (`AC_MSG_NOTICE([zstd support disabled])`,
  no hard dependency), per `doc/compatibility-policy.md`. Recovered and
  rebased from this fork's own prior (unmerged) `v3.4.1-zstd` release —
  originally distcc/distcc#232 by Shawn Landden. (fixes #67)
- `AGENTS.md`/`CLAUDE.md`: repository governance and agent-workflow rules,
  adapted from wiki-mod/lancache-ng's established pattern — issue/PR
  tracking discipline, worktree-per-issue workflow, required validation
  (warnings-are-errors, real build/test verification), this fork's own
  comment-every-function convention, and release/compatibility-policy
  cross-references. (#82)
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
- CI: `repro_issue87` job in `c-build.yml` + `test/e2e/repro-hostlist-issue87.sh`
  — an investigation-only, `continue-on-error` job reproducing (for real,
  via the existing distcc+pump e2e harness) the failure modes behind #87
  (distcc and pump currently need two different host-list entries). Added
  as a job in the already-registered `c-build.yml` rather than a new
  workflow file, since a brand-new workflow file isn't recognized by the
  Actions API until it exists on the default branch (the same structural
  limit already hit in #81). Not part of the merge gate; to be removed
  once #87's real fix lands. (#87)
- CI: `master-heartbeat.yml` — a weekly (and manually dispatchable) heartbeat
  that builds ccache's own source (pinned to `v4.13.6`, a representative
  third-party C/C++ CMake project) fully distributed across the same
  two-container distccd/distcc harness, as a heavier real-world validation
  than the distcc-ng self-compile and independent of whether `master` changed.
  The `test/e2e/` orchestrator was generalized (`E2E_CLIENT_SCRIPT` /
  `E2E_MIN_REMOTE_JOBS`) so one proven harness drives both the nightly
  self-compile and this heartbeat. (Per-push `master` health is already covered
  by `c-build.yml`'s existing push trigger + its `distributed_e2e` job.) (#81)
- CI: automatic failure tracking for the scheduled pipelines. A shared
  composite action (`.github/actions/nightly-status`) files or updates a single
  standing `nightly-broken` GitHub issue when the nightly publish or the weekly
  heartbeat fails — reusing the same open issue across consecutive failures
  rather than opening a new one each run — and closes it automatically on the
  next success. Wired as an `if: always()` reporting job in both workflows so
  it fires even when a gate fails and later jobs are skipped. Both pipelines
  feed the one standing issue (per this design), which self-corrects: a success
  closes it and the next real failure re-files it. (#81)
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
- **CI**: switched CodeQL scanning from GitHub's Default Setup (master-only) to
  Advanced Setup with a custom workflow (`codeql.yml`) that scans both
  `current_dev` and `master` branches. Ensures that CodeQL alerts respect the
  active development branch's actual code state, not just `master`'s, so fixes
  committed to `current_dev` clear corresponding alerts immediately rather than
  waiting for promotion to `master`. Uses extended query suite (`security-extended`)
  over 3 languages (`c-cpp`, `python`, `actions`); `c-cpp` builds manually
  (`autogen.sh && ./configure && make`) since CodeQL's autobuild is unreliable
  with autoconf/automake projects. Weekly schedule (Sunday 05:00 UTC) plus
  push/PR triggers. (#155)

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
- Changelog tooling: replaced `git-changelog` with `git-cliff` for better
  narrative support, later retired entirely in favor of the fully
  automated `release-drafter`-based chain described under Added above
  (see #122). (fixes #106)
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
- CI: the nightly publish now stamps the container image (`VCS_REF`) and the
  release notes with the `current_dev` commit actually built, not `master`'s
  tip. Under `schedule`/`workflow_dispatch` the workflow is evaluated from the
  default branch, so `github.sha` is `master`; the job checks out `current_dev`,
  so the built commit is resolved explicitly with `git rev-parse HEAD`. For the
  same reason, `c-build.yml` no longer emits a build-provenance attestation on
  scheduled runs, where it would otherwise tie `current_dev` binaries to
  `master`'s SHA. (#81)
- **pump mode**: unified distcc+pump host-list support (fixes #87). pump.in's
  manual-DISTCC_HOSTS code path now auto-appends `,cpp,lzo` to hosts that don't
  already specify `,cpp`, mirroring the behavior of the auto-discovery path.
  This allows a single host-list entry (e.g. `distccd-server:3632` or
  `distccd-server:3632,lzo`) to work correctly under both plain distcc
  (which gracefully falls back to client-side preprocessing if no include-server
  is running) and pump mode (which requires server-side preprocessing).
  Previously, users needed two separate entries with different formats,
  causing hard failures or silent behavior differences in real deployments. (#87)
- **code quality**: suppressed `github-code-quality[bot]` findings (unclosed files,
  bare except blocks, empty exception handlers). Fixed unclosed `open()` calls in
  `test/testdistcc.py` by wrapping them in `with` statements. Narrowed bare
  `except:` in `include_server/include_server.py` startup to `except Exception:`
  so `SystemExit` and `KeyboardInterrupt` propagate. Added explanatory comments
  to intentional exception suppressions. Narrowed `OSError` handling in pidfile
  cleanup to only suppress `ENOENT` (file already gone) and re-raise other errors.
  All changes are behavior-preserving. (#109)
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
- **lock.c: shared-DISTCC_DIR lock files now actually get 0666** (#159).
  `dcc_open_lockfile()`'s `open(..., 0666)` was always masked by the
  creating process's umask (typically landing as `0644`/`0664` on disk),
  silently defeating the deliberate shared-multi-user-lock-dir support the
  surrounding comment describes. Added an `fchmod()` call after creation,
  which (unlike `open()`'s mode argument) isn't subject to umask. Verified
  live in a real two-user container test: the resulting file mode is now
  genuinely `0666`. Note: a real second-user relock still fails on hosts
  with the kernel's `fs.protected_regular` hardening enabled — a separate,
  pre-existing limitation of the shared-lock-dir design itself, unrelated
  to this umask fix; see #159 for details.

### Security

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
- `distccd`: reject a client-supplied `CDIR` (current working directory,
  `dcc_r_cwd()` in `src/srvrpc.c` → `make_temp_dir_and_chdir_for_cpp()` in
  `src/serve.c`) that contains a `..` path component, before it is
  concatenated onto the server's per-job temp directory for the `chdir()`
  call. Previously unvalidated, a crafted `CDIR` (e.g., `../../etc`) could
  walk the resulting path outside that temp directory, allowing the server to
  change into (and create) arbitrary subdirectories — discovered during #100
  triage of CodeQL path-injection alerts. This closes the `CDIR` traversal
  vector; it parallels the earlier `NAME` validation fix (see #93). (fixes #100)
- Fixed 5 `cpp/unbounded-write` CodeQL alerts (`src/argutil.c`, `src/compile.c`,
  `src/include_server_if.c`, `src/lsdistcc.c`, `src/serve.c`) by replacing
  `strcpy`/`sprintf`/`strcat` calls with bounded equivalents (`memcpy` with an
  explicit length, `snprintf`, `strncat`) at each flagged call site. Also
  resolves the `cpp/unsafe-strcat` alert on the same `src/lsdistcc.c:891` line.
  (#145, #148)
