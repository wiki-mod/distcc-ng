#!/usr/bin/env bats
# distcc-ng (https://github.com/wiki-mod/distcc-ng)
# SPDX-License-Identifier: GPL-2.0-or-later
# What: Single authoritative CI regression suite.
# Why: One place proves every CI invariant and regression.
# From: Issue #479

# What: Source ci.sh functions without running dispatch.
# Why: Test engine functions directly against the real SOT.
# From: Issue #479
setup() {
    CI_SH="${BATS_TEST_DIRNAME}/ci.sh"
    # shellcheck source=.github/scripts/ci.sh
    source "${CI_SH}"
}

# What: Point CI_MANIFEST at a fixture of the given lines.
# Why: Tests that copy real SOT values are a second truth.
# From: Issue #479, PR #544
_fixture_manifest() {
    CI_MANIFEST="${BATS_TEST_TMPDIR}/build-manifest.yml"
    printf '%s\n' "$@" > "${CI_MANIFEST}"
}

# What: Fixture SOT with one action; FX_PIN is its pin.
# Why: Guard tests must not copy the real SOT action pins.
# From: Issue #479, PR #544
_fixture_actions() {
    local sha
    sha="$(printf 'a%.0s' {1..40})"
    _fixture_manifest 'ci_engine:' '  actions:' '    a:' "      uses: \"o/a@${sha}\"" '      version: "v1"' \
        '  artifacts:' '    k:' '      name: "kind"' '      retention_days: "7"'
    FX_PIN="o/a@${sha} # v1"
}

# What: Make each named command fail loudly if it is run.
# Why: Proves a fail-closed path stops before any side effect.
# From: Issue #479, PR #544
_forbid() {
    local c
    for c in "$@"; do
        eval "${c}() { echo '${c} must not run'; return 99; }"
    done
}

# What: Stub sleep as a no-op for the calling test.
# Why: Retry backoff and agent polls must not slow the suite.
# From: Issue #479, PR #544
_no_sleep() {
    sleep() { :; }
}

# What: Make a git repo at v9.9.9-NG with that tag; print it.
# Why: Both require_new branches check one tagged release.
# From: Issue #479, PR #544
_fixture_tag_repo() {
    local fx="${BATS_TEST_TMPDIR}/fx"
    mkdir -p "${fx}" || return 1
    ( cd "${fx}" && git init -q && git config user.email t@t && git config user.name t \
      && printf 'AC_INIT([distcc-ng],[9.9.9-NG])\n' > configure.ac \
      && git add configure.ac && git commit -q -m x && git tag v9.9.9-NG ) || return 1
    printf '%s\n' "${fx}"
}

# What: Point the harden agent home at a temp dir with state.
# Why: harden stop reads the state file a start would write.
# From: Issue #479, PR #544
_fixture_harden_state() {
    _CI_HARDEN_DIR="${BATS_TEST_TMPDIR}/agent"
    mkdir -p "${_CI_HARDEN_DIR}" || return 1
    printf 'correlation_id=c\nadd_summary=false\n' > "${BATS_TEST_TMPDIR}/ci-harden.state"
}

@test "unknown subcommand fails closed with a stable id" {
    # What: An unknown command MUST never succeed.
    # Why: Fail-closed dispatch is mandatory.
    # From: Issue #479
    run bash "${BATS_TEST_DIRNAME}/ci.sh" bogus-command
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0002"* ]]
}

@test "a missing manifest fails closed" {
    # What: Every command requires the SOT manifest.
    # Why: No operation may derive state without it.
    # From: Issue #479
    CI_MANIFEST="/nonexistent/build-manifest.yml" run ci_require_manifest
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0003"* ]]
}

@test "sot scalar reads a scalar at any nesting depth" {
    # What: The awk reader follows dotted paths of any depth.
    # Why: Every pin and spec is read through this one reader.
    # From: Issue #479, PR #544
    _fixture_manifest 'a:' '  b: "x"' '  c:' '    d: "y:z@sha256:0"'
    [ "$(_ci_sot_scalar a.b)" = "x" ]
    [ "$(_ci_sot_scalar a.c.d)" = "y:z@sha256:0" ]
}

@test "every SOT image pin is name:tag at a full sha256 digest" {
    # What: Each image pin names its channel tag and a digest.
    # Why: No tag, no refresh; no digest, a floating build.
    # From: Issue #479, PR #544
    local s k v
    for s in base_images external_services; do
        for k in $(_ci_sot_children "${s}"); do
            v="$(_ci_sot_scalar "${s}.${k}")"
            [[ "${v}" =~ ^[^@]+/?[^/@]*:[^/@]+@sha256:[0-9a-f]{64}$ ]] || { echo "${s}.${k}=${v}"; false; }
        done
    done
}

@test "every SOT tool with a url carries a full sha256" {
    # What: A downloaded tool is always checked against a pin.
    # Why: A url without sha256 would run an unverified binary.
    # From: Issue #479, PR #544
    local k
    for k in $(_ci_sot_children external_versions); do
        [ -n "$(_ci_sot_optional "external_versions.${k}.url")" ] || continue
        [[ "$(_ci_sot_scalar "external_versions.${k}.sha256")" =~ ^[0-9a-f]{64}$ ]] || { echo "${k}"; false; }
    done
}

@test "sot set rewrites one path and fails closed on a missing one" {
    # What: The writer changes exactly the addressed scalar.
    # Why: sot-update must never touch a neighbouring pin.
    # From: Issue #479, PR #544
    _fixture_manifest 'a:' '  # note' '  b: "x"' '  c:' '    b: "y"' 'b: "z"'
    run _ci_sot_set a.c.b "new"
    [ "${status}" -eq 0 ]
    [ "$(_ci_sot_scalar a.c.b)" = "new" ]
    [ "$(_ci_sot_scalar a.b)" = "x" ]
    [ "$(_ci_sot_scalar b)" = "z" ]
    grep -qx '  # note' "${CI_MANIFEST}"
    cp "${CI_MANIFEST}" "${BATS_TEST_TMPDIR}/before"
    run _ci_sot_set a.nope "v"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SOT-0002"* ]]
    cmp "${CI_MANIFEST}" "${BATS_TEST_TMPDIR}/before"
}

@test "sot scalar fails closed on a missing key" {
    # What: An absent key MUST NOT read as an empty value.
    # Why: An empty pin once silently skipped a checksum.
    # From: Issue #479, PR #544
    run _ci_sot_scalar external_versions.nope.version
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SOT-0002"* ]]
}

@test "sot optional reads absent keys as empty" {
    # What: Per-entry keys like brew/opt_in may be absent.
    # Why: Optional is explicit, never the default reader.
    # From: Issue #479, PR #544
    run _ci_sot_optional build_matrix.variants.default.opt_in
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "sot children fails closed on a missing section" {
    # What: An absent section MUST NOT read as zero children.
    # Why: It would silently empty the build matrix.
    # From: Issue #479, PR #544
    run _ci_sot_children build_matrix.nope
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SOT-0002"* ]]
}

@test "sot children lists only the direct child keys" {
    # What: Children of a path are its next level, nothing deeper.
    # Why: Drift here silently drops or adds a variant or image.
    # From: Issue #479, PR #544
    _fixture_manifest 'v:' '  one:' '    k: 1' '  two:' '    k: 2' 'other: 1'
    run _ci_sot_children v
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "one" ]
    [ "${lines[1]}" = "two" ]
}

@test "sot walker: one path rule for value, children and set" {
    # What: The one walker serves every mode, or fails closed.
    # Why: Readers and the writer must never disagree on a path.
    # From: Issue #479, PR #544
    _fixture_manifest 'a:' '  b: "x"' '  c:' '    d: 1' 'e: "y"'
    run _ci_sot_lookup bogus a.b
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SOT-0009"* ]]
    run _ci_sot_children a.b
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    run _ci_sot_lookup value a.c.zz
    [ "${status}" -eq 3 ]
    _ci_sot_set a.c.d "2"
    [ "$(_ci_sot_scalar a.c.d)" = "2" ]
    [ "$(_ci_sot_children a)" = "$(printf 'b\nc')" ]
}

@test "job count never drops below the floor of 16" {
    # What: bats parallelism = max(16, nproc*2).
    # Why: Serial runs are forbidden; the floor is a guard.
    # From: Issue #479
    run _ci_jobs
    [ "${status}" -eq 0 ]
    [ "${output}" -ge 16 ]
}

@test "_ci_mapfile keeps the command's exit status" {
    # What: Lines land in the array; a failure is returned.
    # Why: mapfile < <(cmd) hid partial and total failures.
    # From: Issue #479, PR #544
    local arr=(stale)
    # What: Stub: two lines of output, then exit 4.
    # Why: A half-failed command must still return its rc.
    _half() { printf 'a\nb c\n'; return 4; }
    run _ci_mapfile arr _half
    [ "${status}" -eq 4 ]
    _ci_mapfile arr printf 'a\nb c\n'
    [ "${#arr[@]}" -eq 2 ]
    [ "${arr[1]}" = "b c" ]
    _ci_mapfile arr printf ''
    [ "${#arr[@]}" -eq 0 ]
    arr=(stale)
    if _ci_mapfile arr _half; then false; fi
    [ "${#arr[@]}" -eq 0 ]
}

@test "job count fails closed when nproc fails" {
    # What: No CPU count is an error, not a silent guess of 4.
    # Why: AG-VAL-001: a failed tool is never worked around.
    # From: Issue #479, PR #544

    # What: Stub nproc as a failing tool.
    # Why: The job count must fail, never guess a CPU count.
    nproc() { return 1; }
    run _ci_jobs
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0005"* ]]
    run ci_cmd_selftest
    [ "${status}" -eq 2 ]
    # What: Stub nproc printing zero CPUs.
    # Why: A count that is not a positive integer is no count.
    nproc() { echo 0; }
    run _ci_nproc
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0005"* ]]
}

@test "pr-title accepts a valid Conventional-Commit title" {
    # What: A conforming title passes even in block mode.
    # Why: Proves the green path of the AG-GH-014 taxonomy.
    # From: Issue #479
    PR_TITLE="feat(pump): add IPv6 support" PR_TITLE_LINT_MODE=block run _ci_check_pr_title
    [ "${status}" -eq 0 ]
}

@test "pr-title taxonomy is read from AGENTS.md AG-GH-014" {
    # What: The real rule yields its 12 types and 15 scopes.
    # Why: AGENTS.md owns the taxonomy; the checker has no copy.
    # From: Issue #479, PR #544, AG-GH-014
    run _ci_title_taxonomy types
    [ "${status}" -eq 0 ]
    [ "${output}" = "feat fix security docs refactor perf test build ci chore style revert" ]
    run _ci_title_taxonomy scopes
    [ "${status}" -eq 0 ]
    [ "$(wc -w <<< "${output}")" -eq 15 ]
    [[ " ${output} " == *" support-upstream "* ]]
}

@test "pr-title fails closed when AG-GH-014 is missing or unparsable" {
    # What: No rule or no list fails the check, never passes.
    # Why: An empty taxonomy must not accept or reject at random.
    # From: Issue #479, PR #544, AG-GH-014
    local fx="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${fx}"
    printf '**[AG-GH-001]** nothing here\n' > "${fx}/AGENTS.md"
    CI_REPO_ROOT="${fx}" PR_TITLE="feat: x" PR_TITLE_LINT_MODE=warn run _ci_check_pr_title
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-META-TITLE-0004"* ]]
    printf '**[AG-GH-014]** titles; allowed types MUST remain none; done\n' > "${fx}/AGENTS.md"
    CI_REPO_ROOT="${fx}" run _ci_title_taxonomy types
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-META-TITLE-0006"* ]]
    CI_REPO_ROOT="${fx}" run _ci_title_taxonomy scopes
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-META-TITLE-0005"* ]]
}

@test "pr-title fails closed on a bad title in block mode" {
    # What: A non-conforming title fails when enforcement is on.
    # Why: Proves the fail-closed path.
    # From: Issue #479
    PR_TITLE="add some stuff" PR_TITLE_LINT_MODE=block run _ci_check_pr_title
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-META-TITLE-0002"* ]]
}

@test "pr-title holds a dependency bot to AG-GH-014 too" {
    # What: A bot's non-conforming title fails in block mode.
    # Why: AG-GH-014 has no author exemption.
    # From: Issue #479, PR #544
    PR_AUTHOR="dependabot[bot]" PR_TITLE="Bump foo from 1 to 2" PR_TITLE_LINT_MODE=block run _ci_check_pr_title
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-META-TITLE-0002"* ]]
}

@test "board add passes its token to gh but never prints it" {
    # What: The token reaches gh; a dry run prints only the args.
    # Why: One board owner; a PAT must not land in a log line.
    # From: Issue #236, Issue #479, PR #544

    # What: Stub gh to echo the token it was handed.
    # Why: Shows the token reaches gh but not the log.
    gh() { echo "token=${GH_TOKEN:-none} args=$*"; }
    run _ci_board_add https://x/1 s3cret
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"token=s3cret args=project item-add"* ]]
    DRY_RUN=true run _ci_board_add https://x/1 s3cret
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DRY_RUN would run: gh project item-add"* ]]
    [[ "${output}" != *"s3cret"* ]]
    run _ci_board_add https://x/1 ""
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"not added to the board"* ]]
}

@test "release assets come from the SOT globs and none fails" {
    # What: Matching files are listed; an empty set is an error.
    # Why: A release or nightly without packages must not ship.
    # From: Issue #362, Issue #479, PR #544
    local fx="${BATS_TEST_TMPDIR}/fx"
    mkdir -p "${fx}/packaging"
    _fixture_manifest 'release:' '  assets: ["distcc-*.tar.gz", "packaging/*.deb"]'
    CI_REPO_ROOT="${fx}" run _ci_release_assets
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-PUBLISH-0007"* ]]
    touch "${fx}/distcc-1.tar.gz" "${fx}/packaging/a.deb" "${fx}/other.txt"
    CI_REPO_ROOT="${fx}" run _ci_release_assets
    [ "${status}" -eq 0 ]
    [ "${output}" = $'distcc-1.tar.gz\npackaging/a.deb' ]
}

@test "a bot PR needs tracking metadata and a changelog too" {
    # What: Bot PRs fail tracking and changelog like any PR.
    # Why: AG-GH-002 and AG-REL-002 name no author exemption.
    # From: Issue #479, PR #544
    local a
    for a in "github-actions[bot]" "dependabot[bot]"; do
        PR_AUTHOR="${a}" PR_LABELS="" PR_MILESTONE_TITLE="" run _ci_check_pr_tracking
        [ "${status}" -eq 1 ]
        [[ "${output}" == *"CI-ERROR-META-TRACKING-0001"* ]]
        # What: Stub the diff owner as a change without CHANGELOG.
        # Why: The changelog check must fail for the bot as well.
        _ci_changed_paths() { printf '%s\n' .github/yaml/build-manifest.yml; }
        PR_AUTHOR="${a}" PR_LABELS="dependencies" BASE=b HEAD=h run _ci_check_changelog
        [ "${status}" -eq 1 ]
        [[ "${output}" == *"CI-ERROR-META-CHANGELOG-0001"* ]]
    done
}

@test "tracking passes with labels and a milestone" {
    # What: A PR with a label and a milestone passes AG-GH-002.
    # Why: Proves the green tracking path.
    # From: Issue #479
    PR_LABELS="ci" PR_MILESTONE_TITLE="current_dev backlog" run _ci_check_pr_tracking
    [ "${status}" -eq 0 ]
}

@test "tracking fails closed without a milestone" {
    # What: A missing milestone fails AG-GH-002.
    # Why: Proves the fail-closed tracking path.
    # From: Issue #479
    PR_LABELS="ci" PR_MILESTONE_TITLE="" run _ci_check_pr_tracking
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-META-TRACKING-0001"* ]]
}

@test "tracking is non-blocking on a draft PR" {
    # What: A draft PR with missing metadata still passes.
    # Why: AG-WF-009; ready_for_review re-checks it for real.
    # From: Issue #479, PR #544
    PR_LABELS="" PR_MILESTONE_TITLE="" PR_DRAFT="true" run _ci_check_pr_tracking
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"draft, non-blocking"* ]]
}

@test "board check skips when PROJECT_AUTOMATION_PAT is unset" {
    # What: No PAT degrades to a skip, not a failure.
    # Why: AG-GH-002's own documented exception.
    # From: Issue #479, PR #544
    unset PROJECT_PAT
    run _ci_check_pr_board
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"CI-META-BOARD"* ]]
}

@test "board check skips for a fork PR even with a PAT configured" {
    # What: A fork PR skips the board lookup entirely.
    # Why: GitHub withholds the PAT from fork PR runs anyway.
    # From: Issue #479, PR #544
    PROJECT_PAT="dummy" PR_IS_FORK="true" run _ci_check_pr_board
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"fork PR"* ]]
}

@test "release version-check fails on a tag that mismatches configure.ac" {
    # What: A tag whose version != configure.ac is rejected.
    # Why: Fail-closed release guardrail (no accidental retag).
    # From: Issue #479
    run bash "${BATS_TEST_DIRNAME}/ci.sh" release version-check v99.99.99-NG
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-RELEASE-0003"* ]]
}

@test "release version-check require_new=false accepts an already-pushed tag" {
    # What: The post-push check accepts its own existing tag.
    # Why: POL-RELEASE-07 runs after the tag was pushed.
    # From: Issue #479, PR #544
    fx="$(_fixture_tag_repo)"
    CI_REPO_ROOT="${fx}" run _ci_check_release_version v9.9.9-NG false
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"CI-RELEASE"*"OK"* ]]
}

@test "release version-check require_new=true still rejects an existing tag" {
    # What: The pre-tag dispatch path keeps refusing a collision.
    # Why: require_new defaults to true for the pre-tag path.
    # From: Issue #479, PR #544
    fx="$(_fixture_tag_repo)"
    CI_REPO_ROOT="${fx}" run _ci_check_release_version v9.9.9-NG
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-RELEASE-0004"* ]]
}

@test "release context: a tag push publishes and moves latest" {
    # What: A v* tag push is the tag, publishes, sets tag_push.
    # Why: POL-RELEASE-07; release jobs read only these outputs.
    # From: Issue #479, PR #544
    GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/v1.2.3-NG GITHUB_REF_NAME=v1.2.3-NG run _ci_release_context
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' v1.2.3-NG false true true)" ]
}

@test "release context: a dispatch reads tag and opt-in from inputs" {
    # What: Dispatch tag and publish_container come from inputs.
    # Why: POL-RELEASE-05: a dry run never moves latest.
    # From: Issue #479, PR #544
    local ev="${BATS_TEST_TMPDIR}/ev.json"
    printf '{"inputs":{"tag":"v1.2.3-NG","publish_container":"true"}}' > "${ev}"
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_EVENT_PATH="${ev}" run _ci_release_context
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' v1.2.3-NG true true false)" ]
    printf '{"inputs":{"tag":"v1.2.3-NG"}}' > "${ev}"
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_EVENT_PATH="${ev}" run _ci_release_context
    [ "${lines[2]}" = "false" ]
    printf '{"inputs":{}}' > "${ev}"
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_EVENT_PATH="${ev}" run _ci_release_context
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-EVENT-0001"*".inputs.tag"* ]]
}

@test "release context fails closed off a release trigger" {
    # What: A branch push or another event has no release tag.
    # Why: Guessing a tag there would publish the wrong ref.
    # From: Issue #479, PR #544
    GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/current_dev GITHUB_REF_NAME=current_dev run _ci_release_context
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-RELEASE-0007"* ]]
    GITHUB_EVENT_NAME=schedule run _ci_release_context
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-RELEASE-0008"* ]]
}

@test "release version-check in CI writes tag, publish, tag_push" {
    # What: The event path checks the tag, then writes outputs.
    # Why: Downstream jobs gate on these, not on the event.
    # From: Issue #479, PR #544
    local out="${BATS_TEST_TMPDIR}/out"
    # What: Stub: accept only v1.2.3-NG, require_new=false.
    # Why: Pins the arguments the CI path must pass.
    _ci_check_release_version() { [ "$1 $2" = "v1.2.3-NG false" ]; }
    # What: Stub an empty container matrix and one variant.
    # Why: Keeps the test off the real SOT inventory.
    _ci_release_matrix() { printf '%s\n' '{"include":[]}' '["a"]'; }
    GITHUB_OUTPUT="${out}" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/v1.2.3-NG GITHUB_REF_NAME=v1.2.3-NG \
        run _ci_release_version_check
    [ "${status}" -eq 0 ]
    [ "$(cat "${out}")" = "$(printf '%s\n' tag=v1.2.3-NG publish=true tag_push=true \
        'container_matrix={"include":[]}' 'variants=["a"]')" ]
}

@test "release matrix is every SOT variant on every SOT platform" {
    # What: Rows carry runner and optional; variants list follows.
    # Why: The workflows hold no variant or platform list.
    # From: Issue #479, PR #544
    _fixture_manifest 'release:' '  container:' '    variants:' '      plain: "p"' '      pump: "q"' \
        '    platforms:' '      amd64:' '        runner: "r1"' '        optional: "false"' \
        '      arm64:' '        runner: "r2"' '        optional: "true"'
    run _ci_release_matrix
    [ "${status}" -eq 0 ]
    [ "${lines[0]}" = '{"include":[{"variant":"plain","platform":"amd64","runs_on":"r1","optional":false},{"variant":"plain","platform":"arm64","runs_on":"r2","optional":true},{"variant":"pump","platform":"amd64","runs_on":"r1","optional":false},{"variant":"pump","platform":"arm64","runs_on":"r2","optional":true}]}' ]
    [ "${lines[1]}" = '["plain","pump"]' ]
    _fixture_manifest 'release:' '  container:' '    variants:' '      plain: "p"' \
        '    platforms:' '      amd64:' '        runner: "r1"' '        optional: "maybe"'
    run _ci_release_matrix
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CONTAINER-0005"* ]]
}

@test "publish manifest takes every platform; only optional may lack" {
    # What: A missing optional platform skips; a required fails.
    # Why: arm64 may fail its build; amd64 never ships without.
    # From: Issue #479, PR #544
    _fixture_manifest 'release:' '  container:' '    variants:' '      plain: "p"' \
        '    platforms:' '      amd64:' '        runner: "r1"' '        optional: "false"' \
        '      arm64:' '        runner: "r2"' '        optional: "true"'
    # What: Stub the registry login as a no-op.
    # Why: The manifest test needs no registry or token.
    _ci_registry_login() { :; }
    # What: Stub inspect per platform tag; echo create.
    # Why: arm64 is missing; AMD_GONE drops amd64 too.
    docker() {
        case "$*" in
            *"inspect "*"-arm64"*) echo "not found"; return 1 ;;
            *"inspect "*"-amd64"*) [ -z "${AMD_GONE:-}" ] || { echo "not found"; return 1; } ;;
            *create*) echo "create $*" ;;
        esac
    }
    GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/out" GITHUB_REPOSITORY_OWNER=o GITHUB_EVENT_NAME=push \
        GITHUB_REF=refs/tags/v1 GITHUB_REF_NAME=v1 run _ci_publish_manifest plain
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"no arm64 image"* ]]
    [[ "${output}" == *"create buildx imagetools create --tag ghcr.io/o/p:v1 ghcr.io/o/p:v1-amd64"* ]]
    AMD_GONE=1 GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/out" GITHUB_REPOSITORY_OWNER=o GITHUB_EVENT_NAME=push \
        GITHUB_REF=refs/tags/v1 GITHUB_REF_NAME=v1 run _ci_publish_manifest plain
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-PUBLISH-0006"*"v1-amd64"* ]]
}

@test "release packages are offered as one artifact per tag" {
    # What: The SOT release assets become the artifact's files.
    # Why: The checklist verifies a CI-built package pre-tag.
    # From: Issue #479, PR #544
    local out="${BATS_TEST_TMPDIR}/out" fx="${BATS_TEST_TMPDIR}/fx"
    mkdir -p "${fx}/packaging"
    : > "${fx}/distcc-1.tar.gz"; : > "${fx}/packaging/d.deb"
    _fixture_manifest 'release:' '  assets: ["distcc-*.tar.gz", "packaging/*.deb"]' 'ci_engine:' '  artifacts:' \
        '    release_packages:' '      name: "pkgs"' '      retention_days: "90"'
    CI_REPO_ROOT="${fx}" GITHUB_OUTPUT="${out}" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/v1-NG \
        GITHUB_REF_NAME=v1-NG run _ci_release_offer_packages
    [ "${status}" -eq 0 ]
    grep -qx 'artifact_name=pkgs-v1-NG' "${out}"
    grep -qx "${fx}/distcc-1.tar.gz" "${out}"
    grep -qx "${fx}/packaging/d.deb" "${out}"
}

@test "release image names map variants to their GHCR packages" {
    # What: A SOT variant maps to its package; names get the tag.
    # Why: One owner; the workflows no longer build these names.
    # From: Issue #359, Issue #479, PR #544
    _fixture_manifest 'release:' '  container:' '    variants:' '      pump: "distcc-ng-pump"'
    run _ci_release_pkg pump
    [ "${output}" = "distcc-ng-pump" ]
    run _ci_release_pkg x
    [ "${status}" -eq 2 ]
    GITHUB_REPOSITORY_OWNER=o run _ci_release_image distcc-ng-pump v1 arm64
    [ "${output}" = "ghcr.io/o/distcc-ng-pump:v1-arm64" ]
    GITHUB_REPOSITORY_OWNER=o run _ci_release_image distcc-ng-nightly latest
    [ "${output}" = "ghcr.io/o/distcc-ng-nightly:latest" ]
}

@test "changelog skips a pre-release and a dispatch without notes" {
    # What: Neither event inserts a section or touches git.
    # Why: Only a published release or explicit notes add one.
    # From: Issue #479, PR #544
    local ev="${BATS_TEST_TMPDIR}/ev.json"
    _forbid _ci_changelog_insert
    printf '{"release":{"prerelease":true,"tag_name":"v1","body":"x"}}' > "${ev}"
    GITHUB_EVENT_NAME=release GITHUB_EVENT_PATH="${ev}" run _ci_publish_changelog_update
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"skipped: pre-release"* ]]
    printf '{"inputs":{"tag":"v1","release_notes":""}}' > "${ev}"
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_EVENT_PATH="${ev}" run _ci_publish_changelog_update
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"skipped: no release_notes"* ]]
}

@test "changelog plan says insert only when the event has notes" {
    # What: Pre-release and note-less dispatch plan insert=false.
    # Why: The write token step must not run without a section.
    # From: Issue #479, PR #544
    local ev="${BATS_TEST_TMPDIR}/ev.json" out="${BATS_TEST_TMPDIR}/out"
    printf '{"release":{"prerelease":false,"tag_name":"v1","body":"n"}}' > "${ev}"
    GITHUB_OUTPUT="${out}" GITHUB_EVENT_NAME=release GITHUB_EVENT_PATH="${ev}" run _ci_changelog_plan
    [ "$(cat "${out}")" = "insert=true" ]
    : > "${out}"
    printf '{"inputs":{"tag":"v1","release_notes":""}}' > "${ev}"
    GITHUB_OUTPUT="${out}" GITHUB_EVENT_NAME=workflow_dispatch GITHUB_EVENT_PATH="${ev}" run _ci_changelog_plan
    [ "$(cat "${out}")" = "insert=false" ]
    GITHUB_OUTPUT="${out}" GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="${ev}" run _ci_changelog_plan
    [ "${status}" -eq 2 ]
}

@test "changelog takes a published release's tag and body" {
    # What: The release payload's tag_name and body are inserted.
    # Why: The workflow passes neither; ci.sh reads the event.
    # From: Issue #479, PR #544
    local ev="${BATS_TEST_TMPDIR}/ev.json"
    # What: Stub the insert to print its tag and notes file.
    # Why: The test checks the event parse, not git.
    _ci_changelog_insert() { printf 'insert %s|%s\n' "$1" "$2"; }
    printf '{"release":{"prerelease":false,"tag_name":"v1.2","body":"notes"}}' > "${ev}"
    GITHUB_EVENT_NAME=release GITHUB_EVENT_PATH="${ev}" run _ci_publish_changelog_update
    [ "${status}" -eq 0 ]
    [ "${output}" = "insert v1.2|notes" ]
    printf '{"inputs":{"tag":"v2-NG","release_notes":"rn"}}' > "${ev}"
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_EVENT_PATH="${ev}" run _ci_publish_changelog_update
    [ "${status}" -eq 0 ]
    [ "${output}" = "insert v2-NG|rn" ]
}

@test "changelog manual retry inserts a notes file, dry run pushes nothing" {
    # What: A notes file is inserted and committed; push dry-runs.
    # Why: The release checklist's recovery path runs it locally.
    # From: Issue #479, PR #544
    local fx="${BATS_TEST_TMPDIR}/fx"
    mkdir -p "${fx}"
    ( cd "${fx}" && git init -q && printf '# Changelog\n<!-- insertion marker -->\n' > CHANGELOG.md \
      && git add CHANGELOG.md && git -c user.name=t -c user.email=t@t commit -q -m x )
    printf 'line one\n' > "${BATS_TEST_TMPDIR}/notes"
    # What: Stub git auth setup as a no-op.
    # Why: A dry run must not need a token or a remote.
    _ci_git_auth_setup() { :; }
    CI_REPO_ROOT="${fx}" DRY_RUN=true run _ci_publish_changelog_update v1.2.3-NG "${BATS_TEST_TMPDIR}/notes"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DRY_RUN would run: git push origin HEAD:current_dev"* ]]
    grep -qx '## \[1.2.3-NG\] - .*' "${fx}/CHANGELOG.md"
    grep -qx 'line one' "${fx}/CHANGELOG.md"
    [ "$(git -C "${fx}" log -1 --format=%s)" = "CHANGELOG.md: add v1.2.3-NG" ]
}

@test "container rejects an unimplemented variant" {
    # What: An unknown container variant fails closed.
    # Why: Consistent fail-closed dispatch for outward phases.
    # From: Issue #479
    run bash "${BATS_TEST_DIRNAME}/ci.sh" container bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CONTAINER-0001"* ]]
}

@test "registry login fails closed without REGISTRY_TOKEN" {
    # What: No token MUST NOT fall through to an anonymous push.
    # Why: A missing secret is a hard failure (AG-VAL-001).
    # From: Issue #479, PR #544
    _forbid docker
    unset REGISTRY_TOKEN
    GITHUB_ACTOR=octo run _ci_registry_login
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"REGISTRY_TOKEN required"* ]]
    [[ "${output}" != *"docker must not run"* ]]
}

@test "registry login pipes the token on stdin as GITHUB_ACTOR" {
    # What: Token goes via stdin, never argv; user is the actor.
    # Why: argv leaks into process listings and logs.
    # From: Issue #479, PR #544

    # What: Stub docker to record its stdin and argv.
    # Why: Proves the token goes on stdin, not in argv.
    docker() { cat > "${BATS_TEST_TMPDIR}/stdin"; echo "$*" > "${BATS_TEST_TMPDIR}/argv"; }
    REGISTRY_TOKEN=s3cret GITHUB_ACTOR=octo run _ci_registry_login
    [ "${status}" -eq 0 ]
    [ "$(cat "${BATS_TEST_TMPDIR}/stdin")" = "s3cret" ]
    [ "$(cat "${BATS_TEST_TMPDIR}/argv")" = "login ghcr.io -u octo --password-stdin" ]
}

@test "e2e compile-ok counter counts only clients inside the CIDR" {
    # What: One counter serves subnet and single-client legs.
    # Why: Only real remote COMPILE_OK from the client may count.
    # From: Issue #479, Issue #264, PR #544
    local log="${BATS_TEST_TMPDIR}/server.log"
    {
        printf 'distccd[1] (dcc_job_summary) client: 172.18.0.10:48058 COMPILE_OK exit:0\n'
        printf 'distccd[2] (dcc_job_summary) client: 172.18.0.20:48059 COMPILE_OK exit:0\n'
        printf 'distccd[3] (dcc_job_summary) client: 172.18.0.10:48060 COMPILE_OK exit:0\n'
        printf 'distccd[4] (dcc_job_summary) client: 172.19.0.10:48061 COMPILE_OK exit:0\n'
        printf 'distccd[5] (dcc_job_summary) client: 172.18.0.10:48062 COMPILE_FAILED exit:1\n'
    } > "${log}"
    [ "$(_ci_e2e_count_compile_ok "${log}" 172.18.0.10/32)" = "2" ]
    [ "$(_ci_e2e_count_compile_ok "${log}" 172.18.0.20/32)" = "1" ]
    [ "$(_ci_e2e_count_compile_ok "${log}" 172.18.0.0/16)" = "3" ]
}

@test "e2e server warning scan passes a clean verbose log" {
    # What: Verbose info/debug lines carry no severity prefix.
    # Why: Green path: a normal distccd session must pass.
    # From: Issue #479, PR #544
    local log="${BATS_TEST_TMPDIR}/server.log"
    printf 'distccd[7] listening on 0.0.0.0:3632\ndistccd[9] (dcc_job_summary) client: 172.18.0.3:4 COMPILE_OK\n' > "${log}"
    run _ci_e2e_check_server_warnings "${log}"
    [ "${status}" -eq 0 ]
}

@test "e2e server warning scan fails on a warning-level line" {
    # What: Any rs_severities prefix above notice fails the leg.
    # Why: A daemon warning never reaches the client's exit code.
    # From: Issue #479, PR #544
    local log="${BATS_TEST_TMPDIR}/server.log"
    printf 'distccd[8] (dcc_check_client) ERROR: connection from client denied\n' > "${log}"
    run _ci_e2e_check_server_warnings "${log}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-E2E-0015"* ]]
}

@test "e2e compile-ok counter fails closed on an unreadable log" {
    # What: A missing server log is an error, not zero compiles.
    # Why: grep -c || true used to mask exactly this case.
    # From: Issue #479, PR #544
    run _ci_e2e_count_compile_ok "${BATS_TEST_TMPDIR}/nope.log" 172.18.0.0/16
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-E2E-0002"* ]]
}

@test "e2e and workload reject unknown modes before touching docker" {
    # What: No default mode runs when the caller typoed one.
    # Why: The old catch-all silently ran the distributed harness.
    # From: Issue #479, PR #544
    _forbid docker
    run ci_cmd_e2e bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-E2E-0013"* ]]
    run ci_cmd_workload bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-WORKLOAD-0006"* ]]
    run ci_cmd_workload ccache sideways
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-WORKLOAD-0004"* ]]
    run ci_cmd_workload samba sideways /tmp/x
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-WORKLOAD-0008"* ]]
    run ci_cmd_image bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-IMAGE-0001"* ]]
    [[ "${output}" != *"must not run"* ]]
}

@test "publish nightly refuses to force-move a v* tag" {
    # What: The nightly publisher never moves a release tag.
    # Why: git push -f on a v* tag would clobber a real release.
    # From: Issue #479
    _fixture_manifest 'release:' '  nightly_tag: "v3.6.6-NG"'
    run _ci_publish_nightly
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-PUBLISH-0002"* ]]
}

@test "release rejects an unknown subcommand" {
    # What: An unknown release subcommand fails closed.
    # Why: Consistent fail-closed dispatch.
    # From: Issue #479
    run bash "${BATS_TEST_DIRNAME}/ci.sh" release bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-RELEASE-0005"* ]]
}

@test "changelog is skipped by the no-changelog-needed label" {
    # What: The opt-out label satisfies the changelog gate.
    # Why: Proves the documented opt-out path.
    # From: Issue #479
    PR_LABELS="ci no-changelog-needed" run _ci_check_changelog
    [ "${status}" -eq 0 ]
}

@test "event range: a PR diffs base..head, a push before..sha" {
    # What: Each event type yields its own base and head commit.
    # Why: The plan diff must never mix PR and push fields.
    # From: Issue #479, PR #544
    local ev="${BATS_TEST_TMPDIR}/ev.json"
    printf '{"pull_request":{"base":{"sha":"b1"},"head":{"sha":"h1"}},"before":"x"}' > "${ev}"
    GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="${ev}" GITHUB_SHA=m run _ci_event_range
    [ "${output}" = "$(printf '%s\n' b1 h1)" ]
    printf '{"before":"p0"}' > "${ev}"
    GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="${ev}" GITHUB_SHA=s1 run _ci_event_range
    [ "${output}" = "$(printf '%s\n' p0 s1)" ]
    printf '{"inputs":{}}' > "${ev}"
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_EVENT_PATH="${ev}" GITHUB_SHA=s1 run _ci_event_range
    [ "${lines[0]}" = "s1" ]
    [ "${#lines[@]}" -eq 1 ]
}

@test "event PR number and board url come from the payload" {
    # What: PR number and issue/PR url are read from the event.
    # Why: The workflows forward neither; a missing one fails.
    # From: Issue #479, PR #544
    local ev="${BATS_TEST_TMPDIR}/ev.json"
    printf '{"pull_request":{"number":7,"html_url":"https://h/pr/7"}}' > "${ev}"
    GITHUB_EVENT_PATH="${ev}" run _ci_event_value .pull_request.number
    [ "${output}" = "7" ]
    # What: Stub the board add to print the URL it gets.
    # Why: The test checks the URL from the payload.
    _ci_board_add() { printf 'add %s\n' "$1"; }
    GITHUB_EVENT_PATH="${ev}" run _ci_variables_add_to_project
    [ "${output}" = "add https://h/pr/7" ]
    printf '{"issue":{"html_url":"https://h/i/3"}}' > "${ev}"
    GITHUB_EVENT_PATH="${ev}" run _ci_variables_add_to_project
    [ "${output}" = "add https://h/i/3" ]
    printf '{}' > "${ev}"
    GITHUB_EVENT_PATH="${ev}" run _ci_event_value .pull_request.number
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-EVENT-0001"* ]]
    GITHUB_EVENT_PATH="${ev}" run _ci_variables_add_to_project
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-EVENT-0001"* ]]
}

@test "impact-hit runs every class off a PR, diffs on a PR" {
    # What: Non-PR events hit; a PR hits only on a matching path.
    # Why: Only a reviewed PR diff may skip a class.
    # From: Issue #479, PR #544
    local out="${BATS_TEST_TMPDIR}/out"
    GITHUB_OUTPUT="${out}" GITHUB_EVENT_NAME=push run ci_cmd_impact_hit fuzz
    [ "$(cat "${out}")" = "hit=true" ]
    # What: Stub the PR range as base b, head h.
    # Why: The test needs a range without a real event.
    _ci_event_range() { printf '%s\n' b h; }
    # What: Stub the diff owner as a docs-only change.
    # Why: A docs diff must miss the fuzz class.
    _ci_changed_paths() { printf '%s\n' doc/x.md; }
    : > "${out}"
    GITHUB_OUTPUT="${out}" GITHUB_EVENT_NAME=pull_request run ci_cmd_impact_hit fuzz
    [ "$(cat "${out}")" = "hit=false" ]
    # What: Stub the diff owner as a fuzz test change.
    # Why: A test/fuzz diff must hit the fuzz class.
    _ci_changed_paths() { printf '%s\n' test/fuzz/a.c; }
    : > "${out}"
    GITHUB_OUTPUT="${out}" GITHUB_EVENT_NAME=pull_request run ci_cmd_impact_hit fuzz
    [ "$(cat "${out}")" = "hit=true" ]
}

@test "impact-hit fails closed when the PR diff fails" {
    # What: A failing git diff is an error, never a miss.
    # Why: A false miss would skip fuzzing on a broken diff.
    # From: Issue #479, PR #544

    # What: Stub the PR range as base b, head h.
    # Why: The diff below must fail, not the range read.
    _ci_event_range() { printf '%s\n' b h; }
    # What: Stub git as a failing diff (rc 128).
    # Why: A failed diff must fail closed, not miss.
    git() { return 128; }
    GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/out" GITHUB_EVENT_NAME=pull_request run ci_cmd_impact_hit fuzz
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-DIFF-0001"* ]]
}

@test "report outcome is success only if every job succeeded" {
    # What: A failure, cancel or skip makes the outcome failure.
    # Why: A skipped publish means the nightly did not ship.
    # From: Issue #479, PR #544
    run _ci_jobs_outcome "$(printf '%s\n' a=success b=success)"
    [ "${output}" = "success" ]
    run _ci_jobs_outcome "$(printf '%s\n' a=success b=skipped)"
    [ "${output}" = "failure" ]
    run _ci_jobs_outcome ""
    [ "${status}" -eq 2 ]
    GITHUB_SERVER_URL=https://s GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=9 run _ci_run_url
    [ "${output}" = "https://s/o/r/actions/runs/9" ]
}

@test "plan on a dispatch selects every phase" {
    # What: No before commit means no diff, so all five phases.
    # Why: NOOP there would skip every check a dispatch asked for.
    # From: Issue #479, PR #544
    local ev="${BATS_TEST_TMPDIR}/ev.json" out="${BATS_TEST_TMPDIR}/out"
    printf '{"inputs":{}}' > "${ev}"
    # What: Stub the build matrix as empty.
    # Why: The test checks phases, not the matrix SOT.
    ci_cmd_matrix() { echo '{"include":[]}'; }
    GITHUB_OUTPUT="${out}" GITHUB_EVENT_NAME=workflow_dispatch GITHUB_EVENT_PATH="${ev}" GITHUB_SHA=HEAD \
        GITHUB_REF_NAME=current_dev run ci_cmd_plan
    [ "${status}" -eq 0 ]
    grep -qx "phases=$(_ci_all_phases | paste -sd ' ')" "${out}"
    grep -qx 'build=true' "${out}"
    grep -qx 'publish_buildtools=true' "${out}"
}

@test "plan classifies the push diff through ci.sh impact" {
    # What: A push's before..sha diff yields impact's phases.
    # Why: impact is the one diff-to-phases owner for plan.
    # From: Issue #479, PR #544
    local fx="${BATS_TEST_TMPDIR}/repo" ev="${BATS_TEST_TMPDIR}/ev.json" out="${BATS_TEST_TMPDIR}/out" b h
    _fixture_manifest 'impact_classes:' '  pk:' '    paths: ["packaging/**"]' '    phases: ["package"]' \
        '  docs:' '    paths: ["**/*.md"]' '    phases: []' 'release:' '  container:' '    variants:' \
        '      plain: "p"' '    platforms:' '      amd64:' '        runner: "r1"' '        optional: "false"'
    ( cd "${BATS_TEST_TMPDIR}" && git init -q repo && cd repo && git config user.email t@t \
        && git config user.name t && echo a > README.md && git add . && git commit -qm a \
        && mkdir packaging && echo b > packaging/x && git add . && git commit -qm b )
    b="$(git -C "${fx}" rev-parse HEAD~1)" h="$(git -C "${fx}" rev-parse HEAD)"
    CI_REPO_ROOT="${fx}" run ci_cmd_impact "${b}" "${h}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "package" ]
    printf '{"before":"%s","after":"%s"}' "${b}" "${h}" > "${ev}"
    # What: Stub the build matrix as empty.
    # Why: The test checks phases, not the matrix SOT.
    ci_cmd_matrix() { echo '{"include":[]}'; }
    CI_REPO_ROOT="${fx}" GITHUB_OUTPUT="${out}" GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="${ev}" \
        GITHUB_SHA="${h}" GITHUB_REF_NAME=current_dev run ci_cmd_plan
    [ "${status}" -eq 0 ]
    grep -qx 'phases=package' "${out}"
    grep -qx 'publish_buildtools=false' "${out}"
}

@test "plan publishes buildtools only from a protected ref" {
    # What: A bot-branch dispatch plans verify but no publish.
    # Why: Only current_dev and master may push buildtools:latest.
    # From: Issue #479, PR #544
    local ev="${BATS_TEST_TMPDIR}/ev.json" out="${BATS_TEST_TMPDIR}/out" ref
    printf '{"inputs":{}}' > "${ev}"
    # What: Stub the build matrix as empty.
    # Why: The test checks the publish flag, not the matrix.
    ci_cmd_matrix() { echo '{"include":[]}'; }
    for ref in bot/x 544/merge; do
        : > "${out}"
        GITHUB_OUTPUT="${out}" GITHUB_EVENT_NAME=workflow_dispatch GITHUB_EVENT_PATH="${ev}" \
            GITHUB_SHA=HEAD GITHUB_REF_NAME="${ref}" run ci_cmd_plan
        [ "${status}" -eq 0 ]
        grep -qx "phases=$(_ci_all_phases | paste -sd ' ')" "${out}"
        grep -qx 'publish_buildtools=false' "${out}"
    done
    unset GITHUB_REF_NAME
    GITHUB_OUTPUT="${out}" GITHUB_EVENT_NAME=workflow_dispatch GITHUB_EVENT_PATH="${ev}" \
        GITHUB_SHA=HEAD run ci_cmd_plan
    [ "${status}" -ne 0 ]
}

@test "matrix expands variant x os and excludes opt-in variants" {
    # What: The PR matrix is the SOT variants minus opt-in ones.
    # Why: An opt-in variant is never a PR gate.
    # From: Issue #479, PR #544
    _fixture_manifest 'build_matrix:' '  variants:' '    a:' '      apt: "p"' '      brew: "q"' \
        '      os: [ubuntu-latest, macos-latest]' '    b:' '      apt: "r"' '      opt_in: true' \
        '      os: [ubuntu-latest]'
    run ci_cmd_matrix
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"include":[{"variant":"a","os":"ubuntu-latest","apt":"p"},{"variant":"a","os":"macos-latest","brew":"q"}]}' ]
}

@test "both matrices stay valid JSON for any SOT value" {
    # What: A backslash in a SOT value is escaped, not raw.
    # Why: Hand-built JSON once let a value break the matrix.
    # From: Issue #479, PR #544
    _fixture_manifest 'build_matrix:' '  variants:' '    a:' '      apt: "p\q"' '      os: [ubuntu-latest]' \
        'release:' '  container:' '    variants:' '      plain: "p"' '    platforms:' '      amd64:' \
        '        runner: "r\1"' '        optional: "false"'
    run ci_cmd_matrix
    [ "${status}" -eq 0 ]
    [ "$(jq -r '.include[0].apt' <<< "${output}")" = 'p\q' ]
    run _ci_release_matrix
    [ "${status}" -eq 0 ]
    [ "$(jq -r '.include[0].runs_on' <<< "${lines[0]}")" = 'r\1' ]
    [ "$(jq -c . <<< "${lines[1]}")" = '["plain"]' ]
}

@test "build fails closed on an unknown variant before touching the tree" {
    # What: An unknown build variant MUST reject, not autogen.
    # Why: Fail-closed before running any build step.
    # From: Issue #479
    CI_REPO_ROOT=/tmp run bash "${BATS_TEST_DIRNAME}/ci.sh" build bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

@test "apt retry first finishes a dpkg run the timeout cut off" {
    # What: After a failed attempt, dpkg --configure -a runs.
    # Why: A killed install leaves dpkg interrupted for the retry.
    # From: Issue #493, Issue #479, PR #544
    local log="${BATS_TEST_TMPDIR}/calls"
    # What: Stub sudo to run its command directly.
    # Why: The test runs as a plain user without sudo.
    sudo() { "$@"; }
    _no_sleep
    # What: Stub timeout: log calls, fail the first apt run.
    # Why: Replays an apt run the timeout cut off mid-dpkg.
    timeout() {
        shift 3
        echo "$*" >> "${log}"
        case "$*" in
            *"dpkg --configure -a"*) [ -z "${DPKG_FAIL:-}" ] ;;
            *) [ "$(grep -c 'apt-get' "${log}")" -ge 2 ] ;;
        esac
    }
    run _ci_apt_install "p q"
    [ "${status}" -eq 0 ]
    [[ "$(sed -n 2p "${log}")" == *"dpkg --configure -a"* ]]
    [ "$(grep -c 'apt-get' "${log}")" -eq 2 ]
    : > "${log}"
    DPKG_FAIL=1 run _ci_apt_install "p q"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-INSTALL-0004"* ]]
}

@test "make gate passes a clean build and fails on a warning" {
    # What: A compiler warning in make output fails the build.
    # Why: Warnings are errors (AG-INT-003) on every tree build.
    # From: Issue #479, PR #544

    # What: Stub make as a clean compile line.
    # Why: A clean build must pass the warning gate.
    make() { echo "gcc -c src/x.c"; }
    run _ci_make_gated "${BATS_TEST_TMPDIR}/ok.log" all
    [ "${status}" -eq 0 ]
    # What: Stub make as a compile with one warning.
    # Why: Any compiler warning must fail the gate.
    make() { echo "src/x.c:12:5: warning: unused variable 'y'"; }
    run _ci_make_gated "${BATS_TEST_TMPDIR}/warn.log" all
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-BUILD-WARN-0001"* ]]
    [[ "${output}" == *"src/x.c:12:5: warning"* ]]
    run _ci_warning_gate "${BATS_TEST_TMPDIR}/missing.log" "make check"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-BUILD-WARN-0002"* ]]
}

@test "make gate and configure fail closed when the tool fails" {
    # What: A failing make or configure is an error, not a pass.
    # Why: Build steps once relied on set -e, lost inside ||.
    # From: Issue #479, PR #544

    # What: Stub make as a failing tool (rc 2).
    # Why: A failed make must fail, not read as clean.
    make() { echo "boom"; return 2; }
    run _ci_make_gated "${BATS_TEST_TMPDIR}/m.log"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0004"* ]]
    cd "${BATS_TEST_TMPDIR}"
    printf '#!/bin/sh\nexit 0\n' > autogen.sh
    printf '#!/bin/sh\nexit 3\n' > configure
    chmod +x autogen.sh configure
    run _ci_configure_tree "${BATS_TEST_TMPDIR}/c.log" --x
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0005"* ]]
    printf '#!/bin/sh\nexit 4\n' > autogen.sh
    run _ci_configure_tree "${BATS_TEST_TMPDIR}/c.log" --x
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0003"* ]]
}

@test "comfychair parse passes on all-OK/NOTRUN output" {
    # What: A run with only OK/NOTRUN lines passes.
    # Why: Proves the green parse path.
    # From: Issue #479
    log="${BATS_TEST_TMPDIR}/log"
    printf '%s\n' "FooCase           OK" "BarCase           NOTRUN, needs root" > "${log}"
    run _ci_parse_comfychair "${log}"
    [ "${status}" -eq 0 ]
}

@test "comfychair parse fails closed on a FAIL line" {
    # What: Any FAIL case fails the parse.
    # Why: A failed test must never report green.
    # From: Issue #479
    log="${BATS_TEST_TMPDIR}/log"
    printf '%s\n' "FooCase           OK" "BarCase           FAIL" > "${log}"
    run _ci_parse_comfychair "${log}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-TEST-0002"* ]]
}

@test "comfychair parse fails closed on zero parsed result lines" {
    # What: 0/0/0 parsed is a hard failure (AG-INT-003).
    # Why: An empty parse must not look like a clean pass.
    # From: Issue #479
    log="${BATS_TEST_TMPDIR}/log"
    printf '%s\n' "build noise, no result lines" > "${log}"
    run _ci_parse_comfychair "${log}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-TEST-0001"* ]]
}

@test "test fails closed on an unknown variant" {
    # What: An unknown test variant MUST reject.
    # Why: Fail-closed dispatch across every phase.
    # From: Issue #479
    CI_REPO_ROOT=/tmp run bash "${BATS_TEST_DIRNAME}/ci.sh" test bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-TEST-0005"* ]]
}

@test "test coverage: both reports, the summary, one artifact offer" {
    # What: The coverage variant end to end, tools stubbed.
    # Why: Each step passed alone; the chain was never proven.
    # From: Issue #479, PR #370, PR #544
    local fx="${BATS_TEST_TMPDIR}/fx" out="${BATS_TEST_TMPDIR}/out" sum="${BATS_TEST_TMPDIR}/sum"
    mkdir -p "${fx}"
    # What: Stub make check as one passing comfychair case.
    # Why: The chain after make check is under test.
    make() { printf '%s\n' 'Foo_Case        OK'; }
    # What: Stub lcov: write coverage.info, fail on LCOV_FAIL.
    # Why: Its result must reach the artifact or fail the step.
    lcov() { [ -z "${LCOV_FAIL:-}" ] || return 3
        case "$*" in *"--output-file coverage.info"*) echo cov > coverage.info ;; esac; echo "lcov $1"; }
    # What: Stub python3-coverage: xml writes its -o file.
    # Why: The Python report must exist before the offer.
    python3-coverage() { [ "$1" != xml ] || echo xml > "$3"; echo "pycov $1"; }
    : > "${out}"; : > "${sum}"
    CI_REPO_ROOT="${fx}" RUNNER_TEMP="${BATS_TEST_TMPDIR}" CI_TEST_UNPRIVILEGED=true \
        GITHUB_OUTPUT="${out}" GITHUB_STEP_SUMMARY="${sum}" run ci_cmd_test coverage
    [ "${status}" -eq 0 ]
    [ -s "${fx}/coverage.info" ] && [ -s "${fx}/coverage-python.xml" ]
    grep -q '^## Coverage summary' "${sum}"
    grep -qx 'artifact_name=coverage-reports' "${out}"
    grep -qx "${fx}/coverage.info" "${out}"
    grep -qx "${fx}/coverage-python.xml" "${out}"
    : > "${out}"
    CI_REPO_ROOT="${fx}" RUNNER_TEMP="${BATS_TEST_TMPDIR}" CI_TEST_UNPRIVILEGED=true LCOV_FAIL=1 \
        GITHUB_OUTPUT="${out}" GITHUB_STEP_SUMMARY="${sum}" run ci_cmd_test coverage
    [ "${status}" -eq 1 ]
    [ ! -s "${out}" ]
}

@test "report fails closed when GH_TOKEN is unset" {
    # What: report fails without credentials, never skips.
    # Why: A silent no-op would hide broken status reporting.
    # From: Issue #479, Issue #81
    GH_TOKEN="" run ci_cmd_report
    [ "${status}" -ne 0 ]
}

@test "add-to-project leaves the PAT decision to the board owner" {
    # What: PROJECT_PAT, set or empty, goes to _ci_board_add.
    # Why: A YAML secret gate once made the same call twice.
    # From: Issue #479, PR #329, PR #544
    local ev="${BATS_TEST_TMPDIR}/ev.json"
    printf '{"issue":{"html_url":"https://h/i/3"}}' > "${ev}"
    # What: Stub the board add to print the token it gets.
    # Why: The test checks which token is handed over.
    _ci_board_add() { printf 'add %s token=%s\n' "$1" "${2:-empty}"; }
    GITHUB_EVENT_PATH="${ev}" PROJECT_PAT=p GH_TOKEN=g run _ci_variables_add_to_project
    [ "${output}" = "add https://h/i/3 token=p" ]
    GITHUB_EVENT_PATH="${ev}" PROJECT_PAT="" GH_TOKEN=g run _ci_variables_add_to_project
    [ "${output}" = "add https://h/i/3 token=empty" ]
    run ci_cmd_variables secret-present
    [ "${status}" -eq 2 ]
}

@test "output writer uses the delimiter form for multi-line values" {
    # What: One-line pairs stay k=v; multi-line ones get k<<EOF.
    # Why: A newline in k=v would end the value early.
    # From: Issue #479, PR #544
    local out="${BATS_TEST_TMPDIR}/out"
    GITHUB_OUTPUT="${out}" _ci_output a 1 b $'x\ny'
    run cat "${out}"
    [ "${lines[0]}" = "a=1" ]
    [[ "${lines[1]}" == "b<<ci_eof_"* ]]
    [ "${lines[2]}" = "x" ]
    [ "${lines[3]}" = "y" ]
    [ "${lines[4]}" = "${lines[1]#b<<}" ]
}

@test "step summary appends a command's output, else NotRun" {
    # What: One writer: append when set, NotRun when unset.
    # Why: Three writers once had two different unset rules.
    # From: Issue #479, PR #544
    local s="${BATS_TEST_TMPDIR}/summary"
    GITHUB_STEP_SUMMARY="${s}" _ci_step_summary _ci_control_build_summary 0
    grep -q '^## Control build: OK' "${s}"
    GITHUB_STEP_SUMMARY="${s}" _ci_step_summary _ci_control_build_summary 3
    grep -q '^## Control build: FAILED (exit 3)' "${s}"
    unset GITHUB_STEP_SUMMARY
    run _ci_step_summary _ci_control_build_summary 0
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"[CI-SUMMARY] NotRun"* ]]
    [[ "${output}" != *"Control build"* ]]
    GITHUB_STEP_SUMMARY="${s}" run _ci_step_summary false
    [ "${status}" -eq 1 ]
}

@test "output writer fails closed on an odd argument count" {
    # What: A name without a value is a caller bug.
    # Why: Writing half a pair would shift every later output.
    # From: Issue #479, PR #544
    GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/out" run _ci_output a 1 b
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0004"* ]]
}

@test "artifact offer writes SOT name, files and retention" {
    # What: The offer emits every upload-artifact input.
    # Why: The workflow step only forwards these outputs.
    # From: Issue #479, PR #544
    local out="${BATS_TEST_TMPDIR}/out" f1="${BATS_TEST_TMPDIR}/f1" f2="${BATS_TEST_TMPDIR}/f2"
    _fixture_actions
    : > "${f1}"; : > "${f2}"
    GITHUB_OUTPUT="${out}" _ci_artifact_offer k address "${f1}" "${f2}"
    run cat "${out}"
    [ "${lines[0]}" = "artifact_name=kind-address" ]
    [ "${lines[2]}" = "${f1}" ]
    [ "${lines[3]}" = "${f2}" ]
    [ "${lines[5]}" = "artifact_retention_days=7" ]
    [ "${lines[6]}" = "artifact_if_missing=error" ]
}

@test "artifact offer fails closed on a missing or empty file set" {
    # What: No files or a missing file is an error, not a skip.
    # Why: An upload of nothing would hide a lost report.
    # From: Issue #479, PR #544
    _fixture_actions
    GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/out" run _ci_artifact_offer k ""
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-ARTIFACT-0001"* ]]
    GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/out" run _ci_artifact_offer k "" "${BATS_TEST_TMPDIR}/none"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-ARTIFACT-0002"* ]]
    [ ! -s "${BATS_TEST_TMPDIR}/out" ]
}

@test "cache plan keys default on OS, arch, autoconf inputs, run" {
    # What: Only configure.ac or m4/ changes move the input hash.
    # Why: A key is never overwritten; restore takes the newest.
    # From: Issue #54, Issue #479, PR #544
    local out="${BATS_TEST_TMPDIR}/out" sum1 sum2
    CI_REPO_ROOT="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${CI_REPO_ROOT}/m4"
    git -C "${CI_REPO_ROOT}" init -q
    echo a > "${CI_REPO_ROOT}/configure.ac"; echo b > "${CI_REPO_ROOT}/m4/x.m4"; echo c > "${CI_REPO_ROOT}/README"
    git -C "${CI_REPO_ROOT}" add -A
    git -C "${CI_REPO_ROOT}" -c user.name=t -c user.email=t@t commit -q -m one
    # What: Stub ccache to report /c/dir as cache_dir.
    # Why: The cache plan path must come from ccache.
    ccache() { [ "$*" = "--get-config cache_dir" ] && echo /c/dir; }
    GITHUB_OUTPUT="${out}" RUNNER_OS=Linux RUNNER_ARCH=X64 GITHUB_RUN_ID=7 ci_cmd_cache default
    sum1="$(sed -n 's/^key=build-Linux-X64-\(.*\)-7$/\1/p' "${out}")"
    [ -n "${sum1}" ]
    echo d > "${CI_REPO_ROOT}/README"
    git -C "${CI_REPO_ROOT}" -c user.name=t -c user.email=t@t commit -q -am two
    GITHUB_OUTPUT="${out}.2" RUNNER_OS=Linux RUNNER_ARCH=X64 GITHUB_RUN_ID=7 ci_cmd_cache default
    grep -qx "key=build-Linux-X64-${sum1}-7" "${out}.2"
    echo e > "${CI_REPO_ROOT}/m4/x.m4"
    git -C "${CI_REPO_ROOT}" -c user.name=t -c user.email=t@t commit -q -am three
    GITHUB_OUTPUT="${out}.3" RUNNER_OS=Linux RUNNER_ARCH=X64 GITHUB_RUN_ID=7 ci_cmd_cache default
    sum2="$(sed -n 's/^key=build-Linux-X64-\(.*\)-7$/\1/p' "${out}.3")"
    [ -n "${sum2}" ] && [ "${sum2}" != "${sum1}" ]
    run cat "${out}"
    [ "${lines[1]}" = "/c/dir" ]
    [ "${lines[2]}" = "${CI_REPO_ROOT}/autom4te.cache" ]
    [ "${lines[4]}" = "key=build-Linux-X64-${sum1}-7" ]
    [ "${lines[6]}" = "build-Linux-X64-${sum1}-" ]
    [ "${lines[7]}" = "build-Linux-X64-" ]
}

@test "CFL run offers crash reproducers and keeps its exit code" {
    # What: A failed run with crashes offers them, still failing.
    # Why: The upload step runs after the failure via always().
    # From: Issue #267, Issue #479, PR #544
    local out="${BATS_TEST_TMPDIR}/out"
    RUNNER_TEMP="${BATS_TEST_TMPDIR}/rt"
    _fixture_manifest 'ci_engine:' '  artifacts:' '    cfl_crashes:' '      name: "cfl-crashes"' '      retention_days: "90"' \
        'security:' '  cfl_run:' '    seconds: "1"' '    mode: "batch"'
    # What: Stub the fuzz run as a crash (rc 1).
    # Why: A crash must offer reproducers, keep its rc.
    _ci_cfl_run() { return 1; }
    mkdir -p "${RUNNER_TEMP}/cfl-workspace/out/artifacts/fuzz_x"
    : > "${RUNNER_TEMP}/cfl-workspace/out/artifacts/fuzz_x/crash-1"
    GITHUB_OUTPUT="${out}" run ci_cmd_clusterfuzzlite_run address
    [ "${status}" -eq 1 ]
    grep -qx 'artifact_name=cfl-crashes-address' "${out}"
    grep -qx "artifact_path=${RUNNER_TEMP}/cfl-workspace/out/artifacts" "${out}"
}

@test "CFL run without crashes offers nothing and passes rc" {
    # What: An empty artifacts dir yields no upload outputs.
    # Why: No reproducer means no artifact; rc is never masked.
    # From: Issue #267, Issue #479, PR #544
    local out="${BATS_TEST_TMPDIR}/out"
    RUNNER_TEMP="${BATS_TEST_TMPDIR}/rt"
    # What: Stub the fuzz run with rc 3 and no crash.
    # Why: No reproducer is offered; the rc passes on.
    _ci_cfl_run() { return 3; }
    mkdir -p "${RUNNER_TEMP}/cfl-workspace/out/artifacts"
    GITHUB_OUTPUT="${out}" run ci_cmd_clusterfuzzlite_run address
    [ "${status}" -eq 3 ]
    [ ! -e "${out}" ]
}

@test "cache plan writes nothing for a variant without ccache" {
    # What: Non-ccache variants get no key, so no cache step runs.
    # Why: Build and cache must agree on the ccache variants.
    # From: Issue #54, Issue #479, PR #544
    local out="${BATS_TEST_TMPDIR}/out"
    _forbid ccache
    GITHUB_OUTPUT="${out}" run ci_cmd_cache coverage
    [ "${status}" -eq 0 ]
    [ ! -e "${out}" ]
}

@test "draft release stops on an API error before it writes" {
    # What: A failed release or PR lookup fails; nothing writes.
    # Why: Empty lookups would publish a wrong, empty draft.
    # From: Issue #479, PR #544
    local log="${BATS_TEST_TMPDIR}/gh"
    # What: Stub gh: log calls; release list fails.
    # Why: An API error must stop before any write.
    gh() { echo "$*" >> "${log}"; case "$1 $2" in "release list") return 1 ;; esac; }
    GH_TOKEN=x GITHUB_REPOSITORY=o/r run _ci_publish_draft_release
    [ "${status}" -eq 1 ]
    run grep -c -E 'release (edit|create)' "${log}"
    [ "${output}" = "0" ]
    # What: Stub gh: one release, one PR, no draft yet.
    # Why: Drives the dry-run create path end to end.
    gh() {
        case "$1 $2" in
            "release list") echo 2026-01-01 ;;
            "pr list") echo '[{"number":5,"title":"fix(ci): a"}]' ;;
            "release view") echo "release not found" >&2; return 1 ;;
        esac
    }
    DRY_RUN=true GH_TOKEN=x GITHUB_REPOSITORY=o/r run _ci_publish_draft_release
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DRY_RUN would run: gh release create draft-current_dev"* ]]
    # What: Stub gh: the draft lookup fails on auth, not 404.
    # Why: An API error must not read as "no draft, create".
    gh() {
        case "$1 $2" in
            "release list") echo 2026-01-01 ;;
            "pr list") echo '[]' ;;
            "release view") echo "HTTP 401: Bad credentials" >&2; return 1 ;;
        esac
    }
    DRY_RUN=true GH_TOKEN=x GITHUB_REPOSITORY=o/r run _ci_publish_draft_release
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-PUBLISH-0010"*"Bad credentials"* ]]
    [[ "${output}" != *"would run: gh release"* ]]
}

@test "draft release body groups PRs under their category heading" {
    # What: A fix PR lands under ### Fixed with number and title.
    # Why: The heading is a value; only the body is a nameref.
    # From: Issue #479, PR #544
    local body=""
    _ci_draft_release_append body "Fixed" "* #5 | fix(ci): a"
    [ "${body}" = "$(printf '%s\n%s\n' '### Fixed' '* #5 | fix(ci): a')
" ]
}

@test "OpenSSF API checks fail closed instead of reading NotMet" {
    # What: An API error or unreadable field errors, never NotMet.
    # Why: A tool failure must never pose as a compliance finding.
    # From: Issue #312, Issue #479, PR #544

    # What: Stub every gh call as failing.
    # Why: API errors must fail, not read as NotMet.
    gh() { return 1; }
    GITHUB_REPOSITORY=o/r run _ci_ossf_check_ac03 7
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-OSSF-0001"*"ruleset 7"* ]]
    GITHUB_REPOSITORY=o/r run _ci_ossf_verdict _ci_ossf_check_ac03 7
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-OSSF-0004"* ]]
    [[ "${output}" != *"NotMet"* ]]
    GITHUB_REPOSITORY=o/r run _ci_ossf_check_br07
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-OSSF-0002"* ]]
    # What: Stub gh to answer null for the field.
    # Why: A hidden field must fail, not read as NotMet.
    gh() { echo null; }
    GITHUB_REPOSITORY=o/r run _ci_ossf_check_br07
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-OSSF-0003"* ]]
    # What: Stub gh: a met ruleset, scanning on, push off.
    # Why: Real Met and NotMet verdicts must still come out.
    gh() { case "$*" in *rulesets/7*) echo '["pull_request","deletion"]' ;; *) echo '{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"disabled"}}' ;; esac; }
    GITHUB_REPOSITORY=o/r run _ci_ossf_verdict _ci_ossf_check_ac03 7
    [ "${output}" = "Met" ]
    GITHUB_REPOSITORY=o/r run _ci_ossf_verdict _ci_ossf_check_br07
    [ "${output}" = "NotMet" ]
}

@test "BR-01 flags only a ref-taking checkout in a target workflow" {
    # What: pull_request_target plus checkout of a ref is NotMet.
    # Why: Base-SHA checkouts run no PR code; a head ref does.
    # From: Issue #312, PR #544
    local fx="${BATS_TEST_TMPDIR}/fx" boot
    boot='curl -fsSL "x/ci.sh" | bash -s -- checkout'
    mkdir -p "${fx}/.github/workflows"
    printf '%s\n' 'on: pull_request_target' "      - run: ${boot}" \
        '        env: {HEAD: "${{ github.event.pull_request.head.sha }}"}' > "${fx}/.github/workflows/a.yml"
    cd "${fx}"
    [ "$(_ci_ossf_verdict _ci_ossf_check_br01)" = "Met" ]
    printf '%s\n' 'on: pull_request_target' "      - run: ${boot} 1 \"\$HEAD\"" > "${fx}/.github/workflows/b.yml"
    [ "$(_ci_ossf_verdict _ci_ossf_check_br01)" = "NotMet" ]
}

@test "OpenSSF local checks give no verdict on a tool error" {
    # What: git, awk or grep failing in a check is no verdict.
    # Why: A failed tool must never read as Met or NotMet.
    # From: Issue #312, Issue #479, PR #544
    local fx="${BATS_TEST_TMPDIR}/fx"
    mkdir -p "${fx}"
    cd "${fx}"
    # What: Stub git as failing.
    # Why: QA-05 must not read a git error as no binaries.
    git() { return 128; }
    run _ci_ossf_verdict _ci_ossf_check_qa05
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-OSSF-0004"* ]]
    unset -f git
    run _ci_ossf_verdict _ci_ossf_check_ac04
    [ "${status}" -eq 2 ]
    run _ci_ossf_verdict _ci_ossf_check_br01
    [ "${status}" -eq 2 ]
    run _ci_ossf_verdict _ci_ossf_check_br05_do06
    [ "${status}" -eq 2 ]
    run _ci_ossf_verdict grep -rq "ci.sh attest release" .github/workflows/
    [ "${status}" -eq 2 ]
    # What: Stub gh: valid ruleset call, broken JSON body.
    # Why: A jq parse error must not read as NotMet.
    gh() { echo 'not json'; }
    GITHUB_REPOSITORY=o/r run _ci_ossf_verdict _ci_ossf_check_ac03 7
    [ "${status}" -eq 2 ]
    GITHUB_REPOSITORY=o/r run _ci_ossf_verdict _ci_ossf_check_br07
    [ "${status}" -eq 2 ]
}

@test "ossf verdict: Met, NotMet, and a tool error is no verdict" {
    # What: rc 0 is Met, rc 1 NotMet, any other rc an error.
    # Why: A missing file once read as a NotMet finding.
    # From: Issue #479, Issue #312, PR #544
    local fx="${BATS_TEST_TMPDIR}/fx"
    printf 'has Security Advisory here\n' > "${fx}"
    [ "$(_ci_ossf_verdict grep -q 'Security Advisor' "${fx}")" = "Met" ]
    [ "$(_ci_ossf_verdict grep -q 'nope-xyz' "${fx}")" = "NotMet" ]
    [ "$(_ci_ossf_verdict grep -qi 'SECURITY ADVISOR' "${fx}")" = "Met" ]
    run _ci_ossf_verdict grep -q 'x' "${BATS_TEST_TMPDIR}/missing"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-OSSF-0004"* ]]
    [[ "${output}" != *"NotMet"* ]]
}

@test "gc candidates keep protected, rollback set, and real tags" {
    # What: Only unprotected old untagged and whole old series go.
    # Why: A real tag or live index child must never be deleted.
    # From: Issue #479, PR #544
    local v out
    v='[
      {"id":1,"name":"sha256:u1","created_at":"2026-01-01T00:00:00Z","metadata":{"container":{"tags":[]}}},
      {"id":2,"name":"sha256:u2","created_at":"2026-01-02T00:00:00Z","metadata":{"container":{"tags":[]}}},
      {"id":3,"name":"sha256:u3","created_at":"2026-01-03T00:00:00Z","metadata":{"container":{"tags":[]}}},
      {"id":4,"name":"sha256:u4","created_at":"2026-01-04T00:00:00Z","metadata":{"container":{"tags":[]}}},
      {"id":5,"name":"sha256:u5","created_at":"2026-01-05T00:00:00Z","metadata":{"container":{"tags":[]}}},
      {"id":11,"name":"sha256:m1","created_at":"2026-01-01T00:00:00Z","metadata":{"container":{"tags":["manual-1"]}}},
      {"id":12,"name":"sha256:m2","created_at":"2026-01-02T00:00:00Z","metadata":{"container":{"tags":["manual-2-amd64"]}}},
      {"id":13,"name":"sha256:m3","created_at":"2026-01-03T00:00:00Z","metadata":{"container":{"tags":["manual-3"]}}},
      {"id":14,"name":"sha256:mx","created_at":"2026-01-01T00:00:00Z","metadata":{"container":{"tags":["manual-1","v3.6.6-NG"]}}},
      {"id":20,"name":"sha256:l","created_at":"2026-01-01T00:00:00Z","metadata":{"container":{"tags":["latest"]}}}
    ]'
    out="$(_ci_gc_candidates "${v}" '["sha256:u4"]' 3 '^manual-([0-9]+)(-amd64|-arm64)?$' 2 | cut -f1 | sort -n | tr '\n' ' ')"
    [ "${out}" = "1 11 " ]
}

@test "gc rejects a package outside the SOT before any API call" {
    # What: Only release.ghcr_packages (or all) may be pruned.
    # Why: A typo MUST NOT reach a delete-capable token.
    # From: Issue #479, PR #544
    _forbid gh docker
    GH_TOKEN=x GITHUB_REPOSITORY_OWNER=wiki-mod run ci_cmd_gc not-a-package
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0001"* ]]
    [[ "${output}" != *"must not run"* ]]
}

@test "gc protection fails closed when a tag cannot be inspected" {
    # What: An uninspectable tag aborts pruning of that package.
    # Why: Unknown children would otherwise lose their protection.
    # From: Issue #479, PR #544

    # What: Stub docker as failing to inspect.
    # Why: An uninspectable tag must stop the prune.
    docker() { return 1; }
    GITHUB_REPOSITORY_OWNER=wiki-mod run _ci_gc_protected_digests distcc-ng '[{"metadata":{"container":{"tags":["latest"]}}}]'
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GC-0002"* ]]
}

@test "gc protection fails closed on unreadable tags or manifests" {
    # What: Bad versions JSON or a bad manifest aborts pruning.
    # Why: A jq error must not drop a child from the keep-set.
    # From: Issue #479, PR #544

    # What: Stub docker to print a non-JSON manifest.
    # Why: A bad manifest must stop the prune.
    docker() { printf 'not json\n'; }
    GITHUB_REPOSITORY_OWNER=wiki-mod run _ci_gc_protected_digests distcc-ng 'not json'
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GC-0003"* ]]
    GITHUB_REPOSITORY_OWNER=wiki-mod run _ci_gc_protected_digests distcc-ng '[{"metadata":{"container":{"tags":["latest"]}}}]'
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GC-0004"* ]]
    # What: Stub docker with a two-child index manifest.
    # Why: Both children must land in the keep-set.
    docker() { printf '{"manifests":[{"digest":"sha256:a"},{"digest":"sha256:b"}]}\n'; }
    GITHUB_REPOSITORY_OWNER=wiki-mod run _ci_gc_protected_digests distcc-ng '[{"metadata":{"container":{"tags":["latest"]}}}]'
    [ "${status}" -eq 0 ]
    [ "${output}" = '["sha256:a","sha256:b"]' ]
}

@test "changelog event: pre-release skips, a bad event fails" {
    # What: true skips (rc 3); non-boolean or unreadable fails.
    # Why: A jq error must not read as "pre-release, skip".
    # From: Issue #479, PR #544
    local ev="${BATS_TEST_TMPDIR}/ev.json"
    echo '{"release":{"prerelease":true,"tag_name":"v1-NG"}}' > "${ev}"
    GITHUB_EVENT_NAME=release GITHUB_EVENT_PATH="${ev}" run _ci_changelog_from_event
    [ "${status}" -eq 3 ]
    echo '{"release":{"tag_name":"v1-NG"}}' > "${ev}"
    GITHUB_EVENT_NAME=release GITHUB_EVENT_PATH="${ev}" run _ci_changelog_from_event
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-EVENT-0001"* ]]
    echo '{"release":{"prerelease":"yes","tag_name":"v1-NG"}}' > "${ev}"
    GITHUB_EVENT_NAME=release GITHUB_EVENT_PATH="${ev}" run _ci_changelog_from_event
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-PUBLISH-0003"* ]]
    echo '{"release":{"prerelease":false}}' > "${ev}"
    GITHUB_EVENT_NAME=release GITHUB_EVENT_PATH="${ev}" run _ci_changelog_from_event
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-EVENT-0001"*".release.tag_name"* ]]
    echo 'not json' > "${ev}"
    GITHUB_EVENT_NAME=release GITHUB_EVENT_PATH="${ev}" run _ci_changelog_from_event
    [ "${status}" -eq 2 ]
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_EVENT_PATH="${ev}" run _ci_changelog_from_event
    [ "${status}" -eq 2 ]
    echo '{"release":{"prerelease":false,"tag_name":"v1-NG","body":"n"}}' > "${ev}"
    GITHUB_EVENT_NAME=release GITHUB_EVENT_PATH="${ev}" run _ci_changelog_from_event
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'"tag": "v1-NG"'* ]]
}

@test "project board identity comes only from the SOT" {
    # What: An env value MUST NOT shadow the SOT's board identity.
    # Why: One owner; a second source is a parallel owner.
    # From: Issue #236, Issue #479, PR #544
    _fixture_manifest 'project_board:' '  owner: "sot-owner"' '  number: "7"'
    PROJECT_OWNER="shadow" PROJECT_NUMBER="999"
    _ci_project_board_load
    [ "${PROJECT_OWNER}" = "sot-owner" ]
    [ "${PROJECT_NUMBER}" = "7" ]
}

@test "failed-jobs filter keeps only failure and cancelled" {
    # What: Only real failures are reported, never skips.
    # Why: A skipped dependent would mask the root cause.
    # From: Issue #479, PR #476
    run _ci_failed_jobs "$(printf 'build=success\ne2e=failure\npublish=skipped\nx=cancelled\n')"
    [ "${status}" -eq 0 ]
    [ "${output}" = "e2e x" ]
}

@test "gate passes when every job succeeded or was skipped" {
    # What: A NOOP/skipped matrix leg must not fail the gate.
    # Why: Content-based impact selection skips whole jobs.
    # From: Issue #479, PR #544
    JOBS="$(printf 'build=success\ne2e=skipped\n')" run ci_cmd_gate
    [ "${status}" -eq 0 ]
}

@test "gate fails closed when a real job failed" {
    # What: A real failure/cancelled entry fails the gate.
    # Why: It is the one stable required-check name.
    # From: Issue #479, PR #544
    JOBS="$(printf 'build=success\ne2e=failure\n')" run ci_cmd_gate
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GATE-0001"* ]]
}

@test "gate fails closed on a JOBS list with no or bad pairs" {
    # What: No parsable pair, or a bad one, is an error.
    # Why: An empty job list once passed the required gate.
    # From: Issue #479, PR #544
    JOBS=" " run ci_cmd_gate
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-JOBS-0002"* ]]
    JOBS="$(printf 'build=success\ne2e:failure\n')" run ci_cmd_gate
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-JOBS-0001"*"e2e:failure"* ]]
    JOBS="build=" run ci_cmd_gate
    [ "${status}" -eq 2 ]
    JOBS="$(printf 'build=success\ne2e=unknown\n')" run ci_cmd_gate
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-JOBS-0001"*"e2e=unknown"* ]]
}

@test "impact: a docs-only diff selects nothing (NOOP)" {
    # What: A .md edit MUST NOT trigger any gated job.
    # Why: Kills the sledgehammer full-CI on documentation.
    # From: Issue #479, PR #544
    run _ci_phases_for_paths < <(printf '%s\n' README.md doc/threat-model.md)
    [ "${status}" -eq 0 ]
    [ "${output}" = "NOOP" ]
}

@test "impact: a c-source diff selects build, e2e and package" {
    # What: A src/*.c edit selects compile, e2e and packaging.
    # Why: Real code changes must build, distribute and package.
    # From: Issue #479, PR #544
    run _ci_phases_for_paths < <(printf '%s\n' src/dopt.c)
    [ "${status}" -eq 0 ]
    [ "$(tr '\n' ' ' <<< "${output}")" = "build e2e package " ]
}

@test "impact: a SOT or engine change selects every gated job" {
    # What: build-manifest.yml or ci.sh select all five phases.
    # Why: A pin bump or engine edit can break any of them.
    # From: Issue #479, PR #544
    local p
    for p in .github/yaml/build-manifest.yml .github/scripts/ci.sh; do
        run _ci_phases_for_paths < <(printf '%s\n' "${p}")
        [ "$(tr '\n' ' ' <<< "${output}")" = "build container e2e package verify " ]
    done
}

@test "every SOT impact phase gates a validate.yml job" {
    # What: The job gated on phase ph is the one running ci.sh ph.
    # Why: A phase nobody runs is policy that changes nothing.
    # From: Issue #479, PR #544
    local ph wiring
    local phases=()
    _ci_mapfile phases _ci_all_phases
    [ "${#phases[@]}" -gt 0 ]
    wiring="$(awk '
        /^  [A-Za-z0-9_-]+:$/ { job = substr($1, 1, length($1) - 1) }
        /^    if:/ { gate[job] = $0 }
        match($0, /run: bash \.github\/scripts\/ci\.sh [a-z0-9-]+/) {
            c = substr($0, RSTART, RLENGTH); sub(/.* /, "", c); cmds[job] = cmds[job] " " c " " }
        END { for (j in gate) print j "|" gate[j] "|" cmds[j] }
    ' "${CI_REPO_ROOT}/.github/workflows/validate.yml")"
    for ph in "${phases[@]}"; do
        if [ "${ph}" = build ]; then
            awk -F'|' -v ph="${ph}" 'index($2, "needs.plan.outputs.build == '\''true'\''") && index($3, " " ph " ") { f = 1 }
                END { exit !f }' <<< "${wiring}" || { echo "no job runs ${ph}"; false; }
        else
            awk -F'|' -v ph="${ph}" 'index($2, "contains(needs.plan.outputs.phases, '\''" ph "'\'')") && index($3, " " ph " ") { f = 1 }
                END { exit !f }' <<< "${wiring}" || { echo "no job runs ${ph}"; false; }
        fi
    done
}

@test "every job legacy CI bounded keeps a timeout-minutes" {
    # What: Build, test, e2e, package and scan jobs stay bounded.
    # Why: Unbounded, a hung test runs to the 6-hour default.
    # From: Issue #479, PR #544
    local spec wf job
    for spec in validate:plan validate:lint validate:build_test validate:e2e validate:package \
        validate:verify_image security:route security:codeql security:openssf nightly:build_test \
        nightly:sanitizer nightly:e2e nightly:bidirectional_e2e nightly:publish release:build_test \
        release:e2e release:package housekeeping:heartbeat housekeeping:control; do
        wf="${spec%%:*}" job="${spec#*:}"
        awk -v job="${job}" '
            /^jobs:/ { j = 1 }
            j && /^  [A-Za-z0-9_-]+:$/ { cur = substr($1, 1, length($1) - 1) }
            cur == job && /^    timeout-minutes: [0-9]+$/ { found = 1 }
            END { exit !found }
        ' "${CI_REPO_ROOT}/.github/workflows/${wf}.yml" || { echo "${spec}"; false; }
    done
}

@test "every CI_COMMANDS entry has its own dispatch arm" {
    # What: The registry and the case dispatch name the same set.
    # Why: A listed command without an arm was a silent stub.
    # From: Issue #479, PR #544
    local c fn arm
    local arms=()
    for c in ${CI_COMMANDS}; do
        fn="ci_cmd_${c//-/_}"
        # What: Stub the command's phase function to report itself.
        # Why: Proves ci_main really routes each name to its owner.
        eval "${fn}() { echo \"reached ${fn} \$*\"; }"
        run ci_main "${c}" a1
        [ "${status}" -eq 0 ] || { echo "${c}: ${output}"; false; }
        [ "${output}" = "reached ${fn} a1" ] || { echo "${c}: ${output}"; false; }
    done
    # What: Every dispatch arm must be a registered command.
    # Why: An arm missing from CI_COMMANDS can never be reached.
    _ci_mapfile arms awk '/^ci_main\(\)/ { m = 1 } m && /^}/ { exit }
        m && match($0, /^ +[a-z-]+\) ci_cmd_/) {
            a = substr($0, RSTART, RLENGTH); sub(/^ +/, "", a); sub(/\).*/, "", a); print a }' "${CI_SH}"
    [ "${#arms[@]}" -gt 0 ]
    for arm in "${arms[@]}"; do
        [[ " ${CI_COMMANDS} " == *" ${arm} "* ]] || { echo "unregistered arm: ${arm}"; false; }
    done
}

@test "impact: an include-server .py diff selects build but not package" {
    # What: include_server/*.py selects build and e2e only.
    # Why: A pump-mode Python change is not a packaging change.
    # From: Issue #479, PR #544
    run _ci_phases_for_paths < <(printf '%s\n' include_server/basics.py)
    [ "${status}" -eq 0 ]
    [ "$(tr '\n' ' ' <<< "${output}")" = "build e2e " ]
}

@test "impact: an unmatched path yields NOOP" {
    # What: A path in no class selects no work at all.
    # Why: DEFAULT=NOOP; nothing runs on an irrelevant change.
    # From: Issue #479
    run _ci_phases_for_paths < <(printf '%s\n' LICENSE)
    [ "${status}" -eq 0 ]
    [ "${output}" = "NOOP" ]
}

@test "classify: a src/*.c path maps to the c-source class" {
    # What: One path resolves to exactly its owning class.
    # Why: Guards the glob matcher against silent misrouting.
    # From: Issue #479
    run _ci_classify_paths < <(printf '%s\n' src/dopt.c)
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"c-source"* ]]
}

@test "glob match: a prefix.* pattern matches its real extension" {
    # What: Regression test for the fallback-match bug.
    # Why: case needs pat unquoted or '*' becomes literal.
    # From: Issue #479
    run _ci_glob_match "src/config-parser.*" "src/config-parser.c"
    [ "${status}" -eq 0 ]
}

@test "glob match: a prefix.* pattern rejects an unrelated file" {
    # What: The fix must not make the matcher always-true.
    # Why: A false positive would mislabel unrelated PRs.
    # From: Issue #479
    run _ci_glob_match "src/config-parser.*" "src/unrelated.c"
    [ "${status}" -ne 0 ]
}

@test "glob: '**/' also matches files at the top level" {
    # What: '**/*.md' matches README.md and doc/a/b.md alike.
    # Why: Globstar semantics; a root file is zero dirs deep.
    # From: Issue #479, PR #544
    run _ci_glob_match "**/*.md" "README.md"
    [ "${status}" -eq 0 ]
    run _ci_glob_match "**/*.md" "doc/a/b.md"
    [ "${status}" -eq 0 ]
    run _ci_glob_match "**/*.md" "README.mdx"
    [ "${status}" -ne 0 ]
}

@test "classifier: a path map's exclude list removes a hit" {
    # What: A path matching paths but also exclude gets no name.
    # Why: The documentation label must skip CHANGELOG.md alone.
    # From: Issue #479, PR #544
    _fixture_manifest 'labels:' '  documentation:' '    paths: ["doc/**", "**/*.md"]' \
        '    exclude: ["CHANGELOG.md"]' '  ci:' '    paths: [".github/workflows/**"]'
    run _ci_classify_paths labels <<< "CHANGELOG.md"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    run _ci_classify_paths labels < <(printf '%s\n' CHANGELOG.md README.md .github/workflows/v.yml)
    [ "${output}" = "$(printf '%s\n' ci documentation)" ]
}

@test "label-pr applies path labels and the title category" {
    # What: SOT path labels plus the title's category are added.
    # Why: The board and release notes read these labels.
    # From: Issue #479, PR #544
    local ev="${BATS_TEST_TMPDIR}/ev.json"
    printf '{"pull_request":{"number":5}}' > "${ev}"
    _fixture_manifest 'labels:' '  ci:' '    paths: [".github/workflows/**"]'
    # What: Stub gh: a workflow diff; echo pr edit.
    # Why: Labels must come from the SOT path map.
    gh() { case "$1 $2" in "pr diff") echo .github/workflows/v.yml ;; "pr edit") echo "edit $*" ;; esac; }
    # What: Stub live PR data with a fix(ci) title.
    # Why: The title sets the category label offline.
    _ci_metadata_fetch_live() { export PR_TITLE="fix(ci): x"; }
    GITHUB_REPOSITORY=o/r GITHUB_EVENT_PATH="${ev}" run _ci_variables_label_pr
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--add-label ci,bug"* ]]
}

@test "pr category: maps AG-GH-014 types to release-drafter labels" {
    # What: feat/fix/docs/security map to a changelog category.
    # Why: Replaces release-drafter's autolabeler regex entirely.
    # From: Issue #479
    [ "$(_ci_pr_category_label 'feat(pump): add IPv6')" = "enhancement" ]
    [ "$(_ci_pr_category_label 'fix(protocol): correct frame bug')" = "bug" ]
    [ "$(_ci_pr_category_label 'docs(governance): add rule')" = "documentation" ]
    [ "$(_ci_pr_category_label 'security(config): patch leak')" = "security" ]
}

@test "pr category: an uncategorized type prints nothing" {
    # What: chore/refactor/etc. get no changelog category label.
    # Why: The release notes have exactly these 4 categories.
    # From: Issue #479
    [ -z "$(_ci_pr_category_label 'chore(ci): bump a dependency')" ]
}

@test "pr category: a title not in AG-GH-014 shape gets no label" {
    # What: "fix stuff" has no type, so it gets no category.
    # Why: Labels and the title check share one title parser.
    # From: Issue #479, PR #544
    run _ci_pr_category_label 'fix stuff'
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    run _ci_title_type 'fix(ci)!: x'
    [ "${output}" = "fix" ]
    run _ci_title_type 'fix stuff'
    [ "${status}" -eq 1 ]
}

@test "line-endings guard passes on an LF-only tree" {
    # What: An LF-only fixture must pass the guard.
    # Why: Proves the green path, not only the failing one.
    # From: Issue #479
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"; printf 'clean line\n' > "${fx}/ok.sh"
    run ci_guard_line_endings "${fx}"
    [ "${status}" -eq 0 ]
}

@test "line-endings guard fails closed on a CRLF file" {
    # What: A CR byte anywhere must fail the guard.
    # Why: Proves the fail-closed path is reachable.
    # From: Issue #479
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"; printf 'bad line\r\n' > "${fx}/crlf.sh"
    run ci_guard_line_endings "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-EOL-0001"* ]]
}

@test "full-sha guard passes on a 64-hex digest" {
    # What: A full 64-hex sha256 is compliant.
    # Why: Proves the green path for the SHA rule.
    # From: Issue #479
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"
    printf 'image: "debian@sha256:fac46bff2e02f51425b6e33b0e1169f55dfb053d83511ca28aa50c09fd5ed7a4"\n' > "${fx}/f.yml"
    run ci_guard_full_sha "${fx}"
    [ "${status}" -eq 0 ]
}

@test "full-sha guard fails closed on an abbreviated digest" {
    # What: A short sha256 must be rejected.
    # Why: No abbreviations or special SHA forms allowed.
    # From: Issue #479
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"; printf 'image: "debian@sha256:fac46bff"\n' > "${fx}/f.yml"
    run ci_guard_full_sha "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-SHA-0001"* ]]
}

@test "guards fail closed on an unreadable tree, not pass" {
    # What: A grep error in a guard is a failure, not clean.
    # Why: 2>/dev/null || true once turned read errors green.
    # From: Issue #479, PR #544
    run ci_guard_line_endings "${BATS_TEST_TMPDIR}/nope"
    [ "${status}" -eq 2 ]
    run ci_guard_full_sha "${BATS_TEST_TMPDIR}/nope"
    [ "${status}" -eq 2 ]
}

@test "changelog and comfychair fail closed on bad input" {
    # What: A bad diff range or a missing log is an error.
    # Why: Both used to read as "no change" or a parse result.
    # From: Issue #479, PR #544
    BASE=0000000000000000000000000000000000000000 HEAD=HEAD PR_LABELS="" run _ci_check_changelog
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-DIFF-0001"* ]]
    run _ci_parse_comfychair "${BATS_TEST_TMPDIR}/nope.log"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-TEST-0007"* ]]
}

@test "pin guard passes the repo's own Dockerfiles and workflows" {
    # What: The real tree holds pins only in the SOT.
    # Why: Thesis 1: build-manifest.yml is the sole pin owner.
    # From: Issue #479, PR #544
    run ci_guard_pins_in_sot "${CI_REPO_ROOT}"
    [ "${status}" -eq 0 ]
}

@test "pin guard passes ARG FROMs, stage aliases and :local images" {
    # What: FROM ${ARG}, FROM <stage> and FROM <name>:local pass.
    # Why: None of them can pull an image the SOT did not pin.
    # From: Issue #479, PR #544
    local fx="${BATS_TEST_TMPDIR}/fx"
    _fixture_actions
    mkdir -p "${fx}/d" "${fx}/.github/workflows"
    printf '%s\n' 'ARG BASE' 'FROM ${BASE} AS one' 'FROM one AS two' 'FROM x-y:local' > "${fx}/d/Dockerfile"
    printf '%s\n' 'jobs:' '  container:' '    steps:' '      - run: bash .github/scripts/ci.sh build' \
        "      - uses: ${FX_PIN}" > "${fx}/.github/workflows/w.yml"
    run ci_guard_pins_in_sot "${fx}"
    [ "${status}" -eq 0 ]
}

@test "pin guard fails closed on every pin form outside the SOT" {
    # What: Digest, ARG default, pulled FROM, workflow pins fail.
    # Why: Each one is a second pin owner beside the SOT.
    # From: Issue #479, PR #544
    local fx="${BATS_TEST_TMPDIR}/fx" d
    d="$(printf 'a%.0s' {1..64})"
    _fixture_actions
    mkdir -p "${fx}/d" "${fx}/.github/workflows"
    printf '%s\n' "ARG BASE=debian@sha256:${d}" 'FROM debian:trixie' 'FROM --platform=linux/amd64 golang:1' > "${fx}/d/Dockerfile"
    printf '%s\n' "        image: foo/bar@sha256:${d}" '    container: debian:13' "      - uses: ${FX_PIN}" \
        > "${fx}/.github/workflows/w.yml"
    run ci_guard_pins_in_sot "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"d/Dockerfile:1: digest"* ]]
    [[ "${output}" == *"d/Dockerfile:1: arg-default"* ]]
    [[ "${output}" == *"d/Dockerfile:2: from debian:trixie"* ]]
    [[ "${output}" == *"d/Dockerfile:3: from golang:1"* ]]
    [[ "${output}" == *"w.yml:1: image or action pin"* ]]
    [[ "${output}" == *"w.yml:2: image or action pin"* ]]
    [[ "${output}" != *"w.yml:3:"* ]]
}

@test "pin guard fails closed on a SOT action no workflow uses" {
    # What: A SOT action pin absent from every workflow fails.
    # Why: Dependabot bumps only YAML; an unused pin goes stale.
    # From: Issue #479, PR #544
    local fx="${BATS_TEST_TMPDIR}/fx"
    _fixture_actions
    mkdir -p "${fx}/.github/workflows"
    printf '%s\n' '      - run: bash .github/scripts/ci.sh build' > "${fx}/.github/workflows/w.yml"
    run ci_guard_pins_in_sot "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-PIN-0003"*"${FX_PIN}"* ]]
}

@test "the CFL Dockerfile FROM is the SOT base-builder tag" {
    # What: CFL builds its Dockerfile without build-args.
    # Why: So its FROM literal must equal the tag ci.sh sets.
    # From: Issue #267, Issue #479, PR #544
    local tag
    tag="$(_ci_sot_scalar security.cfl_base.tag)"
    grep -qx "FROM ${tag}" "${CI_REPO_ROOT}/.clusterfuzzlite/Dockerfile"
}

@test "image alias pulls the SOT pin and tags it locally" {
    # What: The alias resolves a SOT path to its pinned image.
    # Why: A builder without build-args may only see that tag.
    # From: Issue #267, Issue #479, PR #544
    _fixture_manifest 'base:' '  img: "b@sha256:0"' 's:' '  a:' '    from: "base.img"' '    tag: "a:local"'
    _capture_docker
    run _ci_image_alias s.a
    [ "${status}" -eq 0 ]
    [ "$(tr '\n' ' ' < "${BATS_TEST_TMPDIR}/argv")" = "pull b@sha256:0 tag b@sha256:0 a:local " ]
}

@test "route security: crons, PRs and dispatch refs pick the jobs" {
    # What: Each event and SOT cron yields its scans/openssf pair.
    # Why: The workflow holds no cron and no event decision.
    # From: Issue #479, PR #544
    local ev="${BATS_TEST_TMPDIR}/ev.json" out="${BATS_TEST_TMPDIR}/out"
    _fixture_manifest 'schedules:' '  security_scans:' '    workflow: "security"' '    cron: "0 5 * * 0"' \
        '  openssf:' '    workflow: "security"' '    cron: "0 6 1,15 * *"' 'security:' '  cfl_run:' \
        '    sanitizers: ["address"]' '  codeql:' '    languages: ["c-cpp", "python"]'
    # What: Run route security for one event and ref.
    # Why: Each case reads the scans/openssf pair.
    _route() {
        : > "${out}"
        GITHUB_OUTPUT="${out}" GITHUB_EVENT_PATH="${ev}" GITHUB_EVENT_NAME="$1" GITHUB_REF_NAME="$2" \
            ci_cmd_route security || return 1
        head -2 "${out}" | tr '\n' ' '
    }
    echo '{}' > "${ev}"
    [ "$(_route pull_request 544/merge)" = "scans=true openssf=false " ]
    [ "$(_route workflow_dispatch master)" = "scans=true openssf=true " ]
    [ "$(_route workflow_dispatch bot/x)" = "scans=true openssf=false " ]
    echo '{"schedule":"0 5 * * 0"}' > "${ev}"
    [ "$(_route schedule master)" = "scans=true openssf=false " ]
    echo '{"schedule":"0 6 1,15 * *"}' > "${ev}"
    [ "$(_route schedule master)" = "scans=false openssf=true " ]
    grep -qx 'codeql_languages=\["c-cpp","python"\]' "${out}"
    grep -qx 'cfl_sanitizers=\["address"\]' "${out}"
}

@test "route housekeeping: the weekly cron or a dispatch task" {
    # What: Weekly runs sot-update+heartbeat; a task runs itself.
    # Why: gc only ever runs on an explicit dispatch.
    # From: Issue #479, PR #544
    local ev="${BATS_TEST_TMPDIR}/ev.json" out="${BATS_TEST_TMPDIR}/out"
    _fixture_manifest 'schedules:' '  housekeeping_weekly:' '    workflow: "housekeeping"' '    cron: "0 5 * * 1"'
    echo '{"schedule":"0 5 * * 1"}' > "${ev}"
    GITHUB_OUTPUT="${out}" GITHUB_EVENT_PATH="${ev}" GITHUB_EVENT_NAME=schedule run ci_cmd_route housekeeping
    [ "$(tr '\n' ' ' < "${out}")" = "gc=false sot_update=true heartbeat=true " ]
    : > "${out}"
    echo '{"inputs":{"task":"gc"}}' > "${ev}"
    GITHUB_OUTPUT="${out}" GITHUB_EVENT_PATH="${ev}" GITHUB_EVENT_NAME=workflow_dispatch run ci_cmd_route housekeeping
    [ "$(tr '\n' ' ' < "${out}")" = "gc=true sot_update=false heartbeat=false " ]
    run ci_cmd_route nightly
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-ROUTE-0001"* ]]
}

@test "mirror guard passes the real tree and fails closed on drift" {
    # What: A cron or package choice off the SOT fails lint.
    # Why: Both must be literal YAML; the SOT owns their values.
    # From: Issue #479, PR #544
    local fx="${BATS_TEST_TMPDIR}/fx"
    run ci_guard_sot_mirrors "${CI_REPO_ROOT}"
    [ "${status}" -eq 0 ]
    mkdir -p "${fx}/.github/workflows"
    _fixture_manifest 'schedules:' '  n:' '    workflow: "w"' '    cron: "0 1 * * *"' \
        'release:' '  ghcr_packages: ["p"]'
    printf '%s\n' 'on:' '  schedule:' "    - cron: '0 2 * * *'" > "${fx}/.github/workflows/w.yml"
    printf '%s\n' 'on:' '  workflow_dispatch:' '    inputs:' '      package:' '        options:' \
        '          - all' '          - q' '        default: all' > "${fx}/.github/workflows/housekeeping.yml"
    run ci_guard_sot_mirrors "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-MIRROR-0001"*"0 2 * * *"* ]]
    [[ "${output}" == *"CI-ERROR-GUARD-MIRROR-0002"* ]]
}

@test "verify starts one container and runs every in-image check" {
    # What: One docker run, one exec per check; failures add up.
    # Why: #479: the verify container starts once for all phases.
    # From: Issue #479, PR #544
    local log="${BATS_TEST_TMPDIR}/docker"
    # What: Stub docker: log calls; in-image checkout fails.
    # Why: Proves one container and the failed check name.
    docker() {
        echo "$1 $*" >> "${log}"
        [ "$1" = exec ] && [ "$4" = "${CI_CONTAINER_SH}" ] && [ "$6" = checkout ] && return 1
        return 0
    }
    run _ci_verify_in_image img ptrace-selftest build-test samba-configure-dryrun net1
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-VERIFY-0006"*"failed in-image checks: build-test"* ]]
    [ "$(grep -c '^run ' "${log}")" -eq 1 ]
    [ "$(grep -c '^exec ' "${log}")" -eq 3 ]
    grep -q '^run run .*--name net1-verify .*--cap-add=SYS_PTRACE.* img sleep infinity' "${log}"
}

@test "comment guard passes standard blocks, directives and heredocs" {
    # What: Standard blocks, directives and heredocs pass.
    # Why: Heredoc text and tool directives are not prose.
    # From: Issue #479, PR #544
    local fx="${BATS_TEST_TMPDIR}/fx" hd='<<'
    mkdir -p "${fx}/.github"
    printf '%s\n' '#!/usr/bin/env bash' '# distcc-ng (https://github.com/wiki-mod/distcc-ng)' \
        '# SPDX-License-Identifier: GPL-2.0-or-later' '# shellcheck shell=bash' \
        '# What: Do a thing.' '# Why: A reason.' '# From: Issue #1' 'x=1' \
        "cat ${hd}'EOF'" '# a markdown heading' 'EOF' \
        "grep -q x ${hd}${hd:0:1} \"\${y}\"" '    # What: Indented.' '    # Why: Also fine.' 'y=2' \
        > "${fx}/.github/a.sh"
    run ci_guard_comment_format "${fx}"
    [ "${status}" -eq 0 ]
    printf '%s\n' '#!/usr/bin/env bash' '# ====' '# SECTION' '# ====' 'x=1' > "${fx}/.github/a.sh"
    run ci_guard_comment_format "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"a.sh:3: not a What/Why/From line"* ]]
}

@test "directive guard fails on each AG-INT-006 text" {
    # What: A shell file holding a banned text fails the guard.
    # Why: AG-INT-006: the mere presence is the violation.
    # From: Issue #479, PR #544, AG-INT-006
    local fx="${BATS_TEST_TMPDIR}/fx"
    local texts=()
    _ci_mapfile texts _ci_banned_shell_texts
    [ "${#texts[@]}" -eq 2 ]
    mkdir -p "${fx}/packaging"
    printf '%s\n' '#!/sbin/openrc-run' "# ${texts[0]}fickdiehenne" "echo '${texts[1]}'" \
        > "${fx}/packaging/svc.initd"
    run ci_guard_shellcheck_directives "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"svc.initd:2: AG-INT-006 text ${texts[0]}"* ]]
    [[ "${output}" == *"svc.initd:3: AG-INT-006 text ${texts[1]}"* ]]
}

@test "directive guard passes a shell tree without banned text" {
    # What: A source= naming a real file is no banned text.
    # Why: Only the AG-INT-006 texts fail; source= stays usable.
    # From: Issue #479, PR #544, AG-INT-006
    local fx="${BATS_TEST_TMPDIR}/fx"
    mkdir -p "${fx}/lib" "${fx}/.github"
    printf '%s\n' '#!/usr/bin/env bash' 'y=1' > "${fx}/lib/real.sh"
    printf '%s\n' '#!/usr/bin/env bash' '# shellcheck source=lib/real.sh' '. lib/real.sh' \
        > "${fx}/.github/a.sh"
    run ci_guard_shellcheck_directives "${fx}"
    [ "${status}" -eq 0 ]
}

@test "the real lint entry fails on an AG-INT-006 text" {
    # What: ci_cmd_lint fails when one shell file has the text.
    # Why: The guard is only proof if the lint entry runs it.
    # From: Issue #479, PR #544, AG-INT-006
    local fx="${BATS_TEST_TMPDIR}/fx"
    local texts=()
    _ci_mapfile texts _ci_banned_shell_texts
    mkdir -p "${fx}/contrib"
    cp "${CI_REPO_ROOT}/AGENTS.md" "${fx}/AGENTS.md"
    printf '%s\n' '#!/bin/sh' 'x=1' > "${fx}/contrib/tool"
    # What: Stub every other lint step as passing.
    # Why: Only the directive guard may fail the lint entry.
    _ok() { return 0; }
    ci_guard_line_endings() { _ok; }; ci_guard_full_sha() { _ok; }; ci_guard_pins_in_sot() { _ok; }
    ci_guard_sot_mirrors() { _ok; }; ci_guard_orchestrator_only() { _ok; }; ci_guard_comment_format() { _ok; }
    _ci_lint_actionlint() { _ok; }; _ci_lint_shellcheck() { _ok; }
    CI_REPO_ROOT="${fx}" run ci_cmd_lint
    [ "${status}" -eq 0 ]
    printf '%s\n' '#!/bin/sh' "# ${texts[0]}SC2086" 'x=1' > "${fx}/contrib/tool"
    CI_REPO_ROOT="${fx}" run ci_cmd_lint
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"contrib/tool:2: AG-INT-006 text"* ]]
}

@test "banned texts fail closed without a readable AG-INT-006" {
    # What: A missing rule is an error, never an empty ban list.
    # Why: An empty list would pass every shell file silently.
    # From: Issue #479, PR #544, AG-INT-006
    local fx="${BATS_TEST_TMPDIR}/fx"
    mkdir -p "${fx}"
    printf '%s\n' '# rules' > "${fx}/AGENTS.md"
    CI_REPO_ROOT="${fx}" run _ci_banned_shell_texts
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GUARD-SHELLCHECK-0002"* ]]
    CI_REPO_ROOT="${fx}" run ci_guard_shellcheck_directives "${fx}"
    [ "${status}" -eq 2 ]
}

@test "comment guard fails closed on a heredoc that never ends" {
    # What: An unterminated heredoc is reported, not skipped.
    # Why: Skipping to EOF would hide every later comment.
    # From: Issue #479, PR #544
    local fx="${BATS_TEST_TMPDIR}/fx" hd='<<'
    mkdir -p "${fx}/.github"
    printf '%s\n' "cat ${hd}EOF" 'text' '# free prose after' > "${fx}/.github/b.sh"
    run ci_guard_comment_format "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"b.sh:1: heredoc EOF never ends"* ]]
}

@test "comment guard fails closed on prose, a missing Why, a long line" {
    # What: Free prose, What without Why and >60 chars all fail.
    # Why: AG-CODE-001 allows only the What/Why/From form.
    # From: Issue #479, PR #544
    local fx="${BATS_TEST_TMPDIR}/fx"
    mkdir -p "${fx}/.github/workflows"
    printf '%s\n' '# Some free prose.' 'a: 1' '# What: Only a what.' 'b: 2' \
        "# What: $(printf 'x%.0s' {1..60})" '# Why: ok' 'c: 3' > "${fx}/.github/workflows/w.yml"
    run ci_guard_comment_format "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"w.yml:1: not a What/Why/From line"* ]]
    [[ "${output}" == *"w.yml:3: block needs one What, one Why"* ]]
    [[ "${output}" == *"w.yml:5: longer than 60 characters"* ]]
}

@test "orchestrator guard passes on a single-command run: step" {
    # What: `run: bash ci.sh <phase>` is a compliant step.
    # Why: Proves the green path; one command is allowed.
    # From: Issue #479
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"
    printf 'jobs:\n  x:\n    steps:\n      - run: bash .github/scripts/ci.sh build\n' > "${fx}/wf.yml"
    run ci_guard_orchestrator_only "${fx}/wf.yml"
    [ "${status}" -eq 0 ]
}

@test "orchestrator guard fails closed on inline logic in a run: block" {
    # What: A run: block with shell control flow must be rejected.
    # Why: #479 bans inline logic; it belongs in ci.sh.
    # From: Issue #479
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"
    printf 'jobs:\n  x:\n    steps:\n      - run: |\n          if [ -x foo ]; then bar; fi\n' > "${fx}/wf.yml"
    run ci_guard_orchestrator_only "${fx}/wf.yml"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-ORCH-0001"* ]]
}

@test "orchestrator guard passes a SOT action fed by step outputs" {
    # What: An exact SOT pin whose inputs forward outputs passes.
    # Why: Transport-only actions are the one allowed uses: form.
    # From: Issue #479, PR #544
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"
    _fixture_actions
    printf '%s\n' 'jobs:' '  x:' '    steps:' '      - run: |' '          bash .github/scripts/ci.sh cache default' \
        "      - if: steps.c.outputs.key != ''" "        uses: ${FX_PIN}" '        with:' \
        '          path: ${{ steps.c.outputs.path }}' '          restore-keys: ${{ steps.c.outputs.restore_keys }}' \
        '        env:' '          A: b' '      - run: bash .github/scripts/ci.sh build' > "${fx}/wf.yml"
    run ci_guard_orchestrator_only "${fx}/wf.yml"
    [ "${status}" -eq 0 ]
}

@test "orchestrator guard fails closed on a uses: outside the SOT" {
    # What: Local, tag-ref and wrong-SHA uses: lines all fail.
    # Why: Only the exact SOT literal may run an action.
    # From: Issue #479, PR #544
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"
    _fixture_actions
    printf '%s\n' 'jobs:' '  x:' '    steps:' '      - uses: ./.github/actions/foo' '      - uses: o/a@v1' \
        "      - uses: o/a@$(printf 'b%.0s' {1..40}) # v1" > "${fx}/wf.yml"
    run ci_guard_orchestrator_only "${fx}/wf.yml"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"wf.yml:4: uses: ./.github/actions/foo is not an SOT action pin"* ]]
    [[ "${output}" == *"wf.yml:5: uses: o/a@v1 is not an SOT action pin"* ]]
    [[ "${output}" == *"wf.yml:6: uses: o/a@bbbb"* ]]
}

@test "orchestrator guard fails closed on a decided uses: input" {
    # What: A literal or computed with: input is rejected.
    # Why: Keys, paths and names are ci.sh decisions, not YAML.
    # From: Issue #479, PR #544
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"
    _fixture_actions
    printf '%s\n' 'jobs:' '  x:' '    steps:' "      - uses: ${FX_PIN}" '        with:' '          path: ~/.ccache' \
        "          key: ccache-\${{ github.run_id }}" > "${fx}/wf.yml"
    run ci_guard_orchestrator_only "${fx}/wf.yml"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"wf.yml:6: uses: input is not a ci.sh step output: ~/.ccache"* ]]
    [[ "${output}" == *"wf.yml:7: uses: input is not a ci.sh step output"* ]]
}

# What: docker stub that records its argv, one arg per line.
# Why: Owner tests assert the exact flags, not a real daemon.
# From: Issue #479, PR #544
_capture_docker() {
    # What: Record each docker argument on its own line.
    # Why: Owner tests assert flags, not a real daemon.
    docker() { printf '%s\n' "$@" >> "${BATS_TEST_TMPDIR}/argv"; }
}

@test "image build passes SOT ARGs, explicit target and local tag" {
    # What: A local spec builds its file and target, SOT ARGs.
    # Why: The only path a base-image pin may take into a build.
    # From: Issue #359, Issue #479, PR #544
    local d; d="$(printf 'a%.0s' {1..64})"
    _fixture_manifest 'base:' "  img: \"b@sha256:${d}\"" 's:' '  x:' '    dockerfile: "d/Dockerfile"' \
        '    target: "t"' '    args: ["A=base.img"]' '    tag: "x:local"'
    _capture_docker
    run _ci_image_build s.x "" --pull
    [ "${status}" -eq 0 ]
    [ "$(tr '\n' ' ' < "${BATS_TEST_TMPDIR}/argv")" = "build --pull --file ${CI_REPO_ROOT}/d/Dockerfile --target t --build-arg A=b@sha256:${d} --tag x:local ${CI_REPO_ROOT} " ]
}

@test "image build labels a published spec and needs its version" {
    # What: A spec with a description gets 7 OCI labels.
    # Why: One OCI metadata owner; Dockerfiles carry no LABEL.
    # From: Issue #359, Issue #479, PR #544
    _fixture_manifest 'base:' '  img: "b"' 'release:' '  licenses: "L"' '  images:' '    pkg:' \
        '      dockerfile: "f"' '      target: "t"' '      args: ["A=base.img"]' '      description: "D"'
    _capture_docker
    GITHUB_SERVER_URL=https://h GITHUB_REPOSITORY=o/r BUILT_SHA=abc run _ci_image_build release.images.pkg ""
    [ "${status}" -ne 0 ]
    [ ! -f "${BATS_TEST_TMPDIR}/argv" ]
    GITHUB_SERVER_URL=https://h GITHUB_REPOSITORY=o/r BUILT_SHA=abc run _ci_image_build release.images.pkg 1.0
    [ "${status}" -eq 0 ]
    [ "$(grep -c '^org.opencontainers.image' "${BATS_TEST_TMPDIR}/argv")" -eq 7 ]
    grep -qx 'org.opencontainers.image.title=pkg' "${BATS_TEST_TMPDIR}/argv"
    grep -qx 'org.opencontainers.image.version=1.0' "${BATS_TEST_TMPDIR}/argv"
    grep -qx 'org.opencontainers.image.revision=abc' "${BATS_TEST_TMPDIR}/argv"
}

@test "image build fails closed on a bad spec before docker runs" {
    # What: A missing spec or a non ARG=path entry stops it.
    # Why: An unpinned ARG would build FROM an empty base.
    # From: Issue #479, PR #544
    _fixture_manifest 's:' '  x:' '    dockerfile: "f"' '    target: "t"' '    args: ["NOEQUALS"]'
    _forbid docker
    run _ci_image_build s.x ""
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-IMAGE-0002"* ]]
    run _ci_image_build s.nope ""
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SOT-0002"* ]]
    [[ "${output}" != *"must not run"* ]]
}

@test "container run: --init and a read-only checkout, --rm alone" {
    # What: Every run gets --init and the checkout at /ci:ro.
    # Why: --init reaps zombies; a missing one hung earlier runs.
    # From: Issue #479, PR #544
    _capture_docker
    run _ci_container_run img -e K=V -- bash x
    [ "${status}" -eq 0 ]
    [ "$(tr '\n' ' ' < "${BATS_TEST_TMPDIR}/argv")" = "run --init -v ${CI_REPO_ROOT}:/ci:ro --rm -e K=V img bash x " ]
}

@test "container run: inside a stack it joins net and label, no --rm" {
    # What: A stack member is labelled; teardown removes it.
    # Why: --rm would drop a crashed server's log too early.
    # From: Issue #479, PR #544
    _capture_docker
    CI_STACK=n1 run _ci_container_run img -d --
    [ "${status}" -eq 0 ]
    [ "$(tr '\n' ' ' < "${BATS_TEST_TMPDIR}/argv")" = "run --init -v ${CI_REPO_ROOT}:/ci:ro --network n1 --label ci-stack=n1 -d img " ]
}

@test "container run fails closed without -- before the command" {
    # What: Options and command must be split by an explicit --.
    # Why: A guessed split could run an option as the image.
    # From: Issue #479, PR #544
    _forbid docker
    run _ci_container_run img -e K=V
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CONTAINER-0003"* ]]
    [[ "${output}" != *"must not run"* ]]
}

@test "registry push never pushes after a failed login" {
    # What: No token means no login and no push at all.
    # Why: An anonymous or stale-credential push must not happen.
    # From: Issue #479, PR #544
    _forbid docker
    unset REGISTRY_TOKEN
    GITHUB_ACTOR=octo run _ci_registry_push some/image:tag
    [ "${status}" -ne 0 ]
    [[ "${output}" != *"must not run"* ]]
}

@test "wait-until retries a probe and fails after N tries" {
    # What: Success on a later try passes; N failures fail.
    # Why: One bounded poll owner for every readiness wait.
    # From: Issue #479, PR #544

    _no_sleep
    # What: Probe that succeeds on its third call.
    # Why: Proves wait-until retries, then stops.
    _probe() { echo x >> "${BATS_TEST_TMPDIR}/tries"; [ "$(wc -l < "${BATS_TEST_TMPDIR}/tries")" -ge 3 ]; }
    run _ci_wait_until 5 1 _probe
    [ "${status}" -eq 0 ]
    [ "$(wc -l < "${BATS_TEST_TMPDIR}/tries")" -eq 3 ]
    run _ci_wait_until 2 1 false
    [ "${status}" -eq 1 ]
}

@test "wait-until stops at once on a probe error and names tries" {
    # What: rc >= 2 aborts; the probe sees CI_ATTEMPT/CI_TRIES.
    # Why: A hard error must never be retried as transient.
    # From: Issue #479, PR #544

    _no_sleep
    # What: Probe that logs its attempt, then fails hard.
    # Why: Proves a single call and the attempt counters.
    _probe() { echo "${CI_ATTEMPT}/${CI_TRIES}" >> "${BATS_TEST_TMPDIR}/tries"; return 5; }
    run _ci_wait_until 4 1 _probe
    [ "${status}" -eq 5 ]
    [ "$(cat "${BATS_TEST_TMPDIR}/tries")" = "1/4" ]
}

@test "expect-output checks presence, and absence with !re" {
    # What: A fixture's output is the proof, not its exit code.
    # Why: Fixtures exit non-zero; a negated check can fail too.
    # From: Issue #264, Issue #479, PR #544
    run _ci_expect_output t 'needle' bash -c 'echo needle; exit 3'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"t: OK (exit 3)"* ]]
    run _ci_expect_output t '!needle' echo needle
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-SELFTEST-0001"* ]]
    run _ci_expect_output t '!needle' echo hay
    [ "${status}" -eq 0 ]
}

# What: curl stub that copies fixture file $1 to every -o.
# Why: Fetch tests need a deterministic, offline download.
# From: Issue #479, PR #544
_fake_curl() {
    FAKE_DOWNLOAD="$1"
    # What: Stub curl to copy FAKE_DOWNLOAD to its -o file.
    # Why: Downloads stay offline and deterministic.
    curl() { while [ "$#" -gt 0 ]; do if [ "$1" = "-o" ]; then cp "${FAKE_DOWNLOAD}" "$2"; fi; shift; done; }
}

@test "a failed download names its URL and fails" {
    # What: curl's failure surfaces as FETCH-0003 with the URL.
    # Why: A failed fetch must never fail without an error line.
    # From: Issue #479, PR #544

    # What: Stub curl as an HTTP failure (rc 22).
    # Why: A failed fetch must name its URL and fail.
    curl() { return 22; }
    _no_sleep
    run _ci_download "https://h/x.tar.gz" "${BATS_TEST_TMPDIR}/x"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"attempt 3/3 failed"* ]]
    [[ "${output}" == *"CI-ERROR-FETCH-0003"*"https://h/x.tar.gz"* ]]
}

@test "a dropped connection is retried by a later attempt" {
    # What: A first failing curl, then a good one, succeeds.
    # Why: curl --retry does not retry a dropped connection.
    # From: Issue #479, PR #544
    local n="${BATS_TEST_TMPDIR}/n"
    echo 0 > "${n}"
    # What: Stub curl: the first call fails, later ones pass.
    # Why: Proves a later attempt recovers the fetch.
    curl() { local c; c="$(cat "${n}")"; echo $((c + 1)) > "${n}"; [ "${c}" -ge 1 ]; }
    _no_sleep
    run _ci_download "https://h/x.tar.gz" "${BATS_TEST_TMPDIR}/x"
    [ "${status}" -eq 0 ]
    [ "$(cat "${n}")" -eq 2 ]
    [[ "${output}" == *"attempt 1/3 failed"* ]]
}

@test "tool fetch expands the url and extracts on a matching sha256" {
    # What: A matching checksum extracts; bin names the binary.
    # Why: Green path of the one SOT-driven tool downloader.
    # From: Issue #479, PR #544
    local src="${BATS_TEST_TMPDIR}/src" sum
    mkdir -p "${src}/d"; printf 'bin' > "${src}/d/tool"
    tar -czf "${BATS_TEST_TMPDIR}/t.tar.gz" -C "${src}" d
    sum="$(sha256sum "${BATS_TEST_TMPDIR}/t.tar.gz" | cut -d' ' -f1)"
    _fixture_manifest 'x:' '  tool:' '    version: "v1.2"' '    url: "https://h/{version}/t_{bare}.tgz"' \
        "    sha256: \"${sum}\"" '    bin: "d/tool"'
    [ "$(_ci_tool_url x.tool v1.2)" = "https://h/v1.2/t_1.2.tgz" ]
    _fake_curl "${BATS_TEST_TMPDIR}/t.tar.gz"
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _ci_tool_bin x.tool
    [ "${status}" -eq 0 ]
    [ "$(cat "${output}")" = "bin" ]
    [ -x "${output}" ]
}

@test "tool fetch keeps a bare binary under its bin name" {
    # What: archive binary stores the download as the bin file.
    # Why: Some upstreams ship no archive, only the executable.
    # From: Issue #479, PR #544
    local sum
    printf 'exe' > "${BATS_TEST_TMPDIR}/raw"
    sum="$(sha256sum "${BATS_TEST_TMPDIR}/raw" | cut -d' ' -f1)"
    _fixture_manifest 'x:' '  osv:' '    version: "v2"' '    url: "https://h/osv"' \
        "    sha256: \"${sum}\"" '    archive: "binary"' '    bin: "osv-scanner"'
    _fake_curl "${BATS_TEST_TMPDIR}/raw"
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _ci_tool_bin x.osv
    [ "${status}" -eq 0 ]
    [ "$(cat "${output}")" = "exe" ]
}

@test "tool fetch fails closed on a sha256 mismatch or no pin" {
    # What: A wrong or missing checksum never yields a binary.
    # Why: A tampered or unpinned binary must never run.
    # From: Issue #479, PR #544
    printf 'evil' > "${BATS_TEST_TMPDIR}/evil"
    _fixture_manifest 'x:' '  tool:' '    version: "v1"' '    url: "https://h/t.tgz"' \
        "    sha256: \"$(printf '0%.0s' {1..64})\"" '    bin: "tool"' '  bare:' '    version: "v1"' \
        '    url: "https://h/t.tgz"' '    bin: "tool"'
    _fake_curl "${BATS_TEST_TMPDIR}/evil"
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _ci_tool_bin x.tool
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-FETCH-0001"* ]]
    [ ! -f "${BATS_TEST_TMPDIR}/tool-v1/.complete" ]
    _forbid curl
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _ci_tool_bin x.bare
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SOT-0002"* ]]
    [[ "${output}" != *"must not run"* ]]
}

# What: gh and docker stubs for the SOT refresh tests.
# Why: Release lists and registry digests must be offline.
# From: Issue #479, PR #544
_fake_registry() {
    # What: Stub docker to return a fixed 64-hex digest.
    # Why: Registry digests must stay offline.
    docker() { printf '{"digest":"sha256:%s"}\n' "$(printf 'b%.0s' {1..64})"; }
    # What: Stub gh release lists and one asset digest.
    # Why: Any other gh call is a test failure.
    gh() {
        case "$*" in
            *"releases?per_page"*) printf '%s\n' v1.9.9 v1.10.0 v1.2.0 ;;
            *"releases/tags/v1.10.0"*) printf '{"assets":[{"name":"t_1.10.0.tgz","digest":"sha256:%s"}]}\n' "$(printf 'c%.0s' {1..64})" ;;
            *) echo "gh $* must not run"; return 99 ;;
        esac
    }
}

@test "sot refresh moves digests and tool versions, one row each" {
    # What: New digest and newest stable version land in the SOT.
    # Why: ci.sh is the sole pin owner; sort -V beats backports.
    # From: Issue #479, PR #544
    local a b c
    a="$(printf 'a%.0s' {1..64})"; b="$(printf 'b%.0s' {1..64})"; c="$(printf 'c%.0s' {1..64})"
    _fixture_manifest 'base_images:' "  deb: \"debian:trixie@sha256:${a}\"" 'external_services:' \
        "  red: \"redis:8@sha256:${b}\"" 'external_versions:' '  t:' '    version: "v1.9.9"' \
        '    source: "o/t"' '    url: "https://github.com/o/t/releases/download/{version}/t_{bare}.tgz"' \
        "    sha256: \"${a}\"" '  manual:' '    version: "1"'
    _fake_registry
    run _ci_sot_refresh
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "$(_ci_sot_scalar base_images.deb)" = "debian:trixie@sha256:${b}" ]
    [ "$(_ci_sot_scalar external_services.red)" = "redis:8@sha256:${b}" ]
    [ "$(_ci_sot_scalar external_versions.t.version)" = "v1.10.0" ]
    [ "$(_ci_sot_scalar external_versions.t.sha256)" = "${c}" ]
    [ "$(_ci_sot_scalar external_versions.manual.version)" = "1" ]
}

@test "sot refresh fails closed on an image pin without a tag" {
    # What: name@sha256 with no tag has no channel to follow.
    # Why: Refreshing it would silently track latest.
    # From: Issue #479, PR #544
    _fixture_manifest 'base_images:' "  deb: \"debian@sha256:$(printf 'a%.0s' {1..64})\"" 'external_services:' \
        '  none: "x:1@sha256:0"' 'external_versions:' '  m:' '    version: "1"'
    _fake_registry
    run _ci_sot_refresh
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SOT-0004"* ]]
}

# What: Stubs for the OSV gate: scanner, fetch, base SOT, ids.
# Why: The gate logic must be provable without network.
# From: Issue #267, Issue #479, PR #544
_fake_osv() {
    OSV_BASE_SOT="$1"
    # What: Stub the scanner binary as /bin/true.
    # Why: The gate test needs no real OSV scanner.
    _ci_tool_bin() { echo /bin/true; }
    # What: Stub the scanned tool dirs as the temp dir.
    # Why: No tool is fetched in the gate test.
    _ci_osv_tool_dirs() { echo "${BATS_TEST_TMPDIR}"; }
    # What: Stub the OSV run as a no-op.
    # Why: Vulnerability ids come from the stub below.
    _ci_osv_run() { :; }
    # What: Stub the PR range as abc..def.
    # Why: The gate reads the base SOT at the base.
    _ci_event_range() { printf '%s\n' abc def; }
    # What: Stub git: the base has a SOT; show prints it.
    # Why: The base side must use OSV_BASE_SOT.
    git() {
        case "$*" in
            *" ls-tree "*) [ -n "${OSV_GIT_FAIL:-}" ] && return 128; printf '%s\n' .github/yaml/build-manifest.yml ;;
            *" show "*) printf '%s\n' "${OSV_BASE_SOT}" ;;
        esac
    }
    # What: Stub ids: head SOT and base SOT sets.
    # Why: The gate must fail only on head-added ids.
    _ci_osv_vulns() { if [ "$2" = "${CI_MANIFEST}" ]; then printf '%s\n' ${OSV_HEAD_IDS}; else printf '%s\n' ${OSV_BASE_IDS}; fi; }
}

@test "OSV PR gate fails only on ids the head's tools add" {
    # What: A new vuln id in the head fails; a removed one not.
    # Why: Legacy's PR scan blocked newly vulnerable dependencies.
    # From: Issue #267, Issue #479, PR #544
    _fake_osv '    bin: "x"'
    OSV_BASE_IDS="GO-1 GO-2" OSV_HEAD_IDS="GO-1 GO-3" GITHUB_EVENT_NAME=pull_request run ci_cmd_osv_scan out.sarif
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0003"* ]]
    [[ "${output}" == *"GO-3"* ]]
    [[ "${output}" != *"GO-2"* ]]
    OSV_BASE_IDS="GO-1 GO-2" OSV_HEAD_IDS="GO-1" GITHUB_EVENT_NAME=pull_request run ci_cmd_osv_scan out.sarif
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"no new vulnerability"* ]]
}

@test "SARIF upload sends the gzip+base64 file in the request body" {
    # What: The SARIF travels in --input, decodable to the file.
    # Why: A 350-result SARIF in argv failed with E2BIG.
    # From: Issue #479, PR #544
    local big="${BATS_TEST_TMPDIR}/big.sarif"
    head -c 3000000 /dev/urandom | base64 > "${big}"
    # What: Stub gh: decode the --input body, echo an id.
    # Why: Proves the SARIF travels in the body file.
    gh() {
        local in=""
        while [ "$#" -gt 0 ]; do [ "$1" = "--input" ] && in="$2"; shift; done
        jq -r .sarif "${in}" | base64 -d | gunzip > "${BATS_TEST_TMPDIR}/back"
        jq '{id: (.commit_sha + " " + .ref)}' "${in}"
    }
    GH_TOKEN=x GITHUB_REPOSITORY=o/r GITHUB_SHA=abc GITHUB_REF=refs/heads/x run ci_cmd_sarif_upload "${big}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"SARIF upload id abc refs/heads/x"* ]]
    cmp "${big}" "${BATS_TEST_TMPDIR}/back"
}

@test "SARIF upload retries a 5xx or empty answer, never a 4xx" {
    # What: 5xx/empty retry up to three times; 4xx fails at once.
    # Why: A transient API error must not fail a scan job.
    # From: Issue #479, PR #544
    local n="${BATS_TEST_TMPDIR}/n" f="${BATS_TEST_TMPDIR}/s.sarif"
    echo '{}' > "${f}"
    _no_sleep
    echo 0 > "${n}"
    # What: Stub gh: a 502, then empty, then an id.
    # Why: Both transient answers must be retried.
    gh() { local c; c="$(cat "${n}")"; echo $((c + 1)) > "${n}"
        case "${c}" in 0) echo "gh: Server Error (HTTP 502)" >&2; return 1 ;; 1) return 0 ;; *) echo '{"id":"ok"}' ;; esac; }
    GH_TOKEN=x GITHUB_REPOSITORY=o/r GITHUB_SHA=a GITHUB_REF=r run ci_cmd_sarif_upload "${f}"
    [ "${status}" -eq 0 ]
    [ "$(cat "${n}")" -eq 3 ]
    [[ "${output}" == *"attempt 1/3 failed: gh: Server Error (HTTP 502)"* ]]
    [[ "${output}" == *"attempt 2/3 failed: empty response"* ]]
    echo 0 > "${n}"
    # What: Stub gh as HTTP 404, counting calls.
    # Why: A 4xx must fail at once, never retry.
    gh() { echo $(( $(cat "${n}") + 1 )) > "${n}"; echo "gh: Not Found (HTTP 404)" >&2; return 1; }
    GH_TOKEN=x GITHUB_REPOSITORY=o/r GITHUB_SHA=a GITHUB_REF=r run ci_cmd_sarif_upload "${f}"
    [ "${status}" -eq 1 ]
    [ "$(cat "${n}")" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0004"*"HTTP 404"* ]]
}

@test "OSV PR gate is NotRun against a base SOT without tool pins" {
    # What: A base predating tool pins has nothing to compare.
    # Why: Its tools cannot be fetched; reading 0 would fail all.
    # From: Issue #267, Issue #479, PR #544
    _fake_osv '    version: "v1"'
    OSV_BASE_IDS="" OSV_HEAD_IDS="GO-1" GITHUB_EVENT_NAME=pull_request run ci_cmd_osv_scan out.sarif
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"OSV PR gate NotRun"* ]]
    OSV_GIT_FAIL=1 OSV_BASE_IDS="" OSV_HEAD_IDS="GO-1" GITHUB_EVENT_NAME=pull_request run ci_cmd_osv_scan out.sarif
    [ "${status}" -eq 1 ]
    [[ "${output}" != *"NotRun"* ]]
}

@test "OSV run keeps findings 1-126 and fails on a scanner error" {
    # What: rc 1-126 means findings; rc 127 and above is an error.
    # Why: osv-scanner v2.6.0 docs/output.md:796-798 say so.
    # From: Issue #267, Issue #479, PR #544
    local bin="${BATS_TEST_TMPDIR}/osv"
    printf '%s\n' '#!/bin/sh' 'exit "${OSV_RC}"' > "${bin}"
    chmod +x "${bin}"
    OSV_RC=1 run _ci_osv_run "${bin}" sarif "${BATS_TEST_TMPDIR}/o" "${BATS_TEST_TMPDIR}"
    [ "${status}" -eq 0 ]
    OSV_RC=127 run _ci_osv_run "${bin}" sarif "${BATS_TEST_TMPDIR}/o" "${BATS_TEST_TMPDIR}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0002"*"exit=127"* ]]
    OSV_RC=128 run _ci_osv_run "${bin}" sarif "${BATS_TEST_TMPDIR}/o" "${BATS_TEST_TMPDIR}"
    [ "${status}" -eq 2 ]
}

@test "attest predicate has the actions/attest SLSA v1 shape" {
    # What: Claims map to buildType, workflow path, builder, run.
    # Why: gh attestation verify expects that exact provenance.
    # From: Issue #38, Issue #479, PR #544

    # What: Stub the OIDC claims of a push run.
    # Why: The predicate shape is checked offline.
    _ci_attest_claims() {
        printf '%s' '{"ref":"refs/heads/x","sha":"abc","repository":"o/r","event_name":"push",
            "workflow_ref":"o/r/.github/workflows/v.yml@refs/heads/x",
            "job_workflow_ref":"o/r/.github/workflows/v.yml@refs/heads/x","repository_id":"1",
            "repository_owner_id":"2","runner_environment":"github-hosted","run_id":"9","run_attempt":"1"}'
    }
    GITHUB_SERVER_URL=https://github.com run _ci_attest_predicate
    [ "${status}" -eq 0 ]
    [ "$(jq -r .buildDefinition.buildType <<< "${output}")" = "https://actions.github.io/buildtypes/workflow/v1" ]
    [ "$(jq -r .buildDefinition.externalParameters.workflow.path <<< "${output}")" = ".github/workflows/v.yml" ]
    [ "$(jq -r .runDetails.builder.id <<< "${output}")" = "https://github.com/o/r/.github/workflows/v.yml@refs/heads/x" ]
    [ "$(jq -r .runDetails.metadata.invocationId <<< "${output}")" = "https://github.com/o/r/actions/runs/9/attempts/1" ]
    [ "$(jq -r '.buildDefinition.resolvedDependencies[0].digest.gitCommit' <<< "${output}")" = "abc" ]
}

@test "attest builds one in-toto statement over all subjects" {
    # What: Every file is a sha256 subject of one SLSA statement.
    # Why: One signature covers the whole shipped asset set.
    # From: Issue #38, Issue #479, PR #544
    printf 'a' > "${BATS_TEST_TMPDIR}/f1"; printf 'b' > "${BATS_TEST_TMPDIR}/f2"
    # What: Stub cosign as /bin/true.
    # Why: The statement test needs no real signer.
    _ci_tool_bin() { echo /bin/true; }
    # What: Stub the SLSA predicate as a fixed object.
    # Why: The test checks subjects, not the predicate.
    _ci_attest_predicate() { echo '{"p":1}'; }
    # What: Stub publish to keep the statement it gets.
    # Why: The test reads back the built statement.
    _ci_attest_publish() { cat "$2/statement.json" > "${BATS_TEST_TMPDIR}/stmt"; }
    GITHUB_REPOSITORY=o/r GH_TOKEN=x run _ci_attest_subjects \
        "$(_ci_attest_file_subjects "${BATS_TEST_TMPDIR}/f1" "${BATS_TEST_TMPDIR}/f2")" f1
    [ "${status}" -eq 0 ]
    [ "$(jq -r .predicateType "${BATS_TEST_TMPDIR}/stmt")" = "https://slsa.dev/provenance/v1" ]
    [ "$(jq -r '.subject | map(.name) | join(",")' "${BATS_TEST_TMPDIR}/stmt")" = "f1,f2" ]
    [ "$(jq -r '.subject[0].digest.sha256' "${BATS_TEST_TMPDIR}/stmt")" = "$(sha256sum "${BATS_TEST_TMPDIR}/f1" | cut -d' ' -f1)" ]
    [ "$(jq -c .predicate "${BATS_TEST_TMPDIR}/stmt")" = '{"p":1}' ]
}

@test "attest: build without OIDC is NotRun, a bad target fails" {
    # What: A fork-PR build logs NotRun; unknown targets fail.
    # Why: Fork PRs never get an id-token; releases always do.
    # From: Issue #38, Issue #479, PR #544
    _forbid curl gh
    unset ACTIONS_ID_TOKEN_REQUEST_URL
    RUNNER_OS=Linux run ci_cmd_attest build default
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"build attestation NotRun: no id-token"* ]]
    ACTIONS_ID_TOKEN_REQUEST_URL=x RUNNER_OS=macOS run ci_cmd_attest build default
    [[ "${output}" == *"not the default Linux build"* ]]
    ACTIONS_ID_TOKEN_REQUEST_URL=x RUNNER_OS=Linux run ci_cmd_attest build coverage
    [[ "${output}" == *"not the default Linux build"* ]]
    run ci_cmd_attest bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-ATTEST-0001"* ]]
    [[ "${output}" != *"must not run"* ]]
}

@test "sot-update with current pins touches neither git nor PRs" {
    # What: Nothing changed means no branch, PR or dispatch.
    # Why: A weekly no-op must not create noise on the repo.
    # From: Issue #479, PR #544
    local b; b="$(printf 'b%.0s' {1..64})"
    _fixture_manifest 'base_images:' "  deb: \"debian:trixie@sha256:${b}\"" 'external_services:' \
        "  red: \"redis:8@sha256:${b}\"" 'external_versions:' '  m:' '    version: "1"'
    _fake_registry
    _forbid git
    GH_TOKEN=x GITHUB_REPOSITORY=o/r run ci_cmd_sot_update
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"every SOT pin is current"* ]]
    [[ "${output}" != *"must not run"* ]]
}

@test "harden rejects an unknown subcommand" {
    # What: harden only knows start|stop.
    # Why: Fail-closed dispatch for every phase.
    # From: Issue #479, PR #544
    run ci_cmd_harden bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-HARDEN-0001"* ]]
}

@test "harden start is NotRun on an ARM64 runner" {
    # What: arm64 logs NotRun and touches neither net nor sudo.
    # Why: The non-TLS agent ships for x64 only.
    # From: Issue #479, PR #544
    _forbid curl sudo
    RUNNER_OS=Linux RUNNER_ARCH=ARM64 RUNNER_ENVIRONMENT=github-hosted run _ci_harden_start
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"NotRun: agent unsupported on RUNNER_ARCH=ARM64"* ]]
    [[ "${output}" != *"must not run"* ]]
}

@test "harden stop is NotRun when no agent was started" {
    # What: No state file means nothing to stop.
    # Why: Stop runs under if: always(), also after skips.
    # From: Issue #479, PR #544
    _CI_HARDEN_DIR="${BATS_TEST_TMPDIR}/agent"
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _ci_harden_stop
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"NotRun: no agent was started"* ]]
}

@test "harden stop fails closed when the agent never confirms" {
    # What: Missing done.json after the post event is a failure.
    # Why: Unflushed telemetry must not pass silently.
    # From: Issue #479, PR #544
    _fixture_harden_state
    _no_sleep
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _ci_harden_stop
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-HARDEN-0003"* ]]
    [ -f "${_CI_HARDEN_DIR}/post_event.json" ]
}

@test "harden stop passes once the agent wrote done.json" {
    # What: done.json after post_event.json ends the job cleanly.
    # Why: Green path of the post-step replacement.
    # From: Issue #479, PR #544
    _fixture_harden_state
    printf '{}' > "${_CI_HARDEN_DIR}/done.json"
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _ci_harden_stop
    [ "${status}" -eq 0 ]
    [ "$(cat "${_CI_HARDEN_DIR}/post_event.json")" = '{"event":"post"}' ]
}
