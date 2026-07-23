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

See `CLAUDE.md`'s "Project Purpose" section for the authoritative
description; in short: `distcc` (client), `distccd` (compile server
daemon), `pump` (the include-server-backed "pump mode" for a bigger
speedup), `include_server/` (the Python include-server), and the
monitoring tools (`distccmon-text`, `distccmon-gnome`, `lsdistcc`).

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
maintained by an automated chain (see `CLAUDE.md`'s "Changelog
Maintenance" section for the full detail): `release-drafter` categorizes
merged PRs into a draft GitHub Release by an auto-assigned label, and once
a maintainer publishes that release, `changelog-update-on-release.yml`
inserts its notes into `CHANGELOG.md` automatically. What you as a
contributor still need to do: the `changelog-check` CI job currently
requires every PR to either touch `CHANGELOG.md` directly (an entry under
`[Unreleased]`) or carry the `no-changelog-needed` label — don't treat
that gate as a formality to route around.

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

(If your host user doesn't already own the bind-mounted checkout the way
CI's runner does, see `doc/verification-checklist.md` section 9 for the
`chown`-then-drop-to-`verify`-user pattern that avoids arming `distccd`'s
own root privilege-drop test by accident.)

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
