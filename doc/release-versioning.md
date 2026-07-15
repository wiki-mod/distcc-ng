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

1. The maintainer decides the next version number (`X.Y.Z-NG`), informed by
   `CHANGELOG.md`'s `[Unreleased]` section — not derived from it automatically.
2. Cut `release/X.Y.Z-NG` from `current_dev` (via the standard throwaway-branch
   promotion flow — `current_dev` itself is never a PR head/base).
3. Run the release guardrail script (`scripts/check-release-version.sh`) — it
   fails closed if the version is already tagged, or if `configure.ac`
   disagrees with the tag about to be created.
4. Tag `vX.Y.Z-NG` on the release branch's HEAD.
5. Move `CHANGELOG.md`'s `[Unreleased]` section content into a new, dated
   `## [X.Y.Z-NG] - YYYY-MM-DD` section.
6. Bump `current_dev`'s `configure.ac` to the next planned version immediately,
   so `current_dev` never again reports the just-released number.
7. Promote to `master` only with explicit maintainer approval and thorough
   testing (existing hard rule for this repo) — never automatically.

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
