<!--
Dedicated template for preparing and publishing a real distcc-ng release.
The canonical release requirements, and the canonical definition of every
REL-* item ID used below, live in doc/release-checklist.md. This PR body
records execution state and evidence for one concrete release only.
-->

> **Transparency notice:** This release preparation may use AI assistance. Every factual claim and every completed item still requires the evidence required by `AGENTS.md`, especially rules 62 and 87.

## Release Identity

Release version:
Previous release tag:
Candidate SHA:
Release branch:
Expected release tag:

Release type:
- [ ] Regular release
- [ ] Hotfix release

### Candidate SHA invariant

All repository-content-dependent verification evidence in this PR is bound to the Candidate SHA recorded above.

If the Candidate SHA changes for any reason, every previously completed evidence entry that depends on repository content becomes stale and must be reset and re-verified against the new Candidate SHA. Evidence from an older Candidate SHA may only be retained when the corresponding canonical checklist item is demonstrably independent of repository content.

**`Blocked` items specifically:** a content-dependent `Blocked` item resets exactly like `Passed`/`Failed` on a Candidate SHA change. A purely environmental `Blocked` item (its cause has nothing to do with repository content) does not need to reset, but must still be re-attempted at least once against the current Candidate SHA before it can support a release decision — "still blocked" carried forward without a fresh attempt is a stale claim, not a confirmed one.

## Live Release Checklist - Source Of Truth

This table is the single status-bearing execution record for this release. Every row is a stable `REL-*` ID whose canonical definition lives in `doc/release-checklist.md`; this table restates only the imperative and records this release's own execution state and evidence. Findings may be discussed in comments, but the authoritative state must be reflected here so it does not disappear into comment history.

Do not rewrite or independently redefine a canonical check in this PR. If a check itself needs to change, that is a `doc/release-checklist.md` edit (see Checklist Maintenance below), reflected here only as a status update.

Allowed status values: `Pending`, `Passed`, `Failed`, `Blocked`, `N/A`.
- `N/A` requires a concrete rationale.
- `Blocked` requires a matching row in Open Findings / Blockers below naming the cause and required action. A `Blocked` item can never become `Passed` by inference — it must actually run.
- No row may be `Passed` while an Open Findings / Blockers row still references it as unresolved.

### Mandatory core (every release)

| ID | Item (see `doc/release-checklist.md` for the full definition) | Status | Candidate SHA / artifact | Evidence | Notes / N/A rationale |
| --- | --- | --- | --- | --- | --- |
| REL-GOV-01 | Candidate SHA still matches the intended release candidate | Pending | | | |
| REL-GOV-02 | No unresolved release blocker remains | Pending | | | |
| REL-GOV-03 | Final AGENTS.md self-check performed (rule 78(c)) | Pending | | | |
| REL-GOV-04 | Independent review of the finished release PR performed (rule 78(a)) | Pending | | | |
| REL-PRECUT-01 | `[Unreleased]` reviewed end-to-end against real PR history since last tag | Pending | | | |
| REL-PRECUT-02 | A real, dated `## [X.Y.Z-NG] - YYYY-MM-DD` section exists for every tag since the last checklist run | Pending | | | |
| REL-PRECUT-03 | No open unresolved `security`-labeled issue blocking, or a documented maintainer decision to ship anyway | Pending | | | |
| REL-PRECUT-04 | `scripts/check-release-version.sh` run for real against the intended tag | Pending | | | |
| REL-PRECUT-05 | Every `support-upstream/` entry since last release has file + README row | Pending | | | |
| REL-PRECUT-06 | `master`'s copy of every `release:`-event-triggered workflow matches `current_dev`'s | Pending | | | |
| REL-PRECUT-07 | Release branch contains no release-only fixes relative to `current_dev` | Pending | | | |
| REL-PRECUT-08 | No unreviewed drift beyond the release branch's stated expected relationship to `current_dev` | Pending | | | |
| REL-PRECUT-09 | Every commit/PR since the previous tag classified against `doc/verification-checklist.md`'s 9 categories, with real evidence for every touched category | Pending | | | |
| REL-ART-01a | Container image labels match published image — `distcc-ng` | Pending | | | |
| REL-ART-01b | Container image labels match published image — `distcc-ng-pump` | Pending | | | |
| REL-ART-01c | Container image labels match published image — `distcc-ng-nightly` | Pending | | | |
| REL-ART-02 | Seccomp compiled in and enforcing, every shipped artifact class | Pending | | | |
| REL-ART-03 | Built `.rpm`/`.deb` declares dependencies matching real linked libraries | Pending | | | |
| REL-ART-04a | Real end-to-end distributed compile succeeds — plain | Pending | | | |
| REL-ART-04b | Real end-to-end distributed compile succeeds — pump | Pending | | | |
| REL-ART-05 | SBOM attached, confirmed present on the real GitHub Release page | Pending | | | |
| REL-ART-06 | Build attestation attached, confirmed present on the real GitHub Release page | Pending | | | |
| REL-CI-01 | Real `pull_request`-triggered CI run exists for this release PR | Pending | | | |
| REL-CI-02 | Manual pre-tag package/artifact verification run, if used | Pending | | | |
| REL-CI-03 | Real tag-triggered `package-release.yml` run exists and succeeded | Pending | | | |
| REL-CI-04 | `release: types: [published]` actually triggered `changelog-update-on-release.yml` | Pending | | | |
| REL-DOC-01 | `README.md`/`doc/docker.md` quick-start references match what this release publishes | Pending | | | |
| REL-DOC-02 | Every user-visible change since last release is in `CHANGELOG.md` under a dated section | Pending | | | |
| REL-PROMO-01 | Explicit, fresh maintainer approval for this specific promotion | Pending | | | |
| REL-PROMO-02 | `git log master..current_dev` actually read | Pending | | | |
| REL-PROMO-03 | `current_dev`'s `configure.ac` bumped to next planned version after tagging | Pending | | | |
| REL-PROMO-04 | Changelog-automation commit landed on `current_dev` and is accounted for in this promotion | Pending | | | |

### Conditional (fill in only rows whose trigger condition applies to this release's actual diff; otherwise mark the whole block `N/A` once, citing the diff command used)

Diff command used to classify this release's change surface (e.g. `git diff --stat <previous-tag>..<Candidate SHA>`):

| ID | Item | Trigger | Status | Candidate SHA / artifact | Evidence | Notes / N/A rationale |
| --- | --- | --- | --- | --- | --- | --- |
| REL-ART-07 | Effective seccomp denylist matches intent | Seccomp/sandbox files or a `distccd`-building Dockerfile stage changed | Pending | | | |
| REL-ART-08 | Real negative test: denied syscall actually blocked | Same trigger as REL-ART-07 | Pending | | | |
| REL-ART-09 | Real second-user cross-permission check on a real Unix-permission filesystem | Permission/file-mode-affecting file changed | Pending | | | |
| REL-ART-10 | Real two-container distribution test | Distribution/compiler-identity code changed | Pending | | | |
| REL-ART-11 | Published-stage identity re-confirmed via registry API | Any Dockerfile or `package-release.yml` changed | Pending | | | |
| REL-COMPAT-01 | New hard dependency called out against compatibility policy | A new hard dependency was introduced | Pending | | | |
| REL-COMPAT-02 | Compatibility-policy platform matrix re-confirmed | Platform-conditional code changed | Pending | | | |

## CI / Release Pipeline Evidence (evidence appendix — no independent status)

Opening this release PR triggers the repository's normal `pull_request` CI. It does **not** by itself trigger `.github/workflows/package-release.yml`.

This table records evidence only. Completion state belongs in the single Live Release Checklist above (`REL-CI-01`-`REL-CI-04`).

| ID | Pipeline | Trigger | Candidate SHA / tag | Evidence |
| --- | --- | --- | --- | --- |
| REL-CI-01 | Normal PR CI (`c-build.yml` and other PR workflows) | Release PR (`pull_request` event) | | |
| REL-CI-02 | Pre-tag package/artifact verification (`package-release.yml`) | Manual `workflow_dispatch` | | |
| REL-CI-03 | Real release pipeline (`package-release.yml`) | `v*` tag push | | |
| REL-CI-04 | Changelog automation (`changelog-update-on-release.yml`) | `release: types: [published]` | | |

A green normal PR CI run is not evidence that RPM, DEB, source archives, SBOM, attestations, or release containers from `package-release.yml` were already built or verified.

### Manual pre-tag package/artifact verification (REL-CI-02 evidence)

Run the release workflow explicitly against the current release branch when pre-tag package/artifact evidence is required:

```bash
gh workflow run package-release.yml \
  --repo wiki-mod/distcc-ng \
  --ref release/X.Y.Z-NG \
  -f publish_container=false
```

Use `publish_container=true` only when the applicable release checks require the container build/push path as part of the manual verification run.

Candidate SHA:
Workflow run:
`publish_container` value:
Observed result:

## PRETAG Evidence (evidence appendix — no independent status)

Every row below must correspond to a `REL-PRECUT-*` ID above. This section carries supporting detail only; set `Passed`/`Failed`/`Blocked`/`N/A` only in the Live Release Checklist.

Candidate SHA:
Previous release tag:

| ID | Bound Candidate SHA / reference | Evidence |
| --- | --- | --- |
| | | |

### Release Branch Integrity (REL-PRECUT-07 evidence)

Negative claims such as "the release branch contains no release-only fixes" require an explicit reproducible check. Do not treat them as proven from assumption or visual familiarity.

Expected relationship:

Verification command:
```bash

```

Observed result:
```text

```

Candidate SHA:

### Release Branch Drift Check (REL-PRECUT-08 evidence)

Negative claims such as "there is no unreviewed branch drift" require an explicit reproducible check. Do not treat them as proven from assumption or visual familiarity.

Verification command:
```bash

```

Observed result:
```text

```

Candidate SHA:

### Verification-Checklist Sweep (REL-PRECUT-09 evidence)

Every commit/PR merged since the previous release tag goes in this table — a complete accounting of the commit range, not just the interesting rows. A commit touching none of `doc/verification-checklist.md`'s 9 categories still gets a row, with category left as "none".

Commit range: `<previous tag>..<Candidate SHA>`

| Commit / PR | Touched paths (summary) | Category (or "none") | Evidence (named CI test + run URL, or manual-check detail) |
| --- | --- | --- | --- |
| | | | |

## ARTIFACT Evidence (evidence appendix — no independent status)

Every row below must correspond to a `REL-ART-*` or `REL-COMPAT-*` ID above.

Expected release tag:
Actual release tag:
Tag SHA:
Candidate SHA:

| ID | Bound tag / artifact | Evidence |
| --- | --- | --- |
| | | |

A manual pre-tag `workflow_dispatch` result (REL-CI-02) is not proof that the later tag-triggered artifacts (REL-CI-03) were produced successfully. Record the real tag-triggered run separately.

## Publication State

The current repository workflow has no independent manual pre-publication gate between pushing a real release tag and the publication path in `package-release.yml`.

This section documents observed publication evidence only. It is **not** a technical pre-publication gate and carries no independent completion status.

Publication state observed:
Tagged workflow run:
Published release:
`changelog-update-on-release.yml` run for this tag (REL-CI-04 evidence):

A real pre-publication gate requires a separate workflow change and is outside this template's scope.

## Promotion To `master`

Promotion readiness is determined by the single Live Release Checklist above (`REL-PROMO-*` and `REL-GOV-*`). Do not duplicate CI, artifact, blocker, or governance completion state here.

Maintainer approval is governed by `AGENTS.md` rule 81 and is never inferred from a previous release, another PR, silence, or a generic request to work through this checklist.

Approval reference:
Approved Candidate SHA / tag:
Promotion PR / reference:

## Open Findings / Blockers

| Finding | Corresponding checklist ID(s) | Required action | Reference / evidence |
| --- | --- | --- | --- |
| | | | |

Every row above whose status is `Blocked` must appear here. No checklist row may be `Passed` while a matching Open Findings row remains unresolved.

## Checklist Maintenance

During this release, did verification discover a gap in the canonical release coverage?

- [ ] Missing release check (needs a new `REL-*` ID)
- [ ] Missing functional test
- [ ] Missing regression test
- [ ] Missing negative / invalid-input test
- [ ] Missing artifact verification
- [ ] Previously unknown failure class
- [ ] No checklist gap discovered

Required `doc/release-checklist.md` update (name the new or changed ID explicitly):

If a gap is discovered, update the canonical checklist — assign the next unused `REL-*` ID in the relevant family (never reuse or renumber an existing one, same discipline as AGENTS.md rule 64 for rule numbers) — so future releases inherit the lesson. Do not fix only this PR body's local evidence text.

## Final Release Record

Final Candidate SHA:
Final tag:
Final tagged workflow run:
Final GitHub Release:
Promotion PR / reference:
Remaining follow-up work:
