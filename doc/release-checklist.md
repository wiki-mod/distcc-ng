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

## Stable item IDs

Every checklist item below carries a stable `REL-*` ID. `.github/PULL_REQUEST_TEMPLATE/create_and_publish_release.md`
restates only the imperative and an ID for each item, never a second, independently
maintained copy of its definition — this file remains the one place a check's actual
meaning is defined. An ID, once assigned, is never renumbered or reused (same discipline
as AGENTS.md rule 64 for rule numbers): a newly discovered gap gets the next unused
number in its family, appended, not inserted.

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

## Release governance / sign-off

These are process-completion gates AGENTS.md already requires for any large,
tracked effort (rule 78) — listed here explicitly so a release actually
exercises them, rather than relying on that rule being remembered unprompted.

- [ ] **`REL-GOV-01`** — the Candidate SHA recorded in the release PR still
      matches the actual, intended release candidate at the point this
      checklist is treated as complete.
- [ ] **`REL-GOV-02`** — no unresolved release blocker remains open.
- [ ] **`REL-GOV-03`** — a final AGENTS.md self-check (rule 78(c)) has been
      performed against, at minimum: tracking metadata (rule 3), PR scope
      (rule 58), comment style (rules 38-42), real validation evidence
      (rules 31-37), and the support-upstream check (rule 57).
- [ ] **`REL-GOV-04`** — an independent review of the finished release PR
      (rule 78(a)) has been performed, distinct from `REL-GOV-03`'s
      self-check.

## Before cutting `release/X.Y.Z-NG`

- [ ] **`REL-PRECUT-01`** — `CHANGELOG.md`'s `[Unreleased]` section reviewed
      end to end against the real PR history since the last tag (`git log
      <last-tag>..HEAD --oneline`, cross-checked against the section, not
      the other way around) — every user-visible change represented,
      nothing merged silently missing an entry.
- [ ] **`REL-PRECUT-02`** — a real, dated `## [X.Y.Z-NG] - YYYY-MM-DD`
      heading actually exists in `CHANGELOG.md` for *every* tag since the
      last one this checklist was run against, with real content under it —
      not just that `[Unreleased]`'s own content looks complete. A release
      cut that only adds a new dated heading without verifying the previous
      release's heading is still present and populated can silently lose an
      entire release's worth of attribution (confirmed live, issue #460:
      three consecutive releases, v3.6.2-NG/v3.6.3-NG/v3.6.4-NG, never got
      their own dated section on `current_dev` at all, and their content sat
      unsplit under `[Unreleased]` across three further release cuts before
      anyone noticed — fixed retroactively by PR #465).
- [ ] **`REL-PRECUT-03`** — no open, unresolved `security`-labeled issue
      that should block this release, **or** an explicit, dated, documented
      maintainer decision to ship anyway with the reasoning recorded (see
      issue #266's leak-triage precedent for the expected shape of that
      decision — accepted and why, not silently ignored).
- [ ] **`REL-PRECUT-04`** — `scripts/check-release-version.sh` run for real
      against the intended tag — not assumed to pass because
      `configure.ac`'s `AC_INIT` "looks right" on read.
- [ ] **`REL-PRECUT-05`** — every `support-upstream/` entry opened since the
      last release has both its own file and its `support-upstream/README.md`
      index row (AGENTS.md rule 58) — a real, not just a green, `git diff
      <last-tag>..HEAD -- support-upstream/` read.
- [ ] **`REL-PRECUT-06`** — **`master`'s copy of any `release:`-event-triggered
      workflow (currently `changelog-update-on-release.yml`, and any workflow
      `package-release.yml`'s publish step depends on for that event, e.g. the
      identity it publishes releases as) matches `current_dev`'s.** GitHub
      evaluates a `release` event's `on:` trigger from the workflow file on
      the repository's default branch (`master`), not from the tag being
      created — confirmed live, issue #460/PR #467: `master` lagging
      `current_dev` here would silently skip the automatic changelog update
      for the release being cut, with no error anywhere. Diff `master`'s
      copy against `current_dev`'s before tagging; if they differ, either
      promote the `.github/workflows/` change to `master` first, or plan to
      use the workflow's own `workflow_dispatch` retry path for this release
      — dispatched explicitly against `current_dev` (`gh workflow run
      changelog-update-on-release.yml --repo wiki-mod/distcc-ng --ref
      current_dev -f tag_name=... -f release_notes=...`), never bare. An
      unqualified `gh workflow run` runs the workflow file version from the
      repository's default branch (confirmed via `gh workflow run --help`:
      `--ref` is what selects a different version) — exactly the stale,
      pre-fix copy this fallback exists to work around in the first place.
      The current, real state of this diff (whether it passes or fails
      right now) is a transient fact, not part of this check's own
      definition — see issue #460 for that state as of the last time it was
      checked.
- [ ] **`REL-PRECUT-07`** — the release branch contains no release-only
      fixes relative to `current_dev` — an explicit, reproducible check
      (e.g. `git diff current_dev...release/X.Y.Z-NG`), not proven from
      assumption or visual familiarity.
- [ ] **`REL-PRECUT-08`** — no unreviewed drift exists between the release
      branch and its expected relationship to `current_dev` beyond the
      stated, intentional cut point — an explicit reproducible check (e.g.
      `git merge-base --is-ancestor current_dev release/X.Y.Z-NG` plus a
      read of anything ahead of that merge base), not assumed.
- [ ] **`REL-PRECUT-09`** — every commit/PR merged since the previous
      release tag has been classified against `doc/verification-checklist.md`'s
      9 categories, and every category a commit actually touches has real
      evidence behind it (a named CI test that ran and passed, or a fresh
      manual check performed now) — a **complete, itemized sweep of the
      whole commit range**, not spot-checking a subset and treating it as
      equivalent. This item exists because spot-checking already happened
      once in this repo's real history and was indistinguishable, from the
      release PR body alone, from a real sweep having been done (confirmed
      live, issue #460 Finding 5's confirming incident, 2026-08-11: asked
      directly whether every commit since v3.6.4-NG had been checked against
      `doc/verification-checklist.md`'s 9 categories, the honest answer was
      no — only this document had been worked through in full, the
      per-commit sweep had only been spot-checked).
- [ ] **`REL-PRECUT-10`** — `master`'s tip is not so far behind
      `current_dev` that the release PR (`release/X.Y.Z-NG` → `master`)
      would need a real merge to land — checked via `git merge-base
      --is-ancestor <master-tip> <release-branch-head>`. If `master` isn't
      an ancestor, real content drift exists between the two; per issue
      #460 Finding 4, this is the leading (though not fully confirmed)
      explanation for why the release PR's own `pull_request`-triggered CI
      can go silent for its entire review window. If it isn't an ancestor,
      resolve `master`'s staleness (e.g. the promotion-PR pattern PR #463
      used) before relying on the release PR's own CI as evidence.

## Artifact verification — real behavior, not a build matrix

Run `doc/verification-checklist.md`'s relevant sections in full for
*anything* that changed since the last release in a category that document
covers (permissions, sandbox, distribution behavior, container-based
build). The items below are release-specific additions on top of that, not
a replacement for it.

- [ ] **`REL-ART-01a`** — **Container image labels match what's actually
      published — `distcc-ng`.** A `docker build` with no `--target` builds
      whichever stage happens to be *last* in the Dockerfile — silently
      reassignable by a later, unrelated stage being appended (issue #359's
      exact root cause). Confirm the real, live, already-pushed image's
      `org.opencontainers.image.title` label and `COPY` history via the
      registry API (see `doc/verification-checklist.md` Section 9's
      reproduction command), not by reading the Dockerfile and assuming.
- [ ] **`REL-ART-01b`** — same as `REL-ART-01a`, for `distcc-ng-pump`.
- [ ] **`REL-ART-01c`** — same as `REL-ART-01a`, for `distcc-ng-nightly`.
- [ ] **`REL-ART-02`** — **every real `distccd` artifact — containers *and*
      `.rpm`/`.deb` packages — actually has the seccomp sandbox compiled in
      and enforcing**, not just present in the build dependency list.
      Confirm via `doc/verification-checklist.md` Section 2's real negative
      test (a syscall the denylist should block actually gets blocked), not
      a startup log line alone — a log line only proves the code path that
      prints it was reached.
- [ ] **`REL-ART-03`** — **the actual built `.rpm`/`.deb` declares the
      dependencies its own linked libraries need**, checked by inspecting
      the real artifact (`rpm -qp --requires`, `dpkg-deb -I`), not assumed
      from `ldd` on a locally built binary alone — a real CI-built package
      can differ from a local dev build in ways that matter here (build
      flags, linked library versions). Use `gh workflow run
      package-release.yml --ref <branch> -f publish_container=false` to get
      a real, CI-built package without needing a real tag (see
      `doc/verification-checklist.md` Section 2 for the exact
      download/inspection commands).
- [ ] **`REL-ART-04a`** — a real distributed compile succeeds end to end
      through the plain (non-pump) shipped image/package variant — a real
      client, a real server, a real network hop, verified from the server's
      own independent log (`doc/verification-checklist.md` Section 3's
      technique), not just the variant's own internal self-test passing in
      isolation.
- [ ] **`REL-ART-04b`** — same as `REL-ART-04a`, for the pump-mode variant.
      Kept as its own item, not folded into `REL-ART-04a`: local/CI
      verification has previously silently never exercised pump mode at all
      (`doc/verification-checklist.md`'s matching entry) while `make check`
      still reported green.
- [ ] **`REL-ART-05`** — SBOM (`anchore/sbom-action`) actually attached to
      the release — confirmed present on the real GitHub Release page, not
      assumed because the workflow step that generates it didn't fail.
- [ ] **`REL-ART-06`** — build attestation (`actions/attest-build-provenance`)
      actually attached to the release, confirmed the same way as `REL-ART-05`.

### Conditional, change-triggered checks

Fill in only the items whose trigger condition actually applies to what
changed since the last release; record which paths were checked and mark
the rest `N/A` with that reasoning, rather than silently skipping the whole
subsection.

- [ ] **`REL-ART-07`** — if `src/sandbox-seccomp.c`, `src/sandbox-config.c`,
      or a Dockerfile stage building `distccd` changed: the effective
      seccomp denylist matches intent, per affected artifact class
      (`doc/verification-checklist.md` Section 2).
- [ ] **`REL-ART-08`** — same trigger as `REL-ART-07`: a real negative test
      confirms a denied syscall is actually blocked, per affected artifact
      class (`doc/verification-checklist.md` Section 2).
- [ ] **`REL-ART-09`** — if a permission/file-mode-affecting file changed
      (e.g. `src/lock.c`, `src/state.c`, `src/daemon.c`): a real
      second-user cross-permission check on a real Unix-permission
      filesystem (`doc/verification-checklist.md` Section 1).
- [ ] **`REL-ART-10`** — if distribution/scheduling or compiler-identity
      code changed (e.g. `src/arg.c`, `src/climasq.c`, protocol-governed
      wire behavior): a real two-container distribution test
      (`doc/verification-checklist.md` Section 3).
- [ ] **`REL-ART-11`** — if any `docker/**/Dockerfile` or
      `package-release.yml` changed: published-stage identity re-confirmed
      via the registry API for every touched Dockerfile target
      (`doc/verification-checklist.md` Section 9) — the same technique
      `REL-ART-01a`-`c` use, re-run specifically because the build
      definition itself changed this cycle.

## Compatibility and dependencies

- [ ] **`REL-COMPAT-01`** — if a new hard dependency was introduced since
      the last release (a new `apt`/`BuildRequires` entry, a new linked
      library): explicitly called out against `doc/compatibility-policy.md`
      — stated, not silently absorbed into a routine dependency bump.
- [ ] **`REL-COMPAT-02`** — if platform-conditional code changed:
      `doc/compatibility-policy.md`'s supported-platform matrix
      (FreeBSD/macOS/Cygwin, current Linux) re-confirmed for the changed
      code — a change gated behind `#ifdef`/`configure`-time detection on
      one platform needs its no-op behavior on the others actually
      confirmed unchanged, not assumed from the `#ifdef` reading correct.

## CI / Release pipeline sanity

Added by issue #460 Findings 2 and 4, two distinct real gaps found during
v3.6.5-NG's release PR: `REL-CI-04`'s automation had a confirmed root
cause (a `GITHUB_TOKEN` anti-recursion mechanism, PR #467); `REL-CI-01`'s
gap most plausibly traces to a real merge conflict between the release PR
and a stale `master`, though the investigation (issue #460 Finding 4)
could not fully explain every observed timing detail. Either way, these
items exist so a release PR's own CI actually ran, and the changelog
automation actually fired, is checked per release rather than assumed.

- [ ] **`REL-CI-01`** — a real `pull_request`-triggered CI run exists for
      this release PR itself (not inferred from a `pull_request_target` or
      `workflow_dispatch` run) — this is the check that would have caught
      issue #460 Finding 4 before merge, whatever the exact mechanism
      behind a given occurrence turns out to be. If it's `Failed` or
      `Blocked`, check whether the release branch's base is stale enough
      to conflict (`REL-PRECUT-07`/`08`) before assuming it's benign.
- [ ] **`REL-CI-02`** — the manual pre-tag package/artifact verification run
      (`workflow_dispatch` against the release branch), if used for this
      release, is recorded with its run URL and result.
- [ ] **`REL-CI-03`** — the real tag-triggered `package-release.yml` run for
      the pushed tag exists and succeeded.
- [ ] **`REL-CI-04`** — the `release: types: [published]` event actually
      triggered `changelog-update-on-release.yml` for this tag — confirms
      the real-PAT-identity fix (issue #460 Finding 2, PR #467) actually
      took effect. This item cannot pass while `REL-PRECUT-06` is failing —
      a stale `master` copy of either workflow silently prevents this
      regardless of `current_dev`'s own content.

## Documentation

- [ ] **`REL-DOC-01`** — `README.md`'s and `doc/docker.md`'s quick-start
      references (image tags, package names) match what this release will
      actually publish — checked against the real, intended tag list, not
      carried over from the last release's text unread.
- [ ] **`REL-DOC-02`** — every user-visible behavior change since the last
      release is in `CHANGELOG.md` under a real, dated section by the time
      this release is announced — not left in `[Unreleased]` past the point
      the release that should have included it already shipped.

## Promoting `current_dev` → `master`

- [ ] **`REL-PROMO-01`** — explicit, fresh maintainer approval for *this*
      promotion — never carried over from a previous promotion or a
      different PR's approval (AGENTS.md rule 21/52, and see this project's
      own memory of past incidents where approval scope was assumed too
      broadly).
- [ ] **`REL-PROMO-02`** — `git log master..current_dev` actually read, not
      assumed to be "just what we already discussed" — confirm nothing
      unrelated or unreviewed rode along.
- [ ] **`REL-PROMO-03`** — `current_dev`'s `configure.ac` bumped to the next
      planned version immediately after tagging (`doc/release-versioning.md`
      step 6) — so no build from `current_dev` can ever again report the
      version that was just released.
- [ ] **`REL-PROMO-04`** — **`changelog-update-on-release.yml`'s automated
      commit (`doc/release-versioning.md` step 5) actually landed on
      `current_dev`, and its content is explicitly accounted for in this
      release's actual promotion to `master`** (see `doc/release-versioning.md`
      step 7's own note on this real, standing gap — the frozen release
      branch can never receive that commit on its own). Check the
      workflow's Actions run history for a success at the tag's timestamp,
      and confirm the chosen resolution for *this* release is recorded here,
      not just that `CHANGELOG.md` looks right on read.

## Keeping this checklist current

Like `doc/verification-checklist.md`, this document is meant to grow from
real incidents, not from imagining hypothetical ones in advance. When a
release ships something wrong that this checklist would not have caught,
the fix is adding the specific check here — as the next unused ID in its
family — not just fixing the one instance — see AGENTS.md rule 73 (treat a
found bug as an error class, not an isolated line).
