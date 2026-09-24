# CI workflow landscape

A map of `.github/workflows/*.yml`: what triggers each file, what it does,
and how they cross-reference each other. Rewritten for the CI Rewrite 1.2
architecture (Issue #479): a single engine, `.github/scripts/ci.sh`, does
every real decision and action; the 5 workflow files below are thin
orchestrators whose `run:` steps each call exactly one `ci.sh` subcommand
(enforced by `ci.sh lint`'s `ci_guard_orchestrator_only`). The single
source of truth for versions, build matrix, and content-based impact
classification is `.github/yaml/build-manifest.yml`. Companion to
`doc/docker.md` (which covers the container images themselves). Re-verify
against the actual YAML and `ci.sh` before relying on this after either
changes.

## Per-file summary

| File | Trigger(s) | What it does |
|---|---|---|
| `validate.yml` | `pull_request`/`pull_request_target` (several types), `push` (`current_dev`/`master`), `issues: opened`, `workflow_dispatch` | PR metadata gates (title/tracking/changelog), static lint (actionlint/shellcheck/guards), `ci.bats` self-test, content-based impact planning, the build/test matrix, distributed e2e, the verify-image build+self-test, publishing `distcc-ng-buildtools:latest`, and PR labeling/project-board automation |
| `security.yml` | `push`/`pull_request` (`current_dev`/`master`), `workflow_dispatch`, `schedule` (`0 5 * * 0` weekly, `0 6 1,15 * *` monthly), `branch_protection_rule` | CodeQL (matrix `c-cpp`/`python`/`actions`), OSV-Scanner, OpenSSF Scorecard, ClusterFuzzLite fuzzing (path-filtered on `pull_request` via content-based impact classification), and the OpenSSF Best Practices Baseline recheck (`workflow_dispatch`/monthly cron only) |
| `release.yml` | `workflow_dispatch` (`tag`, optional `release_notes`), `release: published`, `push` (`current_dev`) | Changelog insertion and draft-release refresh (event- or dispatch-triggered); a `workflow_dispatch` additionally runs the full build+test+package+container release-cut path. **See the note below -- this trigger design is under active discussion, not settled.** |
| `nightly.yml` | `workflow_dispatch`, `schedule` (`0 4 * * *`) | Builds+tests the `default` and `sanitizer` variants against `current_dev`, runs distributed e2e (plus the full bidirectional e2e on manual dispatch only), publishes `distcc-ng-nightly:latest`, and reports status |
| `housekeeping.yml` | `workflow_dispatch` (`task` choice), `schedule` (`0 5 * * 1` heartbeat, `0 2 * * *` e2e image), `push`/`pull_request` path-filtered `test/e2e/Dockerfile` | GHCR package pruning (`gc`), the weekly distributed ccache heartbeat plus its non-gating plain-compiler control build, and building+publishing the `distcc-ng-e2e` test image |

**Note on `release.yml`'s trigger design:** the previous `package-release.yml`
triggered the real release path on `push: tags: v*`, with `workflow_dispatch`
reserved for a pre-tag verification-only dry run (no real `gh release
create`). The rewritten `release.yml` has no tag-push trigger at all --
`workflow_dispatch`'s `tag` input runs the entire real release path
unconditionally, so there is currently no way to dry-run it without cutting
a real GitHub Release. This is an open question tracked in PR #544, not a
decided design; do not treat this table's description of current behavior
as the intended final state.

## Cross-reference matrix

**Composite actions actually used**: only `.github/actions/ghcr-login`
(shared GHCR `docker login`, different tokens per caller: the default
`github.token` almost everywhere, `GHCR_PACKAGE_DELETE_PAT` for
`housekeeping.yml`'s `gc` job) and `.github/actions/harden-runner` (the one
structural exception to the zero-SHA-outside-SOT rule -- a runner-level
eBPF agent with no CLI/native equivalent). Every other piece of shared
logic (labeler rules, project-board add, standing-issue reporting,
apt/brew install, build-provenance -- see the open question in PR #544)
lives in `ci.sh` itself, not a composite action.

**GHCR image namespace** -- five package names, no tag overlap:

| Image | Published by | Consumed by |
|---|---|---|
| `distcc-ng`, `distcc-ng-pump` | `release.yml`'s `build_container`/`publish_manifest` | end users only |
| `distcc-ng-nightly` | `nightly.yml`'s `publish` job | end users only |
| `distcc-ng-buildtools` | `validate.yml`'s `publish_buildtools` job | referenced by CI itself (every `_ci_lint_buildtools_run`/verification call) |
| `distcc-ng-e2e` | `housekeeping.yml`'s `e2e_image` job | `ci.sh e2e`'s distributed-compile harness |

**Path-filter overlap**: `housekeeping.yml`'s `e2e_image` job and
`security.yml`'s `clusterfuzzlite` job are the only two with any
path-based gating on `pull_request` (a literal `paths:` filter for the
former, content-based `impact_classes.fuzz` classification for the
latter). Every other `pull_request`-triggered job runs on any PR touching
`current_dev`/`master`, with `validate.yml`'s `plan` job then selecting
which of `build_test`/`e2e`/`verify_image` actually do real work based on
the diff (a docs-only PR selects none of them).

## Schedule collisions

All `cron:` schedules, sorted (UTC):

| Time | Day pattern | Workflow | Job |
|---|---|---|---|
| 02:00 | daily | `housekeeping.yml` | `e2e_image` |
| 04:00 | daily | `nightly.yml` | `build_test`/`sanitizer`/`e2e`/`publish`/`report` |
| 05:00 | Sun | `security.yml` | `codeql`/`osv-scan`/`scorecard`/`clusterfuzzlite` |
| 05:00 | Mon | `housekeeping.yml` | `heartbeat`/`control`/`report` |
| 06:00 | 1st/15th (any weekday) | `security.yml` | `openssf` |

**Known collision**: `security.yml`'s own two schedules (`0 5 * * 0` and
`0 6 1,15 * *`) both fire whenever the 1st or 15th of a month falls on a
Sunday -- each is explicitly gated to its own `github.event.schedule`
value (see `codeql`/`osv-scan`/`scorecard`/`clusterfuzzlite`'s `if:` vs.
`openssf`'s), so this collision runs both sets of jobs in the same
workflow trigger rather than either being silently skipped; not itself a
bug, just worth knowing when reading a run's job list.

## Branch dormancy

`schedule` (and a plain, unscoped `workflow_dispatch`) is only honored
from the copy of a workflow file present on the **default branch**
(`master`) -- this repo develops on `current_dev` and only promotes to
`master` via explicit maintainer-approved release PRs. Every `schedule`
trigger described above has no live effect until this PR merges to
`current_dev` and that in turn promotes to `master`; treat every schedule
in this table as inert until then.
