#!/usr/bin/env bash
# distcc-ng (https://github.com/wiki-mod/distcc-ng)
# SPDX-License-Identifier: GPL-2.0-or-later
# What: Single authoritative CI engine.
# Why: All CI decisions live here; YAML only orchestrates.
# From: Issue #479
set -euo pipefail

# What: Absolute directory of this script, if it has one.
# Why: curl|bash bootstrap has no BASH_SOURCE; must not crash.
# From: Issue #479
CI_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
CI_SCRIPT_DIR="${CI_SCRIPT_DIR:-$(pwd)}"

# What: Path to the single source-of-truth manifest.
# Why: One machine-readable owner for versions and matrix.
# From: Issue #479
CI_MANIFEST="${CI_MANIFEST:-${CI_SCRIPT_DIR}/../yaml/build-manifest.yml}"

# What: Repository root (.github/scripts/../..).
# Why: Phases resolve paths from the repo root.
# From: Issue #479
CI_REPO_ROOT="${CI_REPO_ROOT:-$(cd -- "${CI_SCRIPT_DIR}/../.." && pwd)}"

# What: Where every container sees the checkout, read-only.
# Why: Dockerfile RUN mounts and docker run share one path.
# From: Issue #479, PR #544
CI_CONTAINER_ROOT="/ci"

# What: Registry host of every image this repo publishes.
# Why: Login and image names share it; a guard binds the SOT.
# From: Issue #479, PR #544
CI_REGISTRY="ghcr.io"

# What: Release build trees the release Dockerfile copies.
# Why: ci.sh writes them, the Dockerfile COPYs; a guard binds.
# From: Issue #479, PR #544
CI_RELEASE_OUT="/out"
CI_RELEASE_PUMP_OUT="/out-pump"

# What: Directory under $SRC that holds the CFL checkout copy.
# Why: build.sh runs ci.sh there; the Dockerfile COPYs to it.
# From: Issue #267, Issue #479, PR #544
CI_CFL_PROJECT="distcc-ng"

# What: This engine as seen from inside a container.
# Why: Containers run ci.sh workloads, never inline scripts.
# From: Issue #479, PR #544
CI_CONTAINER_SH="${CI_CONTAINER_ROOT}/.github/scripts/ci.sh"

# What: Label that binds a resource to one ci.sh stack.
# Why: Teardown finds every leaked resource by this label.
# From: Issue #479, PR #544
CI_STACK_LABEL="ci-stack"

# What: ccache --show-stats line proving at least one hit.
# Why: The selftest and the Redis check share one proof.
# From: Issue #285, Issue #479, PR #544
CI_CCACHE_HIT_RE='Hits:[[:space:]]*[1-9]'

# What: The directories and files that CI itself owns.
# Why: Lint, comment and LF guards check one tree, not three.
# From: Issue #479, PR #544
CI_OWNED_PATHS=".github docker test/e2e .clusterfuzzlite .trivyignore.yaml"

# What: The known ci.sh subcommands.
# Why: One list drives dispatch and error text (no twin).
# From: Issue #479
CI_COMMANDS="checkout plan route impact impact-hit build cache test e2e scan lint selftest metadata package container publish release gc report gate verify variables install harden workload image sot-update attest"

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

# What: Run a mutating command, or print it if DRY_RUN=true.
# Why: One dry-run owner; each caller picks its own default.
# From: Issue #479, Issue #81, PR #544
_ci_mutate() {
    if [ "${DRY_RUN:-false}" = "true" ]; then
        printf 'DRY_RUN would run:'; printf ' %q' "$@"; printf '\n'
    else
        "$@"
    fi
}

# What: Fail closed unless the SOT manifest exists.
# Why: Every real operation derives state from the manifest.
# From: Issue #479
ci_require_manifest() {
    if [ ! -f "${CI_MANIFEST}" ]; then
        ci_log "[CI-ERROR-CORE-0003]" "manifest=\"${CI_MANIFEST}\" reason=\"manifest not found\""
        return 2
    fi
    _ci_sot_index
}

# What: Index the SOT once per manifest: sorted path arrays.
# Why: One parse and a binary search replace awk per lookup.
# From: Issue #479, PR #544
_ci_sot_index() {
    local idx rc=0
    [ "${_CI_SOT_KEY:-}" != "${CI_MANIFEST}" ] || return 0
    # What: Emit each first-seen path: kind, value, direct kids.
    # Why: Same path, value and first-hit rules as the writer.
    # From: Issue #479, PR #544
    idx="$(awk -v US=$'\x1f' -v GS=$'\x1d' '
        BEGIN { cur = -1 }
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        {
            match($0, /^ */); n = RLENGTH
            if (n % 2) { bad = NR; exit }
            d = n / 2
            for (i = cur + 1; i < d; i++) { stack[i] = "\001"; inst[i] = 0 }
            key = $0; sub(/^ +/, "", key); sub(/:.*$/, "", key)
            stack[d] = key; cur = d
            path = stack[0]
            for (i = 1; i <= d; i++) path = path "." stack[i]
            if (d > 0 && inst[d - 1]) {
                p = ppath[d - 1]
                kids[p] = kids[p] (kn[p]++ ? GS : "") key
            }
            inst[d] = !(path in kind); ppath[d] = path
            if (inst[d]) {
                rest = $0; sub(/^[^:]*:[[:space:]]*/, "", rest)
                if (match(rest, /^"[^"]*"/)) val = substr(rest, 2, RLENGTH - 2)
                else { val = rest; sub(/[[:space:]]+#.*$/, "", val); sub(/[[:space:]]+$/, "", val) }
                kind[path] = (rest == "" || rest ~ /^#/) ? "s" : "v"
                value[path] = val; order[++no] = path
            }
        }
        END {
            if (bad) { print bad; exit 5 }
            for (i = 1; i <= no; i++) {
                p = order[i]
                printf "%s%s%s%s%s%s%s\n", p, US, kind[p], US, value[p], US, kids[p]
            }
        }
    ' "${CI_MANIFEST}")" || rc=$?
    case "${rc}" in
        0) ;;
        5) ci_log "[CI-ERROR-SOT-0011]" "manifest=\"${CI_MANIFEST}\" line ${idx}: odd indentation"; return 2 ;;
        *) ci_log "[CI-ERROR-SOT-0012]" "manifest=\"${CI_MANIFEST}\" cannot be read (rc ${rc})"; return 2 ;;
    esac
    # What: Sort by path in byte order; emit both arrays quoted.
    # Why: The lookup bisects with the same C-locale comparison.
    # From: Issue #479, PR #544
    idx="$(LC_ALL=C sort -t $'\x1f' -k1,1 <<< "${idx}" | awk -F $'\x1f' '
        {
            k = $1; r = substr($0, length($1) + 2)
            gsub(/\047/, "\047\\\047\047", k); gsub(/\047/, "\047\\\047\047", r)
            keys = keys " \047" k "\047"; recs = recs " \047" r "\047"
        }
        END { printf "_CI_SOT_K=(%s)\n_CI_SOT_V=(%s)\n", keys, recs }
    ')" || return 2
    # What: Apply the generated arrays in one eval.
    # Why: awk single-quotes every key and value it emits.
    # From: Issue #479, PR #544
    eval "${idx}"
    _CI_SOT_KEY="${CI_MANIFEST}"
}

# What: Forget the SOT index; the next read rebuilds it.
# Why: A write or a new fixture makes the old index stale.
# From: Issue #479, PR #544
_ci_sot_index_drop() {
    _CI_SOT_K=()
    _CI_SOT_V=()
    _CI_SOT_KEY=""
}

# What: Read a dotted SOT path from the index; 3 if absent.
# Why: One path rule for value and children reads.
# From: Issue #479, PR #544
_ci_sot_lookup() {
    local mode="$1" path="$2" rec="" kind val lo=0 hi mid LC_ALL=C
    case "${mode}" in
        value|children) ;;
        *) ci_log "[CI-ERROR-SOT-0009]" "unknown SOT walk mode=\"${mode}\""; return 2 ;;
    esac
    _ci_sot_index || return 2
    hi=$(( ${#_CI_SOT_K[@]} - 1 ))
    while [ "${lo}" -le "${hi}" ]; do
        mid=$(( (lo + hi) / 2 ))
        if [[ "${_CI_SOT_K[mid]}" == "${path}" ]]; then
            rec="${_CI_SOT_V[mid]}"
            break
        elif [[ "${_CI_SOT_K[mid]}" < "${path}" ]]; then
            lo=$(( mid + 1 ))
        else
            hi=$(( mid - 1 ))
        fi
    done
    [ "${lo}" -le "${hi}" ] || return 3
    kind="${rec%%$'\x1f'*}"
    rec="${rec#*$'\x1f'}"
    val="${rec%%$'\x1f'*}"
    # What: Fail on a scalar read of a section, or vice versa.
    # Why: A wrong node kind must fail, never read as empty.
    # From: Issue #479, PR #544
    case "${mode}/${kind}" in
        value/v) printf '%s\n' "${val}" ;;
        children/s)
            rec="${rec#*$'\x1f'}"
            [ -z "${rec}" ] || printf '%s\n' "${rec//$'\x1d'/$'\n'}" ;;
        *) ci_log "[CI-ERROR-SOT-0010]" "path=\"${path}\" reason=\"${mode} does not fit this node\""; return 2 ;;
    esac
}

# What: Print the SOT with one scalar replaced; 3 if absent.
# Why: The same path rule as the index, applied while copying.
# From: Issue #479, PR #544
_ci_sot_write() {
    local path="$1" value="$2" rc=0
    awk -v path="${path}" -v value="${value}" '
        BEGIN { n = split(path, want, "."); need = 1; hit = 0 }
        END { if (bad) exit 4; if (!hit) exit 3 }
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
        {
            match($0, /^ */); ind = RLENGTH / 2
            key = $0; sub(/^ +/, "", key); sub(/:.*$/, "", key)
            if (!hit) {
                if (ind + 1 < need) { need = ind + 1 }
                if (ind + 1 == need && key == want[need]) {
                    if (need == n) {
                        hit = 1
                        rest = $0; sub(/^[^:]*:[[:space:]]*/, "", rest)
                        if (rest == "" || rest ~ /^#/) { bad = 1; exit }
                        match($0, /^ *[^:]*:/)
                        print substr($0, 1, RLENGTH) " \"" value "\""
                        next
                    }
                    need++
                }
            }
            print
        }
    ' "${CI_MANIFEST}" || rc=$?
    if [ "${rc}" -eq 4 ]; then
        ci_log "[CI-ERROR-SOT-0013]" "path=\"${path}\" reason=\"set does not fit this node\""
        return 2
    fi
    return "${rc}"
}

# What: Log a SOT path that the manifest does not have.
# Why: Scalar, children and set share one absent-path error.
# From: Issue #479, PR #544
_ci_sot_absent() {
    ci_log "[CI-ERROR-SOT-0002]" "path=\"$1\" reason=\"not found in SOT\""
}

# What: Walk one SOT path; an absent path is an error.
# Why: A missing pin or section must never read as empty.
# From: Issue #479, PR #544
_ci_sot_required() {
    local rc=0
    _ci_sot_lookup "$@" || rc=$?
    if [ "${rc}" -eq 3 ]; then
        _ci_sot_absent "$2"
        return 2
    fi
    return "${rc}"
}

# What: Print the scalar at a dotted SOT path; fail if absent.
# Why: A missing pin must never read as an empty value.
# From: Issue #479, PR #544
_ci_sot_scalar() {
    _ci_sot_required value "$1"
}

# What: Print an optional SOT value; empty if absent.
# Why: For per-entry keys only, e.g. opt_in or brew.
# From: Issue #479, PR #544
_ci_sot_optional() {
    local rc=0
    _ci_sot_lookup value "$1" || rc=$?
    [ "${rc}" -eq 3 ] || return "${rc}"
}

# What: Print child keys of a dotted SOT path; fail if absent.
# Why: A missing section must not read as zero variants.
# From: Issue #479, PR #544
_ci_sot_children() {
    _ci_sot_required children "$1"
}

# What: Print each item of an inline `key: [a, b]` list.
# Why: One reader lets phases read path/phase lists as lines.
# From: Issue #479
_ci_sot_list() {
    local raw
    raw="$(_ci_sot_scalar "$1")" || return 2
    raw="${raw#"["}"
    raw="${raw%"]"}"
    printf '%s' "${raw}" \
        | tr ',' '\n' \
        | sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*$//' \
        | awk 'NF'
}

# What: Set one SOT scalar; swap in the new file by rename.
# Why: A failed write keeps the old SOT; subshells drop after.
# From: Issue #479, PR #544
_ci_sot_set() {
    local path="$1" value="$2" tmp rc=0
    tmp="$(mktemp "${CI_MANIFEST}.XXXXXX")" || return 2
    if ! cp -p "${CI_MANIFEST}" "${tmp}"; then
        rm -f "${tmp}"
        return 2
    fi
    _ci_sot_write "${path}" "${value}" > "${tmp}" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        rm -f "${tmp}" || return 2
        if [ "${rc}" -eq 3 ]; then
            _ci_sot_absent "${path}"
        else
            ci_log "[CI-ERROR-SOT-0007]" "path=\"${path}\" reason=\"cannot set (rc ${rc})\""
        fi
        return 2
    fi
    if ! mv -f "${tmp}" "${CI_MANIFEST}"; then
        rm -f "${tmp}"
        return 2
    fi
    _ci_sot_index_drop
}

# What: Match one SOT path glob to a path; 2 if sed fails.
# Why: The SOT owns the patterns; this owns matching.
# From: Issue #479, PR #544
_ci_glob_match() {
    local pat="$1" path="$2" re
    # What: Escape metachars; '**/' may match no directory.
    # Why: =~ needs a regex; '**/*.md' must match README.md.
    # From: Issue #479, PR #544
    re="${pat//\*\*\//$'\x02'}"
    re="${re//\*/$'\x01'}"
    re="$(printf '%s' "${re}" | sed 's/[.^$+?()[\]{}|]/\\&/g')" || return 2
    re="${re//$'\x02'/(.*/)?}"
    re="${re//$'\x01'/.*}"
    [[ "${path}" =~ ^${re}$ ]]
}

# What: Print the names in a SOT path map hit by stdin paths.
# Why: impact_classes and labels share one glob classifier.
# From: Issue #479, PR #544
_ci_classify_paths() {
    local map="${1:-impact_classes}" classes path cls pats excl rc
    classes="$(_ci_sot_children "${map}")" || return 2
    while IFS= read -r path; do
        [ -n "${path}" ] || continue
        for cls in ${classes}; do
            pats="$(_ci_sot_list "${map}.${cls}.paths")" || return 2
            rc=0
            _ci_paths_hit "${path}" "${pats}" || rc=$?
            [ "${rc}" -le 1 ] || return 2
            [ "${rc}" -eq 0 ] || continue
            excl="$(_ci_sot_optional "${map}.${cls}.exclude")" || return 2
            if [ -n "${excl}" ]; then
                excl="$(_ci_sot_list "${map}.${cls}.exclude")" || return 2
                rc=0
                _ci_paths_hit "${path}" "${excl}" || rc=$?
                [ "${rc}" -le 1 ] || return 2
                [ "${rc}" -eq 1 ] || continue
            fi
            printf '%s\n' "${cls}"
        done
    done | sort -u
}

# What: 0 if a glob line matches the path, 1 if none, 2 error.
# Why: A class's paths and its exclude list match alike.
# From: Issue #479, PR #544
_ci_paths_hit() {
    local path="$1" pat rc
    while IFS= read -r pat; do
        [ -n "${pat}" ] || continue
        rc=0
        _ci_glob_match "${pat}" "${path}" || rc=$?
        [ "${rc}" -ne 0 ] || return 0
        [ "${rc}" -eq 1 ] || return 2
    done <<< "$2"
    return 1
}

# What: Print the validate phases selected by paths on stdin.
# Why: NOOP when no matched class selects any job (docs only).
# From: Issue #479, PR #544
_ci_phases_for_paths() {
    local phases classes=()
    _ci_mapfile classes _ci_classify_paths || return 2
    phases="$(_ci_class_phases "${classes[@]}")" || return 2
    printf '%s\n' "${phases:-NOOP}"
}

# What: Print the sorted phase union of the given classes.
# Why: A diff's classes and the all-phases fallback agree.
# From: Issue #479, PR #544
_ci_class_phases() {
    local cls phases=""
    for cls in "$@"; do
        phases="${phases}$(_ci_sot_list "impact_classes.${cls}.phases")"$'\n' || return 2
    done
    awk 'NF' <<< "${phases}" | sort -u
}

# What: Print every phase any SOT impact class can select.
# Why: An unclassifiable diff runs all; the SOT owns the set.
# From: Issue #479, PR #544
_ci_all_phases() {
    local classes=()
    _ci_mapfile classes _ci_sot_children impact_classes || return 2
    _ci_class_phases "${classes[@]}"
}

# What: Print this host's CPU count; fail closed if unknown.
# Why: One count for bats jobs, make -j, waf -j and distccd.
# From: Issue #479, PR #544
_ci_nproc() {
    local n rc=0
    n="$(nproc)" || rc=$?
    if [ "${rc}" -ne 0 ] || ! [[ "${n}" =~ ^[1-9][0-9]*$ ]]; then
        ci_error "[CI-ERROR-CORE-0005]" "nproc failed (rc ${rc}); no CPU count" "${n}"
        return 2
    fi
    printf '%s\n' "${n}"
}

# What: bats job count = max(16, nproc*2).
# Why: Parallel is mandatory; a floor keeps runners busy.
# From: Issue #479
_ci_jobs() {
    local n j
    n="$(_ci_nproc)" || return 2
    j=$(( n * 2 ))
    [ "${j}" -lt 16 ] && j=16
    printf '%s\n' "${j}"
}

# What: Read a command's output lines into array $1, keep rc.
# Why: mapfile < <(cmd) drops cmd's exit status.
# From: Issue #479, PR #544
_ci_mapfile() {
    local -n _cm_ref="$1"
    local _cm_out _cm_rc=0
    shift
    _cm_out="$("$@")" || _cm_rc=$?
    _cm_ref=()
    [ "${_cm_rc}" -eq 0 ] || return "${_cm_rc}"
    [ -z "${_cm_out}" ] || mapfile -t _cm_ref <<< "${_cm_out}"
}

# What: Retry a probe until it succeeds; fail after N tries.
# Why: One bounded retry owner; probe rc >= 2 aborts at once.
# From: Issue #479, PR #544
_ci_wait_until() {
    local CI_TRIES="$1" pause="$2" CI_ATTEMPT rc
    shift 2
    for ((CI_ATTEMPT = 1; CI_ATTEMPT <= CI_TRIES; CI_ATTEMPT++)); do
        rc=0
        "$@" || rc=$?
        if [ "${rc}" -eq 0 ]; then
            return 0
        fi
        if [ "${rc}" -ne 1 ]; then
            return "${rc}"
        fi
        if [ "${CI_ATTEMPT}" -lt "${CI_TRIES}" ]; then
            sleep "${pause}" || return 2
        fi
    done
    return 1
}

# What: Recreate a directory empty; fail closed if it cannot.
# Why: A stale tree from an earlier pass must never be reused.
# From: Issue #479, PR #544
_ci_fresh_dir() {
    : "${1:?directory required}"
    if ! rm -rf "$1" || ! mkdir -p "$1"; then
        ci_log "[CI-ERROR-CORE-0006]" "cannot recreate directory $1"
        return 1
    fi
}

# What: Copy the checkout into a fresh <dir>/src.
# Why: The /ci mount stays read-only; builds need a copy.
# From: Issue #479, PR #544
_ci_tree_copy() {
    _ci_fresh_dir "$1" || return 1
    cp -a "${CI_REPO_ROOT}/." "$1/src"
}

# What: Make a temp dir holding a trivial ok.c; print it.
# Why: Tool self-tests compile and trace the same program.
# From: Issue #264, Issue #285, PR #544
_ci_scratch_c() {
    local d
    d="$(mktemp -d)" || return 1
    printf 'int main(void) { return 0; }\n' > "${d}/ok.c" || return 1
    printf '%s\n' "${d}"
}

# What: Print a run-unique resource name for one purpose.
# Why: Parallel jobs on one host must never share a name.
# From: Issue #479, PR #544
_ci_run_name() {
    printf 'ci-%s-%s-%s\n' "$1" "${GITHUB_RUN_ID:-local}" "$$"
}

# What: True once a container's log has a matching line.
# Why: A service's own ready line beats a probe client.
# From: Issue #479, PR #544
_ci_container_logged() {
    local ctr="$1" re="$2" logs
    if ! logs="$(docker logs "${ctr}" 2>&1)"; then
        ci_error "[CI-ERROR-CONTAINER-0006]" "docker logs ${ctr} failed" "${logs}"
        return 2
    fi
    grep -qE -- "${re}" <<< "${logs}"
}

# What: docker build one SOT image spec; ARGs from the SOT.
# Why: Sole pin path; Dockerfiles carry no default or LABEL.
# From: Issue #359, Issue #479, PR #544
_ci_image_build() {
    local spec="$1" version="$2" file target arg val tag desc ref created
    shift 2
    local specs=() opts=()
    file="$(_ci_sot_scalar "${spec}.dockerfile")" || return 2
    target="$(_ci_sot_scalar "${spec}.target")" || return 2
    _ci_mapfile specs _ci_sot_list "${spec}.args" || return 2
    for arg in "${specs[@]}"; do
        if [ "${arg}" = "${arg#*=}" ]; then
            ci_log "[CI-ERROR-IMAGE-0002]" "${spec}.args entry \"${arg}\" is not ARG=sot.path"
            return 2
        fi
        val="$(_ci_sot_scalar "${arg#*=}")" || return 2
        opts+=(--build-arg "${arg%%=*}=${val}")
    done
    tag="$(_ci_sot_optional "${spec}.tag")" || return 2
    if [ -n "${tag}" ]; then
        opts+=(--tag "${tag}")
    fi
    desc="$(_ci_sot_optional "${spec}.description")" || return 2
    if [ -n "${desc}" ]; then
        : "${version:?published image ${spec} needs a version}"
        : "${GITHUB_SERVER_URL:?GITHUB_SERVER_URL required}"
        : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
        ref="$(_ci_built_sha)" || return 1
        val="$(_ci_sot_scalar release.licenses)" || return 2
        created="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
        opts+=(--label "org.opencontainers.image.title=${spec##*.}"
            --label "org.opencontainers.image.description=${desc}"
            --label "org.opencontainers.image.version=${version}"
            --label "org.opencontainers.image.revision=${ref}"
            --label "org.opencontainers.image.created=${created}"
            --label "org.opencontainers.image.source=${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}"
            --label "org.opencontainers.image.licenses=${val}")
    fi
    docker build "$@" --file "${CI_REPO_ROOT}/${file}" --target "${target}" \
        "${opts[@]}" "${CI_REPO_ROOT}"
}

# What: Print the commit this run builds; --short abbreviates.
# Why: Image labels, tags and release notes name one commit.
# From: Issue #479, PR #544
_ci_built_sha() {
    local sha="${BUILT_SHA:-}"
    if [ -z "${sha}" ]; then
        sha="$(git -C "${CI_REPO_ROOT}" rev-parse HEAD)" || return 1
    fi
    if [ "${1:-}" = "--short" ]; then
        git -C "${CI_REPO_ROOT}" rev-parse --short "${sha}"
        return
    fi
    printf '%s\n' "${sha}"
}

# What: Pull a SOT-pinned image and give it a local tag.
# Why: For builders that pass no build-args, e.g. CFL.
# From: Issue #267, Issue #479, PR #544
_ci_image_alias() {
    local spec="$1" from image tag
    from="$(_ci_sot_scalar "${spec}.from")" || return 2
    image="$(_ci_sot_scalar "${from}")" || return 2
    tag="$(_ci_sot_scalar "${spec}.tag")" || return 2
    docker pull "${image}" || return 1
    docker tag "${image}" "${tag}"
}

# What: docker run --init; checkout read-only at /ci.
# Why: In a stack, teardown removes it after reading its log.
# From: Issue #479, PR #544
_ci_container_run() {
    local image="$1"
    shift
    local opts=(--init -v "${CI_REPO_ROOT}:${CI_CONTAINER_ROOT}:ro")
    if [ -n "${CI_STACK:-}" ]; then
        opts+=(--network "${CI_STACK}" --label "${CI_STACK_LABEL}=${CI_STACK}")
    else
        opts+=(--rm)
    fi
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        opts+=("$1")
        shift
    done
    if [ "$#" -eq 0 ]; then
        ci_log "[CI-ERROR-CONTAINER-0003]" "container run of ${image}: no -- before the command"
        return 2
    fi
    shift
    docker run "${opts[@]}" "${image}" "$@"
}

# What: Log each stack container's tail, remove it all.
# Why: A leaked stack breaks the next run; so it must fail.
# From: Issue #479, PR #544
_ci_stack_teardown() {
    local net="$1" rc=0 c
    local ctrs=() vols=()
    _ci_mapfile ctrs docker ps -aq --filter "label=${CI_STACK_LABEL}=${net}" || rc=1
    for c in "${ctrs[@]}"; do
        echo "== ${net}: last 100 log lines of ${c} =="
        docker logs --tail 100 "${c}" || rc=1
    done
    if [ "${#ctrs[@]}" -gt 0 ]; then
        docker rm -f "${ctrs[@]}" >/dev/null || rc=1
    fi
    _ci_mapfile vols docker volume ls -q --filter "label=${CI_STACK_LABEL}=${net}" || rc=1
    if [ "${#vols[@]}" -gt 0 ]; then
        docker volume rm "${vols[@]}" >/dev/null || rc=1
    fi
    local nets=""
    nets="$(docker network ls --format '{{.Name}}')" || rc=1
    if [[ $'\n'"${nets}"$'\n' == *$'\n'"${net}"$'\n'* ]]; then
        docker network rm "${net}" >/dev/null || rc=1
    fi
    if [ "${rc}" -ne 0 ]; then
        ci_log "[CI-ERROR-STACK-0001]" "teardown of ${net} failed; resources may leak"
    fi
    return "${rc}"
}

# What: Run a body on a fresh labelled net, then tear down.
# Why: Every container the body starts is torn down with it.
# From: Issue #479, PR #544
_ci_stack_run() {
    local net="$1" rc=0
    shift
    docker network create --label "${CI_STACK_LABEL}=${net}" "${net}" >/dev/null || return 1
    ( CI_STACK="${net}"; "$@" "${net}" ) || rc=$?
    if ! _ci_stack_teardown "${net}" && [ "${rc}" -eq 0 ]; then
        rc=1
    fi
    return "${rc}"
}

# What: docker login ghcr.io as GITHUB_ACTOR via stdin token.
# Why: Token varies per job; gc needs the delete:packages PAT.
# From: Issue #479, PR #544
_ci_registry_login() {
    : "${REGISTRY_TOKEN:?REGISTRY_TOKEN required}"
    : "${GITHUB_ACTOR:?GITHUB_ACTOR required}"
    printf '%s\n' "${REGISTRY_TOKEN}" | docker login "${CI_REGISTRY}" -u "${GITHUB_ACTOR}" --password-stdin
}

# What: Log in once, then push every given tag.
# Why: One push owner; no push without a fresh login.
# From: Issue #479, PR #544
_ci_registry_push() {
    local tag
    _ci_registry_login || return 1
    for tag in "$@"; do
        docker push "${tag}" || return 1
    done
}

# What: Print the paths that differ between two commits.
# Why: One diff source for impact, impact-hit and changelog.
# From: Issue #479, PR #544
_ci_changed_paths() {
    local out
    if ! out="$(git -C "${CI_REPO_ROOT}" diff --name-only "$1" "$2")"; then
        ci_log "[CI-ERROR-DIFF-0001]" "cannot diff $1..$2"
        return 1
    fi
    printf '%s\n' "${out}"
}

# What: Print the phases selected by the base..head diff.
# Why: A docs-only diff selects NOOP, never a compile.
# From: Issue #479
ci_cmd_impact() {
    local paths
    paths="$(_ci_changed_paths "${1:?base ref required}" "${2:?head ref required}")" || return 1
    _ci_phases_for_paths <<< "${paths}"
}

# What: Write hit=true/false for one impact class.
# Why: One command; no pipe or && chain in the workflow.
# From: Issue #479
ci_cmd_impact_hit() {
    local class="${1:?class required}" changed classes range=()
    # What: Only a PR diff can skip a class; other events run it.
    # Why: A push or schedule has no reviewed diff to classify.
    # From: Issue #479, PR #544
    if [ "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME required}" != "pull_request" ]; then
        ci_log "[CI-IMPACT]" "${GITHUB_EVENT_NAME}: no PR diff, ${class} runs"
        _ci_output hit true
        return
    fi
    _ci_mapfile range _ci_event_range || return 2
    [ "${#range[@]}" -eq 2 ] || return 2
    changed="$(_ci_changed_paths "${range[0]}" "${range[1]}")" || return 1
    classes="$(_ci_classify_paths <<< "${changed}")" || return 2
    if grep -qx "${class}" <<< "${classes}"; then
        _ci_output hit true
    else
        _ci_output hit false
    fi
}

# What: Emit the variant x os build matrix JSON from SOT.
# Why: One owner feeds strategy.matrix; opt-in excluded.
# From: Issue #479
ci_cmd_matrix() {
    local v os rows="" apt brew variants oses opt_in
    variants="$(_ci_sot_children build_matrix.variants)" || return 2
    for v in ${variants}; do
        opt_in="$(_ci_sot_optional "build_matrix.variants.${v}.opt_in")" || return 2
        [ "${opt_in}" != "true" ] || continue
        apt="$(_ci_sot_scalar "build_matrix.variants.${v}.apt")" || return 2
        brew="$(_ci_sot_optional "build_matrix.variants.${v}.brew")" || return 2
        oses="$(_ci_sot_list "build_matrix.variants.${v}.os")" || return 2
        for os in ${oses}; do
            case "${os}" in
                macos*) rows+="$(jq -cn --arg v "${v}" --arg o "${os}" --arg b "${brew}" \
                    '{variant: $v, os: $o, brew: $b}')"$'\n' || return 2 ;;
                *)      rows+="$(jq -cn --arg v "${v}" --arg o "${os}" --arg a "${apt}" \
                    '{variant: $v, os: $o, apt: $a}')"$'\n' || return 2 ;;
            esac
        done
    done
    jq -cs '{include: .}' <<< "${rows}"
}

# What: Print the value(s) of a jq filter on this run's event.
# Why: An absent or null field fails; it never reads empty.
# From: Issue #479, PR #544
_ci_event_value() {
    : "${GITHUB_EVENT_PATH:?GITHUB_EVENT_PATH required}"
    if ! jq -r "($1) | if . == null then error(\"absent\") else . end" "${GITHUB_EVENT_PATH}"; then
        ci_log "[CI-ERROR-EVENT-0001]" "${GITHUB_EVENT_NAME:-event} payload has no $1"
        return 2
    fi
}

# What: Print the base and head commit of this run's diff.
# Why: A PR diffs base..head; a push or dispatch before..sha.
# From: Issue #479, PR #544
_ci_event_range() {
    case "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME required}" in
        pull_request)
            _ci_event_value '.pull_request.base.sha, .pull_request.head.sha' ;;
        *)
            _ci_event_value '.before // ""' || return 2
            printf '%s\n' "${GITHUB_SHA:?GITHUB_SHA required}" ;;
    esac
}

# What: Write phases/build/matrix for this run's diff.
# Why: One command feeds the orchestrator; no YAML logic.
# From: Issue #479, PR #544
ci_cmd_plan() {
    local base head phases build=false publish=false matrix range=() mx=()
    _ci_mapfile range _ci_event_range || return 2
    if [ "${#range[@]}" -ne 2 ]; then
        ci_log "[CI-ERROR-PLAN-0001]" "cannot read this run's base and head"
        return 2
    fi
    base="${range[0]}" head="${range[1]}"
    cd "${CI_REPO_ROOT}" || return 1
    if [ -z "${base}" ] || ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null; then
        # What: An unknown base (first push) selects every phase.
        # Why: No diff exists to classify; NOOP would skip all.
        # From: Issue #479
        phases="$(_ci_all_phases | tr '\n' ' ')" || return 2
        phases="${phases% }"
    else
        phases="$(ci_cmd_impact "${base}" "${head}" | tr '\n' ' ')" || return 2
        phases="${phases% }"
    fi
    case " ${phases} " in *" build "*) build=true ;; esac
    # What: buildtools:latest publishes from a protected ref only.
    # Why: A dispatch on a bot branch must never publish :latest.
    # From: Issue #479, PR #544
    case " ${phases} " in
        *" verify "*) if _ci_ref_protected; then publish=true; fi ;;
    esac
    matrix='{"include":[]}'
    if [ "${build}" = "true" ]; then
        matrix="$(ci_cmd_matrix)" || return 2
    fi
    _ci_mapfile mx _ci_release_matrix || return 2
    [ "${#mx[@]}" -eq 2 ] || return 2
    _ci_output phases "${phases}" build "${build}" matrix "${matrix}" \
        container_variants "${mx[1]}" publish_buildtools "${publish}"
}

# What: Append a command's output to the job summary.
# Why: One summary writer; outside Actions it is NotRun.
# From: Issue #479, PR #544
_ci_step_summary() {
    if [ -z "${GITHUB_STEP_SUMMARY:-}" ]; then
        ci_log "[CI-SUMMARY]" "NotRun: GITHUB_STEP_SUMMARY unset, $1 not written"
        return 0
    fi
    "$@" >> "${GITHUB_STEP_SUMMARY}"
}

# What: Print the control-build's toolchain/dist verdict.
# Why: It tells a broken toolchain from a broken distcc path.
# From: Issue #263, Issue #479
_ci_control_build_summary() {
    if [ "$1" -eq 0 ]; then
        printf '## Control build: OK\n\nPlain-compiler ccache build succeeded; a same-run heartbeat failure is a distccd/distribution bug, not a toolchain issue.\n'
    else
        printf '## Control build: FAILED (exit %s)\n\nThe plain-compiler ccache build itself failed, with no distcc involved; a same-run heartbeat failure is toolchain/ccache-related, not a distccd bug.\n' "$1"
    fi
}

# What: Count server-log COMPILE_OK from clients in a CIDR.
# Why: Server-side proof of remote compiles, not fallback.
# From: Issue #479, Issue #264, PR #544
_ci_e2e_count_compile_ok() {
    local log="$1" cidr="$2"
    if [ ! -r "${log}" ]; then
        ci_log "[CI-ERROR-E2E-0002]" "server log ${log} is not readable"
        return 2
    fi
    awk -v cidr="${cidr}" '
        function ip2n(ip,  p) { split(ip, p, "."); return ((p[1] * 256 + p[2]) * 256 + p[3]) * 256 + p[4] }
        BEGIN {
            split(cidr, c, "/"); bits = (c[2] == "" ? 32 : c[2] + 0)
            size = 2 ^ (32 - bits); lo = int(ip2n(c[1]) / size) * size
        }
        match($0, /client: [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+ COMPILE_OK/) {
            ip = substr($0, RSTART + 8, RLENGTH - 8); sub(/:.*/, "", ip)
            n = ip2n(ip)
            if (n >= lo && n < lo + size) k++
        }
        END { print k + 0 }
    ' "${log}"
}

# What: Fail if a distcc-ng server logged a warning line.
# Why: A daemon warning never reaches the client's exit code.
# From: Issue #479, PR #544
_ci_e2e_check_server_warnings() {
    local log="$1" hits rc=0
    hits="$(grep -E 'EMERGENCY! |ALERT! |CRITICAL! |ERROR: |Warning: ' "${log}")" || rc=$?
    case "${rc}" in
        0) ci_error "[CI-ERROR-E2E-0015]" "distcc-ng distccd logged warning-or-worse lines" "${hits}"
           return 1 ;;
        1) return 0 ;;
        *) ci_log "[CI-ERROR-E2E-0017]" "cannot scan server log ${log} (grep rc ${rc})"
           return 1 ;;
    esac
}

# What: Build every SOT e2e image (ng, native).
# Why: ng is the checkout under test; native is Debian's.
# From: Issue #264, Issue #479, PR #544
_ci_e2e_images() {
    local flavors flavor
    flavors="$(_ci_sot_children e2e.images)" || return 2
    for flavor in ${flavors}; do
        _ci_image_build "e2e.images.${flavor}" "" || return 1
    done
}

# What: One leg+pass: fresh server, workload, server proof.
# Why: A client exit code alone cannot rule out fallback.
# From: Issue #479, Issue #264, PR #544
_ci_e2e_leg() {
    local mode="$1" leg="$2" pass="$3" workload="$4" extra="$5" floor="$6" net="$7"
    local subnet="$8" cli="${leg%%:*}" srv_flavor="${leg##*:}" id srv out client_rc=0 need n warn
    local srv_image cli_image
    id="${cli}-${srv_flavor}-${pass}"
    srv="${net}-server"
    out="${RUNNER_TEMP:-/tmp}/${net}-${id}"
    srv_image="$(_ci_sot_scalar "e2e.images.${srv_flavor}.tag")" || return 2
    cli_image="$(_ci_sot_scalar "e2e.images.${cli}.tag")" || return 2
    ci_log "[CI-E2E]" "${mode}: leg ${cli} -> ${srv_flavor}, pass ${pass}"
    local nj
    nj="$(_ci_nproc)" || return 2
    _ci_container_run "${srv_image}" -d --name "${srv}" --network-alias distccd-server -- \
        distccd --no-detach --daemon --verbose --log-stderr --port 3632 \
        --allow "${subnet}" --jobs "${nj}" >/dev/null || return 1
    # What: Wait for distccd's own "listening on" log line.
    # Why: A TCP probe is a denied client; listen() follows it.
    # From: Issue #479, PR #544
    if ! _ci_wait_until 30 1 _ci_container_logged "${srv}" 'listening on'; then
        ci_log "[CI-ERROR-E2E-0014]" "distccd in ${srv} never logged listening on"
        docker logs "${srv}" >&2 || return 1
        return 1
    fi
    _ci_container_run "${cli_image}" -v "${net}-cache:/work/cache" -e CI_WORKLOAD_CACHE=/work/cache \
        -e DISTCC_HOSTS=distccd-server:3632 -e DISTCC_FALLBACK=0 -e DISTCC_VERBOSE=1 -- \
        bash "${CI_CONTAINER_SH}" workload "${workload}" "${pass}" \
        "/work/workload/${id}" "${extra}" > "${out}.client" 2>&1 || client_rc=$?
    docker logs "${srv}" > "${out}.server" 2>&1 || return 1
    docker rm -f "${srv}" >/dev/null || return 1
    if [ "${client_rc}" -ne 0 ]; then
        ci_log "[CI-ERROR-E2E-0009]" "${id}: client workload exited ${client_rc}"
        cat "${out}.client" >&2
        return 1
    fi
    if [ "${srv_flavor}" = "ng" ]; then
        warn="$(_ci_sot_scalar "e2e.modes.${mode}.server_warnings")" || return 2
        case "${warn}" in
            fail) _ci_e2e_check_server_warnings "${out}.server" || return 1 ;;
            notrun) ci_log "[CI-E2E]" "${id}: server warning scan NotRun (e2e.modes.${mode}.server_warnings)" ;;
            *) ci_log "[CI-ERROR-E2E-0016]" "e2e.modes.${mode}.server_warnings=${warn} (fail|notrun)"; return 2 ;;
        esac
    fi
    need="${floor}"
    if [ "${floor}" = "objects" ]; then
        need="$(tail -n 1 "${out}.client" | tr -dc '0-9')" || return 1
        if [ -z "${need}" ] || [ "${need}" -le 0 ]; then
            ci_log "[CI-ERROR-E2E-0010]" "${id}: workload printed no object count"
            cat "${out}.client" >&2
            return 1
        fi
    fi
    n="$(_ci_e2e_count_compile_ok "${out}.server" "${subnet}")" || return 2
    ci_log "[CI-E2E]" "${id}: ${n} COMPILE_OK from the client (need >= ${need})"
    if [ "${n}" -lt "${need}" ]; then
        ci_log "[CI-ERROR-E2E-0005]" "${id}: only ${n} remote compiles; not fully distributed"
        return 1
    fi
}

# What: Every leg x pass of one SOT mode on one network.
# Why: Every leg runs after a failure; any failure fails all.
# From: Issue #479, Issue #264, PR #544
_ci_e2e_mode_run() {
    local mode="$1" workload="$2" extra="$3" floor="$4" net="$5" subnet leg pass rc=0
    local legs=() passes=()
    _ci_mapfile legs _ci_sot_list "e2e.modes.${mode}.legs" || return 2
    _ci_mapfile passes _ci_sot_list "e2e.modes.${mode}.passes" || return 2
    subnet="$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "${net}")" || return 1
    docker volume create --label "${CI_STACK_LABEL}=${net}" "${net}-cache" >/dev/null || return 1
    for leg in "${legs[@]}"; do
        for pass in "${passes[@]}"; do
            _ci_e2e_leg "${mode}" "${leg}" "${pass}" "${workload}" "${extra}" \
                "${floor}" "${net}" "${subnet}" || rc=1
        done
    done
    return "${rc}"
}

# What: Run one SOT e2e mode, retried per its max_attempts.
# Why: Each attempt gets its own stack; last failure is final.
# From: Issue #479, Issue #81, PR #544
_ci_e2e_mode() {
    local mode="$1" workload extra floor attempts rc=0
    workload="$(_ci_sot_scalar "e2e.modes.${mode}.workload")" || return 2
    extra="$(_ci_sot_scalar "e2e.modes.${mode}.extra")" || return 2
    floor="$(_ci_sot_scalar "e2e.modes.${mode}.floor")" || return 2
    attempts="$(_ci_sot_scalar "e2e.modes.${mode}.max_attempts")" || return 2
    _ci_e2e_images || return 1
    _ci_wait_until "${attempts}" 0 _ci_e2e_attempt "${mode}" "${workload}" "${extra}" "${floor}" || rc=$?
    case "${rc}" in
        0) ci_log "[CI-E2E]" "${mode}: PASS" ;;
        1) ci_log "[CI-ERROR-E2E-0006]" "${mode}: failed on all ${attempts} attempt(s)"; return 1 ;;
        *) return "${rc}" ;;
    esac
}

# What: One e2e attempt of a mode on its own fresh stack.
# Why: A retry must never reuse a stack a failure left behind.
# From: Issue #479, Issue #81, PR #544
_ci_e2e_attempt() {
    local mode="$1" net
    shift
    net="$(_ci_run_name "e2e-${mode}-${CI_ATTEMPT}")"
    ci_log "[CI-E2E]" "${mode}: attempt ${CI_ATTEMPT}/${CI_TRIES}"
    _ci_stack_run "${net}" _ci_e2e_mode_run "${mode}" "$@"
}

# What: Run a SOT e2e mode, or the ccache control build.
# Why: Unknown modes fail closed instead of running a default.
# From: Issue #479, PR #544
ci_cmd_e2e() {
    cd "${CI_REPO_ROOT}" || return 1
    local mode="${1:-distributed}" st=0 image
    case "${mode}" in
        control)
            _ci_e2e_images || return 1
            image="$(_ci_sot_scalar e2e.images.ng.tag)" || return 2
            _ci_container_run "${image}" -- \
                bash "${CI_CONTAINER_SH}" workload ccache local /work/workload/control "" || st=$?
            _ci_step_summary _ci_control_build_summary "${st}" || return 1
            return "${st}" ;;
        *)
            if ! _ci_sot_optional "e2e.modes.${mode}.workload" | grep -q .; then
                ci_log "[CI-ERROR-E2E-0013]" "unknown e2e mode=\"${mode}\" (control or an e2e.modes key)"
                return 2
            fi
            _ci_e2e_mode "${mode}" ;;
    esac
}

# What: Build into /out (binaries) and /out-pump (all).
# Why: Vendored popt has the CVE fixes; install wires pump.
# From: Issue #181, Issue #485, PR #504, Issue #479, PR #544
_ci_image_release_build() {
    local pkgs
    pkgs="$(_ci_sot_scalar release.image_build_apt)" || return 2
    _ci_apt_install "${pkgs}" image || return 1
    cd "${CI_REPO_ROOT}" || return 1
    _ci_configure_tree /tmp/configure.log PYTHON=python3 --prefix=/usr/local \
        --enable-Werror --without-system-popt || return 1
    local nj
    nj="$(_ci_nproc)" || return 2
    _ci_make_gated /tmp/make.log -j"${nj}" || return 1
    install -D -t "${CI_RELEASE_OUT}/usr/local/bin" distcc distccd lsdistcc distccmon-text || return 1
    make install DESTDIR="${CI_RELEASE_PUMP_OUT}" || return 1
    mv "${CI_RELEASE_PUMP_OUT}/usr/local/bin/pump" "${CI_RELEASE_PUMP_OUT}/usr/local/bin/distcc-pump" || return 1
}

# What: Runtime packages and the unprivileged distcc user.
# Why: distccd must not run as root in the published images.
# From: Issue #398, PR #487, Issue #479, PR #544
_ci_image_release_runtime() {
    local pkgs
    pkgs="$(_ci_sot_scalar release.image_runtime_apt)" || return 2
    _ci_apt_install "${pkgs}" image || return 1
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin distcc
}

# What: CFL toolchain: SOT apt packages and $SRC/build.sh.
# Why: CFL's compile step runs $SRC/build.sh; ci.sh owns it.
# From: Issue #267, Issue #479, PR #544
_ci_image_cfl_toolchain() {
    local pkgs entry="${SRC:?SRC required}/build.sh"
    pkgs="$(_ci_sot_scalar security.cfl_image_apt)" || return 2
    _ci_apt_install "${pkgs}" image || return 1
    printf '%s\n' '#!/bin/bash -eu' \
        "exec bash \"\${SRC}/${CI_CFL_PROJECT}/.github/scripts/ci.sh\" workload fuzz-build" > "${entry}" || return 1
    chmod 755 "${entry}"
}

# What: Run a check; its output must match /re/ (or not, !re).
# Why: Bug fixtures exit non-zero; their output is proof.
# From: Issue #264, Issue #479, PR #544
_ci_expect_output() {
    local name="$1" regex="$2" want=0 out rc=0 hit=0
    shift 2
    if [ "${regex#!}" != "${regex}" ]; then
        want=1
        regex="${regex#!}"
    fi
    out="$("$@" 2>&1)" || rc=$?
    grep -qE -- "${regex}" <<< "${out}" || hit=$?
    if [ "${hit}" -gt 1 ]; then
        ci_log "[CI-ERROR-SELFTEST-0002]" "${name}: grep failed (rc ${hit}) on /${regex}/"
        return 2
    fi
    if [ "${hit}" -ne "${want}" ]; then
        ci_log "[CI-ERROR-SELFTEST-0001]" "${name}: output vs /${regex}/ wrong (negated=${want}, exit ${rc})"
        printf '%s\n' "${out}" >&2
        return 1
    fi
    ci_log "[CI-SELFTEST]" "${name}: OK (exit ${rc})"
}

# What: Prove each verify-image tool works, not just exists.
# Why: A broken tool fails the build, not its first user.
# From: Issue #264 #275 #398, PR #273 #332 #544
_ci_verify_selftest() {
    local d port pid addr
    d="$(_ci_scratch_c)" || return 1
    cd "${d}" || return 1
    gcc ok.c -o ok_gcc || return 1
    ./ok_gcc || return 1
    clang ok.c -o ok_clang || return 1
    ./ok_clang || return 1
    gcc -g -O0 ok.c -o ok_dbg || return 1
    printf '#include <stdlib.h>\nint main(void) { char *p = malloc(8); p[8] = 1; return 0; }\n' > asan.c || return 1
    gcc -fsanitize=address -g asan.c -o asan || return 1
    _ci_expect_output asan 'AddressSanitizer: heap-buffer-overflow' ./asan || return 1
    printf '#include <limits.h>\nint main(void) { int x = INT_MAX; return x + 1; }\n' > ubsan.c || return 1
    gcc -fsanitize=undefined -g ubsan.c -o ubsan || return 1
    _ci_expect_output ubsan 'runtime error: signed integer overflow' ./ubsan || return 1
    printf '#include <stdlib.h>\nint main(void) { malloc(16); return 0; }\n' > leak.c || return 1
    gcc -g -O0 leak.c -o leak || return 1
    _ci_expect_output valgrind 'definitely lost: 16 bytes' valgrind --leak-check=full ./leak || return 1
    _ci_expect_output objdump 'main>:' objdump -d ok_gcc || return 1
    _ci_expect_output readelf 'ELF Header' readelf -h ok_gcc || return 1
    _ci_expect_output nm ' T main$' nm ok_gcc || return 1
    addr="$(nm ok_dbg | awk '$3 == "main" {print $1}')" || return 1
    _ci_expect_output addr2line '^main$' addr2line -f -e ok_dbg "${addr}" || return 1
    printf '%s\n' '#include <fcntl.h>' '#include <stdio.h>' '#include <libelf.h>' '#include <gelf.h>' \
        'int main(void) { GElf_Ehdr h; Elf *e; int fd = open("ok_gcc", O_RDONLY);' \
        '  if (fd < 0 || elf_version(EV_CURRENT) == EV_NONE) return 1;' \
        '  e = elf_begin(fd, ELF_C_READ, NULL);' \
        '  if (!e || !gelf_getehdr(e, &h)) return 1;' \
        '  printf("libelf_ok e_type=%d\n", h.e_type); return 0; }' > libelf.c || return 1
    gcc libelf.c -lelf -o libelf_check || return 1
    _ci_expect_output libelf 'libelf_ok' ./libelf_check || return 1
    printf 'needle_marker\nhaystack\n' > hay.txt || return 1
    _ci_expect_output ripgrep '^needle_marker$' rg needle_marker hay.txt || return 1
    _ci_expect_output grep '^needle_marker$' grep needle_marker hay.txt || return 1
    ccache --zero-stats >/dev/null || return 1
    ccache gcc -c ok.c -o ok.o || return 1
    ccache gcc -c ok.c -o ok.o || return 1
    _ci_expect_output ccache "${CI_CCACHE_HIT_RE}" ccache --show-stats || return 1
    python3 -u -c 'import socket,time; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(1); print(s.getsockname()[1]); time.sleep(60)' > port.txt &
    pid=$!
    _ci_wait_until 20 0.5 test -s port.txt || return 1
    port="$(head -n 1 port.txt)" || return 1
    _ci_expect_output ss ":${port} " ss -tln || return 1
    kill "${pid}" || return 1
    wait "${pid}" || [ "$?" -eq 143 ] || return 1
    exec 9< /etc/hostname
    _ci_expect_output lsof 'hostname' lsof -p "$$" || return 1
    exec 9<&-
    _ci_expect_output dig '^[0-9]+\.' dig +short deb.debian.org || return 1
    _ci_expect_output nslookup 'Address' nslookup deb.debian.org || return 1
    _ci_verify_selftest_ssh "${d}" || return 1
    printf '{"ok": true}\n' > doc.json || return 1
    _ci_expect_output jq '^true$' jq -e .ok doc.json || return 1
    printf '#!/bin/sh\nx="a b"\necho %sx\n' "\$" > sc.sh || return 1
    _ci_expect_output shellcheck 'SC2086' shellcheck sc.sh || return 1
    mkdir -p al/.github/workflows || return 1
    printf 'on: push\njobs:\n  test:\n    steps:\n      - run: echo hi\n' > al/.github/workflows/broken.yml || return 1
    _ci_expect_output actionlint 'runs-on' actionlint al/.github/workflows/broken.yml || return 1
    cd / || return 1
    rm -rf "${d}"
}

# What: A real sshd and ssh client round trip on loopback.
# Why: SSHMode_Case needs both or it is NOTRUN-skipped.
# From: Issue #275, Issue #440, PR #443
_ci_verify_selftest_ssh() {
    local d="$1"
    ssh-keygen -q -t ed25519 -f "${d}/host_key" -N '' || return 1
    ssh-keygen -q -t ed25519 -f "${d}/client_key" -N '' || return 1
    cp "${d}/client_key.pub" "${d}/authorized_keys" || return 1
    printf '%s\n' 'Port 2222' 'ListenAddress 127.0.0.1' "HostKey ${d}/host_key" \
        "AuthorizedKeysFile ${d}/authorized_keys" "PidFile ${d}/sshd.pid" 'UsePAM no' \
        'StrictModes no' 'PasswordAuthentication no' > "${d}/sshd_config" || return 1
    mkdir -p /run/sshd || return 1
    /usr/sbin/sshd -f "${d}/sshd_config" -E "${d}/sshd.log" || return 1
    _ci_expect_output ssh '^ssh_marker$' ssh -p 2222 -i "${d}/client_key" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
        -o ConnectionAttempts=10 -o ConnectTimeout=2 127.0.0.1 'echo ssh_marker' \
        || { cat "${d}/sshd.log" >&2; return 1; }
    kill "$(cat "${d}/sshd.pid")"
}

# What: gdb, strace, ltrace and py-bt really trace a child.
# Why: Build RUNs lack CAP_SYS_PTRACE; only a run proves it.
# From: Issue #285, PR #528, PR #544
_ci_workload_ptrace() {
    local d
    d="$(_ci_scratch_c)" || return 1
    cd "${d}" || return 1
    gcc -g -O0 ok.c -o ok_gcc || return 1
    _ci_expect_output gdb 'Breakpoint 1' \
        gdb -q -batch -ex 'break main' -ex run -ex continue ./ok_gcc || return 1
    # What: gdb must disable ASLR under the narrow profile.
    # Why: The breakpoint still hits when personality() is denied.
    # From: Issue #285
    _ci_expect_output gdb-aslr '!Error disabling address space randomization' \
        gdb -q -batch -ex 'break main' -ex run -ex continue ./ok_gcc || return 1
    _ci_expect_output strace '\+\+\+ exited with 0 \+\+\+' strace -f -e trace=execve ./ok_gcc || return 1
    printf '#include <stdlib.h>\nint main(void) { free(malloc(1)); return 0; }\n' > lt.c || return 1
    gcc -g -O0 lt.c -o lt || return 1
    _ci_expect_output ltrace 'malloc' ltrace -e 'malloc+free' ./lt || return 1
    # What: gdb runs python3-dbg itself, then py-bt.
    # Why: Yama ptrace_scope=1 forbids attaching to a sibling.
    # From: Issue #285
    printf 'import time\ndef target_function():\n    time.sleep(5)\ntarget_function()\n' > py.py || return 1
    _ci_expect_output py-bt 'target_function' gdb -q -batch -ex 'break time_sleep' \
        -ex run -ex 'py-bt' --args python3-dbg py.py || return 1
    cd / || return 1
    rm -rf "${d}"
}

# What: Build, and for check also test, a copy of the tree.
# Why: The mount stays read-only; the build owner is reused.
# From: Issue #285, Issue #286, Issue #479, PR #544
_ci_workload_checkout() {
    local pass="${1:-}" dir="${2:-}"
    case "${pass}" in
        build|check) ;;
        *) ci_log "[CI-ERROR-WORKLOAD-0007]" "checkout pass=${pass} (build|check)"; return 2 ;;
    esac
    _ci_tree_copy "${dir}" || return 1
    bash "${dir}/src/.github/scripts/ci.sh" build default || return 1
    if [ "${pass}" = "check" ]; then
        CI_TEST_UNPRIVILEGED=true bash "${dir}/src/.github/scripts/ci.sh" test default || return 1
    fi
    ccache --show-stats
}

# What: SOT packages, the tool self-test, the verify user.
# Why: The image builds what CI builds; tools must work.
# From: Issue #264, Issue #286, Issue #479, PR #544
_ci_image_verify() {
    local pkgs groups group
    pkgs="$(_ci_sot_scalar build_matrix.variants.default.apt)" || return 2
    groups="$(_ci_sot_children verify.apt)" || return 2
    for group in ${groups}; do
        pkgs="${pkgs} $(_ci_sot_scalar "verify.apt.${group}")" || return 2
    done
    # What: Add the engine's bats self-test packages.
    # Why: Local verification runs ci.bats in this image only.
    # From: Issue #479, PR #544
    pkgs="${pkgs} $(_ci_sot_scalar ci_engine.selftest_apt)" || return 2
    _ci_apt_install "${pkgs}" image || return 1
    _ci_install_tool external_versions.actionlint /usr/local/bin/actionlint || return 1
    _ci_verify_selftest || return 1
    useradd --create-home --shell /bin/bash verify
}

# What: e2e image: SOT apt, e2e user; ng installs the tree.
# Why: native keeps Debian's distcc; ng is under test.
# From: Issue #264, Issue #479, PR #544
_ci_image_e2e() {
    local flavor="$1" pkgs
    pkgs="$(_ci_sot_scalar e2e.image_apt)" || return 2
    if [ "${flavor}" = "native" ]; then
        pkgs="${pkgs} $(_ci_sot_scalar e2e.native_apt)" || return 2
    fi
    _ci_apt_install "${pkgs}" image || return 1
    useradd --create-home --shell /bin/bash e2e || return 1
    mkdir -p /work/workload /work/cache || return 1
    chown -R e2e:e2e /work || return 1
    if [ "${flavor}" = "ng" ]; then
        cd "${CI_REPO_ROOT}" || return 1
        _ci_configure_tree /tmp/configure.log PYTHON=python3 --prefix=/usr/local || return 1
        local nj
        nj="$(_ci_nproc)" || return 2
        _ci_make_gated /tmp/make.log -j"${nj}" || return 1
        make install || return 1
        rm -f /tmp/configure.log /tmp/make.log || return 1
    fi
    update-distcc-symlinks
}

# What: Image build step run by a Dockerfile's single RUN.
# Why: Packages come from the SOT; the tree is only mounted.
# From: Issue #264, Issue #479, PR #544
ci_cmd_image() {
    case "${1:-}" in
        release-build) _ci_image_release_build ;;
        release-runtime) _ci_image_release_runtime ;;
        cfl-toolchain) _ci_image_cfl_toolchain ;;
        verify) _ci_image_verify ;;
        e2e-ng) _ci_image_e2e ng ;;
        e2e-native) _ci_image_e2e native ;;
        *) ci_log "[CI-ERROR-IMAGE-0001]" "unknown image target=\"${1:-}\" (release-build|release-runtime|cfl-toolchain|verify|e2e-ng|e2e-native)"; return 2 ;;
    esac
}

# What: Print tarball, signature, key URL of pinned Samba.
# Why: The SOT owns the layout; Samba signs the plain .tar.
# From: Issue #264, Issue #285, Issue #479, PR #544
_ci_workload_samba_release() {
    local ver key
    ver="$(_ci_sot_scalar external_versions.samba.version)" || return 2
    for key in url sig_url key_url; do
        _ci_tool_url external_versions.samba "${ver}" "${key}" || return 2
    done
}

# What: Fetch Samba, check sha256 and GPG, extract fresh.
# Why: VER-SOURCE: a bad signature is a hard stop.
# From: Issue #264, Issue #285, Issue #479, PR #544
_ci_workload_samba_fetch() {
    local dest="$1" cache
    local rel=()
    _ci_mapfile rel _ci_workload_samba_release || return 2
    [ "${#rel[@]}" -eq 3 ] || return 2
    cache="${CI_WORKLOAD_CACHE:-/tmp/ci-workload-cache}/samba"
    if [ ! -f "${cache}/.verified" ]; then
        _ci_fresh_dir "${cache}" || return 1
        mkdir -m 700 "${cache}/gnupg" || return 1
        _ci_download "${rel[0]}" "${cache}/src.tar.gz" || return 1
        _ci_sha256_ok external_versions.samba "${cache}/src.tar.gz" || return 1
        _ci_download "${rel[1]}" "${cache}/sig" || return 1
        _ci_download "${rel[2]}" "${cache}/key" || return 1
        gunzip -c "${cache}/src.tar.gz" > "${cache}/src.tar" || return 1
        GNUPGHOME="${cache}/gnupg" gpg --batch --import "${cache}/key" || return 1
        if ! GNUPGHOME="${cache}/gnupg" gpg --batch --verify "${cache}/sig" "${cache}/src.tar"; then
            ci_log "[CI-ERROR-WORKLOAD-0002]" "$(basename "${rel[0]}"): signature does not verify"
            return 1
        fi
        touch "${cache}/.verified" || return 1
    fi
    _ci_fresh_dir "${dest}" || return 1
    tar -xf "${cache}/src.tar" -C "${dest}" --strip-components=1
}

# What: Run a build under pump with this node's pump flavor.
# Why: distcc-ng pump appends ,cpp,lzo; Debian's does not.
# From: Issue #87, Issue #264, PR #544
_ci_workload_pump() {
    local rc=0
    if command -v pump >/dev/null; then
        pump "$@"
        return
    fi
    export DISTCC_HOSTS="${DISTCC_HOSTS},cpp,lzo"
    eval "$(timeout 30 distcc-pump --startup)" || return 1
    "$@" || rc=$?
    # What: A hung distcc-pump --shutdown only logs, never fails.
    # Why: Upstream handshake can hang; teardown kills the server.
    # From: Issue #264
    timeout 15 distcc-pump --shutdown \
        || ci_log "[CI-WORKLOAD]" "distcc-pump --shutdown did not finish (upstream hang)"
    return "${rc}"
}

# What: Self-compile the checkout via distcc; count .o.
# Why: Configure stays local; only make's compiles go remote.
# From: Issue #87, Issue #479, PR #544
_ci_workload_self_compile() {
    local pass="${1:-}" dir="${2:-}" probe
    local make_cc=(CC="distcc gcc" CXX="distcc g++") runner=()
    case "${pass}" in
        plain) ;;
        pump) runner=(_ci_workload_pump) ;;
        *) ci_log "[CI-ERROR-WORKLOAD-0005]" "self-compile pass=${pass} (plain|pump)"; return 2 ;;
    esac
    _ci_tree_copy "${dir}" || return 1
    cd "${dir}/src" || return 1
    _ci_configure_tree "${dir}/configure.log" PYTHON=python3 || return 1
    local nj
    nj="$(_ci_nproc)" || return 2
    "${runner[@]}" make -j"${nj}" "${make_cc[@]}" 2>&1 | tee "${dir}/make.log" >&2 || return 1
    _ci_warning_gate "${dir}/make.log" "self-compile ${pass} make" || return 1
    test -x ./distcc && test -x ./distccd || return 1
    if [ "${pass}" = "plain" ]; then
        probe="$(mktemp -d)" || return 1
        printf 'int distcc_e2e_probe(int x) { return (x * 2) + 1; }\n' > "${probe}/probe.c" || return 1
        gcc -O2 -c "${probe}/probe.c" -o "${probe}/local.o" || return 1
        env -u DISTCC_VERBOSE distcc gcc -O2 -c "${probe}/probe.c" -o "${probe}/dist.o" 2> "${probe}/err" || return 1
        if [ -s "${probe}/err" ] || ! cmp "${probe}/local.o" "${probe}/dist.o"; then
            ci_log "[CI-ERROR-WORKLOAD-0003]" "probe: remote object differs or distcc warned"
            cat "${probe}/err" >&2
            return 1
        fi
        # What: ,cpp,lzo host under plain distcc compiles remotely.
        # Why: One host-list form must serve plain and pump (#87).
        # From: Issue #87
        DISTCC_HOSTS="${DISTCC_HOSTS},cpp,lzo" distcc gcc -O2 -c "${probe}/probe.c" -o "${probe}/c.o" || return 1
    fi
    find . -name '*.o' | wc -l
}

# What: Build pinned ccache via distcc, or local control.
# Why: Same source/flags; only the distcc launcher may differ.
# From: Issue #81, Issue #263, Issue #479, PR #544
_ci_workload_ccache() {
    local pass="${1:-}" dir="${2:-}" tag src
    local launcher=()
    tag="$(_ci_sot_scalar external_versions.ccache_heartbeat.version)" || return 2
    case "${pass}" in
        plain) launcher=(-DCMAKE_C_COMPILER_LAUNCHER=distcc -DCMAKE_CXX_COMPILER_LAUNCHER=distcc) ;;
        local) ;;
        *) ci_log "[CI-ERROR-WORKLOAD-0004]" "ccache pass=${pass} (plain|local)"; return 2 ;;
    esac
    _ci_fresh_dir "${dir}" || return 1
    src="$(_ci_sot_scalar external_versions.ccache_heartbeat.source)" || return 2
    git clone --depth 1 --branch "${tag}" "https://github.com/${src}" "${dir}/src" >&2 || return 1
    # What: Two named -Wno-error flags, not -Werror off.
    # Why: GCC 12 false positives; other warnings still fail.
    # From: Issue #263
    cmake -S "${dir}/src" -B "${dir}/build" -DCMAKE_BUILD_TYPE=Release "${launcher[@]}" \
        -DCMAKE_CXX_FLAGS="-Wno-error=maybe-uninitialized -Wno-error=restrict" \
        -DENABLE_TESTING=OFF >&2 || return 1
    local nj
    nj="$(_ci_nproc)" || return 2
    cmake --build "${dir}/build" -j"${nj}" >&2 || return 1
    "${dir}/build/ccache" --version >&2 || return 1
    find "${dir}/build" -name '*.o' | wc -l
}

# What: Configure, build verified Samba; print .o count.
# Why: The count is the floor server COMPILE_OK must meet.
# From: Issue #264, Issue #285, Issue #479, PR #544
_ci_workload_samba() {
    local pass="${1:-}" dir="${2:-}" targets="${3:-}"
    local build=()
    case "${pass}" in
        plain|pump|configure) ;;
        *) ci_log "[CI-ERROR-WORKLOAD-0008]" "samba pass=${pass} (plain|pump|configure)"; return 2 ;;
    esac
    : "${dir:?workdir required}"
    _ci_workload_samba_fetch "${dir}" >&2 || return 1
    cd "${dir}" || return 1
    if [ "${pass}" = "configure" ]; then
        ./configure >&2 || return 1
        ci_log "[CI-WORKLOAD]" "samba configure OK"
        return 0
    fi
    # What: Configure with CC=distcc but fallback allowed.
    # Why: waf keeps its configure CC; probes may fail by design.
    # From: Issue #264
    env -u DISTCC_FALLBACK CC="distcc gcc" ./configure >&2 || return 1
    export PYTHONHASHSEED=1
    local nj
    nj="$(_ci_nproc)" || return 2
    build=(./buildtools/bin/waf build -j"${nj}")
    [ -z "${targets}" ] || build+=(--targets="${targets}")
    if [ "${pass}" = "pump" ]; then
        _ci_workload_pump "${build[@]}" >&2 || return 1
    else
        "${build[@]}" >&2 || return 1
    fi
    find . -name '*.o' | wc -l
}

# What: Build every test/fuzz target in the CFL builder image.
# Why: CFL runs $SRC/build.sh; ci.sh owns the logic.
# From: Issue #267, Issue #479, PR #544
_ci_workload_fuzz_build() {
    : "${CC:?CC required}" "${CXX:?CXX required}" "${OUT:?OUT required}"
    : "${LIB_FUZZING_ENGINE:?LIB_FUZZING_ENGINE required}"
    local skip rename raw f base prefix sysconfdir datarootdir t lib deps=()
    local cflags=() cxxflags=() engine=() libs=() defs=() extra=() objs=()
    read -ra cflags <<< "${CFLAGS:-}"
    read -ra cxxflags <<< "${CXXFLAGS:-}"
    read -ra engine <<< "${LIB_FUZZING_ENGINE}"
    raw="$(_ci_sot_list security.cfl_fuzz.exclude_main)" || return 2
    skip="$(tr '\n' ' ' <<< "${raw}")" || return 1
    skip=" ${skip}"
    raw="$(_ci_sot_list security.cfl_fuzz.rename_main)" || return 2
    rename="$(tr '\n' ' ' <<< "${raw}")" || return 1
    rename=" ${rename}"
    cd "${CI_REPO_ROOT}" || return 1
    # What: --with-auth builds auth_common.c's GSSAPI symbols.
    # Why: The link takes every src/*.c, auth_common.c included.
    # From: Issue #267
    _ci_run_configure /tmp/fuzz-configure.log PYTHON=python3 --disable-pump-mode --with-auth || return 1
    # What: Rebuild Makefile.in's DIR_DEFS for direct compiles.
    # Why: They are Makefile-only; config.h never carries them.
    # From: Issue #267
    prefix="$(_ci_makefile_var prefix)" || return 1
    sysconfdir="$(_ci_makefile_var sysconfdir)" || return 1
    datarootdir="$(_ci_makefile_var datarootdir)" || return 1
    sysconfdir="${sysconfdir//\$\{prefix\}/${prefix}}"
    sysconfdir="${sysconfdir//\$(prefix)/${prefix}}"
    datarootdir="${datarootdir//\$\{prefix\}/${prefix}}"
    datarootdir="${datarootdir//\$(prefix)/${prefix}}"
    defs=("-DLIBDIR=\"${prefix}/lib\"" "-DSYSCONFDIR=\"${sysconfdir}\"" "-DICONDIR=\"${datarootdir}/pixmaps\"")
    for f in src/*.c lzo/minilzo.c; do
        base="$(basename "${f}" .c)" || return 1
        case "${skip}" in *" ${base} "*) continue ;; esac
        extra=()
        case "${rename}" in *" ${base} "*) extra=("-Dmain=distccng_disabled_main_${base}") ;; esac
        "${CC}" "${cflags[@]}" -Isrc -Ilzo -DHAVE_CONFIG_H "${defs[@]}" "${extra[@]}" \
            -c "${f}" -o "${OUT}/${base}.o" || return 1
        objs+=("${OUT}/${base}.o")
    done
    raw="$(_ci_makefile_var LIBS)" || return 1
    read -ra libs <<< "${raw}"
    for t in test/fuzz/*.c; do
        # What: -x c compiles the target as C; -x none ends it.
        # Why: CFL links with $CXX; the .o files must not parse as C.
        # From: Issue #267
        "${CXX}" "${cxxflags[@]}" -Isrc -Ilzo -DHAVE_CONFIG_H -x c "${t}" -x none "${objs[@]}" \
            -o "${OUT}/$(basename "${t}" .c)" -Wl,-rpath,"\$ORIGIN" "${engine[@]}" "${libs[@]}" || return 1
        # What: Ship only libavahi/libpopt next to the target.
        # Why: The run image lacks them; a copied glibc crashes it.
        # From: Issue #267
        raw="$(ldd "${OUT}/$(basename "${t}" .c)")" || return 1
        _ci_mapfile deps awk "/=>/ {print \$3} !/=>/ {if (\$1 ~ /^\//) print \$1}" <<< "${raw}" || return 1
        for lib in "${deps[@]}"; do
            case "$(basename "${lib}")" in
                libavahi-*|libpopt.*) cp -L "${lib}" "${OUT}/" || return 1 ;;
            esac
        done
    done
}

# What: Print one variable of the configured ./Makefile.
# Why: Fuzz compiles bypass make but need its DIR_DEFS/LIBS.
# From: Issue #267, Issue #479, PR #544
_ci_makefile_var() {
    if ! grep -q "^$1 = " Makefile; then
        ci_log "[CI-ERROR-WORKLOAD-0009]" "configured Makefile has no $1"
        return 1
    fi
    sed -n "s/^$1 = //p" Makefile
}

# What: Dispatch workload: <name> <pass> <dir> [extra].
# Why: One owner for all work inside a test container.
# From: Issue #479, PR #544
ci_cmd_workload() {
    local name="${1:-}"
    [ "$#" -eq 0 ] || shift
    case "${name}" in
        self-compile) _ci_workload_self_compile "$@" ;;
        ccache) _ci_workload_ccache "$@" ;;
        samba) _ci_workload_samba "$@" ;;
        checkout) _ci_workload_checkout "$@" ;;
        ptrace) _ci_workload_ptrace ;;
        fuzz-build) _ci_workload_fuzz_build ;;
        *) ci_log "[CI-ERROR-WORKLOAD-0006]" "unknown workload=\"${name}\" (self-compile|ccache|samba|checkout|ptrace|fuzz-build)"; return 2 ;;
    esac
}

# What: Build the source tarball and packages (make deb).
# Why: A missing packaging tool fails before any build.
# From: Issue #479
ci_cmd_package() {
    local py tool log="${RUNNER_TEMP:-/tmp}/ci-package.log"
    cd "${CI_REPO_ROOT}" || return 1
    py="$(_ci_python)" || return 1
    for tool in "${py}" pkg-config eu-strip rpmbuild alien fakeroot; do
        command -v "${tool}" >/dev/null 2>&1 \
            || { ci_log "[CI-ERROR-PACKAGE-0001]" "missing tool: ${tool}"; return 1; }
    done
    _ci_configure_tree "${log}.configure" PYTHON="${py}" --enable-Werror || return 1
    # What: Run make deb without -j, so no jobserver exists.
    # Why: rpmbuild's inner make cannot reach it and warns.
    # From: Issue #479, PR #544
    _ci_make_gated "${log}" deb
}

# What: SBOM of the one source tarball the SOT assets name.
# Why: OSPS-QA-02.02; scans the exact asset a release ships.
# From: Issue #479, PR #544
_ci_package_sbom() {
    local out="${1:?output file required}" asset
    local tars=() assets=()
    _ci_mapfile assets _ci_release_asset_hits || return
    cd "${CI_REPO_ROOT}" || return 1
    for asset in ${assets[@]+"${assets[@]}"}; do
        case "${asset}" in *.tar.gz) tars+=("${asset}") ;; esac
    done
    case "${#tars[@]}" in
        1) ci_cmd_sbom "${tars[0]}" "${out}" ;;
        0) ci_log "[CI-ERROR-PACKAGE-0002]" "no release.assets *.tar.gz file found"; return 1 ;;
        *) ci_log "[CI-ERROR-PACKAGE-0003]" "${#tars[@]} source tarballs: ${tars[*]}"; return 1 ;;
    esac
}

# What: Fail unless a release tag matches configure.ac.
# Why: POL-RELEASE-05/07; require_new=false once pushed.
# From: Issue #479, PR #544
_ci_check_release_version() {
    local tag="${1:?tag required}" require_new="${2:-true}" version configured existing
    version="${tag#v}"
    cd "${CI_REPO_ROOT}" || return 1
    [ -f configure.ac ] || { ci_log "[CI-ERROR-RELEASE-0001]" "no configure.ac"; return 1; }
    configured="$(sed -n 's/^AC_INIT(\[distcc-ng\],\[\([^]]*\)\].*/\1/p' configure.ac)" || return 1
    [ -n "${configured}" ] || { ci_log "[CI-ERROR-RELEASE-0002]" "cannot parse AC_INIT version"; return 1; }
    if [ "${configured}" != "${version}" ]; then
        ci_log "[CI-ERROR-RELEASE-0003]" "configure.ac=${configured} != tag ${tag}"
        return 1
    fi
    if [ "${require_new}" = "true" ]; then
        existing="$(git tag -l -- "${tag}")" || return 1
        if [ -n "${existing}" ]; then
            ci_log "[CI-ERROR-RELEASE-0004]" "tag ${tag} already exists"
            return 1
        fi
    fi
    ci_log "[CI-RELEASE]" "OK: ${tag} matches configure.ac"
}

# What: Build and push the non-release-matrix images.
# Why: Each variant names only its SOT spec, tags and push.
# From: Issue #359, Issue #479, PR #544
ci_cmd_container() {
    local first="${1:?variant or build/push required}"
    if [ "${first}" = "build" ] || [ "${first}" = "push" ]; then
        _ci_container_release "$@"
        return
    fi
    local short base image
    case "${first}" in
        nightly)
            image="$(_ci_release_image distcc-ng-nightly latest)" || return 2
            _ci_image_build release.images.distcc-ng-nightly nightly --tag "${image}" || return 1
            _ci_registry_push "${image}" || return 1
            _ci_output image "${image}" ;;
        verify-image)
            short="$(_ci_built_sha --short)" || return 1
            _ci_image_build release.images.distcc-ng-buildtools "${short}" ;;
        buildtools)
            short="$(_ci_built_sha --short)" || return 1
            base="$(_ci_sot_scalar release.images.distcc-ng-buildtools.ref)" || return 2
            base="${base%:*}"
            _ci_image_build release.images.distcc-ng-buildtools "${short}" \
                --tag "${base}:latest" --tag "${base}:${short}" || return 1
            _ci_registry_push "${base}:latest" "${base}:${short}" ;;
        *) ci_log "[CI-ERROR-CONTAINER-0001]" "unimplemented container variant=\"${first}\""; return 2 ;;
    esac
}

# What: Build (no push) or push a release plain/pump image.
# Why: Trivy scan needs the built, unpushed image.
# From: Issue #479, PR #544
_ci_container_release() {
    local action="$1" variant platform version image pkg
    case "${action}" in
        build)
            variant="${2:?variant required}"
            platform="${3:?platform required (amd64|arm64)}"
            version="${4:?version required}"
            pkg="$(_ci_release_pkg "${variant}")" || return 2
            _ci_sot_scalar "release.container.platforms.${platform}.runner" >/dev/null || return 2
            image="$(_ci_release_image "${pkg}" "${version}" "${platform}")" || return 2
            _ci_image_build "release.images.${pkg}" "${version}" \
                --platform "linux/${platform}" --tag "${image}" || return 1
            _ci_output image "${image}" ;;
        push)
            _ci_registry_push "${2:?image tag required}" ;;
        *) ci_log "[CI-ERROR-CONTAINER-0004]" "release action=${action} (build|push)"; return 2 ;;
    esac
}

# What: Commit as the github-actions bot in this checkout.
# Why: One identity owner; GitHub's bot email carries its id.
# From: Issue #479, PR #544
_ci_git_identity() {
    git config user.name "github-actions[bot]" || return 1
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
}

# What: Wire GH_TOKEN into git's own credential helper.
# Why: ci_cmd_checkout's remote has no credentials at all.
# From: Issue #479, PR #544
_ci_git_auth_setup() {
    : "${GH_TOKEN:?GH_TOKEN required}"
    gh auth setup-git
}

# What: Print every file a SOT release.assets glob matches.
# Why: One glob owner for publish and the source SBOM.
# From: Issue #362, Issue #479, PR #544
_ci_release_asset_hits() {
    local pats pat hits
    pats="$(_ci_sot_list release.assets)" || return 2
    cd "${CI_REPO_ROOT}" || return 1
    while IFS= read -r pat; do
        # What: compgen rc 1 means no match; only a match prints.
        # Why: An unmatched glob is a normal answer, not an error.
        # From: Issue #479, PR #544
        if hits="$(compgen -G "${pat}")"; then
            printf '%s\n' "${hits}"
        fi
    done <<< "${pats}"
}

# What: Print the built release assets the SOT globs match.
# Why: Nightly and release ship one set; none found fails.
# From: Issue #362, Issue #479, PR #544
_ci_release_assets() {
    local hits
    hits="$(_ci_release_asset_hits)" || return
    if [ -z "${hits}" ]; then
        ci_log "[CI-ERROR-PUBLISH-0007]" "no release asset matches release.assets"
        return 1
    fi
    printf '%s\n' "${hits}"
}

# What: Force-move the nightly tag; republish its prerelease.
# Why: Nightly has one rolling tag; a v* tag is refused.
# From: Issue #479
_ci_publish_nightly() {
    local tag ref image notes rc=0
    tag="$(_ci_sot_scalar release.nightly_tag)" || return 2
    case "${tag}" in
        v*) ci_log "[CI-ERROR-PUBLISH-0002]" "refusing to force-move a v* tag: ${tag}"; return 1 ;;
    esac
    image="$(_ci_release_image distcc-ng-nightly latest)" || return 2
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    cd "${CI_REPO_ROOT}" || return 1
    ref="$(_ci_built_sha)" || return 1
    _ci_release_assets > /dev/null || return 1
    _ci_git_identity || return 1
    _ci_mutate git tag -f "${tag}" || return 1
    _ci_git_auth_setup || return 1
    _ci_mutate git push -f origin "refs/tags/${tag}" || return 1
    notes="$(printf '%s\n\n%s\n\n%s' "Automated nightly build of current_dev (${ref})." \
        "Unstable nightly channel -- NOT a real release; overwritten each run." \
        "Container image: ${image}")"
    _ci_gh_release_exists "${tag}" || rc=$?
    case "${rc}" in
        0) _ci_mutate gh release delete "${tag}" --repo "${GITHUB_REPOSITORY}" --yes || return 1 ;;
        1) ;;
        *) return 1 ;;
    esac
    _ci_gh_release_create "${tag}" "${ref}" "distcc-ng nightly" "${notes}" --prerelease --latest=false
}

# What: Succeed if release $1 exists; rc 1 if it does not.
# Why: The list holds drafts; an API error is never a "no".
# From: Issue #479, PR #544
_ci_gh_release_exists() {
    local tags rc=0
    if ! [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; then
        ci_log "[CI-ERROR-PUBLISH-0011]" "release tag \"$1\" is not [A-Za-z0-9._-]+"
        return 2
    fi
    tags="$(gh api --paginate "repos/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}/releases" \
        --jq '.[].tag_name' 2>&1)" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        ci_error "[CI-ERROR-PUBLISH-0010]" "cannot list releases to look up $1" "${tags}"
        return 2
    fi
    grep -qxF -- "$1" <<< "${tags}"
}

# What: Create GitHub release $1 at $2 with the SOT assets.
# Why: Nightly and release ship one asset set, one way.
# From: Issue #362, Issue #479, PR #544
_ci_gh_release_create() {
    local tag="$1" target="$2" title="$3" notes_text="$4" notes
    shift 4
    local assets=()
    _ci_mapfile assets _ci_release_assets || return 1
    notes="$(mktemp)" || return 1
    printf '%s\n' "${notes_text}" > "${notes}" || return 1
    _ci_mutate gh release create "${tag}" "${assets[@]}" --repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}" \
        --target "${target}" --title "${title}" --notes-file "${notes}" "$@"
}

# What: Create the multi-arch manifest from pushed tags.
# Why: imagetools reads the registry; no artifact handoff.
# From: Issue #479, PR #544
_ci_publish_manifest() {
    local variant="${1:?variant required}" pkg base out p platforms opt ctx=() tags=()
    _ci_mapfile ctx _ci_release_context || return 2
    [ "${#ctx[@]}" -eq 4 ] || return 2
    pkg="$(_ci_release_pkg "${variant}")" || return 2
    base="$(_ci_release_image "${pkg}" "${ctx[0]}")" || return 2
    platforms="$(_ci_sot_children release.container.platforms)" || return 2
    _ci_registry_login || return 1
    # What: Take each platform; only an optional one may lack.
    # Why: An optional platform's build may fail on its own.
    # From: Issue #479, PR #544
    for p in ${platforms}; do
        opt="$(_ci_sot_scalar "release.container.platforms.${p}.optional")" || return 2
        if out="$(docker buildx imagetools inspect "${base}-${p}" 2>&1)"; then
            tags+=("${base}-${p}")
        elif [ "${opt}" = "true" ] && grep -qi 'not found' <<< "${out}"; then
            ci_log "[CI-PUBLISH]" "no ${p} image; ${variant} manifest goes without it"
        else
            ci_error "[CI-ERROR-PUBLISH-0006]" "cannot inspect ${base}-${p}" "${out}"
            return 1
        fi
    done
    docker buildx imagetools create --tag "${base}" "${tags[@]}" || return 1
    # What: Only a real tag push moves the :latest manifest.
    # Why: A dispatch dry run must never pose as the newest.
    # From: Issue #479, PR #544
    if [ "${ctx[3]}" = "true" ]; then
        docker buildx imagetools create --tag "${base%:*}:latest" "${tags[@]}" || return 1
    fi
    _ci_output image "${base}"
}

# What: Cut the GitHub release of a tag with built assets.
# Why: The version check gates it before any asset upload.
# From: Issue #479
_ci_publish_github_release() {
    local tag="${1:?tag required}"
    _ci_check_release_version "${tag}" || return 1
    _ci_gh_release_create "${tag}" "${GITHUB_SHA:?GITHUB_SHA required}" "distcc-ng ${tag}" \
        "distcc-ng ${tag}" --latest
}

# What: Insert release notes into CHANGELOG.md on current_dev.
# Why: <tag> <notes-file> is the checklist's manual retry.
# From: Issue #479, PR #544
_ci_publish_changelog_update() {
    local body
    if [ "$#" -eq 0 ]; then
        _ci_publish_changelog_event
        return
    fi
    body="$(cat "${2:?notes file required}")" || return 2
    _ci_changelog_insert "$1" "${body}"
}

# What: Print {tag, body} the event carries; rc 3 means skip.
# Why: A pre-release or a dispatch without notes adds nothing.
# From: Issue #479, PR #544
_ci_changelog_from_event() {
    local pre tag body ctx=()
    case "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME required}" in
        release)
            pre="$(_ci_event_value .release.prerelease)" || return 2
            case "${pre}" in
                true) ci_log "[CI-PUBLISH-CHANGELOG]" "skipped: pre-release"; return 3 ;;
                false) ;;
                *) ci_log "[CI-ERROR-PUBLISH-0003]" "release.prerelease is \"${pre}\", not a boolean"; return 2 ;;
            esac
            tag="$(_ci_event_value .release.tag_name)" || return 2
            body="$(_ci_event_value '.release.body // ""')" || return 2 ;;
        workflow_dispatch)
            body="$(_ci_event_value '.inputs.release_notes // ""')" || return 2
            if [ -z "${body}" ]; then
                ci_log "[CI-PUBLISH-CHANGELOG]" "skipped: no release_notes on this dispatch"
                return 3
            fi
            _ci_mapfile ctx _ci_release_context || return 2
            [ "${#ctx[@]}" -eq 4 ] || return 2
            tag="${ctx[0]}" ;;
        *) ci_log "[CI-ERROR-PUBLISH-0009]" "event ${GITHUB_EVENT_NAME} carries no release notes"; return 2 ;;
    esac
    jq -n --arg tag "${tag}" --arg body "${body}" '{tag: $tag, body: $body}'
}

# What: Write insert=true unless the event's notes skip.
# Why: The write token step runs only when there is a section.
# From: Issue #479, PR #544
_ci_changelog_plan() {
    local rc=0
    _ci_changelog_from_event >/dev/null || rc=$?
    case "${rc}" in
        0) _ci_output insert true ;;
        3) _ci_output insert false ;;
        *) return "${rc}" ;;
    esac
}

# What: Insert the notes a release or a dispatch carries.
# Why: The plan step already skipped events without notes.
# From: Issue #479, PR #544
_ci_publish_changelog_event() {
    local rc=0 json tag body
    json="$(_ci_changelog_from_event)" || rc=$?
    case "${rc}" in
        0) ;;
        3) return 0 ;;
        *) return "${rc}" ;;
    esac
    tag="$(jq -r .tag <<< "${json}")" || return 2
    body="$(jq -r .body <<< "${json}")" || return 2
    _ci_changelog_insert "${tag}" "${body}"
}

# What: Add a tag's notes as a CHANGELOG.md section; commit.
# Why: An existing section is kept, so a rerun adds nothing.
# From: Issue #479, PR #544
_ci_changelog_insert() {
    local tag="$1" body="$2" version date tmp
    if [ -z "${body}" ]; then
        ci_log "[CI-ERROR-PUBLISH-0008]" "release ${tag} has empty notes"
        return 1
    fi
    version="${tag#v}"
    date="$(date -u +%Y-%m-%d)" || return 1
    cd "${CI_REPO_ROOT}" || return 1
    grep -qF '<!-- insertion marker -->' CHANGELOG.md || {
        ci_log "[CI-ERROR-PUBLISH-0005]" "CHANGELOG.md insertion marker not found"
        return 1
    }
    if grep -qF "## [${version}]" CHANGELOG.md; then
        ci_log "[CI-PUBLISH-CHANGELOG]" "skipped: ${tag} section already present"
        return 0
    fi
    tmp="$(mktemp)" || return 1
    {
        printf '## [%s] - %s\n\n' "${version}" "${date}"
        printf '%s\n' "${body}"
    } > "${tmp}" || return 1
    awk -v insertfile="${tmp}" '
        /<!-- insertion marker -->/ {
            print
            print ""
            while ((getline line < insertfile) > 0) print line
            next
        }
        { print }
    ' CHANGELOG.md > CHANGELOG.md.new || return 1
    mv CHANGELOG.md.new CHANGELOG.md || return 1
    rm -f "${tmp}" || return 1
    _ci_git_identity || return 1
    git add CHANGELOG.md || return 1
    git commit -m "CHANGELOG.md: add ${tag}" || return 1
    _ci_git_auth_setup || return 1
    _ci_mutate git push origin HEAD:current_dev
}

# What: Append a category section if it has any items.
# Why: Shared by every category in the draft release body.
# From: Issue #479
_ci_draft_release_append() {
    local -n out_ref="$1"
    local heading="$2"
    shift 2
    [ "$#" -eq 0 ] && return 0
    out_ref="${out_ref}### ${heading}
$(printf '%s\n' "$@")
"
}

# What: Rebuild the draft release from PR title types.
# Why: AG-GH-014's title type is the one category source.
# From: Issue #479
_ci_publish_draft_release() {
    : "${GH_TOKEN:?GH_TOKEN required}"
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    local since since_date pr_json rows number title category n
    local security=() bug=() enhancement=() documentation=()
    since="$(gh release list --repo "${GITHUB_REPOSITORY}" --exclude-drafts \
        --exclude-pre-releases --json tagName,publishedAt \
        --jq 'sort_by(.publishedAt) | last | .publishedAt // empty')" || return 1
    since_date="${since:-2000-01-01}"
    pr_json="$(gh pr list --repo "${GITHUB_REPOSITORY}" --state merged --base current_dev \
        --search "merged:>=${since_date}" --json number,title --limit 1000)" || return 1
    # What: Fail when the list fills the limit; it may be cut off.
    # Why: A draft missing merged PRs must not pass as complete.
    # From: Issue #479, PR #544
    n="$(jq -er 'length' <<< "${pr_json}")" || return 2
    if [ "${n}" -ge 1000 ]; then
        ci_log "[CI-ERROR-PUBLISH-0012]" "1000+ PRs merged since ${since_date}; the list may be cut"
        return 1
    fi
    rows="$(jq -r '.[] | [.number, .title] | @tsv' <<< "${pr_json}")" || return 2
    while IFS=$'\t' read -r number title; do
        [ -n "${number}" ] || continue
        category="$(_ci_pr_category_label "${title}")"
        case "${category}" in
            security)      security+=("* #${number} | ${title}") ;;
            bug)           bug+=("* #${number} | ${title}") ;;
            enhancement)   enhancement+=("* #${number} | ${title}") ;;
            documentation) documentation+=("* #${number} | ${title}") ;;
        esac
    done <<< "${rows}"

    local body=""
    _ci_draft_release_append body "Security" "${security[@]}"
    _ci_draft_release_append body "Fixed" "${bug[@]}"
    _ci_draft_release_append body "Added" "${enhancement[@]}"
    _ci_draft_release_append body "Documentation" "${documentation[@]}"

    local notes rc=0
    notes="$(mktemp)" || return 1
    printf '%s' "${body}" > "${notes}" || return 1
    # What: Edit the draft if it exists, else create it.
    # Why: A create on an existing draft fails loudly, not twice.
    # From: Issue #479, PR #544
    _ci_gh_release_exists draft-current_dev || rc=$?
    case "${rc}" in
        0) _ci_mutate gh release edit draft-current_dev --repo "${GITHUB_REPOSITORY}" --notes-file "${notes}" || return 1 ;;
        1) _ci_mutate gh release create draft-current_dev --repo "${GITHUB_REPOSITORY}" --draft \
               --title "Next release (draft)" --notes-file "${notes}" \
               --target current_dev || return 1 ;;
        *) return 1 ;;
    esac
}

# What: Publish a release-family artifact set.
# Why: Outward; a real cut or manifest is maintainer-driven.
# From: Issue #479
ci_cmd_publish() {
    local sub="${1:?publish target required}"
    if [ "$#" -gt 0 ]; then shift; fi
    case "${sub}" in
        nightly)        _ci_publish_nightly ;;
        manifest)       _ci_publish_manifest "$@" ;;
        github-release) _ci_publish_github_release "$@" ;;
        changelog)      _ci_publish_changelog_update "$@" ;;
        changelog-plan) _ci_changelog_plan ;;
        draft-release)  _ci_publish_draft_release ;;
        *) ci_log "[CI-ERROR-PUBLISH-0001]" "unimplemented publish target=\"${sub}\""; return 2 ;;
    esac
}

# What: Release subcommands: version-check and packages.
# Why: Both run before a tag and change nothing outward.
# From: Issue #479
ci_cmd_release() {
    local sub="${1:-}"
    if [ "$#" -gt 0 ]; then shift; fi
    case "${sub}" in
        version-check) _ci_release_version_check "$@" ;;
        packages) _ci_release_offer_packages ;;
        *) ci_log "[CI-ERROR-RELEASE-0005]" "unknown release subcommand=\"${sub}\" (version-check|packages)"; return 2 ;;
    esac
}

# What: Offer the built release assets as a workflow artifact.
# Why: The checklist checks a CI package before the tag.
# From: Issue #479, PR #544
_ci_release_offer_packages() {
    local ctx=() rel=() files=() f
    _ci_mapfile ctx _ci_release_context || return 2
    [ "${#ctx[@]}" -eq 4 ] || return 2
    _ci_mapfile rel _ci_release_assets || return 1
    for f in "${rel[@]}"; do
        files+=("${CI_REPO_ROOT}/${f}")
    done
    _ci_artifact_offer release_packages "${ctx[0]}" "${files[@]}"
}

# What: Print tag, require_new, publish, tag_push of this run.
# Why: A dispatch names its tag in inputs; a tag push is one.
# From: Issue #479, PR #544
_ci_release_context() {
    local tag publish
    case "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME required}" in
        workflow_dispatch)
            tag="$(_ci_event_value .inputs.tag)" || return 2
            publish="$(_ci_event_value '.inputs.publish_container // false')" || return 2
            printf '%s\n' "${tag}" true "${publish}" false ;;
        push)
            case "${GITHUB_REF:?GITHUB_REF required}" in
                refs/tags/*) ;;
                *) ci_log "[CI-ERROR-RELEASE-0007]" "push of ${GITHUB_REF} is no release tag"; return 2 ;;
            esac
            printf '%s\n' "${GITHUB_REF_NAME:?GITHUB_REF_NAME required}" false true true ;;
        *)
            ci_log "[CI-ERROR-RELEASE-0008]" "event ${GITHUB_EVENT_NAME} has no release tag"
            return 2 ;;
    esac
}

# What: Check a tag; in CI also write tag/publish/tag_push.
# Why: Jobs read the outputs; REL-PRECUT-04 passes a tag.
# From: Issue #479, PR #544
_ci_release_version_check() {
    local ctx=() mx=()
    if [ "$#" -gt 0 ]; then
        _ci_check_release_version "$1" true
        return
    fi
    _ci_mapfile ctx _ci_release_context || return 2
    [ "${#ctx[@]}" -eq 4 ] || return 2
    _ci_check_release_version "${ctx[0]}" "${ctx[1]}" || return 1
    _ci_mapfile mx _ci_release_matrix || return 2
    [ "${#mx[@]}" -eq 2 ] || return 2
    _ci_output tag "${ctx[0]}" publish "${ctx[2]}" tag_push "${ctx[3]}" \
        container_matrix "${mx[0]}" variants "${mx[1]}"
}

# What: Print the GHCR reference of a published package tag.
# Why: One owner of registry, owner and tag naming.
# From: Issue #359, Issue #479, PR #544
_ci_release_image() {
    local pkg="$1" tag="$2" platform="${3:-}"
    printf '%s/%s/%s:%s%s\n' "${CI_REGISTRY}" "${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER required}" \
        "${pkg}" "${tag}" "${platform:+-${platform}}"
}

# What: Print the GHCR package of a SOT release variant.
# Why: An unknown variant fails; it names no published image.
# From: Issue #479, PR #544
_ci_release_pkg() {
    _ci_sot_scalar "release.container.variants.${1:?variant required}"
}

# What: Print the container job matrix, then the variant list.
# Why: Workflows take both from the SOT inventory via outputs.
# From: Issue #479, PR #544
_ci_release_matrix() {
    local platforms v p runner opt rows=""
    local variants=()
    _ci_mapfile variants _ci_sot_children release.container.variants || return 2
    platforms="$(_ci_sot_children release.container.platforms)" || return 2
    for v in "${variants[@]}"; do
        for p in ${platforms}; do
            runner="$(_ci_sot_scalar "release.container.platforms.${p}.runner")" || return 2
            opt="$(_ci_sot_scalar "release.container.platforms.${p}.optional")" || return 2
            case "${opt}" in
                true|false) ;;
                *) ci_log "[CI-ERROR-CONTAINER-0005]" "platform ${p} optional=${opt} (true|false)"; return 2 ;;
            esac
            rows+="$(jq -cn --arg v "${v}" --arg p "${p}" --arg r "${runner}" --argjson o "${opt}" \
                '{variant: $v, platform: $p, runs_on: $r, optional: $o}')"$'\n' || return 2
        done
    done
    jq -cs '{include: .}' <<< "${rows}" || return 2
    jq -cn '$ARGS.positional' --args "${variants[@]}"
}

# What: JSON array of digests a live multi-arch index holds.
# Why: Deleting such a child breaks pulls; errors abort.
# From: Issue #479, PR #544
_ci_gc_protected_digests() {
    local pkg="$1" versions="$2" tags tag raw kids ref children=""
    if ! tags="$(jq -r '[.[].metadata.container.tags[]?] | unique | .[]' <<< "${versions}")"; then
        ci_log "[CI-ERROR-GC-0003]" "cannot read ${pkg}'s version tags; refusing to prune ${pkg}"
        return 1
    fi
    while IFS= read -r tag; do
        [ -n "${tag}" ] || continue
        ref="$(_ci_release_image "${pkg}" "${tag}")" || return 2
        if ! raw="$(docker buildx imagetools inspect --raw "${ref}")"; then
            ci_log "[CI-ERROR-GC-0002]" "cannot inspect ${pkg}:${tag}; refusing to prune ${pkg}"
            return 1
        fi
        if ! kids="$(jq -r '.manifests[]?.digest' <<< "${raw}")"; then
            ci_log "[CI-ERROR-GC-0004]" "cannot parse ${pkg}:${tag}'s manifest; refusing to prune ${pkg}"
            return 1
        fi
        children+="${kids}"$'\n'
    done <<< "${tags}"
    printf '%s' "${children}" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

# What: Print "id<TAB>reason" for every prunable version.
# Why: A tagged version ages out only if all tags are series.
# From: Issue #479, PR #544
_ci_gc_candidates() {
    local versions="$1" protected="$2" keep_untagged="$3" series_re="$4" keep_series="$5"
    jq -r --argjson protected "${protected}" --argjson ku "${keep_untagged}" \
        --arg re "${series_re}" --argjson ks "${keep_series}" '
        map({id, name, created_at, tags: (.metadata.container.tags // [])}) as $v
        | ($v | map(select((.tags | length) == 0 and ((.name | IN($protected[])) | not)))
              | sort_by(.created_at) | reverse | .[$ku:]
              | map({id, why: "untagged \(.name), created \(.created_at)"})) as $untagged
        | ($v | map(select((.tags | length) > 0 and all(.tags[]; test($re))))
              | map(. + {key: (.tags[0] | match($re).captures[0].string | tonumber)})) as $series
        | ($series | map(.key) | unique | sort | reverse | .[:$ks]) as $keep
        | ($series | map(select((.key | IN($keep[])) | not))
              | map({id, why: "superseded series tag \(.tags | join(","))"})) as $old
        | ($untagged + $old)[] | "\(.id)\t\(.why)"
    ' <<< "${versions}"
}

# What: Prune stale GHCR versions of one or all SOT packages.
# Why: Deletes need a delete:packages PAT; dry run by default.
# From: Issue #479, PR #544
ci_cmd_gc() {
    : "${GH_TOKEN:?GH_TOKEN required (delete:packages scope when DRY_RUN=false)}"
    : "${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER required}"
    local DRY_RUN="${DRY_RUN:-true}" sel="${1:-all}" known pkgs pkg
    local ku re ks versions protected candidates id why
    known="$(_ci_sot_list release.ghcr_packages)" || return 2
    ku="$(_ci_sot_scalar gc.keep_untagged)" || return 2
    re="$(_ci_sot_scalar gc.series_tag_regex)" || return 2
    ks="$(_ci_sot_scalar gc.keep_series)" || return 2
    if [ "${sel}" = "all" ]; then
        pkgs="${known}"
    elif grep -qxF -- "${sel}" <<< "${known}"; then
        pkgs="${sel}"
    else
        ci_log "[CI-ERROR-GC-0001]" "unknown package=\"${sel}\" (release.ghcr_packages or all)"
        return 2
    fi
    _ci_registry_login || return 1
    for pkg in ${pkgs}; do
        echo "::group::${pkg}"
        versions="$(gh api --paginate "orgs/${GITHUB_REPOSITORY_OWNER}/packages/container/${pkg}/versions" | jq -s 'add // []')" || return 1
        protected="$(_ci_gc_protected_digests "${pkg}" "${versions}")" || return 1
        candidates="$(_ci_gc_candidates "${versions}" "${protected}" "${ku}" "${re}" "${ks}")" || return 1
        while IFS=$'\t' read -r id why; do
            [ -n "${id}" ] || continue
            ci_log "[CI-GC]" "${pkg}#${id}: delete (${why})"
            _ci_mutate gh api --method DELETE "orgs/${GITHUB_REPOSITORY_OWNER}/packages/container/${pkg}/versions/${id}" --silent || return 1
        done <<< "${candidates}"
        echo "::endgroup::"
    done
}

# What: Print the current index digest of an image tag.
# Why: One multi-arch index digest pins every platform.
# From: Issue #479, PR #544
_ci_registry_digest() {
    local raw digest
    raw="$(docker buildx imagetools inspect "$1" --format '{{json .Manifest}}')" || return 1
    digest="$(jq -r '.digest' <<< "${raw}")" || return 1
    if ! [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        ci_log "[CI-ERROR-SOT-0003]" "no index digest for $1"
        return 1
    fi
    printf '%s\n' "${digest}"
}

# What: Print a tool's highest stable release version.
# Why: Version sort, so a backport never reads as newest.
# From: Issue #479, PR #544
_ci_tool_latest_version() {
    local spec="$1" src prefix tags best
    src="$(_ci_sot_scalar "${spec}.source")" || return 2
    prefix="$(_ci_sot_optional "${spec}.tag_prefix")" || return 2
    tags="$(gh api "repos/${src}/releases?per_page=100" \
        --jq '.[] | select((.draft or .prerelease) | not) | .tag_name')" || return 1
    best="$(while IFS= read -r tag; do
        case "${tag}" in "${prefix}"*) printf '%s\n' "${tag#"${prefix}"}" ;; esac
    done <<< "${tags}" | sort -V | tail -n 1)" || return 1
    if [ -z "${best}" ]; then
        ci_log "[CI-ERROR-SOT-0005]" "${src}: no stable release tag with prefix \"${prefix}\""
        return 1
    fi
    printf '%s\n' "${best}"
}

# What: Print the sha256 GitHub records for a tool's asset.
# Why: The pin comes from the source, not a re-download.
# From: Issue #479, PR #544
_ci_release_asset_sha() {
    local spec="$1" ver="$2" src url tag asset raw sha
    src="$(_ci_sot_scalar "${spec}.source")" || return 2
    url="$(_ci_tool_url "${spec}" "${ver}")" || return 2
    case "${url}" in
        "https://github.com/${src}/releases/download/"*) ;;
        *) ci_log "[CI-ERROR-SOT-0006]" "${spec}.url is no ${src} release asset"; return 2 ;;
    esac
    tag="${url#"https://github.com/${src}/releases/download/"}"
    tag="${tag%%/*}"
    asset="${url##*/}"
    raw="$(gh api "repos/${src}/releases/tags/${tag}")" || return 1
    sha="$(jq -r --arg a "${asset}" '.assets[] | select(.name == $a) | .digest // empty' <<< "${raw}")" || return 1
    if ! [[ "${sha}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        ci_log "[CI-ERROR-SOT-0008]" "${src} ${tag}: no recorded sha256 for ${asset}"
        return 1
    fi
    printf '%s\n' "${sha#sha256:}"
}

# What: Succeed if image ref $1 is name:tag@sha256:<64 hex>.
# Why: Refresh and the pin guard need one tracked-pin rule.
# From: Issue #479, PR #544
_ci_pin_tracked() {
    [[ "$1" =~ ^[^@]+:[^/@]+@sha256:[0-9a-f]{64}$ ]]
}

# What: Move every SOT pin to its channel's newest release.
# Why: Prints one markdown row per change for the PR body.
# From: Issue #479, PR #544
_ci_sot_refresh() {
    local sect key keys path ref tag old new src ver latest sha url
    for sect in base_images external_services; do
        keys="$(_ci_sot_children "${sect}")" || return 2
        for key in ${keys}; do
            path="${sect}.${key}"
            ref="$(_ci_sot_scalar "${path}")" || return 2
            tag="${ref%@*}"
            old="${ref##*@}"
            if ! _ci_pin_tracked "${ref}"; then
                ci_log "[CI-ERROR-SOT-0004]" "${path}=${ref}: no tracked tag (name:tag@sha256:...)"
                return 2
            fi
            new="$(_ci_registry_digest "${tag}")" || return 1
            [ "${new}" != "${old}" ] || continue
            _ci_sot_set "${path}" "${tag}@${new}" || return 2
            printf "| \`%s\` | \`%s\` | \`%s\` | \`%s\` |\n" "${path}" "${tag}" "${old}" "${new}"
        done
    done
    keys="$(_ci_sot_children external_versions)" || return 2
    for key in ${keys}; do
        path="external_versions.${key}"
        src="$(_ci_sot_optional "${path}.source")" || return 2
        [ -n "${src}" ] || continue
        ver="$(_ci_sot_scalar "${path}.version")" || return 2
        latest="$(_ci_tool_latest_version "${path}")" || return 1
        [ "${latest}" != "${ver}" ] || continue
        _ci_sot_set "${path}.version" "${latest}" || return 2
        url="$(_ci_sot_optional "${path}.url")" || return 2
        if [ -n "${url}" ]; then
            sha="$(_ci_release_asset_sha "${path}" "${latest}")" || return 1
            _ci_sot_set "${path}.sha256" "${sha}" || return 2
        fi
        printf "| \`%s\` | \`%s\` | \`%s\` | \`%s\` |\n" "${path}" "${src}" "${ver}" "${latest}"
    done
}

# What: Print the one open PR with head branch $1, or none.
# Why: sot-update refreshes its own PR, never a second one.
# From: Issue #479, PR #544
_ci_open_pr() {
    local prs n
    # What: Keep only PRs whose head branch is in this repo.
    # Why: --head matches a fork's branch of the same name too.
    # From: Issue #479, PR #544
    prs="$(gh pr list --repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}" --head "${1:?branch required}" \
        --state open --json number,baseRefOid,headRefOid,isCrossRepository)" || return 1
    prs="$(jq -ec '[.[] | select(.isCrossRepository == false)]' <<< "${prs}")" || return 1
    n="$(jq -er 'length' <<< "${prs}")" || return 1
    case "${n}" in
        0) ;;
        1) jq -ec '.[0]' <<< "${prs}" ;;
        *) ci_log "[CI-ERROR-PR-0001]" "${n} open pull requests have head $1; none is picked"
           return 1 ;;
    esac
}

# What: Open or refresh the one SOT pin update pull request.
# Why: GITHUB_TOKEN PRs start no CI, so a dispatch runs it.
# From: Issue #479, PR #544
ci_cmd_sot_update() {
    : "${GH_TOKEN:?GH_TOKEN required}"
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    local branch="sot-update" title="chore(deps): refresh SOT pins" rows body open wf milestone url
    cd "${CI_REPO_ROOT}" || return 1
    rows="$(_ci_sot_refresh)" || return 1
    _ci_sot_index_drop
    if [ -z "${rows}" ]; then
        ci_log "[CI-SOT-UPDATE]" "every SOT pin is current"
        return 0
    fi
    body="$(mktemp)" || return 1
    {
        printf '%s\n\n' "Moves SOT pins to the newest release of their channel."
        printf '%s\n%s\n%s\n\n' '| Pin | Channel | Old | New |' '|---|---|---|---|' "${rows}"
        printf '%s\n' "AG-VAL-007: review each crossed release range before merging."
    } > "${body}" || return 1
    cat "${body}" || return 1
    _ci_git_identity || return 1
    _ci_mutate git checkout -q -B "${branch}" || return 1
    _ci_mutate git commit -q -m "${title}" -- "${CI_MANIFEST}" || return 1
    _ci_git_auth_setup || return 1
    _ci_mutate git push -q -f origin "HEAD:refs/heads/${branch}" || return 1
    open="$(_ci_open_pr "${branch}")" || return 1
    if [ -z "${open}" ]; then
        milestone="$(_ci_sot_scalar bot_milestone.title)" || return 2
        url="$(_ci_mutate gh pr create --repo "${GITHUB_REPOSITORY}" --base current_dev --head "${branch}" \
            --title "${title}" --body-file "${body}" --milestone "${milestone}" \
            --label dependencies --label no-changelog-needed)" || return 1
        printf '%s\n' "${url}"
        _ci_board_add "${url}" "${PROJECT_PAT:-}" || return 1
    else
        open="$(jq -er '.number' <<< "${open}")" || return 1
        _ci_mutate gh pr edit "${open}" --repo "${GITHUB_REPOSITORY}" --body-file "${body}" || return 1
    fi
    for wf in validate.yml security.yml; do
        _ci_mutate gh workflow run "${wf}" --repo "${GITHUB_REPOSITORY}" --ref "${branch}" || return 1
    done
}

# What: Print "name result" per name=result line of $1.
# Why: Gate and report read one validated job list.
# From: Issue #479, PR #476, PR #544
_ci_job_results() {
    local line n=0
    while IFS= read -r line; do
        [ -n "${line//[[:space:]]/}" ] || continue
        if ! [[ "${line}" =~ ^[[:space:]]*([A-Za-z0-9_.-]+)=(success|failure|cancelled|skipped)[[:space:]]*$ ]]; then
            ci_log "[CI-ERROR-JOBS-0001]" "not a name=result line: ${line}"
            return 2
        fi
        printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        n=$((n + 1))
    done <<< "$1"
    if [ "${n}" -eq 0 ]; then
        ci_log "[CI-ERROR-JOBS-0002]" "JOBS names no job"
        return 2
    fi
}

# What: Print names of failed or cancelled jobs from pairs.
# Why: A skip means an upstream job failed, not this one.
# From: Issue #479, PR #476
_ci_failed_jobs() {
    local results jname jresult out=""
    results="$(_ci_job_results "$1")" || return 2
    while read -r jname jresult; do
        case "${jresult}" in
            failure|cancelled) out="${out} ${jname}" ;;
        esac
    done <<< "${results}"
    printf '%s\n' "${out# }"
}

# What: Fail if JOBS has any real failure/cancelled entry.
# Why: Skipped jobs have no name a ruleset can require.
# From: Issue #479, PR #544
ci_cmd_gate() {
    : "${JOBS:?JOBS required}"
    local failed
    failed="$(_ci_failed_jobs "${JOBS}")" || return 2
    if [ -n "${failed}" ]; then
        ci_log "[CI-ERROR-GATE-0001]" "failed: ${failed}"
        return 1
    fi
    ci_log "[CI-GATE]" "all jobs passed or were skipped"
}

# What: Set PROJECT_OWNER/PROJECT_NUMBER from the SOT only.
# Why: One board owner; no env or repo Variable may shadow it.
# From: Issue #236, Issue #479, PR #544
_ci_project_board_load() {
    PROJECT_OWNER="$(_ci_sot_scalar project_board.owner)" || return 2
    PROJECT_NUMBER="$(_ci_sot_scalar project_board.number)" || return 2
}

# What: Add an issue or PR url to the SOT project board.
# Why: One board owner; only this write needs a project PAT.
# From: Issue #236, Issue #479, PR #476, PR #544
_ci_board_add() {
    local url="$1" token="$2"
    _ci_project_board_load || return 2
    if [ -z "${token}" ]; then
        echo "::warning::[CI-WARN-BOARD-0001] PROJECT_AUTOMATION_PAT not configured; ${url} was not added to the board."
        return 0
    fi
    GH_TOKEN="${token}" _ci_mutate gh project item-add "${PROJECT_NUMBER}" \
        --owner "${PROJECT_OWNER}" --url "${url}"
}

# What: Give issue $1 the Bug type unless it has a type.
# Why: Retrying on each failure heals a missed one-shot.
# From: Issue #479, PR #476
_ci_report_ensure_bug_type() {
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    local issue_number="$1" owner name issue_query_result issue_node_id current_type bug_type_id
    owner="${GITHUB_REPOSITORY%%/*}"
    name="${GITHUB_REPOSITORY##*/}"
    issue_query_result="$(gh api graphql -f query="
      query(\$owner: String!, \$name: String!, \$number: Int!) {
        repository(owner: \$owner, name: \$name) {
          issue(number: \$number) { id issueType { name } }
        }
      }" -F owner="${owner}" -F name="${name}" -F number="${issue_number}" \
      --jq '.data.repository.issue | .id + " " + (.issueType.name // "-")')" || return 1
    read -r issue_node_id current_type <<<"${issue_query_result}"
    [ "${current_type}" != "-" ] && return 0
    bug_type_id="$(gh api graphql -f query="
      query(\$owner: String!, \$name: String!) {
        repository(owner: \$owner, name: \$name) {
          issueTypes(first: 20) { nodes { id name } }
        }
      }" -F owner="${owner}" -F name="${name}" \
      --jq '.data.repository.issueTypes.nodes[] | select(.name == "Bug") | .id')" || return 1
    if [ -z "${bug_type_id}" ]; then
        ci_log "[CI-ERROR-REPORT-0001]" "no 'Bug' issue type configured for ${GITHUB_REPOSITORY}"
        return 1
    fi
    _ci_mutate gh api graphql -f query="
      mutation(\$issueId: ID!, \$typeId: ID!) {
        updateIssue(input: {id: \$issueId, issueTypeId: \$typeId}) { issue { id } }
      }" -F issueId="${issue_node_id}" -F typeId="${bug_type_id}"
}

# What: Print success if every name=result line is success.
# Why: A skipped job means the run did not do its work.
# From: Issue #479, PR #544
_ci_jobs_outcome() {
    local results jname jresult outcome=success
    results="$(_ci_job_results "$1")" || return 2
    while read -r jname jresult; do
        [ "${jresult}" = "success" ] || outcome=failure
    done <<< "${results}"
    printf '%s\n' "${outcome}"
}

# What: Print the URL of this workflow run.
# Why: Built from the runner's own variables, never passed in.
# From: Issue #479, PR #544
_ci_run_url() {
    printf '%s/%s/actions/runs/%s\n' "${GITHUB_SERVER_URL:?GITHUB_SERVER_URL required}" \
        "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}" "${GITHUB_RUN_ID:?GITHUB_RUN_ID required}"
}

# What: Type issue $1 as Bug and put its url $2 on the board.
# Why: Every report path keeps the standing issue tracked.
# From: Issue #479, PR #476, PR #544
_ci_report_track() {
    _ci_report_ensure_bug_type "$1" || return 1
    _ci_board_add "$2" "${PROJECT_PAT:-}"
}

# What: File, update or close the standing tracking issue.
# Why: All schedules share it; any success closes it.
# From: Issue #479, Issue #81, PR #89, PR #476
ci_cmd_report() {
    : "${GH_TOKEN:?GH_TOKEN required}"
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    : "${GITHUB_SERVER_URL:?GITHUB_SERVER_URL required}"
    : "${SCOPE:?SCOPE required, e.g. 'weekly ccache heartbeat (master)'}"
    : "${JOBS:?JOBS required (name=result lines)}"
    local LABEL="${LABEL:-nightly-broken}" existing detail new_issue_url RUN_URL url
    local OUTCOME FAILED_JOBS
    RUN_URL="$(_ci_run_url)" || return 2
    OUTCOME="$(_ci_jobs_outcome "${JOBS}")" || return 2
    # What: Name only the failed or cancelled jobs.
    # Why: A skip is the upstream failure, already named.
    # From: Issue #479, PR #476
    FAILED_JOBS="$(_ci_failed_jobs "${JOBS}")" || return 2
    existing="$(gh issue list --repo "${GITHUB_REPOSITORY}" --label "${LABEL}" --state open \
        --json number --jq 'sort_by(.number) | .[0].number // empty')" || return 1
    url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/issues/${existing}"
    if [ "${OUTCOME}" = "success" ]; then
        if [ -z "${existing}" ]; then
            ci_log "[CI-REPORT]" "success and no open ${LABEL} issue: nothing to do"
            return 0
        fi
        _ci_report_track "${existing}" "${url}" || return 1
        ci_log "[CI-REPORT]" "success: closing standing ${LABEL} issue #${existing}"
        _ci_mutate gh issue comment "${existing}" --repo "${GITHUB_REPOSITORY}" \
            --body "Recovered: ${SCOPE} succeeded in ${RUN_URL}. Closing this standing tracking issue automatically; it will re-open if a later scheduled run fails." \
            || return 1
        _ci_mutate gh issue close "${existing}" --repo "${GITHUB_REPOSITORY}" || return 1
        return 0
    fi
    _ci_mutate gh label create "${LABEL}" --repo "${GITHUB_REPOSITORY}" --color b60205 --force \
        --description "A scheduled nightly/heartbeat CI run is failing" || return 1
    detail="${SCOPE} failed in ${RUN_URL}"
    [ -z "${FAILED_JOBS}" ] || detail="${detail} (failed: ${FAILED_JOBS})"
    if [ -n "${existing}" ]; then
        ci_log "[CI-REPORT]" "failure: commenting on standing ${LABEL} issue #${existing}"
        _ci_mutate gh issue comment "${existing}" --repo "${GITHUB_REPOSITORY}" \
            --body "Still failing: ${detail}." || return 1
        _ci_report_track "${existing}" "${url}"
        return
    fi
    ci_log "[CI-REPORT]" "failure: opening a new standing ${LABEL} issue"
    new_issue_url="$(_ci_mutate gh issue create --repo "${GITHUB_REPOSITORY}" --label "${LABEL}" \
        --title "[${LABEL}] a scheduled CI run is failing" \
        --body "A scheduled CI run failed. This standing issue is reused across consecutive failures and closed automatically on the next successful run.

${detail}.")" || return 1
    # What: A dry run has no new issue url to act on.
    # Why: Bug type and board both need the created issue.
    # From: Issue #479, PR #544
    if [ "${DRY_RUN:-false}" = "true" ]; then
        printf '%s\n' "${new_issue_url}"
        return 0
    fi
    _ci_report_track "${new_issue_url##*/}" "${new_issue_url}"
}

# What: Append name/value pairs to GITHUB_OUTPUT.
# Why: A multi-line value needs the delimiter form.
# From: Issue #479, PR #544
_ci_output() {
    : "${GITHUB_OUTPUT:?GITHUB_OUTPUT required}"
    local delim
    if [ $(( $# % 2 )) -ne 0 ]; then
        ci_log "[CI-ERROR-CORE-0004]" "_ci_output needs name/value pairs, got $#"
        return 2
    fi
    while [ "$#" -gt 0 ]; do
        case "$2" in
            *$'\n'*)
                delim="ci_eof_${RANDOM}${RANDOM}"
                printf '%s<<%s\n%s\n%s\n' "$1" "${delim}" "$2" "${delim}" >> "${GITHUB_OUTPUT}" || return 1 ;;
            *)
                printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT}" || return 1 ;;
        esac
        shift 2
    done
}

# What: Print a SOT list as a JSON array of strings.
# Why: A job matrix reads it through fromJSON.
# From: Issue #479, PR #544
_ci_sot_json_list() {
    local items
    items="$(_ci_sot_list "$1")" || return 2
    jq -cnR '[inputs | select(length > 0)]' <<< "${items}"
}

# What: Succeed if this run fired from the SOT schedule $1.
# Why: The cron string is the only thing naming a schedule.
# From: Issue #479, PR #544
_ci_schedule_is() {
    local want got
    [ "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME required}" = "schedule" ] || return 1
    want="$(_ci_sot_scalar "schedules.$1.cron")" || return 2
    got="$(_ci_event_value '.schedule // ""')" || return 2
    [ "${got}" = "${want}" ]
}

# What: Print true or false for _ci_schedule_is $1.
# Why: A failed lookup must fail the route, not read as false.
# From: Issue #479, PR #544
_ci_schedule_flag() {
    local rc=0
    _ci_schedule_is "$1" || rc=$?
    case "${rc}" in
        0) echo true ;;
        1) echo false ;;
        *) return 2 ;;
    esac
}

# What: Succeed when this run's ref is current_dev or master.
# Why: One owner for "only these branches publish or post".
# From: Issue #312, Issue #479, PR #544
_ci_ref_protected() {
    case "${GITHUB_REF_NAME:?GITHUB_REF_NAME required}" in
        current_dev|master) return 0 ;;
    esac
    return 1
}

# What: Write which jobs of a scheduled workflow run now.
# Why: One owner maps events, crons and tasks to jobs.
# From: Issue #479, PR #544
ci_cmd_route() {
    local wf="${1:?workflow required}" scans openssf weekly task="" tasks t on run langs sans
    local outs=()
    case "${wf}" in
        security)
            if [ "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME required}" = "schedule" ]; then
                scans="$(_ci_schedule_flag security_scans)" || return 2
            else
                scans=true
            fi
            openssf="$(_ci_schedule_flag openssf)" || return 2
            # What: A dispatch rechecks only from current_dev or master.
            # Why: It posts to the tracking issue; a bot branch must not.
            # From: Issue #312, PR #544
            if [ "${GITHUB_EVENT_NAME}" = "workflow_dispatch" ] && _ci_ref_protected; then
                openssf=true
            fi
            langs="$(_ci_sot_json_list security.codeql.languages)" || return 2
            sans="$(_ci_sot_json_list security.cfl_run.sanitizers)" || return 2
            _ci_output scans "${scans}" openssf "${openssf}" \
                codeql_languages "${langs}" cfl_sanitizers "${sans}" ;;
        housekeeping)
            weekly="$(_ci_schedule_flag housekeeping_weekly)" || return 2
            tasks="$(_ci_sot_children housekeeping_tasks)" || return 2
            if [ "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME required}" = "workflow_dispatch" ]; then
                task="$(_ci_event_value .inputs.task)" || return 2
                if ! grep -qxF -- "${task}" <<< "${tasks}"; then
                    ci_log "[CI-ERROR-ROUTE-0002]" "task=\"${task}\" is no housekeeping_tasks key"
                    return 2
                fi
            fi
            # What: A task runs if dispatched, or weekly when it is.
            # Why: The SOT owns tasks and cadence; outputs follow names.
            # From: Issue #479, PR #544
            for t in ${tasks}; do
                on="$(_ci_sot_scalar "housekeeping_tasks.${t}.weekly")" || return 2
                case "${on}" in
                    true|false) ;;
                    *) ci_log "[CI-ERROR-ROUTE-0003]" "housekeeping_tasks.${t}.weekly=${on} (true|false)"; return 2 ;;
                esac
                run=false
                if [ "${task}" = "${t}" ] || { [ "${weekly}" = true ] && [ "${on}" = true ]; }; then run=true; fi
                outs+=("${t//-/_}" "${run}")
            done
            _ci_output "${outs[@]}" ;;
        *) ci_log "[CI-ERROR-ROUTE-0001]" "no route for workflow=${wf} (security|housekeeping)"; return 2 ;;
    esac
}

# What: Offer files for upload as one SOT artifact kind.
# Why: upload-artifact only transports; ci.sh picks the files.
# From: Issue #267, Issue #479, PR #370, PR #544
_ci_artifact_offer() {
    local kind="$1" suffix="$2" name days f
    shift 2
    name="$(_ci_sot_scalar "ci_engine.artifacts.${kind}.name")" || return 2
    days="$(_ci_sot_scalar "ci_engine.artifacts.${kind}.retention_days")" || return 2
    if [ "$#" -eq 0 ]; then
        ci_log "[CI-ERROR-ARTIFACT-0001]" "kind=${kind} offers no files"
        return 2
    fi
    for f in "$@"; do
        if [ ! -e "${f}" ]; then
            ci_log "[CI-ERROR-ARTIFACT-0002]" "kind=${kind} file missing: ${f}"
            return 1
        fi
    done
    _ci_output artifact_name "${name}${suffix:+-${suffix}}" \
        artifact_path "$(printf '%s\n' "$@")" \
        artifact_retention_days "${days}" artifact_if_missing error
}

# What: Add this event's issue or PR url to the board.
# Why: The url comes from the payload, never from YAML.
# From: Issue #479
_ci_variables_add_to_project() {
    local url
    url="$(_ci_event_value '.issue.html_url // .pull_request.html_url')" || return 2
    _ci_board_add "${url}" "${PROJECT_PAT:-}"
}

# What: Map a Commit type prefix to a category label.
# Why: Release notes group PRs by exactly these four labels.
# From: Issue #479
_ci_pr_category_label() {
    local type
    type="$(_ci_title_type "$1")" || return 0
    case "${type}" in
        security) printf 'security' ;;
        fix)      printf 'bug' ;;
        feat)     printf 'enhancement' ;;
        docs)     printf 'documentation' ;;
    esac
}

# What: Apply path- and title-based labels to a PR.
# Why: SOT labels map paths; the title type sets the category.
# From: Issue #479, PR #544
_ci_variables_label_pr() {
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    local files hits labels=() category PR_NUMBER want got
    PR_NUMBER="$(_ci_event_value .pull_request.number)" || return 2
    want="$(_ci_event_value .pull_request.changed_files)" || return 2
    # What: Read the PR file list page by page, not the diff.
    # Why: The diff API refuses a PR of over 300 files (HTTP 406).
    # From: Issue #479, PR #544
    files="$(gh api --paginate "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/files" \
        --jq '.[].filename')" || return 1
    got="$(awk 'NF { n++ } END { print n + 0 }' <<< "${files}")"
    # What: Fail on a list shorter than the PR's file count.
    # Why: The files API stops at 3000; no partial labels.
    # From: Issue #479, PR #544
    if [ "${got}" != "${want}" ]; then
        ci_log "[CI-ERROR-VARIABLES-0002]" "PR #${PR_NUMBER} lists ${got} of ${want} changed files"
        return 1
    fi
    hits="$(_ci_classify_paths labels <<< "${files}")" || return 2
    _ci_mapfile labels printf '%s' "${hits}" || return 2
    _ci_metadata_fetch_live || return 2
    category="$(_ci_pr_category_label "${PR_TITLE:-}")"
    [ -z "${category}" ] || labels+=("${category}")
    if [ "${#labels[@]}" -gt 0 ]; then
        _ci_mutate gh pr edit "${PR_NUMBER}" --repo "${GITHUB_REPOSITORY}" \
            --add-label "$(IFS=,; printf '%s' "${labels[*]}")"
    fi
}

# What: Workflow variable/output helpers dispatch.
# Why: One owner for gate logic YAML cannot express.
# From: Issue #479
ci_cmd_variables() {
    local sub="${1:?variables subcommand required}"
    case "${sub}" in
        add-to-project)  _ci_variables_add_to_project ;;
        label-pr)        _ci_variables_label_pr ;;
        *) ci_log "[CI-ERROR-VARIABLES-0001]" "unknown variables subcommand=\"${sub}\""; return 2 ;;
    esac
}

# What: Print Met for check rc 0, NotMet for rc 1; else error.
# Why: A failed tool must never pose as a NotMet finding.
# From: Issue #479, Issue #312, PR #544
_ci_ossf_verdict() {
    local rc=0
    "$@" || rc=$?
    case "${rc}" in
        0) echo "Met" ;;
        1) echo "NotMet" ;;
        *) ci_log "[CI-ERROR-OSSF-0004]" "no verdict, check failed (rc ${rc}): $*"; return 2 ;;
    esac
}

# What: URL-encode one argument via jq @uri.
# Why: Justification text must survive in a query string.
# From: Issue #312
_ci_ossf_urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

# What: Append a status=Met&justification pair if $2 is Met.
# Why: Only currently-Met criteria enter the proposal URL.
# From: Issue #312, PR #544
_ci_ossf_add_met() {
    local -n _qs="$1"
    local verdict="$2" osps_id="$3" justification="$4" param_key enc_just
    [ "${verdict}" = "Met" ] || return 0
    param_key="${osps_id,,}"
    param_key="${param_key//-/_}"
    enc_just="$(_ci_ossf_urlencode "${justification}")" || return 1
    [ -z "${_qs}" ] || _qs="${_qs}&"
    _qs="${_qs}${param_key}_status=Met&${param_key}_justification=${enc_just}"
}

# What: Print the bestpractices.dev edit URL of one level.
# Why: Callers pass an assembled Met-criteria query string.
# From: Issue #312
_ci_ossf_url() { echo "https://www.bestpractices.dev/en/projects/${PROJECT_ID}/baseline-$1/edit?$2"; }

# What: Ruleset keeps pull_request and deletion rules.
# Why: Catches a ruleset recreated under a new ID.
# From: Issue #312
_ci_ossf_check_ac03() {
    local types id
    id="${1:?ruleset id required}"
    if ! types="$(gh api "repos/${GITHUB_REPOSITORY}/rulesets/${id}" --jq '[.rules[].type]')"; then
        ci_log "[CI-ERROR-OSSF-0001]" "cannot read ruleset ${id}; no verdict"
        return 2
    fi
    jq -e 'contains(["pull_request"]) and contains(["deletion"])' <<< "${types}" >/dev/null
}

# What: No pull_request_target fork code, no raw event text.
# Why: Only a ci.sh checkout given a ref can fetch PR code.
# From: Issue #312, PR #544
_ci_ossf_check_br01() {
    local f rc lines
    for f in .github/workflows/*.yml; do
        rc=0
        grep -q "pull_request_target" "${f}" || rc=$?
        [ "${rc}" -le 1 ] || return 2
        [ "${rc}" -eq 0 ] || continue
        rc=0
        grep -qE 'bash -s -- checkout [0-9]+ [^[:space:]]' "${f}" || rc=$?
        [ "${rc}" -ne 0 ] || return 1
        [ "${rc}" -eq 1 ] || return 2
    done
    lines="$(grep -hv '^[[:space:]]*#' .github/workflows/*.yml)" || return 2
    rc=0
    grep -qE 'github\.event\.(pull_request|issue|comment)\.(title|body)' <<< "${lines}" || rc=$?
    case "${rc}" in
        0) return 1 ;;
        1) return 0 ;;
        *) return 2 ;;
    esac
}

# What: Secret scanning and push protection are enabled.
# Why: Needs an admin token; github.token hides the field.
# From: Issue #312
_ci_ossf_check_br07() {
    local analysis
    if ! analysis="$(gh api "repos/${GITHUB_REPOSITORY}" --jq '.security_and_analysis')"; then
        ci_log "[CI-ERROR-OSSF-0002]" "cannot read ${GITHUB_REPOSITORY}; no verdict"
        return 2
    fi
    # What: Either unreadable field is an error, never NotMet.
    # Why: github.token hides them; a NotMet there would be false.
    # From: Issue #312, PR #544
    if ! jq -e '.secret_scanning.status and .secret_scanning_push_protection.status' \
        <<< "${analysis}" >/dev/null; then
        ci_log "[CI-ERROR-OSSF-0003]" "token cannot read security_and_analysis; no verdict"
        return 2
    fi
    jq -e '.secret_scanning.status == "enabled" and .secret_scanning_push_protection.status == "enabled"' \
        <<< "${analysis}" >/dev/null
}

# What: No compiled binary is tracked in the git tree.
# Why: Build outputs must be produced, never committed.
# From: Issue #312
_ci_ossf_check_qa05() {
    local tree rc=0
    tree="$(git ls-tree -r HEAD --name-only)" || return 2
    grep -qEi '\.(o|so|a|exe|dll|bin)$' <<< "${tree}" || rc=$?
    case "${rc}" in
        0) return 1 ;;
        1) return 0 ;;
        *) return 2 ;;
    esac
}

# What: Each workflow has a narrow top-level permissions key.
# Why: A missing or write-all default is not least-privilege.
# From: Issue #312
_ci_ossf_check_ac04() {
    local f block rc
    for f in .github/workflows/*.yml; do
        block="$(awk '/^permissions:/{flag=1} /^jobs:/{flag=0} flag' "${f}")" || return 2
        [ -n "${block}" ] || return 1
        rc=0
        grep -qE 'permissions:[[:space:]]*write-all|^[[:space:]]*contents:[[:space:]]*write' <<< "${block}" || rc=$?
        [ "${rc}" -ne 0 ] || return 1
        [ "${rc}" -eq 1 ] || return 2
    done
}

# What: The SOT pin refresh is scheduled; its policy is doc'd.
# Why: Both must hold for OSPS-BR-05.01/DO-06.01.
# From: Issue #312, PR #544
_ci_ossf_check_br05_do06() {
    grep -q 'ci.sh sot-update' .github/workflows/housekeeping.yml \
        && grep -q "## Dependency management policy" doc/compatibility-policy.md
}

# What: Run every baseline check; post the tracking comment.
# Why: One recheck owner; workflows only call the phase.
# From: Issue #479, Issue #312
_ci_scan_openssf() {
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    local ISSUE_NUMBER PROJECT_ID RULESET_ID RUN_URL
    ISSUE_NUMBER="$(_ci_sot_scalar security.openssf.issue)" || return 2
    PROJECT_ID="$(_ci_sot_scalar security.openssf.project_id)" || return 2
    RULESET_ID="$(_ci_sot_scalar security.openssf.ruleset_id)" || return 2
    RUN_URL="$(_ci_run_url)" || return 2
    local MARKER="<!-- openssf-baseline-recheck -->"
    local TODAY; TODAY="$(date -u +%Y-%m-%d)" || return 1
    local ac03 br01 br07 qa05 vm02 ac04 br06 br05_do06 gv01 vm01_vm03 do04_do05
    ac03="$(_ci_ossf_verdict _ci_ossf_check_ac03 "${RULESET_ID}")" || return 2
    br01="$(_ci_ossf_verdict _ci_ossf_check_br01)" || return 2
    br07="$(_ci_ossf_verdict _ci_ossf_check_br07)" || return 2
    qa05="$(_ci_ossf_verdict _ci_ossf_check_qa05)" || return 2
    vm02="$(_ci_ossf_verdict test -f SECURITY.md)" || return 2
    ac04="$(_ci_ossf_verdict _ci_ossf_check_ac04)" || return 2
    br06="$(_ci_ossf_verdict grep -rq "ci.sh attest release" .github/workflows/)" || return 2
    br05_do06="$(_ci_ossf_verdict _ci_ossf_check_br05_do06)" || return 2
    gv01="$(_ci_ossf_verdict grep -q 'grant maintainer-level approval' AGENTS.md)" || return 2
    vm01_vm03="$(_ci_ossf_verdict grep -qi 'Security Advisor' SECURITY.md)" || return 2
    do04_do05="$(_ci_ossf_verdict grep -q '## Supported Versions' SECURITY.md)" || return 2
    local new_state
    new_state="$(jq -nc \
        --arg ac03 "${ac03}" --arg br01 "${br01}" --arg br07 "${br07}" \
        --arg qa05 "${qa05}" --arg vm02 "${vm02}" --arg ac04 "${ac04}" \
        --arg br06 "${br06}" --arg br05_do06 "${br05_do06}" --arg gv01 "${gv01}" \
        --arg vm01_vm03 "${vm01_vm03}" --arg do04_do05 "${do04_do05}" \
        '{"AC-03":$ac03,"BR-01":$br01,"BR-07":$br07,"QA-05":$qa05,"VM-02":$vm02,
          "AC-04":$ac04,"BR-06":$br06,"BR-05_DO-06":$br05_do06,"GV-01":$gv01,
          "VM-01_VM-03":$vm01_vm03,"DO-04_DO-05":$do04_do05}')" || return 1
    local existing_id prev_state regressed_keys
    existing_id="$(gh api "repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/comments" --paginate \
        --jq "[.[] | select(.body | startswith(\"${MARKER}\"))] | sort_by(.id) | last | .id // empty")" || return 1
    if [ -z "${existing_id}" ]; then
        prev_state="{}"
    else
        local prev_body state_line
        prev_body="$(gh api "repos/${GITHUB_REPOSITORY}/issues/comments/${existing_id}" --jq '.body')" || return 1
        state_line="$(awk 'match($0, /<!-- openssf-baseline-recheck-state: .*-->/) {
            print substr($0, RSTART, RLENGTH) }' <<< "${prev_body}")" || return 2
        if [ -z "${state_line}" ]; then
            prev_state="{}"
        else
            prev_state="$(echo "${state_line}" | sed -e 's/^<!-- openssf-baseline-recheck-state: //' -e 's/ -->$//')" \
                || return 2
        fi
    fi
    regressed_keys="$(jq -rn --argjson prev "${prev_state}" --argjson new "${new_state}" '
        $new | to_entries[] | select(.value == "NotMet" and ($prev[.key] // "") == "Met") | .key')" || return 2
    local qs1="" qs2="" qs3="" l1 l2 l3 url1 url2 url3 regressed_block=""
    _ci_ossf_add_met qs1 "${ac03}" "OSPS-AC-03.01" "Ruleset ${RULESET_ID} on ${GITHUB_REPOSITORY} has a pull_request and a deletion rule, re-verified ${TODAY}." || return 1
    _ci_ossf_add_met qs1 "${ac03}" "OSPS-AC-03.02" "Same ruleset re-verified ${TODAY}; deletion rule present." || return 1
    _ci_ossf_add_met qs1 "${br01}" "OSPS-BR-01.01" "No workflow runs fork code under pull_request_target, re-verified ${TODAY}." || return 1
    _ci_ossf_add_met qs1 "${br01}" "OSPS-BR-01.03" "No workflow interpolates untrusted event title/body, re-verified ${TODAY}." || return 1
    _ci_ossf_add_met qs1 "${br07}" "OSPS-BR-07.01" "Secret scanning and push protection are enabled on ${GITHUB_REPOSITORY}, re-verified ${TODAY}." || return 1
    _ci_ossf_add_met qs1 "${qa05}" "OSPS-QA-05.01" "No compiled binary is tracked in the git tree, re-verified ${TODAY}." || return 1
    _ci_ossf_add_met qs1 "${qa05}" "OSPS-QA-05.02" "Same check, re-verified ${TODAY}." || return 1
    _ci_ossf_add_met qs1 "${vm02}" "OSPS-VM-02.01" "SECURITY.md still exists at the repo root, re-verified ${TODAY}." || return 1
    l1="- AC-03.01/03.02 (ruleset PR+deletion rules): ${ac03}
- BR-01.01/01.03 (no fork-code pull_request_target / no unsanitized event interpolation): ${br01}
- BR-07.01 (secret scanning + push protection): ${br07}
- QA-05.01/05.02 (no tracked binary artifacts): ${qa05}
- VM-02.01 (SECURITY.md present): ${vm02}"
    _ci_ossf_add_met qs2 "${ac04}" "OSPS-AC-04.01" "Every workflow top-level permissions block is contents:read or narrower, re-verified ${TODAY}." || return 1
    _ci_ossf_add_met qs2 "${br06}" "OSPS-BR-06.01" "A build-provenance attestation step is present, re-verified ${TODAY}." || return 1
    _ci_ossf_add_met qs2 "${br05_do06}" "OSPS-BR-05.01" "housekeeping.yml schedules the ci.sh SOT pin refresh, re-verified ${TODAY}." || return 1
    _ci_ossf_add_met qs2 "${br05_do06}" "OSPS-DO-06.01" "doc/compatibility-policy.md documents the dependency policy, re-verified ${TODAY}." || return 1
    _ci_ossf_add_met qs2 "${gv01}" "OSPS-GV-01.01" "AGENTS.md documents maintainer approval authority, re-verified ${TODAY}." || return 1
    _ci_ossf_add_met qs2 "${gv01}" "OSPS-GV-01.02" "Same rule, re-verified ${TODAY}." || return 1
    _ci_ossf_add_met qs2 "${vm01_vm03}" "OSPS-VM-01.01" "SECURITY.md documents GitHub Security Advisories as the channel, re-verified ${TODAY}." || return 1
    _ci_ossf_add_met qs2 "${vm01_vm03}" "OSPS-VM-03.01" "Same document, re-verified ${TODAY}." || return 1
    l2="- AC-04.01 (workflow permissions spot-check): ${ac04}
- BR-06.01 (build provenance attestation present): ${br06}
- BR-05.01/DO-06.01 (scheduled SOT pin refresh + dependency policy doc): ${br05_do06}
- GV-01.01/01.02 (AGENTS.md maintainer authority): ${gv01}
- VM-01.01/03.01 (SECURITY.md documents GH Security Advisories): ${vm01_vm03}"
    _ci_ossf_add_met qs3 "${ac04}" "OSPS-AC-04.02" "Same workflow-permissions spot-check as AC-04.01, re-verified ${TODAY}." || return 1
    _ci_ossf_add_met qs3 "${br01}" "OSPS-BR-01.04" "Same untrusted-input grep as BR-01.01, re-verified ${TODAY}." || return 1
    _ci_ossf_add_met qs3 "${do04_do05}" "OSPS-DO-04.01" "SECURITY.md documents a Supported Versions table, re-verified ${TODAY}." || return 1
    _ci_ossf_add_met qs3 "${do04_do05}" "OSPS-DO-05.01" "Same table, re-verified ${TODAY}." || return 1
    l3="- AC-04.02 (workflow permissions, stricter framing): ${ac04}
- BR-01.04 (untrusted-input sanitization, stricter framing): ${br01}
- DO-04.01/05.01 (SECURITY.md Supported Versions table): ${do04_do05}
- QA-04.02 (single-repo N/A): static N/A, no live check applicable"
    url1="$(_ci_ossf_url 1 "${qs1}")"
    url2="$(_ci_ossf_url 2 "${qs2}")"
    url3="$(_ci_ossf_url 3 "${qs3}")"
    if [ -n "${regressed_keys}" ]; then
        regressed_block="## REGRESSED -- was Met on the previous recheck, now NotMet

- ${regressed_keys//$'\n'/$'\n'- }

These were excluded from the proposal links; investigate before re-proposing them."
    fi
    local body
    body="$(cat <<EOF
${MARKER}
# OpenSSF Best Practices Baseline recheck -- ${TODAY}

Automated re-verification of the mechanically-checkable criteria for [project ${PROJECT_ID}](https://www.bestpractices.dev/projects/${PROJECT_ID}). This does not submit anything to bestpractices.dev -- a logged-in human must open a proposal link below and submit the form there.

${regressed_block}

## Level 1
${l1}

Proposal link (Level 1, currently-Met criteria only): ${url1}

## Level 2
${l2}

Proposal link (Level 2, currently-Met criteria only): ${url2}

## Level 3
${l3}

Proposal link (Level 3, currently-Met criteria only): ${url3}

Run: ${RUN_URL}
<!-- openssf-baseline-recheck-state: ${new_state} -->
EOF
)" || return 1
    local body_file
    body_file="$(mktemp)" || return 1
    printf '%s\n' "${body}" | tee "${body_file}" || return 1
    if [ -n "${existing_id}" ]; then
        _ci_mutate gh api --method PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${existing_id}" \
            -F "body=@${body_file}" || return 1
    else
        _ci_mutate gh api --method POST "repos/${GITHUB_REPOSITORY}/issues/${ISSUE_NUMBER}/comments" \
            -F "body=@${body_file}" || return 1
    fi
}

# What: Expand {version}/{bare} in a SOT url key, default url.
# Why: One url owner for fetch and the sot-update digest.
# From: Issue #479, PR #544
_ci_tool_url() {
    local spec="$1" ver="$2" key="${3:-url}" url
    url="$(_ci_sot_scalar "${spec}.${key}")" || return 2
    url="${url//\{version\}/${ver}}"
    printf '%s\n' "${url//\{bare\}/${ver#v}}"
}

# What: One curl attempt of a download; log it if it fails.
# Why: Each failed attempt is named; _ci_wait_until retries.
# From: Issue #479, PR #544
_ci_download_attempt() {
    if curl -fsSL -o "$2" "$1"; then
        return 0
    fi
    ci_log "[CI-FETCH]" "attempt ${CI_ATTEMPT}/${CI_TRIES} failed: $1"
    return 1
}

# What: Download one URL to a file in up to three attempts.
# Why: CFL's curl 7.68 lacks --retry-all-errors.
# From: Issue #479, PR #544
_ci_download() {
    local url="$1" file="$2"
    if _ci_wait_until 3 2 _ci_download_attempt "${url}" "${file}"; then
        return 0
    fi
    ci_log "[CI-ERROR-FETCH-0003]" "download failed: ${url}"
    return 1
}

# What: Check $2 against SOT pin $1.sha256; remove it if not.
# Why: One pin check for every fetched file; none runs bare.
# From: Issue #479, PR #544
_ci_sha256_ok() {
    local spec="$1" file="$2" sha
    sha="$(_ci_sot_scalar "${spec}.sha256")" || return 2
    if ! printf '%s  %s\n' "${sha}" "${file}" | sha256sum -c --quiet -; then
        ci_log "[CI-ERROR-FETCH-0001]" "sha256 mismatch for ${spec} (${file##*/})"
        rm -f "${file}" || return 2
        return 2
    fi
}

# What: Fetch, sha256-check and cache one SOT tool; print dir.
# Why: One tool fetcher; a missing sha256 pin fails closed.
# From: Issue #479, PR #544
_ci_fetch_tool() {
    local spec="$1" ver url kind dest file bin
    ver="$(_ci_sot_scalar "${spec}.version")" || return 2
    _ci_sot_scalar "${spec}.sha256" >/dev/null || return 2
    url="$(_ci_tool_url "${spec}" "${ver}")" || return 2
    kind="$(_ci_sot_optional "${spec}.archive")" || return 2
    dest="${RUNNER_TEMP:-/tmp}/${spec##*.}-${ver}"
    if [ ! -f "${dest}/.complete" ]; then
        rm -rf "${dest}" || return 2
        mkdir -p "${dest}" || return 2
        file="${dest}.download"
        _ci_download "${url}" "${file}" || return 2
        _ci_sha256_ok "${spec}" "${file}" || return 2
        case "${kind:-tar.gz}" in
            tar.gz) tar -xzf "${file}" -C "${dest}" || return 2; rm -f "${file}" || return 2 ;;
            binary)
                bin="$(_ci_sot_scalar "${spec}.bin")" || return 2
                mv "${file}" "${dest}/${bin}" || return 2 ;;
            *) ci_log "[CI-ERROR-FETCH-0002]" "${spec}.archive=${kind} (tar.gz|binary)"; return 2 ;;
        esac
        chmod -R u+rwX "${dest}" || return 2
        touch "${dest}/.complete" || return 2
    fi
    printf '%s' "${dest}"
}

# What: Print the path of a fetched SOT tool's executable.
# Why: The SOT bin key owns where each archive keeps it.
# From: Issue #479, PR #544
_ci_tool_bin() {
    local spec="$1" dest bin
    dest="$(_ci_fetch_tool "${spec}")" || return 2
    bin="$(_ci_sot_scalar "${spec}.bin")" || return 2
    chmod +x "${dest}/${bin}" || return 2
    printf '%s/%s' "${dest}" "${bin}"
}

# What: Fetch SOT tool $1 and install its binary as file $2.
# Why: Images and the harden agent take a tool in one way.
# From: Issue #479, PR #544
_ci_install_tool() {
    local rt bin rc=0
    rt="$(mktemp -d)" || return 1
    bin="$(RUNNER_TEMP="${rt}" _ci_tool_bin "$1")" || rc=2
    if [ "${rc}" -eq 0 ]; then
        install -m 755 "${bin}" "$2" || rc=1
    fi
    rm -rf "${rt}" || return 1
    return "${rc}"
}

# What: Scan a local image ref for HIGH/CRITICAL vulns.
# Why: A HIGH or CRITICAL finding must stop the push.
# From: Issue #479
ci_cmd_trivy_scan() {
    local image_ref="${1:?image ref required}" bin
    bin="$(_ci_tool_bin external_versions.trivy)" || return 2
    "${bin}" image --scanners vuln,secret --severity HIGH,CRITICAL \
        --ignore-unfixed --ignorefile "${CI_REPO_ROOT}/.trivyignore.yaml" \
        --exit-code 1 --timeout 10m "${image_ref}"
}

# What: Generate an SPDX-JSON SBOM for an image/path.
# Why: OSPS-QA-02.02: every release asset ships an SBOM.
# From: Issue #479
ci_cmd_sbom() {
    local target="${1:?image ref or path required}" out="${2:?output file required}" bin
    bin="$(_ci_tool_bin external_versions.syft)" || return 2
    "${bin}" "${target}" -o "spdx-json=${out}"
}

# What: Dispatch one security scan subcommand.
# Why: One scan phase owner; YAML only names the scan.
# From: Issue #479, Issue #312
ci_cmd_scan() {
    local sub="${1:?scan target required}"
    [ "$#" -gt 0 ] && shift
    case "${sub}" in
        openssf)             _ci_scan_openssf ;;
        codeql)               ci_cmd_codeql_scan "$@" ;;
        sarif-upload)         ci_cmd_sarif_upload "$@" ;;
        scorecard)            ci_cmd_scorecard_scan "$@" ;;
        osv)                  ci_cmd_osv_scan "$@" ;;
        clusterfuzzlite-build) ci_cmd_clusterfuzzlite_build "$@" ;;
        clusterfuzzlite-run)   ci_cmd_clusterfuzzlite_run "$@" ;;
        trivy)                 ci_cmd_trivy_scan "$@" ;;
        sbom)                  ci_cmd_sbom "$@" ;;
        package-sbom)          _ci_package_sbom "$@" ;;
        *) ci_log "[CI-ERROR-SCAN-0001]" "unknown scan target=\"${sub}\""; return 2 ;;
    esac
}

# What: Run one verify check in the local buildtools image.
# Why: Each check is a workload; ptrace ones get the profile.
# From: Issue #285, Issue #286, PR #528, PR #544
ci_cmd_verify() {
    local sub="${1:?verify subcommand required}" image
    image="$(_ci_sot_scalar release.images.distcc-ng-buildtools.tag)" || return 2
    case "${sub}" in
        all)
            _ci_stack_run "$(_ci_run_name verify)" _ci_verify_all "${image}" ;;
        ptrace-selftest|build-test|samba-configure-dryrun)
            _ci_stack_run "$(_ci_run_name verify)" _ci_verify_in_image "${image}" "${sub}" ;;
        ccache-redis)
            _ci_stack_run "$(_ci_run_name ccache-redis)" _ci_verify_ccache_redis "${image}" ;;
        *) ci_log "[CI-ERROR-VERIFY-0001]" "unknown verify subcommand=\"${sub}\""; return 2 ;;
    esac
}

# What: Print the workload argv of one in-image verify check.
# Why: One owner whether a check runs alone or with the rest.
# From: Issue #264, Issue #479, PR #544
_ci_verify_argv() {
    case "$1" in
        ptrace-selftest) printf '%s\n' ptrace ;;
        build-test) printf '%s\n' checkout check /tmp/checkout ;;
        samba-configure-dryrun) printf '%s\n' samba configure /tmp/samba ;;
        *) ci_log "[CI-ERROR-VERIFY-0005]" "unknown in-image check=\"$1\""; return 2 ;;
    esac
}

# What: Run in-image checks in one verify container, in order.
# Why: #479: the verify container starts once for all phases.
# From: Issue #264, Issue #285, Issue #479, PR #528, PR #544
_ci_verify_in_image() {
    local image="$1" net="${!#}" name check rc=0 argv=() failed=""
    local checks=("${@:2:$#-2}")
    name="${net}-verify"
    # What: ptrace and the narrow seccomp profile for the checks.
    # Why: The self-test and make check run gdb/strace in here.
    # From: Issue #285, PR #528
    _ci_container_run "${image}" -d --name "${name}" --cap-add=SYS_PTRACE \
        --security-opt "seccomp=${CI_REPO_ROOT}/docker/verify/seccomp-verify.json" \
        -- sleep infinity >/dev/null || return 1
    for check in "${checks[@]}"; do
        _ci_mapfile argv _ci_verify_argv "${check}" || return 2
        [ "${#argv[@]}" -gt 0 ] || return 2
        ci_log "[CI-VERIFY]" "== ${check}"
        if ! docker exec "${name}" bash "${CI_CONTAINER_SH}" workload "${argv[@]}"; then
            failed="${failed} ${check}"
            rc=1
        fi
    done
    if [ "${rc}" -ne 0 ]; then
        ci_log "[CI-ERROR-VERIFY-0006]" "failed in-image checks:${failed}"
    fi
    return "${rc}"
}

# What: Run every verify check: in-image ones, then Redis.
# Why: The Redis check needs its own fresh containers.
# From: Issue #285, Issue #479, PR #544
_ci_verify_all() {
    local image="$1" net="$2" rc=0
    _ci_verify_in_image "${image}" ptrace-selftest build-test samba-configure-dryrun "${net}" || rc=1
    _ci_verify_ccache_redis "${image}" "${net}" || rc=1
    return "${rc}"
}

# What: Two fresh containers build via ccache's Redis backend.
# Why: The second has an empty local cache; a hit is Redis's.
# From: Issue #285, Issue #479, PR #528, PR #544
_ci_verify_ccache_redis() {
    local image="$1" net="$2" redis pass out
    redis="$(_ci_sot_scalar external_services.redis)" || return 2
    # What: Redis gets the maintainer's 2g memory budget.
    # Why: The ccache-remote-storage workload needs about 2GB.
    # From: Issue #479, Issue #285
    _ci_container_run "${redis}" -d --name "${net}-redis" --network-alias redis \
        --memory=2g -- >/dev/null || return 1
    if ! _ci_wait_until 30 1 _ci_container_logged "${net}-redis" 'Ready to accept connections'; then
        ci_log "[CI-ERROR-VERIFY-0004]" "Redis backend did not become ready within 30s"
        return 1
    fi
    for pass in first second; do
        out="${RUNNER_TEMP:-/tmp}/${net}-${pass}.log"
        if ! _ci_container_run "${image}" -e CCACHE_REMOTE_STORAGE=redis://redis:6379 -- \
            bash "${CI_CONTAINER_SH}" workload checkout build /tmp/checkout > "${out}" 2>&1; then
            ci_log "[CI-ERROR-VERIFY-0003]" "ccache/Redis ${pass} build failed"
            cat "${out}" >&2
            return 1
        fi
    done
    if ! grep -qE "${CI_CCACHE_HIT_RE}" "${out}"; then
        ci_log "[CI-ERROR-VERIFY-0002]" "no ccache hit in the fresh container; Redis served nothing"
        cat "${out}" >&2
        return 1
    fi
    ci_log "[CI-VERIFY]" "ccache hit in a fresh container, served by the SOT-pinned Redis"
}

# What: Print AG-GH-014's allowed types or scopes.
# Why: The rule is the one taxonomy owner; no checker copy.
# From: Issue #479, PR #544
_ci_title_taxonomy() {
    local kind="$1" key line list
    case "${kind}" in
        types) key="allowed types MUST remain " ;;
        scopes) key="optional lowercase scopes MUST remain " ;;
        *) ci_log "[CI-ERROR-META-TITLE-0003]" "unknown taxonomy kind=\"${kind}\" (types|scopes)"; return 2 ;;
    esac
    if ! line="$(grep -F -- '**[AG-GH-014]**' "${CI_REPO_ROOT}/AGENTS.md")"; then
        ci_log "[CI-ERROR-META-TITLE-0004]" "AGENTS.md has no [AG-GH-014] rule"
        return 2
    fi
    list="${line#*"${key}"}"
    if [ "${list}" = "${line}" ]; then
        ci_log "[CI-ERROR-META-TITLE-0005]" "[AG-GH-014] has no \"${key% }\" list"
        return 2
    fi
    list="$(grep -o -E "\`[a-z-]+\`" <<< "${list%%;*}" | tr -d "\`" | tr '\n' ' ')" || {
        ci_log "[CI-ERROR-META-TITLE-0006]" "[AG-GH-014] ${kind} list is empty"
        return 2
    }
    printf '%s\n' "${list% }"
}

# What: AG-GH-014 title shape: type, (scope), !, subject.
# Why: The title check and the category labels parse alike.
# From: Issue #479, PR #544
CI_TITLE_RE='^([a-zA-Z]+)(\(([a-z0-9-]+)\))?(!)?:[[:space:]](.+)$'

# What: Print the type of an AG-GH-014 title; rc 1 if none.
# Why: A title that is not type(scope)!: subject has no type.
# From: Issue #479, PR #544
_ci_title_type() {
    [[ "$1" =~ ${CI_TITLE_RE} ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

# What: Validate a PR title against the AG-GH-014 taxonomy.
# Why: Warn mode and drafts only warn; block mode fails.
# From: Issue #479
_ci_check_pr_title() {
    local title="${PR_TITLE:-}"
    local mode="${PR_TITLE_LINT_MODE:-warn}" draft="${PR_DRAFT:-false}"
    if [ -z "${title}" ]; then
        ci_log "[CI-ERROR-META-TITLE-0001]" "no PR title provided"
        return 1
    fi
    title="${title%$'\r'}"
    title="$(printf '%s' "${title}" | sed 's/[[:space:]]*$//')" || return 2
    local types scopes errs=() t sc subj tsub
    types="$(_ci_title_taxonomy types)" || return 2
    scopes="$(_ci_title_taxonomy scopes)" || return 2
    if [[ "${title}" =~ ${CI_TITLE_RE} ]]; then
        t="${BASH_REMATCH[1]}"; sc="${BASH_REMATCH[3]}"; subj="${BASH_REMATCH[5]}"
        tsub="$(printf '%s' "${subj}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" || return 2
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
    local msg="PR title check failed (AG-GH-014): '${title}'" e
    for e in "${errs[@]}"; do msg="${msg}; ${e}"; done
    if [ "${draft}" = "true" ] || [ "${mode}" = "warn" ]; then
        ci_log "[CI-WARN-META-TITLE]" "${msg} (non-blocking)"
        return 0
    fi
    ci_log "[CI-ERROR-META-TITLE-0002]" "${msg}"
    return 1
}

# What: True if this PR is a member of the target project.
# Why: Queried from the PR side; no board-size page limit.
# From: Issue #479, PR #544
_ci_pr_on_project_board() {
    : "${PROJECT_PAT:?PROJECT_PAT required}"
    : "${PROJECT_NUMBER:?PROJECT_NUMBER required}"
    : "${PROJECT_OWNER:?PROJECT_OWNER required}"
    : "${PR_NUMBER:?PR_NUMBER required}"
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    local title items
    title="$(GH_TOKEN="${PROJECT_PAT}" gh project view "${PROJECT_NUMBER}" \
        --owner "${PROJECT_OWNER}" --format json --jq '.title')" || return 2
    items="$(GH_TOKEN="${PROJECT_PAT}" gh pr view "${PR_NUMBER}" \
        --repo "${GITHUB_REPOSITORY}" --json projectItems)" || return 2
    printf '%s' "${items}" | jq -e --arg t "${title}" \
        '.projectItems[]? | select(.title == $t)' >/dev/null
}

# What: Board sub-check; fails once a PAT is set.
# Why: AG-GH-002 lets it warn only while no PAT exists.
# From: Issue #479, PR #544
_ci_check_pr_board() {
    if [ -z "${PROJECT_PAT:-}" ]; then
        ci_log "[CI-META-BOARD]" "skipped: PROJECT_AUTOMATION_PAT not configured"
        return 0
    fi
    _ci_project_board_load || return 2
    local board_status=0
    _ci_pr_on_project_board || board_status=$?
    case "${board_status}" in
        0) ci_log "[CI-META-BOARD]" "OK: on project board #${PROJECT_NUMBER}"; return 0 ;;
        2) ci_log "[CI-ERROR-META-BOARD-0001]" "project-board lookup failed (token invalid/expired?)" ;;
        *) ci_log "[CI-ERROR-META-BOARD-0002]" "not on project board #${PROJECT_NUMBER} (${PROJECT_OWNER})" ;;
    esac
    return 1
}

# What: Labels/milestone/board checks per AG-GH-002.
# Why: AG-GH-002 makes labels and a milestone blocking.
# From: Issue #479, PR #544
_ci_check_pr_tracking() {
    local errs=()
    local pr_labels="${PR_LABELS:-}"
    [ -n "${pr_labels//[[:space:]]/}" ] || errs+=("no labels set")
    [ -n "${PR_MILESTONE_TITLE:-}" ] || errs+=("no milestone set")
    _ci_check_pr_board || errs+=("not on project board")
    if [ "${#errs[@]}" -eq 0 ]; then
        ci_log "[CI-META-TRACKING]" "OK: labels and milestone set; board as logged above"
        return 0
    fi
    local msg="PR tracking metadata failed (AG-GH-002)" e
    for e in "${errs[@]}"; do msg="${msg}; ${e}"; done
    if [ "${PR_DRAFT:-false}" = "true" ]; then
        ci_log "[CI-META-TRACKING]" "draft, non-blocking: ${msg}"
        return 0
    fi
    ci_log "[CI-ERROR-META-TRACKING-0001]" "${msg}"
    return 1
}

# What: Require a CHANGELOG.md change or its opt-out label.
# Why: Every user-facing change needs a changelog entry.
# From: Issue #479
_ci_check_changelog() {
    case " ${PR_LABELS:-} " in
        *" no-changelog-needed "*)
            ci_log "[CI-META-CHANGELOG]" "skipped: no-changelog-needed label"
            return 0 ;;
    esac
    local changed fork rc=0
    # What: Diff from the merge base, the PR's own changes only.
    # Why: A base tip that gained a CHANGELOG entry must not pass.
    # From: Issue #479, PR #544
    if ! fork="$(git -C "${CI_REPO_ROOT}" merge-base "${BASE:?BASE required}" "${HEAD:-HEAD}")"; then
        ci_log "[CI-ERROR-META-CHANGELOG-0002]" "no merge base of ${BASE} and ${HEAD:-HEAD}"
        return 1
    fi
    changed="$(_ci_changed_paths "${fork}" "${HEAD:-HEAD}")" || return 1
    grep -qx 'CHANGELOG.md' <<< "${changed}" || rc=$?
    [ "${rc}" -le 1 ] || return 1
    if [ "${rc}" -eq 0 ]; then
        ci_log "[CI-META-CHANGELOG]" "OK: CHANGELOG.md touched"
        return 0
    fi
    ci_log "[CI-ERROR-META-CHANGELOG-0001]" "no CHANGELOG.md change and no no-changelog-needed label"
    return 1
}

# What: Fetch one PR's live title/labels/tracking fields.
# Why: An event snapshot goes stale (AG-GH-002, AG-GH-014).
# From: Issue #479
_ci_metadata_fetch_live() {
    : "${PR_NUMBER:?PR_NUMBER required}"
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    local json
    json="$(gh pr view "${PR_NUMBER}" --repo "${GITHUB_REPOSITORY}" \
        --json title,labels,milestone,isDraft)" || return 2
    PR_TITLE="$(jq -er '.title' <<< "${json}")" || return 2
    PR_LABELS="$(jq -er '[.labels[].name] | join(" ")' <<< "${json}")" || return 2
    PR_MILESTONE_TITLE="$(jq -er '.milestone.title // ""' <<< "${json}")" || return 2
    PR_DRAFT="$(jq -r '.isDraft | if type == "boolean" then . else error("isDraft") end' <<< "${json}")" || return 2
}

# What: Set PR_NUMBER, BASE, HEAD from the pull_request event.
# Why: Only a pull_request run has a PR context to check.
# From: Issue #479, PR #544
_ci_metadata_pr() {
    local range=()
    case "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME required}" in
        pull_request)
            PR_NUMBER="$(_ci_event_value .pull_request.number)" || return 2
            _ci_mapfile range _ci_event_range || return 2
            [ "${#range[@]}" -eq 2 ] || return 2
            BASE="${range[0]}" HEAD="${range[1]}" ;;
        *)
            ci_log "[CI-ERROR-META-0002]" "no pull request context in a ${GITHUB_EVENT_NAME} run"
            return 2 ;;
    esac
}

# What: Runs metadata check(s); fetches live PR data first.
# Why: One PR-context gate for title, tracking and changelog.
# From: Issue #479
ci_cmd_metadata() {
    local sub="${1:-all}" rc=0
    case "${sub}" in
        title|tracking|changelog|all) ;;
        *) ci_log "[CI-ERROR-META-0001]" "unknown metadata check=\"${sub}\""; return 2 ;;
    esac
    _ci_metadata_pr || return
    _ci_metadata_fetch_live || return 2
    case "${sub}" in
        title)     _ci_check_pr_title || rc=1 ;;
        tracking)  _ci_check_pr_tracking || rc=1 ;;
        changelog) _ci_check_changelog || rc=1 ;;
        all)
            _ci_check_pr_title || rc=1
            _ci_check_pr_tracking || rc=1
            _ci_check_changelog || rc=1 ;;
    esac
    return "${rc}"
}

# What: Log each non-empty stdin line as one guard hit.
# Why: Every guard reports alike; any hit fails the guard.
# From: Issue #479, PR #544
_ci_guard_hits() {
    local id="$1" prefix="${2:-}" suffix="${3:-}" hit rc=0
    while IFS= read -r hit; do
        [ -n "${hit}" ] || continue
        rc=1
        ci_log "${id}" "${prefix}${hit}${suffix}"
    done
    return "${rc}"
}

# What: Fail with id $1 unless every path $2.. is readable.
# Why: A guard on a missing input must fail with an id.
# From: Issue #479, PR #544
_ci_guard_readable() {
    local id="$1" p rc=0
    shift
    if [ "$#" -eq 0 ]; then
        ci_log "${id}" "no input path given"
        return 2
    fi
    for p in "$@"; do
        if [ ! -r "${p}" ]; then
            ci_log "${id}" "input ${p} does not exist or is not readable"
            rc=2
        fi
    done
    return "${rc}"
}

# What: Fail if any file under root contains a CR byte.
# Why: CRLF breaks shell and heredoc parsing in CI files.
# From: Issue #479
ci_guard_line_endings() {
    local root="${1:-${CI_REPO_ROOT}/.github}" hits
    _ci_guard_readable "[CI-ERROR-GUARD-EOL-0002]" "${root}" || return 2
    hits="$(find "${root}" -type f -exec awk '/\r/ { print FILENAME; nextfile }' {} +)" || return 2
    _ci_guard_hits "[CI-ERROR-GUARD-EOL-0001]" "CR/CRLF found: " <<< "${hits}"
}

# What: Print AG-CODE-001 violations of one '#'-comment file.
# Why: Prose comments are What/Why/From lines of 60 chars.
# From: Issue #479, PR #544
_ci_comment_violations() {
    awk -v F="$1" -v q="'" '
        BEGIN { hd = "(^|[ \t(])<<-?[ ]*[\"" q "]?[A-Za-z_][A-Za-z0-9_]*[\"" q "]?([ \t;|&)]|$)" }
        function flush(   i, nwhat, nwhy, nfrom) {
            nwhat = nwhy = nfrom = 0
            for (i = 1; i <= np; i++) {
                if (kind[i] == "") print F ":" pno[i] ": not a What/Why/From line"
                else if (kind[i] == "What") nwhat++
                else if (kind[i] == "Why") nwhy++
                else nfrom++
            }
            if (np > 0 && (nwhat != 1 || nwhy != 1 || nfrom > 1))
                print F ":" pno[1] ": block needs one What, one Why, at most one From"
            np = 0
        }
        term != "" { if ($0 ~ ("^[ \t]*" term "$")) term = ""; next }
        {
            s = $0; sub(/^[ \t]+/, "", s)
            if (substr(s, 1, 1) != "#") {
                if (np == 0 && s ~ /^([A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{|@test "[^"]*"[ \t]*\{)/)
                    print F ":" NR ": function without a comment block above"
                flush()
                l = $0; gsub(/<<</, "", l)
                if (match(l, hd)) {
                    term = substr(l, RSTART, RLENGTH); tline = NR
                    sub(/^[ \t(]*<<-?[ ]*/, "", term); sub(/[ \t;|&)]$/, "", term)
                    gsub("[\"" q "]", "", term)
                }
                next
            }
            if (s ~ /^#!/ || s ~ /^#[ ]*(shellcheck |syntax=|SPDX-License-Identifier:)/) next
            if (index(s, "# distcc-ng (https://") == 1) next
            np++; pno[np] = NR; kind[np] = ""
            if (s ~ /^#[ ]?(What|Why|From):[ ]/) {
                body = s; sub(/^#[ ]?/, "", body)
                kind[np] = substr(body, 1, index(body, ":") - 1)
                if (length(body) > 60) print F ":" NR ": longer than 60 characters"
                if (kind[np] == "From" && body !~ /^From: (Issue|PR) #[0-9]+( #[0-9]+)*(, (Issue|PR) #[0-9]+( #[0-9]+)*)*$/)
                    print F ":" NR ": From names something not an Issue or PR"
            }
        }
        END {
            flush()
            if (term != "") print F ":" tline ": heredoc " term " never ends"
        }
    ' "$1"
}

# What: Print each CI_OWNED_PATHS entry present under root $1.
# Why: An absent owned path is reported NotRun, never skipped.
# From: Issue #479, PR #544
_ci_owned_paths_in() {
    local d
    for d in ${CI_OWNED_PATHS}; do
        if [ -e "$1/${d}" ]; then
            printf '%s\n' "${d}"
        else
            ci_log "[CI-LINT]" "NotRun: ${d} absent under $1"
        fi
    done
}

# What: Fail on malformed or missing What/Why/From blocks.
# Why: #479's comment guard; AG-CODE-001 defines the form.
# From: Issue #479, PR #544
ci_guard_comment_format() {
    local root="${1:-${CI_REPO_ROOT}}" rc=0 f out d
    local files=() found=() owned=()
    _ci_guard_readable "[CI-ERROR-GUARD-COMMENT-0003]" "${root}" || return 2
    _ci_mapfile owned _ci_owned_paths_in "${root}" || return 2
    for d in "${owned[@]}"; do
        _ci_mapfile found find "${root}/${d}" -type f \( -name '*.sh' \
            -o -name '*.bats' -o -name '*.yml' -o -name '*.yaml' -o -name 'Dockerfile*' \) || return 2
        files+=("${found[@]}")
    done
    if [ "${#files[@]}" -eq 0 ]; then
        ci_log "[CI-ERROR-GUARD-COMMENT-0002]" "no file to check under ${root} (${CI_OWNED_PATHS})"
        return 2
    fi
    for f in "${files[@]}"; do
        out="$(_ci_comment_violations "${f}")" || return 2
        _ci_guard_hits "[CI-ERROR-GUARD-COMMENT-0001]" <<< "${out}" || rc=1
    done
    return "${rc}"
}

# What: Print every shell source under root, by name or #!.
# Why: The ShellCheck directive ban covers all shell code.
# From: Issue #479, PR #544
_ci_shell_sources() {
    find "$1" -path "$1/.git" -prune -o -type f -exec awk '
        FNR == 1 {
            if (FILENAME ~ /\.(sh|bats)$/ \
                || $0 ~ /^#![^ \t]*\/(env[ \t]+)?(ba|da|k|z|a)?sh([ \t]|$)/ \
                || $0 ~ /^#![^ \t]*\/openrc-run([ \t]|$)/) print FILENAME
            nextfile
        }' {} +
}

# What: Print the SOT's banned shell texts, one per line.
# Why: The SOT owns the list; ci.sh holds no copy of it.
# From: Issue #479, PR #544
_ci_banned_shell_texts() {
    local texts
    texts="$(_ci_sot_list ci_engine.banned_shell_texts)" || return 2
    if [ -z "${texts}" ]; then
        ci_log "[CI-ERROR-GUARD-SHELLCHECK-0003]" "ci_engine.banned_shell_texts names no text"
        return 2
    fi
    printf '%s\n' "${texts}"
}

# What: Fail on any SOT-banned text in a shell source.
# Why: AG-INT-003: a silenced warning is itself a violation.
# From: Issue #479, PR #544
ci_guard_shellcheck_directives() {
    local root="${1:-${CI_REPO_ROOT}}" texts out
    local files=()
    _ci_guard_readable "[CI-ERROR-GUARD-SHELLCHECK-0005]" "${root}" || return 2
    texts="$(_ci_banned_shell_texts)" || return 2
    _ci_mapfile files _ci_shell_sources "${root}" || return 2
    if [ "${#files[@]}" -eq 0 ]; then
        ci_log "[CI-ERROR-GUARD-SHELLCHECK-0004]" "no shell source under ${root}"
        return 2
    fi
    out="$(CI_BANNED="${texts}" awk 'BEGIN { n = split(ENVIRON["CI_BANNED"], b, "\n") }
        { for (i = 1; i <= n; i++) if (index($0, b[i])) print FILENAME ":" FNR ": banned shell text " b[i] }
        ' "${files[@]}")" || return 2
    _ci_guard_hits "[CI-ERROR-GUARD-SHELLCHECK-0001]" <<< "${out}"
}

# What: Fail on any sha256 digest not 64 lowercase hex.
# Why: Full-length SHAs only; no abbreviated forms.
# From: Issue #479
ci_guard_full_sha() {
    local root="${1:-${CI_REPO_ROOT}/.github}" hits bad
    _ci_guard_readable "[CI-ERROR-GUARD-SHA-0002]" "${root}" || return 2
    hits="$(find "${root}" -type f -exec awk '{
        while (match($0, /sha256:[0-9a-fA-F]+/)) {
            print substr($0, RSTART, RLENGTH); $0 = substr($0, RSTART + RLENGTH)
        } }' {} +)" || return 2
    bad="$(awk -F: "length(\$2) != 64 || \$2 ~ /[A-F]/ { print }" <<< "${hits}")" || return 2
    _ci_guard_hits "[CI-ERROR-GUARD-SHA-0001]" "not a full 64-hex sha256: " <<< "${bad}"
}

# What: Print "line kind ref" per pin-shaped Dockerfile line.
# Why: Digests, ARG defaults, pulled FROMs bypass the SOT.
# From: Issue #479, PR #544
_ci_dockerfile_pins() {
    awk '
        /@sha256:/ { print NR " digest -" }
        /^[[:space:]]*ARG[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=/ { print NR " arg-default -" }
        toupper($1) == "FROM" {
            i = 2
            while ($i ~ /^--/) i++
            ref = $i
            if (ref !~ /^[$][{]?[A-Za-z_]/ && !(ref in stage) && ref !~ /^[a-z0-9._-]+:local$/)
                print NR " from " ref
            if (tolower($(i + 1)) == "as") stage[$(i + 2)] = 1
        }
    ' "$1"
}

# What: Fail if a YAML literal no longer mirrors the SOT.
# Why: Crons, choices, milestones are literals; SOT owns them.
# From: Issue #479, PR #544
ci_guard_sot_mirrors() {
    local root="${1:-${CI_REPO_ROOT}}" rc=0 f wf names n want got pkgs num
    _ci_guard_readable "[CI-ERROR-GUARD-MIRROR-0011]" "${root}" || return 2
    want=""
    names="$(_ci_sot_children schedules)" || return 2
    for n in ${names}; do
        want+="$(_ci_sot_scalar "schedules.${n}.workflow")" || return 2
        want+=" $(_ci_sot_scalar "schedules.${n}.cron")"$'\n' || return 2
    done
    got=""
    for f in "${root}"/.github/workflows/*.yml; do
        [ -f "${f}" ] || continue
        wf="$(basename "${f}" .yml)" || return 2
        got+="$(sed -n "s/^ *- cron: '\(.*\)'\$/${wf} \1/p" "${f}")"$'\n' || return 2
    done
    want="$(awk 'NF' <<< "${want}" | sort)" || return 2
    got="$(awk 'NF' <<< "${got}" | sort)" || return 2
    _ci_guard_mirror "[CI-ERROR-GUARD-MIRROR-0001]" "on.schedule crons differ from SOT schedules" \
        "${want}" "${got}" || rc=$?
    [ "${rc}" -ne 2 ] || return 2
    f="${root}/.github/workflows/housekeeping.yml"
    if [ -f "${f}" ]; then
        pkgs="$({ echo all; _ci_sot_list release.ghcr_packages; } | sort)" || return 2
        got="$(_ci_dispatch_options "${f}" package | sort)" || return 2
        _ci_guard_mirror "[CI-ERROR-GUARD-MIRROR-0002]" \
            "housekeeping package options differ from all + release.ghcr_packages" "${pkgs}" "${got}" \
            || rc=$?
        [ "${rc}" -ne 2 ] || return 2
        want="$(_ci_sot_children housekeeping_tasks | sort)" || return 2
        got="$(_ci_dispatch_options "${f}" task | sort)" || return 2
        _ci_guard_mirror "[CI-ERROR-GUARD-MIRROR-0004]" \
            "housekeeping task options differ from housekeeping_tasks" "${want}" "${got}" || rc=$?
        [ "${rc}" -ne 2 ] || return 2
    fi
    f="${root}/.github/dependabot.yml"
    if [ -f "${f}" ]; then
        num="$(_ci_sot_scalar bot_milestone.number)" || return 2
        got="$(awk '
            /^  - package-ecosystem:/ { if (n) print (ms == "" ? "none" : ms); n++; ms = "" }
            /^    milestone:/ { ms = $2 }
            END { if (n) print (ms == "" ? "none" : ms) }
        ' "${f}")" || return 2
        want=""
        if [ -n "${got}" ]; then
            want="$(awk -v w="${num}" '{ print w }' <<< "${got}")" || return 2
        fi
        _ci_guard_mirror "[CI-ERROR-GUARD-MIRROR-0003]" \
            "dependabot.yml milestones differ from bot_milestone.number" "${want}" "${got}" || rc=$?
        [ "${rc}" -ne 2 ] || return 2
    fi
    f="${root}/.github/workflows/validate.yml"
    if [ -f "${f}" ]; then
        got="$(_ci_unwired_phases "${f}")" || return 2
        _ci_guard_hits "[CI-ERROR-GUARD-MIRROR-0009]" "SOT phase " " gates no validate.yml job running it" \
            <<< "${got}" || rc=1
    else
        ci_log "[CI-LINT]" "NotRun: ${f} absent"
    fi
    f="${root}/.clusterfuzzlite/Dockerfile"
    if [ -f "${f}" ]; then
        want="$(_ci_sot_scalar security.cfl_base.tag)" || return 2
        if ! grep -qxF -- "FROM ${want}" "${f}"; then
            ci_log "[CI-ERROR-GUARD-MIRROR-0010]" "${f} has no FROM ${want} (security.cfl_base.tag)"
            rc=1
        fi
    else
        ci_log "[CI-LINT]" "NotRun: ${f} absent"
    fi
    return "${rc}"
}

# What: Print each SOT phase no gated job of workflow $1 runs.
# Why: A phase nobody runs is policy that changes nothing.
# From: Issue #479, PR #544
_ci_unwired_phases() {
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

# What: Print the choice options of input $2 in workflow $1.
# Why: Mirror checks read every choice list one way.
# From: Issue #479, PR #544
_ci_dispatch_options() {
    awk -v name="$2" '
        $0 == "      " name ":" { inpkg = 1; next }
        inpkg && /^      [A-Za-z0-9_-]+:$/ { exit }
        inpkg && /^        options:$/ { inopt = 1; next }
        inopt && /^          - / { sub(/^          - /, ""); print; next }
        inopt { exit }
    ' "$1"
}

# What: Fail if a Dockerfile or SOT literal drifts from ci.sh.
# Why: A Dockerfile cannot read ci.sh; it repeats the values.
# From: Issue #479, PR #544
ci_guard_path_mirrors() {
    local root="${1:-${CI_REPO_ROOT}}" rc=0 f out names refs ref
    local files=()
    _ci_guard_readable "[CI-ERROR-GUARD-MIRROR-0012]" "${root}" || return 2
    _ci_mapfile files find "${root}" -name Dockerfile -type f -not -path '*/.git/*' || return 2
    for f in "${files[@]}"; do
        out="$(awk -v want="${CI_CONTAINER_ROOT}" '
            { l = $0
              while (match(l, /--mount=type=bind,target=[^ ,]+/)) {
                  t = substr(l, RSTART + 25, RLENGTH - 25)
                  if (t != want) print FNR ": bind target " t " is not " want
                  l = substr(l, RSTART + RLENGTH) } }' "${f}")" || return 2
        _ci_guard_hits "[CI-ERROR-GUARD-MIRROR-0005]" "${f}:" <<< "${out}" || rc=1
    done
    f="${root}/docker/release/Dockerfile"
    if [ -f "${f}" ]; then
        out="$(awk -v a="${CI_RELEASE_OUT}/" -v b="${CI_RELEASE_PUMP_OUT}/" '
            $1 == "COPY" && $2 == "--from=build" {
                if (index($3, a) == 1) ha = 1
                else if (index($3, b) == 1) hb = 1
                else print FNR ": COPY source " $3 " is no ci.sh release tree" }
            END { if (!ha) print "no COPY from " a; if (!hb) print "no COPY from " b }' "${f}")" || return 2
        _ci_guard_hits "[CI-ERROR-GUARD-MIRROR-0006]" "${f}: " <<< "${out}" || rc=1
    else
        ci_log "[CI-LINT]" "NotRun: ${f} absent"
    fi
    f="${root}/.clusterfuzzlite/Dockerfile"
    if [ -f "${f}" ]; then
        out="$(awk -v want="\$SRC/${CI_CFL_PROJECT}" '
            $1 == "COPY" && $2 == "." { seen = 1; if ($3 != want) print FNR ": COPY target " $3 " is not " want }
            END { if (!seen) print "no COPY . " want }' "${f}")" || return 2
        _ci_guard_hits "[CI-ERROR-GUARD-MIRROR-0007]" "${f}: " <<< "${out}" || rc=1
    else
        ci_log "[CI-LINT]" "NotRun: ${f} absent"
    fi
    names="$(_ci_sot_children release.images)" || return 2
    refs=""
    for f in ${names}; do
        ref="$(_ci_sot_optional "release.images.${f}.ref")" || return 2
        [ -z "${ref}" ] || [ "${ref#"${CI_REGISTRY}/"}" != "${ref}" ] || refs+="release.images.${f}.ref=${ref}"$'\n'
    done
    _ci_guard_hits "[CI-ERROR-GUARD-MIRROR-0008]" "" " is not in ${CI_REGISTRY}" <<< "${refs}" || rc=1
    return "${rc}"
}

# What: Fail with a diff when a YAML literal list drifts.
# Why: Both mirror checks report want vs got the same way.
# From: Issue #479, PR #544
_ci_guard_mirror() {
    local id="$1" what="$2" want="$3" got="$4" d
    [ "${want}" != "${got}" ] || return 0
    d="$(CI_WANT="${want}" CI_GOT="${got}" awk 'BEGIN {
        n = split(ENVIRON["CI_WANT"], w, "\n"); for (i = 1; i <= n; i++) inw[w[i]] = 1
        m = split(ENVIRON["CI_GOT"], g, "\n"); for (i = 1; i <= m; i++) ing[g[i]] = 1
        for (i = 1; i <= n; i++) if (!(w[i] in ing)) print "< " w[i]
        for (i = 1; i <= m; i++) if (!(g[i] in inw)) print "> " g[i]
    }')" || return 2
    ci_error "${id}" "${what}" "${d}"
    return 1
}

# What: Print each SOT action as its exact uses: value.
# Why: uses: takes no expression; YAML repeats this literal.
# From: Issue #479, PR #544
_ci_action_pins() {
    local names a uses ver
    names="$(_ci_sot_children ci_engine.actions)" || return 2
    for a in ${names}; do
        uses="$(_ci_sot_scalar "ci_engine.actions.${a}.uses")" || return 2
        ver="$(_ci_sot_scalar "ci_engine.actions.${a}.version")" || return 2
        printf '%s # %s\n' "${uses}" "${ver}"
    done
}

# What: Fail on a pin outside the SOT or an unused SOT action.
# Why: The SOT is the sole pin owner; uses: lines mirror it.
# From: Issue #479, PR #544
ci_guard_pins_in_sot() {
    local root="${1:-${CI_REPO_ROOT}}" rc=0 f out pins pin unused=""
    local files=() wfs=()
    _ci_guard_readable "[CI-ERROR-GUARD-PIN-0006]" "${root}" || return 2
    for f in "${root}"/.github/workflows/*.yml; do
        [ -f "${f}" ] || continue
        wfs+=("${f}")
        # What: uses: lines belong to the orchestrator guard.
        # Why: It matches each one against the SOT action pins.
        # From: Issue #479, PR #544
        out="$(awk '
            /^[[:space:]]*(-[[:space:]]+)?uses:/ { next }
            /@sha256:/ || /^    +(image|container):/ { print FNR; next }
            { l = $0
              while (match(l, /@[0-9a-f]+/)) {
                  if (RLENGTH >= 41) { print FNR; next }
                  l = substr(l, RSTART + RLENGTH) } }' "${f}")" || return 2
        _ci_guard_hits "[CI-ERROR-GUARD-PIN-0001]" "${f}:" ": image or action pin outside the SOT" \
            <<< "${out}" || rc=1
    done
    pins="$(_ci_action_pins)" || return 2
    while IFS= read -r pin; do
        [ -n "${pin}" ] || continue
        if [ "${#wfs[@]}" -eq 0 ] || ! grep -qF -- "uses: ${pin}" "${wfs[@]}"; then
            unused+="${pin}"$'\n'
        fi
    done <<< "${pins}"
    _ci_guard_hits "[CI-ERROR-GUARD-PIN-0003]" "SOT action " " is used by no workflow" <<< "${unused}" || rc=1
    _ci_mapfile files find "${root}" -name Dockerfile -type f -not -path '*/.git/*' || return 2
    for f in "${files[@]}"; do
        out="$(_ci_dockerfile_pins "${f}" | sed 's/ /: /')" || return 2
        _ci_guard_hits "[CI-ERROR-GUARD-PIN-0002]" "${f}:" " bypasses the SOT ARG" \
            <<< "${out}" || rc=1
    done
    return "${rc}"
}

# What: Fail on a SOT image pin or tool pin of the wrong form.
# Why: No tag, no refresh; no digest or sha256, no check.
# From: Issue #479, PR #544
ci_guard_sot_pins() {
    local s k v keys bad="" rc=0
    for s in base_images external_services; do
        keys="$(_ci_sot_children "${s}")" || return 2
        for k in ${keys}; do
            v="$(_ci_sot_scalar "${s}.${k}")" || return 2
            _ci_pin_tracked "${v}" || bad+="${s}.${k}=${v}"$'\n'
        done
    done
    _ci_guard_hits "[CI-ERROR-GUARD-PIN-0004]" "" " is not name:tag@sha256:<64 hex>" <<< "${bad}" || rc=1
    bad=""
    keys="$(_ci_sot_children external_versions)" || return 2
    for k in ${keys}; do
        v="$(_ci_sot_optional "external_versions.${k}.url")" || return 2
        [ -n "${v}" ] || continue
        v="$(_ci_sot_optional "external_versions.${k}.sha256")" || return 2
        [[ "${v}" =~ ^[0-9a-f]{64}$ ]] || bad+="external_versions.${k}"$'\n'
    done
    _ci_guard_hits "[CI-ERROR-GUARD-PIN-0005]" "" " has a url but no 64-hex sha256" <<< "${bad}" || rc=1
    return "${rc}"
}

# What: Print orchestrator violations in run: and uses: steps.
# Why: run: calls one ci.sh command; uses: only transports.
# From: Issue #479, PR #544
_ci_scan_run_blocks() {
    awk -v F="$1" -v allowed="$2" '
        function flag(r){ print F":"NR": "r }
        BEGIN { n = split(allowed, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") ok[a[i]] = 1 }
        /^[ ]*(- )?uses:[ ]/ {
            match($0, /^[ ]*(- )?/); uind = RLENGTH
            ref = $0; sub(/^[ ]*(- )?uses:[ ]+/, "", ref); sub(/[ ]+$/, "", ref)
            if (!(ref in ok)) flag("uses: " ref " is not an SOT action pin")
            instep = 1; inwith = 0; inrun = 0; next
        }
        instep && $0 !~ /^[ ]*$/ {
            match($0, /^[ ]*/); ind = RLENGTH
            if (ind < uind || $0 ~ /^[ ]*- /) { instep = 0; inwith = 0 }
            else if (ind == uind) { inwith = ($0 ~ /^[ ]*with:[ ]*$/); next }
            else if (inwith) {
                # What: A uses: input must forward one ci.sh output.
                # Why: Keys, paths and names are ci.sh decisions.
                # From: Issue #479, PR #544
                v = $0; sub(/^[ ]*[A-Za-z0-9_-]+:[ ]*/, "", v)
                mid = substr(v, 11, length(v) - 13)
                if (substr(v, 1, 10) != "${{ steps." || substr(v, length(v) - 2) != " }}" \
                    || mid !~ /^[A-Za-z0-9_-]+\.outputs\.[A-Za-z0-9_]+$/)
                    flag("uses: input is not a ci.sh step output: " v)
                next
            }
            else next
        }
        { match($0,/^[ ]*/); ind=RLENGTH
          if (inrun && $0 !~ /^[ ]*$/ && ind <= runind) inrun=0
          if ($0 ~ /^[ ]*(- )?run:[ ]*[|>]/) { inrun=1; runind=ind; next }
          scan = ($0 ~ /^[ ]*(- )?run:[ ]/) || inrun
          if (!scan) next
          l=$0
          # What: Exempt the checkout bootstrap pipe.
          # Why: ci.sh is not on disk at this exact line.
          # From: Issue #479
          if (l ~ /curl -fsSL[^|]*\.github\/scripts\/ci\.sh" \| bash -s -- checkout/) next
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

# What: Fail on step logic or an action outside the SOT.
# Why: Logic belongs in ci.sh; workflows only orchestrate.
# From: Issue #479, PR #544
ci_guard_orchestrator_only() {
    local rc=0 f pins out
    pins="$(_ci_action_pins)" || return 2
    _ci_guard_readable "[CI-ERROR-GUARD-ORCH-0002]" "$@" || return 2
    for f in "$@"; do
        out="$(_ci_scan_run_blocks "${f}" "${pins}")" || return 2
        _ci_guard_hits "[CI-ERROR-GUARD-ORCH-0001]" <<< "${out}" || rc=1
    done
    return "${rc}"
}

# What: Fail on a workflow job with no timeout-minutes.
# Why: Unbounded, a hung job runs to the 6-hour default.
# From: Issue #479, PR #544
ci_guard_job_timeouts() {
    local out
    _ci_guard_readable "[CI-ERROR-GUARD-TIME-0002]" "$@" || return 2
    out="$(awk '
        FNR == 1 { if (cur != "" && !t) print F " " cur; F = FILENAME; j = 0; cur = ""; t = 0 }
        /^jobs:/ { j = 1; next }
        j && /^  [A-Za-z0-9_-]+:$/ { if (cur != "" && !t) print F " " cur; cur = substr($1, 1, length($1) - 1); t = 0 }
        j && cur != "" && /^    timeout-minutes: [0-9]+$/ { t = 1 }
        END { if (cur != "" && !t) print F " " cur }
    ' "$@")" || return 2
    _ci_guard_hits "[CI-ERROR-GUARD-TIME-0001]" "" " has no timeout-minutes" <<< "${out}"
}

# What: Fail on a CI-ERROR id that file $1 raises twice.
# Why: Triage greps an id to find the one place it is raised.
# From: Issue #479, PR #544
ci_guard_error_ids() {
    local ids rc=0
    _ci_guard_readable "[CI-ERROR-GUARD-ERRID-0002]" "$@" || return 2
    ids="$(grep -oE 'CI-ERROR-[A-Z0-9-]+-[0-9]{4}' "$1")" || rc=$?
    [ "${rc}" -le 1 ] || return 2
    sort <<< "${ids}" | uniq -d \
        | _ci_guard_hits "[CI-ERROR-GUARD-ERRID-0001]" "" " is raised in more than one place"
}

# What: Run the ci.bats regression suite in parallel.
# Why: The engine tests itself when .github/scripts changes.
# From: Issue #479
ci_cmd_selftest() {
    local jobs
    jobs="$(_ci_jobs)" || return 2
    bats --jobs "${jobs}" "${CI_SCRIPT_DIR}/ci.bats"
}

# What: Run a lint tool in the published buildtools image.
# Why: Lint uses the image CI publishes, not a local rebuild.
# From: Issue #479, PR #544
_ci_lint_run() {
    local image
    image="$(_ci_sot_scalar release.images.distcc-ng-buildtools.ref)" || return 2
    _ci_container_run "${image}" -w "${CI_CONTAINER_ROOT}" -- "$@"
}

# What: Lint every workflow file with actionlint.
# Why: File list built on the host; no nested-shell expansion.
# From: Issue #479
_ci_lint_actionlint() {
    local files=()
    _ci_mapfile files env -C "${CI_REPO_ROOT}" find .github/workflows -name "*.yml" -type f || return 2
    if [ "${#files[@]}" -eq 0 ]; then
        ci_log "[CI-ERROR-LINT-0002]" "no workflow files under .github/workflows to lint"
        return 2
    fi
    _ci_lint_run actionlint -color "${files[@]}"
}

# What: Shellcheck every shell source in the CI-owned tree.
# Why: #479 floor is warning; only *.bats stays at that floor.
# From: Issue #479, PR #544
_ci_lint_shellcheck() {
    local rc=0 d f
    local found=() sh=() bats=() owned=()
    _ci_mapfile owned _ci_owned_paths_in "${CI_REPO_ROOT}" || return 2
    for d in "${owned[@]}"; do
        _ci_mapfile found _ci_shell_sources "${CI_REPO_ROOT}/${d}" || return 2
        for f in "${found[@]}"; do
            case "${f}" in
                *.bats) bats+=("${f#"${CI_REPO_ROOT}"/}") ;;
                *) sh+=("${f#"${CI_REPO_ROOT}"/}") ;;
            esac
        done
    done
    if [ "${#sh[@]}" -eq 0 ] || [ "${#bats[@]}" -eq 0 ]; then
        ci_log "[CI-ERROR-LINT-0003]" "found ${#sh[@]} shell and ${#bats[@]} bats files to shellcheck"
        return 2
    fi
    _ci_lint_run shellcheck -x "${sh[@]}" || rc=1
    _ci_lint_run shellcheck -x --severity=warning "${bats[@]}" || rc=1
    return "${rc}"
}

# What: Run the governance guards over the CI-owned tree.
# Why: One phase enforces the repo's CI hygiene invariants.
# From: Issue #479
ci_cmd_lint() {
    local rc=0 d
    local owned=()
    _ci_mapfile owned _ci_owned_paths_in "${CI_REPO_ROOT}" || return 2
    for d in "${owned[@]}"; do
        ci_guard_line_endings "${CI_REPO_ROOT}/${d}" || rc=1
    done
    # What: Full-SHA scan of the dirs that may carry a pin.
    # Why: Scripts hold none; ci.bats holds test fixtures.
    # From: Issue #479
    for d in .github/workflows .github/yaml docker; do
        if [ ! -e "${CI_REPO_ROOT}/${d}" ]; then
            ci_log "[CI-LINT]" "full-SHA NotRun: ${d} absent"
            continue
        fi
        ci_guard_full_sha "${CI_REPO_ROOT}/${d}" || rc=1
    done
    ci_guard_pins_in_sot "${CI_REPO_ROOT}" || rc=1
    ci_guard_sot_pins || rc=1
    ci_guard_comment_format "${CI_REPO_ROOT}" || rc=1
    ci_guard_shellcheck_directives "${CI_REPO_ROOT}" || rc=1
    ci_guard_sot_mirrors "${CI_REPO_ROOT}" || rc=1
    ci_guard_path_mirrors "${CI_REPO_ROOT}" || rc=1
    # What: Orchestrator, timeout, error-id guards; linters.
    # Why: #479 allows no workflow-local logic, none exempt.
    # From: Issue #479, PR #544
    ci_guard_orchestrator_only "${CI_REPO_ROOT}"/.github/workflows/*.yml || rc=1
    ci_guard_job_timeouts "${CI_REPO_ROOT}"/.github/workflows/*.yml || rc=1
    ci_guard_error_ids "${CI_SCRIPT_DIR}/ci.sh" || rc=1
    _ci_lint_actionlint || rc=1
    _ci_lint_shellcheck || rc=1
    return "${rc}"
}

# What: apt-get update+install, two bounded attempts.
# Why: The default ubuntu mirror can hang with no timeout.
# From: Issue #493, Issue #479
_ci_apt_install() {
    local packages="${1:?package list required}" mode="${2:-runner}" rc=0
    local as_root=(sudo) apt_opts="" upgrade="" limit="3m"
    if [ "$(id -u)" -eq 0 ]; then
        as_root=()
    fi
    # What: Image builds skip recommends and drop the apt lists.
    # Why: Image layers stay minimal; runners keep defaults.
    # From: Issue #479, PR #544
    case "${mode}" in
        runner) ;;
        image)
            apt_opts="--no-install-recommends"
            # What: Image builds full-upgrade the base before installing.
            # Why: Every image gets the packages current at build time.
            # From: Issue #479, PR #544
            upgrade="apt-get full-upgrade -y ${apt_opts} &&"
            # What: An image attempt may take 6 minutes, not 3.
            # Why: CFL's Ubuntu mirror ran 90s green and over 3m red.
            # From: Issue #493, Issue #479, PR #544
            limit="6m" ;;
        *) ci_log "[CI-ERROR-INSTALL-0003]" "apt mode=${mode} (runner|image)"; return 2 ;;
    esac
    _ci_wait_until 2 10 _ci_apt_attempt "${limit}" "${packages}" "${apt_opts}" "${upgrade}" "${as_root[@]}" || rc=$?
    case "${rc}" in
        0) ;;
        1) ci_log "[CI-ERROR-INSTALL-0001]" "apt install failed after 2 attempts"; return 1 ;;
        *) return 1 ;;
    esac
    if [ "${mode}" = "image" ]; then
        rm -rf /var/lib/apt/lists/* || return 1
    fi
}

# What: One bounded apt attempt; repair dpkg before a retry.
# Why: Else every retry stops at "dpkg was interrupted".
# From: Issue #493, Issue #479, PR #544
_ci_apt_attempt() {
    local limit="$1" packages="$2" apt_opts="$3" upgrade="$4" rc=0 why=""
    shift 4
    "$@" timeout -k 10s "${limit}" env DEBIAN_FRONTEND=noninteractive \
        bash -c "apt-get update && ${upgrade} apt-get install -y ${apt_opts} ${packages}" || rc=$?
    if [ "${rc}" -eq 0 ]; then
        return 0
    fi
    [ "${rc}" -ne 124 ] || why=" (timed out after ${limit})"
    ci_log "[CI-INSTALL-APT]" "attempt ${CI_ATTEMPT}/${CI_TRIES}: apt exited ${rc}${why}"
    [ "${CI_ATTEMPT}" -lt "${CI_TRIES}" ] || return 1
    if ! "$@" timeout -k 10s "${limit}" env DEBIAN_FRONTEND=noninteractive dpkg --configure -a; then
        ci_log "[CI-ERROR-INSTALL-0004]" "dpkg --configure -a failed after attempt ${CI_ATTEMPT}"
        return 2
    fi
    return 1
}

# What: brew install for a space-separated package list.
# Why: macOS legs take their SOT brew list in one way.
# From: Issue #479
_ci_brew_install() {
    local packages="${1:?package list required}"
    local -a pkgs
    read -ra pkgs <<< "${packages}"
    brew install "${pkgs[@]}"
}

# What: Dispatch apt|brew|sot-apt dependency installation.
# Why: One owner; workflows call this, never raw apt/brew.
# From: Issue #479
ci_cmd_install() {
    local kind="${1:?apt, brew, or sot-apt required}" arg="${2:?argument required}"
    case "${kind}" in
        apt)     _ci_apt_install "${arg}" ;;
        brew)    _ci_brew_install "${arg}" ;;
        sot-apt)
            local pkgs
            pkgs="$(_ci_sot_scalar "${arg}")" || return 2
            _ci_apt_install "${pkgs}" ;;
        *) ci_log "[CI-ERROR-INSTALL-0002]" "unknown install kind=\"${kind}\""; return 2 ;;
    esac
}

# What: Fetch+checkout the triggering commit via plain git.
# Why: No action, no SHA; ci.sh isn't on disk pre-checkout.
# From: Issue #479
ci_cmd_checkout() {
    local depth="${1:-1}" ref="${2:-${GITHUB_SHA:-}}"
    : "${GITHUB_SERVER_URL:?GITHUB_SERVER_URL required}"
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    : "${ref:?ref required (pass one, or set GITHUB_SHA)}"
    git init -q . || return 1
    git remote add origin "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}" || return 1
    if [ "${depth}" = "0" ]; then
        git fetch -q origin "${ref}" || return 1
    else
        git fetch -q --depth="${depth}" origin "${ref}" || return 1
    fi
    git checkout -q FETCH_HEAD
}

# What: Print the claims of this job's GitHub OIDC token.
# Why: The provenance predicate is built from these claims.
# From: Issue #38, Issue #479, PR #544
_ci_attest_claims() {
    local raw token payload pad
    raw="$(curl -fsS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?no id-token permission}" \
        "${ACTIONS_ID_TOKEN_REQUEST_URL:?no id-token permission}&audience=nobody")" || return 1
    token="$(jq -r '.value' <<< "${raw}")" || return 1
    payload="${token#*.}"
    payload="${payload%%.*}"
    payload="$(tr '_-' '/+' <<< "${payload}")" || return 1
    pad=$(( (4 - ${#payload} % 4) % 4 ))
    while [ "${pad}" -gt 0 ]; do
        payload+="="
        pad=$(( pad - 1 ))
    done
    base64 -d <<< "${payload}"
}

# What: Print the SLSA v1 provenance predicate for this run.
# Why: actions/attest's shape, so gh attestation verify works.
# From: Issue #38, Issue #479, PR #544
_ci_attest_predicate() {
    local claims
    claims="$(_ci_attest_claims)" || return 1
    jq -e -n --argjson c "${claims}" --arg s "${GITHUB_SERVER_URL:?GITHUB_SERVER_URL required}" '
        ($c.workflow_ref | ltrimstr($c.repository + "/") | split("@")[0]) as $path
        | {buildDefinition: {
              buildType: "https://actions.github.io/buildtypes/workflow/v1",
              externalParameters: {workflow: {ref: $c.ref,
                  repository: ($s + "/" + $c.repository), path: $path}},
              internalParameters: {github: {event_name: $c.event_name,
                  repository_id: $c.repository_id, repository_owner_id: $c.repository_owner_id,
                  runner_environment: $c.runner_environment}},
              resolvedDependencies: [{uri: ("git+" + $s + "/" + $c.repository + "@" + $c.ref),
                  digest: {gitCommit: $c.sha}}]},
           runDetails: {builder: {id: ($s + "/" + $c.job_workflow_ref)},
              metadata: {invocationId: ($s + "/" + $c.repository + "/actions/runs/"
                  + $c.run_id + "/attempts/" + $c.run_attempt)}}}'
}

# What: Sign "name sha256" subjects and store them on GitHub.
# Why: One owner; the stored bundle must verify right away.
# From: Issue #38, Issue #479, PR #544
_ci_attest_subjects() {
    local subjects="$1" verify="$2" cosign work
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    : "${GH_TOKEN:?GH_TOKEN required (attestations: write)}"
    cosign="$(_ci_tool_bin external_versions.cosign)" || return 2
    work="$(mktemp -d)" || return 1
    _ci_attest_predicate > "${work}/predicate.json" || return 1
    jq -e -n -R --slurpfile p "${work}/predicate.json" '
        [inputs | select(length > 0) | split(" ") | {name: .[0], digest: {sha256: .[1]}}] as $s
        | {_type: "https://in-toto.io/Statement/v1", subject: $s,
           predicateType: "https://slsa.dev/provenance/v1", predicate: $p[0]}
        | if (.subject | length) == 0 then error("no subject") else . end' \
        <<< "${subjects}" > "${work}/statement.json" || return 1
    _ci_mutate _ci_attest_publish "${cosign}" "${work}" "${verify}" || return 1
    rm -rf "${work}"
}

# What: cosign-sign the statement, store it, verify it back.
# Why: One outward step, so _ci_mutate alone gates a dry run.
# From: Issue #38, Issue #479, PR #544
_ci_attest_publish() {
    local cosign="$1" work="$2" verify="$3"
    "${cosign}" attest-blob --yes --statement "${work}/statement.json" \
        --bundle "${work}/bundle.json" || return 1
    jq -r '.subject[] | "[CI-ATTEST] subject \(.name) sha256:\(.digest.sha256)"' \
        "${work}/statement.json" || return 1
    jq -e '{bundle: .}' "${work}/bundle.json" > "${work}/body.json" || return 1
    gh api --method POST "repos/${GITHUB_REPOSITORY}/attestations" --input "${work}/body.json" \
        --jq '"[CI-ATTEST] stored attestation \(.id)"' || return 1
    gh attestation verify "${verify}" --repo "${GITHUB_REPOSITORY}" --format json \
        | jq -er '.[] | "[CI-ATTEST] verified \(.verificationResult.statement.predicateType) by \(.verificationResult.signature.certificate.subjectAlternativeName)"'
}

# What: Print "name sha256" for each given file, by basename.
# Why: A subject names the artifact a consumer downloads.
# From: Issue #38, Issue #479, PR #544
_ci_attest_file_subjects() {
    local f sum
    for f in "$@"; do
        sum="$(sha256sum "${f}")" || return 1
        printf '%s %s\n' "$(basename "${f}")" "${sum%% *}"
    done
}

# What: 0 if this run is a PR from another repo, else 1.
# Why: GitHub gives a fork PR's run no id-token at all.
# From: Issue #38, Issue #479, PR #544
_ci_event_is_fork_pr() {
    local head
    [ "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME required}" = "pull_request" ] || return 1
    head="$(_ci_event_value .pull_request.head.repo.full_name)" || return 2
    [ "${head}" != "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}" ]
}

# What: Log NotRun for a local or fork-PR run; else fail.
# Why: Every other Actions job gets the id-token it asks for.
# From: Issue #38, Issue #479, PR #544
_ci_attest_without_token() {
    local rc=0
    if [ "${GITHUB_ACTIONS:-}" != "true" ]; then
        ci_log "[CI-ATTEST]" "build attestation NotRun: no id-token outside GitHub Actions"
        return 0
    fi
    _ci_event_is_fork_pr || rc=$?
    case "${rc}" in
        0)
            ci_log "[CI-ATTEST]" "build attestation NotRun: no id-token for a fork PR"
            return 0 ;;
        1)
            ci_log "[CI-ERROR-ATTEST-0002]" "no id-token on ${GITHUB_EVENT_NAME} of ${GITHUB_REPOSITORY}; job lacks id-token: write"
            return 1 ;;
        *) return 2 ;;
    esac
}

# What: Attest build binaries, release assets, or an image.
# Why: Only a fork-PR build may lack OIDC; a release must not.
# From: Issue #38, Issue #479, PR #544
ci_cmd_attest() {
    local what="${1:-}" subjects ref digest
    local files=()
    [ "$#" -eq 0 ] || shift
    cd "${CI_REPO_ROOT}" || return 1
    case "${what}" in
        build)
            # What: Attest only the default Linux leg's binaries.
            # Why: That build is the one the release ships.
            # From: Issue #38, Issue #479, PR #544
            if [ "${1:?variant required}" != "default" ] || [ "${RUNNER_OS:?RUNNER_OS required}" != "Linux" ]; then
                ci_log "[CI-ATTEST]" "build attestation NotRun: ${1} on ${RUNNER_OS} is not the default Linux build"
                return 0
            fi
            if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
                _ci_attest_without_token || return
                return 0
            fi
            files=(distcc distccd) ;;
        release)
            _ci_mapfile files _ci_release_assets || return 1
            files+=("$@") ;;
        image)
            ref="${1:?image ref required}"
            digest="$(_ci_registry_digest "${ref}")" || return 1
            _ci_attest_subjects "${ref%:*} ${digest#sha256:}" "oci://${ref}"
            return ;;
        *) ci_log "[CI-ERROR-ATTEST-0001]" "unknown attest target=\"${what}\" (build|release|image)"; return 2 ;;
    esac
    subjects="$(_ci_attest_file_subjects "${files[@]}")" || return 1
    _ci_attest_subjects "${subjects}" "${files[0]}"
}

# What: Agent home; fixed by the agent's own systemd unit.
# Why: The unit's ExecStart/WorkingDirectory hardcode it.
# From: Issue #479, PR #544
_CI_HARDEN_DIR="/home/agent"

# What: Print why the agent cannot run on this runner, if so.
# Why: Community tier: non-TLS agent, hosted Linux x64 only.
# From: Issue #479, PR #544
_ci_harden_unsupported() {
    if [ "${RUNNER_OS:-}" != "Linux" ]; then
        printf 'RUNNER_OS=%s' "${RUNNER_OS:-unset}"
    elif [ "${RUNNER_ARCH:-}" != "X64" ]; then
        printf 'RUNNER_ARCH=%s' "${RUNNER_ARCH:-unset}"
    elif [ "${RUNNER_ENVIRONMENT:-}" != "github-hosted" ]; then
        printf 'RUNNER_ENVIRONMENT=%s' "${RUNNER_ENVIRONMENT:-unset}"
    fi
}

# What: Print the agent's systemd unit.
# Why: Unit content is the agent's own install contract.
# From: Issue #479, PR #544
_ci_harden_service_unit() {
    cat <<EOF
[Unit]
Description=Agent
After=network.target

[Service]
Type=simple
ExecStart=${_CI_HARDEN_DIR}/agent
WorkingDirectory=${_CI_HARDEN_DIR}
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=agentservice
AmbientCapabilities=CAP_NET_BIND_SERVICE, CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
EOF
}

# What: Register the job, install and start the agent.
# Why: Monitor API is third-party; an outage must not fail CI.
# From: Issue #479, PR #544, Issue #58
_ci_harden_start() {
    local why api tel web egress cid resp code otk="" summary="false"
    local private
    why="$(_ci_harden_unsupported)"
    if [ -n "${why}" ]; then
        ci_log "[CI-HARDEN]" "NotRun: agent unsupported on ${why}"
        return 0
    fi
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    : "${GITHUB_RUN_ID:?GITHUB_RUN_ID required}"
    : "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE required}"
    : "${GITHUB_EVENT_PATH:?GITHUB_EVENT_PATH required}"
    : "${USER:?USER required}"
    : "${RUNNER_TEMP:?RUNNER_TEMP required}"
    api="$(_ci_sot_scalar harden_runner.api_url)" || return 2
    tel="$(_ci_sot_scalar harden_runner.telemetry_url)" || return 2
    web="$(_ci_sot_scalar harden_runner.web_url)" || return 2
    egress="$(_ci_sot_scalar harden_runner.egress_policy)" || return 2
    cid="$(cat /proc/sys/kernel/random/uuid)" || return 1
    resp="${RUNNER_TEMP:-/tmp}/harden-monitor.json"
    code="$(curl -sS --max-time 3 -o "${resp}" -w '%{http_code}' -X POST \
        -H 'content-type: application/json' \
        --data "{\"correlation_id\":\"${cid}\",\"job\":\"${GITHUB_JOB:-}\"}" \
        "${api}/github/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/monitor")" || code="000"
    ci_log "[CI-HARDEN]" "monitor endpoint HTTP ${code}"
    if [ "${code}" = "409" ]; then
        ci_log "[CI-HARDEN]" "NotRun: StepSecurity reports the service unavailable"
        return 0
    fi
    if [ "${code}" = "200" ]; then
        if ! otk="$(jq -r '.one_time_key // ""' "${resp}")" \
            || ! summary="$(jq -r 'if .monitoring_started then "true" else "false" end' "${resp}")"; then
            ci_log "[CI-HARDEN]" "monitor endpoint HTTP 200 body is not JSON; agent runs without its key"
            cat "${resp}" >&2
            otk="" summary="false"
        fi
    fi
    private="$(_ci_event_value '.repository.private // false')" || return 2
    sudo mkdir -p "${_CI_HARDEN_DIR}" || return 1
    sudo chown -R "${USER}" "${_CI_HARDEN_DIR}" || return 1
    _ci_install_tool external_versions.harden_runner_agent "${_CI_HARDEN_DIR}/agent" || return
    jq -n --arg repo "${GITHUB_REPOSITORY}" --arg run_id "${GITHUB_RUN_ID}" \
        --arg cid "${cid}" --arg wd "${GITHUB_WORKSPACE}" --arg api "${api}" \
        --arg tel "${tel}" --arg egress "${egress}" --arg otk "${otk}" \
        --argjson private "${private}" \
        '{repo: $repo, run_id: $run_id, correlation_id: $cid,
          working_directory: $wd, api_url: $api, telemetry_url: $tel,
          allowed_endpoints: "", egress_policy: $egress,
          disable_telemetry: false, disable_sudo: false,
          disable_sudo_and_containers: false, disable_file_monitoring: false,
          private: $private, is_github_hosted: true, is_debug: false,
          one_time_key: $otk, deploy_on_self_hosted_vm: false}' \
        > "${_CI_HARDEN_DIR}/agent.json" || return 1
    printf 'correlation_id=%s\nadd_summary=%s\n' "${cid}" "${summary}" \
        > "${RUNNER_TEMP}/ci-harden.state" || return 1
    _ci_harden_service_unit | sudo tee /etc/systemd/system/agent.service >/dev/null || return 1
    sudo systemctl daemon-reload || return 1
    timeout 15 sudo service agent start || return 1
    if _ci_wait_until 31 0.3 test -f "${_CI_HARDEN_DIR}/agent.status"; then
        ci_log "[CI-HARDEN]" "agent status: $(cat "${_CI_HARDEN_DIR}/agent.status")"
        ci_log "[CI-HARDEN]" "insights: ${web}/github/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
        return 0
    fi
    ci_log "[CI-ERROR-HARDEN-0002]" "agent wrote no agent.status within 9s"
    _ci_harden_agent_log
    return 1
}

# What: Print the agent's own log, or say that it wrote none.
# Why: A read error then shows raw; a missing log is named.
# From: Issue #479, PR #544
_ci_harden_agent_log() {
    if [ -e "${_CI_HARDEN_DIR}/agent.log" ]; then
        cat "${_CI_HARDEN_DIR}/agent.log"
        return
    fi
    ci_log "[CI-ERROR-HARDEN-0004]" "the agent wrote no agent.log"
}

# What: Signal job end, await the agent's flush, add summary.
# Why: Agent writes done.json when it audits post_event.json.
# From: Issue #479, PR #544
_ci_harden_stop() {
    local state="${RUNNER_TEMP:?RUNNER_TEMP required}/ci-harden.state"
    local cid summary api out code
    if [ ! -f "${state}" ]; then
        ci_log "[CI-HARDEN]" "NotRun: no agent was started in this job"
        return 0
    fi
    cid="$(sed -n 's/^correlation_id=//p' "${state}")" || return 1
    summary="$(sed -n 's/^add_summary=//p' "${state}")" || return 1
    printf '{"event":"post"}' > "${_CI_HARDEN_DIR}/post_event.json" || return 1
    if ! _ci_wait_until 11 1 test -f "${_CI_HARDEN_DIR}/done.json"; then
        ci_log "[CI-ERROR-HARDEN-0003]" "agent did not confirm job end within 10s"
        _ci_harden_agent_log
        return 1
    fi
    if [ "${summary}" != "true" ]; then
        return 0
    fi
    api="$(_ci_sot_scalar harden_runner.api_url)" || return 2
    out="${RUNNER_TEMP:-/tmp}/harden-summary.md"
    code="$(curl -sS --max-time 3 -o "${out}" -w '%{http_code}' \
        "${api}/github/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}/actions/runs/${GITHUB_RUN_ID:?GITHUB_RUN_ID required}/correlation/${cid}/job-markdown-summary")" || code="000"
    if [ "${code}" = "200" ]; then
        _ci_step_summary cat "${out}" || return 1
    else
        ci_log "[CI-HARDEN]" "job summary endpoint HTTP ${code}; summary not added"
    fi
}

# What: Dispatch harden start|stop.
# Why: One owner for the agent's whole job lifecycle.
# From: Issue #479, PR #544
ci_cmd_harden() {
    case "${1:-}" in
        start) _ci_harden_start ;;
        stop) _ci_harden_stop ;;
        *) ci_log "[CI-ERROR-HARDEN-0001]" "unknown harden subcommand=\"${1:-}\" (start|stop)"; return 2 ;;
    esac
}

# What: Map language+suite to a CodeQL query-pack reference.
# Why: One mapping; callers pass only a plain suite name.
# From: Issue #479
_ci_codeql_query_pack() {
    local lang="$1" suite="$2"
    case "${lang}" in
        c-cpp)  printf 'codeql/cpp-queries:codeql-suites/cpp-%s.qls' "${suite}" ;;
        python) printf 'codeql/python-queries:codeql-suites/python-%s.qls' "${suite}" ;;
        *)      printf 'codeql/%s-queries' "${lang}" ;;
    esac
}

# What: Create a CodeQL DB and analyze it into a SARIF file.
# Why: c-cpp traces the repo's own ci.sh build command.
# From: Issue #479
ci_cmd_codeql_scan() {
    local lang="${1:?language required}" out="${2:?sarif output required}" suite bin db pack
    suite="$(_ci_sot_scalar security.codeql.suite)" || return 2
    bin="$(_ci_tool_bin external_versions.codeql_cli)" || return 2
    db="${RUNNER_TEMP:-/tmp}/codeql-db-${lang}"
    pack="$(_ci_codeql_query_pack "${lang}" "${suite}")" || return 2
    rm -rf "${db}" || return 1
    case "${lang}" in
        c-cpp)
            # What: Install the c-cpp build deps before tracing.
            # Why: Only the traced build needs them; others do not.
            # From: Issue #479, PR #544
            ci_cmd_install sot-apt security.codeql_cpp_apt || return 1
            "${bin}" database create "${db}" --language=cpp \
                --source-root=. \
                --command="bash .github/scripts/ci.sh build default" || return 2
            ;;
        *)
            "${bin}" database create "${db}" --language="${lang}" \
                --source-root=. || return 2
            ;;
    esac
    "${bin}" database analyze "${db}" "${pack}" \
        --format=sarif-latest --output="${out}" --download \
        --sarif-category="/language:${lang}" || return 2
}

# What: One SARIF POST; rc 1 retries a 5xx, 429 or empty 2xx.
# Why: gh names no status for a 5xx with an empty body.
# From: Issue #479, PR #544
_ci_sarif_post() {
    local work="$1" rc=0 code id why
    : > "${work}/jqerr" || return 2
    gh api --include --method POST "repos/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}/code-scanning/sarifs" \
        --input "${work}/body.json" > "${work}/resp" 2> "${work}/err" || rc=$?
    code="$(sed -nE '1s#^HTTP/[0-9.]+ ([0-9]{3}).*#\1#p' "${work}/resp")" || return 2
    sed -E '1,/^\r?$/d' "${work}/resp" > "${work}/body" || return 2
    if [ "${rc}" -eq 0 ] && id="$(jq -er '.id // empty' "${work}/body" 2> "${work}/jqerr")"; then
        ci_log "[CI-SCAN]" "SARIF upload id ${id}"
        return 0
    fi
    why="$(cat "${work}/err" "${work}/jqerr" "${work}/body")" || return 2
    why="HTTP ${code:-none}${why:+: ${why}}"
    printf '%s' "${why}" > "${work}/why" || return 2
    case "${code}" in
        2[0-9][0-9]|429|5[0-9][0-9]) ;;
        *) return 2 ;;
    esac
    ci_log "[CI-SCAN]" "SARIF upload attempt ${CI_ATTEMPT}/${CI_TRIES} failed: ${why}"
    return 1
}

# What: Upload one SARIF file via the code-scanning API.
# Why: The body goes in a file; a large SARIF overflows argv.
# From: Issue #479, PR #544
ci_cmd_sarif_upload() {
    local file="${1:?sarif file required}" work why
    : "${GH_TOKEN:?GH_TOKEN required}"
    work="$(mktemp -d)" || return 1
    gzip -c "${file}" | base64 -w0 > "${work}/sarif.b64" || return 1
    jq -n --arg c "${GITHUB_SHA:?GITHUB_SHA required}" --arg r "${GITHUB_REF:?GITHUB_REF required}" \
        --rawfile s "${work}/sarif.b64" '{commit_sha: $c, ref: $r, sarif: $s}' > "${work}/body.json" || return 1
    if _ci_wait_until 3 5 _ci_sarif_post "${work}"; then
        rm -rf "${work}" || return 1
        return 0
    fi
    why=""
    if [ -f "${work}/why" ]; then
        why="$(cat "${work}/why")" || return 1
    fi
    ci_error "[CI-ERROR-SCAN-0004]" "SARIF upload of ${file} failed" "${why:-empty response}"
    rm -rf "${work}"
    return 1
}

# What: Convert Scorecard's own JSON into real SARIF.
# Why: bare CLI has no --format=sarif (see --help).
# From: Issue #479
_ci_scorecard_json_to_sarif() {
    jq '
        {
            "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
            version: "2.1.0",
            runs: [{
                tool: {
                    driver: {
                        name: "scorecard",
                        informationUri: "https://github.com/ossf/scorecard",
                        version: .scorecard.version,
                        rules: [.checks[] | {
                            id: .name,
                            name: .name,
                            shortDescription: {text: .documentation.short},
                            helpUri: .documentation.url
                        }] | unique_by(.id)
                    }
                },
                results: [.checks[] | select(.score >= 0 and .score < 10) | {
                    ruleId: .name,
                    level: (if .score <= 3 then "warning" else "note" end),
                    message: {text: ([.reason] + (.details // [])) | join("\n")}
                }]
            }]
        }
    '
}

# What: Run Scorecard, convert its JSON to SARIF.
# Why: Code scanning accepts only SARIF uploads.
# From: Issue #479
ci_cmd_scorecard_scan() {
    local out="${1:-results.sarif}" bin json
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    bin="$(_ci_tool_bin external_versions.scorecard)" || return 2
    json="${RUNNER_TEMP:-/tmp}/scorecard-results.json"
    "${bin}" --repo="github.com/${GITHUB_REPOSITORY}" \
        --format=json --show-details > "${json}" || return 1
    _ci_scorecard_json_to_sarif < "${json}" > "${out}" || return 1
    case "${out}" in
        /*) ;;
        *) out="${PWD}/${out}" ;;
    esac
    _ci_artifact_offer scorecard "" "${out}"
}

# What: Scan the SOT tools with OSV-Scanner into SARIF.
# Why: A PR may not add a known-vulnerable tool version.
# From: Issue #479
ci_cmd_osv_scan() {
    local out="${1:-osv-results.sarif}" bin base base_sot base_tree old new added pins=0
    local dirs=() range=()
    bin="$(_ci_tool_bin external_versions.osv_scanner)" || return 2
    _ci_mapfile dirs _ci_osv_tool_dirs || return 2
    [ "${#dirs[@]}" -gt 0 ] || return 2
    _ci_osv_run "${bin}" sarif "${out}" "${dirs[@]}" || return 2
    if [ "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME required}" != "pull_request" ]; then
        return 0
    fi
    _ci_mapfile range _ci_event_range || return 2
    [ "${#range[@]}" -eq 2 ] || return 2
    base="${range[0]}"
    # What: PR gate: fail on vuln ids the head's tools add.
    # Why: Same scanner and DB on both SOTs; only versions differ.
    # From: Issue #267, Issue #479, PR #544
    base_sot="$(mktemp)" || return 1
    git -C "${CI_REPO_ROOT}" fetch -q --depth=1 origin "${base}" || return 1
    base_tree="$(git -C "${CI_REPO_ROOT}" ls-tree --name-only "${base}" -- .github/yaml/build-manifest.yml)" \
        || return 1
    if [ -z "${base_tree}" ]; then
        ci_log "[CI-SCAN]" "OSV PR gate NotRun: base ${base} has no SOT yet"
        return 0
    fi
    git -C "${CI_REPO_ROOT}" show "${base}:.github/yaml/build-manifest.yml" > "${base_sot}" || return 1
    grep -q '^    bin:' "${base_sot}" || pins=$?
    case "${pins}" in
        0) ;;
        1) ci_log "[CI-SCAN]" "OSV PR gate NotRun: base SOT has no tool pins to compare"
           return 0 ;;
        *) ci_log "[CI-ERROR-SCAN-0005]" "cannot read the base SOT ${base_sot} (grep rc ${pins})"
           return 2 ;;
    esac
    old="$(_ci_osv_vulns "${bin}" "${base_sot}")" || return 2
    new="$(_ci_osv_vulns "${bin}" "${CI_MANIFEST}")" || return 2
    added="$(comm -13 <(printf '%s\n' "${old}") <(printf '%s\n' "${new}"))" || return 2
    if [ -n "${added}" ]; then
        ci_error "[CI-ERROR-SCAN-0003]" "this PR adds known-vulnerable CI tool versions" "${added}"
        return 1
    fi
    ci_log "[CI-SCAN]" "OSV PR gate: no new vulnerability in the SOT tools"
}

# What: Fetch every SOT tool with a bin; print each tool dir.
# Why: These binaries are CI's real third-party dependencies.
# From: Issue #267, Issue #479, PR #544
_ci_osv_tool_dirs() {
    local keys key dest bin
    keys="$(_ci_sot_children external_versions)" || return 2
    for key in ${keys}; do
        bin="$(_ci_sot_optional "external_versions.${key}.bin")" || return 2
        [ -n "${bin}" ] || continue
        dest="$(_ci_fetch_tool "external_versions.${key}")" || return 2
        printf '%s\n' "${dest}"
    done
}

# What: osv-scanner over tool dirs with the artifact plugins.
# Why: The default plugins read no binaries; 1-126 = findings.
# From: Issue #267, Issue #479, PR #544
_ci_osv_run() {
    local bin="$1" format="$2" out="$3" rc=0
    shift 3
    # What: Skip the transitive Maven pom resolver.
    # Why: osv calls it risky on foreign files; jars read as-is.
    # From: Issue #267, PR #544
    "${bin}" scan source --experimental-plugins artifact \
        --experimental-disable-plugins transitivedependency/pomxml --format="${format}" \
        --output-file="${out}" -r "$@" || rc=$?
    if [ "${rc}" -ge 127 ]; then
        ci_log "[CI-ERROR-SCAN-0002]" "tool=osv-scanner exit=${rc} reason=\"scan failed\""
        return 2
    fi
}

# What: Print the sorted vuln ids OSV finds in a SOT's tools.
# Why: The PR gate diffs these id sets, base against head.
# From: Issue #267, Issue #479, PR #544
_ci_osv_vulns() {
    local bin="$1" sot="$2" json
    local dirs=()
    json="$(mktemp)" || return 1
    CI_MANIFEST="${sot}" _ci_mapfile dirs _ci_osv_tool_dirs || return 2
    _ci_osv_run "${bin}" json "${json}" "${dirs[@]}" || return 2
    jq -r '[.results[]?.packages[]?.vulnerabilities[]?.id] | unique | .[]' "${json}"
}

# What: Print the ClusterFuzzLite workspace directory.
# Why: The run and the crash offer must read the same tree.
# From: Issue #267, Issue #479, PR #544
_ci_cfl_workspace() {
    printf '%s\n' "${RUNNER_TEMP:-/tmp}/cfl-workspace"
}

# What: Run a ClusterFuzzLite step image; CFL options only.
# Why: CFL runs docker itself; --volumes-from needs our name.
# From: Issue #267, Issue #479, PR #544
_ci_cfl_run() {
    local step="$1" image name work repo
    shift
    image="$(_ci_sot_scalar "base_images.cfl_${step}_fuzzers")" || return 2
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    repo="${GITHUB_REPOSITORY#*/}"
    name="$(_ci_run_name "cfl-${step}")"
    work="$(_ci_cfl_workspace)"
    mkdir -p "${work}" || return 1
    # What: CFL reads the checkout from PROJECT_SRC_PATH.
    # Why: Standalone mode has no other source; unset is None.
    # From: Issue #267, PR #544
    _ci_container_run "${image}" --name "${name}" -e "CFL_CONTAINER_ID=${name}" \
        -v /var/run/docker.sock:/var/run/docker.sock -v "${work}:${work}" \
        -e "PROJECT_SRC_PATH=${CI_CONTAINER_ROOT}" \
        -e CFL_PLATFORM=standalone -e LANGUAGE=c -e "REPOSITORY=${repo}" \
        -e "WORKSPACE=${work}" -e "FILESTORE_ROOT_DIR=${work}/filestore" \
        -e LOW_DISK_SPACE=True "$@" --
}

# What: Tag the SOT base-builder, then build the CFL fuzzers.
# Why: CFL builds its Dockerfile without any build-args.
# From: Issue #267, Issue #479, PR #544
ci_cmd_clusterfuzzlite_build() {
    local sanitizer="${1:?sanitizer required}"
    # What: Generate configure on the host before the CFL build.
    # Why: base-builder has autoconf 2.69; configure needs 2.71.
    # From: Issue #267, Issue #479, PR #544
    ci_cmd_install sot-apt security.cfl_host_apt || return 1
    ( cd "${CI_REPO_ROOT}" && _ci_run_autogen "${RUNNER_TEMP:-/tmp}/cfl-autogen.log" ) || return 1
    _ci_image_alias security.cfl_base || return 1
    _ci_cfl_run build -e "SANITIZER=${sanitizer}"
}

# What: Run the built fuzzers for a bounded time.
# Why: Code-change mode on PRs; SARIF feeds code scanning.
# From: Issue #267, Issue #479
ci_cmd_clusterfuzzlite_run() {
    local sanitizer="${1:?sanitizer required}" fuzz_seconds mode rc=0 crashes found
    fuzz_seconds="$(_ci_sot_scalar security.cfl_run.seconds)" || return 2
    mode="$(_ci_sot_scalar security.cfl_run.mode)" || return 2
    _ci_cfl_run run -e "SANITIZER=${sanitizer}" -e "FUZZ_SECONDS=${fuzz_seconds}" \
        -e "MODE=${mode}" -e OUTPUT_SARIF=true || rc=$?
    # What: Offer the crash reproducers CFL left in its workspace.
    # Why: A crash fails this step; the upload still needs them.
    # From: Issue #267, Issue #479, PR #544
    crashes="$(_ci_cfl_workspace)/out/artifacts"
    if [ -d "${crashes}" ]; then
        found="$(find "${crashes}" -mindepth 1 -print -quit)" || return 1
        if [ -n "${found}" ]; then
            _ci_artifact_offer cfl_crashes "${sanitizer}" "${crashes}" || return 1
        fi
    fi
    return "${rc}"
}

# What: Print the python the build uses: 3.13 if present.
# Why: make check fails on brew's newer python (da6d609).
# From: Issue #479, PR #544
_ci_python() {
    if command -v python3.13; then
        return 0
    fi
    if command -v python3; then
        return 0
    fi
    ci_log "[CI-ERROR-BUILD-0006]" "neither python3.13 nor python3 is installed"
    return 1
}

# What: Print every real gcc/clang warning line of a log.
# Why: Warnings are errors (AG-INT-003); diag-shape anchor.
# From: Issue #479
_ci_compiler_warnings() {
    grep -E '^[^: ]+\.(c|h|cc|cpp):[0-9]+:([0-9]+:)? *[Ww]arning:' "$1"
}

# What: Fail if a build log holds a compiler warning.
# Why: Warnings are errors; an unreadable log is no pass.
# From: Issue #479, PR #544
_ci_warning_gate() {
    local log="$1" what="$2" warnings rc=0
    warnings="$(_ci_compiler_warnings "${log}")" || rc=$?
    case "${rc}" in
        0) ci_error "[CI-ERROR-BUILD-WARN-0001]" "${what} emitted compiler warnings (AG-INT-003)" "${warnings}"
           return 1 ;;
        1) return 0 ;;
        *) ci_log "[CI-ERROR-BUILD-WARN-0002]" "cannot scan ${log} for warnings (grep rc ${rc})"
           return 1 ;;
    esac
}

# What: autogen and configure the tree in cwd; log to $1.
# Why: One configure owner; stdout stays free for callers.
# From: Issue #479, PR #544
_ci_configure_tree() {
    local log="$1"
    shift
    _ci_run_autogen "${log}" || return 1
    _ci_run_configure "${log}" "$@"
}

# What: Generate configure in cwd with autogen.sh; log to $1.
# Why: CFL runs it on the host, where apt autoconf is new.
# From: Issue #267, Issue #479, PR #544
_ci_run_autogen() {
    if ! ./autogen.sh 2>&1 | tee "$1" >&2; then
        ci_log "[CI-ERROR-BUILD-0003]" "autogen failed"
        return 1
    fi
}

# What: Run the generated configure in cwd; append to log $1.
# Why: The CFL base-builder runs it without any autoconf.
# From: Issue #267, Issue #479, PR #544
_ci_run_configure() {
    local log="$1"
    shift
    if ! ./configure "$@" 2>&1 | tee -a "${log}" >&2; then
        ci_log "[CI-ERROR-BUILD-0005]" "configure failed: $*"
        return 1
    fi
}

# What: make in cwd; fail on an error or a compiler warning.
# Why: One make owner, so every tree build gets the gate.
# From: Issue #479, PR #544
_ci_make_gated() {
    local log="$1"
    shift
    if ! make "$@" 2>&1 | tee "${log}" >&2; then
        ci_log "[CI-ERROR-BUILD-0004]" "make $* failed"
        return 1
    fi
    _ci_warning_gate "${log}" "make $*"
}

# What: Compile vendored popt/*.c under this repo's flags.
# Why: popt-vendor proves bundled popt builds Werror-clean.
# From: Issue #479, Issue #63
_ci_popt_strict_compile() {
    local out="${RUNNER_TEMP:-/tmp}/popt-strict-check" f
    mkdir -p "${out}" || return 1
    local cflags=(-DHAVE_CONFIG_H -D_GNU_SOURCE \
        "-DPOPT_SYSCONFDIR=\"/usr/local/etc\"" "-DPACKAGE=\"distcc\"" \
        -Isrc -Ipopt -Wall -Wextra -Werror -Wno-unused -Wno-unused-parameter)
    for f in popt/popt.c popt/poptconfig.c popt/popthelp.c popt/poptparse.c popt/poptint.c; do
        gcc "${cflags[@]}" -c "${f}" -o "${out}/$(basename "${f}").o" || return 1
    done
}

# What: Verify the vendored popt/ tree has 3 CVE fixes.
# Why: A revert to a pre-fix snapshot would compile fine.
# From: Issue #479
_ci_popt_cve_fingerprint_check() {
    local want got rc=0
    want="$(_ci_sot_scalar external_versions.popt_vendor.version)" || return 2
    got="$(cat popt/POPT_VERSION)" || got="<missing popt/POPT_VERSION>"
    if [ "${got}" != "${want}" ]; then
        ci_log "[CI-ERROR-POPT-CVE-0001]" "POPT_VERSION mismatch: got=\"${got}\" want=\"${want}\""
        rc=1
    fi
    grep -q "poptJlu32lpair" popt/poptint.h || {
        ci_log "[CI-ERROR-POPT-CVE-0002]" "poptint.h missing poptJlu32lpair"
        rc=1
    }
    { [ -f popt/findme.c ] || [ -f popt/findme.h ]; } && {
        ci_log "[CI-ERROR-POPT-CVE-0003]" "findme.c/findme.h present (pre-fix tree)"
        rc=1
    }
    grep -q "con->os - con->optionStack + 1) == POPT_OPTION_DEPTH" popt/popt.c || {
        ci_log "[CI-ERROR-POPT-CVE-0004]" "poptStuffArgs missing the depth guard (CVE-2026-18739)"
        rc=1
    }
    grep -q "calloc" popt/poptconfig.c || {
        ci_log "[CI-ERROR-POPT-CVE-0005]" "poptconfig.c missing the calloc-args fix"
        rc=1
    }
    [ "$(grep -c 'maxargvlen = argvlen \* 2;' popt/poptparse.c)" -eq 2 ] || {
        ci_log "[CI-ERROR-POPT-CVE-0006]" "poptparse.c missing the doubling fix (CVE-2026-18743)"
        rc=1
    }
    return "${rc}"
}

# What: Fail unless $1 is a SOT build variant; log id $2.
# Why: An unknown variant must never build or test a default.
# From: Issue #479, PR #544
_ci_variant_known() {
    local variants
    variants="$(_ci_sot_children build_matrix.variants)" || return 2
    if ! grep -qxF -- "$1" <<< "${variants}"; then
        ci_log "$2" "unknown variant=\"$1\""
        return 2
    fi
}

# What: rc 0 if SOT variant $1 builds via ccache, 1 if not.
# Why: Build and cache plan read one flag; a bad value: rc 2.
# From: Issue #54, Issue #479, PR #544
_ci_variant_ccache() {
    local on
    on="$(_ci_sot_optional "build_matrix.variants.$1.ccache")" || return 2
    case "${on}" in
        true) return 0 ;;
        ""|false) return 1 ;;
        *) ci_log "[CI-ERROR-BUILD-0007]" "build_matrix.variants.$1.ccache=${on} (true|false)"; return 2 ;;
    esac
}

# What: Write the compile-cache path, key and restore keys.
# Why: actions/cache only transports; ci.sh owns the policy.
# From: Issue #54, Issue #362, Issue #479, PR #166, PR #544
ci_cmd_cache() {
    local variant="${1:?variant required}" dir sum scope rc=0
    _ci_variant_ccache "${variant}" || rc=$?
    case "${rc}" in
        0) ;;
        1) ci_log "[CI-CACHE]" "variant=${variant} has no compile cache"; return 0 ;;
        *) return 2 ;;
    esac
    : "${RUNNER_OS:?RUNNER_OS required}" "${RUNNER_ARCH:?RUNNER_ARCH required}"
    : "${GITHUB_RUN_ID:?GITHUB_RUN_ID required}"
    cd "${CI_REPO_ROOT}" || return 1
    dir="$(ccache --get-config cache_dir)" || return 1
    # What: Key on the autoconf inputs plus the run id.
    # Why: A key is never overwritten; restore takes the newest.
    # From: Issue #54, Issue #362, PR #166
    sum="$(git ls-tree HEAD -- configure.ac m4 | git hash-object --stdin)" || return 1
    scope="build-${RUNNER_OS}-${RUNNER_ARCH}"
    _ci_output path "${dir}"$'\n'"${CI_REPO_ROOT}/autom4te.cache" \
        key "${scope}-${sum}-${GITHUB_RUN_ID}" \
        restore_keys "${scope}-${sum}-"$'\n'"${scope}-"
}

# What: Configure one SOT variant, then run its build steps.
# Why: The SOT defines each variant; warnings fail the build.
# From: Issue #479, PR #544
ci_cmd_build() {
    local variant="${1:?variant required}" log py cc="" val step steps rc=0
    local flags=() opts=()
    _ci_variant_known "${variant}" "[CI-ERROR-BUILD-0002]" || return 2
    log="${RUNNER_TEMP:-/tmp}/ci-build-${variant}.log"
    py="$(_ci_python)" || return 1
    flags=(PYTHON="${py}")
    # What: Use ccache only where the job installed it.
    # Why: CodeQL's build has none; a cache hit would hide code.
    # From: Issue #54, Issue #479, PR #544
    _ci_variant_ccache "${variant}" || rc=$?
    case "${rc}" in
        0) cc="cc"
           if command -v ccache >/dev/null 2>&1; then cc="$(command -v ccache) cc"; fi
           flags+=(CC="${cc}") ;;
        1) ;;
        *) return 2 ;;
    esac
    val="$(_ci_sot_optional "build_matrix.variants.${variant}.cflags")" || return 2
    [ -z "${val}" ] || flags+=(CFLAGS="${val}")
    val="$(_ci_sot_optional "build_matrix.variants.${variant}.ldflags")" || return 2
    [ -z "${val}" ] || flags+=(LDFLAGS="${val}")
    val="$(_ci_sot_optional "build_matrix.variants.${variant}.configure")" || return 2
    read -ra opts <<< "${val}"
    flags+=(${opts[@]+"${opts[@]}"})
    steps="$(_ci_sot_list "build_matrix.variants.${variant}.build_steps")" || return 2
    cd "${CI_REPO_ROOT}" || return 1
    _ci_configure_tree "${log}.configure" "${flags[@]}" || return 1
    for step in ${steps}; do
        _ci_build_step "${step}" "${log}" "${cc}" || return
    done
}

# What: Run one named SOT build step on the configured tree.
# Why: The SOT orders the steps; each name has one body.
# From: Issue #479, PR #544
_ci_build_step() {
    local step="$1" log="$2" cc="$3"
    case "${step}" in
        make)
            _ci_make_gated "${log}" || return 1
            if [ "${cc}" != "${cc#*ccache}" ]; then
                ccache --show-stats || return 1
            fi ;;
        popt-fallback-line)
            if ! grep -q "system libpopt not found (or disabled); building bundled popt" "${log}.configure"; then
                ci_log "[CI-ERROR-BUILD-POPT-0001]" "configure did not fall back to bundled popt (libpopt-dev leaking?)"
                return 1
            fi ;;
        popt-smoke) _ci_popt_fallback_smoke_test ;;
        popt-fingerprint) _ci_popt_cve_fingerprint_check ;;
        popt-strict) _ci_popt_strict_compile ;;
        *) ci_log "[CI-ERROR-BUILD-0008]" "unknown build step=\"${step}\""; return 2 ;;
    esac
}

# What: Prove the bundled-popt binary parses real options.
# Why: A poptGetNextOpt() regression compiles fine.
# From: Issue #479
_ci_popt_fallback_smoke_test() {
    local help opt
    if ! help="$(./distccd --help 2>&1)"; then
        ci_error "[CI-ERROR-BUILD-POPT-0003]" "distccd --help failed" "${help}"
        return 1
    fi
    for opt in --jobs --nice --listen --daemon --log-file --allow --user --port; do
        grep -qF -- "${opt}" <<< "${help}" || {
            ci_error "[CI-ERROR-BUILD-POPT-0002]" "distccd --help missing ${opt}" "${help}"
            return 1
        }
    done
}

# What: Parse comfychair make-check output into a verdict.
# Why: 0/0/0 parsed is a hard fail (AG-INT-003), not a pass.
# From: Issue #479
_ci_parse_comfychair() {
    local log="$1" counts ok notrun failed
    if [ ! -r "${log}" ]; then
        ci_log "[CI-ERROR-TEST-0007]" "make check log ${log} is not readable"
        return 1
    fi
    counts="$(awk '
        /^[A-Za-z0-9_]+[[:space:]]+OK[[:space:]]*$/ { ok++ }
        /^[A-Za-z0-9_]+[[:space:]]+NOTRUN,/ { notrun++ }
        /^[A-Za-z0-9_]+[[:space:]]+FAIL[[:space:]]*$/ { failed++; print > "/dev/stderr" }
        END { print ok + 0, notrun + 0, failed + 0 }
    ' "${log}")" || return 1
    read -r ok notrun failed <<< "${counts}"
    ci_log "[CI-TEST-SUMMARY]" "OK=${ok} NOTRUN=${notrun} FAILED=${failed}"
    if [ "$(( ok + notrun + failed ))" -eq 0 ]; then
        ci_log "[CI-ERROR-TEST-0001]" "parsed zero comfychair result lines"
        return 1
    fi
    if [ "${failed}" -gt 0 ]; then
        ci_log "[CI-ERROR-TEST-0002]" "${failed} comfychair case(s) FAILED"
        return 1
    fi
}

# What: Rerun the root-only case, fail on NOTRUN or non-OK.
# Why: The unprivileged make check leaves it NOTRUN otherwise.
# From: Issue #479
_ci_privileged_single_test() {
    if [ "$(uname -s)" != "Linux" ]; then
        ci_log "[CI-TEST-SKIP]" "autogroup privilege case is Linux-only; skipping on $(uname -s)"
        return 0
    fi
    # What: The verify-image workload runs this test without root.
    # Why: That container is unprivileged; it has no sudo.
    # From: Issue #285, Issue #479, PR #544
    if [ "${CI_TEST_UNPRIVILEGED:-false}" = "true" ]; then
        ci_log "[CI-TEST-NOTRUN]" "AutogroupNicenessPrivilegeDrop_Case: unprivileged verify container"
        return 0
    fi
    local log="${RUNNER_TEMP:-/tmp}/ci-autogroup.log"
    if ! sudo make TESTNAME=AutogroupNicenessPrivilegeDrop_Case single-test 2>&1 | tee "${log}"; then
        ci_log "[CI-ERROR-TEST-0008]" "make single-test AutogroupNicenessPrivilegeDrop_Case failed"
        return 1
    fi
    if grep -q "AutogroupNicenessPrivilegeDrop_Case NOTRUN" "${log}"; then
        ci_log "[CI-ERROR-TEST-0003]" "AutogroupNicenessPrivilegeDrop_Case NOTRUN"
        return 1
    fi
    grep -q "AutogroupNicenessPrivilegeDrop_Case OK" "${log}" \
        || { ci_log "[CI-ERROR-TEST-0004]" "AutogroupNicenessPrivilegeDrop_Case not OK"; return 1; }
}

# What: Write the coverage PYTHON wrapper; print its path.
# Why: include_server/*.py joins the coverage denominator.
# From: Issue #479, PR #370
_ci_coverage_python_wrapper() {
    local w="${RUNNER_TEMP:-/tmp}/coverage-python-wrapper" py
    py="$(_ci_python)" || return 1
    cat > "${w}" <<EOF || return 1
#!/bin/sh
if [ "\$1" = "-c" ]; then
    exec "${py}" "\$@"
fi
exec python3-coverage run --append --source="${CI_REPO_ROOT}/include_server" "\$@"
EOF
    chmod +x "${w}" || return 1
    printf '%s\n' "${w}"
}

# What: Capture C coverage into coverage.info via lcov.
# Why: Own shipped code only; lzo/ and src/h_*.c removed.
# From: Issue #479, PR #370
_ci_coverage_lcov() {
    lcov --capture --directory . --output-file coverage_raw.info \
        --rc branch_coverage=1 --rc geninfo_unexecuted_blocks=1 || return 1
    lcov --remove coverage_raw.info '*/lzo/*' '*/src/h_*.c' \
        --output-file coverage.info --rc branch_coverage=1 || return 1
    lcov --list coverage.info --rc branch_coverage=1
}

# What: Run python3-coverage on include_server's data file.
# Why: make check runs those tests from include_server/.
# From: Issue #479, PR #370, PR #544
_ci_coverage_python() {
    python3-coverage "$@" --data-file="${CI_REPO_ROOT}/include_server/.coverage" \
        --include="${CI_REPO_ROOT}/include_server/*"
}

# What: Print C+Python coverage for the job summary.
# Why: The run page shows coverage without a download.
# From: Issue #479, PR #370
_ci_coverage_summary() {
    local fence='```'
    printf '## Coverage summary\n\n### C (lcov)\n%s\n' "${fence}" || return 1
    lcov --list coverage.info --rc branch_coverage=1 || return 1
    printf '%s\n\n### Python (include_server)\n%s\n' "${fence}" "${fence}" || return 1
    _ci_coverage_python report || return 1
    printf '%s\n' "${fence}"
}

# What: Run one SOT variant's test steps on the built tree.
# Why: The SOT defines each variant; an empty list is NotRun.
# From: Issue #479, PR #544
ci_cmd_test() {
    local variant="${1:?variant required}" log step
    local steps
    _ci_variant_known "${variant}" "[CI-ERROR-TEST-0005]" || return 2
    steps="$(_ci_sot_list "build_matrix.variants.${variant}.test_steps")" || return 2
    if [ -z "${steps}" ]; then
        ci_log "[CI-TEST-SKIP]" "NotRun: variant=${variant} has no test steps"
        return 0
    fi
    cd "${CI_REPO_ROOT}" || return 1
    log="${RUNNER_TEMP:-/tmp}/ci-check-${variant}.log"
    for step in ${steps}; do
        _ci_test_step "${step}" "${variant}" "${log}" || return
    done
}

# What: Run one named SOT test step for variant $2.
# Why: The SOT orders the steps; each name has one body.
# From: Issue #479, PR #544
_ci_test_step() {
    local step="$1" variant="$2" log="$3" wrapper
    case "${step}" in
        check) _ci_make_check "${variant}" "${log}" ;;
        check-coverage)
            wrapper="$(_ci_coverage_python_wrapper)" || return 1
            _ci_make_check "${variant}" "${log}" PYTHON="${wrapper}" ;;
        privileged) _ci_privileged_single_test ;;
        coverage-report)
            _ci_coverage_lcov || return 1
            _ci_coverage_python xml -o "${CI_REPO_ROOT}/coverage-python.xml" || return 1
            _ci_step_summary _ci_coverage_summary || return 1
            _ci_artifact_offer coverage "" "${CI_REPO_ROOT}/coverage.info" \
                "${CI_REPO_ROOT}/coverage-python.xml" ;;
        *) ci_log "[CI-ERROR-TEST-0009]" "unknown test step=\"${step}\""; return 2 ;;
    esac
}

# What: make check with the variant's SOT env; gate the log.
# Why: Warnings, a FAIL line or a bad exit each fail the step.
# From: Issue #479, PR #544
_ci_make_check() {
    local variant="$1" log="$2" val kv st=0
    local envs=()
    shift 2
    val="$(_ci_sot_optional "build_matrix.variants.${variant}.check_env")" || return 2
    read -ra envs <<< "${val}"
    for kv in ${envs[@]+"${envs[@]}"}; do
        if ! [[ "${kv}" =~ ^[A-Z_][A-Z0-9_]*=[^[:space:]]*$ ]]; then
            ci_log "[CI-ERROR-TEST-0010]" "build_matrix.variants.${variant}.check_env entry \"${kv}\" is not KEY=VALUE"
            return 2
        fi
    done
    # What: Export the SOT env only into the make check subshell.
    # Why: Later steps of the job must not inherit sanitizer env.
    # From: Issue #479, PR #544
    ( for kv in ${envs[@]+"${envs[@]}"}; do export "${kv?}"; done; make check "$@" ) > "${log}" 2>&1 || st=$?
    cat "${log}" || return 1
    _ci_warning_gate "${log}" "variant=${variant} make check" || return 1
    _ci_parse_comfychair "${log}" || return 1
    if [ "${st}" -ne 0 ]; then
        ci_log "[CI-ERROR-TEST-0006]" "make check exited ${st} for variant=${variant}"
        return 1
    fi
}

# What: Run ci_cmd_<command> for a CI_COMMANDS entry.
# Why: CI_COMMANDS is the one list; a name derives its call.
# From: Issue #479, PR #544
ci_main() {
    local command="${1:-}" fn
    if [ "$#" -gt 0 ]; then shift; fi
    case " ${CI_COMMANDS} " in
        *" ${command} "*) ;;
        *)
            ci_log "[CI-ERROR-CORE-0002]" "command=\"${command}\" reason=\"unknown subcommand\" known=\"${CI_COMMANDS}\""
            return 2 ;;
    esac
    fn="ci_cmd_${command//-/_}"
    if ! declare -F "${fn}" >/dev/null; then
        ci_log "[CI-ERROR-CORE-0001]" "command=${command} has no function ${fn}"
        return 2
    fi
    if [ "${command}" != "checkout" ]; then
        ci_require_manifest || return
    fi
    "${fn}" "$@"
}

# What: Run the dispatcher only on direct execution.
# Why: Lets ci.bats source the functions to test them.
# From: Issue #479
if [ "${BASH_SOURCE[0]:-${0}}" = "${0}" ]; then
    ci_main "$@"
fi
