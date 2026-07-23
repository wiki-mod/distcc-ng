# Changelog

All notable changes to distcc-ng will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning continues distcc's own numbering (currently based on distcc 3.4),
with a `<version>-NG` suffix marking this fork's own releases — e.g. `3.5.0-NG`.
See `doc/release-versioning.md` for the full versioning and release process.

<!-- insertion marker -->

## [Unreleased]

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
