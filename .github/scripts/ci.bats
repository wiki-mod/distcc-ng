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

@test "resolve prints the samba pin from the SOT" {
    # What: resolve proves end-to-end SOT reads.
    # Why: Every later phase depends on this read path.
    # From: Issue #479
    run ci_cmd_resolve
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"samba=4.22.4"* ]]
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
