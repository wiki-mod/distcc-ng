# CI workflow landscape

A map of `.github/workflows/*.yml` (plus the composite action and labeler
config they share): what triggers each file, what it writes, and how they
cross-reference each other. Companion to `doc/docker.md` (which covers the
container images themselves, not the workflows that build them) -- keep
both in sync when either changes. Written from a full read-through of every
file (issue #356), not a summary of comments alone; re-verify against the
actual YAML before relying on this after a workflow file changes.

## Per-file summary

| File | Trigger(s) | What it does | What it writes |
|---|---|---|---|
| `actionlint.yml` | `workflow_dispatch`, `pull_request` (unfiltered), `push` to `current_dev`/`master` | Lints all workflow YAML (`action-lint` job) and `scripts/*.sh` (`shellcheck` job) via the pinned `distcc-ng-buildtools` image | nothing (pass/fail gate) |
| `add-to-project.yml` | `issues: opened`, `pull_request_target: opened` | Adds new issues/PRs to the project board (needs `PROJECT_AUTOMATION_PAT`) | project-board card |
| `c-build.yml` | `push` (`current_dev`/`master`), `pull_request` (unfiltered), `workflow_dispatch`, `schedule 03:00 daily` | Core build+test gate: `make_check` (macOS+Linux matrix), `popt_fallback_build`, `popt_vendor_check`, `distributed_e2e` (builds `test/e2e/` fresh), `coverage` (gcov/lcov + Python coverage, published to the job summary and as a build artifact -- no third-party service), `report` (schedule-only, files/updates/closes the standing nightly-broken issue) | build-provenance attestations, coverage job summary + `coverage-reports` artifact, standing nightly-broken issue (schedule runs only) |
| `changelog-check.yml` | `pull_request` (unfiltered, several types), `workflow_dispatch` | Three PR gates: CHANGELOG touched, tracking-metadata (rule 3), title convention (rule 71, warn-only) | nothing persistent |
| `changelog-update-on-release.yml` | `release: published` (guarded to non-prerelease), `workflow_dispatch` | Inserts release notes into `CHANGELOG.md`, commits to `current_dev` | commit to `current_dev` |
| `clusterfuzzlite-pr.yml` | `pull_request`, path-filtered `src/**`, `test/fuzz/**`, `.clusterfuzzlite/**` | Fuzzes `test/fuzz/fuzz_rpc_argv.c` | SARIF |
| `codeql.yml` | `push`/`pull_request` (unfiltered), `workflow_dispatch`, `schedule 05:00 Sun` | CodeQL Advanced Setup, matrix `[c-cpp, python, actions]`, each leg gated by its own path-based `changes` job | SARIF -> code-scanning |
| `labeler.yml` | `pull_request_target: [opened, synchronize]` | Applies `.github/labeler.yml`'s path-based labels | PR labels |
| `master-heartbeat.yml` | `workflow_dispatch`, `schedule 05:00 Mon` | Weekly real ccache build fully distributed against `master`; independent control build to classify failures | job summary, standing nightly-broken issue |
| `nightly-publish.yml` | `workflow_dispatch`, `schedule 04:00 daily` (weekly Samba e2e schedule commented out) | Builds+tests+publishes a moving `nightly` channel from `current_dev`: packages, `distcc-ng-nightly:latest` image, `nightly` pre-release | GHCR image, moved tag+pre-release, standing issue |
| `openssf-baseline-recheck.yml` | `workflow_dispatch`, `schedule 06:00 1st/15th` | Re-checks OpenSSF Best Practices Baseline criteria against issue #312 | issue comment |
| `osv-scanner.yml` | `pull_request`/`push` (unfiltered), `schedule 07:00 Sun`, `workflow_dispatch` | SCA scan of pinned Action refs via OSV.dev (reusable workflows) | SARIF -> code-scanning |
| `package-release.yml` | `push: tags: v*`, `workflow_dispatch` | Real tagged-release path: build+test, packages+SBOM, multi-arch container build+scan+manifest, GitHub Release | GHCR `distcc-ng`/`distcc-ng-pump`, GitHub Release, SBOMs, attestations |
| `release-drafter.yml` | `push` to `current_dev`, `pull_request: [opened, reopened, synchronize]`, `workflow_dispatch` | Maintains a draft GitHub Release; separately autolabels PRs | draft release, PR category labels |
| `scorecard.yml` | `push` (`current_dev`/`master`), `branch_protection_rule`, `schedule 06:00 Sun`, `workflow_dispatch` | OpenSSF Scorecard trial run (`publish_results: false`) | SARIF -> code-scanning, 5-day artifact |
| `verify-image-build.yml` | `push`/`pull_request` path-filtered `docker/verify/**`, `workflow_dispatch` | Builds+proves `docker/verify/Dockerfile` (ptrace self-test, real build+check, ccache+Redis round-trip, signed Samba configure dry-run) | GHCR `distcc-ng-buildtools:latest`+`:<sha>` |

## Cross-reference matrix

**Shared composite action** -- `.github/actions/nightly-status` files/updates/closes
one standing `nightly-broken`-labeled issue (issue #81 design: any caller's
success can close an issue a different caller opened). Callers: `master-heartbeat.yml`,
`nightly-publish.yml`, `c-build.yml` (its `report` job, schedule-event only),
`e2e-image-build.yml`.

**GHCR image namespace** -- four separate package names, no tag overlap:

| Image | Published by | Consumed by |
|---|---|---|
| `distcc-ng`, `distcc-ng-pump` | `package-release.yml` | end users only |
| `distcc-ng-nightly` | `nightly-publish.yml` | end users only |
| `distcc-ng-buildtools` | `verify-image-build.yml` | `actionlint.yml` (only cross-workflow image consumption in this set) |

**Path-filter overlap** -- only `clusterfuzzlite-pr.yml` and `verify-image-build.yml`
carry a real workflow-level `paths:` filter; every other `pull_request`-triggered
workflow fires on any PR (some then filter internally via their own `changes`
job, which skips steps, not the check-run). Notably: a PR touching only
`docker/verify/Dockerfile` triggers `verify-image-build.yml` as intended, but
also runs `c-build.yml`'s full build+test matrix, since that file's own
`changes` job only exempts `\.md$`/`^doc/` paths.

**Known-dangling outputs** -- not consumed by anything in this set today:
- Scorecard's `scorecard-results` workflow artifact (5-day retention) -- manual-inspection only.
- Per-image SBOM artifacts from `package-release.yml`'s `build_container` job --
  only the separate package-level SBOM (from `build_packages`) reaches
  `publish_github_release`; the per-image ones do not appear to be downloaded
  or attached anywhere.

## Schedule collisions

All `cron:` schedules, sorted (UTC):

| Time | Day pattern | Workflow |
|---|---|---|
| 03:00 | daily | `c-build.yml` |
| 04:00 | daily | `nightly-publish.yml` |
| 05:00 | Sun | `codeql.yml` |
| 05:00 | Mon | `master-heartbeat.yml` |
| 06:00 | 1st/15th (any weekday) | `openssf-baseline-recheck.yml` |
| 06:00 | Sun | `scorecard.yml` |
| 07:00 | Sun | `osv-scanner.yml` |

**Known collision**: `openssf-baseline-recheck.yml` (`0 6 1,15 * *`, day-of-week
unrestricted) and `scorecard.yml` (`0 6 * * 0`) both fire 06:00 UTC whenever
the 1st or 15th of a month falls on a Sunday. Tracked separately (not fixed
by this doc-only change).

## Branch dormancy

`schedule` (and a plain, unscoped `workflow_dispatch`) is only honored from
the copy of a workflow file present on the **default branch** (`master`,
see issue #81's history) -- this repo develops on `current_dev` and only
promotes to `master` via explicit maintainer-approved release PRs.
`nightly-publish.yml` and `master-heartbeat.yml` both self-document this: their
`schedule` trigger has no live effect until the next `current_dev`->`master`
promotion. `c-build.yml`'s own `schedule` trigger is already live (the
workflow exists on `master` today), but its new `report` job is not: since
`report` was added on `current_dev` only, `master`'s copy of `c-build.yml`
still lacks that job entirely, so the nightly standing-issue reporting this
table describes for `c-build.yml` has no live effect until the next
`current_dev`->`master` promotion, same as the two workflows above.
`codeql.yml`, `scorecard.yml`, `openssf-baseline-recheck.yml`, and
`osv-scanner.yml` carry no such caveat and are treated as already live.

## Known follow-ups (not fixed by this doc)

- Cron collision between `openssf-baseline-recheck.yml` and `scorecard.yml` (above).
- `actionlint.yml`'s `action-lint` job excludes a file named `release.yml` from
  linting -- the real release workflow is `package-release.yml`, so the
  exclusion currently matches nothing (likely stale from a rename).
