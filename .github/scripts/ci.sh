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
CI_COMMANDS="plan impact identity resolve build test e2e analyze scan lint selftest metadata package container publish release gc variables"

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
    cd "${CI_REPO_ROOT}"
    git diff --name-only "${base}" "${head}" | _ci_phases_for_paths
}

# What: Emit the build matrix JSON (variant x os) from the SOT.
# Why: One owner feeds strategy.matrix; opt-in variants excluded.
# From: Issue #479
ci_cmd_matrix() {
    local v os first=1 out='{"include":[' apt brew
    for v in $(_ci_sot_children build_matrix.variants); do
        [ "$(_ci_sot_scalar "build_matrix.variants.${v}.opt_in")" = "true" ] && continue
        apt="$(_ci_sot_scalar "build_matrix.variants.${v}.apt")"
        brew="$(_ci_sot_scalar "build_matrix.variants.${v}.brew")"
        for os in $(_ci_sot_list "build_matrix.variants.${v}.os"); do
            [ "${first}" -eq 1 ] || out="${out},"
            first=0
            case "${os}" in
                macos*) out="${out}{\"variant\":\"${v}\",\"os\":\"${os}\",\"brew\":\"${brew}\"}" ;;
                *)      out="${out}{\"variant\":\"${v}\",\"os\":\"${os}\",\"apt\":\"${apt}\"}" ;;
            esac
        done
    done
    printf '%s]}\n' "${out}"
}

# What: Write phases/build/matrix outputs for the base..head diff.
# Why: One command feeds the orchestrator; no logic in the YAML.
# From: Issue #479
ci_cmd_plan() {
    local base="${1:-}" head="${2:-HEAD}"
    local phases build=false matrix
    cd "${CI_REPO_ROOT}"
    if [ -z "${base}" ] || ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1; then
        # Unknown base (e.g. first push / branch creation): run everything.
        phases="build test e2e coverage analyze scan lint selftest"
    else
        phases="$(git diff --name-only "${base}" "${head}" \
            | _ci_phases_for_paths | tr '\n' ' ')"
        phases="${phases% }"
    fi
    case " ${phases} " in *" build "*) build=true ;; esac
    if [ "${build}" = "true" ]; then matrix="$(ci_cmd_matrix)"; else matrix='{"include":[]}'; fi
    {
        printf 'phases=%s\n' "${phases}"
        printf 'build=%s\n' "${build}"
        printf 'matrix=%s\n' "${matrix}"
    } >> "${GITHUB_OUTPUT:-/dev/stdout}"
}

# What: Run the distributed-compile e2e harness (distributed|full).
# Why: distributed = 2-container; full = bidirectional compat matrix.
# From: Issue #479
ci_cmd_e2e() {
    cd "${CI_REPO_ROOT}"
    case "${1:-distributed}" in
        full) bash test/e2e-full/run-bidirectional-e2e.sh ;;
        *)    bash test/e2e/run-e2e.sh ;;
    esac
}

# =========================================================
# PACKAGING / RELEASE
# =========================================================

# What: Build the source tarball and binary packages (make deb).
# Why: Folds build-release-packages.sh; fails on a missing tool.
# From: Issue #479
ci_cmd_package() {
    cd "${CI_REPO_ROOT}"
    local py tool
    py="$(command -v python3.13 || command -v python3)"
    for tool in "${py}" pkg-config eu-strip rpmbuild alien fakeroot; do
        command -v "${tool}" >/dev/null 2>&1 \
            || { ci_log "[CI-ERROR-PACKAGE-0001]" "missing tool: ${tool}"; return 1; }
    done
    ./autogen.sh
    ./configure PYTHON="${py}" --enable-Werror
    make -j"${JOBS:-2}" deb
}

# What: Fail unless a release tag matches configure.ac and is new.
# Why: Folds check-release-version.sh; fail-closed release guardrail.
# From: Issue #479
_ci_check_release_version() {
    local tag="${1:?tag required}" version configured
    version="${tag#v}"
    cd "${CI_REPO_ROOT}"
    [ -f configure.ac ] || { ci_log "[CI-ERROR-RELEASE-0001]" "no configure.ac"; return 1; }
    configured="$(sed -n 's/^AC_INIT(\[distcc-ng\],\[\([^]]*\)\].*/\1/p' configure.ac)"
    [ -n "${configured}" ] || { ci_log "[CI-ERROR-RELEASE-0002]" "cannot parse AC_INIT version"; return 1; }
    if [ "${configured}" != "${version}" ]; then
        ci_log "[CI-ERROR-RELEASE-0003]" "configure.ac=${configured} != tag ${tag}"
        return 1
    fi
    if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1; then
        ci_log "[CI-ERROR-RELEASE-0004]" "tag ${tag} already exists"
        return 1
    fi
    ci_log "[CI-RELEASE]" "OK: ${tag} matches configure.ac and is new"
}

# What: Build and push a release-family container image.
# Why: Base image ARG comes from the SOT; folds nightly's docker build.
# From: Issue #479
ci_cmd_container() {
    local variant="${1:?variant required}" ref debian
    cd "${CI_REPO_ROOT}"
    ref="${BUILT_SHA:-$(git rev-parse HEAD)}"
    debian="$(_ci_sot_scalar base_images.debian_release)"
    case "${variant}" in
        nightly)
            docker build --file docker/release/Dockerfile \
                --build-arg "DEBIAN_IMAGE=${debian}" \
                --build-arg "VCS_REF=${ref}" \
                --build-arg "VERSION=nightly" \
                --tag "${IMAGE_TAG:?IMAGE_TAG required}" .
            docker push "${IMAGE_TAG}" ;;
        *) ci_log "[CI-ERROR-CONTAINER-0001]" "unimplemented container variant=\"${variant}\""; return 2 ;;
    esac
}

# What: Force-move the floating nightly tag and (re)publish its prerelease.
# Why: Folds nightly-publish.yml; refuses to move a real v* release tag.
# From: Issue #479
_ci_publish_nightly() {
    cd "${CI_REPO_ROOT}"
    local tag="${NIGHTLY_TAG:?NIGHTLY_TAG required}" ref repo notes
    ref="${BUILT_SHA:-$(git rev-parse HEAD)}"
    repo="${GITHUB_REPOSITORY:-wiki-mod/distcc-ng}"
    case "${tag}" in
        v*) ci_log "[CI-ERROR-PUBLISH-0002]" "refusing to force-move a v* tag: ${tag}"; return 1 ;;
    esac
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git tag -f "${tag}"
    git push -f origin "refs/tags/${tag}"
    shopt -s nullglob
    local assets=(distcc-*.tar.gz distcc-*.tar.bz2 packaging/*.rpm packaging/*.deb)
    notes="$(mktemp)"
    {
        printf 'Automated nightly build of current_dev (%s).\n\n' "${ref}"
        printf 'Unstable nightly channel -- NOT a real release; overwritten each run.\n\n'
        printf 'Container image: %s\n' "${IMAGE_TAG:-}"
    } > "${notes}"
    if gh release view "${tag}" --repo "${repo}" >/dev/null 2>&1; then
        gh release delete "${tag}" --repo "${repo}" --yes
    fi
    gh release create "${tag}" "${assets[@]}" --repo "${repo}" \
        --title "distcc-ng nightly" --notes-file "${notes}" \
        --prerelease --latest=false --target "${ref}"
}

# What: Publish a release-family artifact set.
# Why: Outward; nightly folded, real release cut is maintainer-driven.
# From: Issue #479
ci_cmd_publish() {
    local variant="${1:?variant required}"
    case "${variant}" in
        nightly) _ci_publish_nightly ;;
        *) ci_log "[CI-ERROR-PUBLISH-0001]" "unimplemented publish variant=\"${variant}\""; return 2 ;;
    esac
}

# What: Release subcommands; version-check is safe, cut is outward.
# Why: The version guardrail runs anywhere; publishing is maintainer-gated.
# From: Issue #479
ci_cmd_release() {
    local sub="${1:-}"
    if [ "$#" -gt 0 ]; then shift; fi
    case "${sub}" in
        version-check) _ci_check_release_version "$@" ;;
        *) ci_log "[CI-ERROR-RELEASE-0005]" "unknown release subcommand=\"${sub}\" (version-check)"; return 2 ;;
    esac
}

# What: Delete or (dry-run) list one stale GHCR package version.
# Why: DRY_RUN=true only lists; real deletes need delete:packages PAT.
# From: Issue #479
_ci_gc_delete_version() {
    local pkg="$1" id="$2" reason="$3"
    if [ "${DRY_RUN:-true}" = "true" ]; then
        echo "[dry-run] would delete ${pkg}#${id} (${reason})"
    else
        echo "deleting ${pkg}#${id} (${reason})"
        gh api --method DELETE "orgs/${OWNER}/packages/container/${pkg}/versions/${id}" --silent
    fi
}

# What: Prune stale GHCR versions (untagged + old manual-N builds).
# Why: Verbatim fold of ghcr-cleanup.sh; never touches real/latest tags.
# From: Issue #479
ci_cmd_gc() {
    : "${GH_TOKEN:?GH_TOKEN required (delete:packages scope when DRY_RUN=false)}"
    : "${OWNER:?OWNER required, e.g. wiki-mod}"
    local sel="${1:-all}" pkgs
    if [ "${sel}" = "all" ]; then
        pkgs="distcc-ng distcc-ng-pump distcc-ng-nightly distcc-ng-buildtools distcc-ng-e2e"
    else
        pkgs="${sel}"
    fi
    local DRY_RUN="${DRY_RUN:-true}" KEEP_MANUAL="${KEEP_MANUAL:-2}" KEEP_UNTAGGED="${KEEP_UNTAGGED:-3}"
    local pkg versions_json all_tags tag raw kept created id digest manual_numbers keep_numbers num
    for pkg in ${pkgs}; do
        echo "::group::${pkg}"
        versions_json="$(gh api --paginate "orgs/${OWNER}/packages/container/${pkg}/versions")"
        declare -A protected=()
        all_tags="$(jq -r '.[].metadata.container.tags[]?' <<< "${versions_json}" | sort -u)"
        while IFS= read -r tag; do
            [ -z "${tag}" ] && continue
            raw="$(docker buildx imagetools inspect --raw "ghcr.io/${OWNER}/${pkg}:${tag}" 2>/dev/null)" || continue
            if grep -q 'manifest\.list\.v2\|image\.index\.v1' <<< "${raw}"; then
                while IFS= read -r child; do
                    protected["${child}"]=1
                done < <(jq -r '.manifests[]?.digest' <<< "${raw}")
            fi
        done <<< "${all_tags}"
        deletable_untagged="$(
            jq -r '.[] | select((.metadata.container.tags | length) == 0) | [.created_at, .id, .name] | @tsv' <<< "${versions_json}" \
              | while IFS=$'\t' read -r created id digest; do
                    [ -z "${id}" ] && continue
                    if [ -n "${protected[${digest}]+x}" ]; then
                        echo "SKIP untagged ${digest} (${pkg}#${id}): still referenced by a live multi-arch manifest" >&2
                        continue
                    fi
                    printf '%s\t%s\t%s\n' "${created}" "${id}" "${digest}"
                done | sort -r
        )"
        kept=0
        while IFS=$'\t' read -r created id digest; do
            [ -z "${id}" ] && continue
            kept=$((kept + 1))
            if [ "${kept}" -le "${KEEP_UNTAGGED}" ]; then
                echo "KEEP untagged ${digest} (${pkg}#${id}, created ${created})"
                continue
            fi
            _ci_gc_delete_version "${pkg}" "${id}" "untagged ${digest}, created ${created}"
        done <<< "${deletable_untagged}"
        manual_numbers="$(jq -r '.[].metadata.container.tags[]?' <<< "${versions_json}" \
            | sed -nE 's/^manual-([0-9]+)(-amd64|-arm64)?$/\1/p' | sort -un)"
        keep_numbers="$(printf '%s\n' "${manual_numbers}" | sort -urn | head -n "${KEEP_MANUAL}")"
        while IFS=$'\t' read -r id tag; do
            [ -z "${id}" ] && continue
            num="$(sed -E 's/^manual-([0-9]+).*/\1/' <<< "${tag}")"
            if grep -qx "${num}" <<< "${keep_numbers}"; then
                continue
            fi
            _ci_gc_delete_version "${pkg}" "${id}" "old manual tag ${tag}"
        done < <(jq -r '.[] | .id as $id | .metadata.container.tags[]? | select(test("^manual-[0-9]+(-amd64|-arm64)?$")) | [$id, .] | @tsv' <<< "${versions_json}")
        unset protected
        echo "::endgroup::"
    done
}

# =========================================================
# METADATA CHECKS (PR context)
# =========================================================

# What: Validate a PR title against the rule-71 taxonomy.
# Why: Folds check-pr-title-convention.sh; dependabot exempt.
# From: Issue #479, rule 71
_ci_check_pr_title() {
    local title="${1:-${PR_TITLE:-}}"
    if [ "${PR_AUTHOR:-}" = "dependabot[bot]" ]; then
        ci_log "[CI-META-TITLE]" "skipped: dependabot[bot] cannot conform"
        return 0
    fi
    local mode="${PR_TITLE_LINT_MODE:-warn}" draft="${PR_DRAFT:-false}"
    if [ -z "${title}" ]; then
        ci_log "[CI-ERROR-META-TITLE-0001]" "no PR title provided"
        return 1
    fi
    title="${title%$'\r'}"
    title="$(printf '%s' "${title}" | sed 's/[[:space:]]*$//')"
    local types="feat fix docs refactor perf test build ci chore style revert security"
    local scopes="distcc distccd pump protocol seccomp zstd config packaging docker ci docs scripts tests governance support-upstream"
    local errs=() t sc subj tsub
    if [[ "${title}" =~ ^([a-zA-Z]+)(\(([a-z0-9-]+)\))?(!)?:[[:space:]](.+)$ ]]; then
        t="${BASH_REMATCH[1]}"; sc="${BASH_REMATCH[3]}"; subj="${BASH_REMATCH[5]}"
        tsub="$(printf '%s' "${subj}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        case " ${types} " in *" ${t} "*) ;; *) errs+=("type '${t}' not in: ${types}") ;; esac
        if [ -n "${sc}" ]; then
            case " ${scopes} " in *" ${sc} "*) ;; *) errs+=("scope '(${sc})' not a documented area") ;; esac
        fi
        [ -n "${tsub}" ] || errs+=("subject is empty")
    else
        errs+=("not Conventional-Commit 'type(scope)!: subject'")
    fi
    if [ "${#errs[@]}" -eq 0 ]; then
        ci_log "[CI-META-TITLE]" "OK: ${title}"
        return 0
    fi
    local msg="PR title check failed (rule 71): '${title}'" e
    for e in "${errs[@]}"; do msg="${msg}; ${e}"; done
    if [ "${draft}" = "true" ] || [ "${mode}" = "warn" ]; then
        ci_log "[CI-WARN-META-TITLE]" "${msg} (non-blocking)"
        return 0
    fi
    ci_log "[CI-ERROR-META-TITLE-0002]" "${msg}"
    return 1
}

# What: Enforce PR labels + milestone (rule 3); board best-effort.
# Why: Folds check-pr-tracking-metadata.sh's always-enforced core.
# From: Issue #479, rule 3
_ci_check_pr_tracking() {
    if [ "${PR_AUTHOR:-}" = "dependabot[bot]" ]; then
        ci_log "[CI-META-TRACKING]" "skipped: dependabot[bot]"
        return 0
    fi
    local errs=() labels="${PR_LABELS:-}"
    [ -n "${labels//[[:space:]]/}" ] || errs+=("no labels set")
    [ -n "${PR_MILESTONE_TITLE:-}" ] || errs+=("no milestone set")
    if [ "${#errs[@]}" -eq 0 ]; then
        ci_log "[CI-META-TRACKING]" "OK: labels + milestone set (board best-effort)"
        return 0
    fi
    local msg="PR tracking metadata failed (rule 3)" e
    for e in "${errs[@]}"; do msg="${msg}; ${e}"; done
    ci_log "[CI-ERROR-META-TRACKING-0001]" "${msg}"
    return 1
}

# What: Require a CHANGELOG.md change or the no-changelog-needed label.
# Why: Folds require_changelog; PR_LABELS/BASE/HEAD from the workflow.
# From: Issue #479
_ci_check_changelog() {
    if [ "${PR_AUTHOR:-}" = "dependabot[bot]" ]; then
        ci_log "[CI-META-CHANGELOG]" "skipped: dependabot[bot]"
        return 0
    fi
    case " ${PR_LABELS:-} " in
        *" no-changelog-needed "*)
            ci_log "[CI-META-CHANGELOG]" "skipped: no-changelog-needed label"
            return 0 ;;
    esac
    cd "${CI_REPO_ROOT}"
    if git diff --name-only "${BASE:-}" "${HEAD:-HEAD}" 2>/dev/null | grep -qx 'CHANGELOG.md'; then
        ci_log "[CI-META-CHANGELOG]" "OK: CHANGELOG.md touched"
        return 0
    fi
    ci_log "[CI-ERROR-META-CHANGELOG-0001]" "no CHANGELOG.md change and no no-changelog-needed label"
    return 1
}

# What: Run the requested PR-metadata check(s).
# Why: One phase replaces changelog-check.yml's PR-context jobs.
# From: Issue #479
ci_cmd_metadata() {
    local sub="${1:-all}" rc=0
    case "${sub}" in
        title)     _ci_check_pr_title || rc=1 ;;
        tracking)  _ci_check_pr_tracking || rc=1 ;;
        changelog) _ci_check_changelog || rc=1 ;;
        all)
            _ci_check_pr_title || rc=1
            _ci_check_pr_tracking || rc=1
            _ci_check_changelog || rc=1 ;;
        *) ci_log "[CI-ERROR-META-0001]" "unknown metadata check=\"${sub}\""; return 2 ;;
    esac
    return "${rc}"
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

# What: Print orchestrator-only violations in a workflow's run: blocks.
# Why: AG-CI-023 forbids inline logic; run: calls one command only.
# From: Issue #479
_ci_scan_run_blocks() {
    awk -v F="$1" '
        function flag(r){ print F":"NR": "r }
        { match($0,/^[ ]*/); ind=RLENGTH
          if (inrun && $0 !~ /^[ ]*$/ && ind <= runind) inrun=0
          if ($0 ~ /^[ ]*(- )?run:[ ]*[|>]/) { inrun=1; runind=ind; next }
          scan = ($0 ~ /^[ ]*(- )?run:[ ]/) || inrun
          if (!scan) next
          l=$0
          if (l ~ /(^|[;&(| ])(if|for|while|until|case)([ (]|$)/) flag("control-flow keyword")
          if (index(l,"&&")) flag("&& chaining")
          if (index(l,"||")) flag("|| chaining")
          if (l ~ /;/) flag("; chaining")
          if (l ~ /\|/ && !index(l,"||")) flag("pipe")
          if (index(l,"$(")) flag("command substitution")
          if (index(l,"`")) flag("backtick substitution")
          if (index(l,"<<")) flag("heredoc")
          if (l ~ /bash[ ]+-c/) flag("bash -c")
          if (l ~ /python3?[ ]+-c/) flag("python -c")
          if (l ~ /(^|[ ])(awk|sed|jq)([ ]|$)/) flag("awk/sed/jq")
          if (l ~ /set[ ]+-[euo]/) flag("set -e/-u/-o")
        }
    ' "$1"
}

# What: Fail if any given workflow has inline logic in a run: block.
# Why: New orchestrators must call one command; legacy is exempt (#267 clause).
# From: Issue #479
ci_guard_orchestrator_only() {
    local rc=0 f hit
    for f in "$@"; do
        [ -f "${f}" ] || continue
        while IFS= read -r hit; do
            [ -n "${hit}" ] || continue
            rc=1
            ci_log "[CI-ERROR-GUARD-ORCH-0001]" "${hit}"
        done < <(_ci_scan_run_blocks "${f}")
    done
    return "${rc}"
}

# What: Run the ci.bats regression suite in parallel.
# Why: The engine tests itself when .github/scripts changes.
# From: Issue #479
ci_cmd_selftest() {
    bats --jobs "$(_ci_jobs)" "${CI_SCRIPT_DIR}/ci.bats"
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
    # Every shipped workflow is an orchestrator; there is no legacy exemption.
    ci_guard_orchestrator_only "${CI_REPO_ROOT}"/.github/workflows/*.yml || rc=1
    return "${rc}"
}

# =========================================================
# BUILD / TEST
# =========================================================

# What: True if a build log holds a real gcc/clang warning.
# Why: Warnings are errors (rule 31); anchored to diag shape.
# From: Issue #479
_ci_has_compiler_warning() {
    grep -qE '^[^: ]+\.(c|h|cc|cpp):[0-9]+:([0-9]+:)? *[Ww]arning:' "$1"
}

# What: Compile vendored popt/*.c under this repo's warn flags.
# Why: popt-vendor proves bundled popt builds Werror-clean.
# From: Issue #479, Issue #63
_ci_popt_strict_compile() {
    local out="${RUNNER_TEMP:-/tmp}/popt-strict-check" f
    mkdir -p "${out}"
    local cflags=(-DHAVE_CONFIG_H -D_GNU_SOURCE \
        "-DPOPT_SYSCONFDIR=\"/usr/local/etc\"" "-DPACKAGE=\"distcc\"" \
        -Isrc -Ipopt -Wall -Wextra -Werror -Wno-unused -Wno-unused-parameter)
    for f in popt/popt.c popt/poptconfig.c popt/popthelp.c popt/poptparse.c popt/poptint.c; do
        gcc "${cflags[@]}" -c "${f}" -o "${out}/$(basename "${f}").o"
    done
}

# What: Build one configure variant from the SOT matrix.
# Why: Folds c-build.yml per-variant configure/make, Werror-clean.
# From: Issue #479
ci_cmd_build() {
    local variant="${1:?variant required}" log
    cd "${CI_REPO_ROOT}"
    log="${RUNNER_TEMP:-/tmp}/ci-build-${variant}.log"
    case "${variant}" in
        default|popt-fallback|popt-vendor|coverage|sanitizer) ;;
        *) ci_log "[CI-ERROR-BUILD-0002]" "unknown variant=\"${variant}\""; return 2 ;;
    esac
    ./autogen.sh
    case "${variant}" in
        default)
            local cc="cc"
            command -v ccache >/dev/null 2>&1 && cc="$(command -v ccache) cc"
            ./configure CC="${cc}" \
                PYTHON="$(command -v python3.13 || command -v python3)" ;;
        popt-fallback)
            ./configure PYTHON="$(command -v python3)" 2>&1 | tee "${log}"
            grep -q "system libpopt not found (or disabled); building bundled popt" "${log}" \
                || { ci_log "[CI-ERROR-BUILD-POPT-0001]" "configure did not fall back to bundled popt (libpopt-dev leaking?)"; return 1; } ;;
        popt-vendor)
            ./configure --without-system-popt PYTHON="$(command -v python3)"
            _ci_popt_strict_compile
            return 0 ;;
        coverage)
            ./configure PYTHON="$(command -v python3)" \
                CFLAGS="--coverage -O0" LDFLAGS="--coverage" --with-seccomp ;;
        sanitizer)
            ./configure PYTHON="$(command -v python3)" --without-seccomp \
                CFLAGS="-O2 -fsanitize=address,undefined -fno-sanitize=alignment -fno-sanitize-recover=address -fsanitize-recover=undefined -fno-omit-frame-pointer -g -Wno-stringop-truncation" ;;
        *)
            ci_log "[CI-ERROR-BUILD-0002]" "unknown variant=\"${variant}\""
            return 2 ;;
    esac
    make 2>&1 | tee "${log}"
    if _ci_has_compiler_warning "${log}"; then
        ci_error "[CI-ERROR-BUILD-WARN-0001]" "variant=${variant} compiler warning (rule 31)" \
            "$(grep -E '^[^: ]+\.(c|h|cc|cpp):[0-9]+:([0-9]+:)? *[Ww]arning:' "${log}")"
        return 1
    fi
}

# What: Parse comfychair make-check output into a verdict.
# Why: 0/0/0 parsed is a hard fail (rule 66), not a clean pass.
# From: Issue #479
_ci_parse_comfychair() {
    local log="$1" ok notrun failed
    ok="$(grep -cE '^[A-Za-z0-9_]+[[:space:]]+OK[[:space:]]*$' "${log}" || true)"
    notrun="$(grep -cE '^[A-Za-z0-9_]+[[:space:]]+NOTRUN,' "${log}" || true)"
    failed="$(grep -cE '^[A-Za-z0-9_]+[[:space:]]+FAIL[[:space:]]*$' "${log}" || true)"
    ci_log "[CI-TEST-SUMMARY]" "OK=${ok} NOTRUN=${notrun} FAILED=${failed}"
    if [ "$(( ok + notrun + failed ))" -eq 0 ]; then
        ci_log "[CI-ERROR-TEST-0001]" "parsed zero comfychair result lines"
        return 1
    fi
    if [ "${failed}" -gt 0 ]; then
        grep -E '^[A-Za-z0-9_]+[[:space:]]+FAIL[[:space:]]*$' "${log}" >&2 || true
        ci_log "[CI-ERROR-TEST-0002]" "${failed} comfychair case(s) FAILED"
        return 1
    fi
    return 0
}

# What: Rerun the root-only case, fail on NOTRUN or non-OK.
# Why: The unprivileged make check leaves it NOTRUN otherwise.
# From: Issue #479
_ci_privileged_single_test() {
    if [ "$(uname -s)" != "Linux" ]; then
        ci_log "[CI-TEST-SKIP]" "autogroup privilege case is Linux-only; skipping on $(uname -s)"
        return 0
    fi
    local log="${RUNNER_TEMP:-/tmp}/ci-autogroup.log"
    sudo make TESTNAME=AutogroupNicenessPrivilegeDrop_Case single-test 2>&1 | tee "${log}"
    if grep -q "AutogroupNicenessPrivilegeDrop_Case NOTRUN" "${log}"; then
        ci_log "[CI-ERROR-TEST-0003]" "AutogroupNicenessPrivilegeDrop_Case NOTRUN"
        return 1
    fi
    grep -q "AutogroupNicenessPrivilegeDrop_Case OK" "${log}" \
        || { ci_log "[CI-ERROR-TEST-0004]" "AutogroupNicenessPrivilegeDrop_Case not OK"; return 1; }
}

# What: Create the coverage-recording PYTHON wrapper; print its path.
# Why: Records include_server/*.py into the coverage denominator.
# From: Issue #479, PR #370
_ci_coverage_python_wrapper() {
    local w="${RUNNER_TEMP:-/tmp}/coverage-python-wrapper" py
    py="$(command -v python3)"
    cat > "${w}" <<EOF
#!/bin/sh
if [ "\$1" = "-c" ]; then
    exec "${py}" "\$@"
fi
exec python3-coverage run --append --source="${CI_REPO_ROOT}/include_server" "\$@"
EOF
    chmod +x "${w}"
    printf '%s\n' "${w}"
}

# What: Capture C coverage into coverage.info via lcov.
# Why: Own shipped code only; lzo/ and src/h_*.c removed.
# From: Issue #479, PR #370
_ci_coverage_lcov() {
    lcov --capture --directory . --output-file coverage_raw.info \
        --rc branch_coverage=1 --rc geninfo_unexecuted_blocks=1
    lcov --remove coverage_raw.info '*/lzo/*' '*/src/h_*.c' \
        --output-file coverage.info --rc branch_coverage=1
    lcov --list coverage.info --rc branch_coverage=1
}

# What: Run make check for a variant and verify the result.
# Why: Folds run-tests.sh parse + c-build.yml per-variant env.
# From: Issue #479
ci_cmd_test() {
    local variant="${1:-default}" log wrapper st=0
    cd "${CI_REPO_ROOT}"
    log="${RUNNER_TEMP:-/tmp}/ci-check-${variant}.log"
    case "${variant}" in
        popt-vendor)
            ci_log "[CI-TEST-SKIP]" "popt-vendor has no make-check phase"
            return 0 ;;
        sanitizer)
            ASAN_OPTIONS=detect_leaks=0:verify_asan_link_order=0 UBSAN_OPTIONS=print_stacktrace=1 \
                make check > "${log}" 2>&1 || st=$? ;;
        coverage)
            wrapper="$(_ci_coverage_python_wrapper)"
            make check PYTHON="${wrapper}" > "${log}" 2>&1 || st=$? ;;
        default|popt-fallback)
            make check > "${log}" 2>&1 || st=$? ;;
        *)
            ci_log "[CI-ERROR-TEST-0005]" "unknown variant=\"${variant}\""
            return 2 ;;
    esac
    cat "${log}"
    if _ci_has_compiler_warning "${log}"; then
        ci_error "[CI-ERROR-TEST-WARN-0001]" "variant=${variant} make check warning (rule 31)" \
            "$(grep -E '^[^: ]+\.(c|h|cc|cpp):[0-9]+:([0-9]+:)? *[Ww]arning:' "${log}")"
        return 1
    fi
    _ci_parse_comfychair "${log}" || return 1
    if [ "${st}" -ne 0 ]; then
        ci_log "[CI-ERROR-TEST-0006]" "make check exited ${st} for variant=${variant}"
        return 1
    fi
    case "${variant}" in
        default|coverage) _ci_privileged_single_test || return 1 ;;
    esac
    [ "${variant}" = "coverage" ] && _ci_coverage_lcov
    return 0
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
                matrix) ci_cmd_matrix "$@" ;;
                plan) ci_cmd_plan "$@" ;;
                build) ci_cmd_build "$@" ;;
                test) ci_cmd_test "$@" ;;
                e2e) ci_cmd_e2e "$@" ;;
                selftest) ci_cmd_selftest "$@" ;;
                metadata) ci_cmd_metadata "$@" ;;
                package) ci_cmd_package "$@" ;;
                container) ci_cmd_container "$@" ;;
                publish) ci_cmd_publish "$@" ;;
                gc) ci_cmd_gc "$@" ;;
                release) ci_cmd_release "$@" ;;
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
