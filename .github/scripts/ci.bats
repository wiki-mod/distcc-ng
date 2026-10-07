#!/usr/bin/env bats
# distcc-ng (https://github.com/wiki-mod/distcc-ng)
# SPDX-License-Identifier: GPL-2.0-or-later
# What: Bats suite for ci.sh, its SOT and workflow wiring.
# Why: Issue #479 allows ci.bats as the only CI test file.
# From: Issue #479

# What: Source ci.sh functions without running dispatch.
# Why: ci.sh runs ci_main only when executed, not sourced.
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

# What: Make each named command a no-op that passes.
# Why: Isolates one step by passing every step around it.
# From: Issue #479, PR #544
_pass() {
    local c
    for c in "$@"; do
        eval "${c}() { return 0; }"
    done
}

# What: Make command $1 print the other args, one per line.
# Why: One commented owner for every fixed-output stub.
# From: Issue #479, PR #544
_print() {
    local c="$1"
    shift
    eval "${c}() { printf '%s\n' $(printf '%q ' "$@"); }"
}

# What: Apply the stub calls in $1, then run the rest of $@.
# Why: Under run, core-tool stubs stay out of bats cleanup.
# From: Issue #479, PR #544
_stubbed() {
    eval "$1"
    shift
    "$@"
}

# What: Make command $1 print $3 to stderr and return $2.
# Why: One commented owner for every failing-tool stub.
# From: Issue #479, PR #544
_fail() {
    local c="$1" rc="$2" msg
    msg="$(printf '%q' "${3:-}")"
    eval "${c}() { [ -z ${msg} ] || printf '%s\n' ${msg} >&2; return ${rc}; }"
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

# What: Runs ci.sh with a command no dispatch arm knows.
# Why: A mistyped workflow command must fail, not skip.
# From: Issue #479
@test "unknown subcommand fails closed with a stable id" {
    run bash "${BATS_TEST_DIRNAME}/ci.sh" bogus-command
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0002"* ]]
}

# What: Print each CI-ERROR id that occurs twice in file $1.
# Why: Triage greps an id to find the one place it is raised.
# From: Issue #479, PR #544
_dup_error_ids() {
    grep -oE 'CI-ERROR-[A-Z0-9-]+-[0-9]{4}' "$1" | sort | uniq -d
}

# What: Lists duplicate ids in ci.sh, then in a copy with one.
# Why: A shared id would point triage at the wrong failure.
# From: Issue #479, PR #544
@test "every CI-ERROR id in ci.sh is raised in one place" {
    local fx="${BATS_TEST_TMPDIR}/ci.sh"
    run _dup_error_ids "${CI_SH}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    cp "${CI_SH}" "${fx}"
    printf '%s\n' 'ci_log "[CI-ERROR-CORE-0002]" "again"' >> "${fx}"
    run _dup_error_ids "${fx}"
    [ "${output}" = "CI-ERROR-CORE-0002" ]
}

# What: Points CI_MANIFEST at a path that does not exist.
# Why: Without the SOT every pin and spec would read empty.
# From: Issue #479
@test "a missing manifest fails closed" {
    CI_MANIFEST="/nonexistent/build-manifest.yml" run ci_require_manifest
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0003"* ]]
}

# What: Reads a 2- and a 3-level path from a fixture SOT.
# Why: Every pin and spec is read through this one reader.
# From: Issue #479, PR #544
@test "sot scalar reads a scalar at any nesting depth" {
    _fixture_manifest 'a:' '  b: "x"' '  c:' '    d: "y:z@sha256:0"'
    [ "$(_ci_sot_scalar a.b)" = "x" ]
    [ "$(_ci_sot_scalar a.c.d)" = "y:z@sha256:0" ]
}

# What: Matches every base_images and external_services pin.
# Why: No tag, no refresh; no digest, a floating build.
# From: Issue #479, PR #544
@test "every SOT image pin is name:tag at a full sha256 digest" {
    local s k v
    for s in base_images external_services; do
        for k in $(_ci_sot_children "${s}"); do
            v="$(_ci_sot_scalar "${s}.${k}")"
            [[ "${v}" =~ ^[^@]+/?[^/@]*:[^/@]+@sha256:[0-9a-f]{64}$ ]] || { echo "${s}.${k}=${v}"; false; }
        done
    done
}

# What: Checks the sha256 of each SOT tool that has a url.
# Why: A url without sha256 would run an unverified binary.
# From: Issue #479, PR #544
@test "every SOT tool with a url carries a full sha256" {
    local k
    for k in $(_ci_sot_children external_versions); do
        [ -n "$(_ci_sot_optional "external_versions.${k}.url")" ] || continue
        [[ "$(_ci_sot_scalar "external_versions.${k}.sha256")" =~ ^[0-9a-f]{64}$ ]] || { echo "${k}"; false; }
    done
}

# What: Sets a.c.b beside same-named keys, then a bad path.
# Why: sot-update must never touch a neighbouring pin.
# From: Issue #479, PR #544
@test "sot set rewrites one path and fails closed on a missing one" {
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

# What: Sets a value with mv broken, then one on a 640 SOT.
# Why: A half-written SOT would corrupt every later read.
# From: Issue #479, PR #544
@test "sot set keeps the old SOT and its mode around the rename" {
    _fixture_manifest 'a:' '  b: "x"'
    chmod 640 "${CI_MANIFEST}"
    cp "${CI_MANIFEST}" "${BATS_TEST_TMPDIR}/before"
    run _stubbed '_fail mv 1 "mv broke"' _ci_sot_set a.b "new"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"mv broke"* ]]
    cmp "${CI_MANIFEST}" "${BATS_TEST_TMPDIR}/before"
    run _ci_sot_set a.nope "v"
    [ "${status}" -eq 2 ]
    _ci_sot_set a.b "new"
    [ "$(_ci_sot_scalar a.b)" = "new" ]
    [ "$(stat -c %a "${CI_MANIFEST}")" = "640" ]
    [ -z "$(find "${BATS_TEST_TMPDIR}" -name 'build-manifest.yml.*')" ]
}

# What: Reads a key the real SOT does not have.
# Why: An empty string would pass on as a valid pin.
# From: Issue #479, PR #544
@test "sot scalar fails closed on a missing key" {
    run _ci_sot_scalar external_versions.nope.version
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SOT-0002"* ]]
}

# What: Reads the default variant's absent opt_in key.
# Why: Only _ci_sot_optional may turn absence into empty.
# From: Issue #479, PR #544
@test "sot optional reads absent keys as empty" {
    run _ci_sot_optional build_matrix.variants.default.opt_in
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

# What: Lists children of a build_matrix key that is absent.
# Why: It would silently empty the build matrix.
# From: Issue #479, PR #544
@test "sot children fails closed on a missing section" {
    run _ci_sot_children build_matrix.nope
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SOT-0002"* ]]
}

# What: Lists v in a fixture with nested keys and a sibling.
# Why: Drift here silently drops or adds a variant or image.
# From: Issue #479, PR #544
@test "sot children lists only the direct child keys" {
    _fixture_manifest 'v:' '  one:' '    k: 1' '  two:' '    k: 2' 'other: 1'
    run _ci_sot_children v
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "one" ]
    [ "${lines[1]}" = "two" ]
}

# What: Drives value, children and set modes on one fixture.
# Why: Readers and the writer must never disagree on a path.
# From: Issue #479, PR #544
@test "sot walker: one path rule for value, children and set" {
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

# What: Reads _ci_jobs on the machine running the suite.
# Why: Serial runs are forbidden; the floor is a guard.
# From: Issue #479
@test "job count never drops below the floor of 16" {
    run _ci_jobs
    [ "${status}" -eq 0 ]
    [ "${output}" -ge 16 ]
}

# What: Maps a half-failed, a clean and an empty command.
# Why: mapfile < <(cmd) drops the exit status of cmd.
# From: Issue #479, PR #544
@test "_ci_mapfile keeps the command's exit status" {
    local arr=(stale)
    # What: Stub: print two lines, then exit 4.
    # Why: Real tools often print part of a result, then fail.
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

# What: Breaks nproc, then makes it report zero CPUs.
# Why: AG-VAL-001: a failed tool is never worked around.
# From: Issue #479, PR #544
@test "job count fails closed when nproc fails" {
    _fail nproc 1
    run _ci_jobs
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0005"* ]]
    run ci_cmd_selftest
    [ "${status}" -eq 2 ]
    _print nproc 0
    run _ci_nproc
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0005"* ]]
}

# What: Checks a feat(scope) title with enforcement on.
# Why: Block mode must not reject what AG-GH-014 allows.
# From: Issue #479
@test "pr-title accepts a valid Conventional-Commit title" {
    PR_TITLE="feat(pump): add IPv6 support" PR_TITLE_LINT_MODE=block run _ci_check_pr_title
    [ "${status}" -eq 0 ]
}

# What: Reads types and scopes from the repo's AGENTS.md.
# Why: AGENTS.md owns the taxonomy; the checker has no copy.
# From: Issue #479, PR #544, AG-GH-014
@test "pr-title taxonomy is read from AGENTS.md AG-GH-014" {
    run _ci_title_taxonomy types
    [ "${status}" -eq 0 ]
    [ "${output}" = "feat fix security docs refactor perf test build ci chore style revert" ]
    run _ci_title_taxonomy scopes
    [ "${status}" -eq 0 ]
    [ "$(wc -w <<< "${output}")" -eq 15 ]
    [[ " ${output} " == *" support-upstream "* ]]
}

# What: Feeds AGENTS.md without the rule, then empty lists.
# Why: An empty taxonomy must not accept or reject at random.
# From: Issue #479, PR #544, AG-GH-014
@test "pr-title fails closed when AG-GH-014 is missing or unparsable" {
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

# What: Checks a title without a type with enforcement on.
# Why: Only block mode turns a title finding into a failure.
# From: Issue #479
@test "pr-title fails closed on a bad title in block mode" {
    PR_TITLE="add some stuff" PR_TITLE_LINT_MODE=block run _ci_check_pr_title
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-META-TITLE-0002"* ]]
}

# What: Checks a Dependabot bump title in block mode.
# Why: AG-GH-014 has no author exemption.
# From: Issue #479, PR #544
@test "pr-title holds a dependency bot to AG-GH-014 too" {
    PR_AUTHOR="dependabot[bot]" PR_TITLE="Bump foo from 1 to 2" PR_TITLE_LINT_MODE=block run _ci_check_pr_title
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-META-TITLE-0002"* ]]
}

# What: Adds a url with a token, as a dry run, and without.
# Why: A PAT must never land in a log line.
# From: Issue #236, Issue #479, PR #544
@test "board add passes its token to gh but never prints it" {
    # What: Stub gh to echo the token and args it was handed.
    # Why: The real gh needs a project and the network.
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

# What: Lists assets in an empty tree, then in a filled one.
# Why: A release or nightly without packages must not ship.
# From: Issue #362, Issue #479, PR #544
@test "release assets come from the SOT globs and none fails" {
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

# What: Runs both checks for two bot authors, no metadata.
# Why: AG-GH-002 and AG-REL-002 name no author exemption.
# From: Issue #479, PR #544
@test "a bot PR needs tracking metadata and a changelog too" {
    local a
    for a in "github-actions[bot]" "dependabot[bot]"; do
        PR_AUTHOR="${a}" PR_LABELS="" PR_MILESTONE_TITLE="" run _ci_check_pr_tracking
        [ "${status}" -eq 1 ]
        [[ "${output}" == *"CI-ERROR-META-TRACKING-0001"* ]]
        _print _ci_changed_paths .github/yaml/build-manifest.yml
        PR_AUTHOR="${a}" PR_LABELS="dependencies" BASE=b HEAD=h run _stubbed '_print git m' _ci_check_changelog
        [ "${status}" -eq 1 ]
        [[ "${output}" == *"CI-ERROR-META-CHANGELOG-0001"* ]]
    done
}

# What: Checks a PR with the ci label and a milestone.
# Why: AG-GH-002 asks for a label and a milestone, no more.
# From: Issue #479
@test "tracking passes with labels and a milestone" {
    PR_LABELS="ci" PR_MILESTONE_TITLE="current_dev backlog" run _ci_check_pr_tracking
    [ "${status}" -eq 0 ]
}

# What: Checks a labelled PR that has no milestone.
# Why: AG-GH-002 requires a milestone on every PR.
# From: Issue #479
@test "tracking fails closed without a milestone" {
    PR_LABELS="ci" PR_MILESTONE_TITLE="" run _ci_check_pr_tracking
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-META-TRACKING-0001"* ]]
}

# What: Reads live PR data, then replies lacking a field.
# Why: A field jq cannot read must fail, never read empty.
# From: Issue #479, PR #544
@test "live PR fetch sets every field or fails closed" {
    local bad ok='{"title":"fix(ci): x","labels":[{"name":"ci"},{"name":"bug"}],"milestone":null,"isDraft":false}'
    _print gh "${ok}"
    PR_NUMBER=5 GITHUB_REPOSITORY=o/r _ci_metadata_fetch_live
    [ "${PR_TITLE}" = "fix(ci): x" ]
    [ "${PR_LABELS}" = "ci bug" ]
    [ -z "${PR_MILESTONE_TITLE}" ]
    [ "${PR_DRAFT}" = "false" ]
    for bad in 'del(.title)' 'del(.labels)' '.isDraft = "no"'; do
        _print gh "$(jq -c "${bad}" <<< "${ok}")"
        PR_NUMBER=5 GITHUB_REPOSITORY=o/r run _ci_metadata_fetch_live
        [ "${status}" -eq 2 ]
    done
    _fail gh 1
    PR_NUMBER=5 GITHUB_REPOSITORY=o/r run _ci_metadata_fetch_live
    [ "${status}" -eq 2 ]
}

# What: PR run, dispatch with fork PRs, bad heads, fork only.
# Why: A dispatched PR branch is checked too; AG-GH-002 holds.
# From: Issue #479, PR #544
@test "metadata finds the pull request of a PR run and a dispatch" {
    local ev="${BATS_TEST_TMPDIR}/ev.json"
    printf '%s\n' '{"pull_request":{"number":7,"base":{"sha":"b1"},"head":{"sha":"h1"}}}' > "${ev}"
    GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="${ev}" _ci_metadata_pr
    [ "${PR_NUMBER} ${BASE} ${HEAD}" = "7 b1 h1" ]
    _print gh '[{"number":8,"baseRefOid":"f","headRefOid":"f","isCrossRepository":true},{"number":9,"baseRefOid":"b2","headRefOid":"h2","isCrossRepository":false}]'
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=o/r GITHUB_REF_NAME=sot-update GITHUB_SHA=h2 \
        run _stubbed '_pass git' eval '_ci_metadata_pr && echo "${PR_NUMBER} ${BASE} ${HEAD}"'
    [ "${status}" -eq 0 ]
    [ "${output}" = "9 b2 h2" ]
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=o/r GITHUB_REF_NAME=sot-update GITHUB_SHA=h3 \
        run _stubbed '_forbid git' _ci_metadata_pr
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-META-0003"*"head h2 is not this run's h3"* ]]
    _print gh '[{"number":9,"isCrossRepository":false},{"number":10,"isCrossRepository":false}]'
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=o/r GITHUB_REF_NAME=x run _ci_metadata_pr
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-PR-0001"*"2 open pull requests have head x"* ]]
    _print gh '[{"number":8,"baseRefOid":"f","headRefOid":"f","isCrossRepository":true}]'
    _forbid _ci_metadata_fetch_live
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=o/r GITHUB_REF_NAME=x run ci_cmd_metadata
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"NotRun: no open pull request has head x"* ]]
    [[ "${output}" != *"must not run"* ]]
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=o/r GITHUB_REF_NAME=x run ci_cmd_metadata bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-META-0001"* ]]
    _fail gh 1
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=o/r GITHUB_REF_NAME=x run ci_cmd_metadata
    [ "${status}" -eq 2 ]
    GITHUB_EVENT_NAME=push run ci_cmd_metadata
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-META-0002"* ]]
}

# What: Checks a draft PR with no label and no milestone.
# Why: AG-WF-009; ready_for_review re-checks it for real.
# From: Issue #479, PR #544
@test "tracking is non-blocking on a draft PR" {
    PR_LABELS="" PR_MILESTONE_TITLE="" PR_DRAFT="true" run _ci_check_pr_tracking
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"draft, non-blocking"* ]]
}

# What: Runs the board check with PROJECT_PAT unset.
# Why: AG-GH-002 lets only this board sub-check warn.
# From: Issue #479, PR #544
@test "board check skips when PROJECT_AUTOMATION_PAT is unset" {
    unset PROJECT_PAT
    run _ci_check_pr_board
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"CI-META-BOARD"* ]]
}

# What: Board check with a PAT: on, off, lookup error.
# Why: With a PAT, AG-GH-002 makes the board check blocking.
# From: Issue #479, PR #544
@test "board check with a PAT passes only a PR on the board" {
    _print _ci_pr_on_project_board
    PROJECT_PAT="dummy" run _ci_check_pr_board
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"OK: on project board"* ]]
    _fail _ci_pr_on_project_board 1
    PROJECT_PAT="dummy" run _ci_check_pr_board
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-META-BOARD-0002"* ]]
    _fail _ci_pr_on_project_board 2
    PROJECT_PAT="dummy" run _ci_check_pr_board
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-META-BOARD-0001"* ]]
}

# What: Runs version-check for v99.99.99-NG on the repo.
# Why: A tag must name the version configure.ac builds.
# From: Issue #479
@test "release version-check fails on a tag that mismatches configure.ac" {
    run bash "${BATS_TEST_DIRNAME}/ci.sh" release version-check v99.99.99-NG
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-RELEASE-0003"* ]]
}

# What: Checks the fixture's own tag with require_new=false.
# Why: POL-RELEASE-07 runs after the tag was pushed.
# From: Issue #479, PR #544
@test "release version-check require_new=false accepts an already-pushed tag" {
    fx="$(_fixture_tag_repo)"
    CI_REPO_ROOT="${fx}" run _ci_check_release_version v9.9.9-NG false
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"CI-RELEASE"*"OK"* ]]
}

# What: Checks the fixture's existing tag with the default.
# Why: Re-tagging would move an already published ref.
# From: Issue #479, PR #544
@test "release version-check require_new=true still rejects an existing tag" {
    fx="$(_fixture_tag_repo)"
    CI_REPO_ROOT="${fx}" run _ci_check_release_version v9.9.9-NG
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-RELEASE-0004"* ]]
}

# What: Breaks git inside the require_new tag lookup.
# Why: POL-RELEASE-05 needs proof the tag is new.
# From: Issue #479, PR #544
@test "release version-check fails when git cannot list tags" {
    fx="$(_fixture_tag_repo)"
    _fail git 128 "git broke"
    CI_REPO_ROOT="${fx}" run _ci_check_release_version v9.9.9-NG
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"git broke"* ]]
    [[ "${output}" != *"CI-ERROR-RELEASE-0004"* ]]
    [[ "${output}" != *"OK"* ]]
}

# What: Reads the context of a v1.2.3-NG tag push.
# Why: POL-RELEASE-07; release jobs read only these outputs.
# From: Issue #479, PR #544
@test "release context: a tag push publishes and moves latest" {
    GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/v1.2.3-NG GITHUB_REF_NAME=v1.2.3-NG run _ci_release_context
    [ "${status}" -eq 0 ]
    [ "${output}" = "$(printf '%s\n' v1.2.3-NG false true true)" ]
}

# What: Reads three dispatches: opt-in, no opt-in, no tag.
# Why: POL-RELEASE-05: a dry run never moves latest.
# From: Issue #479, PR #544
@test "release context: a dispatch reads tag and opt-in from inputs" {
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

# What: Reads the context of a branch push and a schedule.
# Why: Guessing a tag there would publish the wrong ref.
# From: Issue #479, PR #544
@test "release context fails closed off a release trigger" {
    GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/current_dev GITHUB_REF_NAME=current_dev run _ci_release_context
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-RELEASE-0007"* ]]
    GITHUB_EVENT_NAME=schedule run _ci_release_context
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-RELEASE-0008"* ]]
}

# What: Runs the tag-push check with check and matrix stubbed.
# Why: Downstream jobs gate on these, not on the event.
# From: Issue #479, PR #544
@test "release version-check in CI writes tag, publish, tag_push" {
    local out="${BATS_TEST_TMPDIR}/out"
    # What: Stub: pass only v1.2.3-NG with require_new=false.
    # Why: Pins the arguments the CI path must pass.
    _ci_check_release_version() { [ "$1 $2" = "v1.2.3-NG false" ]; }
    _print _ci_release_matrix '{"include":[]}' '["a"]'
    GITHUB_OUTPUT="${out}" GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/v1.2.3-NG GITHUB_REF_NAME=v1.2.3-NG \
        run _ci_release_version_check
    [ "${status}" -eq 0 ]
    [ "$(cat "${out}")" = "$(printf '%s\n' tag=v1.2.3-NG publish=true tag_push=true \
        'container_matrix={"include":[]}' 'variants=["a"]')" ]
}

# What: Expands two variants on two platforms, then bad data.
# Why: The workflows hold no variant or platform list.
# From: Issue #479, PR #544
@test "release matrix is every SOT variant on every SOT platform" {
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

# What: Publishes with arm64 missing, then amd64 missing too.
# Why: arm64 may fail its build; amd64 never ships without.
# From: Issue #479, PR #544
@test "publish manifest takes every platform; only optional may lack" {
    _fixture_manifest 'release:' '  container:' '    variants:' '      plain: "p"' \
        '    platforms:' '      amd64:' '        runner: "r1"' '        optional: "false"' \
        '      arm64:' '        runner: "r2"' '        optional: "true"'
    _pass _ci_registry_login
    # What: Stub docker: no arm64 tag; AMD_GONE hides amd64.
    # Why: inspect is how publish learns a platform is missing.
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

# What: Offers a tarball and a .deb for tag v1-NG.
# Why: The checklist verifies a CI-built package pre-tag.
# From: Issue #479, PR #544
@test "release packages are offered as one artifact per tag" {
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

# What: Maps a variant, a bad variant and two image refs.
# Why: Release and nightly images share one naming rule.
# From: Issue #359, Issue #479, PR #544
@test "release image names map variants to their GHCR packages" {
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

# What: Feeds a pre-release and a note-less dispatch event.
# Why: Only a published release or explicit notes add one.
# From: Issue #479, PR #544
@test "changelog skips a pre-release and a dispatch without notes" {
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

# What: Plans a release, a note-less dispatch and a push.
# Why: The write token step must not run without a section.
# From: Issue #479, PR #544
@test "changelog plan says insert only when the event has notes" {
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

# What: Feeds a release event and a dispatch with notes.
# Why: The workflow passes neither; ci.sh reads the event.
# From: Issue #479, PR #544
@test "changelog takes a published release's tag and body" {
    local ev="${BATS_TEST_TMPDIR}/ev.json"
    # What: Stub the insert to print its tag and notes.
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

# What: Inserts a notes file into a fixture repo, dry run.
# Why: The release checklist's recovery path runs it locally.
# From: Issue #479, PR #544
@test "changelog manual retry inserts a notes file, dry run pushes nothing" {
    local fx="${BATS_TEST_TMPDIR}/fx"
    mkdir -p "${fx}"
    ( cd "${fx}" && git init -q && printf '# Changelog\n<!-- insertion marker -->\n' > CHANGELOG.md \
      && git add CHANGELOG.md && git -c user.name=t -c user.email=t@t commit -q -m x )
    printf 'line one\n' > "${BATS_TEST_TMPDIR}/notes"
    _pass _ci_git_auth_setup
    CI_REPO_ROOT="${fx}" DRY_RUN=true run _ci_publish_changelog_update v1.2.3-NG "${BATS_TEST_TMPDIR}/notes"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DRY_RUN would run: git push origin HEAD:current_dev"* ]]
    grep -qx '## \[1.2.3-NG\] - .*' "${fx}/CHANGELOG.md"
    grep -qx 'line one' "${fx}/CHANGELOG.md"
    [ "$(git -C "${fx}" log -1 --format=%s)" = "CHANGELOG.md: add v1.2.3-NG" ]
}

# What: Runs ci.sh container with an unknown variant.
# Why: A variant typo must not build a default image.
# From: Issue #479
@test "container rejects an unimplemented variant" {
    run bash "${BATS_TEST_DIRNAME}/ci.sh" container bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CONTAINER-0001"* ]]
}

# What: Logs in with REGISTRY_TOKEN unset, docker forbidden.
# Why: A missing secret is a hard failure (AG-VAL-001).
# From: Issue #479, PR #544
@test "registry login fails closed without REGISTRY_TOKEN" {
    _forbid docker
    unset REGISTRY_TOKEN
    GITHUB_ACTOR=octo run _ci_registry_login
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"REGISTRY_TOKEN required"* ]]
    [[ "${output}" != *"docker must not run"* ]]
}

# What: Logs in with a docker stub recording stdin and argv.
# Why: argv leaks into process listings and logs.
# From: Issue #479, PR #544
@test "registry login pipes the token on stdin as GITHUB_ACTOR" {
    # What: Stub docker to record its stdin and argv.
    # Why: The real login needs a registry and a token.
    docker() { cat > "${BATS_TEST_TMPDIR}/stdin"; echo "$*" > "${BATS_TEST_TMPDIR}/argv"; }
    REGISTRY_TOKEN=s3cret GITHUB_ACTOR=octo run _ci_registry_login
    [ "${status}" -eq 0 ]
    [ "$(cat "${BATS_TEST_TMPDIR}/stdin")" = "s3cret" ]
    [ "$(cat "${BATS_TEST_TMPDIR}/argv")" = "login ghcr.io -u octo --password-stdin" ]
}

# What: Counts a five-line log for two hosts and a subnet.
# Why: Only real remote COMPILE_OK from the client may count.
# From: Issue #479, Issue #264, PR #544
@test "e2e compile-ok counter counts only clients inside the CIDR" {
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

# What: Scans a log of a listen line and one COMPILE_OK.
# Why: Verbose info/debug lines carry no severity prefix.
# From: Issue #479, PR #544
@test "e2e server warning scan passes a clean verbose log" {
    local log="${BATS_TEST_TMPDIR}/server.log"
    printf 'distccd[7] listening on 0.0.0.0:3632\ndistccd[9] (dcc_job_summary) client: 172.18.0.3:4 COMPILE_OK\n' > "${log}"
    run _ci_e2e_check_server_warnings "${log}"
    [ "${status}" -eq 0 ]
}

# What: Scans a log holding one ERROR line.
# Why: ERROR: is one of the severity prefixes distccd logs.
# From: Issue #479, PR #544
@test "e2e server warning scan fails on a warning-level line" {
    local log="${BATS_TEST_TMPDIR}/server.log"
    printf 'distccd[8] (dcc_check_client) ERROR: connection from client denied\n' > "${log}"
    run _ci_e2e_check_server_warnings "${log}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-E2E-0015"* ]]
}

# What: Counts COMPILE_OK in a log file that does not exist.
# Why: A missing log must not read as zero compiles.
# From: Issue #479, PR #544
@test "e2e compile-ok counter fails closed on an unreadable log" {
    run _ci_e2e_count_compile_ok "${BATS_TEST_TMPDIR}/nope.log" 172.18.0.0/16
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-E2E-0002"* ]]
}

# What: Calls e2e, workload and image with bad modes.
# Why: A typo must never run a default harness.
# From: Issue #479, PR #544
@test "e2e and workload reject unknown modes before touching docker" {
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

# What: Self-compiles a stub tree: clean make, then a warning.
# Why: The distributed build must pass the warning gate too.
# From: Issue #479, PR #544
@test "self-compile gates its make output in both passes" {
    local dir="${BATS_TEST_TMPDIR}/w" pass
    mkdir -p "${dir}/src"
    printf '#!/bin/sh\n' | tee "${dir}/src/distcc" > "${dir}/src/distccd"
    chmod +x "${dir}/src/distcc" "${dir}/src/distccd"
    _pass _ci_tree_copy _ci_configure_tree
    _print _ci_nproc 2
    _print make "gcc -c src/x.c"
    # What: Stub the ng pump launcher to log, then run its args.
    # Why: The pump pass must reach make through the launcher.
    pump() { echo "pump ran" >&2; "$@"; }
    run _ci_workload_self_compile pump "${dir}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"pump ran"* ]]
    _print make "src/x.c:12:5: warning: unused variable 'y'"
    for pass in plain pump; do
        run _ci_workload_self_compile "${pass}" "${dir}"
        [ "${status}" -eq 1 ]
        [[ "${output}" == *"CI-ERROR-BUILD-WARN-0001"* ]]
    done
}

# What: Copies a fixture repo over a stale dir, then fails cp.
# Why: Every workload must start from a fresh, full copy.
# From: Issue #479, PR #544
@test "tree copy replaces the workdir with a full fresh copy" {
    local repo="${BATS_TEST_TMPDIR}/repo" dir="${BATS_TEST_TMPDIR}/w"
    mkdir -p "${repo}/sub" "${dir}/src"
    printf 'a\n' > "${repo}/sub/f"
    printf 'old\n' > "${dir}/src/stale"
    CI_REPO_ROOT="${repo}" _ci_tree_copy "${dir}"
    [ "$(cat "${dir}/src/sub/f")" = "a" ]
    [ ! -e "${dir}/src/stale" ]
    CI_REPO_ROOT="${repo}" run _stubbed '_fail cp 1 boom' _ci_tree_copy "${dir}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"boom"* ]]
}

# What: Sets the SOT nightly tag to v3.6.6-NG and publishes.
# Why: git push -f on a v* tag would clobber a real release.
# From: Issue #479
@test "publish nightly refuses to force-move a v* tag" {
    _fixture_manifest 'release:' '  nightly_tag: "v3.6.6-NG"'
    run _ci_publish_nightly
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-PUBLISH-0002"* ]]
}

# What: Runs ci.sh release with an unknown subcommand.
# Why: A typo must not fall through to a publish step.
# From: Issue #479
@test "release rejects an unknown subcommand" {
    run bash "${BATS_TEST_DIRNAME}/ci.sh" release bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-RELEASE-0005"* ]]
}

# What: Checks a PR labelled no-changelog-needed.
# Why: AG-REL-002 accepts that label in place of an entry.
# From: Issue #479
@test "changelog is skipped by the no-changelog-needed label" {
    PR_LABELS="ci no-changelog-needed" run _ci_check_changelog
    [ "${status}" -eq 0 ]
}

# What: A base gains CHANGELOG.md after the fork; the PR not.
# Why: Only the PR's own changes may satisfy AG-REL-002.
# From: Issue #479, PR #544
@test "changelog check diffs from the merge base, not the base tip" {
    local r="${BATS_TEST_TMPDIR}/r" trunk base head
    mkdir -p "${r}/src"
    ( cd "${r}" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m root ) || return 1
    trunk="$(git -C "${r}" symbolic-ref --short HEAD)"
    ( cd "${r}" && git checkout -q -b pr && printf 'x\n' > src/x.c && git add src/x.c \
      && git commit -q -m pr && git checkout -q "${trunk}" && printf 'e\n' > CHANGELOG.md \
      && git add CHANGELOG.md && git commit -q -m entry ) || return 1
    base="$(git -C "${r}" rev-parse "${trunk}")"
    head="$(git -C "${r}" rev-parse pr)"
    CI_REPO_ROOT="${r}" BASE="${base}" HEAD="${head}" PR_LABELS="" run _ci_check_changelog
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-META-CHANGELOG-0001"* ]]
    ( cd "${r}" && git checkout -q pr && printf 'p\n' > CHANGELOG.md && git add CHANGELOG.md \
      && git commit -q -m own ) || return 1
    head="$(git -C "${r}" rev-parse pr)"
    CI_REPO_ROOT="${r}" BASE="${base}" HEAD="${head}" PR_LABELS="" run _ci_check_changelog
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"OK: CHANGELOG.md touched"* ]]
}

# What: Reads a PR, a push and a dispatch payload.
# Why: The plan diff must never mix PR and push fields.
# From: Issue #479, PR #544
@test "event range: a PR diffs base..head, a push before..sha" {
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

# What: Reads a PR, an issue and an empty payload.
# Why: The workflows forward neither; a missing one fails.
# From: Issue #479, PR #544
@test "event PR number and board url come from the payload" {
    local ev="${BATS_TEST_TMPDIR}/ev.json"
    printf '{"pull_request":{"number":7,"html_url":"https://h/pr/7"}}' > "${ev}"
    GITHUB_EVENT_PATH="${ev}" run _ci_event_value .pull_request.number
    [ "${output}" = "7" ]
    # What: Stub the board add to print the url it gets.
    # Why: The test checks the url, not the board API.
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

# What: Runs fuzz impact on a push, a docs PR and a fuzz PR.
# Why: Only a reviewed PR diff may skip a class.
# From: Issue #479, PR #544
@test "impact-hit runs every class off a PR, diffs on a PR" {
    local out="${BATS_TEST_TMPDIR}/out"
    GITHUB_OUTPUT="${out}" GITHUB_EVENT_NAME=push run ci_cmd_impact_hit fuzz
    [ "$(cat "${out}")" = "hit=true" ]
    _print _ci_event_range b h
    _print _ci_changed_paths doc/x.md
    : > "${out}"
    GITHUB_OUTPUT="${out}" GITHUB_EVENT_NAME=pull_request run ci_cmd_impact_hit fuzz
    [ "$(cat "${out}")" = "hit=false" ]
    _print _ci_changed_paths test/fuzz/a.c
    : > "${out}"
    GITHUB_OUTPUT="${out}" GITHUB_EVENT_NAME=pull_request run ci_cmd_impact_hit fuzz
    [ "$(cat "${out}")" = "hit=true" ]
}

# What: Runs fuzz impact on a PR whose git diff fails.
# Why: A false miss would skip fuzzing on a broken diff.
# From: Issue #479, PR #544
@test "impact-hit fails closed when the PR diff fails" {
    _print _ci_event_range b h
    _fail git 128
    GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/out" GITHUB_EVENT_NAME=pull_request run ci_cmd_impact_hit fuzz
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-DIFF-0001"* ]]
}

# What: Rates all-success, one skip and an empty list.
# Why: A skipped publish means the nightly did not ship.
# From: Issue #479, PR #544
@test "report outcome is success only if every job succeeded" {
    run _ci_jobs_outcome "$(printf '%s\n' a=success b=success)"
    [ "${output}" = "success" ]
    run _ci_jobs_outcome "$(printf '%s\n' a=success b=skipped)"
    [ "${output}" = "failure" ]
    run _ci_jobs_outcome ""
    [ "${status}" -eq 2 ]
    GITHUB_SERVER_URL=https://s GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=9 run _ci_run_url
    [ "${output}" = "https://s/o/r/actions/runs/9" ]
}

# What: Plans a dispatch and a schedule; neither has a before.
# Why: NOOP would skip the checks a dispatch or nightly needs.
# From: Issue #479, PR #544
@test "plan on a dispatch or schedule selects every phase" {
    local ev="${BATS_TEST_TMPDIR}/ev.json" out="${BATS_TEST_TMPDIR}/out" e
    _print ci_cmd_matrix '{"include":[]}'
    for e in workflow_dispatch:'{"inputs":{}}' schedule:'{"schedule":"0 4 * * *"}'; do
        printf '%s' "${e#*:}" > "${ev}"
        : > "${out}"
        GITHUB_OUTPUT="${out}" GITHUB_EVENT_NAME="${e%%:*}" GITHUB_EVENT_PATH="${ev}" GITHUB_SHA=HEAD \
            GITHUB_REF_NAME=current_dev run ci_cmd_plan
        [ "${status}" -eq 0 ]
        grep -qx "phases=$(_ci_all_phases | paste -sd ' ')" "${out}"
        grep -qx 'build=true' "${out}"
        grep -qx 'publish_buildtools=true' "${out}"
    done
}

# What: Plans a push that adds a packaging file.
# Why: impact is the one diff-to-phases owner for plan.
# From: Issue #479, PR #544
@test "plan classifies the push diff through ci.sh impact" {
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
    _print ci_cmd_matrix '{"include":[]}'
    CI_REPO_ROOT="${fx}" GITHUB_OUTPUT="${out}" GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="${ev}" \
        GITHUB_SHA="${h}" GITHUB_REF_NAME=current_dev run ci_cmd_plan
    [ "${status}" -eq 0 ]
    grep -qx 'phases=package' "${out}"
    grep -qx 'publish_buildtools=false' "${out}"
}

# What: Plans dispatches on bot/x, 544/merge and no ref.
# Why: Only current_dev and master may push buildtools:latest.
# From: Issue #479, PR #544
@test "plan publishes buildtools only from a protected ref" {
    local ev="${BATS_TEST_TMPDIR}/ev.json" out="${BATS_TEST_TMPDIR}/out" ref
    printf '{"inputs":{}}' > "${ev}"
    _print ci_cmd_matrix '{"include":[]}'
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

# What: Expands a two-OS variant and an opt-in variant.
# Why: An opt-in variant is never a PR gate.
# From: Issue #479, PR #544
@test "matrix expands variant x os and excludes opt-in variants" {
    _fixture_manifest 'build_matrix:' '  variants:' '    a:' '      apt: "p"' '      brew: "q"' \
        '      os: [ubuntu-latest, macos-latest]' '    b:' '      apt: "r"' '      opt_in: true' \
        '      os: [ubuntu-latest]'
    run ci_cmd_matrix
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"include":[{"variant":"a","os":"ubuntu-latest","apt":"p"},{"variant":"a","os":"macos-latest","brew":"q"}]}' ]
}

# What: Expands both matrices with backslashes in the SOT.
# Why: jq builds the JSON, so any value stays a string.
# From: Issue #479, PR #544
@test "both matrices stay valid JSON for any SOT value" {
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

# What: Runs ci.sh build bogus with /tmp as the repo root.
# Why: No configure or make may run for a mistyped variant.
# From: Issue #479
@test "build fails closed on an unknown variant before touching the tree" {
    CI_REPO_ROOT=/tmp run bash "${BATS_TEST_DIRNAME}/ci.sh" build bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

# What: Real popt/ tree, then a copy with six fixes undone.
# Why: A reverted vendored popt must fail popt-vendor.
# From: Issue #479, PR #544
@test "popt CVE fingerprints pass the real tree and fail a reverted one" {
    local fx="${BATS_TEST_TMPDIR}/fx" i
    cd "${CI_REPO_ROOT}"
    run _ci_popt_cve_fingerprint_check
    [ "${status}" -eq 0 ]
    mkdir -p "${fx}"
    cp -a "${CI_REPO_ROOT}/popt" "${fx}/"
    printf 'old\n' > "${fx}/popt/POPT_VERSION"
    sed -i 's/poptJlu32lpair/x/' "${fx}/popt/poptint.h"
    touch "${fx}/popt/findme.c"
    sed -i 's/== POPT_OPTION_DEPTH/>= 0/' "${fx}/popt/popt.c"
    sed -i 's/calloc/malloc/g' "${fx}/popt/poptconfig.c"
    sed -i 's/maxargvlen = argvlen \* 2;/maxargvlen = argvlen;/' "${fx}/popt/poptparse.c"
    cd "${fx}"
    run _ci_popt_cve_fingerprint_check
    [ "${status}" -eq 1 ]
    for i in 1 2 3 4 5 6; do
        [[ "${output}" == *"CI-ERROR-POPT-CVE-000${i}"* ]]
    done
}

# What: Smoke-tests stub distccd builds; gcc-compiles popt.
# Why: A popt regression compiles; --help or -Werror shows it.
# From: Issue #479, PR #544
@test "popt smoke test and strict compile fail closed" {
    local d="${BATS_TEST_TMPDIR}/b"
    mkdir -p "${d}"
    cd "${d}"
    printf '#!/bin/sh\necho "--jobs --nice --listen --daemon --log-file --allow --user --port"\n' > distccd
    chmod +x distccd
    run _ci_popt_fallback_smoke_test
    [ "${status}" -eq 0 ]
    printf '#!/bin/sh\necho "--jobs --nice"\n' > distccd
    run _ci_popt_fallback_smoke_test
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-BUILD-POPT-0002"*"missing --listen"* ]]
    printf '#!/bin/sh\necho boom\nexit 3\n' > distccd
    run _ci_popt_fallback_smoke_test
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-BUILD-POPT-0003"*"boom"* ]]
    _pass gcc
    RUNNER_TEMP="${d}" run _ci_popt_strict_compile
    [ "${status}" -eq 0 ]
    _fail gcc 1 "popt.c:1:1: error: x"
    RUNNER_TEMP="${d}" run _ci_popt_strict_compile
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"error: x"* ]]
}

# What: Builds popt-fallback without, then with, the fallback.
# Why: A leaked libpopt-dev must fail, not build system popt.
# From: Issue #479, PR #544
@test "build popt variants gate on the fallback line and fingerprints" {
    _print _ci_python python3
    _pass _ci_make_gated _ci_popt_fallback_smoke_test
    # What: Stub configure to log that system popt was found.
    # Why: The fallback check reads only the configure log.
    _ci_configure_tree() { printf 'checking for popt... yes\n' > "$1"; }
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run ci_cmd_build popt-fallback
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-BUILD-POPT-0001"* ]]
    # What: Stub configure to log the bundled-popt fallback.
    # Why: Only this line proves the build used bundled popt.
    _ci_configure_tree() { printf 'system libpopt not found (or disabled); building bundled popt\n' > "$1"; }
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run ci_cmd_build popt-fallback
    [ "${status}" -eq 0 ]
    _fail _ci_popt_cve_fingerprint_check 1
    _forbid _ci_popt_strict_compile
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run ci_cmd_build popt-vendor
    [ "${status}" -eq 1 ]
    [[ "${output}" != *"must not run"* ]]
}

# What: Logs the apt line of an image and a runner install.
# Why: An image ships the packages current on its build day.
# From: Issue #479, PR #544
@test "image installs full-upgrade first; runner installs do not" {
    local log="${BATS_TEST_TMPDIR}/calls"
    # What: Stub timeout to log the command it would run.
    # Why: The test reads the apt line without a real apt.
    timeout() { shift 3; echo "$*" >> "${log}"; }
    run _stubbed '_print id 0; _pass rm' _ci_apt_install "p q" image
    [ "${status}" -eq 0 ]
    grep -qF 'apt-get update && apt-get full-upgrade -y --no-install-recommends && apt-get install -y --no-install-recommends p q' "${log}"
    : > "${log}"
    run _stubbed '_print id 0; _pass rm' _ci_apt_install "p q"
    [ "${status}" -eq 0 ]
    grep -qF 'apt-get install -y' "${log}"
    run grep -c 'upgrade' "${log}"
    [ "${output}" = "0" ]
}

# What: apt cut off once, dpkg failing, apt failing twice.
# Why: A killed install leaves dpkg interrupted for the retry.
# From: Issue #493, Issue #479, PR #544
@test "apt retry first finishes a dpkg run the timeout cut off" {
    local log="${BATS_TEST_TMPDIR}/calls"
    # What: Stub sudo to run its command directly.
    # Why: The test runs as a plain user without sudo.
    sudo() { "$@"; }
    _pass sleep
    # What: Stub timeout: log calls; the first apt run times out.
    # Why: Replays an apt run the timeout cut off mid-dpkg.
    timeout() {
        shift 3
        echo "$*" >> "${log}"
        case "$*" in
            *"dpkg --configure -a"*) [ -z "${DPKG_FAIL:-}" ] ;;
            *) [ -z "${APT_RC:-}" ] || return "${APT_RC}"
               [ "$(grep -c 'apt-get' "${log}")" -ge 2 ] || return 124 ;;
        esac
    }
    run _ci_apt_install "p q"
    [ "${status}" -eq 0 ]
    [[ "$(sed -n 2p "${log}")" == *"dpkg --configure -a"* ]]
    [ "$(grep -c 'apt-get' "${log}")" -eq 2 ]
    [[ "${output}" == *"attempt 1/2: apt exited 124 (timed out after 3m)"* ]]
    : > "${log}"
    DPKG_FAIL=1 run _ci_apt_install "p q"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-INSTALL-0004"* ]]
    : > "${log}"
    APT_RC=100 run _ci_apt_install "p q"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"attempt 1/2: apt exited 100"* ]]
    [[ "${output}" == *"attempt 2/2: apt exited 100"*"CI-ERROR-INSTALL-0001"* ]]
    [[ "${output}" != *"timed out"* ]]
}

# What: Gates a clean make, a warning make and a missing log.
# Why: Warnings are errors (AG-INT-003) on every tree build.
# From: Issue #479, PR #544
@test "make gate passes a clean build and fails on a warning" {
    _print make "gcc -c src/x.c"
    run _ci_make_gated "${BATS_TEST_TMPDIR}/ok.log" all
    [ "${status}" -eq 0 ]
    _print make "src/x.c:12:5: warning: unused variable 'y'"
    run _ci_make_gated "${BATS_TEST_TMPDIR}/warn.log" all
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-BUILD-WARN-0001"* ]]
    [[ "${output}" == *"src/x.c:12:5: warning"* ]]
    run _ci_warning_gate "${BATS_TEST_TMPDIR}/missing.log" "make check"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-BUILD-WARN-0002"* ]]
}

# What: Fails make, then configure, then autogen in turn.
# Why: set -e is off under ||, so each rc needs a check.
# From: Issue #479, PR #544
@test "make gate and configure fail closed when the tool fails" {
    _fail make 2 boom
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

# What: Parses one OK and one NOTRUN line.
# Why: NOTRUN is a declared skip, not a failure.
# From: Issue #479
@test "comfychair parse passes on all-OK/NOTRUN output" {
    log="${BATS_TEST_TMPDIR}/log"
    printf '%s\n' "FooCase           OK" "BarCase           NOTRUN, needs root" > "${log}"
    run _ci_parse_comfychair "${log}"
    [ "${status}" -eq 0 ]
}

# What: Parses one OK and one FAIL line.
# Why: A failed test must never report green.
# From: Issue #479
@test "comfychair parse fails closed on a FAIL line" {
    log="${BATS_TEST_TMPDIR}/log"
    printf '%s\n' "FooCase           OK" "BarCase           FAIL" > "${log}"
    run _ci_parse_comfychair "${log}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-TEST-0002"* ]]
}

# What: Parses build noise without any result line.
# Why: An empty parse must not look like a clean pass.
# From: Issue #479
@test "comfychair parse fails closed on zero parsed result lines" {
    log="${BATS_TEST_TMPDIR}/log"
    printf '%s\n' "build noise, no result lines" > "${log}"
    run _ci_parse_comfychair "${log}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-TEST-0001"* ]]
}

# What: Runs ci.sh test bogus with /tmp as the repo root.
# Why: No make check may run for a mistyped variant.
# From: Issue #479
@test "test fails closed on an unknown variant" {
    CI_REPO_ROOT=/tmp run bash "${BATS_TEST_DIRNAME}/ci.sh" test bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-TEST-0005"* ]]
}

# What: Runs ci.sh test coverage with make and lcov stubbed.
# Why: Each step passing alone does not prove the chain.
# From: Issue #479, PR #370, PR #544
@test "test coverage: both reports, the summary, one artifact offer" {
    local fx="${BATS_TEST_TMPDIR}/fx" out="${BATS_TEST_TMPDIR}/out" sum="${BATS_TEST_TMPDIR}/sum"
    mkdir -p "${fx}"
    _print make 'Foo_Case        OK'
    # What: Stub lcov: write coverage.info; LCOV_FAIL fails it.
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

# What: Runs report with an empty GH_TOKEN.
# Why: A silent no-op would hide broken status reporting.
# From: Issue #479, Issue #81
@test "report fails closed when GH_TOKEN is unset" {
    GH_TOKEN="" run ci_cmd_report
    [ "${status}" -ne 0 ]
}

# What: Adds an issue url with PROJECT_PAT set, then empty.
# Why: _ci_board_add is the one owner of the PAT decision.
# From: Issue #479, PR #329, PR #544
@test "add-to-project leaves the PAT decision to the board owner" {
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

# What: Writes a one-line and a two-line output pair.
# Why: A newline in k=v would end the value early.
# From: Issue #479, PR #544
@test "output writer uses the delimiter form for multi-line values" {
    local out="${BATS_TEST_TMPDIR}/out"
    GITHUB_OUTPUT="${out}" _ci_output a 1 b $'x\ny'
    run cat "${out}"
    [ "${lines[0]}" = "a=1" ]
    [[ "${lines[1]}" == "b<<ci_eof_"* ]]
    [ "${lines[2]}" = "x" ]
    [ "${lines[3]}" = "y" ]
    [ "${lines[4]}" = "${lines[1]#b<<}" ]
}

# What: Writes a summary set, unset, then from a failing tool.
# Why: Local runs have no summary file; CI runs always do.
# From: Issue #479, PR #544
@test "step summary appends a command's output, else NotRun" {
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

# What: Calls the output writer with a name and no value.
# Why: Writing half a pair would shift every later output.
# From: Issue #479, PR #544
@test "output writer fails closed on an odd argument count" {
    GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/out" run _ci_output a 1 b
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0004"* ]]
}

# What: Offers two files under the SOT artifact kind k.
# Why: The workflow step only forwards these outputs.
# From: Issue #479, PR #544
@test "artifact offer writes SOT name, files and retention" {
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

# What: Offers no files, then a file that does not exist.
# Why: An upload of nothing would hide a lost report.
# From: Issue #479, PR #544
@test "artifact offer fails closed on a missing or empty file set" {
    _fixture_actions
    GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/out" run _ci_artifact_offer k ""
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-ARTIFACT-0001"* ]]
    GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/out" run _ci_artifact_offer k "" "${BATS_TEST_TMPDIR}/none"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-ARTIFACT-0002"* ]]
    [ ! -s "${BATS_TEST_TMPDIR}/out" ]
}

# What: Plans keys over a README edit, then an m4 edit.
# Why: Only configure.ac and m4/ change the autoconf output.
# From: Issue #54, Issue #479, PR #544
@test "cache plan keys default on OS, arch, autoconf inputs, run" {
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

# What: Runs CFL as a crash with one reproducer on disk.
# Why: The upload step runs after the failure via always().
# From: Issue #267, Issue #479, PR #544
@test "CFL run offers crash reproducers and keeps its exit code" {
    local out="${BATS_TEST_TMPDIR}/out"
    RUNNER_TEMP="${BATS_TEST_TMPDIR}/rt"
    _fixture_manifest 'ci_engine:' '  artifacts:' '    cfl_crashes:' '      name: "cfl-crashes"' '      retention_days: "90"' \
        'security:' '  cfl_run:' '    seconds: "1"' '    mode: "batch"'
    _fail _ci_cfl_run 1
    mkdir -p "${RUNNER_TEMP}/cfl-workspace/out/artifacts/fuzz_x"
    : > "${RUNNER_TEMP}/cfl-workspace/out/artifacts/fuzz_x/crash-1"
    GITHUB_OUTPUT="${out}" run ci_cmd_clusterfuzzlite_run address
    [ "${status}" -eq 1 ]
    grep -qx 'artifact_name=cfl-crashes-address' "${out}"
    grep -qx "artifact_path=${RUNNER_TEMP}/cfl-workspace/out/artifacts" "${out}"
}

# What: Runs CFL with rc 3 and an empty artifacts dir.
# Why: No reproducer means no artifact; rc is never masked.
# From: Issue #267, Issue #479, PR #544
@test "CFL run without crashes offers nothing and passes rc" {
    local out="${BATS_TEST_TMPDIR}/out"
    RUNNER_TEMP="${BATS_TEST_TMPDIR}/rt"
    _fail _ci_cfl_run 3
    mkdir -p "${RUNNER_TEMP}/cfl-workspace/out/artifacts"
    GITHUB_OUTPUT="${out}" run ci_cmd_clusterfuzzlite_run address
    [ "${status}" -eq 3 ]
    [ ! -e "${out}" ]
}

# What: Plans the cache for the coverage variant.
# Why: Build and cache must agree on the ccache variants.
# From: Issue #54, Issue #479, PR #544
@test "cache plan writes nothing for a variant without ccache" {
    local out="${BATS_TEST_TMPDIR}/out"
    _forbid ccache
    GITHUB_OUTPUT="${out}" run ci_cmd_cache coverage
    [ "${status}" -eq 0 ]
    [ ! -e "${out}" ]
}

# What: Drafts with a failing list, no draft, an auth error.
# Why: Empty lookups would publish a wrong, empty draft.
# From: Issue #479, PR #544
@test "draft release stops on an API error before it writes" {
    local log="${BATS_TEST_TMPDIR}/gh"
    # What: Stub gh: log calls; release list fails.
    # Why: The log shows whether any edit or create ran.
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

# What: Appends one fix PR to an empty body under Fixed.
# Why: The heading is a value; only the body is a nameref.
# From: Issue #479, PR #544
@test "draft release body groups PRs under their category heading" {
    local body=""
    _ci_draft_release_append body "Fixed" "* #5 | fix(ci): a"
    [ "${body}" = "$(printf '%s\n%s\n' '### Fixed' '* #5 | fix(ci): a')
" ]
}

# What: AC-03 and BR-07 on failing, null, partial, real data.
# Why: A tool failure must never pose as a compliance finding.
# From: Issue #312, Issue #479, PR #544
@test "OpenSSF API checks fail closed instead of reading NotMet" {
    _fail gh 1
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
    _print gh null
    GITHUB_REPOSITORY=o/r run _ci_ossf_check_br07
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-OSSF-0003"* ]]
    _print gh '{"secret_scanning":{"status":"enabled"}}'
    GITHUB_REPOSITORY=o/r run _ci_ossf_verdict _ci_ossf_check_br07
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-OSSF-0003"* ]]
    [[ "${output}" != *"NotMet"* ]]
    # What: Stub gh: a met ruleset, scanning on, push off.
    # Why: Real Met and NotMet verdicts must still come out.
    gh() { case "$*" in *rulesets/7*) echo '["pull_request","deletion"]' ;; *) echo '{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"disabled"}}' ;; esac; }
    GITHUB_REPOSITORY=o/r run _ci_ossf_verdict _ci_ossf_check_ac03 7
    [ "${output}" = "Met" ]
    GITHUB_REPOSITORY=o/r run _ci_ossf_verdict _ci_ossf_check_br07
    [ "${output}" = "NotMet" ]
}

# What: Checks a base-SHA bootstrap, then a ref-taking one.
# Why: Base-SHA checkouts run no PR code; a head ref does.
# From: Issue #312, PR #544
@test "BR-01 flags only a ref-taking checkout in a target workflow" {
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

# What: Runs each local check in an empty dir, git broken.
# Why: A failed tool must never read as Met or NotMet.
# From: Issue #312, Issue #479, PR #544
@test "OpenSSF local checks give no verdict on a tool error" {
    local fx="${BATS_TEST_TMPDIR}/fx"
    mkdir -p "${fx}"
    cd "${fx}"
    run _stubbed '_fail git 128' _ci_ossf_verdict _ci_ossf_check_qa05
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-OSSF-0004"* ]]
    run _ci_ossf_verdict _ci_ossf_check_ac04
    [ "${status}" -eq 2 ]
    run _ci_ossf_verdict _ci_ossf_check_br01
    [ "${status}" -eq 2 ]
    run _ci_ossf_verdict _ci_ossf_check_br05_do06
    [ "${status}" -eq 2 ]
    run _ci_ossf_verdict grep -rq "ci.sh attest release" .github/workflows/
    [ "${status}" -eq 2 ]
    _print gh 'not json'
    GITHUB_REPOSITORY=o/r run _ci_ossf_verdict _ci_ossf_check_ac03 7
    [ "${status}" -eq 2 ]
    GITHUB_REPOSITORY=o/r run _ci_ossf_verdict _ci_ossf_check_br07
    [ "${status}" -eq 2 ]
}

# What: Builds one proposal query over three calls.
# Why: The link may carry only criteria re-verified as Met.
# From: Issue #312, PR #544
@test "ossf add_met: only Met adds a pair; an encode error fails" {
    local qs=""
    _ci_ossf_add_met qs NotMet "OSPS-AC-03.01" "x y"
    [ -z "${qs}" ]
    _ci_ossf_add_met qs Met "OSPS-AC-03.01" "x y"
    _ci_ossf_add_met qs Met "OSPS-BR-01.01" "z"
    [ "${qs}" = "osps_ac_03.01_status=Met&osps_ac_03.01_justification=x%20y&osps_br_01.01_status=Met&osps_br_01.01_justification=z" ]
    _fail _ci_ossf_urlencode 1 "jq broke"
    run _ci_ossf_add_met qs Met "OSPS-VM-02.01" "w"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"jq broke"* ]]
}

# What: Maps grep hits, a miss and a missing file to verdicts.
# Why: Only rc 0 and 1 are answers; others are tool errors.
# From: Issue #479, Issue #312, PR #544
@test "ossf verdict: Met, NotMet, and a tool error is no verdict" {
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

# What: Picks prune candidates from ten fixture versions.
# Why: A real tag or live index child must never be deleted.
# From: Issue #479, PR #544
@test "gc candidates keep protected, rollback set, and real tags" {
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

# What: Runs gc for a package the SOT does not list.
# Why: A typo MUST NOT reach a delete-capable token.
# From: Issue #479, PR #544
@test "gc rejects a package outside the SOT before any API call" {
    _forbid gh docker
    GH_TOKEN=x GITHUB_REPOSITORY_OWNER=wiki-mod run ci_cmd_gc not-a-package
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0001"* ]]
    [[ "${output}" != *"must not run"* ]]
}

# What: Collects protected digests with docker inspect broken.
# Why: Unknown children would otherwise lose their protection.
# From: Issue #479, PR #544
@test "gc protection fails closed when a tag cannot be inspected" {
    _fail docker 1
    GITHUB_REPOSITORY_OWNER=wiki-mod run _ci_gc_protected_digests distcc-ng '[{"metadata":{"container":{"tags":["latest"]}}}]'
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GC-0002"* ]]
}

# What: Collects digests from bad JSON, then a 2-child index.
# Why: A jq error must not drop a child from the keep-set.
# From: Issue #479, PR #544
@test "gc protection fails closed on unreadable tags or manifests" {
    _print docker 'not json'
    GITHUB_REPOSITORY_OWNER=wiki-mod run _ci_gc_protected_digests distcc-ng 'not json'
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GC-0003"* ]]
    GITHUB_REPOSITORY_OWNER=wiki-mod run _ci_gc_protected_digests distcc-ng '[{"metadata":{"container":{"tags":["latest"]}}}]'
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GC-0004"* ]]
    _print docker '{"manifests":[{"digest":"sha256:a"},{"digest":"sha256:b"}]}'
    GITHUB_REPOSITORY_OWNER=wiki-mod run _ci_gc_protected_digests distcc-ng '[{"metadata":{"container":{"tags":["latest"]}}}]'
    [ "${status}" -eq 0 ]
    [ "${output}" = '["sha256:a","sha256:b"]' ]
}

# What: Reads six release payloads, good and malformed.
# Why: A jq error must not read as "pre-release, skip".
# From: Issue #479, PR #544
@test "changelog event: pre-release skips, a bad event fails" {
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

# What: Loads the board with PROJECT_OWNER/NUMBER preset.
# Why: One owner; a second source is a parallel owner.
# From: Issue #236, Issue #479, PR #544
@test "project board identity comes only from the SOT" {
    _fixture_manifest 'project_board:' '  owner: "sot-owner"' '  number: "7"'
    PROJECT_OWNER="shadow" PROJECT_NUMBER="999"
    _ci_project_board_load
    [ "${PROJECT_OWNER}" = "sot-owner" ]
    [ "${PROJECT_NUMBER}" = "7" ]
}

# What: Filters four results: success, failure, skip, cancel.
# Why: A skipped dependent would mask the root cause.
# From: Issue #479, PR #476
@test "failed-jobs filter keeps only failure and cancelled" {
    run _ci_failed_jobs "$(printf 'build=success\ne2e=failure\npublish=skipped\nx=cancelled\n')"
    [ "${status}" -eq 0 ]
    [ "${output}" = "e2e x" ]
}

# What: Gates one successful and one skipped job.
# Why: Content-based impact selection skips whole jobs.
# From: Issue #479, PR #544
@test "gate passes when every job succeeded or was skipped" {
    JOBS="$(printf 'build=success\ne2e=skipped\n')" run ci_cmd_gate
    [ "${status}" -eq 0 ]
}

# What: Gates one successful and one failed job.
# Why: It is the one stable required-check name.
# From: Issue #479, PR #544
@test "gate fails closed when a real job failed" {
    JOBS="$(printf 'build=success\ne2e=failure\n')" run ci_cmd_gate
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GATE-0001"* ]]
}

# What: Gates a blank list, a colon pair, no value, a typo.
# Why: An empty job list must not pass the required gate.
# From: Issue #479, PR #544
@test "gate fails closed on a JOBS list with no or bad pairs" {
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

# What: Classifies README.md and doc/threat-model.md.
# Why: A documentation PR must not run the full CI.
# From: Issue #479, PR #544
@test "impact: a docs-only diff selects nothing (NOOP)" {
    run _ci_phases_for_paths < <(printf '%s\n' README.md doc/threat-model.md)
    [ "${status}" -eq 0 ]
    [ "${output}" = "NOOP" ]
}

# What: Classifies src/dopt.c into phases.
# Why: Real code changes must build, distribute and package.
# From: Issue #479, PR #544
@test "impact: a c-source diff selects build, e2e and package" {
    run _ci_phases_for_paths < <(printf '%s\n' src/dopt.c)
    [ "${status}" -eq 0 ]
    [ "$(tr '\n' ' ' <<< "${output}")" = "build e2e package " ]
}

# What: Classifies the SOT and ci.sh one at a time.
# Why: A pin bump or engine edit can break any of them.
# From: Issue #479, PR #544
@test "impact: a SOT or engine change selects every gated job" {
    local p
    for p in .github/yaml/build-manifest.yml .github/scripts/ci.sh; do
        run _ci_phases_for_paths < <(printf '%s\n' "${p}")
        [ "$(tr '\n' ' ' <<< "${output}")" = "build container e2e package verify " ]
    done
}

# What: Print each SOT phase no gated job of file $1 runs.
# Why: A phase nobody runs is policy that changes nothing.
# From: Issue #479, PR #544
_unwired_phases() {
    local ph gate wiring rc
    local phases=()
    _ci_mapfile phases _ci_all_phases || return 2
    [ "${#phases[@]}" -gt 0 ] || return 2
    wiring="$(awk '
        /^  [A-Za-z0-9_-]+:$/ { job = substr($1, 1, length($1) - 1) }
        /^    if:/ { gate[job] = $0 }
        match($0, /run: bash \.github\/scripts\/ci\.sh [a-z0-9-]+/) {
            c = substr($0, RSTART, RLENGTH); sub(/.* /, "", c); cmds[job] = cmds[job] " " c " " }
        END { for (j in gate) print j "|" gate[j] "|" cmds[j] }
    ' "$1")" || return 2
    for ph in "${phases[@]}"; do
        gate="contains(needs.plan.outputs.phases, '${ph}')"
        [ "${ph}" != build ] || gate="needs.plan.outputs.build == 'true'"
        rc=0
        awk -F'|' -v g="${gate}" -v ph="${ph}" 'index($2, g) && index($3, " " ph " ") { f = 1 }
            END { exit !f }' <<< "${wiring}" || rc=$?
        case "${rc}" in
            0) ;;
            1) printf '%s\n' "${ph}" ;;
            *) return 2 ;;
        esac
    done
}

# What: Checks validate.yml, then 2 copies with e2e cut off.
# Why: The copies prove the wiring check can fail at all.
# From: Issue #479, PR #544
@test "every SOT impact phase gates a validate.yml job" {
    local wf="${CI_REPO_ROOT}/.github/workflows/validate.yml" fx="${BATS_TEST_TMPDIR}/validate.yml"
    run _unwired_phases "${wf}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    sed "s/contains(needs.plan.outputs.phases, 'e2e')/false/" "${wf}" > "${fx}"
    run _unwired_phases "${fx}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "e2e" ]
    sed 's#scripts/ci\.sh e2e#scripts/ci.sh lint#' "${wf}" > "${fx}"
    run _unwired_phases "${fx}"
    [ "${output}" = "e2e" ]
}

# What: Print "file job" for each job of $@ with no timeout.
# Why: Unbounded, a hung job runs to the 6-hour default.
# From: Issue #479, PR #544
_jobs_without_timeout() {
    awk '
        FNR == 1 { if (cur != "" && !t) print F " " cur; F = FILENAME; j = 0; cur = ""; t = 0 }
        /^jobs:/ { j = 1; next }
        j && /^  [A-Za-z0-9_-]+:$/ { if (cur != "" && !t) print F " " cur; cur = substr($1, 1, length($1) - 1); t = 0 }
        j && cur != "" && /^    timeout-minutes: [0-9]+$/ { t = 1 }
        END { if (cur != "" && !t) print F " " cur }
    ' "$@"
}

# What: Checks all five workflows, then a copy missing one.
# Why: The copy proves the timeout check can fail at all.
# From: Issue #479, PR #544
@test "every workflow job has a timeout-minutes" {
    local wfs=("${CI_REPO_ROOT}"/.github/workflows/*.yml) fx="${BATS_TEST_TMPDIR}/validate.yml"
    [ "${#wfs[@]}" -eq 5 ]
    run _jobs_without_timeout "${wfs[@]}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    awk '/^  plan:$/ { p = 1 } p && /^    timeout-minutes:/ { p = 0; next } { print }' \
        "${CI_REPO_ROOT}/.github/workflows/validate.yml" > "${fx}"
    run _jobs_without_timeout "${fx}"
    [ "${output}" = "${fx} plan" ]
}

# What: Print each registered command ci_main of $1 misroutes.
# Why: A listed command without its own arm is a dead stub.
# From: Issue #479, PR #544
_dispatch_misroutes() {
    (
        local c fn out
        # shellcheck source=.github/scripts/ci.sh
        source "$1" || exit 2
        for c in ${CI_COMMANDS}; do
            fn="ci_cmd_${c//-/_}"
            # What: Stub the command's phase function to report itself.
            # Why: The real phases would run builds and API calls.
            eval "${fn}() { echo \"reached ${fn} \$*\"; }"
            out="$(ci_main "${c}" a1 2>&1)" || { printf '%s\n' "${c}"; continue; }
            [ "${out}" = "reached ${fn} a1" ] || printf '%s\n' "${c}"
        done
    )
}

# What: Print each ci_main arm of file $1 not in CI_COMMANDS.
# Why: An arm missing from CI_COMMANDS can never be reached.
# From: Issue #479, PR #544
_unregistered_arms() {
    local arm
    local arms=()
    _ci_mapfile arms awk '/^ci_main\(\)/ { m = 1 } m && /^}/ { exit }
        m && match($0, /^ +[a-z-]+\) ci_cmd_/) {
            a = substr($0, RSTART, RLENGTH); sub(/^ +/, "", a); sub(/\).*/, "", a); print a }' "$1" || return 2
    [ "${#arms[@]}" -gt 0 ] || return 2
    for arm in "${arms[@]}"; do
        [[ " ${CI_COMMANDS} " == *" ${arm} "* ]] || printf '%s\n' "${arm}"
    done
}

# What: Checks ci.sh, then copies: gc misrouted, zap added.
# Why: The copies prove both dispatch checks can fail at all.
# From: Issue #479, PR #544
@test "every CI_COMMANDS entry has its own dispatch arm" {
    local fx="${BATS_TEST_TMPDIR}/ci.sh"
    run _dispatch_misroutes "${CI_SH}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    run _unregistered_arms "${CI_SH}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    sed 's/^\( *gc)\) ci_cmd_gc /\1 ci_cmd_report /' "${CI_SH}" > "${fx}"
    run _dispatch_misroutes "${fx}"
    [ "${status}" -eq 0 ]
    [ "${output}" = "gc" ]
    sed 's/^\( *\)gate) ci_cmd_gate "\$@" ;;/&\n\1zap) ci_cmd_zap "$@" ;;/' "${CI_SH}" > "${fx}"
    run _unregistered_arms "${fx}"
    [ "${output}" = "zap" ]
}

# What: Classifies include_server/basics.py into phases.
# Why: A pump-mode Python change is not a packaging change.
# From: Issue #479, PR #544
@test "impact: an include-server .py diff selects build but not package" {
    run _ci_phases_for_paths < <(printf '%s\n' include_server/basics.py)
    [ "${status}" -eq 0 ]
    [ "$(tr '\n' ' ' <<< "${output}")" = "build e2e " ]
}

# What: Classifies LICENSE into phases.
# Why: DEFAULT=NOOP; nothing runs on an irrelevant change.
# From: Issue #479
@test "impact: an unmatched path yields NOOP" {
    run _ci_phases_for_paths < <(printf '%s\n' LICENSE)
    [ "${status}" -eq 0 ]
    [ "${output}" = "NOOP" ]
}

# What: Classifies src/dopt.c against the real SOT classes.
# Why: A misrouted path would run the wrong jobs.
# From: Issue #479
@test "classify: a src/*.c path maps to the c-source class" {
    run _ci_classify_paths < <(printf '%s\n' src/dopt.c)
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"c-source"* ]]
}

# What: Matches src/config-parser.* against its .c file.
# Why: '*' must match any text, not a literal star.
# From: Issue #479
@test "glob match: a prefix.* pattern matches its real extension" {
    run _ci_glob_match "src/config-parser.*" "src/config-parser.c"
    [ "${status}" -eq 0 ]
}

# What: Matches src/config-parser.* against src/unrelated.c.
# Why: A false positive would mislabel unrelated PRs.
# From: Issue #479
@test "glob match: a prefix.* pattern rejects an unrelated file" {
    run _ci_glob_match "src/config-parser.*" "src/unrelated.c"
    [ "${status}" -ne 0 ]
}

# What: Matches **/*.md on a root, a deep and a .mdx file.
# Why: Globstar semantics; a root file is zero dirs deep.
# From: Issue #479, PR #544
@test "glob: '**/' also matches files at the top level" {
    run _ci_glob_match "**/*.md" "README.md"
    [ "${status}" -eq 0 ]
    run _ci_glob_match "**/*.md" "doc/a/b.md"
    [ "${status}" -eq 0 ]
    run _ci_glob_match "**/*.md" "README.mdx"
    [ "${status}" -ne 0 ]
}

# What: Classifies CHANGELOG.md alone, then with two others.
# Why: The documentation label must skip CHANGELOG.md alone.
# From: Issue #479, PR #544
@test "classifier: a path map's exclude list removes a hit" {
    _fixture_manifest 'labels:' '  documentation:' '    paths: ["doc/**", "**/*.md"]' \
        '    exclude: ["CHANGELOG.md"]' '  ci:' '    paths: [".github/workflows/**"]'
    run _ci_classify_paths labels <<< "CHANGELOG.md"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    run _ci_classify_paths labels < <(printf '%s\n' CHANGELOG.md README.md .github/workflows/v.yml)
    [ "${output}" = "$(printf '%s\n' ci documentation)" ]
}

# What: Breaks sed, then the matcher, at each chain level.
# Why: A lost class skips the jobs that guard its paths.
# From: Issue #479, PR #544
@test "classifier: a glob matcher error is rc 2, never no match" {
    run _stubbed '_fail sed 1 "sed broke"' _ci_glob_match "src/*.c" "src/dopt.c"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"sed broke"* ]]
    _fixture_manifest 'labels:' '  documentation:' '    paths: ["**/*.md"]' '    exclude: ["CHANGELOG.md"]'
    # What: Stub the matcher: error only on the CHANGELOG.md glob.
    # Why: Only the exclude list holds that glob in the fixture.
    _ci_glob_match() { [ "$1" != "CHANGELOG.md" ] || return 2; }
    run _ci_classify_paths labels <<< "CHANGELOG.md"
    [ "${status}" -eq 2 ]
    _fail _ci_glob_match 2
    run _ci_classify_paths labels <<< "README.md"
    [ "${status}" -eq 2 ]
}

# What: Labels PR 5, whose diff touches one workflow file.
# Why: The board and release notes read these labels.
# From: Issue #479, PR #544
@test "label-pr applies path labels and the title category" {
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

# What: Maps a feat, fix, docs and security title.
# Why: Each of these four types gets its own notes section.
# From: Issue #479
@test "pr category: maps AG-GH-014 types to release-drafter labels" {
    [ "$(_ci_pr_category_label 'feat(pump): add IPv6')" = "enhancement" ]
    [ "$(_ci_pr_category_label 'fix(protocol): correct frame bug')" = "bug" ]
    [ "$(_ci_pr_category_label 'docs(governance): add rule')" = "documentation" ]
    [ "$(_ci_pr_category_label 'security(config): patch leak')" = "security" ]
}

# What: Maps a chore(ci) title.
# Why: The release notes have exactly these 4 categories.
# From: Issue #479
@test "pr category: an uncategorized type prints nothing" {
    [ -z "$(_ci_pr_category_label 'chore(ci): bump a dependency')" ]
}

# What: Maps a typeless title; parses a breaking-change type.
# Why: Labels and the title check share one title parser.
# From: Issue #479, PR #544
@test "pr category: a title not in AG-GH-014 shape gets no label" {
    run _ci_pr_category_label 'fix stuff'
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    run _ci_title_type 'fix(ci)!: x'
    [ "${output}" = "fix" ]
    run _ci_title_type 'fix stuff'
    [ "${status}" -eq 1 ]
}

# What: Scans a tree holding one LF-only file.
# Why: CR is the only byte the guard may reject.
# From: Issue #479
@test "line-endings guard passes on an LF-only tree" {
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"; printf 'clean line\n' > "${fx}/ok.sh"
    run ci_guard_line_endings "${fx}"
    [ "${status}" -eq 0 ]
}

# What: Scans a tree holding one CRLF file.
# Why: A CR breaks a shell script run on Linux.
# From: Issue #479
@test "line-endings guard fails closed on a CRLF file" {
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"; printf 'bad line\r\n' > "${fx}/crlf.sh"
    run ci_guard_line_endings "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-EOL-0001"* ]]
}

# What: Scans a yml with a 64-hex sha256 digest.
# Why: A full digest is the only accepted pin form.
# From: Issue #479
@test "full-sha guard passes on a 64-hex digest" {
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"
    printf 'image: "debian@sha256:fac46bff2e02f51425b6e33b0e1169f55dfb053d83511ca28aa50c09fd5ed7a4"\n' > "${fx}/f.yml"
    run ci_guard_full_sha "${fx}"
    [ "${status}" -eq 0 ]
}

# What: Scans a yml with an 8-hex sha256 digest.
# Why: A short digest can match more than one image.
# From: Issue #479
@test "full-sha guard fails closed on an abbreviated digest" {
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"; printf 'image: "debian@sha256:fac46bff"\n' > "${fx}/f.yml"
    run ci_guard_full_sha "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-SHA-0001"* ]]
}

# What: Runs both guards on a root that does not exist.
# Why: A read error must never look like a clean tree.
# From: Issue #479, PR #544
@test "guards fail closed on an unreadable tree, not pass" {
    run ci_guard_line_endings "${BATS_TEST_TMPDIR}/nope"
    [ "${status}" -eq 2 ]
    run ci_guard_full_sha "${BATS_TEST_TMPDIR}/nope"
    [ "${status}" -eq 2 ]
}

# What: Runs three guards on an empty tree and a missing file.
# Why: A guard that checked nothing must not report a pass.
# From: Issue #479, PR #544
@test "guards fail closed when they find nothing to check" {
    local fx="${BATS_TEST_TMPDIR}/fx"
    mkdir -p "${fx}"
    run ci_guard_comment_format "${fx}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GUARD-COMMENT-0002"* ]]
    run ci_guard_shellcheck_directives "${fx}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GUARD-SHELLCHECK-0004"* ]]
    run ci_guard_orchestrator_only
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GUARD-ORCH-0002"* ]]
    run ci_guard_orchestrator_only "${fx}/none.yml"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GUARD-ORCH-0003"* ]]
}

# What: Zero-SHA base, then a failing diff; a missing log.
# Why: Neither may read as no change or as a parse result.
# From: Issue #479, PR #544
@test "changelog and comfychair fail closed on bad input" {
    BASE=0000000000000000000000000000000000000000 HEAD=HEAD PR_LABELS="" run _ci_check_changelog
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-META-CHANGELOG-0002"* ]]
    _fail _ci_changed_paths 1 "[CI-ERROR-DIFF-0001] cannot diff"
    BASE=HEAD HEAD=HEAD PR_LABELS="" run _ci_check_changelog
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-DIFF-0001"* ]]
    [[ "${output}" != *"CI-ERROR-META-CHANGELOG-0001"* ]]
    run _ci_parse_comfychair "${BATS_TEST_TMPDIR}/nope.log"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-TEST-0007"* ]]
}

# What: Runs the pin guard on this repository.
# Why: build-manifest.yml is the sole pin owner (Thesis 1).
# From: Issue #479, PR #544
@test "pin guard passes the repo's own Dockerfiles and workflows" {
    run ci_guard_pins_in_sot "${CI_REPO_ROOT}"
    [ "${status}" -eq 0 ]
}

# What: Scans ARG, stage and :local FROMs and an SOT action.
# Why: None of them can pull an image the SOT did not pin.
# From: Issue #479, PR #544
@test "pin guard passes ARG FROMs, stage aliases and :local images" {
    local fx="${BATS_TEST_TMPDIR}/fx"
    _fixture_actions
    mkdir -p "${fx}/d" "${fx}/.github/workflows"
    printf '%s\n' 'ARG BASE' 'FROM ${BASE} AS one' 'FROM one AS two' 'FROM x-y:local' > "${fx}/d/Dockerfile"
    printf '%s\n' 'jobs:' '  container:' '    steps:' '      - run: bash .github/scripts/ci.sh build' \
        "      - uses: ${FX_PIN}" > "${fx}/.github/workflows/w.yml"
    run ci_guard_pins_in_sot "${fx}"
    [ "${status}" -eq 0 ]
}

# What: Scans a Dockerfile and workflow with six pin forms.
# Why: Each one is a second pin owner beside the SOT.
# From: Issue #479, PR #544
@test "pin guard fails closed on every pin form outside the SOT" {
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

# What: Scans a workflow that uses no SOT action.
# Why: Dependabot bumps only YAML; an unused pin goes stale.
# From: Issue #479, PR #544
@test "pin guard fails closed on a SOT action no workflow uses" {
    local fx="${BATS_TEST_TMPDIR}/fx"
    _fixture_actions
    mkdir -p "${fx}/.github/workflows"
    printf '%s\n' '      - run: bash .github/scripts/ci.sh build' > "${fx}/.github/workflows/w.yml"
    run ci_guard_pins_in_sot "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-PIN-0003"*"${FX_PIN}"* ]]
}

# What: Writes the CFL entry and runs it on a stub ci.sh.
# Why: oss-fuzz compile runs bash -eux $SRC/build.sh first.
# From: Issue #267, Issue #479, PR #544
@test "cfl toolchain writes the build.sh entry CFL runs" {
    local src="${BATS_TEST_TMPDIR}/src"
    mkdir -p "${src}/distcc-ng/.github/scripts"
    printf '%s\n' 'echo "stub ci.sh $*"' > "${src}/distcc-ng/.github/scripts/ci.sh"
    _pass _ci_apt_install
    SRC="${src}" run _ci_image_cfl_toolchain
    [ "${status}" -eq 0 ]
    [ "$(stat -c %a "${src}/build.sh")" = "755" ]
    SRC="${src}" run bash -eux "${src}/build.sh"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"stub ci.sh workload fuzz-build"* ]]
    run _ci_image_cfl_toolchain
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"SRC required"* ]]
}

# What: Greps the CFL Dockerfile for the SOT builder tag.
# Why: CFL builds without build-args, so FROM is a literal.
# From: Issue #267, Issue #479, PR #544
@test "the CFL Dockerfile FROM is the SOT base-builder tag" {
    local tag
    tag="$(_ci_sot_scalar security.cfl_base.tag)"
    grep -qx "FROM ${tag}" "${CI_REPO_ROOT}/.clusterfuzzlite/Dockerfile"
}

# What: Aliases s.a and records the docker calls.
# Why: A builder without build-args may only see that tag.
# From: Issue #267, Issue #479, PR #544
@test "image alias pulls the SOT pin and tags it locally" {
    _fixture_manifest 'base:' '  img: "b@sha256:0"' 's:' '  a:' '    from: "base.img"' '    tag: "a:local"'
    _capture_docker
    run _ci_image_alias s.a
    [ "${status}" -eq 0 ]
    [ "$(tr '\n' ' ' < "${BATS_TEST_TMPDIR}/argv")" = "pull b@sha256:0 tag b@sha256:0 a:local " ]
}

# What: Routes a PR, two dispatches and both security crons.
# Why: The workflow holds no cron and no event decision.
# From: Issue #479, PR #544
@test "route security: crons, PRs and dispatch refs pick the jobs" {
    local ev="${BATS_TEST_TMPDIR}/ev.json" out="${BATS_TEST_TMPDIR}/out"
    _fixture_manifest 'schedules:' '  security_scans:' '    workflow: "security"' '    cron: "0 5 * * 0"' \
        '  openssf:' '    workflow: "security"' '    cron: "0 6 1,15 * *"' 'security:' '  cfl_run:' \
        '    sanitizers: ["address"]' '  codeql:' '    languages: ["c-cpp", "python"]'
    # What: Run route security for one event and ref.
    # Why: Each case needs a fresh output file.
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

# What: Routes the weekly cron, a gc dispatch, a bad workflow.
# Why: gc only ever runs on an explicit dispatch.
# From: Issue #479, PR #544
@test "route housekeeping: the weekly cron or a dispatch task" {
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

# What: Real tree, then a drifted cron, option and milestones.
# Why: All are literal YAML; the SOT owns their values.
# From: Issue #479, PR #544
@test "mirror guard passes the real tree and fails closed on drift" {
    local fx="${BATS_TEST_TMPDIR}/fx"
    run ci_guard_sot_mirrors "${CI_REPO_ROOT}"
    [ "${status}" -eq 0 ]
    mkdir -p "${fx}/.github/workflows"
    _fixture_manifest 'schedules:' '  n:' '    workflow: "w"' '    cron: "0 1 * * *"' \
        'release:' '  ghcr_packages: ["p"]' 'bot_milestone:' '  number: "3"'
    printf '%s\n' 'on:' '  schedule:' "    - cron: '0 2 * * *'" > "${fx}/.github/workflows/w.yml"
    printf '%s\n' 'on:' '  workflow_dispatch:' '    inputs:' '      package:' '        options:' \
        '          - all' '          - q' '        default: all' > "${fx}/.github/workflows/housekeeping.yml"
    printf '%s\n' 'updates:' '  - package-ecosystem: a' '    milestone: 4' '  - package-ecosystem: b' \
        > "${fx}/.github/dependabot.yml"
    run ci_guard_sot_mirrors "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-MIRROR-0001"*"0 2 * * *"* ]]
    [[ "${output}" == *"CI-ERROR-GUARD-MIRROR-0002"* ]]
    [[ "${output}" == *"CI-ERROR-GUARD-MIRROR-0003"* ]]
}

# What: Runs three checks with the checkout check failing.
# Why: The failed check must be named, not only counted.
# From: Issue #479, PR #544
@test "verify starts one container and runs every in-image check" {
    local log="${BATS_TEST_TMPDIR}/docker"
    # What: Stub docker: log calls; in-image checkout fails.
    # Why: The log counts run and exec calls separately.
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

# What: Scans blocks, directives and heredocs, then a banner.
# Why: Heredoc text and tool directives are not prose.
# From: Issue #479, PR #544
@test "comment guard passes standard blocks, directives and heredocs" {
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

# What: Scans an initd file holding both banned texts.
# Why: AG-INT-003: the mere presence is the violation.
# From: Issue #479, PR #544
@test "directive guard fails on each banned shell text" {
    local fx="${BATS_TEST_TMPDIR}/fx"
    local texts=()
    _ci_mapfile texts _ci_banned_shell_texts
    [ "${#texts[@]}" -eq 2 ]
    mkdir -p "${fx}/packaging"
    printf '%s\n' '#!/sbin/openrc-run' "# ${texts[0]}anything" "echo '${texts[1]}'" \
        > "${fx}/packaging/svc.initd"
    run ci_guard_shellcheck_directives "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"svc.initd:2: banned shell text ${texts[0]}"* ]]
    [[ "${output}" == *"svc.initd:3: banned shell text ${texts[1]}"* ]]
}

# What: Scans a tree whose source= names a real file.
# Why: Only the banned texts fail; source= stays usable.
# From: Issue #479, PR #544
@test "directive guard passes a shell tree without banned text" {
    local fx="${BATS_TEST_TMPDIR}/fx"
    mkdir -p "${fx}/lib" "${fx}/.github"
    printf '%s\n' '#!/usr/bin/env bash' 'y=1' > "${fx}/lib/real.sh"
    printf '%s\n' '#!/usr/bin/env bash' '# shellcheck source=lib/real.sh' '. lib/real.sh' \
        > "${fx}/.github/a.sh"
    run ci_guard_shellcheck_directives "${fx}"
    [ "${status}" -eq 0 ]
}

# What: Runs ci_cmd_lint on a clean tree, then a banned text.
# Why: The guard is only proof if the lint entry runs it.
# From: Issue #479, PR #544
@test "the real lint entry fails on a banned shell text" {
    local fx="${BATS_TEST_TMPDIR}/fx"
    local texts=()
    _ci_mapfile texts _ci_banned_shell_texts
    mkdir -p "${fx}/contrib"
    printf '%s\n' '#!/bin/sh' 'x=1' > "${fx}/contrib/tool"
    _pass ci_guard_line_endings ci_guard_full_sha ci_guard_pins_in_sot ci_guard_sot_mirrors \
        ci_guard_orchestrator_only ci_guard_comment_format _ci_lint_actionlint _ci_lint_shellcheck
    CI_REPO_ROOT="${fx}" run ci_cmd_lint
    [ "${status}" -eq 0 ]
    printf '%s\n' '#!/bin/sh' "# ${texts[0]}SC2086" 'x=1' > "${fx}/contrib/tool"
    CI_REPO_ROOT="${fx}" run ci_cmd_lint
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"contrib/tool:2: banned shell text"* ]]
}

# What: Reads the ban list from a SOT lacking it, then empty.
# Why: An empty list would pass every shell file silently.
# From: Issue #479, PR #544
@test "banned texts fail closed on a missing or empty SOT list" {
    _fixture_manifest 'ci_engine:' '  selftest_apt: "bats"'
    run _ci_banned_shell_texts
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SOT-0002"* ]]
    run ci_guard_shellcheck_directives "${CI_REPO_ROOT}"
    [ "${status}" -eq 2 ]
    _fixture_manifest 'ci_engine:' '  banned_shell_texts: []'
    run _ci_banned_shell_texts
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GUARD-SHELLCHECK-0003"* ]]
}

# What: Scans a file whose heredoc has no terminator.
# Why: Skipping to EOF would hide every later comment.
# From: Issue #479, PR #544
@test "comment guard fails closed on a heredoc that never ends" {
    local fx="${BATS_TEST_TMPDIR}/fx" hd='<<'
    mkdir -p "${fx}/.github"
    printf '%s\n' "cat ${hd}EOF" 'text' '# free prose after' > "${fx}/.github/b.sh"
    run ci_guard_comment_format "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"b.sh:1: heredoc EOF never ends"* ]]
}

# What: Scans prose, a What-only block and a 61-char line.
# Why: AG-CODE-001 allows only the What/Why/From form.
# From: Issue #479, PR #544
@test "comment guard fails closed on prose, a missing Why, a long line" {
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

# What: Scans an uncommented function, nested stub and test.
# Why: AG-CODE-001: every function MUST have a comment.
# From: Issue #479, PR #544
@test "comment guard fails closed on a function without a block" {
    local fx="${BATS_TEST_TMPDIR}/fx"
    mkdir -p "${fx}/.github"
    printf '%s\n' '# What: Do a thing.' '# Why: A reason.' 'ok() { :; }' '' 'bad() { :; }' \
        '# What: A test.' '# Why: A reason.' '@test "x" {' '    inner() { :; }' '}' '' \
        '@test "y" {' '}' > "${fx}/.github/t.bats"
    run ci_guard_comment_format "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"t.bats:5: function without a comment block above"* ]]
    [[ "${output}" == *"t.bats:9: function without a comment block above"* ]]
    [[ "${output}" == *"t.bats:12: function without a comment block above"* ]]
    [[ "${output}" != *"t.bats:3:"* ]]
    [[ "${output}" != *"t.bats:8:"* ]]
}

# What: Checks a step whose run: is one ci.sh command.
# Why: #479 lets a run: step call ci.sh and nothing else.
# From: Issue #479
@test "orchestrator guard passes on a single-command run: step" {
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"
    printf 'jobs:\n  x:\n    steps:\n      - run: bash .github/scripts/ci.sh build\n' > "${fx}/wf.yml"
    run ci_guard_orchestrator_only "${fx}/wf.yml"
    [ "${status}" -eq 0 ]
}

# What: Checks a run: block holding an if statement.
# Why: #479 bans inline logic; it belongs in ci.sh.
# From: Issue #479
@test "orchestrator guard fails closed on inline logic in a run: block" {
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"
    printf 'jobs:\n  x:\n    steps:\n      - run: |\n          if [ -x foo ]; then bar; fi\n' > "${fx}/wf.yml"
    run ci_guard_orchestrator_only "${fx}/wf.yml"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-ORCH-0001"* ]]
}

# What: Checks an SOT action whose inputs are step outputs.
# Why: Transport-only actions are the one allowed uses: form.
# From: Issue #479, PR #544
@test "orchestrator guard passes a SOT action fed by step outputs" {
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"
    _fixture_actions
    printf '%s\n' 'jobs:' '  x:' '    steps:' '      - run: |' '          bash .github/scripts/ci.sh cache default' \
        "      - if: steps.c.outputs.key != ''" "        uses: ${FX_PIN}" '        with:' \
        '          path: ${{ steps.c.outputs.path }}' '          restore-keys: ${{ steps.c.outputs.restore_keys }}' \
        '        env:' '          A: b' '      - run: bash .github/scripts/ci.sh build' > "${fx}/wf.yml"
    run ci_guard_orchestrator_only "${fx}/wf.yml"
    [ "${status}" -eq 0 ]
}

# What: Checks a local, a tag-ref and a wrong-SHA uses: line.
# Why: Only the exact SOT literal may run an action.
# From: Issue #479, PR #544
@test "orchestrator guard fails closed on a uses: outside the SOT" {
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

# What: Checks an SOT action given a literal and a run_id key.
# Why: Keys, paths and names are ci.sh decisions, not YAML.
# From: Issue #479, PR #544
@test "orchestrator guard fails closed on a decided uses: input" {
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"
    _fixture_actions
    printf '%s\n' 'jobs:' '  x:' '    steps:' "      - uses: ${FX_PIN}" '        with:' '          path: ~/.ccache' \
        "          key: ccache-\${{ github.run_id }}" > "${fx}/wf.yml"
    run ci_guard_orchestrator_only "${fx}/wf.yml"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"wf.yml:6: uses: input is not a ci.sh step output: ~/.ccache"* ]]
    [[ "${output}" == *"wf.yml:7: uses: input is not a ci.sh step output"* ]]
}

# What: Install the argv-recording docker stub for one test.
# Why: Owner tests assert exact flags without a daemon.
# From: Issue #479, PR #544
_capture_docker() {
    # What: Stub docker: append each argument as one argv line.
    # Why: One arg per line keeps arguments with spaces apart.
    docker() { printf '%s\n' "$@" >> "${BATS_TEST_TMPDIR}/argv"; }
}

# What: Builds s.x with --pull and records the docker argv.
# Why: The only path a base-image pin may take into a build.
# From: Issue #359, Issue #479, PR #544
@test "image build passes SOT ARGs, explicit target and local tag" {
    local d; d="$(printf 'a%.0s' {1..64})"
    _fixture_manifest 'base:' "  img: \"b@sha256:${d}\"" 's:' '  x:' '    dockerfile: "d/Dockerfile"' \
        '    target: "t"' '    args: ["A=base.img"]' '    tag: "x:local"'
    _capture_docker
    run _ci_image_build s.x "" --pull
    [ "${status}" -eq 0 ]
    [ "$(tr '\n' ' ' < "${BATS_TEST_TMPDIR}/argv")" = "build --pull --file ${CI_REPO_ROOT}/d/Dockerfile --target t --build-arg A=b@sha256:${d} --tag x:local ${CI_REPO_ROOT} " ]
}

# What: Builds a described spec without, then with a version.
# Why: One OCI metadata owner; Dockerfiles carry no LABEL.
# From: Issue #359, Issue #479, PR #544
@test "image build labels a published spec and needs its version" {
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

# What: Builds a spec with a bad ARG, then a missing spec.
# Why: An unpinned ARG would build FROM an empty base.
# From: Issue #479, PR #544
@test "image build fails closed on a bad spec before docker runs" {
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

# What: Runs one container outside a stack, docker recorded.
# Why: --init reaps zombies; without it containers can hang.
# From: Issue #479, PR #544
@test "container run: --init and a read-only checkout, --rm alone" {
    _capture_docker
    run _ci_container_run img -e K=V -- bash x
    [ "${status}" -eq 0 ]
    [ "$(tr '\n' ' ' < "${BATS_TEST_TMPDIR}/argv")" = "run --init -v ${CI_REPO_ROOT}:/ci:ro --rm -e K=V img bash x " ]
}

# What: Tears down ci-x-1 and ci-x, then with ls broken.
# Why: Teardown must delete its own net and no other.
# From: Issue #479, PR #544
@test "stack teardown removes only a listed net; a list error fails" {
    # What: Stub docker: list ci-x-1; FX_LS_FAIL breaks the list.
    # Why: rm calls land in a file the test reads back.
    docker() {
        case "$1 $2" in
            "network ls")
                [ -z "${FX_LS_FAIL:-}" ] || { echo "ls broke" >&2; return 1; }
                printf 'bridge\nci-x-1\n' ;;
            "network rm") echo "$3" >> "${BATS_TEST_TMPDIR}/rm" ;;
        esac
    }
    run _ci_stack_teardown ci-x-1
    [ "${status}" -eq 0 ]
    [ "$(cat "${BATS_TEST_TMPDIR}/rm")" = "ci-x-1" ]
    run _ci_stack_teardown ci-x
    [ "${status}" -eq 0 ]
    [ "$(cat "${BATS_TEST_TMPDIR}/rm")" = "ci-x-1" ]
    FX_LS_FAIL=1 run _ci_stack_teardown ci-x-1
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"ls broke"* ]]
    [[ "${output}" == *"CI-ERROR-STACK-0001"* ]]
    [ "$(cat "${BATS_TEST_TMPDIR}/rm")" = "ci-x-1" ]
}

# What: Runs one detached container inside stack n1.
# Why: --rm would drop a crashed server's log too early.
# From: Issue #479, PR #544
@test "container run: inside a stack it joins net and label, no --rm" {
    _capture_docker
    CI_STACK=n1 run _ci_container_run img -d --
    [ "${status}" -eq 0 ]
    [ "$(tr '\n' ' ' < "${BATS_TEST_TMPDIR}/argv")" = "run --init -v ${CI_REPO_ROOT}:/ci:ro --network n1 --label ci-stack=n1 -d img " ]
}

# What: Runs a container with options but no -- separator.
# Why: A guessed split could run an option as the image.
# From: Issue #479, PR #544
@test "container run fails closed without -- before the command" {
    _forbid docker
    run _ci_container_run img -e K=V
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CONTAINER-0003"* ]]
    [[ "${output}" != *"must not run"* ]]
}

# What: Pushes with REGISTRY_TOKEN unset, docker forbidden.
# Why: An anonymous or stale-credential push must not happen.
# From: Issue #479, PR #544
@test "registry push never pushes after a failed login" {
    _forbid docker
    unset REGISTRY_TOKEN
    GITHUB_ACTOR=octo run _ci_registry_push some/image:tag
    [ "${status}" -ne 0 ]
    [[ "${output}" != *"must not run"* ]]
}

# What: Polls a probe passing on try 3, then a false one.
# Why: One bounded poll owner for every readiness wait.
# From: Issue #479, PR #544
@test "wait-until retries a probe and fails after N tries" {
    _pass sleep
    # What: Probe that succeeds on its third call.
    # Why: Two failures before a pass exercise the retry.
    _probe() { echo x >> "${BATS_TEST_TMPDIR}/tries"; [ "$(wc -l < "${BATS_TEST_TMPDIR}/tries")" -ge 3 ]; }
    run _ci_wait_until 5 1 _probe
    [ "${status}" -eq 0 ]
    [ "$(wc -l < "${BATS_TEST_TMPDIR}/tries")" -eq 3 ]
    run _ci_wait_until 2 1 false
    [ "${status}" -eq 1 ]
}

# What: Polls a probe that returns 5 on its first call.
# Why: A hard error must never be retried as transient.
# From: Issue #479, PR #544
@test "wait-until stops at once on a probe error and names tries" {
    _pass sleep
    # What: Probe that logs its attempt, then returns 5.
    # Why: rc >= 2 is the hard-error class that must stop it.
    _probe() { echo "${CI_ATTEMPT}/${CI_TRIES}" >> "${BATS_TEST_TMPDIR}/tries"; return 5; }
    run _ci_wait_until 4 1 _probe
    [ "${status}" -eq 5 ]
    [ "$(cat "${BATS_TEST_TMPDIR}/tries")" = "1/4" ]
}

# What: Expects a needle from a failing and a passing command.
# Why: Fixtures exit non-zero; a negated check can fail too.
# From: Issue #264, Issue #479, PR #544
@test "expect-output checks presence, and absence with !re" {
    run _ci_expect_output t 'needle' bash -c 'echo needle; exit 3'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"t: OK (exit 3)"* ]]
    run _ci_expect_output t '!needle' echo needle
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-SELFTEST-0001"* ]]
    run _ci_expect_output t '!needle' echo hay
    [ "${status}" -eq 0 ]
}

# What: Install a curl stub that copies file $1 to any -o.
# Why: Fetch tests need a deterministic, offline download.
# From: Issue #479, PR #544
_fake_curl() {
    FAKE_DOWNLOAD="$1"
    # What: Stub curl: copy FAKE_DOWNLOAD to each -o argument.
    # Why: _ci_download names its target only through -o.
    curl() { while [ "$#" -gt 0 ]; do if [ "$1" = "-o" ]; then cp "${FAKE_DOWNLOAD}" "$2"; fi; shift; done; }
}

# What: Downloads with curl failing every attempt (rc 22).
# Why: A failed fetch must never fail without an error line.
# From: Issue #479, PR #544
@test "a failed download names its URL and fails" {
    _fail curl 22
    _pass sleep
    run _ci_download "https://h/x.tar.gz" "${BATS_TEST_TMPDIR}/x"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"attempt 3/3 failed"* ]]
    [[ "${output}" == *"CI-ERROR-FETCH-0003"*"https://h/x.tar.gz"* ]]
}

# What: Downloads with curl failing only the first call.
# Why: curl --retry does not retry a dropped connection.
# From: Issue #479, PR #544
@test "a dropped connection is retried by a later attempt" {
    local n="${BATS_TEST_TMPDIR}/n"
    echo 0 > "${n}"
    # What: Stub curl: the first call fails, later ones pass.
    # Why: A count file outlives each call's subshell.
    curl() { local c; c="$(cat "${n}")"; echo $((c + 1)) > "${n}"; [ "${c}" -ge 1 ]; }
    _pass sleep
    run _ci_download "https://h/x.tar.gz" "${BATS_TEST_TMPDIR}/x"
    [ "${status}" -eq 0 ]
    [ "$(cat "${n}")" -eq 2 ]
    [[ "${output}" == *"attempt 1/3 failed"* ]]
}

# What: Fetches a fixture tarball whose sha256 the SOT pins.
# Why: Release URLs use the tag with and without its v.
# From: Issue #479, PR #544
@test "tool fetch expands the url and extracts on a matching sha256" {
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

# What: Installs a pinned binary, a bad sha, a bad target.
# Why: An image must never carry an unchecked tool.
# From: Issue #479, PR #544
@test "tool install puts the checked binary at its target only" {
    local sum to="${BATS_TEST_TMPDIR}/bin/osv"
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    printf 'exe' > "${BATS_TEST_TMPDIR}/raw"
    sum="$(sha256sum "${BATS_TEST_TMPDIR}/raw" | cut -d' ' -f1)"
    _fixture_manifest 'x:' '  osv:' '    version: "v2"' '    url: "https://h/osv"' \
        "    sha256: \"${sum}\"" '    archive: "binary"' '    bin: "osv-scanner"' \
        '  bad:' '    version: "v2"' '    url: "https://h/osv"' \
        "    sha256: \"$(printf '0%.0s' {1..64})\"" '    archive: "binary"' '    bin: "osv-scanner"'
    _fake_curl "${BATS_TEST_TMPDIR}/raw"
    run _ci_install_tool x.osv "${to}"
    [ "${status}" -eq 0 ]
    [ "$(cat "${to}")" = "exe" ]
    [ "$(stat -c %a "${to}")" = "755" ]
    run _ci_install_tool x.bad "${BATS_TEST_TMPDIR}/bin/bad"
    [ "${status}" -eq 2 ]
    [ ! -e "${BATS_TEST_TMPDIR}/bin/bad" ]
    run _ci_install_tool x.osv "${BATS_TEST_TMPDIR}/nope/osv"
    [ "${status}" -eq 1 ]
}

# What: Fetches an unarchived binary with archive: binary.
# Why: Some upstreams ship no archive, only the executable.
# From: Issue #479, PR #544
@test "tool fetch keeps a bare binary under its bin name" {
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

# What: Fetches over a stale partial dir rm cannot remove.
# Why: Extracting over leftovers would mix old and new files.
# From: Issue #479, PR #544
@test "tool fetch stops when a partial tool dir cannot be removed" {
    _fixture_manifest 'x:' '  tool:' '    version: "v1"' '    url: "https://h/t.tgz"' \
        "    sha256: \"$(printf '0%.0s' {1..64})\"" '    bin: "tool"'
    mkdir -p "${BATS_TEST_TMPDIR}/tool-v1"
    : > "${BATS_TEST_TMPDIR}/tool-v1/stale"
    _forbid curl
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _stubbed '_fail rm 1 "rm broke"' _ci_fetch_tool x.tool
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"rm broke"* ]]
    [[ "${output}" != *"must not run"* ]]
}

# What: Fetches a file with a wrong sha256, then with none.
# Why: A tampered or unpinned binary must never run.
# From: Issue #479, PR #544
@test "tool fetch fails closed on a sha256 mismatch or no pin" {
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

# What: Install offline gh and docker stubs for SOT refresh.
# Why: Release lists and registry digests must be offline.
# From: Issue #479, PR #544
_fake_registry() {
    # What: Stub docker: answer every inspect with one digest.
    # Why: Every image pin then has one known newer digest.
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

# What: Refreshes two image pins, a tool and a manual pin.
# Why: ci.sh is the sole pin owner; sort -V beats backports.
# From: Issue #479, PR #544
@test "sot refresh moves digests and tool versions, one row each" {
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

# What: Refreshes a SOT image pinned as name@sha256 only.
# Why: Refreshing it would silently track latest.
# From: Issue #479, PR #544
@test "sot refresh fails closed on an image pin without a tag" {
    _fixture_manifest 'base_images:' "  deb: \"debian@sha256:$(printf 'a%.0s' {1..64})\"" 'external_services:' \
        '  none: "x:1@sha256:0"' 'external_versions:' '  m:' '    version: "1"'
    _fake_registry
    run _ci_sot_refresh
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SOT-0004"* ]]
}

# What: Install the OSV gate stubs; $1 is the base SOT text.
# Why: The gate logic must be provable without network.
# From: Issue #267, Issue #479, PR #544
_fake_osv() {
    OSV_BASE_SOT="$1"
    _print _ci_tool_bin /bin/true
    _print _ci_osv_tool_dirs "${BATS_TEST_TMPDIR}"
    _pass _ci_osv_run
    _print _ci_event_range abc def
    # What: Stub git: ls-tree lists the SOT, show prints it.
    # Why: The base side must read OSV_BASE_SOT, not the tree.
    git() {
        case "$*" in
            *" ls-tree "*) [ -n "${OSV_GIT_FAIL:-}" ] && return 128; printf '%s\n' .github/yaml/build-manifest.yml ;;
            *" show "*) printf '%s\n' "${OSV_BASE_SOT}" ;;
        esac
    }
    # What: Stub ids: OSV_HEAD_IDS for the head SOT, else base.
    # Why: The gate must fail only on head-added ids.
    _ci_osv_vulns() { if [ "$2" = "${CI_MANIFEST}" ]; then printf '%s\n' ${OSV_HEAD_IDS}; else printf '%s\n' ${OSV_BASE_IDS}; fi; }
}

# What: Scans a head adding GO-3, then one removing GO-2.
# Why: Only a vulnerability the PR adds may block it.
# From: Issue #267, Issue #479, PR #544
@test "OSV PR gate fails only on ids the head's tools add" {
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

# What: Uploads a 4 MB SARIF through a decoding gh stub.
# Why: A large SARIF in argv fails with E2BIG.
# From: Issue #479, PR #544
@test "SARIF upload sends the gzip+base64 file in the request body" {
    local big="${BATS_TEST_TMPDIR}/big.sarif"
    head -c 3000000 /dev/urandom | base64 > "${big}"
    # What: Stub gh: decode the --input body, echo an id.
    # Why: The decoded copy is compared byte for byte below.
    gh() {
        local in=""
        while [ "$#" -gt 0 ]; do [ "$1" = "--input" ] && in="$2"; shift; done
        jq -r .sarif "${in}" | base64 -d | gunzip > "${BATS_TEST_TMPDIR}/back"
        printf 'HTTP/2.0 202 Accepted\nContent-Type: application/json\r\n\r\n'
        jq '{id: (.commit_sha + " " + .ref)}' "${in}"
    }
    GH_TOKEN=x GITHUB_REPOSITORY=o/r GITHUB_SHA=abc GITHUB_REF=refs/heads/x run ci_cmd_sarif_upload "${big}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"SARIF upload id abc refs/heads/x"* ]]
    cmp "${big}" "${BATS_TEST_TMPDIR}/back"
}

# What: Uploads against empty 500 and 200, a 404, no answer.
# Why: A transient API error must not fail a scan job.
# From: Issue #479, PR #544
@test "SARIF upload retries a 5xx or empty answer, never a 4xx" {
    local n="${BATS_TEST_TMPDIR}/n" f="${BATS_TEST_TMPDIR}/s.sarif"
    echo '{}' > "${f}"
    _pass sleep
    echo 0 > "${n}"
    # What: Stub gh --include: an empty 500, empty 200, an id.
    # Why: gh names no status for an empty 5xx, as in CI.
    gh() { local c; c="$(cat "${n}")"; echo $((c + 1)) > "${n}"
        case "${c}" in
            0) printf 'HTTP/2.0 500 Internal Server Error\nContent-Length: 0\r\n\r\n'
               echo "unexpected end of JSON input" >&2; return 1 ;;
            1) printf 'HTTP/2.0 200 OK\n\r\n' ;;
            *) printf 'HTTP/2.0 202 Accepted\n\r\n{"id":"ok"}\n' ;;
        esac; }
    GH_TOKEN=x GITHUB_REPOSITORY=o/r GITHUB_SHA=a GITHUB_REF=r run ci_cmd_sarif_upload "${f}"
    [ "${status}" -eq 0 ]
    [ "$(cat "${n}")" -eq 3 ]
    [[ "${output}" == *"attempt 1/3 failed: HTTP 500: unexpected end of JSON input"* ]]
    [[ "${output}" == *"attempt 2/3 failed: HTTP 200"* ]]
    [[ "${output}" == *"SARIF upload id ok"* ]]
    echo 0 > "${n}"
    # What: Stub gh --include as HTTP 404, counting calls.
    # Why: A 4xx must fail at once, never retry.
    gh() { echo $(( $(cat "${n}") + 1 )) > "${n}"; printf 'HTTP/2.0 404 Not Found\n\r\n{"message":"Not Found"}\n'
        echo "gh: Not Found (HTTP 404)" >&2; return 1; }
    GH_TOKEN=x GITHUB_REPOSITORY=o/r GITHUB_SHA=a GITHUB_REF=r run ci_cmd_sarif_upload "${f}"
    [ "${status}" -eq 1 ]
    [ "$(cat "${n}")" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0004"*"HTTP 404"*"Not Found"* ]]
    _fail gh 1 "dial tcp: connection refused"
    GH_TOKEN=x GITHUB_REPOSITORY=o/r GITHUB_SHA=a GITHUB_REF=r run ci_cmd_sarif_upload "${f}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0004"*"HTTP none: dial tcp: connection refused"* ]]
}

# What: Scans against a base without bin pins, then git fails.
# Why: Its tools cannot be fetched; reading 0 would fail all.
# From: Issue #267, Issue #479, PR #544
@test "OSV PR gate is NotRun against a base SOT without tool pins" {
    _fake_osv '    version: "v1"'
    OSV_BASE_IDS="" OSV_HEAD_IDS="GO-1" GITHUB_EVENT_NAME=pull_request run ci_cmd_osv_scan out.sarif
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"OSV PR gate NotRun"* ]]
    OSV_GIT_FAIL=1 OSV_BASE_IDS="" OSV_HEAD_IDS="GO-1" GITHUB_EVENT_NAME=pull_request run ci_cmd_osv_scan out.sarif
    [ "${status}" -eq 1 ]
    [[ "${output}" != *"NotRun"* ]]
}

# What: Runs a fake scanner exiting 1, 127 and 128.
# Why: v2.6.0 docs/output.md:796-798: 127 and 128 are errors.
# From: Issue #267, Issue #479, PR #544
@test "OSV run keeps findings 1-126 and fails on a scanner error" {
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

# What: Builds the predicate from stubbed push-run claims.
# Why: gh attestation verify expects that exact provenance.
# From: Issue #38, Issue #479, PR #544
@test "attest predicate has the actions/attest SLSA v1 shape" {
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

# What: Encodes 7, 8 and 9 byte claims as a JWT does.
# Why: Each length restores a different '=' count.
# From: Issue #38, PR #544
@test "attest claims decode an unpadded base64url token payload" {
    local j p
    export ACTIONS_ID_TOKEN_REQUEST_TOKEN=t ACTIONS_ID_TOKEN_REQUEST_URL=u
    # What: Stub curl: answer the token request with FX_TOKEN.
    # Why: Each loop pass swaps FX_TOKEN, not the stub.
    curl() { printf '{"value":"%s"}' "${FX_TOKEN}"; }
    for j in '{"a":1}' '{"ab":1}' '{"abc":1}'; do
        p="$(printf '%s' "${j}" | base64 -w0 | tr '/+' '_-' | tr -d '=')"
        FX_TOKEN="h.${p}.s"
        run _ci_attest_claims
        [ "${status}" -eq 0 ]
        [ "${output}" = "${j}" ]
    done
    _fail tr 1 "tr broke"
    run _ci_attest_claims
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"tr broke"* ]]
}

# What: Attests two files with cosign and predicate stubbed.
# Why: One signature covers the whole shipped asset set.
# From: Issue #38, Issue #479, PR #544
@test "attest builds one in-toto statement over all subjects" {
    printf 'a' > "${BATS_TEST_TMPDIR}/f1"; printf 'b' > "${BATS_TEST_TMPDIR}/f2"
    _print _ci_tool_bin /bin/true
    _print _ci_attest_predicate '{"p":1}'
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

# What: Attests without OIDC, on macOS, coverage and bogus.
# Why: Fork PRs never get an id-token; releases always do.
# From: Issue #38, Issue #479, PR #544
@test "attest: build without OIDC is NotRun, a bad target fails" {
    local ev="${BATS_TEST_TMPDIR}/ev.json"
    _forbid curl gh
    unset ACTIONS_ID_TOKEN_REQUEST_URL
    GITHUB_ACTIONS="" RUNNER_OS=Linux run ci_cmd_attest build default
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"build attestation NotRun: no id-token outside GitHub Actions"* ]]
    export GITHUB_ACTIONS=true GITHUB_REPOSITORY=o/r GITHUB_EVENT_PATH="${ev}" RUNNER_OS=Linux
    printf '{"pull_request":{"head":{"repo":{"full_name":"fork/r"}}}}' > "${ev}"
    GITHUB_EVENT_NAME=pull_request run ci_cmd_attest build default
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"build attestation NotRun: no id-token for a fork PR"* ]]
    printf '{"pull_request":{"head":{"repo":{"full_name":"o/r"}}}}' > "${ev}"
    GITHUB_EVENT_NAME=pull_request run ci_cmd_attest build default
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-ATTEST-0002"* ]]
    GITHUB_EVENT_NAME=push run ci_cmd_attest build default
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-ATTEST-0002"* ]]
    printf '{"pull_request":{}}' > "${ev}"
    GITHUB_EVENT_NAME=pull_request run ci_cmd_attest build default
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-EVENT-0001"* ]]
    unset GITHUB_ACTIONS
    ACTIONS_ID_TOKEN_REQUEST_URL=x RUNNER_OS=macOS run ci_cmd_attest build default
    [[ "${output}" == *"not the default Linux build"* ]]
    ACTIONS_ID_TOKEN_REQUEST_URL=x RUNNER_OS=Linux run ci_cmd_attest build coverage
    [[ "${output}" == *"not the default Linux build"* ]]
    run ci_cmd_attest bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-ATTEST-0001"* ]]
    [[ "${output}" != *"must not run"* ]]
}

# What: Runs sot-update on a SOT whose pins are all current.
# Why: A weekly no-op must not create noise on the repo.
# From: Issue #479, PR #544
@test "sot-update with current pins touches neither git nor PRs" {
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

# What: Dry-runs sot-update with no open PR, then with one.
# Why: The PR is created once; later runs refresh its body.
# From: Issue #479, PR #544
@test "sot-update creates its PR once, then edits the open one" {
    _print _ci_sot_refresh '| `a` | `x` | `1` | `2` |'
    _pass _ci_git_identity _ci_git_auth_setup
    _print gh '[]'
    DRY_RUN=true GH_TOKEN=x GITHUB_REPOSITORY=o/r run ci_cmd_sot_update
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"would run: gh pr create"* ]]
    [[ "${output}" != *"gh pr edit"* ]]
    _print gh '[{"number":12,"baseRefOid":"b","headRefOid":"h","isCrossRepository":false}]'
    DRY_RUN=true GH_TOKEN=x GITHUB_REPOSITORY=o/r run ci_cmd_sot_update
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"would run: gh pr edit 12"* ]]
    [[ "${output}" != *"gh pr create"* ]]
    _print gh '[{"number":8,"baseRefOid":"f","headRefOid":"f","isCrossRepository":true}]'
    DRY_RUN=true GH_TOKEN=x GITHUB_REPOSITORY=o/r run ci_cmd_sot_update
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"would run: gh pr create"* ]]
    [[ "${output}" != *"gh pr edit"* ]]
    # What: Stub gh: no open PR; create logs args, prints a URL.
    # Why: The SOT milestone and that URL's board add must follow.
    gh() { case "$1 $2" in "pr list") echo '[]' ;; "pr create") echo "create $*" >&2; echo "https://x/pull/7" ;;
        *) echo "gh $*" ;; esac; }
    PROJECT_PAT=t GH_TOKEN=x GITHUB_REPOSITORY=o/r run _stubbed '_pass git' ci_cmd_sot_update
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--milestone current_dev backlog"* ]]
    [[ "${output}" == *"gh project item-add 11 --owner wiki-mod --url https://x/pull/7"* ]]
}

# What: Runs ci_cmd_harden with an unknown subcommand.
# Why: start and stop are the agent's only lifecycle steps.
# From: Issue #479, PR #544
@test "harden rejects an unknown subcommand" {
    run ci_cmd_harden bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-HARDEN-0001"* ]]
}

# What: Starts harden on ARM64 with curl and sudo forbidden.
# Why: The non-TLS agent ships for x64 only.
# From: Issue #479, PR #544
@test "harden start is NotRun on an ARM64 runner" {
    _forbid curl sudo
    RUNNER_OS=Linux RUNNER_ARCH=ARM64 RUNNER_ENVIRONMENT=github-hosted run _ci_harden_start
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"NotRun: agent unsupported on RUNNER_ARCH=ARM64"* ]]
    [[ "${output}" != *"must not run"* ]]
}

# What: Answers the monitor call once in JSON, once in text.
# Why: Agent is audit-only (Issue #58); bad reply drops key.
# From: Issue #479, PR #544, Issue #58
@test "harden start: a 200 body that is not JSON runs keyless" {
    export RUNNER_OS=Linux RUNNER_ARCH=X64 RUNNER_ENVIRONMENT=github-hosted USER=u
    export GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=1 GITHUB_WORKSPACE=/w RUNNER_TEMP="${BATS_TEST_TMPDIR}"
    export GITHUB_EVENT_PATH="${BATS_TEST_TMPDIR}/event.json"
    printf '{"repository":{"private":false}}' > "${GITHUB_EVENT_PATH}"
    _CI_HARDEN_DIR="${BATS_TEST_TMPDIR}/agent"
    mkdir -p "${_CI_HARDEN_DIR}"
    printf 'ok' > "${_CI_HARDEN_DIR}/agent.status"
    _print _ci_tool_bin /bin/true
    # What: Stub sudo: swallow tee input, pass everything else.
    # Why: No root step may touch the machine running the test.
    sudo() { [ "$1" != tee ] || cat > /dev/null; }
    _pass timeout
    # What: Stub curl: write FX_BODY to -o, report HTTP 200.
    # Why: Each run picks its monitor reply through FX_BODY.
    curl() {
        while [ "$#" -gt 0 ]; do [ "$1" != -o ] || FX_RESP="$2"; shift; done
        printf '%s' "${FX_BODY}" > "${FX_RESP}"
        printf '200'
    }
    FX_BODY='{"one_time_key":"k","monitoring_started":true}' run _ci_harden_start
    [ "${status}" -eq 0 ]
    [ "$(jq -r .one_time_key "${_CI_HARDEN_DIR}/agent.json")" = "k" ]
    grep -qx 'add_summary=true' "${RUNNER_TEMP}/ci-harden.state"
    FX_BODY='not json' run _ci_harden_start
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"body is not JSON"*"not json"* ]]
    [ "$(jq -r .one_time_key "${_CI_HARDEN_DIR}/agent.json")" = "" ]
    grep -qx 'add_summary=false' "${RUNNER_TEMP}/ci-harden.state"
}

# What: Stops harden with no state file present.
# Why: Stop runs under if: always(), also after skips.
# From: Issue #479, PR #544
@test "harden stop is NotRun when no agent was started" {
    _CI_HARDEN_DIR="${BATS_TEST_TMPDIR}/agent"
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _ci_harden_stop
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"NotRun: no agent was started"* ]]
}

# What: Stops harden; the agent never writes done.json.
# Why: Unflushed telemetry must not pass silently.
# From: Issue #479, PR #544
@test "harden stop fails closed when the agent never confirms" {
    _fixture_harden_state
    _pass sleep
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _ci_harden_stop
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-HARDEN-0003"* ]]
    [ -f "${_CI_HARDEN_DIR}/post_event.json" ]
}

# What: Breaks sed while the start-written state is read.
# Why: The correlation id selects which summary is fetched.
# From: Issue #479, PR #544
@test "harden stop fails closed when its state file cannot be read" {
    _fixture_harden_state
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _stubbed '_fail sed 1 "sed broke"' _ci_harden_stop
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"sed broke"* ]]
    [ ! -e "${_CI_HARDEN_DIR}/post_event.json" ]
}

# What: Stops harden after the agent wrote done.json.
# Why: The agent flushes only after it reads post_event.json.
# From: Issue #479, PR #544
@test "harden stop passes once the agent wrote done.json" {
    _fixture_harden_state
    printf '{}' > "${_CI_HARDEN_DIR}/done.json"
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _ci_harden_stop
    [ "${status}" -eq 0 ]
    [ "$(cat "${_CI_HARDEN_DIR}/post_event.json")" = '{"event":"post"}' ]
}
