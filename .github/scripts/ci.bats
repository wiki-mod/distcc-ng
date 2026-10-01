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

# What: Make each named command fail loudly if it is run.
# Why: Proves a fail-closed path stops before any side effect.
# From: Issue #479, PR #544
_forbid() {
    local c
    for c in "$@"; do
        eval "${c}() { echo '${c} must not run'; return 99; }"
    done
}

# =========================================================
# DISPATCH
# =========================================================

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

# =========================================================
# SOT READERS
# =========================================================

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

# =========================================================
# PARALLELISM
# =========================================================

@test "job count never drops below the floor of 16" {
    # What: bats parallelism = max(16, nproc*2).
    # Why: Serial runs are forbidden; the floor is a guard.
    # From: Issue #479
    run _ci_jobs
    [ "${status}" -eq 0 ]
    [ "${output}" -ge 16 ]
}

# =========================================================
# PHASES
# =========================================================

@test "pr-title accepts a valid Conventional-Commit title" {
    # What: A conforming title passes even in block mode.
    # Why: Proves the green path of the rule-71 taxonomy.
    # From: Issue #479
    PR_TITLE="feat(pump): add IPv6 support" PR_TITLE_LINT_MODE=block run _ci_check_pr_title
    [ "${status}" -eq 0 ]
}

@test "pr-title fails closed on a bad title in block mode" {
    # What: A non-conforming title fails when enforcement is on.
    # Why: Proves the fail-closed path.
    # From: Issue #479
    PR_TITLE="add some stuff" PR_TITLE_LINT_MODE=block run _ci_check_pr_title
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-META-TITLE-0002"* ]]
}

@test "pr-title exempts dependabot" {
    # What: dependabot titles are skipped, not failed.
    # Why: It cannot conform; the gate must see an explicit pass.
    # From: Issue #479
    PR_AUTHOR="dependabot[bot]" PR_TITLE="Bump foo from 1 to 2" PR_TITLE_LINT_MODE=block run _ci_check_pr_title
    [ "${status}" -eq 0 ]
}

@test "board add passes its token to gh but never prints it" {
    # What: The token reaches gh; a dry run prints only the args.
    # Why: One board owner; a PAT must not land in a log line.
    # From: Issue #236, Issue #479, PR #544
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

@test "the SOT refresh bot is exempt from PR tracking metadata" {
    # What: github-actions[bot] PRs skip labels/milestone/board.
    # Why: The sot-update PR has no milestone; AG-VAL-007 reviews.
    # From: Issue #479, PR #544
    PR_AUTHOR="github-actions[bot]" PR_LABELS="" PR_MILESTONE_TITLE="" run _ci_check_pr_tracking
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dependency bot github-actions[bot]"* ]]
    PR_AUTHOR="someone" PR_LABELS="" PR_MILESTONE_TITLE="" run _ci_check_pr_tracking
    [ "${status}" -eq 1 ]
}

@test "tracking passes with labels and a milestone" {
    # What: A PR with a label and a milestone passes rule 3.
    # Why: Proves the green tracking path.
    # From: Issue #479
    PR_LABELS="ci" PR_MILESTONE_TITLE="current_dev backlog" run _ci_check_pr_tracking
    [ "${status}" -eq 0 ]
}

@test "tracking fails closed without a milestone" {
    # What: A missing milestone fails rule 3.
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
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"
    ( cd "${fx}" && git init -q && git config user.email t@t && git config user.name t
      printf 'AC_INIT([distcc-ng],[9.9.9-NG])\n' > configure.ac
      git add configure.ac && git commit -q -m x && git tag v9.9.9-NG )
    CI_REPO_ROOT="${fx}" run _ci_check_release_version v9.9.9-NG false
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"CI-RELEASE"*"OK"* ]]
}

@test "release version-check require_new=true still rejects an existing tag" {
    # What: The pre-tag dispatch path keeps refusing a collision.
    # Why: require_new defaults to true for the pre-tag path.
    # From: Issue #479, PR #544
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"
    ( cd "${fx}" && git init -q && git config user.email t@t && git config user.name t
      printf 'AC_INIT([distcc-ng],[9.9.9-NG])\n' > configure.ac
      git add configure.ac && git commit -q -m x && git tag v9.9.9-NG )
    CI_REPO_ROOT="${fx}" run _ci_check_release_version v9.9.9-NG
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-RELEASE-0004"* ]]
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
    [[ "${output}" == *"CI-ERROR-WORKLOAD-0005"* ]]
    run ci_cmd_image bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-IMAGE-0001"* ]]
    [[ "${output}" != *"must not run"* ]]
}

@test "publish nightly refuses to force-move a v* tag" {
    # What: The nightly publisher never moves a release tag.
    # Why: git push -f on a v* tag would clobber a real release.
    # From: Issue #479
    NIGHTLY_TAG="v3.6.6-NG" run _ci_publish_nightly
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

@test "build fails closed on an unknown variant before touching the tree" {
    # What: An unknown build variant MUST reject, not autogen.
    # Why: Fail-closed before running any build step.
    # From: Issue #479
    CI_REPO_ROOT=/tmp run bash "${BATS_TEST_DIRNAME}/ci.sh" build bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

@test "make gate passes a clean build and fails on a warning" {
    # What: A compiler warning in make output fails the build.
    # Why: Warnings are errors (rule 31) on every tree build.
    # From: Issue #479, PR #544
    make() { echo "gcc -c src/x.c"; }
    run _ci_make_gated "${BATS_TEST_TMPDIR}/ok.log" all
    [ "${status}" -eq 0 ]
    make() { echo "src/x.c:12:5: warning: unused variable 'y'"; }
    run _ci_make_gated "${BATS_TEST_TMPDIR}/warn.log" all
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-BUILD-WARN-0001"* ]]
    [[ "${output}" == *"src/x.c:12:5: warning"* ]]
}

@test "make gate and configure fail closed when the tool fails" {
    # What: A failing make or configure is an error, not a pass.
    # Why: Build steps once relied on set -e, lost inside ||.
    # From: Issue #479, PR #544
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
    # What: 0/0/0 parsed is a hard failure (rule 66).
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

@test "report fails closed when GH_TOKEN is unset" {
    # What: report fails without credentials, never skips.
    # Why: A silent no-op would hide broken status reporting.
    # From: Issue #479, Issue #81
    GH_TOKEN="" run ci_cmd_report
    [ "${status}" -ne 0 ]
}

@test "variables secret-present writes available true/false" {
    # What: The secret-presence gate writes true, then false.
    # Why: GitHub forbids the secrets context inside an if:.
    # From: Issue #479, PR #329
    local out="${BATS_TEST_TMPDIR}/out"
    GITHUB_OUTPUT="${out}" SECRET_VALUE="x" _ci_variables_secret_present
    GITHUB_OUTPUT="${out}" SECRET_VALUE="" _ci_variables_secret_present
    run cat "${out}"
    [ "${lines[0]}" = "available=true" ]
    [ "${lines[1]}" = "available=false" ]
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
    [ "$(_ci_ossf_check_br01)" = "Met" ]
    printf '%s\n' 'on: pull_request_target' "      - run: ${boot} 1 \"\$HEAD\"" > "${fx}/.github/workflows/b.yml"
    [ "$(_ci_ossf_check_br01)" = "NotMet" ]
}

@test "ossf grep helper reports Met, NotMet, and case-insensitive" {
    # What: The baseline grep helper backs many openssf checks.
    # Why: A wrong Met/NotMet misreports a security criterion.
    # From: Issue #479, Issue #312
    local fx="${BATS_TEST_TMPDIR}/fx"
    printf 'has Security Advisory here\n' > "${fx}"
    [ "$(_ci_ossf_grep "${fx}" 'Security Advisor')" = "Met" ]
    [ "$(_ci_ossf_grep "${fx}" 'nope-xyz')" = "NotMet" ]
    [ "$(_ci_ossf_grep "${fx}" 'SECURITY ADVISOR' -i)" = "Met" ]
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
    GH_TOKEN=x OWNER=wiki-mod run ci_cmd_gc not-a-package
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0001"* ]]
    [[ "${output}" != *"must not run"* ]]
}

@test "gc protection fails closed when a tag cannot be inspected" {
    # What: An uninspectable tag aborts pruning of that package.
    # Why: Unknown children would otherwise lose their protection.
    # From: Issue #479, PR #544
    docker() { return 1; }
    OWNER=wiki-mod run _ci_gc_protected_digests distcc-ng '[{"metadata":{"container":{"tags":["latest"]}}}]'
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GC-0002"* ]]
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

# =========================================================
# IMPACT (DEFAULT=NOOP)
# =========================================================

@test "impact: a docs-only diff selects doc-lint, never build" {
    # What: A .md edit MUST NOT trigger a compile.
    # Why: Kills the sledgehammer full-CI on documentation.
    # From: Issue #479
    run _ci_phases_for_paths < <(printf '%s\n' README.md doc/threat-model.md)
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"doc-lint"* ]]
    [[ "${output}" != *"build"* ]]
    [[ "${output}" != *"e2e"* ]]
}

@test "impact: a c-source diff selects build and test" {
    # What: A src/*.c edit selects the compile phases.
    # Why: Real code changes must build, test and analyze.
    # From: Issue #479
    run _ci_phases_for_paths < <(printf '%s\n' src/dopt.c)
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"build"* ]]
    [[ "${output}" == *"test"* ]]
}

@test "impact: an include-server .py diff selects build but not package" {
    # What: include_server/*.py selects build/test/analyze only.
    # Why: A pump-mode Python change is not a packaging change.
    # From: Issue #479
    run _ci_phases_for_paths < <(printf '%s\n' include_server/basics.py)
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"build"* ]]
    [[ "${output}" != *"package"* ]]
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

@test "labeler: documentation label matches doc/** and non-CHANGELOG .md" {
    # What: Mirrors labeler's any:/negation for one label.
    # Why: Two earlier configs got this negation wrong.
    # From: Issue #479
    run _ci_labeler_documentation_match $'doc/foo.md\nsrc/bar.c'
    [ "${status}" -eq 0 ]
    run _ci_labeler_documentation_match "README.md"
    [ "${status}" -eq 0 ]
}

@test "labeler: documentation label excludes a CHANGELOG.md-only diff" {
    # What: CHANGELOG.md alone must not fire this label.
    # Why: Almost every PR touches it; not a real doc PR.
    # From: Issue #479
    run _ci_labeler_documentation_match "CHANGELOG.md"
    [ "${status}" -ne 0 ]
}

@test "pr category: maps rule-71 types to release-drafter labels" {
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

# =========================================================
# GOVERNANCE GUARDS (green + red)
# =========================================================

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
    [[ "${output}" == *"CI-ERROR-META-CHANGELOG-0002"* ]]
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
    mkdir -p "${fx}/d" "${fx}/.github/workflows"
    printf '%s\n' 'ARG BASE' 'FROM ${BASE} AS one' 'FROM one AS two' 'FROM x-y:local' > "${fx}/d/Dockerfile"
    printf '%s\n' 'jobs:' '  x:' '    steps:' '      - run: bash .github/scripts/ci.sh build' > "${fx}/.github/workflows/w.yml"
    run ci_guard_pins_in_sot "${fx}"
    [ "${status}" -eq 0 ]
}

@test "pin guard fails closed on every pin form outside the SOT" {
    # What: Digest, ARG default, pulled FROM, workflow pins fail.
    # Why: Each one is a second pin owner beside the SOT.
    # From: Issue #479, PR #544
    local fx="${BATS_TEST_TMPDIR}/fx" d
    d="$(printf 'a%.0s' {1..64})"
    mkdir -p "${fx}/d" "${fx}/.github/workflows"
    printf '%s\n' "ARG BASE=debian@sha256:${d}" 'FROM debian:trixie' 'FROM --platform=linux/amd64 golang:1' > "${fx}/d/Dockerfile"
    printf '%s\n' "      - uses: foo/bar@$(printf 'b%.0s' {1..40})" '    container: debian:13' > "${fx}/.github/workflows/w.yml"
    run ci_guard_pins_in_sot "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"d/Dockerfile:1: digest"* ]]
    [[ "${output}" == *"d/Dockerfile:1: arg-default"* ]]
    [[ "${output}" == *"d/Dockerfile:2: from debian:trixie"* ]]
    [[ "${output}" == *"d/Dockerfile:3: from golang:1"* ]]
    [[ "${output}" == *"w.yml:1: image or action pin"* ]]
    [[ "${output}" == *"w.yml:2: image or action pin"* ]]
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

@test "orchestrator guard fails closed on any uses: step" {
    # What: A composite or marketplace uses: step is rejected.
    # Why: #479: workflows only invoke ci.sh, no actions at all.
    # From: Issue #479, PR #544
    fx="${BATS_TEST_TMPDIR}/fx"; mkdir -p "${fx}"
    printf 'jobs:\n  x:\n    steps:\n      - uses: ./.github/actions/foo\n' > "${fx}/wf.yml"
    run ci_guard_orchestrator_only "${fx}/wf.yml"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"uses: step"* ]]
}

# =========================================================
# EXECUTION OWNERS (argv capture, no real docker)
# =========================================================

# What: docker stub that records its argv, one arg per line.
# Why: Owner tests assert the exact flags, not a real daemon.
# From: Issue #479, PR #544
_capture_docker() {
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
    sleep() { :; }
    _probe() { echo x >> "${BATS_TEST_TMPDIR}/tries"; [ "$(wc -l < "${BATS_TEST_TMPDIR}/tries")" -ge 3 ]; }
    run _ci_wait_until 5 1 _probe
    [ "${status}" -eq 0 ]
    [ "$(wc -l < "${BATS_TEST_TMPDIR}/tries")" -eq 3 ]
    run _ci_wait_until 2 1 false
    [ "${status}" -eq 1 ]
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

# =========================================================
# TOOL FETCH + HARDEN RUNNER
# =========================================================

# What: curl stub that copies fixture file $1 to every -o.
# Why: Fetch tests need a deterministic, offline download.
# From: Issue #479, PR #544
_fake_curl() {
    FAKE_DOWNLOAD="$1"
    curl() { while [ "$#" -gt 0 ]; do if [ "$1" = "-o" ]; then cp "${FAKE_DOWNLOAD}" "$2"; fi; shift; done; }
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
    docker() { printf '{"digest":"sha256:%s"}\n' "$(printf 'b%.0s' {1..64})"; }
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
    _ci_tool_bin() { echo /bin/true; }
    _ci_osv_tool_dirs() { echo "${BATS_TEST_TMPDIR}"; }
    _ci_osv_run() { :; }
    git() { case "$*" in *" show "*) printf '%s\n' "${OSV_BASE_SOT}" ;; esac; }
    _ci_osv_vulns() { if [ "$2" = "${CI_MANIFEST}" ]; then printf '%s\n' ${OSV_HEAD_IDS}; else printf '%s\n' ${OSV_BASE_IDS}; fi; }
}

@test "OSV PR gate fails only on ids the head's tools add" {
    # What: A new vuln id in the head SOT fails; a removed one not.
    # Why: Legacy's PR scan blocked newly vulnerable dependencies.
    # From: Issue #267, Issue #479, PR #544
    _fake_osv '    bin: "x"'
    OSV_BASE_IDS="GO-1 GO-2" OSV_HEAD_IDS="GO-1 GO-3" BASE=abc run ci_cmd_osv_scan out.sarif
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0003"* ]]
    [[ "${output}" == *"GO-3"* ]]
    [[ "${output}" != *"GO-2"* ]]
    OSV_BASE_IDS="GO-1 GO-2" OSV_HEAD_IDS="GO-1" BASE=abc run ci_cmd_osv_scan out.sarif
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"no new vulnerability"* ]]
}

@test "OSV PR gate is NotRun against a base SOT without tool pins" {
    # What: A base predating tool pins has nothing to compare.
    # Why: Its tools cannot be fetched; reading 0 would fail all.
    # From: Issue #267, Issue #479, PR #544
    _fake_osv '    version: "v1"'
    OSV_BASE_IDS="" OSV_HEAD_IDS="GO-1" BASE=abc run ci_cmd_osv_scan out.sarif
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"OSV PR gate NotRun"* ]]
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
    _CI_HARDEN_DIR="${BATS_TEST_TMPDIR}/agent"; mkdir -p "${_CI_HARDEN_DIR}"
    printf 'correlation_id=c\nadd_summary=false\n' > "${BATS_TEST_TMPDIR}/ci-harden.state"
    sleep() { :; }
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _ci_harden_stop
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-HARDEN-0003"* ]]
    [ -f "${_CI_HARDEN_DIR}/post_event.json" ]
}

@test "harden stop passes once the agent wrote done.json" {
    # What: done.json after post_event.json ends the job cleanly.
    # Why: Green path of the post-step replacement.
    # From: Issue #479, PR #544
    _CI_HARDEN_DIR="${BATS_TEST_TMPDIR}/agent"; mkdir -p "${_CI_HARDEN_DIR}"
    printf 'correlation_id=c\nadd_summary=false\n' > "${BATS_TEST_TMPDIR}/ci-harden.state"
    printf '{}' > "${_CI_HARDEN_DIR}/done.json"
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" run _ci_harden_stop
    [ "${status}" -eq 0 ]
    [ "$(cat "${_CI_HARDEN_DIR}/post_event.json")" = '{"event":"post"}' ]
}
