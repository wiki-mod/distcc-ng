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
| `housekeeping.yml` | `workflow_dispatch` (`task` choice), `schedule` (`0 5 * * 1`) | GHCR package pruning (`gc`), the weekly SOT pin refresh (`sot-update`: one pull request moving image digests and tool versions, with Validate/Security dispatched on it), and the weekly distributed ccache heartbeat plus its non-gating plain-compiler control build |

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

**GHCR image namespace** -- four published package names, no tag overlap:

| Image | Published by | Consumed by |
|---|---|---|
| `distcc-ng`, `distcc-ng-pump` | `release.yml`'s `build_container`/`publish_manifest` | end users only |
| `distcc-ng-nightly` | `nightly.yml`'s `publish` job | end users only |
| `distcc-ng-buildtools` | `validate.yml`'s `publish_buildtools` job | CI itself: every lint run, and the toolchain base of the e2e images |

`distcc-ng-e2e` is no longer published; it stays in
`release.ghcr_packages` only so `ci.sh gc` can prune its existing versions.

**Path-based gating**: `security.yml`'s `clusterfuzzlite` job and
`validate.yml`'s `plan` job both gate on the content-based
`impact_classes` in `build-manifest.yml`; no workflow uses a literal
`paths:` filter. A docs-only PR selects no build, test, or e2e work.

## Distributed-compile e2e (`ci.sh e2e <mode>`)

One harness, defined per mode in `build-manifest.yml` (`e2e.modes`):

| Mode | Legs (client:server) | Passes | Workload | Floor | Run by |
|---|---|---|---|---|---|
| `distributed` | `ng:ng` | plain, pump | `self-compile` | 5 | `validate.yml` (when planned), `nightly.yml`, `release.yml` |
| `heartbeat` | `ng:ng` | plain | `ccache` | 20 | `housekeeping.yml` weekly |
| `full` | `ng:native`, `native:ng` | plain, pump | `samba` (bounded `waf` targets) | `objects` | `nightly.yml` manual dispatch |

- `ng` is this checkout, built into `test/e2e/Dockerfile`'s `ng` stage; `native` is Debian's packaged `distcc`/`distcc-pump` (`native` stage). Both stages build on `distcc-ng-buildtools`, the one owner of the toolchain, and each stage is a single `ci.sh image <target>` call with the checkout bind-mounted for that step only.
- Every leg and pass starts a fresh `distccd` server, runs the workload in a fresh client container (`ci.sh workload ...`, checkout mounted read-only), and then counts `COMPILE_OK` lines in the server's own log from the client network. The build passes only if that count reaches the floor; `objects` means the number of `.o` files the build itself produced. A distcc-ng server additionally must log no warning-or-worse line.
- `ci.sh e2e control` builds the same ccache revision with the plain compiler only; a failure there points at the toolchain rather than distribution.
- `full` is too heavy for every PR. The CI run is bounded by `e2e.modes.full.extra`; an unbounded run is the same command on a larger host with `extra` set to `""` in a local copy of the manifest.

Run locally with Docker: `bash .github/scripts/ci.sh e2e distributed` (or `heartbeat`, `full`, `control`).

## Schedule collisions

All `cron:` schedules, sorted (UTC):

| Time | Day pattern | Workflow | Job |
|---|---|---|---|
| 04:00 | daily | `nightly.yml` | `build_test`/`sanitizer`/`e2e`/`publish`/`report` |
| 05:00 | Sun | `security.yml` | `codeql`/`osv-scan`/`scorecard`/`clusterfuzzlite` |
| 05:00 | Mon | `housekeeping.yml` | `sot_update`/`heartbeat`/`control`/`report` |
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
changed workflow file has been promoted to `master`. This includes
`ci.sh sot-update`'s own `gh workflow run` of `validate.yml` and
`security.yml` on its update branch: until those files exist on `master`,
that dispatch returns 404 and the `sot_update` job fails instead of
leaving an untested pull request behind.
