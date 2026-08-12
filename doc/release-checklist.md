# Release Readiness Checklist

This document answers a different question than its two siblings:

- `doc/release-versioning.md` says **how** a release is cut and tagged (the
  mechanical branch/tag process).
- `doc/verification-checklist.md` says **how to verify a specific category
  of change** (permissions, sandbox, distribution behavior, etc.) as work
  happens.
- **This document** says what must actually be true, gathered together in
  one place, before a release is trusted to go out — so a release is never
  a surprise assembled from whatever happened to be green on the day.

## The one rule everything below exists to enforce

**A green build proves nothing.** `make`/`docker build`/`rpmbuild` succeeding
means the toolchain accepted the syntax — it says nothing about whether the
result behaves correctly, safely, or the same as the previous release. A
program can compile perfectly cleanly and be completely broken. Every item
below that can be satisfied by "it built" instead of a real, specific,
behavioral check is written to make that distinction unavoidable. If a
checklist item here can be checked off by a green CI run alone, that item is
wrong and should be fixed, not the release process worked around.

This document exists because that exact gap was real: `docker/release/Dockerfile`
and `package-release.yml` both built cleanly, on every CI run, for a long time
while silently shipping every real `distccd` release artifact — containers
*and* `.rpm`/`.deb` packages — with the seccomp sandbox compiled out entirely
(issue #360). Nothing failed. Nothing was red. The build was never the
problem; nobody had checked what the build actually *produced*.

## Before cutting `release/X.Y.Z-NG`

- [ ] `CHANGELOG.md`'s `[Unreleased]` section reviewed end to end against
      the real PR history since the last tag (`git log <last-tag>..HEAD
      --oneline`, cross-checked against the section, not the other way
      around) — every user-visible change represented, nothing merged
      silently missing an entry. **This check must also catch a missing
      dated section for an intermediate release**, not only missing
      entries within one: confirm a `## [X.Y.Z-NG] - YYYY-MM-DD` heading
      actually exists for every tag since the last one this checklist was
      run against, with real content under it — not just that
      `[Unreleased]`'s own content looks complete. A release cut that
      only adds a new dated heading without verifying the previous
      release's heading is still present and populated can silently lose
      an entire release's worth of attribution (confirmed live, issue
      #460: three consecutive releases, v3.6.2-NG/v3.6.3-NG/v3.6.4-NG,
      never got their own dated section on `current_dev` at all, and
      their content sat unsplit under `[Unreleased]` across three
      further release cuts before anyone noticed).
- [ ] No open, unresolved `security`-labeled issue that should block this
      release, **or** an explicit, dated, documented maintainer decision to
      ship anyway with the reasoning recorded (see issue #266's leak-triage
      precedent for the expected shape of that decision — accepted and
      why, not silently ignored).
- [ ] `scripts/check-release-version.sh` run for real against the intended
      tag — not assumed to pass because `configure.ac`'s `AC_INIT` "looks
      right" on read.
- [ ] Every `support-upstream/` entry opened since the last release has
      both its own file and its `support-upstream/README.md` index row
      (AGENTS.md rule 58) — a real, not just a green, `git diff
      <last-tag>..HEAD -- support-upstream/` read.
- [ ] **`master`'s copy of any `release:`-event-triggered workflow (currently
      just `changelog-update-on-release.yml`) matches `current_dev`'s.**
      GitHub evaluates a `release` event's `on:` trigger from the workflow
      file on the repository's default branch (`master`), not from the
      tag being created — confirmed live, issue #460/PR #467: `master`
      lagging `current_dev` here would silently skip the automatic
      changelog update for the release being cut, with no error anywhere.
      Diff `master`'s copy against `current_dev`'s before tagging; if they
      differ, either promote the `.github/workflows/` change to `master`
      first, or plan to use the workflow's own `workflow_dispatch` retry
      path for this release.

## Artifact verification — real behavior, not a build matrix

Run `doc/verification-checklist.md`'s relevant sections in full for
*anything* that changed since the last release in a category that document
covers (permissions, sandbox, distribution behavior, container-based
build). The items below are release-specific additions on top of that, not
a replacement for it.

- [ ] **Container image labels match what's actually published.** A
      `docker build` with no `--target` builds whichever stage happens to
      be *last* in the Dockerfile — silently reassignable by a later,
      unrelated stage being appended (issue #359's exact root cause).
      Confirm the real, live, already-pushed image's
      `org.opencontainers.image.title` label and `COPY` history via the
      registry API (see `doc/verification-checklist.md` Section 9's
      reproduction command), not by reading the Dockerfile and assuming.
      Do this for every published tag (`distcc-ng`, `distcc-ng-pump`,
      `distcc-ng-nightly`), not just the one that happened to prompt the
      last time this was checked.
- [ ] **Every real `distccd` artifact — containers *and* `.rpm`/`.deb`
      packages — actually has the seccomp sandbox compiled in and
      enforcing**, not just present in the build dependency list. Confirm
      via `doc/verification-checklist.md` Section 2's real negative test
      (a syscall the denylist should block actually gets blocked), not a
      startup log line alone — a log line only proves the code path that
      prints it was reached.
- [ ] **The actual built `.rpm`/`.deb` declares the dependencies its own
      linked libraries need**, checked by inspecting the real artifact
      (`rpm -qp --requires`, `dpkg-deb -I`), not assumed from `ldd` on a
      locally built binary alone — a real CI-built package can differ from
      a local dev build in ways that matter here (build flags, linked
      library versions). Use `gh workflow run package-release.yml --ref
      <branch> -f publish_container=false` to get a real, CI-built package
      without needing a real tag (see `doc/verification-checklist.md`
      Section 2 for the exact download/inspection commands).
- [ ] **A real distributed compile succeeds end to end through each
      shipped image/package variant** (plain and pump, at minimum) — a
      real client, a real server, a real network hop, verified from the
      server's own independent log (`doc/verification-checklist.md`
      Section 3's technique), not just each variant's own internal
      self-test passing in isolation.
- [ ] SBOM (`anchore/sbom-action`) and build attestation
      (`actions/attest-build-provenance`) actually attached to the release
      — confirmed present on the real GitHub Release page, not assumed
      because the workflow step that generates them didn't fail.

## Compatibility and dependencies

- [ ] Any new hard dependency introduced since the last release (a new
      `apt`/`BuildRequires` entry, a new linked library) is explicitly
      called out against `doc/compatibility-policy.md` — stated, not
      silently absorbed into a routine dependency bump.
- [ ] `doc/compatibility-policy.md`'s supported-platform matrix
      (FreeBSD/macOS/Cygwin, current Linux) still holds for anything that
      changed — a change gated behind `#ifdef`/`configure`-time detection
      on one platform needs its no-op behavior on the others actually
      confirmed unchanged, not assumed from the `#ifdef` reading correct.

## Documentation

- [ ] `README.md`'s and `doc/docker.md`'s quick-start references (image
      tags, package names) match what this release will actually publish
      — checked against the real, intended tag list, not carried over
      from the last release's text unread.
- [ ] Every user-visible behavior change since the last release is in
      `CHANGELOG.md` under a real, dated section by the time this release
      is announced — not left in `[Unreleased]` past the point the release
      that should have included it already shipped.

## Promoting `current_dev` → `master`

- [ ] Explicit, fresh maintainer approval for *this* promotion — never
      carried over from a previous promotion or a different PR's approval
      (AGENTS.md rule 21/52, and see this project's own memory of past
      incidents where approval scope was assumed too broadly).
- [ ] `git log master..current_dev` actually read, not assumed to be
      "just what we already discussed" — confirm nothing unrelated or
      unreviewed rode along.
- [ ] `current_dev`'s `configure.ac` bumped to the next planned version
      immediately after tagging (`doc/release-versioning.md` step 6) — so
      no build from `current_dev` can ever again report the version that
      was just released.

## Keeping this checklist current

Like `doc/verification-checklist.md`, this document is meant to grow from
real incidents, not from imagining hypothetical ones in advance. When a
release ships something wrong that this checklist would not have caught,
the fix is adding the specific check here, not just fixing the one
instance — see AGENTS.md rule 73 (treat a found bug as an error class, not
an isolated line).
