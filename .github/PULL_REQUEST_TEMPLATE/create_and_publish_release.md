<!--
Dedicated template for preparing and publishing a real distcc-ng release.
The canonical release requirements live in doc/release-checklist.md.
This PR body records execution state and evidence for one concrete release.
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

If the Candidate SHA changes for any reason, every previously completed PRETAG or ARTIFACT verification that depends on repository content becomes stale and must be reset and re-verified against the new Candidate SHA. Evidence from an older Candidate SHA may only be retained when the corresponding canonical checklist item is demonstrably independent of repository content.

## Live Release Checklist - Source Of Truth

This table is the single status-bearing execution record for this release. Findings may be discussed in comments, but the authoritative state must be reflected here so it does not disappear into comment history.

Canonical release requirements:
`doc/release-checklist.md`

Do not rewrite or independently redefine canonical checks in this PR. Reference the applicable checklist section/item and record only this release's execution state and evidence.

Allowed status values are `Pending`, `Passed`, `Failed`, and `N/A`. Every `N/A` needs a concrete rationale.

| Checklist / control reference | Status | Candidate SHA / artifact | Evidence | Notes / N/A rationale |
| --- | --- | --- | --- | --- |
| `doc/release-checklist.md`: <section / item> | Pending | | | |
| Release control: Candidate SHA still matches the intended release candidate | Pending | | | |
| Release control: no unresolved release blocker remains | Pending | | | |
| Release control: final AGENTS.md compliance review | Pending | | | |
| Release control: explicit maintainer approval for promotion to `master` per rule 81 | Pending | | | |

The maintainer-approval row may only be marked `Passed` after explicit approval from the maintainer identity authorized by `AGENTS.md` rule 81. An agent must never infer, grant, or record that approval on the maintainer's behalf.

## CI / Release Pipeline Evidence

Opening this release PR triggers the repository's normal `pull_request` CI. It does **not** by itself trigger `.github/workflows/package-release.yml`.

This table records evidence only. Completion state belongs in the single Live Release Checklist above.

| Pipeline | Trigger | Candidate SHA / tag | Evidence |
| --- | --- | --- | --- |
| Normal PR CI (`c-build.yml` and other PR workflows) | Release PR | | |
| Pre-tag package/artifact verification (`package-release.yml`) | Manual `workflow_dispatch` | | |
| Real release pipeline (`package-release.yml`) | `v*` tag push | | |

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
Observed result:

## PRETAG Evidence

This section carries supporting evidence only. Set `Passed`, `Failed`, or `N/A` only in the Live Release Checklist.

Candidate SHA:
Previous release tag:

| Evidence subject | Bound Candidate SHA / reference | Evidence |
| --- | --- | --- |
| Previous-tag to Candidate-SHA change review | | |
| Normal pull-request CI | | |
| Manual package-release verification | | |
| Required functional verification | | |
| Required negative / invalid-input verification | | |
| Version / changelog consistency | | |
| Release-branch integrity | | |

### Release Branch Integrity

Negative claims such as "the release branch contains no release-only fixes" or "there is no unreviewed branch drift" require an explicit reproducible check. Do not treat them as proven from assumption or visual familiarity.

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

This section carries supporting evidence only. Set release-check completion state only in the Live Release Checklist.

Expected release tag:
Actual release tag:
Tag SHA:
Candidate SHA:

| Artifact / verification | Bound tag / artifact | Evidence |
| --- | --- | --- |
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

This section documents observed publication evidence only. It is **not** a technical pre-publication gate and carries no independent completion status.

Publication state observed:
Tagged workflow run:
Published release:

A real pre-publication gate requires a separate workflow change and is outside this template's scope.

## Promotion To `master`

Promotion readiness is determined by the single Live Release Checklist above. Do not duplicate CI, artifact, blocker, or governance completion state here.

Maintainer approval is governed by `AGENTS.md` rule 81 and is never inferred from a previous release, another PR, silence, or a generic request to work through this checklist.

Approval reference:
Approved Candidate SHA / tag:
Promotion PR / reference:

## Open Findings / Blockers

| Finding | Required action | Reference / evidence |
| --- | --- | --- |
| | | |

Any unresolved blocker must keep the corresponding Live Release Checklist control row from being marked `Passed`.

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

If a gap is discovered, update the canonical checklist so future releases inherit the lesson. Do not fix only this PR body's local evidence text.

## Final Release Record

Final Candidate SHA:
Final tag:
Final tagged workflow run:
Final GitHub Release:
Promotion PR / reference:
Remaining follow-up work:
