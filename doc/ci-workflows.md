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
| `release.yml` | `push` (`v*` tags, `current_dev`), `workflow_dispatch` (`tag`, `publish_container`, `release_notes`), `release: published` | A `v*` tag push is the real release (POL-RELEASE-07): version check, build+test, e2e, packages+SBOM, `gh release create`, container build+scan+push, multi-arch manifest incl. `:latest`. `workflow_dispatch` is the pre-tag dry run (POL-RELEASE-05): same path without a GitHub Release, containers pushed only with `publish_container=true`, `:latest` never moved. `release: published` inserts the notes into `CHANGELOG.md`; a `current_dev` push refreshes the draft release. |
| `nightly.yml` | `workflow_dispatch`, `schedule` (`0 4 * * *`) | Builds+tests the `default` and `sanitizer` variants against `current_dev`, runs distributed e2e (plus the full bidirectional e2e on manual dispatch only), publishes `distcc-ng-nightly:latest`, and reports status |
| `housekeeping.yml` | `workflow_dispatch` (`task` choice), `schedule` (`0 5 * * 1` heartbeat, `0 2 * * *` e2e image), `push`/`pull_request` path-filtered `test/e2e/Dockerfile` | GHCR package pruning (`gc`), the weekly distributed ccache heartbeat plus its non-gating plain-compiler control build, and building+publishing the `distcc-ng-e2e` test image |

## Cross-reference matrix

**GHCR login**: `ci.sh`'s `_ci_registry_login`, called by every command
that pushes to or reads from GHCR, using the calling step's `REGISTRY_TOKEN`
(the default `github.token` almost everywhere, `GHCR_PACKAGE_DELETE_PAT` for
`housekeeping.yml`'s `gc` job).

**Harden Runner**: `ci.sh harden start` (right after checkout) and
`ci.sh harden stop` (last step, `if: always()`) install, run, and flush the
StepSecurity agent in audit-only egress mode. Agent version and SHA256 live
in `build-manifest.yml` (`external_versions.harden_runner_agent`), policy and
endpoints in its `harden_runner` section. On runners the agent does not
support (arm64, non-Linux) both steps log `NotRun` with the reason.

**No composite or marketplace actions**: workflows contain no `uses:` step
at all (enforced by `ci_guard_orchestrator_only`). All shared logic,
including labeler rules, project-board add, standing-issue reporting,
apt/brew install, GHCR login, and Harden Runner, lives in `ci.sh`.

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
`master` via explicit maintainer-approved release PRs. A `schedule` or
unscoped `workflow_dispatch` change therefore takes effect only once the
changed workflow file has been promoted to `master`.
