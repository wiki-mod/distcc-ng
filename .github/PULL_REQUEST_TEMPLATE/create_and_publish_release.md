<!--
Dedicated template for preparing and publishing a real distcc-ng release.
The canonical release requirements live in doc/release-checklist.md.
This PR body records execution state and evidence for one concrete release.
-->

> **Transparency notice:** This release preparation may use AI assistance. Every factual claim and every checked item still requires the evidence required by `AGENTS.md`, especially rules 62 and 87.

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

If the Candidate SHA changes for any reason, every previously completed PRETAG or ARTIFACT verification that depends on repository content becomes stale and must be reset and re-verified against the new Candidate SHA. Evidence from an older Candidate SHA may only be retained when the corresponding canonical checklist item is demonstrably independent of repository content.

## Live checklist - source of truth

This PR body is the current release status. Findings may be discussed in comments, but the authoritative status must be reflected back here so it does not disappear into comment history.

Canonical release requirements:
`doc/release-checklist.md`

This template does not redefine those requirements. It records their execution for this release.

### Release-process status

- [ ] Release identity above is complete.
- [ ] Candidate SHA still matches the intended release candidate.
- [ ] Applicable PRETAG requirements from `doc/release-checklist.md` are complete.
- [ ] Normal pull-request CI for this release PR is complete for the current Candidate SHA.
- [ ] Required manual pre-tag package/artifact verification is complete for the current Candidate SHA.
- [ ] Real tag-triggered package/release workflow has completed for the final tag.
- [ ] Applicable artifact-verification requirements from `doc/release-checklist.md` are complete.
- [ ] No unresolved release blocker remains.
- [ ] Final AGENTS.md compliance review is complete.
- [ ] Explicit maintainer approval for promotion to `master` has been recorded.

The maintainer-approval checkbox above may only be checked after explicit approval from the maintainer identity authorized by `AGENTS.md` rule 81. An agent must never infer, grant, or mark this approval on the maintainer's behalf.

## CI / Release Pipeline Status

Opening this release PR triggers the repository's normal `pull_request` CI. It does **not** by itself trigger `.github/workflows/package-release.yml`.

| Pipeline | Trigger | Candidate SHA / tag | Status | Evidence |
| --- | --- | --- | --- | --- |
| Normal PR CI (`c-build.yml` and other PR workflows) | Release PR | | Pending | |
| Pre-tag package/artifact verification (`package-release.yml`) | Manual `workflow_dispatch` | | Pending | |
| Real release pipeline (`package-release.yml`) | `v*` tag push | | Pending | |

A green normal PR CI run is not evidence that RPM, DEB, source archives, SBOM, attestations, or release containers from `package-release.yml` were already built or verified.

### Manual pre-tag package/artifact verification

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
Result:

## Release Checklist Execution

Use the exact current items from `doc/release-checklist.md`. Do not copy their definitions into this PR and then maintain an independent version here.

Allowed status values are `Pending`, `Passed`, `Failed`, and `N/A`. Every `N/A` needs a concrete rationale.

| Canonical checklist section / item | Status | Candidate SHA / artifact | Evidence | Notes / N/A rationale |
| --- | --- | --- | --- | --- |
| | Pending | | | |

## PRETAG Evidence

Candidate SHA:
Previous release tag:

| Check | Result | Evidence |
| --- | --- | --- |
| Canonical PRETAG checklist coverage | | |
| Previous-tag to Candidate-SHA change review | | |
| Normal pull-request CI | | |
| Manual package-release verification | | |
| Required functional verification | | |
| Required negative / invalid-input verification | | |
| Version / changelog consistency | | |
| Release-branch integrity | | |

### Release Branch Integrity

Negative claims such as "the release branch contains no release-only fixes" or "there is no unreviewed branch drift" require an explicit reproducible check. Do not mark them complete from assumption or visual familiarity.

Expected relationship:

Verification command:
```bash

```

Observed result:
```text

```

Candidate SHA:

### Release Branch Drift Check

Verification command:
```bash

```

Observed result:
```text

```

Candidate SHA:

## ARTIFACT Evidence

Expected release tag:
Actual release tag:
Tag SHA:
Candidate SHA:

| Artifact / verification | Result | Evidence |
| --- | --- | --- |
| Canonical artifact checklist coverage | | |
| Tagged package-release workflow | | |
| Source artifact | | |
| DEB | | |
| RPM | | |
| Container variants, where applicable | | |
| SBOM | | |
| Build attestation | | |
| Functional verification against real release artifacts | | |

A manual pre-tag `workflow_dispatch` result is not proof that the later tag-triggered artifacts were produced successfully. Record the real tag-triggered run separately.

## Publication State

The current repository workflow has no independent manual pre-publication gate between pushing a real release tag and the publication path in `package-release.yml`.

This section therefore documents the observed publication state. It is **not** a technical pre-publication gate.

Publication status:
Tagged workflow run:
Published release:

A real pre-publication gate requires a separate workflow change and is outside this template's scope.

## Promotion To `master`

- [ ] All applicable canonical release checks are complete.
- [ ] All evidence refers to the current Candidate SHA or the corresponding final tagged artifact.
- [ ] Normal PR CI is complete for the current Candidate SHA.
- [ ] Required package/artifact verification is complete.
- [ ] No unresolved release blocker remains.
- [ ] Final AGENTS.md compliance review completed.
- [ ] Explicit maintainer approval for this promotion to `master` recorded.

Maintainer approval is governed by `AGENTS.md` rule 81 and is never inferred from a previous release, another PR, silence, or a generic request to work through this checklist.

## Open Findings / Blockers

| Status | Finding | Required action | Reference / evidence |
| --- | --- | --- | --- |
| | | | |

## Checklist Maintenance

During this release, did verification discover a gap in the canonical release coverage?

- [ ] Missing release check
- [ ] Missing functional test
- [ ] Missing regression test
- [ ] Missing negative / invalid-input test
- [ ] Missing artifact verification
- [ ] Previously unknown failure class
- [ ] No checklist gap discovered

Required `doc/release-checklist.md` update / reference:

If a gap is discovered, update the canonical checklist so future releases inherit the lesson. Do not fix only this PR body's local checklist text.

## Final Release Record

Final Candidate SHA:
Final tag:
Final tagged workflow run:
Final GitHub Release:
Promotion PR / reference:
Remaining follow-up work:
