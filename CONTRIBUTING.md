# Contributing to distcc-ng

Thank you for helping improve distcc-ng.

distcc-ng is a distributed C/C++ compiler: `distccd` runs as a network
daemon accepting compile jobs from other machines, `distcc`/`pump` decide
what gets sent over the wire and how, and the wire protocol has to stay
compatible with independently-built `distcc`/`distccd` binaries on the
other end. Changes here can affect daemon security (privilege drop,
sandboxing), protocol-version compatibility with hosts this fork didn't
build, and cross-platform build correctness across the toolchains this
fork supports. Please keep contributions small, reviewable, and easy to
verify against real behavior — not just a diff that looks right.

## Project scope

distcc-ng is a maintained fork of [distcc/distcc](https://github.com/distcc/distcc)
— a distributed C/C++ compiler that lets `make -jN` (or any build) farm
out compile jobs to other machines on the network. This fork exists
because upstream distcc does not accept AI-assisted contributions;
`wiki-mod/distcc-ng` does, under the governance in `AGENTS.md`.

Core pieces: `distcc` (client), `distccd` (compile server daemon), `pump`
(the include-server-backed "pump mode" for a bigger speedup),
`include_server/` (the Python include-server), and the monitoring tools
(`distccmon-text`, `distccmon-gnome`, `lsdistcc`).

```
src/                     # distcc/distccd/pump C sources
include_server/          # Python include-server (pump mode's header-dependency analysis)
include_server/c_extensions/  # C extension backing the include-server's fast paths
lzo/                     # bundled minilzo (LZO compression, always available)
test/                    # comfychair-based test harness (testdistcc.py — real e2e-ish
                         # daemon+compile tests, not just unit tests)
packaging/               # RPM/.deb packaging (rpm.spec, rpm.sh, deb.sh)
docker/release/          # Release container image
doc/                     # release-versioning.md, release-checklist.md,
                         # compatibility-policy.md, protocol docs
scripts/                 # build-release-packages.sh, check-release-version.sh
.github/workflows/       # c-build.yml (build+test), package-release.yml (tagged releases),
                         # changelog-check.yml, actionlint.yml
```

Build system is autoconf/automake (`configure.ac`/`Makefile.in`) — a
deliberate choice, not an oversight; a Meson migration was investigated
and not (yet) adopted (see the tracking issue for the full feasibility
analysis). Don't assume a build-system change is safe to make casually —
see `AGENTS.md` rule 53.

### A few design notes worth knowing before you dig in

- **Wire protocol compression**: LZO (`src/compress-lzox1.c`) always
  available; zstd (`src/compress-zstd.c`) optional, configure-time
  auto-detected, degrading gracefully when libzstd isn't present. The
  include-server's own C-extension build needs `LIBS` forwarded from
  `Makefile.in` to pick up the same linker flags the main binaries get
  automatically — worth knowing if you're touching that build path,
  since it's easy to miss on a platform where the library happens to
  already be on the default linker path.
- **Upstream relationship**: this fork tracks and periodically surveys
  upstream `distcc/distcc`'s issue/PR history for adoptable fixes —
  never adopted unverified. A recovered patch still needs a real
  cross-check against this fork's *current* source before landing, since
  both have moved independently since it was written.
- **CI build acceleration**: `make`/`make check` build through `ccache`
  in CI, with the object cache persisted across runs.

## Before you start

- Open an issue for large or behavior-changing work before writing a big
  patch — see `.github/ISSUE_TEMPLATE/feature_request.md` or
  `bug_report.md` depending on what you're proposing. Small, focused fixes
  can go straight to a PR.
- Keep unrelated changes in separate pull requests — a PR should bundle
  only what's causally necessary for its own stated goal.
- A behavior-changing or bug-fixing change should add or update an
  automated test (`test/testdistcc.py`) covering it, not just a manual
  local check — see "Baseline build and test" below for how the suite is
  run. If a change genuinely can't be covered this way (e.g. it's purely
  documentation, or the behavior isn't practically testable in
  `test/testdistcc.py`'s harness), say so explicitly in the PR rather than
  silently omitting test coverage.
- Do not commit credentials, tokens, private hostnames/IPs, or other
  environment-specific values (see `AGENTS.md`'s "Secrets And Sensitive
  Data" section) — use GitHub Secrets/Variables instead, even for a value
  only used in testing.
- Don't assume every user builds on the same OS/toolchain — see
  `doc/compatibility-policy.md` before changing a minimum compiler/library
  version or adding a new hard dependency.

## Pull request expectations

Opening a PR pre-fills `.github/pull_request_template.md`. Fill in every
section rather than deleting the ones that feel redundant for a small
change — a short "N/A" is fine, but keep the heading so reviewers always
know where to look. At minimum, each pull request should cover:

- what changed, in before/after terms, with a concrete example where
  possible
- why the change is needed and what it fixes or adds
- how users/operators are affected
- what the PR deliberately does **not** touch (scope boundaries)
- which files were actually touched (scope evidence, e.g. `git diff --stat`)
- which checks were run, with the exact commands and real output — not
  "should work" (see "Local checks" below)
- any remaining risk, rollback notes, or follow-up work

### Issue linking

- Use `Refs #123` for tracking/parent/umbrella issues, design discussions,
  or partial/follow-up work.
- Use `Closes #123`/`Fixes #123` only when merging this PR should actually
  close that issue.
- If the PR is a scaffold, partial fix, or explicitly defers part of an
  issue's scope, say so in the title/body, name the remaining tracker with
  `Refs #123`, and do not use `Closes`/`Fixes` for the unresolved part.
- Once merged, a completion claim should be checked against the actual
  merge commit or current base branch, not just the PR head.

### Changelog expectations

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/)
format, but you don't hand-edit its release sections yourself — it's
maintained fully automatically by a three-step chain (this replaced an
earlier git-cliff-based approach, see #122):

1. **`release-drafter`** (`.github/release-drafter.yml`,
   `.github/workflows/release-drafter.yml`) auto-maintains a draft GitHub
   Release (visible in the Releases tab), refreshed on every push to
   `current_dev`, zero manual trigger. PRs are categorized
   (`Security`/`Fixed`/`Added`/`Documentation`) by a label auto-assigned
   from the PR title via its `autolabeler`. Entries use `#N | title`.
2. A maintainer publishes that release as part of the existing manual
   release-cut process (`doc/release-versioning.md`) — unchanged.
3. On that `release: released` event,
   `.github/workflows/changelog-update-on-release.yml` runs
   [`stefanzweifel/changelog-updater-action`](https://github.com/marketplace/actions/changelog-updater)
   to insert the release's notes as a new dated section into
   `CHANGELOG.md`, then
   [`stefanzweifel/git-auto-commit-action`](https://github.com/stefanzweifel/git-auto-commit-action)
   commits it to `current_dev` (tags are cut from `current_dev`'s tip, so
   that's always where the update belongs).

What you as a contributor still need to do: the `changelog-check` CI job
currently requires every PR to either touch `CHANGELOG.md` directly (an
entry under `[Unreleased]`) or carry the `no-changelog-needed` label —
don't treat that gate as a formality to route around.

## Code comments

This fork's comment convention (see `AGENTS.md`'s "Comment Style" section)
differs from a typical minimal-comments house style:

- Every function gets a comment.
- Once a function-level comment exists, comment the **WHY**, not the
  WHAT — a hidden constraint, a subtle invariant, a workaround for a
  specific bug, or something that would surprise a reader. Well-named
  identifiers already say what the code does.
- Don't reference the current issue/PR number in a code comment (e.g.
  "fixed for #123") — that belongs in the PR/commit description.
- If you touch a file for any reason, bring its existing comments up to
  this same standard, not just the one function that motivated your
  change. A missing WHY-comment in code you're already touching is a
  defect to fix as part of that change, not a pre-existing gap to leave.
- Remove placeholder/TODO markers the moment the work they describe is
  actually done in that same change.

## Local checks

Run the checks that match your change; note any check you couldn't run
and why.

### Baseline build and test

```bash
./autogen.sh
./configure PYTHON=python3   # add --without-zstd, --disable-pump-mode, etc. as needed
make
make check
```

`make check` runs the real test suite (`test/testdistcc.py`, a
comfychair-based harness with genuine daemon+compile e2e-style tests, not
just unit tests) — necessary, but on its own only proves you didn't break
something already covered. See `doc/verification-checklist.md` for what
additional, real evidence a permission/sandbox/distribution/protocol
change needs beyond a passing build+test.

### Using the verification/buildtools container

distcc-ng publishes its own pre-built verification image (issue #264),
`ghcr.io/wiki-mod/distcc-ng-buildtools:latest` (built from
`docker/verify/Dockerfile`, documented in `doc/docker.md`) — a
self-contained Debian image with this repo's build toolchain, debug tools
(`gdb`, `strace`, `ltrace`), a sanitizer/memory-debug toolchain
(ASan/UBSan, `valgrind`), and no fetch/install step at container start.
Pull and run it against your checkout instead of relying on host-local
tools that may be missing, misconfigured, or stale versus what CI uses:

```bash
docker pull ghcr.io/wiki-mod/distcc-ng-buildtools:latest
docker run --rm -v "$PWD:/work/src:rw" -w /work/src \
  ghcr.io/wiki-mod/distcc-ng-buildtools:latest \
  bash -c './autogen.sh && ./configure PYTHON=python3 && make && make check'
```

If the image's baked-in non-root user doesn't already own the bind-mounted
checkout (your own uid differs from the image's default), add `--user
"$(id -u):$(id -g)"` and `-e HOME=<a writable path>` to the `docker run`
above instead of running as the image's default user or as root -- see
`doc/verification-checklist.md` section 9 for why both flags are needed
and what breaks without the `HOME` override. If your `make check` run
needs to exercise `SSHMode_Case` (or anything else calling `getpwuid()`),
your own uid also needs a resolvable `/etc/passwd`/`/etc/group` entry
inside the container -- section 9's same entry covers the bind-mounted-
file fix and links the current, real implementation.

### Workflow changes

Any `.github/workflows/*.yml` change needs `actionlint` run against it
before it's correct:

```bash
actionlint .github/workflows/*.yml
```

## Release process

Release cuts, versioning, and tagging follow `doc/release-versioning.md`.
There is no automated version-bump tooling — the `X.Y.Z` number is always
a manual maintainer decision, informed by `CHANGELOG.md`'s `[Unreleased]`
section.

## Security-sensitive changes

If you find a vulnerability, do not open a public issue — see
`SECURITY.md` for how to report it privately via GitHub Security
Advisories, and for this project's documented security design decisions
(network trust model, sandboxing, TLS status) so you can tell whether
what you found is a known tradeoff or a real new finding.
