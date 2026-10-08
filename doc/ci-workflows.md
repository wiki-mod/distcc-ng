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
| `validate.yml` | `pull_request`/`pull_request_target` (`opened`, `synchronize`, `reopened`, `ready_for_review`; no label or milestone events, so a metadata change never cancels or shadows a content run; the metadata check reads labels live and reruns on `ready_for_review`), `push` (`current_dev`/`master`), `issues: opened`, `workflow_dispatch` | PR metadata gates (title/tracking/changelog), static lint (actionlint/shellcheck/guards), `ci.bats` self-test, content-based impact planning, the build/test matrix, distributed e2e, the release image and package builds, the verify image (`ci.sh verify all`: one container runs the ptrace self-test, build-test and the Samba configure dry run, then the ccache/Redis check), publishing `distcc-ng-buildtools:latest`, and PR labeling/project-board automation |
| `security.yml` | `push`/`pull_request` (`current_dev`/`master`), `workflow_dispatch`, `schedule` (`0 5 * * 0` weekly, `0 6 1,15 * *` on the 1st and 15th), `branch_protection_rule` | A `route` job (`ci.sh route security`) picks the jobs per event and cron. CodeQL (languages and suite from `security.codeql`), OSV-Scanner, OpenSSF Scorecard, ClusterFuzzLite fuzzing (sanitizers, seconds and mode from `security.cfl_run`; path-filtered on `pull_request` via content-based impact classification), and the OpenSSF Best Practices Baseline recheck (its cron, or a dispatch from `current_dev`/`master`) |
| `release.yml` | `push` (`v*` tags, `current_dev`), `workflow_dispatch` (`tag`, `publish_container`, `release_notes`), `release: published` | A `v*` tag push is the real release (POL-RELEASE-07): version check, build+test, e2e, packages+SBOM, `gh release create`, container build+scan+push, multi-arch manifest incl. `:latest`. `workflow_dispatch` is the pre-tag dry run (POL-RELEASE-05): same path without a GitHub Release, containers pushed only with `publish_container=true`, `:latest` never moved. Every run uploads the built packages as the `distcc-release-packages-<tag>` artifact; the image variants and platforms come from `release.container`. `release: published` inserts the notes into `CHANGELOG.md`; a `current_dev` push refreshes the draft release. |
| `nightly.yml` | `workflow_dispatch`, `schedule` (`0 4 * * *`) | Builds+tests every SOT variant on every OS (`ci.sh plan`: a schedule has no diff base, so the full matrix) plus the opt-in `sanitizer` variant against `current_dev`, runs distributed e2e (plus the full bidirectional e2e on manual dispatch only), publishes `distcc-ng-nightly:latest` once the matrix and e2e pass, and reports the status of every scheduled job (the dispatch-only bidirectional e2e excluded) |
| `housekeeping.yml` | `workflow_dispatch` (`task` choice), `schedule` (`0 5 * * 1`) | A `route` job (`ci.sh route housekeeping`) maps the cron or task to jobs: GHCR package pruning (`gc`), the weekly SOT pin refresh (`sot-update`: one pull request moving image digests and tool versions, with Validate/Security dispatched on it), and the weekly distributed ccache heartbeat plus its plain-compiler control build (a failure fails that job and the run; it never changes the heartbeat report) |

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
support (arm64, non-Linux) both steps log `NotRun` with the reason. arm64
is a tier limit, not a missing binary: `step-security/harden-runner` itself
skips arm64 without TLS inspection ("community tier"), so this matches the
former `harden-runner` action on the arm64 container leg.

**Transport-only actions, no composite actions**: the only `uses:` steps
are `actions/cache` and `actions/upload-artifact`. The cache and artifact
services need the Actions runtime token, which the runner passes to
JavaScript and container actions but never to a `run:` step, so `ci.sh`
cannot reach them itself. Both pins live in `build-manifest.yml`
(`ci_engine.actions`). Because `uses:` takes no expression, each workflow
repeats the exact `<repo>@<sha> # <version>` literal. `ci_guard_orchestrator_only`
fails on any `uses:` line that is not such a literal, and on any `with:`
input that does not forward a `${{ steps.<id>.outputs.<name> }}` value.
`ci_guard_pins_in_sot` fails on a SOT action that no workflow uses. Every
decision (cache path, key and restore keys; artifact name, files and
retention) comes from a `ci.sh` step output. All other shared logic,
including PR labeling, project-board add, standing-issue reporting,
apt/brew install, GHCR login, and Harden Runner, lives in `ci.sh`. PR
path labels are SOT data (`labels`, matched like `impact_classes`, with
an optional `exclude` list).

**Lint guards** (`ci.sh lint`): LF-only line endings, full-length
sha256 digests, every pin in the SOT (`ci_guard_pins_in_sot`), SOT image
pins as `name:tag@sha256:<64 hex>` and a sha256 beside every tool `url`
(`ci_guard_sot_pins`), YAML literals that repeat SOT values: crons,
dispatch choice lists, Dependabot milestones, the validate.yml job gate
of every SOT phase and the ClusterFuzzLite base-builder `FROM`
(`ci_guard_sot_mirrors`), Dockerfile paths and SOT image refs that
repeat `ci.sh` constants: the `/ci` bind target, the release `/out`
trees, the CFL `$SRC` directory and the registry
(`ci_guard_path_mirrors`), orchestrator-only workflows
(`ci_guard_orchestrator_only`), a `timeout-minutes` on every workflow
job (`ci_guard_job_timeouts`), each `CI-ERROR` id raised in one place
only (`ci_guard_error_ids`), the `What:`/`Why:`/`From:` comment form
of `AGENTS.md` `[AG-CODE-001]` (`From:` holds Issue/PR pointers only),
with a block directly above every function, nested stub and bats test,
over every shell, bats, YAML and Dockerfile in `.github/`, `docker/`,
`test/e2e/`, `.clusterfuzzlite/` and `.trivyignore.yaml`
(`ci_guard_comment_format`; an absent one of those paths is logged
NotRun), no
ShellCheck suppression text in any shell source of the repository
(`ci_guard_shellcheck_directives`, which reads the banned texts from the
SOT's `ci_engine.banned_shell_texts`; `AGENTS.md` `[AG-INT-003]`
forbids silencing a real warning), actionlint, and `shellcheck -x` over
every shell source of those directories (`*.bats` at the
`--severity=warning` floor Issue #479 sets, everything else at every
level).

**PR metadata** (`ci.sh metadata`): the AG-GH-014 title, the AG-GH-002
labels, milestone and project board, and the AG-REL-002 changelog entry
are checked for every pull request author alike, bots included, on
`pull_request` runs only; any other event fails with
`CI-ERROR-META-0002`. Bot pull requests carry the SOT milestone `bot_milestone`:
`sot-update` sets its title and adds its new pull request to the project
board with `PROJECT_AUTOMATION_PAT`, and both `dependabot.yml` entries set
its number, which `ci_guard_sot_mirrors` binds to the SOT.

**Build variants**: `build_matrix.variants` in the SOT defines each
variant completely: OS list, packages, `configure`/`cflags`/`ldflags`,
`ccache`, `check_env`, and the ordered `build_steps`/`test_steps`.
`ci.sh build` and `ci.sh test` hold no variant names; they implement the
named steps and fail closed on an unknown variant, step or flag value.

**Compile cache**: every job that builds a variant with `ccache: "true"`
(today `default`: the `validate.yml` matrix legs, `nightly.yml` and
`release.yml` `build_test`) runs `ci.sh cache <variant>` first, and
`actions/cache` restores and saves
ccache's own `cache_dir` plus `autom4te.cache` under one key:
`build-<os>-<arch>-<autoconf inputs>-<run id>`. Restore takes the newest
entry with the same `configure.ac`/`m4/` content, else the newest for the
platform. A stale entry only makes the build slower: ccache is
content-addressed and autom4te invalidates a stale trace itself.
`config.cache` is never cached. The CodeQL build installs no ccache and
gets no cache, since a ccache hit would skip a compile CodeQL must trace.
No cache step runs in a job reachable from `pull_request_target`
(`plan` excludes that event), so a pull request cannot seed a cache that
base-branch runs restore.

**Artifacts**: the `coverage` leg uploads `coverage.info` and
`coverage-python.xml` (`coverage-reports`, 90 days), ClusterFuzzLite
uploads any crash reproducers even when the fuzz step fails
(`cfl-crashes-<sanitizer>`, 90 days), and Scorecard uploads its SARIF
(`scorecard-results`, 5 days). Names and retention live in
`ci_engine.artifacts`.

**Trivy exceptions**: `ci.sh scan trivy` fails a release image on any
HIGH or CRITICAL finding except those listed in `.trivyignore.yaml`. An
entry is only for a finding with no fix available that is assessed as not
exploitable in that image, and it carries an expiry date so it is
reviewed again:

```yaml
vulnerabilities:
  - id: CVE-YYYY-NNNNN
    paths:
      - usr/local/lib/some/path
    statement: >-
      Why this is accepted, and what would change the assessment.
    expired_at: YYYY-MM-DD
```

**Action pin updates**: `GITHUB_TOKEN` cannot be granted the `workflows`
permission that editing `.github/workflows/` requires, so `sot-update`
cannot move these pins. `.github/dependabot.yml` bumps them weekly
instead. A Dependabot pull request changes only the YAML literal, so the
lint guards fail until its reviewer updates `ci_engine.actions` in the
same pull request (`AGENTS.md` `[AG-VAL-007]` review).

**GHCR image namespace** -- four published package names, no tag overlap:

| Image | Published by | Consumed by |
|---|---|---|
| `distcc-ng`, `distcc-ng-pump` | `release.yml`'s `build_container`/`publish_manifest` | end users only |
| `distcc-ng-nightly` | `nightly.yml`'s `publish` job | end users only |
| `distcc-ng-buildtools` | `validate.yml`'s `publish_buildtools` job | CI itself: every lint run, and the toolchain base of the e2e images |

No workflow here publishes `distcc-ng-e2e`; until this CI reaches `master`,
`master`'s former workflows still push it. It stays in
`release.ghcr_packages` only so `ci.sh gc` can prune its existing versions.

**Job timeouts**: every job the former workflows bounded keeps that bound
as a `timeout-minutes` literal: `plan`/`route` 5, `lint` and the OpenSSF
recheck 15, the PR `build_test` matrix 15 (the backstop `test/testdistcc.py`
relies on for its daemon tests), the nightly/release `build_test` 20, the
2-container `e2e` and nightly `sanitizer` 30, `verify_image` and `control` 45,
`package`/`publish` 60, `heartbeat` 75, `bidirectional_e2e` 340 and CodeQL
360. A `ci.bats` test fails when one of these jobs loses its bound.

**Path-based gating**: `security.yml`'s `clusterfuzzlite` job and
`validate.yml`'s `plan` job both gate on the content-based
`impact_classes` in `build-manifest.yml`; no workflow uses a literal
`paths:` filter. `plan` selects five phases, each gating one job set:
`build` (the build/test matrix), `e2e`, `verify` (the verify image),
`container` (both release images built and Trivy-scanned) and `package`
(the rpm/deb build). A change to the SOT or to `ci.sh` selects all five;
a docs-only PR selects none (`NOOP`). Lint, the `ci.bats` self-test,
metadata and the security scans run on every PR regardless.

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
| 04:00 | daily | `nightly.yml` | `plan`/`build_test` (full matrix)/`sanitizer`/`e2e`/`publish`/`report` |
| 05:00 | Sun | `security.yml` | `route`, `codeql`/`osv-scan`/`scorecard`/`clusterfuzzlite` |
| 05:00 | Mon | `housekeeping.yml` | `route`, `sot_update`/`heartbeat`/`control`/`report` |
| 06:00 | 1st/15th (any weekday) | `security.yml` | `route`, `openssf` |

The crons live in `build-manifest.yml` (`schedules`); each workflow's
`on.schedule` repeats them literally, and `ci_guard_sot_mirrors` fails
lint when the two differ. A `route` job (`ci.sh route <workflow>`) reads
the firing cron from the event and decides which jobs that run starts.
Housekeeping's tasks and their weekly cadence live in `housekeeping_tasks`;
`route` rejects a dispatched task outside that list, and
`ci_guard_sot_mirrors` binds the `task` choice options to it.
The security scans run unless `route` wrote `scans=false`, so a failed
`route` (no output) still runs every required scan instead of skipping it.

**Known collision**: `security.yml`'s two schedules (`0 5 * * 0` and
`0 6 1,15 * *`) both fire whenever the 1st or 15th of a month falls on a
Sunday. Each cron starts its own run, and `ci.sh route security` gives
each run its own job set, so neither is skipped.

## Branch dormancy

`schedule` (and a plain, unscoped `workflow_dispatch`) is only honored
from the copy of a workflow file present on the **default branch**
(`master`) -- this repo develops on `current_dev` and only promotes to
`master` via explicit maintainer-approved release PRs. A `schedule` or
unscoped `workflow_dispatch` change therefore takes effect only once the
changed workflow file has been promoted to `master`. This includes
`ci.sh sot-update`'s own `gh workflow run` of `validate.yml` and
`security.yml` on its update branch: until those files exist on `master`,
that dispatch returns 404 and the `sot_update` job fails. Once it
succeeds, the dispatched runs test the update branch, but checks from a
`workflow_dispatch` run do not satisfy the pull request's required status
checks, so the `sot-update` pull request cannot merge on them alone.
Dependabot likewise reads
`.github/dependabot.yml` only from the default branch, so `master`'s copy
stays the active configuration until the release promotes this one.
