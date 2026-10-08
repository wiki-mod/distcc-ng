#!/usr/bin/env bats
# distcc-ng (https://github.com/wiki-mod/distcc-ng)
# SPDX-License-Identifier: GPL-2.0-or-later
# What: Bats suite for ci.sh, its SOT and workflow wiring.
# Why: Issue #479 allows ci.bats as the only CI test file.
# From: Issue #479

# What: Index the real SOT once per file into a sourced file.
# Why: The SOT is read-only here; one parse serves every test.
# From: Issue #479, PR #544
setup_file() {
    # shellcheck source=.github/scripts/ci.sh
    source "${BATS_TEST_DIRNAME}/ci.sh"
    _ci_sot_index
    {
        printf '_CI_SOT_K=(%s)\n' "$(printf '%q ' "${_CI_SOT_K[@]}")"
        printf '_CI_SOT_V=(%s)\n' "$(printf '%q ' "${_CI_SOT_V[@]}")"
        printf '_CI_SOT_KEY=%q\n' "${_CI_SOT_KEY}"
    } > "${BATS_FILE_TMPDIR}/sot-index.sh"
}

# What: Source ci.sh functions and the file's SOT index.
# Why: ci.sh runs ci_main only when executed, not sourced.
# From: Issue #479, PR #544
setup() {
    CI_SH="${BATS_TEST_DIRNAME}/ci.sh"
    # shellcheck source=.github/scripts/ci.sh
    source "${CI_SH}"
    eval "$(< "${BATS_FILE_TMPDIR}/sot-index.sh")"
}

# What: Point CI_MANIFEST at a fixture of the given lines.
# Why: Tests that copy real SOT values are a second truth.
# From: Issue #479, PR #544
_fixture_manifest() {
    CI_MANIFEST="${BATS_TEST_TMPDIR}/build-manifest.yml"
    printf '%s\n' "$@" > "${CI_MANIFEST}"
    _ci_sot_index_drop
    _ci_sot_index
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

# What: Make fake executable $1: log args, print, exit $RC/$2.
# Why: One stand-in for every tool a test runs by its path.
# From: Issue #479, PR #544
_fake_tool() {
    printf '#!/bin/sh\necho "$*" >> "%s.args"\n[ -z "${OUT_TEXT:-}" ] || printf "%%s\\n" "${OUT_TEXT}"\nexit "${RC:-%s}"\n' "$1" "${2:-0}" > "$1"
    chmod +x "$1"
}

# What: Make each named command print "name args" to stdout.
# Why: One stub owner for steps a test checks by their output.
# From: Issue #479, PR #544
_echoes() {
    local c
    for c in "$@"; do
        eval "${c}() { echo \"${c} \$*\"; }"
    done
}

# What: Make each named command log "name args" to $CALL_LOG.
# Why: One stub owner for steps a test checks by their calls.
# From: Issue #479, PR #544
_record() {
    local c
    for c in "$@"; do
        eval "${c}() { echo \"${c} \$*\" >> \"\${CALL_LOG:?CALL_LOG required}\"; }"
    done
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

# What: An unknown command, variant or mode at each entry.
# Why: A typo must fail with its id before any tool runs.
# From: Issue #479, PR #544
@test "unknown commands, variants and modes fail closed before any work" {
    local args id
    local argv=()
    run bash "${BATS_TEST_DIRNAME}/ci.sh" bogus-command
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0002"* ]]
    _forbid docker make _ci_configure_tree
    while IFS='|' read -r args id; do
        read -ra argv <<< "${args}"
        run ci_main "${argv[@]}"
        [ "${status}" -eq 2 ] || { echo "${args}: rc ${status}: ${output}"; return 1; }
        [[ "${output}" == *"[CI-ERROR-${id}]"* ]] || { echo "${args}: want ${id}: ${output}"; return 1; }
        [[ "${output}" != *"must not run"* ]] || { echo "${args}: ran a tool: ${output}"; return 1; }
    done <<'EOF'
container bogus|CONTAINER-0001
e2e bogus|E2E-0013
workload bogus|WORKLOAD-0006
workload ccache sideways|WORKLOAD-0004
workload samba sideways /tmp/x|WORKLOAD-0008
image bogus|IMAGE-0001
release bogus|RELEASE-0005
build bogus|BUILD-0002
test bogus|TEST-0005
harden bogus|HARDEN-0001
EOF
}

# What: Guards ci.sh, then a copy that raises one id twice.
# Why: A shared id would point triage at the wrong failure.
# From: Issue #479, PR #544
@test "the error-id guard fails on an id raised twice" {
    local fx="${BATS_TEST_TMPDIR}/ci.sh"
    run ci_guard_error_ids "${CI_SH}"
    [ "${status}" -eq 0 ]
    cp "${CI_SH}" "${fx}"
    printf '%s\n' 'ci_log "[CI-ERROR-CORE-0002]" "again"' >> "${fx}"
    run ci_guard_error_ids "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-ERRID-0001"*"CI-ERROR-CORE-0002 is raised"* ]]
}

# What: Points CI_MANIFEST at a path that does not exist.
# Why: Without the SOT every pin and spec would read empty.
# From: Issue #479
@test "a missing manifest fails closed" {
    CI_MANIFEST="/nonexistent/build-manifest.yml" run ci_require_manifest
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0003"* ]]
}

# What: Every SOT reader on one fixture: values, gaps, kinds.
# Why: A wrong path or node kind must fail, never read empty.
# From: Issue #479, PR #544
@test "SOT readers: values, absent paths and node kinds" {
    local r path rc want got
    _fixture_manifest 'a:' '  b: "x"' '  c:' '    d: "y:z@sha256:0"' '  q: "v1"  # note' '  u: v2 # note' \
        '  e: ""' '  l: ["p", "q"]' '  w: "it'"'"'s $HOME `id`"' 'v:' '  one:' '    k: 1' '  two:' '    k: 2' \
        'other: 1'
    while IFS='|' read -r r path rc want; do
        case "${r}" in
            scalar) run _ci_sot_scalar "${path}" ;;
            optional) run _ci_sot_optional "${path}" ;;
            children) run _ci_sot_children "${path}" ;;
            list) run _ci_sot_list "${path}" ;;
            mode-*) run _ci_sot_lookup "${r#mode-}" "${path}" ;;
        esac
        got="${output//$'\n'/ }"
        [ "${status}" -eq "${rc}" ] || { echo "${r} ${path}: rc ${status}: ${got}"; return 1; }
        case "${want}" in
            =*) [ "${got}" = "${want#=}" ] ;;
            *) [[ "${got}" == *"${want}"* ]] ;;
        esac || { echo "${r} ${path}: want ${want}: ${got}"; return 1; }
    done <<'EOF'
scalar|a.b|0|=x
scalar|a.c.d|0|=y:z@sha256:0
scalar|a.q|0|=v1
scalar|a.u|0|=v2
scalar|a.e|0|=
scalar|a.c|2|CI-ERROR-SOT-0010
scalar|a.nope|2|CI-ERROR-SOT-0002
optional|a.nope|0|=
optional|a.b|0|=x
optional|a.c|2|CI-ERROR-SOT-0010
children|v|0|=one two
children|a.b|2|CI-ERROR-SOT-0010
children|v.nope|2|CI-ERROR-SOT-0002
list|a.l|0|=p q
scalar|a.w|0|=it's $HOME `id`
list|a.c|2|CI-ERROR-SOT-0010
mode-bogus|a.b|2|CI-ERROR-SOT-0009
mode-value|a.c.zz|3|=
EOF
    printf '%s
' 'a:' '   b: 1' > "${CI_MANIFEST}"
    _ci_sot_index_drop
    run _ci_sot_scalar a.b
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SOT-0011"*"line 2: odd indentation"* ]]
    CI_MANIFEST="${BATS_TEST_TMPDIR}/none.yml" run _ci_sot_scalar a.b
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SOT-0012"* ]]
}

# What: Clean fixture SOT pins, then each malformed pin form.
# Why: No tag, no refresh; no digest or sha256, no check.
# From: Issue #479, PR #544
@test "SOT pin guard needs name:tag@digest and a sha256 per url" {
    local d; d="$(printf 'a%.0s' {1..64})"
    _fixture_manifest 'base_images:' "  deb: \"debian:trixie@sha256:${d}\"" 'external_services:' \
        "  red: \"redis:8@sha256:${d}\"" 'external_versions:' '  t:' '    url: "https://h/t"' \
        "    sha256: \"${d}\"" '  m:' '    version: "1"'
    run ci_guard_sot_pins
    [ "${status}" -eq 0 ]
    _fixture_manifest 'base_images:' "  deb: \"debian@sha256:${d}\"" 'external_services:' \
        '  red: "redis:8@sha256:abc"' 'external_versions:' '  t:' '    url: "https://h/t"' '  m:' '    version: "1"'
    run ci_guard_sot_pins
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-PIN-0004"*"base_images.deb=debian@sha256"* ]]
    [[ "${output}" == *"CI-ERROR-GUARD-PIN-0004"*"external_services.red=redis:8@sha256:abc"* ]]
    [[ "${output}" == *"CI-ERROR-GUARD-PIN-0005"*"external_versions.t has a url"* ]]
    [[ "${output}" != *"external_versions.m"* ]]
}

# What: Sets a.c.b beside twins; bad path, section, broken mv.
# Why: sot-update never touches a neighbour or half-writes.
# From: Issue #479, PR #544
@test "sot set rewrites one path, keeps mode, and fails closed" {
    _fixture_manifest 'a:' '  # note' '  b: "x"' '  c:' '    b: "y"' 'b: "z"'
    run _ci_sot_set a.c.b "new"
    [ "${status}" -eq 0 ]
    _ci_sot_index_drop
    [ "$(_ci_sot_scalar a.c.b)" = "new" ]
    [ "$(_ci_sot_scalar a.b)" = "x" ]
    [ "$(_ci_sot_scalar b)" = "z" ]
    grep -qx '  # note' "${CI_MANIFEST}"
    cp "${CI_MANIFEST}" "${BATS_TEST_TMPDIR}/before"
    run _ci_sot_set a.nope "v"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SOT-0002"* ]]
    run _ci_sot_set a.c "v"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SOT-0013"* ]]
    cmp "${CI_MANIFEST}" "${BATS_TEST_TMPDIR}/before"
    chmod 640 "${CI_MANIFEST}"
    run _stubbed '_fail mv 1 "mv broke"' _ci_sot_set a.b "new"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"mv broke"* ]]
    cmp "${CI_MANIFEST}" "${BATS_TEST_TMPDIR}/before"
    _ci_sot_index
    _ci_sot_set a.b "new"
    [ "$(_ci_sot_scalar a.b)" = "new" ]
    [ "$(stat -c %a "${CI_MANIFEST}")" = "640" ]
    [ -z "$(find "${BATS_TEST_TMPDIR}" -name 'build-manifest.yml.*')" ]
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

# What: Job count per nproc answer: fail, 0, 2, 8 and 12 CPUs.
# Why: Floor 16, else nproc*2; a failed nproc never guesses.
# From: Issue #479, PR #544
@test "job count is max(16, nproc*2) and fails closed without nproc" {
    local cpus rc want
    while IFS='|' read -r cpus rc want; do
        if [ "${cpus}" = fail ]; then _fail nproc 1; else _print nproc "${cpus}"; fi
        run _ci_jobs
        [ "${status}" -eq "${rc}" ] || { echo "nproc ${cpus}: rc ${status}: ${output}"; return 1; }
        if [ "${rc}" -eq 0 ]; then
            [ "${output}" = "${want}" ] || { echo "nproc ${cpus}: want ${want}: ${output}"; return 1; }
        else
            [[ "${output}" == *"${want}"* ]] || { echo "nproc ${cpus}: want ${want}: ${output}"; return 1; }
        fi
    done <<'EOF'
fail|2|CI-ERROR-CORE-0005
0|2|CI-ERROR-CORE-0005
2|0|16
8|0|16
12|0|24
EOF
    _fail nproc 1
    run ci_cmd_selftest
    [ "${status}" -eq 2 ]
}

# What: Titles per lint mode and draft on a fixture AG-GH-014.
# Why: Only block mode on a ready PR may fail a bad title.
# From: Issue #479, PR #544
@test "pr-title: valid, bad type, bad scope and no type per mode" {
    local fx="${BATS_TEST_TMPDIR}/repo" title mode draft rc want
    mkdir -p "${fx}"
    printf '%s\n' '**[AG-GH-014]** T; allowed types MUST remain `feat` and `fix`; optional lowercase scopes MUST remain `pump` and `ci`; end' \
        > "${fx}/AGENTS.md"
    while IFS='|' read -r title mode draft rc want; do
        CI_REPO_ROOT="${fx}" PR_TITLE="${title}" PR_TITLE_LINT_MODE="${mode}" PR_DRAFT="${draft}" \
            run _ci_check_pr_title
        [ "${status}" -eq "${rc}" ] || { echo "${title}/${mode}/${draft}: rc ${status}: ${output}"; return 1; }
        [[ "${output}" == *"${want}"* ]] || { echo "${title}/${mode}/${draft}: want ${want}: ${output}"; return 1; }
    done <<'EOF'
feat(pump): add IPv6|block|false|0|[CI-META-TITLE] OK
fix: x|block|false|0|[CI-META-TITLE] OK
add some stuff|block|false|1|[CI-ERROR-META-TITLE-0002]
add some stuff|warn|false|0|[CI-WARN-META-TITLE]
add some stuff|block|true|0|[CI-WARN-META-TITLE]
docs(pump): x|block|false|1|type 'docs' not in: feat fix
feat(zstd): x|block|false|1|scope '(zstd)' not a documented area
|block|false|1|[CI-ERROR-META-TITLE-0001]
EOF
}

# What: Parses a fixture AG-GH-014, then no rule, empty lists.
# Why: AGENTS.md owns the taxonomy; a gap must not pass.
# From: Issue #479, PR #544
@test "pr-title taxonomy comes from AG-GH-014 and fails closed" {
    local fx="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${fx}"
    printf '%s\n' '**[AG-GH-014]** T; allowed types MUST remain `feat` and `fix`; optional lowercase scopes MUST remain `pump`, `support-upstream`; end' \
        > "${fx}/AGENTS.md"
    CI_REPO_ROOT="${fx}" run _ci_title_taxonomy types
    [ "${output}" = "feat fix" ]
    CI_REPO_ROOT="${fx}" run _ci_title_taxonomy scopes
    [ "${output}" = "pump support-upstream" ]
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

# What: Both, no milestone, no label; then a draft PR.
# Why: AG-GH-002 asks for a label and a milestone, no more.
# From: Issue #479, PR #544
@test "tracking needs a label and a milestone; drafts warn" {
    local labels ms rc want
    unset PROJECT_PAT
    while IFS='|' read -r labels ms rc want; do
        PR_LABELS="${labels}" PR_MILESTONE_TITLE="${ms}" run _ci_check_pr_tracking
        [ "${status}" -eq "${rc}" ] || { echo "[${labels}][${ms}]: rc ${status}: ${output}"; return 1; }
        [[ "${output}" == *"${want}"* ]] || { echo "[${labels}][${ms}]: want ${want}: ${output}"; return 1; }
    done <<'EOF'
ci|current_dev backlog|0|OK: labels and milestone set
ci||1|[CI-ERROR-META-TRACKING-0001] PR tracking metadata failed (AG-GH-002); no milestone set
 |current_dev backlog|1|no labels set
EOF
    PR_LABELS="" PR_MILESTONE_TITLE="" PR_DRAFT="true" run _ci_check_pr_tracking
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"draft, non-blocking"* ]]
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

# What: A PR run sets the PR; dispatch and push fail closed.
# Why: Dispatch checks never satisfy required PR checks.
# From: Issue #479, PR #544
@test "metadata reads the PR of a PR run and rejects any other event" {
    local ev="${BATS_TEST_TMPDIR}/ev.json"
    printf '%s\n' '{"pull_request":{"number":7,"base":{"sha":"b1"},"head":{"sha":"h1"}}}' > "${ev}"
    GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="${ev}" _ci_metadata_pr
    [ "${PR_NUMBER} ${BASE} ${HEAD}" = "7 b1 h1" ]
    _forbid gh _ci_metadata_fetch_live
    for e in workflow_dispatch push; do
        GITHUB_EVENT_NAME="${e}" run ci_cmd_metadata
        [ "${status}" -eq 2 ]
        [[ "${output}" == *"CI-ERROR-META-0002"*"in a ${e} run"* ]]
        [[ "${output}" != *"must not run"* ]]
    done
    GITHUB_EVENT_NAME=pull_request run ci_cmd_metadata bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-META-0001"* ]]
}

# What: Board check: no PAT, on, off board, lookup error.
# Why: Only a missing PAT may warn; with one it is blocking.
# From: Issue #479, PR #544
@test "board check warns without a PAT and blocks with one" {
    local pat lookup rc want
    while IFS='|' read -r pat lookup rc want; do
        case "${lookup}" in
            on) _print _ci_pr_on_project_board ;;
            off) _fail _ci_pr_on_project_board 1 ;;
            err) _fail _ci_pr_on_project_board 2 ;;
            none) _forbid _ci_pr_on_project_board ;;
        esac
        PROJECT_PAT="${pat}" run _ci_check_pr_board
        [ "${status}" -eq "${rc}" ] || { echo "${pat}/${lookup}: rc ${status}: ${output}"; return 1; }
        [[ "${output}" == *"${want}"* ]] || { echo "${pat}/${lookup}: want ${want}: ${output}"; return 1; }
    done <<'EOF'
|none|0|[CI-META-BOARD]
dummy|on|0|OK: on project board
dummy|off|1|[CI-ERROR-META-BOARD-0002]
dummy|err|1|[CI-ERROR-META-BOARD-0001]
EOF
}

# What: Tag v9.9.9-NG: pushed, re-tag, mismatch, git down.
# Why: POL-RELEASE-05/07: a tag names configure.ac and is new.
# From: Issue #479, PR #544
@test "release version-check: configure.ac match, new tag, git errors" {
    local fx tag new rc want
    fx="$(_fixture_tag_repo)"
    while IFS='|' read -r tag new rc want; do
        CI_REPO_ROOT="${fx}" run _ci_check_release_version "${tag}" "${new}"
        [ "${status}" -eq "${rc}" ] || { echo "${tag}/${new}: rc ${status}: ${output}"; return 1; }
        [[ "${output}" == *"${want}"* ]] || { echo "${tag}/${new}: want ${want}: ${output}"; return 1; }
    done <<'EOF'
v9.9.9-NG|false|0|[CI-RELEASE]
v9.9.9-NG|true|1|[CI-ERROR-RELEASE-0004]
v99.99.99-NG|true|1|[CI-ERROR-RELEASE-0003]
EOF
    _fail git 128 "git broke"
    CI_REPO_ROOT="${fx}" run _ci_check_release_version v9.9.9-NG
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"git broke"* ]]
    [[ "${output}" != *"CI-ERROR-RELEASE-0004"* ]]
    [[ "${output}" != *"OK"* ]]
}

# What: Tag push, dispatches with and without inputs, others.
# Why: POL-RELEASE-05/07: only a release trigger names a tag.
# From: Issue #479, PR #544
@test "release context per event: tag push, dispatch, and refusals" {
    local ev="${BATS_TEST_TMPDIR}/ev.json" event ref json rc want got
    while IFS='|' read -r event ref json rc want; do
        printf '%s' "${json}" > "${ev}"
        GITHUB_EVENT_NAME="${event}" GITHUB_REF="${ref}" GITHUB_REF_NAME="${ref##*/}" GITHUB_EVENT_PATH="${ev}" \
            run _ci_release_context
        got="${output//$'\n'/ }"
        [ "${status}" -eq "${rc}" ] || { echo "${event} ${ref} ${json}: rc ${status}: ${got}"; return 1; }
        case "${want}" in
            =*) [ "${got}" = "${want#=}" ] ;;
            *) [[ "${got}" == *"${want}"* ]] ;;
        esac || { echo "${event} ${ref} ${json}: want ${want}: ${got}"; return 1; }
    done <<'EOF'
push|refs/tags/v1.2.3-NG|{}|0|=v1.2.3-NG false true true
workflow_dispatch||{"inputs":{"tag":"v1.2.3-NG","publish_container":"true"}}|0|=v1.2.3-NG true true false
workflow_dispatch||{"inputs":{"tag":"v1.2.3-NG"}}|0|=v1.2.3-NG true false false
workflow_dispatch||{"inputs":{}}|2|[CI-ERROR-EVENT-0001] workflow_dispatch payload has no .inputs.tag
push|refs/heads/current_dev|{}|2|[CI-ERROR-RELEASE-0007]
schedule||{}|2|[CI-ERROR-RELEASE-0008]
EOF
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

# What: Release, notes, pre-release, no notes; a retry file.
# Why: The workflow passes neither; ci.sh reads the event.
# From: Issue #479, PR #544
@test "changelog update: event, notes file retry, dry run" {
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
    local ev="${BATS_TEST_TMPDIR}/ev.json" event json want
    # What: Stub the insert to print its tag and notes.
    # Why: The test checks the event parse, not git.
    _ci_changelog_insert() { printf 'insert %s|%s\n' "$1" "$2"; }
    while IFS='^' read -r event json want; do
        printf '%s' "${json}" > "${ev}"
        GITHUB_EVENT_NAME="${event}" GITHUB_EVENT_PATH="${ev}" run _ci_publish_changelog_update
        [ "${status}" -eq 0 ] || { echo "${json}: rc ${status}: ${output}"; return 1; }
        case "${want}" in
            insert*) [ "${output}" = "${want}" ] ;;
            *) [[ "${output}" == *"${want}"* && "${output}" != *insert* ]] ;;
        esac || { echo "${json}: want ${want}: ${output}"; return 1; }
    done <<'EOF'
release^{"release":{"prerelease":false,"tag_name":"v1.2","body":"notes"}}^insert v1.2|notes
workflow_dispatch^{"inputs":{"tag":"v2-NG","release_notes":"rn"}}^insert v2-NG|rn
release^{"release":{"prerelease":true,"tag_name":"v1","body":"x"}}^skipped: pre-release
workflow_dispatch^{"inputs":{"tag":"v1","release_notes":""}}^skipped: no release_notes
EOF
}

# What: Login and push without a token, then a recorded login.
# Why: No anonymous push; argv leaks into logs, stdin not.
# From: Issue #479, PR #544
@test "registry login needs REGISTRY_TOKEN and pipes it on stdin" {
    _forbid docker
    unset REGISTRY_TOKEN
    GITHUB_ACTOR=octo run _ci_registry_login
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"REGISTRY_TOKEN required"* ]]
    [[ "${output}" != *"must not run"* ]]
    GITHUB_ACTOR=octo run _ci_registry_push some/image:tag
    [ "${status}" -ne 0 ]
    [[ "${output}" != *"must not run"* ]]
    # What: Stub docker to record its stdin and argv.
    # Why: The real login needs a registry and a token.
    docker() { cat > "${BATS_TEST_TMPDIR}/stdin"; echo "$*" > "${BATS_TEST_TMPDIR}/argv"; }
    REGISTRY_TOKEN=s3cret GITHUB_ACTOR=octo run _ci_registry_login
    [ "${status}" -eq 0 ]
    [ "$(cat "${BATS_TEST_TMPDIR}/stdin")" = "s3cret" ]
    [ "$(cat "${BATS_TEST_TMPDIR}/argv")" = "login ghcr.io -u octo --password-stdin" ]
}

# What: Counts a five-line log per host and subnet; no log.
# Why: Only real client COMPILE_OK counts; no log is no zero.
# From: Issue #479, Issue #264, PR #544
@test "e2e compile-ok counter counts clients in the CIDR, needs a log" {
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
    run _ci_e2e_count_compile_ok "${BATS_TEST_TMPDIR}/nope.log" 172.18.0.0/16
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-E2E-0002"* ]]
}

# What: Scans a clean verbose log, then one with an ERROR.
# Why: Info lines have no prefix; ERROR: is a severity one.
# From: Issue #479, PR #544
@test "e2e server warning scan passes info lines, fails on ERROR" {
    local log="${BATS_TEST_TMPDIR}/server.log"
    printf 'distccd[7] listening on 0.0.0.0:3632\ndistccd[9] (dcc_job_summary) client: 172.18.0.3:4 COMPILE_OK\n' > "${log}"
    run _ci_e2e_check_server_warnings "${log}"
    [ "${status}" -eq 0 ]
    printf 'distccd[8] (dcc_check_client) ERROR: connection from client denied\n' > "${log}"
    run _ci_e2e_check_server_warnings "${log}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-E2E-0015"* ]]
}

# What: Release build and runtime images, each step failing.
# Why: No binary or user may land after a failed earlier step.
# From: Issue #398, Issue #479, PR #544
@test "release images stop at the first failed step" {
    export CALL_LOG="${BATS_TEST_TMPDIR}/calls"
    local log="${CALL_LOG}"
    _print _ci_nproc 2
    _pass _ci_configure_tree _ci_make_gated
    _record _ci_apt_install install make mv useradd
    run _ci_image_release_build
    [ "${status}" -eq 0 ]
    grep -q '^install -D -t /out/usr/local/bin distcc distccd lsdistcc distccmon-text$' "${log}"
    grep -q '^mv /out-pump/usr/local/bin/pump /out-pump/usr/local/bin/distcc-pump$' "${log}"
    run _ci_image_release_runtime
    [ "${status}" -eq 0 ]
    grep -q '^useradd --system .*--shell /usr/sbin/nologin distcc$' "${log}"
    : > "${log}"
    _fail _ci_make_gated 1
    run _ci_image_release_build
    [ "${status}" -eq 1 ]
    [ "$(grep -c '^install\|^mv' "${log}")" -eq 0 ]
    _fail _ci_apt_install 1
    run _ci_image_release_runtime
    [ "${status}" -eq 1 ]
    [ "$(grep -c '^useradd' "${log}")" -eq 0 ]
}

# What: e2e images: native adds Debian distcc; ng builds tree.
# Why: native is the reference; only ng carries the checkout.
# From: Issue #264, Issue #479, PR #544
@test "e2e images: native installs Debian distcc, ng builds the tree" {
    export CALL_LOG="${BATS_TEST_TMPDIR}/calls"
    local log="${CALL_LOG}" native
    native="$(_ci_sot_scalar e2e.native_apt)"
    _print _ci_nproc 2
    _pass useradd update-distcc-symlinks _ci_make_gated make
    _record _ci_apt_install _ci_configure_tree
    run _stubbed '_pass mkdir chown' _ci_image_e2e native
    [ "${status}" -eq 0 ]
    grep -q "^_ci_apt_install .*${native} image$" "${log}"
    [ "$(grep -c '^_ci_configure_tree' "${log}")" -eq 0 ]
    : > "${log}"
    run _stubbed '_pass mkdir chown' _ci_image_e2e ng
    [ "${status}" -eq 0 ]
    [ "$(grep -c "${native}" "${log}")" -eq 0 ]
    grep -q '^_ci_configure_tree' "${log}"
    _fail _ci_make_gated 1
    run _stubbed '_pass mkdir chown' _ci_image_e2e ng
    [ "${status}" -eq 1 ]
}

# What: Leg: pass, too few, client fail, warning, no listen.
# Why: Only the server log proves the compiles went remote.
# From: Issue #479, Issue #264, PR #544
@test "e2e leg needs enough server-side compiles and a clean daemon" {
    local ok='distccd[1] (dcc_job_summary) client: 172.18.0.5:4000 COMPILE_OK exit:0'
    _print _ci_nproc 2
    _pass sleep _ci_container_logged
    # What: Stub container runs; the client exits $CLIENT_RC.
    # Why: A failed client workload must fail the leg.
    _ci_container_run() { case "$*" in *" workload "*) echo "${CLIENT_OUT:-}"; return "${CLIENT_RC:-0}" ;; esac; }
    # What: Stub docker: logs prints $SERVER_LOG, rm passes.
    # Why: The leg reads the server's log for its verdict.
    docker() { [ "$1" != logs ] || printf '%s\n' "${SERVER_LOG}"; }
    SERVER_LOG="$(printf '%s\n' "${ok}" "${ok}" "${ok}")" RUNNER_TEMP="${BATS_TEST_TMPDIR}" \
        run _ci_e2e_leg distributed ng:ng plain self-compile "" 3 n 172.18.0.0/16
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ng-ng-plain: 3 COMPILE_OK from the client (need >= 3)"* ]]
    SERVER_LOG="${ok}" RUNNER_TEMP="${BATS_TEST_TMPDIR}" \
        run _ci_e2e_leg distributed ng:ng plain self-compile "" 3 n 172.18.0.0/16
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-E2E-0005"* ]]
    CLIENT_RC=2 SERVER_LOG="${ok}" RUNNER_TEMP="${BATS_TEST_TMPDIR}" \
        run _ci_e2e_leg distributed ng:ng plain self-compile "" 1 n 172.18.0.0/16
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-E2E-0009"* ]]
    SERVER_LOG="$(printf '%s\n' "${ok}" 'distccd[1] (x) Warning: odd')" RUNNER_TEMP="${BATS_TEST_TMPDIR}" \
        run _ci_e2e_leg distributed ng:ng plain self-compile "" 1 n 172.18.0.0/16
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-E2E-0015"* ]]
    CLIENT_OUT=nothing SERVER_LOG="${ok}" RUNNER_TEMP="${BATS_TEST_TMPDIR}" \
        run _ci_e2e_leg distributed ng:ng plain self-compile "" objects n 172.18.0.0/16
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-E2E-0010"* ]]
    _fail _ci_container_logged 1
    SERVER_LOG="${ok}" RUNNER_TEMP="${BATS_TEST_TMPDIR}" \
        run _ci_e2e_leg distributed ng:ng plain self-compile "" 1 n 172.18.0.0/16
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-E2E-0014"* ]]
}

# What: Mode run with the first leg failing; mode retries.
# Why: Every leg runs; a mode fails only after all attempts.
# From: Issue #479, Issue #264, PR #544
@test "e2e mode runs every leg and retries up to max_attempts" {
    local calls="${BATS_TEST_TMPDIR}/calls"
    # What: Stub docker: inspect prints a subnet, volume passes.
    # Why: The mode run needs the stack network's subnet.
    docker() { [ "$2" != inspect ] || echo 172.18.0.0/16; }
    # What: Stub the leg: log it; the first call fails.
    # Why: Later legs must still run after one failed.
    _ci_e2e_leg() { echo "$3" >> "${calls}"; [ "$(wc -l < "${calls}")" -gt 1 ]; }
    run _ci_e2e_mode_run distributed self-compile "" 5 n
    [ "${status}" -eq 1 ]
    [ "$(paste -sd' ' "${calls}")" = "plain pump" ]
    _pass _ci_e2e_images
    : > "${calls}"
    # What: Stub an attempt: log it; the first one fails.
    # Why: heartbeat allows two attempts; the second passes.
    _ci_e2e_attempt() { echo a >> "${calls}"; [ "$(wc -l < "${calls}")" -gt 1 ]; }
    run _ci_e2e_mode heartbeat
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"heartbeat: PASS"* ]]
    _fail _ci_e2e_attempt 1
    run _ci_e2e_mode heartbeat
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-E2E-0006"*"failed on all 2 attempt(s)"* ]]
}

# What: Self-compiles a stub tree: clean make, then a warning.
# Why: The distributed build must pass the warning gate too.
# From: Issue #479, PR #544
@test "self-compile gates its make output in both passes" {
    local dir="${BATS_TEST_TMPDIR}/w" pass
    mkdir -p "${dir}/src"
    _fake_tool "${dir}/src/distcc"
    _fake_tool "${dir}/src/distccd"
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

# What: ccache workload plain, local; clone and cmake fail.
# Why: Only the plain pass may compile through distcc.
# From: Issue #81, Issue #263, Issue #479, PR #544
@test "ccache workload sets the distcc launcher only for plain" {
    local dir="${BATS_TEST_TMPDIR}/w" log="${BATS_TEST_TMPDIR}/calls"
    _print _ci_nproc 2
    _pass git
    # What: Stub cmake: log its arguments; fake the ccache binary.
    # Why: The test reads which launcher flags the build got.
    cmake() {
        echo "cmake $*" >> "${log}"
        mkdir -p "${dir}/build"
        _fake_tool "${dir}/build/ccache"
    }
    run _ci_workload_ccache plain "${dir}"
    [ "${status}" -eq 0 ]
    grep -q -- '-DCMAKE_C_COMPILER_LAUNCHER=distcc' "${log}"
    : > "${log}"
    run _ci_workload_ccache local "${dir}"
    [ "${status}" -eq 0 ]
    [ "$(grep -c -- 'LAUNCHER' "${log}")" -eq 0 ]
    run _stubbed '_fail git 128 "no such tag"' _ci_workload_ccache plain "${dir}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"no such tag"* ]]
    _fail cmake 1 "cmake broke"
    run _ci_workload_ccache plain "${dir}"
    [ "${status}" -eq 1 ]
}

# What: Samba fetch: bad pin, bad signature, good, cached.
# Why: VER-SOURCE: a bad pin or signature must stop the build.
# From: Issue #264, Issue #285, Issue #479, PR #544
@test "samba fetch stops on a bad signature and caches a good one" {
    local cache="${BATS_TEST_TMPDIR}/c" dest="${BATS_TEST_TMPDIR}/d" calls="${BATS_TEST_TMPDIR}/dl"
    _fixture_manifest 'external_versions:' '  samba:' '    version: "9"' '    url: "https://h/s-{version}.tgz"' \
        "    sha256: \"$(printf 'x' | sha256sum | cut -d' ' -f1)\"" '    sig_url: "https://h/s-{version}.asc"' \
        '    key_url: "https://h/k.asc"'
    # What: Stub the download to log the URL and write $FX_BODY.
    # Why: A verified cache must skip every later download.
    _ci_download() { echo "$1" >> "${calls}"; printf '%s' "${FX_BODY:-x}" > "$2"; }
    _pass gunzip tar
    FX_BODY=y CI_WORKLOAD_CACHE="${cache}" run _ci_workload_samba_fetch "${dest}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-FETCH-0001"*"external_versions.samba"* ]]
    [ "$(head -1 "${calls}")" = "https://h/s-9.tgz" ]
    [ ! -e "${cache}/samba/.verified" ]
    # What: Stub gpg: import passes; verify exits $GPG_RC.
    # Why: Only a verified signature may mark the cache good.
    gpg() { case "$*" in *--verify*) return "${GPG_RC:-0}" ;; esac; }
    GPG_RC=1 CI_WORKLOAD_CACHE="${cache}" run _ci_workload_samba_fetch "${dest}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-WORKLOAD-0002"* ]]
    [ ! -e "${cache}/samba/.verified" ]
    CI_WORKLOAD_CACHE="${cache}" run _ci_workload_samba_fetch "${dest}"
    [ "${status}" -eq 0 ]
    [ -e "${cache}/samba/.verified" ]
    : > "${calls}"
    CI_WORKLOAD_CACHE="${cache}" run _ci_workload_samba_fetch "${dest}"
    [ "${status}" -eq 0 ]
    [ ! -s "${calls}" ]
}

# What: Fuzz build on a fixture: skip, rename, libs, Makefile.
# Why: Only libFuzzer's entry may define main in the link.
# From: Issue #267, Issue #479, PR #544
@test "fuzz build skips and renames SOT mains and ships two libs" {
    local root="${BATS_TEST_TMPDIR}/r" out="${BATS_TEST_TMPDIR}/out" t="${BATS_TEST_TMPDIR}/cc"
    mkdir -p "${root}/src" "${root}/lzo" "${root}/test/fuzz" "${out}" "${BATS_TEST_TMPDIR}/lib"
    touch "${root}/src/distcc.c" "${root}/src/daemon.c" "${root}/src/util.c" "${root}/lzo/minilzo.c" \
        "${root}/test/fuzz/fuzz_x.c" "${BATS_TEST_TMPDIR}/lib/libpopt.so.0" "${BATS_TEST_TMPDIR}/lib/libc.so.6"
    printf '%s\n' 'prefix = /usr/local' 'sysconfdir = ${prefix}/etc' 'datarootdir = ${prefix}/share' \
        'LIBS = -lpopt' > "${root}/Makefile"
    _fake_tool "${t}"
    _pass _ci_run_configure
    _print ldd "libpopt.so.0 => ${BATS_TEST_TMPDIR}/lib/libpopt.so.0 (0x1)" \
        "libc.so.6 => ${BATS_TEST_TMPDIR}/lib/libc.so.6 (0x2)"
    CI_REPO_ROOT="${root}" CC="${t}" CXX="${t}" OUT="${out}" LIB_FUZZING_ENGINE=-fsanitize=fuzzer \
        run _ci_workload_fuzz_build
    [ "${status}" -eq 0 ]
    [ "$(grep -c 'src/distcc.c' "${t}.args")" -eq 0 ]
    grep -q -- '-Dmain=distccng_disabled_main_daemon .*src/daemon.c' "${t}.args"
    grep -q -- '-DSYSCONFDIR="/usr/local/etc"' "${t}.args"
    grep -q -- 'fuzz_x .*-fsanitize=fuzzer -lpopt' "${t}.args"
    [ -e "${out}/libpopt.so.0" ]
    [ ! -e "${out}/libc.so.6" ]
    printf '%s\n' 'prefix = /usr/local' > "${root}/Makefile"
    CI_REPO_ROOT="${root}" CC="${t}" CXX="${t}" OUT="${out}" LIB_FUZZING_ENGINE=-fsanitize=fuzzer \
        run _ci_workload_fuzz_build
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-WORKLOAD-0009"*"no sysconfdir"* ]]
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

# What: Merge-base diff, opt-out label, zero SHA, failed diff.
# Why: Only the PR's own changes or the label meet AG-REL-002.
# From: Issue #479, PR #544
@test "changelog check: merge-base diff, label, and bad input" {
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
    PR_LABELS="ci no-changelog-needed" run _ci_check_changelog
    [ "${status}" -eq 0 ]
    BASE=0000000000000000000000000000000000000000 HEAD=HEAD PR_LABELS="" run _ci_check_changelog
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-META-CHANGELOG-0002"* ]]
    _fail _ci_changed_paths 1 "[CI-ERROR-DIFF-0001] cannot diff"
    BASE=HEAD HEAD=HEAD PR_LABELS="" run _ci_check_changelog
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-DIFF-0001"* ]]
    [[ "${output}" != *"CI-ERROR-META-CHANGELOG-0001"* ]]
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

# What: PR, issue and empty payloads; the PAT decision.
# Why: Workflows forward neither; the board owner decides.
# From: Issue #479, PR #544
@test "add-to-project: payload values and the PAT decision" {
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

# What: Fuzz impact on a push, docs PR, fuzz PR, broken diff.
# Why: Only a PR diff may skip a class; a broken one fails.
# From: Issue #479, PR #544
@test "impact-hit runs every class off a PR, diffs on a PR, fails closed" {
    local out="${BATS_TEST_TMPDIR}/out"
    _print _ci_event_range b h
    _fail git 128
    GITHUB_OUTPUT="${out}" GITHUB_EVENT_NAME=pull_request run ci_cmd_impact_hit fuzz
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-DIFF-0001"* ]]
    : > "${out}"
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

# What: Dispatch, schedule, push diff, buildtools refs.
# Why: NOOP skips needed checks; only protected refs publish.
# From: Issue #479, PR #544
@test "plan: phases per event and the buildtools publish gate" {
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

# What: Two-OS and opt-in variants; backslashes in both.
# Why: Opt-in is never a PR gate; jq keeps values strings.
# From: Issue #479, PR #544
@test "matrix expands variant x os and excludes opt-in variants" {
    _fixture_manifest 'build_matrix:' '  variants:' '    a:' '      apt: "p"' '      brew: "q"' \
        '      os: [ubuntu-latest, macos-latest]' '    b:' '      apt: "r"' '      opt_in: true' \
        '      os: [ubuntu-latest]'
    run ci_cmd_matrix
    [ "${status}" -eq 0 ]
    [ "${output}" = '{"include":[{"variant":"a","os":"ubuntu-latest","apt":"p"},{"variant":"a","os":"macos-latest","brew":"q"}]}' ]
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
    _fake_tool distccd
    OUT_TEXT="--jobs --nice --listen --daemon --log-file --allow --user --port" run _ci_popt_fallback_smoke_test
    [ "${status}" -eq 0 ]
    OUT_TEXT="--jobs --nice" run _ci_popt_fallback_smoke_test
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-BUILD-POPT-0002"*"missing --listen"* ]]
    OUT_TEXT=boom RC=3 run _ci_popt_fallback_smoke_test
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

# What: popt variants by their SOT steps; bad step and flag.
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
    _fixture_manifest 'build_matrix:' '  variants:' '    v:' '      build_steps: ["make", "zap"]' \
        '    w:' '      ccache: "maybe"' '      build_steps: ["make"]'
    _forbid _ci_configure_tree
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run ci_cmd_build w
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0007"*"maybe"* ]]
    [[ "${output}" != *"must not run"* ]]
    _pass _ci_configure_tree
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run ci_cmd_build v
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0008"*'"zap"'* ]]
}

# What: Packages without alien, then with all tools; SBOM.
# Why: A missing tool fails first; the SBOM needs the tarball.
# From: Issue #479, PR #544
@test "package needs every packaging tool; SBOM needs the tarball" {
    local bin="${BATS_TEST_TMPDIR}/bin" root="${BATS_TEST_TMPDIR}/root" t
    mkdir -p "${bin}" "${root}"
    for t in python3 pkg-config eu-strip rpmbuild fakeroot; do
        _fake_tool "${bin}/${t}"
    done
    _print _ci_python python3
    _forbid _ci_configure_tree _ci_make_gated
    CI_REPO_ROOT="${root}" PATH="${bin}" run ci_cmd_package
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-PACKAGE-0001"*"missing tool: alien"* ]]
    [[ "${output}" != *"must not run"* ]]
    _fake_tool "${bin}/alien"
    _pass _ci_configure_tree
    _echoes _ci_make_gated
    CI_REPO_ROOT="${root}" PATH="${bin}" run ci_cmd_package
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"_ci_make_gated "*"deb"* ]]
    _echoes ci_cmd_sbom
    CI_REPO_ROOT="${root}" run _ci_package_sbom out.json
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-PACKAGE-0002"* ]]
    touch "${root}/distcc-9.9.tar.gz" "${root}/distcc-9.9.tar.bz2"
    CI_REPO_ROOT="${root}" run _ci_package_sbom out.json
    [ "${status}" -eq 0 ]
    [ "${output}" = "ci_cmd_sbom distcc-9.9.tar.gz out.json" ]
    touch "${root}/distcc-9.8.tar.gz"
    CI_REPO_ROOT="${root}" run _ci_package_sbom out.json
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-PACKAGE-0003"*"2 source tarballs"* ]]
}

# What: Every container variant and release action, stubbed.
# Why: Each builds its SOT image, pushes only its own tags.
# From: Issue #359, Issue #479, PR #544
@test "container variants build their SOT image and push only theirs" {
    local out="${BATS_TEST_TMPDIR}/out" base
    export GITHUB_REPOSITORY_OWNER=o
    base="$(_ci_sot_scalar release.images.distcc-ng-buildtools.ref)"
    base="${base%:*}"
    _echoes _ci_image_build _ci_registry_push
    _print _ci_built_sha abc1234
    GITHUB_OUTPUT="${out}" run ci_cmd_container nightly
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"_ci_image_build release.images.distcc-ng-nightly nightly --tag "*"distcc-ng-nightly:latest"* ]]
    [[ "${output}" == *"_ci_registry_push "*"distcc-ng-nightly:latest"* ]]
    grep -q '^image=.*distcc-ng-nightly:latest$' "${out}"
    _forbid _ci_registry_push
    run ci_cmd_container verify-image
    [ "${status}" -eq 0 ]
    [ "${output}" = "_ci_image_build release.images.distcc-ng-buildtools abc1234" ]
    _echoes _ci_registry_push
    run ci_cmd_container buildtools
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"_ci_registry_push ${base}:latest ${base}:abc1234"* ]]
    : > "${out}"
    GITHUB_OUTPUT="${out}" run ci_cmd_container build plain amd64 v9.9
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--platform linux/amd64 --tag"* ]]
    grep -q '^image=' "${out}"
    run ci_cmd_container build plain sparc v9.9
    [ "${status}" -eq 2 ]
    run ci_cmd_container push img:tag
    [ "${output}" = "_ci_registry_push img:tag" ]
    run ci_cmd_container bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CONTAINER-0001"* ]]
    run _ci_container_release bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CONTAINER-0004"* ]]
    _fail _ci_registry_push 1 "denied"
    GITHUB_OUTPUT="${out}" run ci_cmd_container nightly
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"denied"* ]]
}

# What: Image full-upgrade, runner install, timed-out dpkg.
# Why: Images are current; a cut dpkg run is finished first.
# From: Issue #493, Issue #479, PR #544
@test "apt install: image upgrade, runner install, dpkg retry" {
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
    APT_RC=124 run _ci_apt_install "p q" image
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"attempt 1/2: apt exited 124 (timed out after 6m)"* ]]
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

# What: Clean, warning, no log; make, configure, autogen fail.
# Why: Warnings are errors (AG-INT-003); each rc is checked.
# From: Issue #479, PR #544
@test "make gate and configure: warnings and tool failures fail" {
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
    _fail make 2 boom
    run _ci_make_gated "${BATS_TEST_TMPDIR}/m.log"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0004"* ]]
    cd "${BATS_TEST_TMPDIR}"
    _fake_tool autogen.sh
    _fake_tool configure 3
    run _ci_configure_tree "${BATS_TEST_TMPDIR}/c.log" --x
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0005"* ]]
    _fake_tool autogen.sh 4
    run _ci_configure_tree "${BATS_TEST_TMPDIR}/c.log" --x
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0003"* ]]
}

# What: OK+NOTRUN, a FAIL line, no result line, no log at all.
# Why: NOTRUN is a declared skip; nothing else may look green.
# From: Issue #479, PR #544
@test "comfychair parse: OK and NOTRUN pass, FAIL or nothing fails" {
    local log="${BATS_TEST_TMPDIR}/log" lines rc want
    while IFS='|' read -r lines rc want; do
        rm -f "${log}"
        [ "${lines}" = "-" ] || printf '%b\n' "${lines}" > "${log}"
        run _ci_parse_comfychair "${log}"
        [ "${status}" -eq "${rc}" ] || { echo "${lines}: rc ${status}: ${output}"; return 1; }
        [[ "${output}" == *"${want}"* ]] || { echo "${lines}: want ${want}: ${output}"; return 1; }
    done <<'EOF'
FooCase           OK\nBarCase           NOTRUN, needs root|0|
FooCase           OK\nBarCase           FAIL|1|[CI-ERROR-TEST-0002]
build noise, no result lines|1|[CI-ERROR-TEST-0001]
-|1|[CI-ERROR-TEST-0007]
EOF
}

# What: coverage test steps, then SOT step and env rows.
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
    _fixture_manifest 'build_matrix:' '  variants:' '    e:' '      test_steps: []' \
        '    s:' '      check_env: "K_ONE=a:b K_TWO=c"' '      test_steps: ["check"]' \
        '    b:' '      check_env: "not an env"' '      test_steps: ["check"]' \
        '    z:' '      test_steps: ["zap"]'
    run ci_cmd_test e
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"NotRun: variant=e has no test steps"* ]]
    # What: Stub make: print the env make check gets, as OK lines.
    # Why: The SOT check_env must reach make check, and only it.
    make() { printf '%s_Case OK\n' "${K_ONE:-none}" "${K_TWO:-none}"; }
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run ci_cmd_test s
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"a:b_Case OK"*"c_Case OK"* ]]
    [ -z "${K_ONE:-}" ]
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run ci_cmd_test b
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-TEST-0010"* ]]
    run ci_cmd_test z
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-TEST-0009"*'"zap"'* ]]
}

# What: Report pass/fail, with and without an issue; no token.
# Why: One standing issue; a no-op hides broken reporting.
# From: Issue #479, Issue #81, PR #476, PR #544
@test "report keeps one standing issue: comment, close or open" {
    _print _ci_run_url u
    _pass _ci_report_track
    # What: Stub gh: the issue list prints $EXISTING.
    # Why: Every branch depends on whether an issue is open.
    gh() { case "$*" in "issue list"*) echo "${EXISTING:-}" ;; esac; }
    export GH_TOKEN=x GITHUB_REPOSITORY=o/r GITHUB_SERVER_URL=https://h SCOPE=nightly DRY_RUN=true
    JOBS="a=success" run ci_cmd_report
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"nothing to do"* ]]
    EXISTING=9 JOBS="a=success" run ci_cmd_report
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"would run: gh issue close 9"* ]]
    EXISTING=9 JOBS=$'a=failure\nb=skipped' run ci_cmd_report
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"gh issue comment 9"*"Still\\ failing:"*"failed:\\ a"* ]]
    [[ "${output}" != *"issue create"* ]]
    JOBS="a=failure" run ci_cmd_report
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"would run: gh issue create"* ]]
    _fail gh 1 "HTTP 502"
    JOBS="a=failure" run ci_cmd_report
    [ "${status}" -eq 1 ]
    [[ "${output}" != *"would run"* ]]
    GH_TOKEN="" run ci_cmd_report
    [ "${status}" -ne 0 ]
}

# What: Bug type: already typed, untyped, no Bug type at all.
# Why: The standing issue must end up typed as a Bug.
# From: Issue #479, PR #476, PR #544
@test "report types its issue as Bug once and fails without the type" {
    # What: Stub gh graphql: the issue type is $TYPE, Bug is $BUG.
    # Why: Each branch depends on the issue's and repo's types.
    gh() {
        case "$*" in
            *"issue(number"*) echo "I1 ${TYPE:--}" ;;
            *"issueTypes"*) echo "${BUG:-}" ;;
        esac
    }
    TYPE=Bug DRY_RUN=true GITHUB_REPOSITORY=o/r run _ci_report_ensure_bug_type 9
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"would run"* ]]
    BUG=T1 DRY_RUN=true GITHUB_REPOSITORY=o/r run _ci_report_ensure_bug_type 9
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"would run: gh api graphql"*"issueId=I1"*"typeId=T1"* ]]
    DRY_RUN=true GITHUB_REPOSITORY=o/r run _ci_report_ensure_bug_type 9
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-REPORT-0001"* ]]
}

# What: Writes one- and two-line pairs, then a bare name.
# Why: A newline ends a k=v value; half a pair shifts all.
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
    GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/out" run _ci_output a 1 b
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0004"* ]]
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

# What: Offers two SOT files, then none and a missing file.
# Why: Upload needs the SOT name; no files is no artifact.
# From: Issue #479, PR #544
@test "artifact offer writes SOT name, files, retention; needs files" {
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
    rm -f "${out}"
    GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/out" run _ci_artifact_offer k ""
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-ARTIFACT-0001"* ]]
    GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/out" run _ci_artifact_offer k "" "${BATS_TEST_TMPDIR}/none"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-ARTIFACT-0002"* ]]
    [ ! -s "${BATS_TEST_TMPDIR}/out" ]
}

# What: Keys over a README and an m4 edit; no-ccache variant.
# Why: Autoconf inputs key the cache; no ccache, no plan.
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
    rm -f "${out}"
    _forbid ccache
    GITHUB_OUTPUT="${out}" run ci_cmd_cache coverage
    [ "${status}" -eq 0 ]
    [ ! -e "${out}" ]
}

# What: CFL crash with a reproducer, then rc 3 with none.
# Why: Crashes are offered; the fuzz rc is never swallowed.
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
    rm -rf "${out}" "${RUNNER_TEMP}/cfl-workspace"
    _fail _ci_cfl_run 3
    mkdir -p "${RUNNER_TEMP}/cfl-workspace/out/artifacts"
    GITHUB_OUTPUT="${out}" run ci_cmd_clusterfuzzlite_run address
    [ "${status}" -eq 3 ]
    [ ! -e "${out}" ]
}

# What: Drafts on list and auth errors; groups a fix PR body.
# Why: No write after an API error; notes follow categories.
# From: Issue #479, PR #544
@test "draft release stops on API errors and groups PRs by category" {
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
            "api --paginate") echo v1.0-NG ;;
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
            "api --paginate") echo "HTTP 401: Bad credentials" >&2; return 1 ;;
        esac
    }
    DRY_RUN=true GH_TOKEN=x GITHUB_REPOSITORY=o/r run _ci_publish_draft_release
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-PUBLISH-0010"*"Bad credentials"* ]]
    [[ "${output}" != *"would run: gh release"* ]]
    # What: Stub gh: the merged-PR list fills its limit.
    # Why: A cut list must stop the draft, not shorten it.
    gh() {
        case "$1 $2" in
            "release list") echo 2026-01-01 ;;
            "pr list") jq -cn '[range(1000) | {number: ., title: "fix(ci): x"}]' ;;
        esac
    }
    DRY_RUN=true GH_TOKEN=x GITHUB_REPOSITORY=o/r run _ci_publish_draft_release
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-PUBLISH-0012"* ]]
    [[ "${output}" != *"would run: gh release"* ]]
    local body=""
    _ci_draft_release_append body "Fixed" "* #5 | fix(ci): a"
    [ "${body}" = "$(printf '%s\n%s\n' '### Fixed' '* #5 | fix(ci): a')
" ]
}

# What: API, local and verdict checks; BR-01 checkout scope.
# Why: A tool or API failure is never a compliance finding.
# From: Issue #312, Issue #479, PR #544
@test "OpenSSF checks give no verdict on a tool or API error" {
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
    local doc="${BATS_TEST_TMPDIR}/security.md"
    printf 'has Security Advisory here\n' > "${doc}"
    [ "$(_ci_ossf_verdict grep -q 'Security Advisor' "${doc}")" = "Met" ]
    [ "$(_ci_ossf_verdict grep -q 'nope-xyz' "${doc}")" = "NotMet" ]
    [ "$(_ci_ossf_verdict grep -qi 'SECURITY ADVISOR' "${doc}")" = "Met" ]
    run _ci_ossf_verdict grep -q 'x' "${BATS_TEST_TMPDIR}/missing"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-OSSF-0004"* ]]
    [[ "${output}" != *"NotMet"* ]]
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

# What: Recheck regression, first post, list error; add_met.
# Why: One comment per state; only Met adds a proposal pair.
# From: Issue #312, Issue #479, PR #544
@test "openssf recheck flags a regression and edits its one comment" {
    _print _ci_run_url u
    # What: Stub verdicts: BR-07 is NotMet, all others Met.
    # Why: One regressed criterion must leave the proposal link.
    _ci_ossf_verdict() { case "$*" in *br07*) echo NotMet ;; *) echo Met ;; esac; }
    # What: Stub gh: comment list prints $EXISTING, body a state.
    # Why: The previous state says BR-07 was Met last time.
    gh() {
        case "$*" in
            *"/comments --paginate"*) echo "${EXISTING:-}" ;;
            *"issues/comments/"*"--jq"*) echo 'x <!-- openssf-baseline-recheck-state: {"BR-07":"Met"} -->' ;;
        esac
    }
    EXISTING=77 DRY_RUN=true GITHUB_REPOSITORY=o/r run _ci_scan_openssf
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"## REGRESSED"*"- BR-07"* ]]
    [[ "${output}" == *"osps_ac_03.01_status=Met"* ]]
    [[ "${output}" != *"osps_br_07"* ]]
    [[ "${output}" == *"would run: gh api --method PATCH repos/o/r/issues/comments/77"* ]]
    DRY_RUN=true GITHUB_REPOSITORY=o/r run _ci_scan_openssf
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"REGRESSED"* ]]
    [[ "${output}" == *"would run: gh api --method POST"* ]]
    _fail gh 1 "HTTP 502"
    DRY_RUN=true GITHUB_REPOSITORY=o/r run _ci_scan_openssf
    [ "${status}" -eq 1 ]
    [[ "${output}" != *"would run"* ]]
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

# What: Bad JSON, a 2-child index, a tag inspect that fails.
# Why: Unknown children would otherwise lose protection.
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
    _fail docker 1
    GITHUB_REPOSITORY_OWNER=wiki-mod run _ci_gc_protected_digests distcc-ng '[{"metadata":{"container":{"tags":["latest"]}}}]'
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GC-0002"* ]]
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

# What: Filter, pass, real failure; blank, colon, typo lists.
# Why: Only success or skipped passes; a bad list never does.
# From: Issue #479, PR #544
@test "gate passes success and skipped only; bad JOBS lists fail" {
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
    run _ci_failed_jobs "$(printf 'build=success\ne2e=failure\npublish=skipped\nx=cancelled\n')"
    [ "${status}" -eq 0 ]
    [ "${output}" = "e2e x" ]
    JOBS="$(printf 'build=success\ne2e=skipped\n')" run ci_cmd_gate
    [ "${status}" -eq 0 ]
    JOBS="$(printf 'build=success\ne2e=failure\n')" run ci_cmd_gate
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GATE-0001"* ]]
}

# What: Docs, c-source, SOT/engine, include-server, unmatched.
# Why: A misrouted diff runs wrong jobs or skips needed ones.
# From: Issue #479, PR #544
@test "impact: each path class selects exactly its phases" {
    run _ci_phases_for_paths < <(printf '%s\n' README.md doc/threat-model.md)
    [ "${status}" -eq 0 ]
    [ "${output}" = "NOOP" ]
    run _ci_phases_for_paths < <(printf '%s\n' src/dopt.c)
    [ "${status}" -eq 0 ]
    [ "$(tr '\n' ' ' <<< "${output}")" = "build e2e package " ]
    local p
    for p in .github/yaml/build-manifest.yml .github/scripts/ci.sh; do
        run _ci_phases_for_paths < <(printf '%s\n' "${p}")
        [ "$(tr '\n' ' ' <<< "${output}")" = "build container e2e package verify " ]
    done
    run _ci_phases_for_paths < <(printf '%s\n' include_server/basics.py)
    [ "${status}" -eq 0 ]
    [ "$(tr '\n' ' ' <<< "${output}")" = "build e2e " ]
    run _ci_phases_for_paths < <(printf '%s\n' LICENSE)
    [ "${status}" -eq 0 ]
    [ "${output}" = "NOOP" ]
}



# What: Guards every workflow, then a copy missing one bound.
# Why: The copy proves the timeout guard can fail at all.
# From: Issue #479, PR #544
@test "the timeout guard fails on a job with no timeout-minutes" {
    local fx="${BATS_TEST_TMPDIR}/validate.yml"
    run ci_guard_job_timeouts "${CI_REPO_ROOT}"/.github/workflows/*.yml
    [ "${status}" -eq 0 ]
    awk '/^  plan:$/ { p = 1 } p && /^    timeout-minutes:/ { p = 0; next } { print }' \
        "${CI_REPO_ROOT}/.github/workflows/validate.yml" > "${fx}"
    run ci_guard_job_timeouts "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-TIME-0001"*"${fx} plan has no timeout-minutes"* ]]
}

# What: Each command resolves to its function; a gap fails.
# Why: CI_COMMANDS is the one list; a typo must not skip.
# From: Issue #479, PR #544
@test "every CI_COMMANDS entry dispatches to its ci_cmd function" {
    local c missing=""
    for c in ${CI_COMMANDS}; do
        declare -F "ci_cmd_${c//-/_}" >/dev/null || missing+=" ${c}"
    done
    [ -z "${missing}" ]
    _echoes ci_cmd_impact_hit
    run ci_main impact-hit a1
    [ "${status}" -eq 0 ]
    [ "${output}" = "ci_cmd_impact_hit a1" ]
    CI_COMMANDS="${CI_COMMANDS} zap" run ci_main zap
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0001"*"ci_cmd_zap"* ]]
}

# What: Real c-source class, an exclude hit, a matcher error.
# Why: A misrouted path runs wrong jobs; an error is no miss.
# From: Issue #479
@test "classify: path map hits, excludes, and matcher errors" {
    run _ci_classify_paths < <(printf '%s\n' src/dopt.c)
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"c-source"* ]]
    _fixture_manifest 'labels:' '  documentation:' '    paths: ["doc/**", "**/*.md"]' \
        '    exclude: ["CHANGELOG.md"]' '  ci:' '    paths: [".github/workflows/**"]'
    run _ci_classify_paths labels <<< "CHANGELOG.md"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    run _ci_classify_paths labels < <(printf '%s\n' CHANGELOG.md README.md .github/workflows/v.yml)
    [ "${output}" = "$(printf '%s\n' ci documentation)" ]
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

# What: prefix.* match and reject; '**/' at the top level.
# Why: '*' matches any text; '**/' also covers depth zero.
# From: Issue #479
@test "glob match: prefix.*, unrelated files, top-level '**/'" {
    run _ci_glob_match "src/config-parser.*" "src/config-parser.c"
    [ "${status}" -eq 0 ]
    run _ci_glob_match "src/config-parser.*" "src/unrelated.c"
    [ "${status}" -ne 0 ]
    run _ci_glob_match "**/*.md" "README.md"
    [ "${status}" -eq 0 ]
    run _ci_glob_match "**/*.md" "doc/a/b.md"
    [ "${status}" -eq 0 ]
    run _ci_glob_match "**/*.md" "README.mdx"
    [ "${status}" -ne 0 ]
}

# What: Labels PR 5 (one workflow file), then a short list.
# Why: The board and release notes read these labels.
# From: Issue #479, PR #544
@test "label-pr applies path labels and the title category" {
    local ev="${BATS_TEST_TMPDIR}/ev.json"
    printf '{"pull_request":{"number":5,"changed_files":1}}' > "${ev}"
    _fixture_manifest 'labels:' '  ci:' '    paths: [".github/workflows/**"]'
    # What: Stub gh: one workflow file; echo pr edit.
    # Why: Labels must come from the SOT path map.
    gh() {
        case "$1 $2" in
            "api --paginate") [ "$3" = "repos/o/r/pulls/5/files" ] && echo .github/workflows/v.yml ;;
            "pr edit") echo "edit $*" ;;
        esac
    }
    # What: Stub live PR data with a fix(ci) title.
    # Why: The title sets the category label offline.
    _ci_metadata_fetch_live() { export PR_TITLE="fix(ci): x"; }
    GITHUB_REPOSITORY=o/r GITHUB_EVENT_PATH="${ev}" run _ci_variables_label_pr
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--add-label ci,bug"* ]]
    printf '{"pull_request":{"number":5,"changed_files":3001}}' > "${ev}"
    GITHUB_REPOSITORY=o/r GITHUB_EVENT_PATH="${ev}" run _ci_variables_label_pr
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0002"*"lists 1 of 3001"* ]]
    [[ "${output}" != *"edit "* ]]
}

# What: AG-GH-014 types, an untyped title, a malformed title.
# Why: Release notes have four categories; others get none.
# From: Issue #479
@test "pr category: label per type, none for other titles" {
    [ "$(_ci_pr_category_label 'feat(pump): add IPv6')" = "enhancement" ]
    [ "$(_ci_pr_category_label 'fix(protocol): correct frame bug')" = "bug" ]
    [ "$(_ci_pr_category_label 'docs(governance): add rule')" = "documentation" ]
    [ "$(_ci_pr_category_label 'security(config): patch leak')" = "security" ]
    [ -z "$(_ci_pr_category_label 'chore(ci): bump a dependency')" ]
    run _ci_pr_category_label 'fix stuff'
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
    run _ci_title_type 'fix(ci)!: x'
    [ "${output}" = "fix" ]
    run _ci_title_type 'fix stuff'
    [ "${status}" -eq 1 ]
}

# What: An LF-only tree, then a CRLF file.
# Why: CR is the only byte the guard may reject.
# From: Issue #479
@test "line-endings guard passes LF and fails on CRLF" {
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"; printf 'clean line\n' > "${fx}/ok.sh"
    run ci_guard_line_endings "${fx}"
    [ "${status}" -eq 0 ]
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"; printf 'bad line\r\n' > "${fx}/crlf.sh"
    run ci_guard_line_endings "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-EOL-0001"* ]]
}

# What: A 64-hex digest, then an abbreviated one.
# Why: A full digest is the only accepted pin form.
# From: Issue #479
@test "full-sha guard passes 64 hex and fails a short digest" {
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"
    printf 'image: "debian@sha256:fac46bff2e02f51425b6e33b0e1169f55dfb053d83511ca28aa50c09fd5ed7a4"\n' > "${fx}/f.yml"
    run ci_guard_full_sha "${fx}"
    [ "${status}" -eq 0 ]
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"; printf 'image: "debian@sha256:fac46bff"\n' > "${fx}/f.yml"
    run ci_guard_full_sha "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-SHA-0001"* ]]
}

# What: Empty tree, no input, missing path, unreadable root.
# Why: A guard that checked nothing must not report a pass.
# From: Issue #479, PR #544
@test "guards fail closed when they find nothing to check" {
    local fx="${BATS_TEST_TMPDIR}/fx" guard id arg
    mkdir -p "${fx}"
    run ci_guard_comment_format "${fx}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GUARD-COMMENT-0002"* ]]
    run ci_guard_shellcheck_directives "${fx}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GUARD-SHELLCHECK-0004"* ]]
    run ci_guard_orchestrator_only
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GUARD-ORCH-0002"*"no input path given"* ]]
    while IFS='|' read -r guard id; do
        run "${guard}" "${fx}/none"
        [ "${status}" -eq 2 ] || { echo "${guard}: rc ${status}: ${output}"; return 1; }
        [[ "${output}" == *"[CI-ERROR-GUARD-${id}]"*"input ${fx}/none does not exist"* ]] \
            || { echo "${guard}: want ${id}: ${output}"; return 1; }
    done <<'EOF'
ci_guard_line_endings|EOL-0002
ci_guard_comment_format|COMMENT-0003
ci_guard_shellcheck_directives|SHELLCHECK-0005
ci_guard_full_sha|SHA-0002
ci_guard_sot_mirrors|MIRROR-0011
ci_guard_path_mirrors|MIRROR-0012
ci_guard_pins_in_sot|PIN-0006
ci_guard_orchestrator_only|ORCH-0002
ci_guard_job_timeouts|TIME-0002
ci_guard_error_ids|ERRID-0002
EOF
    for arg in "" "${fx}/none"; do
        run ci_guard_job_timeouts ${arg:+"${arg}"}
        [ "${status}" -eq 2 ]
    done
    run ci_guard_line_endings "${BATS_TEST_TMPDIR}/nope"
    [ "${status}" -eq 2 ]
    run ci_guard_full_sha "${BATS_TEST_TMPDIR}/nope"
    [ "${status}" -eq 2 ]
}

# What: ARG, stage, :local FROMs; pins outside; unused action.
# Why: No image or action may bypass or rot in the SOT.
# From: Issue #479, PR #544
@test "pin guard: allowed FROMs, pins outside, unused actions" {
    local fx="${BATS_TEST_TMPDIR}/fx"
    _fixture_actions
    mkdir -p "${fx}/d" "${fx}/.github/workflows"
    printf '%s\n' 'ARG BASE' 'FROM ${BASE} AS one' 'FROM one AS two' 'FROM x-y:local' > "${fx}/d/Dockerfile"
    printf '%s\n' 'jobs:' '  container:' '    steps:' '      - run: bash .github/scripts/ci.sh build' \
        "      - uses: ${FX_PIN}" > "${fx}/.github/workflows/w.yml"
    run ci_guard_pins_in_sot "${fx}"
    [ "${status}" -eq 0 ]
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

# What: Security crons, PRs, dispatch refs; housekeeping.
# Why: The workflow holds no cron and no event decision.
# From: Issue #479, PR #544
@test "route: security and housekeeping jobs per event" {
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
    : > "${out}"
    _fixture_manifest 'schedules:' '  housekeeping_weekly:' '    workflow: "housekeeping"' '    cron: "0 5 * * 1"' \
        'housekeeping_tasks:' '  gc:' '    weekly: "false"' '  sot-update:' '    weekly: "true"' \
        '  heartbeat:' '    weekly: "true"'
    echo '{"schedule":"0 5 * * 1"}' > "${ev}"
    GITHUB_OUTPUT="${out}" GITHUB_EVENT_PATH="${ev}" GITHUB_EVENT_NAME=schedule run ci_cmd_route housekeeping
    [ "$(tr '\n' ' ' < "${out}")" = "gc=false sot_update=true heartbeat=true " ]
    : > "${out}"
    echo '{"inputs":{"task":"gc"}}' > "${ev}"
    GITHUB_OUTPUT="${out}" GITHUB_EVENT_PATH="${ev}" GITHUB_EVENT_NAME=workflow_dispatch run ci_cmd_route housekeeping
    [ "$(tr '\n' ' ' < "${out}")" = "gc=true sot_update=false heartbeat=false " ]
    : > "${out}"
    echo '{"inputs":{"task":"zap"}}' > "${ev}"
    GITHUB_OUTPUT="${out}" GITHUB_EVENT_PATH="${ev}" GITHUB_EVENT_NAME=workflow_dispatch run ci_cmd_route housekeeping
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-ROUTE-0002"*"zap"* ]]
    [ ! -s "${out}" ]
    run ci_cmd_route nightly
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-ROUTE-0001"* ]]
}

# What: Real tree; drift in cron, options, milestone, wiring.
# Why: All are literal YAML; the SOT owns their values.
# From: Issue #479, PR #544
@test "mirror guard passes the real tree and fails closed on drift" {
    local fx="${BATS_TEST_TMPDIR}/fx"
    run ci_guard_sot_mirrors "${CI_REPO_ROOT}"
    [ "${status}" -eq 0 ]
    mkdir -p "${fx}/.github/workflows"
    _fixture_manifest 'schedules:' '  n:' '    workflow: "w"' '    cron: "0 1 * * *"' \
        'release:' '  ghcr_packages: ["p"]' 'bot_milestone:' '  number: "3"' \
        'housekeeping_tasks:' '  gc:' '    weekly: "false"'
    printf '%s\n' 'on:' '  schedule:' "    - cron: '0 2 * * *'" > "${fx}/.github/workflows/w.yml"
    printf '%s\n' 'on:' '  workflow_dispatch:' '    inputs:' '      task:' '        options:' '          - gc' \
        '          - zap' '      package:' '        options:' \
        '          - all' '          - q' '        default: all' > "${fx}/.github/workflows/housekeeping.yml"
    printf '%s\n' 'updates:' '  - package-ecosystem: a' '    milestone: 4' '  - package-ecosystem: b' \
        > "${fx}/.github/dependabot.yml"
    run ci_guard_sot_mirrors "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-MIRROR-0001"*"0 2 * * *"* ]]
    [[ "${output}" == *"CI-ERROR-GUARD-MIRROR-0002"* ]]
    [[ "${output}" == *"CI-ERROR-GUARD-MIRROR-0003"* ]]
    [[ "${output}" == *"CI-ERROR-GUARD-MIRROR-0004"*"> zap"* ]]
    mkdir -p "${fx}/.clusterfuzzlite"
    _fixture_manifest 'impact_classes:' '  c:' '    paths: ["src/**"]' '    phases: ["build", "e2e"]' \
        'security:' '  cfl_base:' '    tag: "b:local"' 'schedules:' '  n:' '    workflow: "validate"' '    cron: "0 1 * * *"'
    printf '%s\n' 'on:' '  schedule:' "    - cron: '0 1 * * *'" 'jobs:' '  build_test:' \
        "    if: needs.plan.outputs.build == 'true'" \
        '    steps:' '      - run: bash .github/scripts/ci.sh build x' '  e2e:' \
        "    if: contains(needs.plan.outputs.phases, 'e2e')" '    steps:' \
        '      - run: bash .github/scripts/ci.sh lint' > "${fx}/.github/workflows/validate.yml"
    printf '%s\n' 'FROM other:local' > "${fx}/.clusterfuzzlite/Dockerfile"
    rm -f "${fx}/.github/workflows/housekeeping.yml" "${fx}/.github/dependabot.yml" "${fx}/.github/workflows/w.yml"
    run ci_guard_sot_mirrors "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-MIRROR-0009"*"SOT phase e2e gates no validate.yml job"* ]]
    [[ "${output}" != *"SOT phase build"* ]]
    [[ "${output}" == *"CI-ERROR-GUARD-MIRROR-0010"*"FROM b:local"* ]]
}

# What: Clean fixture tree, then one drift per path mirror.
# Why: A Dockerfile repeats ci.sh paths it cannot read itself.
# From: Issue #479, PR #544
@test "path mirror guard binds Dockerfile paths and SOT refs to ci.sh" {
    local fx="${BATS_TEST_TMPDIR}/fx"
    mkdir -p "${fx}/docker/release" "${fx}/.clusterfuzzlite"
    printf '%s\n' "RUN --mount=type=bind,target=${CI_CONTAINER_ROOT},rw bash x" \
        "COPY --from=build ${CI_RELEASE_OUT}/ /" "COPY --from=build ${CI_RELEASE_PUMP_OUT}/usr/local/ /usr/local/" \
        > "${fx}/docker/release/Dockerfile"
    printf '%s\n' "COPY . \$SRC/${CI_CFL_PROJECT}" > "${fx}/.clusterfuzzlite/Dockerfile"
    _fixture_manifest 'release:' '  images:' '    a:' "      ref: \"${CI_REGISTRY}/o/a:latest\""
    run ci_guard_path_mirrors "${fx}"
    [ "${status}" -eq 0 ]
    printf '%s\n' 'RUN --mount=type=bind,target=/src bash x' 'COPY --from=build /stage/ /' \
        > "${fx}/docker/release/Dockerfile"
    printf '%s\n' 'COPY . $SRC/other' > "${fx}/.clusterfuzzlite/Dockerfile"
    _fixture_manifest 'release:' '  images:' '    a:' '      ref: "docker.io/o/a:latest"'
    run ci_guard_path_mirrors "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-MIRROR-0005"*"bind target /src is not ${CI_CONTAINER_ROOT}"* ]]
    [[ "${output}" == *"CI-ERROR-GUARD-MIRROR-0006"*"COPY source /stage/ is no ci.sh release tree"* ]]
    [[ "${output}" == *"CI-ERROR-GUARD-MIRROR-0006"*"no COPY from ${CI_RELEASE_PUMP_OUT}/"* ]]
    [[ "${output}" == *"CI-ERROR-GUARD-MIRROR-0007"*"COPY target \$SRC/other"* ]]
    [[ "${output}" == *"CI-ERROR-GUARD-MIRROR-0008"*"release.images.a.ref=docker.io/o/a:latest"* ]]
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

# What: Blocks, directives, heredocs; prose, gaps, no block.
# Why: Comments are What/Why/From; heredocs are not prose.
# From: Issue #479, PR #544
@test "comment guard: allowed forms and every violation" {
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
    [[ "${output}" == *"[CI-LINT] NotRun: docker absent under ${fx}"* ]]
    printf '%s\n' '#!/usr/bin/env bash' '# ====' '# SECTION' '# ====' 'x=1' > "${fx}/.github/a.sh"
    run ci_guard_comment_format "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"a.sh:3: not a What/Why/From line"* ]]
    local fx="${BATS_TEST_TMPDIR}/fx" hd='<<'
    mkdir -p "${fx}/.github"
    printf '%s\n' "cat ${hd}EOF" 'text' '# free prose after' > "${fx}/.github/b.sh"
    run ci_guard_comment_format "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"b.sh:1: heredoc EOF never ends"* ]]
    local fx="${BATS_TEST_TMPDIR}/fx"
    mkdir -p "${fx}/.github/workflows"
    printf '%s\n' '# Some free prose.' 'a: 1' '# What: Only a what.' 'b: 2' \
        "# What: $(printf 'x%.0s' {1..60})" '# Why: ok' 'c: 3' \
        '# What: x' '# Why: y' '# From: Issue #1, AG-GH-014' 'd: 4' \
        '# What: x' '# Why: y' '# From: Issue #1 #2, PR #3' 'e: 5' > "${fx}/.github/workflows/w.yml"
    run ci_guard_comment_format "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"w.yml:1: not a What/Why/From line"* ]]
    [[ "${output}" == *"w.yml:3: block needs one What, one Why"* ]]
    [[ "${output}" == *"w.yml:5: longer than 60 characters"* ]]
    [[ "${output}" == *"w.yml:10: From names something not an Issue or PR"* ]]
    [[ "${output}" != *"w.yml:14:"* ]]
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

# What: Clean tree, each banned text, no or empty SOT list.
# Why: AG-INT-003: presence is the violation; no list fails.
# From: Issue #479, PR #544
@test "directive guard: clean tree, banned texts, no SOT list" {
    local fx="${BATS_TEST_TMPDIR}/fx"
    mkdir -p "${fx}/lib" "${fx}/.github"
    printf '%s\n' '#!/usr/bin/env bash' 'y=1' > "${fx}/lib/real.sh"
    printf '%s\n' '#!/usr/bin/env bash' '# shellcheck source=lib/real.sh' '. lib/real.sh' \
        > "${fx}/.github/a.sh"
    run ci_guard_shellcheck_directives "${fx}"
    [ "${status}" -eq 0 ]
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
        ci_guard_orchestrator_only ci_guard_job_timeouts ci_guard_comment_format _ci_lint_actionlint \
        _ci_lint_shellcheck
    CI_REPO_ROOT="${fx}" run ci_cmd_lint
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"NotRun: docker absent under ${fx}"* ]]
    printf '%s\n' '#!/bin/sh' "# ${texts[0]}SC2086" 'x=1' > "${fx}/contrib/tool"
    CI_REPO_ROOT="${fx}" run ci_cmd_lint
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"contrib/tool:2: banned shell text"* ]]
}

# What: One-command run:, inline logic, SOT uses:, bad inputs.
# Why: #479 lets a step call ci.sh or move ci.sh outputs only.
# From: Issue #479
@test "orchestrator guard: allowed steps and each violation" {
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"
    printf 'jobs:\n  x:\n    steps:\n      - run: bash .github/scripts/ci.sh build\n' > "${fx}/wf.yml"
    run ci_guard_orchestrator_only "${fx}/wf.yml"
    [ "${status}" -eq 0 ]
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"
    printf 'jobs:\n  x:\n    steps:\n      - run: |\n          if [ -x foo ]; then bar; fi\n' > "${fx}/wf.yml"
    run ci_guard_orchestrator_only "${fx}/wf.yml"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-ORCH-0001"* ]]
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"
    _fixture_actions
    printf '%s\n' 'jobs:' '  x:' '    steps:' '      - run: |' '          bash .github/scripts/ci.sh cache default' \
        "      - if: steps.c.outputs.key != ''" "        uses: ${FX_PIN}" '        with:' \
        '          path: ${{ steps.c.outputs.path }}' '          restore-keys: ${{ steps.c.outputs.restore_keys }}' \
        '        env:' '          A: b' '      - run: bash .github/scripts/ci.sh build' > "${fx}/wf.yml"
    run ci_guard_orchestrator_only "${fx}/wf.yml"
    [ "${status}" -eq 0 ]
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"
    _fixture_actions
    printf '%s\n' 'jobs:' '  x:' '    steps:' '      - uses: ./.github/actions/foo' '      - uses: o/a@v1' \
        "      - uses: o/a@$(printf 'b%.0s' {1..40}) # v1" > "${fx}/wf.yml"
    run ci_guard_orchestrator_only "${fx}/wf.yml"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"wf.yml:4: uses: ./.github/actions/foo is not an SOT action pin"* ]]
    [[ "${output}" == *"wf.yml:5: uses: o/a@v1 is not an SOT action pin"* ]]
    [[ "${output}" == *"wf.yml:6: uses: o/a@bbbb"* ]]
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

# What: SOT ARGs, target, tag; labels and version; bad spec.
# Why: The only path a pin takes into a build; bad specs stop.
# From: Issue #359, Issue #479, PR #544
@test "image build: SOT ARGs, labels, version, bad spec first" {
    local d; d="$(printf 'a%.0s' {1..64})"
    _fixture_manifest 'base:' "  img: \"b@sha256:${d}\"" 's:' '  x:' '    dockerfile: "d/Dockerfile"' \
        '    target: "t"' '    args: ["A=base.img"]' '    tag: "x:local"'
    _capture_docker
    run _ci_image_build s.x "" --pull
    [ "${status}" -eq 0 ]
    [ "$(tr '\n' ' ' < "${BATS_TEST_TMPDIR}/argv")" = "build --pull --file ${CI_REPO_ROOT}/d/Dockerfile --target t --build-arg A=b@sha256:${d} --tag x:local ${CI_REPO_ROOT} " ]
    rm -f "${BATS_TEST_TMPDIR}/argv"
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
    rm -f "${BATS_TEST_TMPDIR}/argv"
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

# What: Alone, inside a stack, and without -- before the cmd.
# Why: --init reaps zombies; a stack run joins its net.
# From: Issue #479, PR #544
@test "container run: alone, in a stack, and argv checks" {
    _capture_docker
    run _ci_container_run img -e K=V -- bash x
    [ "${status}" -eq 0 ]
    [ "$(tr '\n' ' ' < "${BATS_TEST_TMPDIR}/argv")" = "run --init -v ${CI_REPO_ROOT}:/ci:ro --rm -e K=V img bash x " ]
    rm -f "${BATS_TEST_TMPDIR}/argv"
    _capture_docker
    CI_STACK=n1 run _ci_container_run img -d --
    [ "${status}" -eq 0 ]
    [ "$(tr '\n' ' ' < "${BATS_TEST_TMPDIR}/argv")" = "run --init -v ${CI_REPO_ROOT}:/ci:ro --network n1 --label ci-stack=n1 -d img " ]
    _forbid docker
    run _ci_container_run img -e K=V
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CONTAINER-0003"* ]]
    [[ "${output}" != *"must not run"* ]]
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

# What: Probe passing on try 3, a false one, a probe error.
# Why: One bounded poll owner; a probe error stops at once.
# From: Issue #479, PR #544
@test "wait-until: retries, gives up after N, stops on error" {
    _pass sleep
    # What: Probe that succeeds on its third call.
    # Why: Two failures before a pass exercise the retry.
    _probe() { echo x >> "${BATS_TEST_TMPDIR}/tries"; [ "$(wc -l < "${BATS_TEST_TMPDIR}/tries")" -ge 3 ]; }
    run _ci_wait_until 5 1 _probe
    [ "${status}" -eq 0 ]
    [ "$(wc -l < "${BATS_TEST_TMPDIR}/tries")" -eq 3 ]
    run _ci_wait_until 2 1 false
    [ "${status}" -eq 1 ]
    rm -f "${BATS_TEST_TMPDIR}/tries"
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

# What: curl failing every try, then a dropped connection.
# Why: A failed fetch names its URL; a drop is retried.
# From: Issue #479, PR #544
@test "download: names a failed URL, retries a dropped one" {
    _fail curl 22
    _pass sleep
    run _ci_download "https://h/x.tar.gz" "${BATS_TEST_TMPDIR}/x"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"attempt 3/3 failed"* ]]
    [[ "${output}" == *"CI-ERROR-FETCH-0003"*"https://h/x.tar.gz"* ]]
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

# What: Tarball, bare binary, sha256 gate, stuck partial dir.
# Why: Only a pinned, matching download may be installed.
# From: Issue #479, PR #544
@test "tool fetch: url, tarball, bare binary, sha256 gate" {
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
    local sum
    printf 'exe' > "${BATS_TEST_TMPDIR}/raw"
    sum="$(sha256sum "${BATS_TEST_TMPDIR}/raw" | cut -d' ' -f1)"
    _fixture_manifest 'x:' '  osv:' '    version: "v2"' '    url: "https://h/osv"' \
        "    sha256: \"${sum}\"" '    archive: "binary"' '    bin: "osv-scanner"'
    _fake_curl "${BATS_TEST_TMPDIR}/raw"
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _ci_tool_bin x.osv
    [ "${status}" -eq 0 ]
    [ "$(cat "${output}")" = "exe" ]
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

# What: Two image pins, a tool, a manual pin; a tagless pin.
# Why: ci.sh is the sole pin owner; no tag means no refresh.
# From: Issue #479, PR #544
@test "sot refresh: digests and tools; a tagless pin fails" {
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
    _ci_sot_index_drop
    [ "$(_ci_sot_scalar base_images.deb)" = "debian:trixie@sha256:${b}" ]
    [ "$(_ci_sot_scalar external_services.red)" = "redis:8@sha256:${b}" ]
    [ "$(_ci_sot_scalar external_versions.t.version)" = "v1.10.0" ]
    [ "$(_ci_sot_scalar external_versions.t.sha256)" = "${c}" ]
    [ "$(_ci_sot_scalar external_versions.manual.version)" = "1" ]
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

# What: Trivy and syft via a fake tool: pass, fail, no tool.
# Why: A finding or a scanner error must fail the scan step.
# From: Issue #479, PR #544
@test "trivy and sbom pass the tool's exit on, with the SOT flags" {
    local t="${BATS_TEST_TMPDIR}/tool"
    _fake_tool "${t}"
    _print _ci_tool_bin "${t}"
    run ci_cmd_trivy_scan img:1
    [ "${status}" -eq 0 ]
    grep -q -- '--severity HIGH,CRITICAL' "${t}.args"
    grep -q -- '--exit-code 1' "${t}.args"
    grep -q -- '--ignorefile .*/.trivyignore.yaml' "${t}.args"
    RC=1 run ci_cmd_trivy_scan img:1
    [ "${status}" -eq 1 ]
    run ci_cmd_sbom img:1 out.json
    [ "${status}" -eq 0 ]
    grep -q -- 'img:1 -o spdx-json=out.json' "${t}.args"
    RC=3 run ci_cmd_sbom img:1 out.json
    [ "${status}" -eq 3 ]
    _fail _ci_tool_bin 2 "no pin"
    run ci_cmd_trivy_scan img:1
    [ "${status}" -eq 2 ]
    run ci_cmd_sbom img:1 out.json
    [ "${status}" -eq 2 ]
}

# What: Scorecard JSON to SARIF, then the tool and jq failing.
# Why: Only a real SARIF of the run may reach the upload step.
# From: Issue #479, PR #544
@test "scorecard converts its JSON to SARIF and fails closed" {
    local t="${BATS_TEST_TMPDIR}/tool" out="${BATS_TEST_TMPDIR}/s.sarif"
    _fake_tool "${t}"
    _print _ci_tool_bin "${t}"
    _pass _ci_artifact_offer
    OUT_TEXT='{"scorecard":{"version":"v5"},"checks":[{"name":"A","score":10,"reason":"ok","documentation":{"short":"a","url":"u"}},{"name":"B","score":2,"reason":"low","details":["d"],"documentation":{"short":"b","url":"u"}}]}' \
        GITHUB_REPOSITORY=o/r RUNNER_TEMP="${BATS_TEST_TMPDIR}" run ci_cmd_scorecard_scan "${out}"
    [ "${status}" -eq 0 ]
    grep -q -- '--repo=github.com/o/r' "${t}.args"
    [ "$(jq -r '.runs[0].results | length' "${out}")" = "1" ]
    [ "$(jq -r '.runs[0].results[0].level' "${out}")" = "warning" ]
    [ "$(jq -r '.runs[0].tool.driver.rules | length' "${out}")" = "2" ]
    RC=1 GITHUB_REPOSITORY=o/r RUNNER_TEMP="${BATS_TEST_TMPDIR}" run ci_cmd_scorecard_scan "${out}"
    [ "${status}" -eq 1 ]
    OUT_TEXT='not json' GITHUB_REPOSITORY=o/r RUNNER_TEMP="${BATS_TEST_TMPDIR}" run ci_cmd_scorecard_scan "${out}"
    [ "${status}" -eq 1 ]
}

# What: CodeQL for python and c-cpp, then each step failing.
# Why: c-cpp traces ci.sh build; a failed step gives no SARIF.
# From: Issue #479, PR #544
@test "codeql traces the ci.sh build for c-cpp and fails closed" {
    local t="${BATS_TEST_TMPDIR}/tool"
    _fake_tool "${t}"
    _print _ci_tool_bin "${t}"
    _forbid ci_cmd_install
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run ci_cmd_codeql_scan python out.sarif
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"must not run"* ]]
    grep -q -- 'database create .* --language=python' "${t}.args"
    grep -q -- 'database analyze .*codeql/python-queries:codeql-suites/python-security-extended.qls .*--sarif-category=/language:python' "${t}.args"
    _pass ci_cmd_install
    : > "${t}.args"
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run ci_cmd_codeql_scan c-cpp out.sarif
    [ "${status}" -eq 0 ]
    grep -q -- '--language=cpp .*--command=bash .github/scripts/ci.sh build default' "${t}.args"
    RC=1 RUNNER_TEMP="${BATS_TEST_TMPDIR}" run ci_cmd_codeql_scan python out.sarif
    [ "${status}" -eq 2 ]
    _fail ci_cmd_install 1 "apt down"
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run ci_cmd_codeql_scan c-cpp out.sarif
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"apt down"* ]]
}

# What: CFL build steps in order, then autogen failing.
# Why: The fuzzers must build from configure made on the host.
# From: Issue #267, Issue #479, PR #544
@test "clusterfuzzlite build runs its steps in order and fails closed" {
    export CALL_LOG="${BATS_TEST_TMPDIR}/steps"
    local log="${CALL_LOG}"
    _record ci_cmd_install _ci_run_autogen _ci_image_alias _ci_cfl_run
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run ci_cmd_clusterfuzzlite_build address
    [ "${status}" -eq 0 ]
    [ "$(cut -d' ' -f1 "${log}" | paste -sd' ')" = "ci_cmd_install _ci_run_autogen _ci_image_alias _ci_cfl_run" ]
    grep -qx '_ci_cfl_run build -e SANITIZER=address' "${log}"
    _fail _ci_run_autogen 1 "autogen broke"
    _forbid _ci_image_alias _ci_cfl_run
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run ci_cmd_clusterfuzzlite_build address
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"autogen broke"* ]]
    [[ "${output}" != *"must not run"* ]]
}

# What: Releases a tag past and failing its version check.
# Why: No release may be cut for a tag configure.ac disowns.
# From: Issue #479, PR #544
@test "github release is cut only after the version check" {
    _echoes _ci_gh_release_create
    _pass _ci_check_release_version
    GITHUB_SHA=abc run _ci_publish_github_release v9.9-NG
    [ "${status}" -eq 0 ]
    [[ "${output}" == "_ci_gh_release_create v9.9-NG abc distcc-ng v9.9-NG distcc-ng v9.9-NG --latest" ]]
    _fail _ci_check_release_version 1
    _forbid _ci_gh_release_create
    GITHUB_SHA=abc run _ci_publish_github_release v9.9-NG
    [ "${status}" -eq 1 ]
    [[ "${output}" != *"must not run"* ]]
}

# What: Release lookup: listed, unlisted, API error, bad tag.
# Why: An API or auth error must never read as no release.
# From: Issue #479, PR #544
@test "release lookup tells missing from an API error" {
    _print gh v0 v1
    GITHUB_REPOSITORY=o/r run _ci_gh_release_exists v1
    [ "${status}" -eq 0 ]
    _print gh v0 v10
    GITHUB_REPOSITORY=o/r run _ci_gh_release_exists v1
    [ "${status}" -eq 1 ]
    _fail gh 1 "HTTP 401: Bad credentials"
    GITHUB_REPOSITORY=o/r run _ci_gh_release_exists v1
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-PUBLISH-0010"*"Bad credentials"* ]]
    _forbid gh
    GITHUB_REPOSITORY=o/r run _ci_gh_release_exists 'v1 x'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-PUBLISH-0011"* ]]
    [[ "${output}" != *"must not run"* ]]
    _print _ci_release_assets a.tar.gz b.rpm
    DRY_RUN=true GITHUB_REPOSITORY=o/r run _ci_gh_release_create v1 abc t n --prerelease
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"gh release create v1 a.tar.gz b.rpm --repo o/r --target abc"*"--prerelease"* ]]
    _fail _ci_release_assets 1
    _forbid gh
    DRY_RUN=true GITHUB_REPOSITORY=o/r run _ci_gh_release_create v1 abc t n
    [ "${status}" -eq 1 ]
}

# What: Redis check: a hit, no hit, a failed pass, no Redis.
# Why: Only a hit in a fresh container proves Redis served it.
# From: Issue #285, Issue #479, PR #544
@test "verify ccache-redis needs a hit from a fresh container" {
    _pass sleep _ci_container_logged
    # What: Stub container runs; builds print $HITS as stats.
    # Why: The second, fresh build must report a ccache hit.
    _ci_container_run() {
        case "$*" in *"workload checkout"*) [ -z "${PASS_FAIL:-}" ] || return 1
            echo "  Hits: ${HITS:-0} / 10" ;; esac
    }
    HITS=4 RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _ci_verify_ccache_redis img net
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ccache hit in a fresh container"* ]]
    HITS=0 RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _ci_verify_ccache_redis img net
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-VERIFY-0002"* ]]
    PASS_FAIL=1 RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _ci_verify_ccache_redis img net
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-VERIFY-0003"* ]]
    _fail _ci_container_logged 1
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _ci_verify_ccache_redis img net
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-VERIFY-0004"* ]]
}

# What: verify all with in-image checks failing; then brew.
# Why: Redis must still run so one failure hides no other.
# From: Issue #285, Issue #479, PR #544
@test "verify all runs every check; brew installs the list" {
    _fail _ci_verify_in_image 1
    # What: Stub the Redis check to report that it ran.
    # Why: It must run even after the in-image checks failed.
    _ci_verify_ccache_redis() { echo "redis ran"; }
    run _ci_verify_all img net
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"redis ran"* ]]
    _echoes brew
    run _ci_brew_install "a b"
    [ "${status}" -eq 0 ]
    [ "${output}" = "brew install a b" ]
    _fail brew 1 "no formula"
    run _ci_brew_install "a b"
    [ "${status}" -eq 1 ]
}

# What: A 4 MB SARIF through gh; 5xx, empty and 4xx answers.
# Why: argv would hit E2BIG; only transient errors retry.
# From: Issue #479, PR #544
@test "SARIF upload: body file, retry 5xx or empty, never 4xx" {
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

# What: Base SOT without tool pins; ids the head's tools add.
# Why: The PR gate judges only what the head changed.
# From: Issue #267, Issue #479, PR #544
@test "OSV PR gate: NotRun without base pins, fails on new ids" {
    _fake_osv '    version: "v1"'
    OSV_BASE_IDS="" OSV_HEAD_IDS="GO-1" GITHUB_EVENT_NAME=pull_request run ci_cmd_osv_scan out.sarif
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"OSV PR gate NotRun"* ]]
    OSV_GIT_FAIL=1 OSV_BASE_IDS="" OSV_HEAD_IDS="GO-1" GITHUB_EVENT_NAME=pull_request run ci_cmd_osv_scan out.sarif
    [ "${status}" -eq 1 ]
    [[ "${output}" != *"NotRun"* ]]
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

# What: Runs a fake scanner exiting 1, 127 and 128.
# Why: v2.6.0 docs/usage.md:790-799: 127 and 128 are errors.
# From: Issue #267, Issue #479, PR #544
@test "OSV run keeps findings 1-126 and fails on a scanner error" {
    local bin="${BATS_TEST_TMPDIR}/osv"
    _fake_tool "${bin}"
    RC=1 run _ci_osv_run "${bin}" sarif "${BATS_TEST_TMPDIR}/o" "${BATS_TEST_TMPDIR}"
    [ "${status}" -eq 0 ]
    RC=127 run _ci_osv_run "${bin}" sarif "${BATS_TEST_TMPDIR}/o" "${BATS_TEST_TMPDIR}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0002"*"exit=127"* ]]
    RC=128 run _ci_osv_run "${bin}" sarif "${BATS_TEST_TMPDIR}/o" "${BATS_TEST_TMPDIR}"
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

# What: Tool pin refresh: newest stable tag, then its sha256.
# Why: sot-update moves a version and its digest together.
# From: Issue #479, PR #544
@test "sot-update reads the newest stable tag and its recorded sha256" {
    local h; h="$(printf 'a%.0s' {1..64})"
    _fixture_manifest 'external_versions:' '  t:' '    version: "v1.2.0"' '    source: "o/t"' \
        '    tag_prefix: "v"' '    url: "https://github.com/o/t/releases/download/v{bare}/t-{bare}.tar.gz"'
    _print gh v1.2.0 v1.10.0 v1.9.3 other-9.9
    run _ci_tool_latest_version external_versions.t
    [ "${status}" -eq 0 ]
    [ "${output}" = "1.10.0" ]
    _print gh other-9.9
    run _ci_tool_latest_version external_versions.t
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-SOT-0005"* ]]
    _print gh "{\"assets\":[{\"name\":\"t-1.10.0.tar.gz\",\"digest\":\"sha256:${h}\"}]}"
    run _ci_release_asset_sha external_versions.t 1.10.0
    [ "${status}" -eq 0 ]
    [ "${output}" = "${h}" ]
    _print gh '{"assets":[{"name":"t-1.10.0.tar.gz"}]}'
    run _ci_release_asset_sha external_versions.t 1.10.0
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-SOT-0008"* ]]
    _fixture_manifest 'external_versions:' '  t:' '    version: "1"' '    source: "o/t"' \
        '    url: "https://example.org/t-{bare}.tar.gz"'
    run _ci_release_asset_sha external_versions.t 1
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SOT-0006"* ]]
    _fail gh 1 "HTTP 502"
    run _ci_tool_latest_version external_versions.t
    [ "${status}" -eq 1 ]
}

# What: Current pins, then changes: create the PR, then edit.
# Why: A no-op is quiet; one sot-update PR stays open.
# From: Issue #479, PR #544
@test "sot-update: quiet no-op, one PR created then edited" {
    local b; b="$(printf 'b%.0s' {1..64})"
    _fixture_manifest 'base_images:' "  deb: \"debian:trixie@sha256:${b}\"" 'external_services:' \
        "  red: \"redis:8@sha256:${b}\"" 'external_versions:' '  m:' '    version: "1"'
    _fake_registry
    _forbid git
    GH_TOKEN=x GITHUB_REPOSITORY=o/r run ci_cmd_sot_update
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"every SOT pin is current"* ]]
    [[ "${output}" != *"must not run"* ]]
    unset -f git
    CI_MANIFEST="${BATS_TEST_DIRNAME}/../yaml/build-manifest.yml"
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
    _print gh '[{"number":9,"isCrossRepository":false},{"number":10,"isCrossRepository":false}]'
    DRY_RUN=true GH_TOKEN=x GITHUB_REPOSITORY=o/r run ci_cmd_sot_update
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-PR-0001"*"2 open pull requests have head"* ]]
    [[ "${output}" != *"would run: gh pr"* ]]
    # What: Stub gh: no open PR; create logs args, prints a URL.
    # Why: The SOT milestone and that URL's board add must follow.
    gh() { case "$1 $2" in "pr list") echo '[]' ;; "pr create") echo "create $*" >&2; echo "https://x/pull/7" ;;
        *) echo "gh $*" ;; esac; }
    PROJECT_PAT=t GH_TOKEN=x GITHUB_REPOSITORY=o/r run _stubbed '_pass git' ci_cmd_sot_update
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--milestone current_dev backlog"* ]]
    [[ "${output}" == *"gh project item-add 11 --owner wiki-mod --url https://x/pull/7"* ]]
}

# What: ARM64 runner, then a 200 answer that is not JSON.
# Why: The agent ships for x64; bad JSON falls back keyless.
# From: Issue #479, PR #544
@test "harden start: NotRun on ARM64, keyless on bad JSON" {
    _forbid curl sudo
    RUNNER_OS=Linux RUNNER_ARCH=ARM64 RUNNER_ENVIRONMENT=github-hosted run _ci_harden_start
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"NotRun: agent unsupported on RUNNER_ARCH=ARM64"* ]]
    [[ "${output}" != *"must not run"* ]]
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

# What: No state, unreadable state, unconfirmed, confirmed.
# Why: Stop runs under always(); only a confirmed flush ok.
# From: Issue #479, PR #544
@test "harden stop: NotRun, unreadable state, unconfirmed, confirmed" {
    _CI_HARDEN_DIR="${BATS_TEST_TMPDIR}/agent"
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _ci_harden_stop
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"NotRun: no agent was started"* ]]
    _fixture_harden_state
    _pass sleep
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _ci_harden_stop
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-HARDEN-0003"* ]]
    [ -f "${_CI_HARDEN_DIR}/post_event.json" ]
    _fixture_harden_state
    printf '{}' > "${_CI_HARDEN_DIR}/done.json"
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _ci_harden_stop
    [ "${status}" -eq 0 ]
    [ "$(cat "${_CI_HARDEN_DIR}/post_event.json")" = '{"event":"post"}' ]
    rm -rf "${_CI_HARDEN_DIR}"
    _fixture_harden_state
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _stubbed '_fail sed 1 "sed broke"' _ci_harden_stop
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"sed broke"* ]]
    [ ! -e "${_CI_HARDEN_DIR}/post_event.json" ]
}
