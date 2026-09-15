#!/usr/bin/env bash
# distcc-ng (https://github.com/wiki-mod/distcc-ng)
# SPDX-License-Identifier: GPL-2.0-or-later
# What: Single authoritative CI engine (skeleton).
# Why: All CI decisions live here; YAML only orchestrates.
# From: Issue #479
set -euo pipefail

# =========================================================
# CONSTANTS
# =========================================================

# What: Absolute directory of this script.
# Why: Locate the SOT manifest regardless of caller CWD.
# From: Issue #479
CI_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# What: Path to the single source-of-truth manifest.
# Why: One machine-readable owner for versions and matrix.
# From: Issue #479
CI_MANIFEST="${CI_MANIFEST:-${CI_SCRIPT_DIR}/../yaml/build-manifest.yml}"

# What: Repository root (.github/scripts/../..).
# Why: Phases resolve paths from the repo root.
# From: Issue #479
CI_REPO_ROOT="${CI_REPO_ROOT:-$(cd -- "${CI_SCRIPT_DIR}/../.." && pwd)}"

# What: The known ci.sh subcommands.
# Why: One list drives dispatch and error text (no twin).
# From: Issue #479
CI_COMMANDS="plan impact identity resolve build test e2e analyze scan lint package container publish release gc variables"

# =========================================================
# LOGGING / EXIT HANDLING
# =========================================================

# What: Emit one log line with a stable, greppable id.
# Why: Every message MUST carry a unique id for triage.
# From: Issue #479
ci_log() {
    local message_id="$1"
    shift
    printf '%s %s\n' "${message_id}" "$*" >&2
}

# What: Emit a failure with its raw captured output.
# Why: A command's raw output MUST always be shown.
# From: Issue #479
ci_error() {
    local message_id="$1" context="$2" raw="$3"
    ci_log "${message_id}" "${context}"
    printf 'raw:\n%s\n' "${raw}" >&2
}

# What: Report an unimplemented dispatch target.
# Why: The skeleton MUST fail closed, never succeed silently.
# From: Issue #479
ci_not_implemented() {
    ci_log "[CI-ERROR-CORE-0001]" "command=$* state=SKELETON reason=\"not yet implemented\""
    return 2
}

# What: Fail closed unless the SOT manifest exists.
# Why: Every real operation derives state from the manifest.
# From: Issue #479
ci_require_manifest() {
    [ -f "${CI_MANIFEST}" ] && return 0
    ci_log "[CI-ERROR-CORE-0003]" "manifest=\"${CI_MANIFEST}\" reason=\"manifest not found\""
    return 2
}

# =========================================================
# SOT READERS (awk only; no yq/jq/python)
# =========================================================

# What: Print the scalar at a dotted YAML path in the SOT.
# Why: One reader for every pin; no yq/jq/python dependency.
# From: Issue #479
_ci_sot_scalar() {
    local path="$1"
    awk -v path="${path}" '
        BEGIN { n = split(path, want, "."); need = 1 }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            match($0, /^ */); ind = RLENGTH / 2
            if (ind + 1 < need) { need = ind + 1 }
            if (ind + 1 != need) { next }
            key = $0; sub(/^ +/, "", key); sub(/:.*$/, "", key)
            if (key != want[need]) { next }
            if (need == n) {
                val = $0; sub(/^[^:]*:[[:space:]]*/, "", val)
                gsub(/^"|"[[:space:]]*$/, "", val)
                print val; exit
            }
            need++
        }
    ' "${CI_MANIFEST}"
}

# What: Print the immediate child keys of a dotted SOT path.
# Why: One reader lets phases iterate variants/impact classes.
# From: Issue #479
_ci_sot_children() {
    local path="$1"
    awk -v path="${path}" '
        BEGIN { n = split(path, want, "."); need = 1; inside = 0; childind = 0 }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            match($0, /^ */); ind = RLENGTH / 2
            key = $0; sub(/^ +/, "", key); sub(/:.*$/, "", key)
            if (!inside) {
                if (ind + 1 < need) { need = ind + 1 }
                if (ind + 1 != need) { next }
                if (key != want[need]) { next }
                if (need == n) { inside = 1; childind = ind + 1; next }
                need++; next
            }
            if (ind < childind) { exit }
            if (ind == childind) { print key }
        }
    ' "${CI_MANIFEST}"
}

# What: Print the items of an inline list `key: [a, b]` at a path.
# Why: One reader lets phases read path/phase lists as lines.
# From: Issue #479
_ci_sot_list() {
    local raw
    raw="$(_ci_sot_scalar "$1")"
    raw="${raw#"["}"
    raw="${raw%"]"}"
    printf '%s' "${raw}" \
        | tr ',' '\n' \
        | sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*$//' \
        | grep -v '^[[:space:]]*$' || true
}

# =========================================================
# PATH CLASSIFICATION (impact)
# =========================================================

# What: Match one SOT path glob to a path.
# Why: The SOT owns patterns; this owns the matching semantics.
# From: Issue #479
_ci_glob_match() {
    local pat="$1" path="$2"
    case "${pat}" in
        '**/*.'*) case "${path}" in *".${pat##*.}") return 0 ;; *) return 1 ;; esac ;;
        *'/**')   case "${path}" in "${pat%/**}"/*) return 0 ;; *) return 1 ;; esac ;;
        *)        [ "${path}" = "${pat}" ] ;;
    esac
}

# What: Print the impact classes matched by the paths on stdin.
# Why: DEFAULT=NOOP; only a matched class selects any phase.
# From: Issue #479
_ci_classify_paths() {
    local classes path cls pat
    classes="$(_ci_sot_children impact_classes)"
    while IFS= read -r path; do
        [ -n "${path}" ] || continue
        for cls in ${classes}; do
            while IFS= read -r pat; do
                [ -n "${pat}" ] || continue
                if _ci_glob_match "${pat}" "${path}"; then
                    printf '%s\n' "${cls}"
                    break
                fi
            done < <(_ci_sot_list "impact_classes.${cls}.paths")
        done
    done | sort -u
}

# What: Print the ci.sh phases selected by the paths on stdin.
# Why: NOOP when nothing matches; docs select doc-lint, not build.
# From: Issue #479
_ci_phases_for_paths() {
    local classes cls
    classes="$(_ci_classify_paths)"
    [ -n "${classes}" ] || { printf 'NOOP\n'; return 0; }
    for cls in ${classes}; do
        _ci_sot_list "impact_classes.${cls}.phases"
    done | sort -u
}

# =========================================================
# PARALLELISM
# =========================================================

# What: bats job count = max(16, nproc*2).
# Why: Parallel is mandatory; a floor keeps small runners busy.
# From: Issue #479
_ci_jobs() {
    local n j
    n="$(nproc 2>/dev/null || printf '4')"
    j=$(( n * 2 ))
    [ "${j}" -lt 16 ] && j=16
    printf '%s\n' "${j}"
}

# =========================================================
# PHASES
# =========================================================

# What: Print the resolved external pins from the SOT.
# Why: Proves end-to-end SOT reads before wiring builds.
# From: Issue #479
ci_cmd_resolve() {
    printf 'debian_verify=%s\n'   "$(_ci_sot_scalar base_images.debian_verify)"
    printf 'debian_release=%s\n'  "$(_ci_sot_scalar base_images.debian_release)"
    printf 'golang_actionlint=%s\n' "$(_ci_sot_scalar base_images.golang_actionlint)"
    printf 'samba=%s\n'           "$(_ci_sot_scalar external_versions.samba.version)"
    printf 'actionlint=%s\n'      "$(_ci_sot_scalar external_versions.actionlint.version)"
}

# What: Print the phases selected by the base..head diff.
# Why: A docs-only diff selects doc-lint, never a compile.
# From: Issue #479
ci_cmd_impact() {
    local base="${1:?base ref required}" head="${2:?head ref required}"
    git -C "${CI_REPO_ROOT}" diff --name-only "${base}" "${head}" | _ci_phases_for_paths
}

# =========================================================
# GOVERNANCE GUARDS
# =========================================================

# What: Fail if any file under root contains a CR byte.
# Why: The repo is LF-only; CRLF breaks shell/heredoc parsing.
# From: Issue #479
ci_guard_line_endings() {
    local root="${1:-${CI_REPO_ROOT}/.github}" rc=0 f
    while IFS= read -r f; do
        rc=1
        ci_log "[CI-ERROR-GUARD-EOL-0001]" "CR/CRLF found: ${f}"
    done < <(grep -rlU "$(printf '\r')" "${root}" 2>/dev/null || true)
    return "${rc}"
}

# What: Fail if any sha256 digest is not full 64 lowercase hex.
# Why: Full-length SHAs only; no abbreviations or special forms.
# From: Issue #479
ci_guard_full_sha() {
    local root="${1:-${CI_REPO_ROOT}/.github}" rc=0 hit
    while IFS= read -r hit; do
        [ -n "${hit}" ] || continue
        rc=1
        ci_log "[CI-ERROR-GUARD-SHA-0001]" "not a full 64-hex sha256: ${hit}"
    done < <(grep -rhoE 'sha256:[0-9a-fA-F]+' "${root}" 2>/dev/null \
             | awk -F: 'length($2)!=64 || $2 ~ /[A-F]/ { print }' || true)
    while IFS= read -r hit; do
        [ -n "${hit}" ] || continue
        rc=1
        ci_log "[CI-ERROR-GUARD-SHA-0002]" "not a full 40-hex action SHA: ${hit}"
    done < <(grep -rhoE 'uses:[[:space:]]*[^@[:space:]]+@[0-9a-fA-F]+([[:space:]]|$)' "${root}" 2>/dev/null \
             | grep -oE '@[0-9a-fA-F]+' \
             | grep -vE '^@[0-9a-f]{40}$' || true)
    return "${rc}"
}

# What: Fail if a SOT base-image pin is absent from its Dockerfile.
# Why: Binds Dependabot's Dockerfile digest bumps to the SOT; no drift.
# From: Issue #479
ci_guard_dependabot_consistency() {
    local root="${1:-${CI_REPO_ROOT}}" rc=0 pair key df sot
    for pair in \
        "debian_verify:docker/verify/Dockerfile" \
        "debian_release:docker/release/Dockerfile" \
        "golang_actionlint:docker/verify/Dockerfile"; do
        key="${pair%%:*}"; df="${pair#*:}"
        [ -f "${root}/${df}" ] || continue
        sot="$(_ci_sot_scalar "base_images.${key}")"
        if [ -z "${sot}" ]; then
            rc=1
            ci_log "[CI-ERROR-GUARD-DEP-0001]" "SOT missing base_images.${key}"
            continue
        fi
        if ! grep -Fq "${sot}" "${root}/${df}" 2>/dev/null; then
            rc=1
            ci_log "[CI-ERROR-GUARD-DEP-0002]" "base_images.${key}=${sot} not present in ${df}"
        fi
    done
    return "${rc}"
}

# What: Run the governance guards over the CI-owned tree.
# Why: One phase enforces the repo's CI hygiene invariants.
# From: Issue #479
ci_cmd_lint() {
    local rc=0 d
    ci_guard_line_endings "${CI_REPO_ROOT}/.github" || rc=1
    ci_guard_line_endings "${CI_REPO_ROOT}/docker" || rc=1
    # Full-SHA scans only files that may carry pins; scripts carry none
    # by design (ci.sh reads pins from the SOT, ci.bats holds fixtures).
    for d in .github/workflows .github/actions .github/yaml docker; do
        [ -e "${CI_REPO_ROOT}/${d}" ] || continue
        ci_guard_full_sha "${CI_REPO_ROOT}/${d}" || rc=1
    done
    ci_guard_dependabot_consistency "${CI_REPO_ROOT}" || rc=1
    return "${rc}"
}

# =========================================================
# DISPATCH
# =========================================================

# What: Route a subcommand to its phase function.
# Why: One-list membership avoids a duplicated command list.
# From: Issue #479
ci_main() {
    local command="${1:-}"
    if [ "$#" -gt 0 ]; then shift; fi
    case " ${CI_COMMANDS} " in
        *" ${command} "*)
            ci_require_manifest || return "$?"
            case "${command}" in
                resolve) ci_cmd_resolve "$@" ;;
                impact) ci_cmd_impact "$@" ;;
                lint) ci_cmd_lint "$@" ;;
                *) ci_not_implemented "${command}" "$@" ;;
            esac
            ;;
        *)
            ci_log "[CI-ERROR-CORE-0002]" "command=\"${command}\" reason=\"unknown subcommand\" known=\"${CI_COMMANDS}\""
            return 2
            ;;
    esac
}

# What: Run the dispatcher only on direct execution.
# Why: Lets ci.bats source the functions to test them.
# From: Issue #479
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    ci_main "$@"
fi
