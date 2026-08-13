# Release Versioning Policy

This document is the release-versioning contract for the distcc-ng fork.

## Core Rule

distcc-ng versions continue distcc's own numbering, with a `-NG` suffix
identifying this fork's own releases — e.g. `3.5.0-NG`.

**The X.Y.Z number itself is a manual maintainer decision.** There is no
semantic-release bot, no Conventional Commits parser, and no other automated
version-bump tooling in this repository, and none is planned unless a
maintainer explicitly decides otherwise. `CHANGELOG.md`'s `[Unreleased]`
section informs that decision, but the version number is never derived
automatically from commit messages or PR titles.

## Branches And Tags

| Ref | Meaning | Mutability |
| --- | --- | --- |
| `master` | Stable, tested; what users/packagers should build from | No direct commits; only updated via an explicit, maintainer-approved promotion |
| `current_dev` | Integration branch, always reflects the latest merged work | Mutable |
| `dev/<topic>` | Per-bugfix/feature topic branches | Mutable, short-lived |
| `release/X.Y.Z-NG` | Cut once per release from `current_dev` (via a throwaway promote branch, never `current_dev` itself as a PR head) | Created once; never force-pushed or deleted |
| `vX.Y.Z-NG` (git tag) | The actual immutable release marker, created on the release branch's HEAD at release time | Created once; never moved, deleted, or reused |

## Version Reporting

- `configure.ac`'s `AC_INIT` version is the *next planned* release number.
- Builds from `current_dev`/`dev/*` (i.e. anything not built from the exact
  commit a release tag points at) must not report a bare `X.Y.Z-NG` string
  identical to a real release. Reported version output for such builds should
  carry build provenance (e.g. `git describe --tags --always --dirty` output,
  or an equivalent `+dev.<short-sha>` suffix), so a development build can
  never be mistaken for the tagged release it is heading toward.
- Only a commit that is exactly the tagged `vX.Y.Z-NG` ref reports the bare
  version string with no suffix.

## Cutting A Release (Manual, Maintainer-Driven)

Use `doc/release-checklist.md` as the canonical release-readiness checklist
throughout this process. Complete every applicable pre-tag requirement before
creating the release tag in step 4. This section covers the tagging/branching
mechanics, not what must actually be true about the release's content before
it ships.

1. The maintainer decides the next version number (`X.Y.Z-NG`), informed by
   `CHANGELOG.md`'s `[Unreleased]` section — not derived from it automatically.
2. Cut `release/X.Y.Z-NG` from `current_dev` (via the standard throwaway-branch
   promotion flow — `current_dev` itself is never a PR head/base).

   **2a. Open the release pull request.** Immediately after cutting the release
   branch, open a Draft PR from `release/X.Y.Z-NG` to `master` using the
   dedicated release template:

   ```bash
   gh pr create \
     --repo wiki-mod/distcc-ng \
     --base master \
     --head release/X.Y.Z-NG \
     --draft \
     --title "chore(release): prepare X.Y.Z-NG" \
     --body-file .github/PULL_REQUEST_TEMPLATE/create_and_publish_release.md
   ```

   Fill in the previous release tag, Candidate SHA, release branch, and expected
   tag before treating any release evidence as current. Opening this PR triggers
   the repository's normal `pull_request` CI, but it does not trigger
   `.github/workflows/package-release.yml` by itself. A green PR run therefore
   is not evidence that the release RPM, DEB, source archives, SBOM,
   attestations, or release containers have been built or verified.

   When pre-tag package/artifact evidence is required by
   `doc/release-checklist.md`, dispatch the release workflow explicitly against
   the release branch and record the resulting run in the release PR:

   ```bash
   gh workflow run package-release.yml \
     --repo wiki-mod/distcc-ng \
     --ref release/X.Y.Z-NG \
     -f publish_container=false
   ```

   Set `publish_container=true` only when the applicable release checks require
   the container build/push path. Keep the release PR body current as the
   Candidate SHA or verification evidence changes.
3. Run the release guardrail script (`scripts/check-release-version.sh`) — it
   fails closed if the version is already tagged, or if `configure.ac`
   disagrees with the tag about to be created.
4. Tag `vX.Y.Z-NG` on the release branch's HEAD. This tag push triggers
   `package-release.yml`, which builds/publishes the release and, once
   `publish_github_release` actually publishes it, fires the `release`
   event that `changelog-update-on-release.yml` listens for.
5. `changelog-update-on-release.yml` moves `CHANGELOG.md`'s `[Unreleased]`
   section content into a new, dated `## [X.Y.Z-NG] - YYYY-MM-DD` section
   automatically, as a new commit on `current_dev` — this is no longer a
   manual step. Verify that workflow's run actually succeeded (check its
   Actions history for the tag's timestamp) before proceeding to step 7;
   if it failed, use its own `workflow_dispatch` retry path (see that
   workflow's header) rather than editing `CHANGELOG.md` by hand, since a
   manual edit racing the automated one can conflict. The tagged commit
   itself never contains this dated section — tags are immutable
   snapshots created before this reactive commit exists — this is
   expected, not a defect to fix by reordering tagging itself.
6. Bump `current_dev`'s `configure.ac` to the next planned version immediately,
   so `current_dev` never again reports the just-released number.
7. Promote to `master` only with explicit maintainer approval and thorough
   testing (existing hard rule for this repo) — never automatically.
   **A real, standing gap in the current design:** step 5's dated-section
   commit lands on `current_dev`, but the release PR from step 2a has
   `release/X.Y.Z-NG` as its head, frozen at cut time (rule 70) — it can
   never receive that later commit, so merging it as-is carries the
   release into `master` still sitting under `[Unreleased]`. This is not
   a documented limitation to route around by convention each time; it
   needs the maintainer's own explicit, justified exception for how a
   given release resolves it (rule 70's own "release branch is frozen,
   patch current_dev instead" principle, applied here) — see PR #461/
   #463 for one real precedent, not a template to repeat automatically.

## Guardrails (Fail Closed)

- Refuse to tag a release if `vX.Y.Z-NG` already exists as a git tag.
- Refuse to tag a release if `configure.ac`'s `AC_INIT` version does not
  exactly match the tag about to be created.
- Refuse to merge into `master` without explicit maintainer approval.
- Never delete or force-push an existing `release/*` branch or `vX.Y.Z-NG`
  tag.
- **No release may ever be untagged.** Every published GitHub Release must
  correspond to a real `vX.Y.Z-NG` git tag — never publish a release (or
  move a stable/`latest`-style channel pointer, if one is introduced later)
  from an ad-hoc or manual identifier (e.g. a `manual-<run-number>`-style
  fallback name). A manual/`workflow_dispatch` trigger may still build and
  upload artifacts for testing, but it must not create or update a GitHub
  Release unless a real tag drives it. This exists so every release has an
  unambiguous, permanent git reference behind it.

## Retention

Keep all `release/*` branches and `vX.Y.Z-NG` tags indefinitely. They exist
specifically so that changes and backports on a given released version can
still be tracked after the fact.
