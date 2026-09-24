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

@test "sot scalar reads a two-level pin" {
    # What: base_images.debian_verify is one owned digest.
    # Why: Drift here breaks every verify-image build.
    # From: Issue #479
    run _ci_sot_scalar base_images.debian_verify
    [ "${status}" -eq 0 ]
    [[ "${output}" == debian@sha256:* ]]
}

@test "sot scalar reads a three-level pin" {
    # What: external_versions.samba.version is one owner.
    # Why: The verify source check downloads exactly this tag.
    # From: Issue #479
    run _ci_sot_scalar external_versions.samba.version
    [ "${status}" -eq 0 ]
    [ "${output}" = "4.22.4" ]
}

@test "sot children lists exactly the five build variants" {
    # What: build_matrix.variants owns the build set.
    # Why: Drift here silently drops or adds a build.
    # From: Issue #479
    run _ci_sot_children build_matrix.variants
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -eq 5 ]
    printf '%s\n' "${lines[@]}" | grep -qx "default"
    printf '%s\n' "${lines[@]}" | grep -qx "sanitizer"
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
    PROJECT_PAT="dummy" PROJECT_OWNER="wiki-mod" PROJECT_NUMBER="11" \
        PR_IS_FORK="true" run _ci_check_pr_board
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

@test "container rejects an unimplemented variant" {
    # What: An unknown container variant fails closed.
    # Why: Consistent fail-closed dispatch for outward phases.
    # From: Issue #479
    run bash "${BATS_TEST_DIRNAME}/ci.sh" container bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CONTAINER-0001"* ]]
}

@test "publish nightly refuses to force-move a v* tag" {
    # What: The nightly publisher must never touch a real release tag.
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

@test "matrix includes default on both OSes and excludes opt-in sanitizer" {
    # What: The PR matrix is the SOT variants minus opt-in ones.
    # Why: sanitizer is dispatch/schedule-only, never a PR gate.
    # From: Issue #479
    run ci_cmd_matrix
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'"variant":"default","os":"ubuntu-latest"'* ]]
    [[ "${output}" == *'"variant":"default","os":"macos-latest"'* ]]
    [[ "${output}" != *'sanitizer'* ]]
}

@test "build fails closed on an unknown variant before touching the tree" {
    # What: An unknown build variant MUST reject, not autogen.
    # Why: Fail-closed before running any build step.
    # From: Issue #479
    CI_REPO_ROOT=/tmp run bash "${BATS_TEST_DIRNAME}/ci.sh" build bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

@test "comfychair parse passes on all-OK/NOTRUN output" {
    # What: A run with only OK/NOTRUN lines passes.
    # Why: Proves the green parse path.
    # From: Issue #479
    log="$(mktemp)"
    printf '%s\n' "FooCase           OK" "BarCase           NOTRUN, needs root" > "${log}"
    run _ci_parse_comfychair "${log}"
    rm -f "${log}"
    [ "${status}" -eq 0 ]
}

@test "comfychair parse fails closed on a FAIL line" {
    # What: Any FAIL case fails the parse.
    # Why: A failed test must never report green.
    # From: Issue #479
    log="$(mktemp)"
    printf '%s\n' "FooCase           OK" "BarCase           FAIL" > "${log}"
    run _ci_parse_comfychair "${log}"
    rm -f "${log}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-TEST-0002"* ]]
}

@test "comfychair parse fails closed on zero parsed result lines" {
    # What: 0/0/0 parsed is a hard failure (rule 66).
    # Why: An empty parse must not look like a clean pass.
    # From: Issue #479
    log="$(mktemp)"
    printf '%s\n' "build noise, no result lines" > "${log}"
    run _ci_parse_comfychair "${log}"
    rm -f "${log}"
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

@test "resolve prints every external pin from the SOT" {
    # What: One resolve call proves all end-to-end SOT reads at once.
    # Why: Every later phase depends on these read paths; no floating literals.
    # From: Issue #479, Issue #81
    run ci_cmd_resolve
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"debian_verify=debian@sha256:"* ]]
    [[ "${output}" == *"samba=4.22.4"* ]]
    [[ "${output}" == *"actionlint=1.7.12"* ]]
    [[ "${output}" == *"ccache_heartbeat=v4.13.6"* ]]
    [[ "${output}" == *"codeql_cli=v2.27.0"* ]]
    [[ "${output}" == *"scorecard=v5.5.0"* ]]
    [[ "${output}" == *"osv_scanner=v2.6.0"* ]]
    [[ "${output}" == *"clusterfuzzlite=v1"* ]]
    [[ "${output}" == *"redis=redis@sha256:"* ]]
}

@test "report fails closed when GH_TOKEN is unset" {
    # What: report must fail rather than silently skip without credentials.
    # Why: A silent no-op would hide broken scheduled-status wiring.
    # From: Issue #479, Issue #81
    GH_TOKEN="" run ci_cmd_report
    [ "${status}" -ne 0 ]
}

@test "variables secret-present writes available true/false" {
    # What: The secret-presence gate that add-to-project's if: depends on.
    # Why: GitHub forbids the secrets context in if:, so ci.sh owns the gate.
    # From: Issue #479, PR #329
    local out; out="$(mktemp)"
    GITHUB_OUTPUT="${out}" SECRET_VALUE="x" _ci_variables_secret_present
    GITHUB_OUTPUT="${out}" SECRET_VALUE="" _ci_variables_secret_present
    run cat "${out}"
    [ "${lines[0]}" = "available=true" ]
    [ "${lines[1]}" = "available=false" ]
    rm -f "${out}"
}

@test "ossf grep helper reports Met, NotMet, and case-insensitive" {
    # What: The shared baseline grep helper drives many openssf checks.
    # Why: A wrong Met/NotMet would mis-report a security criterion.
    # From: Issue #479, Issue #312
    local fx; fx="$(mktemp)"
    printf 'has Security Advisory here\n' > "${fx}"
    [ "$(_ci_ossf_grep "${fx}" 'Security Advisor')" = "Met" ]
    [ "$(_ci_ossf_grep "${fx}" 'nope-xyz')" = "NotMet" ]
    [ "$(_ci_ossf_grep "${fx}" 'SECURITY ADVISOR' -i)" = "Met" ]
    rm -f "${fx}"
}

@test "gc package list and e2e tuning come from the SOT" {
    # What: gc names and heartbeat/full tuning have one owner, not literals.
    # Why: A hardcoded copy in ci.sh would drift from the manifest.
    # From: Issue #479
    run _ci_sot_list release.ghcr_packages
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"distcc-ng-buildtools"* ]]
    [[ "${output}" == *"distcc-ng-e2e"* ]]
    [ "$(_ci_sot_scalar e2e.heartbeat_min_remote_jobs)" = "20" ]
    [ "$(_ci_sot_scalar e2e.full_waf_targets)" = "replace,ldb,tdb,talloc,tevent" ]
}

@test "failed-jobs filter keeps only failure and cancelled" {
    # What: Only real failures are reported, not upstream-caused skips.
    # Why: A skipped dependent would otherwise mask the true root cause.
    # From: Issue #479, PR #476
    run _ci_failed_jobs "$(printf 'build=success\ne2e=failure\npublish=skipped\nx=cancelled\n')"
    [ "${status}" -eq 0 ]
    [ "${output}" = "e2e x" ]
}

# =========================================================
# IMPACT (DEFAULT=NOOP)
# =========================================================

@test "impact: a docs-only diff selects doc-lint, never build" {
    # What: A .md edit MUST NOT trigger a compile.
    # Why: Kills the sledgehammer full-CI on documentation.
    # From: Issue #479
    run bash -c 'printf "%s\n" README.md doc/threat-model.md | { source "'"${BATS_TEST_DIRNAME}"'/ci.sh"; _ci_phases_for_paths; }'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"doc-lint"* ]]
    [[ "${output}" != *"build"* ]]
    [[ "${output}" != *"e2e"* ]]
}

@test "impact: a c-source diff selects build and test" {
    # What: A src/*.c edit selects the compile phases.
    # Why: Real code changes must build, test and analyze.
    # From: Issue #479
    run bash -c 'printf "%s\n" src/dopt.c | { source "'"${BATS_TEST_DIRNAME}"'/ci.sh"; _ci_phases_for_paths; }'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"build"* ]]
    [[ "${output}" == *"test"* ]]
}

@test "impact: an include-server .py diff selects build but not package" {
    # What: include_server/*.py selects build/test/analyze only.
    # Why: A pump-mode Python change is not a packaging change.
    # From: Issue #479
    run bash -c 'printf "%s\n" include_server/basics.py | { source "'"${BATS_TEST_DIRNAME}"'/ci.sh"; _ci_phases_for_paths; }'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"build"* ]]
    [[ "${output}" != *"package"* ]]
}

@test "impact: an unmatched path yields NOOP" {
    # What: A path in no class selects no work at all.
    # Why: DEFAULT=NOOP; nothing runs on an irrelevant change.
    # From: Issue #479
    run bash -c 'printf "%s\n" LICENSE | { source "'"${BATS_TEST_DIRNAME}"'/ci.sh"; _ci_phases_for_paths; }'
    [ "${status}" -eq 0 ]
    [ "${output}" = "NOOP" ]
}

@test "classify: a src/*.c path maps to the c-source class" {
    # What: One path resolves to exactly its owning class.
    # Why: Guards the glob matcher against silent misrouting.
    # From: Issue #479
    run bash -c 'printf "%s\n" src/dopt.c | { source "'"${BATS_TEST_DIRNAME}"'/ci.sh"; _ci_classify_paths; }'
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
    # What: feat/fix/docs/security map to their changelog category.
    # Why: Replaces release-drafter's autolabeler regex entirely.
    # From: Issue #479
    [ "$(_ci_pr_category_label 'feat(pump): add IPv6')" = "enhancement" ]
    [ "$(_ci_pr_category_label 'fix(protocol): correct frame bug')" = "bug" ]
    [ "$(_ci_pr_category_label 'docs(governance): add rule')" = "documentation" ]
    [ "$(_ci_pr_category_label 'security(config): patch leak')" = "security" ]
}

@test "pr category: an uncategorized type prints nothing" {
    # What: chore/refactor/etc. get no changelog category label.
    # Why: Matches release-drafter.yml's original 4-category scope.
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
    fx="$(mktemp -d)"; printf 'clean line\n' > "${fx}/ok.sh"
    run ci_guard_line_endings "${fx}"
    rm -rf "${fx}"
    [ "${status}" -eq 0 ]
}

@test "line-endings guard fails closed on a CRLF file" {
    # What: A CR byte anywhere must fail the guard.
    # Why: Proves the fail-closed path is reachable.
    # From: Issue #479
    fx="$(mktemp -d)"; printf 'bad line\r\n' > "${fx}/crlf.sh"
    run ci_guard_line_endings "${fx}"
    rm -rf "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-EOL-0001"* ]]
}

@test "full-sha guard passes on a 64-hex digest" {
    # What: A full 64-hex sha256 is compliant.
    # Why: Proves the green path for the SHA rule.
    # From: Issue #479
    fx="$(mktemp -d)"
    printf 'image: "debian@sha256:fac46bff2e02f51425b6e33b0e1169f55dfb053d83511ca28aa50c09fd5ed7a4"\n' > "${fx}/f.yml"
    run ci_guard_full_sha "${fx}"
    rm -rf "${fx}"
    [ "${status}" -eq 0 ]
}

@test "full-sha guard fails closed on an abbreviated digest" {
    # What: A short sha256 must be rejected.
    # Why: No abbreviations or special SHA forms allowed.
    # From: Issue #479
    fx="$(mktemp -d)"; printf 'image: "debian@sha256:fac46bff"\n' > "${fx}/f.yml"
    run ci_guard_full_sha "${fx}"
    rm -rf "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-SHA-0001"* ]]
}

@test "full-sha guard fails closed on an abbreviated action pin" {
    # What: A short git SHA on a `uses:` pin must be rejected.
    # Why: Action pins MUST be full 40-hex SHAs.
    # From: Issue #479
    fx="$(mktemp -d)"; printf '      - uses: actions/checkout@abc1234\n' > "${fx}/w.yml"
    run ci_guard_full_sha "${fx}"
    rm -rf "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-SHA-0002"* ]]
}

@test "dependabot-consistency passes when SOT and Dockerfile agree" {
    # What: A SOT pin present verbatim in its Dockerfile passes.
    # Why: Proves the green path of the anti-drift binding.
    # From: Issue #479
    fx="$(mktemp -d)"; mkdir -p "${fx}/docker/verify" "${fx}/.github/yaml"
    a="$(printf 'a%.0s' {1..64})"; g="$(printf 'b%.0s' {1..64})"
    printf 'ARG DEBIAN_IMAGE=debian@sha256:%s\nFROM golang@sha256:%s AS actionlint-builder\nFROM ${DEBIAN_IMAGE}\n' "${a}" "${g}" > "${fx}/docker/verify/Dockerfile"
    printf 'base_images:\n  debian_verify: "debian@sha256:%s"\n  golang_actionlint: "golang@sha256:%s"\n' "${a}" "${g}" > "${fx}/.github/yaml/build-manifest.yml"
    CI_MANIFEST="${fx}/.github/yaml/build-manifest.yml" run ci_guard_dependabot_consistency "${fx}"
    rm -rf "${fx}"
    [ "${status}" -eq 0 ]
}

@test "dependabot-consistency fails closed when the SOT drifts from the Dockerfile" {
    # What: A SOT digest absent from its Dockerfile must fail.
    # Why: Catches a Dependabot bump that did not reach the SOT.
    # From: Issue #479
    fx="$(mktemp -d)"; mkdir -p "${fx}/docker/verify" "${fx}/.github/yaml"
    a="$(printf 'a%.0s' {1..64})"; c="$(printf 'c%.0s' {1..64})"; g="$(printf 'b%.0s' {1..64})"
    printf 'ARG DEBIAN_IMAGE=debian@sha256:%s\nFROM golang@sha256:%s AS actionlint-builder\nFROM ${DEBIAN_IMAGE}\n' "${a}" "${g}" > "${fx}/docker/verify/Dockerfile"
    printf 'base_images:\n  debian_verify: "debian@sha256:%s"\n  golang_actionlint: "golang@sha256:%s"\n' "${c}" "${g}" > "${fx}/.github/yaml/build-manifest.yml"
    CI_MANIFEST="${fx}/.github/yaml/build-manifest.yml" run ci_guard_dependabot_consistency "${fx}"
    rm -rf "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-DEP-0002"* ]]
}

@test "orchestrator guard passes on a single-command run: step" {
    # What: `run: bash ci.sh <phase>` is a compliant orchestrator step.
    # Why: Proves the green path; one command is allowed.
    # From: Issue #479
    fx="$(mktemp -d)"
    printf 'jobs:\n  x:\n    steps:\n      - run: bash .github/scripts/ci.sh build\n' > "${fx}/wf.yml"
    run ci_guard_orchestrator_only "${fx}/wf.yml"
    rm -rf "${fx}"
    [ "${status}" -eq 0 ]
}

@test "orchestrator guard fails closed on inline logic in a run: block" {
    # What: A run: block with shell control flow must be rejected.
    # Why: AG-CI-023 bans inline logic; it belongs in ci.sh.
    # From: Issue #479
    fx="$(mktemp -d)"
    printf 'jobs:\n  x:\n    steps:\n      - run: |\n          if [ -x foo ]; then bar; fi\n' > "${fx}/wf.yml"
    run ci_guard_orchestrator_only "${fx}/wf.yml"
    rm -rf "${fx}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-GUARD-ORCH-0001"* ]]
}
