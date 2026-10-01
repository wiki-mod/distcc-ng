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

# What: Absolute directory of this script, if it has one.
# Why: curl|bash bootstrap has no BASH_SOURCE; must not crash.
# From: Issue #479
CI_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
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

# What: The known ci.sh subcommands.
# Why: One list drives dispatch and error text (no twin).
# From: Issue #479
CI_COMMANDS="checkout plan impact impact-hit build cache test e2e scan lint selftest metadata package container publish release gc report gate verify variables install harden workload image sot-update attest"

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
    [ -f "${CI_MANIFEST}" ] && return 0
    ci_log "[CI-ERROR-CORE-0003]" "manifest=\"${CI_MANIFEST}\" reason=\"manifest not found\""
    return 2
}

# =========================================================
# SOT READERS (awk only; no yq/jq/python)
# =========================================================

# What: Print the scalar at a dotted SOT path; fail if absent.
# Why: A missing pin must never read as an empty value.
# From: Issue #479, PR #544
_ci_sot_scalar() {
    local path="$1" rc=0
    _ci_sot_lookup "${path}" || rc=$?
    if [ "${rc}" -eq 3 ]; then
        ci_log "[CI-ERROR-SOT-0002]" "path=\"${path}\" reason=\"not found in SOT\""
        return 2
    fi
    return "${rc}"
}

# What: Print an optional SOT value; empty if absent.
# Why: For per-entry keys only, e.g. opt_in or brew.
# From: Issue #479, PR #544
_ci_sot_optional() {
    local rc=0
    _ci_sot_lookup "$1" || rc=$?
    [ "${rc}" -eq 3 ] || return "${rc}"
}

# What: awk lookup of a dotted SOT path; exit 3 if absent.
# Why: Lets scalar fail closed and optional stay explicit.
# From: Issue #479, PR #544
_ci_sot_lookup() {
    local path="$1"
    awk -v path="${path}" '
        BEGIN { n = split(path, want, "."); need = 1; found = 0 }
        END { if (!found) exit 3 }
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
                print val; found = 1; exit
            }
            need++
        }
    ' "${CI_MANIFEST}"
}

# What: Print child keys of a dotted SOT path; fail if absent.
# Why: A missing section must not read as zero variants.
# From: Issue #479, PR #544
_ci_sot_children() {
    local path="$1" rc=0
    awk -v path="${path}" '
        BEGIN { n = split(path, want, "."); need = 1; inside = 0; childind = 0 }
        END { if (!inside) exit 3 }
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
    ' "${CI_MANIFEST}" || rc=$?
    if [ "${rc}" -eq 3 ]; then
        ci_log "[CI-ERROR-SOT-0002]" "path=\"${path}\" reason=\"not found in SOT\""
        return 2
    fi
    return "${rc}"
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
        | grep -v '^[[:space:]]*$' || [ "$?" -eq 1 ]
}

# What: Set the scalar at a dotted SOT path in place.
# Why: The one SOT writer; an absent path fails closed.
# From: Issue #479, PR #544
_ci_sot_set() {
    local path="$1" value="$2" tmp rc=0
    tmp="$(mktemp)" || return 2
    awk -v path="${path}" -v value="${value}" '
        BEGIN { n = split(path, want, "."); need = 1; done = 0 }
        done || /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
        {
            match($0, /^ */); ind = RLENGTH / 2
            if (ind + 1 < need) { need = ind + 1 }
            key = $0; sub(/^ +/, "", key); sub(/:.*$/, "", key)
            if (ind + 1 == need && key == want[need]) {
                if (need == n) {
                    match($0, /^ *[^:]*:/)
                    print substr($0, 1, RLENGTH) " \"" value "\""
                    done = 1
                    next
                }
                need++
            }
            print
        }
        END { if (!done) exit 3 }
    ' "${CI_MANIFEST}" > "${tmp}" || rc=$?
    if [ "${rc}" -ne 0 ]; then
        rm -f "${tmp}"
        ci_log "[CI-ERROR-SOT-0002]" "path=\"${path}\" reason=\"cannot set (rc ${rc})\""
        return 2
    fi
    cat "${tmp}" > "${CI_MANIFEST}" || return 2
    rm -f "${tmp}"
}

# =========================================================
# PATH CLASSIFICATION (impact)
# =========================================================

# What: Match one SOT path glob to a path.
# Why: The SOT owns the patterns; this owns matching.
# From: Issue #479
_ci_glob_match() {
    local pat="$1" path="$2" re
    # What: Escape regex metachars, then turn '*' runs into '.*'.
    # Why: =~ needs a real regex; case and [[ == warn here.
    # From: Issue #479
    re="${pat//\*/$'\x01'}"
    re="$(printf '%s' "${re}" | sed 's/[.^$+?()[\]{}|]/\\&/g')"
    re="${re//$'\x01'/.*}"
    [[ "${path}" =~ ^${re}$ ]]
}

# What: Print impact classes matched by paths on stdin.
# Why: DEFAULT=NOOP; only a matched class selects any phase.
# From: Issue #479
_ci_classify_paths() {
    local classes path cls pat pats
    classes="$(_ci_sot_children impact_classes)" || return 2
    while IFS= read -r path; do
        [ -n "${path}" ] || continue
        for cls in ${classes}; do
            pats="$(_ci_sot_list "impact_classes.${cls}.paths")" || return 2
            while IFS= read -r pat; do
                [ -n "${pat}" ] || continue
                if _ci_glob_match "${pat}" "${path}"; then
                    printf '%s\n' "${cls}"
                    break
                fi
            done <<< "${pats}"
        done
    done | sort -u
}

# What: Print the validate phases selected by paths on stdin.
# Why: NOOP when no matched class selects any job (docs only).
# From: Issue #479, PR #544
_ci_phases_for_paths() {
    local classes cls phases=""
    classes="$(_ci_classify_paths)" || return 2
    for cls in ${classes}; do
        phases="${phases}$(_ci_sot_list "impact_classes.${cls}.phases")"$'\n' || return 2
    done
    phases="$(grep -v '^$' <<< "${phases}" | sort -u)" || [ "$?" -eq 1 ] || return 2
    printf '%s\n' "${phases:-NOOP}"
}

# =========================================================
# PARALLELISM
# =========================================================

# What: bats job count = max(16, nproc*2).
# Why: Parallel is mandatory; a floor keeps runners busy.
# From: Issue #479
_ci_jobs() {
    local n j
    n="$(nproc 2>/dev/null || printf '4')"
    j=$(( n * 2 ))
    [ "${j}" -lt 16 ] && j=16
    printf '%s\n' "${j}"
}

# =========================================================
# EXECUTION (one owner each: wait, name, build, run, stack)
# =========================================================

# What: Retry a probe until it succeeds; fail after N tries.
# Why: One bounded poll owner; callers own only the probe.
# From: Issue #479, PR #544
_ci_wait_until() {
    local tries="$1" pause="$2" i
    shift 2
    for ((i = 1; i <= tries; i++)); do
        if "$@"; then
            return 0
        fi
        if [ "${i}" -lt "${tries}" ]; then
            sleep "${pause}"
        fi
    done
    return 1
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
    logs="$(docker logs "${ctr}" 2>&1)" || return 1
    grep -qE -- "${re}" <<< "${logs}"
}

# What: docker build one SOT image spec; ARGs from the SOT.
# Why: Sole pin path; Dockerfiles carry no default or LABEL.
# From: Issue #359, Issue #479, PR #544
_ci_image_build() {
    local spec="$1" version="$2" file target raw arg val tag desc ref
    shift 2
    local specs=() opts=()
    file="$(_ci_sot_scalar "${spec}.dockerfile")" || return 2
    target="$(_ci_sot_scalar "${spec}.target")" || return 2
    raw="$(_ci_sot_list "${spec}.args")" || return 2
    mapfile -t specs <<< "${raw}"
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
        ref="${BUILT_SHA:-$(git -C "${CI_REPO_ROOT}" rev-parse HEAD)}" || return 1
        val="$(_ci_sot_scalar release.licenses)" || return 2
        opts+=(--label "org.opencontainers.image.title=${spec##*.}"
            --label "org.opencontainers.image.description=${desc}"
            --label "org.opencontainers.image.version=${version}"
            --label "org.opencontainers.image.revision=${ref}"
            --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            --label "org.opencontainers.image.source=${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}"
            --label "org.opencontainers.image.licenses=${val}")
    fi
    docker build "$@" --file "${CI_REPO_ROOT}/${file}" --target "${target}" \
        "${opts[@]}" "${CI_REPO_ROOT}"
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
    mapfile -t ctrs < <(docker ps -aq --filter "label=${CI_STACK_LABEL}=${net}") || rc=1
    for c in "${ctrs[@]}"; do
        echo "== ${net}: last 100 log lines of ${c} =="
        docker logs --tail 100 "${c}" || rc=1
    done
    if [ "${#ctrs[@]}" -gt 0 ]; then
        docker rm -f "${ctrs[@]}" >/dev/null || rc=1
    fi
    mapfile -t vols < <(docker volume ls -q --filter "label=${CI_STACK_LABEL}=${net}") || rc=1
    if [ "${#vols[@]}" -gt 0 ]; then
        docker volume rm "${vols[@]}" >/dev/null || rc=1
    fi
    if docker network inspect "${net}" >/dev/null 2>&1; then
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
    printf '%s\n' "${REGISTRY_TOKEN}" | docker login ghcr.io -u "${GITHUB_ACTOR}" --password-stdin
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

# =========================================================
# PHASES
# =========================================================

# What: Print the phases selected by the base..head diff.
# Why: A docs-only diff selects doc-lint, never a compile.
# From: Issue #479
ci_cmd_impact() {
    local base="${1:?base ref required}" head="${2:?head ref required}"
    cd "${CI_REPO_ROOT}"
    git diff --name-only "${base}" "${head}" | _ci_phases_for_paths
}

# What: Write hit=true/false for one impact class.
# Why: One command; no pipe or && chain in the workflow.
# From: Issue #479
ci_cmd_impact_hit() {
    local class="${1:?class required}" base="${2:?base ref required}" head="${3:?head ref required}"
    cd "${CI_REPO_ROOT}"
    if git diff --name-only "${base}" "${head}" | _ci_classify_paths | grep -qx "${class}"; then
        _ci_output hit true
    else
        _ci_output hit false
    fi
}

# What: Emit the variant x os build matrix JSON from SOT.
# Why: One owner feeds strategy.matrix; opt-in excluded.
# From: Issue #479
ci_cmd_matrix() {
    local v os first=1 out='{"include":[' apt brew variants oses
    variants="$(_ci_sot_children build_matrix.variants)" || return 2
    for v in ${variants}; do
        [ "$(_ci_sot_optional "build_matrix.variants.${v}.opt_in")" = "true" ] && continue
        apt="$(_ci_sot_scalar "build_matrix.variants.${v}.apt")" || return 2
        brew="$(_ci_sot_optional "build_matrix.variants.${v}.brew")" || return 2
        oses="$(_ci_sot_list "build_matrix.variants.${v}.os")" || return 2
        for os in ${oses}; do
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

# What: Write phases/build/matrix for the base..head diff.
# Why: One command feeds the orchestrator; no YAML logic.
# From: Issue #479
ci_cmd_plan() {
    local base="${1:-}" head="${2:-HEAD}"
    local phases build=false matrix
    cd "${CI_REPO_ROOT}" || return 1
    if [ -z "${base}" ] || ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1; then
        # What: An unknown base (first push) selects every phase.
        # Why: No diff exists to classify; NOOP would skip all.
        # From: Issue #479
        phases="build e2e verify container package"
    else
        phases="$(git diff --name-only "${base}" "${head}" \
            | _ci_phases_for_paths | tr '\n' ' ')" || return 2
        phases="${phases% }"
    fi
    case " ${phases} " in *" build "*) build=true ;; esac
    matrix='{"include":[]}'
    if [ "${build}" = "true" ]; then
        matrix="$(ci_cmd_matrix)" || return 2
    fi
    _ci_output phases "${phases}" build "${build}" matrix "${matrix}"
}

# What: Write the control-build's toolchain/dist verdict.
# Why: The raw trace log alone was hard to untangle.
# From: Issue #263, Issue #479
_ci_control_build_step_summary() {
    local st="$1"
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
    if [ "${st}" -eq 0 ]; then
        printf '## Control build: OK\n\nPlain-compiler ccache build succeeded; a same-run heartbeat failure is a distccd/distribution bug, not a toolchain issue.\n' \
            >> "${GITHUB_STEP_SUMMARY}"
    else
        printf '## Control build: FAILED (exit %s)\n\nThe plain-compiler ccache build itself failed, with no distcc involved; a same-run heartbeat failure is toolchain/ccache-related, not a distccd bug.\n' \
            "${st}" >> "${GITHUB_STEP_SUMMARY}"
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
    local log="$1"
    if grep -Eq 'EMERGENCY! |ALERT! |CRITICAL! |ERROR: |Warning: ' "${log}"; then
        ci_log "[CI-ERROR-E2E-0015]" "distcc-ng distccd logged warning-or-worse lines:"
        grep -E 'EMERGENCY! |ALERT! |CRITICAL! |ERROR: |Warning: ' "${log}" >&2
        return 1
    fi
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
    _ci_container_run "${srv_image}" -d --name "${srv}" --network-alias distccd-server -- \
        distccd --no-detach --daemon --verbose --log-stderr --port 3632 \
        --allow "${subnet}" --jobs "$(nproc)" >/dev/null || return 1
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
        need="$(tail -n 1 "${out}.client" | tr -dc '0-9')"
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
    mapfile -t legs < <(_ci_sot_list "e2e.modes.${mode}.legs") || return 2
    mapfile -t passes < <(_ci_sot_list "e2e.modes.${mode}.passes") || return 2
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
    local mode="$1" workload extra floor attempts attempt=1 net
    workload="$(_ci_sot_scalar "e2e.modes.${mode}.workload")" || return 2
    extra="$(_ci_sot_scalar "e2e.modes.${mode}.extra")" || return 2
    floor="$(_ci_sot_scalar "e2e.modes.${mode}.floor")" || return 2
    attempts="$(_ci_sot_scalar "e2e.modes.${mode}.max_attempts")" || return 2
    _ci_e2e_images || return 1
    while :; do
        net="$(_ci_run_name "e2e-${mode}-${attempt}")"
        ci_log "[CI-E2E]" "${mode}: attempt ${attempt}/${attempts}"
        if _ci_stack_run "${net}" _ci_e2e_mode_run "${mode}" "${workload}" "${extra}" "${floor}"; then
            ci_log "[CI-E2E]" "${mode}: PASS"
            return 0
        fi
        if [ "${attempt}" -ge "${attempts}" ]; then
            ci_log "[CI-ERROR-E2E-0006]" "${mode}: failed on all ${attempts} attempt(s)"
            return 1
        fi
        attempt=$((attempt + 1))
    done
}

# What: Run a SOT e2e mode, or the ccache control build.
# Why: Unknown modes fail closed instead of running a default.
# From: Issue #479, PR #544
ci_cmd_e2e() {
    cd "${CI_REPO_ROOT}"
    local mode="${1:-distributed}" st=0 image
    case "${mode}" in
        control)
            _ci_e2e_images || return 1
            image="$(_ci_sot_scalar e2e.images.ng.tag)" || return 2
            _ci_container_run "${image}" -- \
                bash "${CI_CONTAINER_SH}" workload ccache local /work/workload/control "" || st=$?
            _ci_control_build_step_summary "${st}"
            return "${st}" ;;
        *)
            if ! _ci_sot_optional "e2e.modes.${mode}.workload" | grep -q .; then
                ci_log "[CI-ERROR-E2E-0013]" "unknown e2e mode=\"${mode}\" (control or an e2e.modes key)"
                return 2
            fi
            _ci_e2e_mode "${mode}" ;;
    esac
}

# =========================================================
# IMAGES AND WORKLOADS (run inside the test containers)
# =========================================================

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
    _ci_make_gated /tmp/make.log -j"$(nproc)" || return 1
    install -D -t /out/usr/local/bin distcc distccd lsdistcc distccmon-text || return 1
    make install DESTDIR=/out-pump || return 1
    mv /out-pump/usr/local/bin/pump /out-pump/usr/local/bin/distcc-pump || return 1
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

# What: CFL toolchain: SOT packages, autoconf from source.
# Why: base-builder ships autoconf 2.69; we need 2.71.
# From: Issue #267, Issue #479, PR #544
_ci_image_cfl_toolchain() {
    local pkgs ver dest
    pkgs="$(_ci_sot_scalar security.cfl_image_apt)" || return 2
    ver="$(_ci_sot_scalar external_versions.autoconf.version)" || return 2
    _ci_apt_install "${pkgs}" image || return 1
    dest="$(_ci_fetch_tool external_versions.autoconf)" || return 1
    cd "${dest}/autoconf-${ver}" || return 1
    ./configure || return 1
    make -j"$(nproc)" || return 1
    make install || return 1
    rm -rf "${dest}"
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
    grep -qE -- "${regex}" <<< "${out}" || hit=1
    if [ "${hit}" -ne "${want}" ]; then
        ci_log "[CI-ERROR-SELFTEST-0001]" "${name}: output vs /${regex}/ wrong (negated=${want}, exit ${rc})"
        printf '%s\n' "${out}" >&2
        return 1
    fi
    ci_log "[CI-SELFTEST]" "${name}: OK (exit ${rc})"
}

# What: Source-build the SOT actionlint version into /out.
# Why: A release binary embeds a possibly stale Go stdlib.
# From: Issue #267, Issue #479, PR #544
_ci_image_actionlint() {
    local ver
    ver="$(_ci_sot_scalar external_versions.actionlint.version)" || return 2
    GOBIN=/out go install "github.com/rhysd/actionlint/cmd/actionlint@v${ver}" || return 1
    /out/actionlint --version
}

# What: Prove each verify-image tool works, not just exists.
# Why: A broken tool fails the build, not its first user.
# From: Issue #264 #275 #398, PR #273 #332 #544
_ci_verify_selftest() {
    local d port pid addr
    d="$(mktemp -d)"
    cd "${d}" || return 1
    printf 'int main(void) { return 0; }\n' > ok.c
    gcc ok.c -o ok_gcc || return 1
    ./ok_gcc || return 1
    clang ok.c -o ok_clang || return 1
    ./ok_clang || return 1
    gcc -g -O0 ok.c -o ok_dbg || return 1
    printf '#include <stdlib.h>\nint main(void) { char *p = malloc(8); p[8] = 1; return 0; }\n' > asan.c
    gcc -fsanitize=address -g asan.c -o asan || return 1
    _ci_expect_output asan 'AddressSanitizer: heap-buffer-overflow' ./asan || return 1
    printf '#include <limits.h>\nint main(void) { int x = INT_MAX; return x + 1; }\n' > ubsan.c
    gcc -fsanitize=undefined -g ubsan.c -o ubsan || return 1
    _ci_expect_output ubsan 'runtime error: signed integer overflow' ./ubsan || return 1
    printf '#include <stdlib.h>\nint main(void) { malloc(16); return 0; }\n' > leak.c
    gcc -g -O0 leak.c -o leak || return 1
    _ci_expect_output valgrind 'definitely lost: 16 bytes' valgrind --leak-check=full ./leak || return 1
    _ci_expect_output objdump 'main>:' objdump -d ok_gcc || return 1
    _ci_expect_output readelf 'ELF Header' readelf -h ok_gcc || return 1
    _ci_expect_output nm ' T main$' nm ok_gcc || return 1
    addr="$(nm ok_dbg | awk '$3 == "main" {print $1}')"
    _ci_expect_output addr2line '^main$' addr2line -f -e ok_dbg "${addr}" || return 1
    printf '%s\n' '#include <fcntl.h>' '#include <stdio.h>' '#include <libelf.h>' '#include <gelf.h>' \
        'int main(void) { GElf_Ehdr h; Elf *e; int fd = open("ok_gcc", O_RDONLY);' \
        '  if (fd < 0 || elf_version(EV_CURRENT) == EV_NONE) return 1;' \
        '  e = elf_begin(fd, ELF_C_READ, NULL);' \
        '  if (!e || !gelf_getehdr(e, &h)) return 1;' \
        '  printf("libelf_ok e_type=%d\n", h.e_type); return 0; }' > libelf.c
    gcc libelf.c -lelf -o libelf_check || return 1
    _ci_expect_output libelf 'libelf_ok' ./libelf_check || return 1
    printf 'needle_marker\nhaystack\n' > hay.txt
    _ci_expect_output ripgrep '^needle_marker$' rg needle_marker hay.txt || return 1
    _ci_expect_output grep '^needle_marker$' grep needle_marker hay.txt || return 1
    ccache --zero-stats >/dev/null || return 1
    ccache gcc -c ok.c -o ok.o || return 1
    ccache gcc -c ok.c -o ok.o || return 1
    _ci_expect_output ccache "${CI_CCACHE_HIT_RE}" ccache --show-stats || return 1
    python3 -u -c 'import socket,time; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(1); print(s.getsockname()[1]); time.sleep(60)' > port.txt &
    pid=$!
    _ci_wait_until 20 0.5 test -s port.txt || return 1
    port="$(head -n 1 port.txt)"
    _ci_expect_output ss ":${port} " ss -tln || return 1
    kill "${pid}" || return 1
    wait "${pid}" || [ "$?" -eq 143 ] || return 1
    exec 9< /etc/hostname
    _ci_expect_output lsof 'hostname' lsof -p "$$" || return 1
    exec 9<&-
    _ci_expect_output dig '^[0-9]+\.' dig +short deb.debian.org || return 1
    _ci_expect_output nslookup 'Address' nslookup deb.debian.org || return 1
    _ci_verify_selftest_ssh "${d}" || return 1
    printf '{"ok": true}\n' > doc.json
    _ci_expect_output jq '^true$' jq -e .ok doc.json || return 1
    printf '#!/bin/sh\nx="a b"\necho %sx\n' "\$" > sc.sh
    _ci_expect_output shellcheck 'SC2086' shellcheck sc.sh || return 1
    mkdir -p al/.github/workflows
    printf 'on: push\njobs:\n  test:\n    steps:\n      - run: echo hi\n' > al/.github/workflows/broken.yml
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
        'StrictModes no' 'PasswordAuthentication no' > "${d}/sshd_config"
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
    d="$(mktemp -d)"
    cd "${d}" || return 1
    printf 'int main(void) { return 0; }\n' > ok.c
    gcc -g -O0 ok.c -o ok_gcc || return 1
    _ci_expect_output gdb 'Breakpoint 1' \
        gdb -q -batch -ex 'break main' -ex run -ex continue ./ok_gcc || return 1
    # What: gdb must disable ASLR under the narrow profile.
    # Why: The breakpoint still hits when personality() is denied.
    # From: Issue #285
    _ci_expect_output gdb-aslr '!Error disabling address space randomization' \
        gdb -q -batch -ex 'break main' -ex run -ex continue ./ok_gcc || return 1
    _ci_expect_output strace '\+\+\+ exited with 0 \+\+\+' strace -f -e trace=execve ./ok_gcc || return 1
    printf '#include <stdlib.h>\nint main(void) { free(malloc(1)); return 0; }\n' > lt.c
    gcc -g -O0 lt.c -o lt || return 1
    _ci_expect_output ltrace 'malloc' ltrace -e 'malloc+free' ./lt || return 1
    # What: gdb runs python3-dbg itself, then py-bt.
    # Why: Yama ptrace_scope=1 forbids attaching to a sibling.
    # From: Issue #285
    printf 'import time\ndef target_function():\n    time.sleep(5)\ntarget_function()\n' > py.py
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
    : "${dir:?workdir required}"
    rm -rf "${dir}"
    mkdir -p "${dir}"
    cp -a "${CI_REPO_ROOT}/." "${dir}/src" || return 1
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
    # Why: ci.bats evidence must come from the buildtools image.
    # From: Issue #479, PR #544
    pkgs="${pkgs} $(_ci_sot_scalar ci_engine.selftest_apt)" || return 2
    _ci_apt_install "${pkgs}" image || return 1
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
        _ci_make_gated /tmp/make.log -j"$(nproc)" || return 1
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
        actionlint) _ci_image_actionlint ;;
        verify) _ci_image_verify ;;
        e2e-ng) _ci_image_e2e ng ;;
        e2e-native) _ci_image_e2e native ;;
        *) ci_log "[CI-ERROR-IMAGE-0001]" "unknown image target=\"${1:-}\" (release-build|release-runtime|cfl-toolchain|actionlint|verify|e2e-ng|e2e-native)"; return 2 ;;
    esac
}

# What: Print tarball, signature, key URL of pinned Samba.
# Why: One owner of Samba's release layout; it signs the .tar.
# From: Issue #264, Issue #285, Issue #479, PR #544
_ci_workload_samba_release() {
    local ver
    ver="$(_ci_sot_scalar external_versions.samba.version)" || return 2
    printf '%s\n' "https://download.samba.org/pub/samba/stable/samba-${ver}.tar.gz" \
        "https://download.samba.org/pub/samba/stable/samba-${ver}.tar.asc" \
        "https://download.samba.org/pub/samba/samba-pubkey.asc"
}

# What: Fetch Samba, GPG-verify it, extract a fresh tree.
# Why: VER-SOURCE: a bad signature is a hard stop.
# From: Issue #264, Issue #285, Issue #479, PR #544
_ci_workload_samba_fetch() {
    local dest="$1" cache
    local rel=()
    mapfile -t rel < <(_ci_workload_samba_release) || return 2
    [ "${#rel[@]}" -eq 3 ] || return 2
    cache="${CI_WORKLOAD_CACHE:-/tmp/ci-workload-cache}/samba"
    if [ ! -f "${cache}/.verified" ]; then
        rm -rf "${cache}"
        mkdir -p "${cache}/gnupg"
        chmod 700 "${cache}/gnupg"
        _ci_download "${rel[0]}" "${cache}/src.tar.gz" || return 1
        _ci_download "${rel[1]}" "${cache}/sig" || return 1
        _ci_download "${rel[2]}" "${cache}/key" || return 1
        gunzip -c "${cache}/src.tar.gz" > "${cache}/src.tar" || return 1
        GNUPGHOME="${cache}/gnupg" gpg --batch --import "${cache}/key" || return 1
        if ! GNUPGHOME="${cache}/gnupg" gpg --batch --verify "${cache}/sig" "${cache}/src.tar"; then
            ci_log "[CI-ERROR-WORKLOAD-0002]" "$(basename "${rel[0]}"): signature does not verify"
            return 1
        fi
        touch "${cache}/.verified"
    fi
    rm -rf "${dest}"
    mkdir -p "${dest}"
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
        pump) runner=(pump) ;;
        *) ci_log "[CI-ERROR-WORKLOAD-0005]" "self-compile pass=${pass} (plain|pump)"; return 2 ;;
    esac
    : "${dir:?workdir required}"
    rm -rf "${dir}"
    mkdir -p "${dir}"
    cp -a "${CI_REPO_ROOT}/." "${dir}/src" || return 1
    cd "${dir}/src" || return 1
    _ci_configure_tree "${dir}/configure.log" PYTHON=python3 || return 1
    "${runner[@]}" make -j"$(nproc)" "${make_cc[@]}" >&2 || return 1
    test -x ./distcc && test -x ./distccd || return 1
    if [ "${pass}" = "plain" ]; then
        probe="$(mktemp -d)"
        printf 'int distcc_e2e_probe(int x) { return (x * 2) + 1; }\n' > "${probe}/probe.c"
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
    local pass="${1:-}" dir="${2:-}" tag
    local launcher=()
    tag="$(_ci_sot_scalar external_versions.ccache_heartbeat.version)" || return 2
    case "${pass}" in
        plain) launcher=(-DCMAKE_C_COMPILER_LAUNCHER=distcc -DCMAKE_CXX_COMPILER_LAUNCHER=distcc) ;;
        local) ;;
        *) ci_log "[CI-ERROR-WORKLOAD-0004]" "ccache pass=${pass} (plain|local)"; return 2 ;;
    esac
    : "${dir:?workdir required}"
    rm -rf "${dir}"
    git clone --depth 1 --branch "${tag}" https://github.com/ccache/ccache "${dir}/src" >&2 || return 1
    # What: Two named -Wno-error flags, not -Werror off.
    # Why: GCC 12 false positives; other warnings still fail.
    # From: Issue #263
    cmake -S "${dir}/src" -B "${dir}/build" -DCMAKE_BUILD_TYPE=Release "${launcher[@]}" \
        -DCMAKE_CXX_FLAGS="-Wno-error=maybe-uninitialized -Wno-error=restrict" \
        -DENABLE_TESTING=OFF >&2 || return 1
    cmake --build "${dir}/build" -j"$(nproc)" >&2 || return 1
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
        *) ci_log "[CI-ERROR-WORKLOAD-0005]" "samba pass=${pass} (plain|pump|configure)"; return 2 ;;
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
    build=(./buildtools/bin/waf build -j"$(nproc)")
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
    local skip rename raw f base prefix sysconfdir datarootdir t lib
    local cflags=() cxxflags=() engine=() libs=() defs=() extra=() objs=()
    read -ra cflags <<< "${CFLAGS:-}"
    read -ra cxxflags <<< "${CXXFLAGS:-}"
    read -ra engine <<< "${LIB_FUZZING_ENGINE}"
    raw="$(_ci_sot_list security.cfl_fuzz.exclude_main)" || return 2
    skip=" $(tr '\n' ' ' <<< "${raw}")"
    raw="$(_ci_sot_list security.cfl_fuzz.rename_main)" || return 2
    rename=" $(tr '\n' ' ' <<< "${raw}")"
    cd "${CI_REPO_ROOT}" || return 1
    # What: --with-auth builds auth_common.c's GSSAPI symbols.
    # Why: The link takes every src/*.c, auth_common.c included.
    # From: Issue #267
    _ci_configure_tree /tmp/fuzz-configure.log PYTHON=python3 --disable-pump-mode --with-auth || return 1
    # What: Rebuild Makefile.in's DIR_DEFS for direct compiles.
    # Why: They are Makefile-only; config.h never carries them.
    # From: Issue #267
    prefix="$(sed -n 's/^prefix = //p' Makefile)" || return 1
    sysconfdir="$(sed -n 's/^sysconfdir = //p' Makefile)" || return 1
    datarootdir="$(sed -n 's/^datarootdir = //p' Makefile)" || return 1
    sysconfdir="${sysconfdir//\$\{prefix\}/${prefix}}"
    sysconfdir="${sysconfdir//\$(prefix)/${prefix}}"
    datarootdir="${datarootdir//\$\{prefix\}/${prefix}}"
    datarootdir="${datarootdir//\$(prefix)/${prefix}}"
    defs=("-DLIBDIR=\"${prefix}/lib\"" "-DSYSCONFDIR=\"${sysconfdir}\"" "-DICONDIR=\"${datarootdir}/pixmaps\"")
    for f in src/*.c lzo/minilzo.c; do
        base="$(basename "${f}" .c)"
        case "${skip}" in *" ${base} "*) continue ;; esac
        extra=()
        case "${rename}" in *" ${base} "*) extra=("-Dmain=distccng_disabled_main_${base}") ;; esac
        "${CC}" "${cflags[@]}" -Isrc -Ilzo -DHAVE_CONFIG_H "${defs[@]}" "${extra[@]}" \
            -c "${f}" -o "${OUT}/${base}.o" || return 1
        objs+=("${OUT}/${base}.o")
    done
    read -ra libs <<< "$(sed -n 's/^LIBS = //p' Makefile)"
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
        while read -r lib; do
            case "$(basename "${lib}")" in
                libavahi-*|libpopt.*) cp -L "${lib}" "${OUT}/" || return 1 ;;
            esac
        done < <(awk '/=>/ {print $3} !/=>/ {if ($1 ~ /^\//) print $1}' <<< "${raw}")
    done
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

# =========================================================
# PACKAGING / RELEASE
# =========================================================

# What: Build the source tarball and packages (make deb).
# Why: A missing packaging tool fails before any build.
# From: Issue #479
ci_cmd_package() {
    local py tool log="${RUNNER_TEMP:-/tmp}/ci-package.log"
    cd "${CI_REPO_ROOT}" || return 1
    py="$(command -v python3.13 || command -v python3)" || return 1
    for tool in "${py}" pkg-config eu-strip rpmbuild alien fakeroot; do
        command -v "${tool}" >/dev/null 2>&1 \
            || { ci_log "[CI-ERROR-PACKAGE-0001]" "missing tool: ${tool}"; return 1; }
    done
    _ci_configure_tree "${log}.configure" PYTHON="${py}" --enable-Werror || return 1
    _ci_make_gated "${log}" -j"${JOBS:-2}" deb
}

# What: Generate an SBOM for the just-built source tarball.
# Why: OSPS-QA-02.02; scans the exact asset a release ships.
# From: Issue #479
_ci_package_sbom() {
    local out="${1:?output file required}" tarball
    cd "${CI_REPO_ROOT}"
    tarball="$(find . -maxdepth 1 -name 'distcc-*.tar.gz' -print -quit)"
    [ -n "${tarball}" ] || {
        ci_log "[CI-ERROR-PACKAGE-0002]" "no distcc-*.tar.gz found"
        return 1
    }
    ci_cmd_sbom "${tarball}" "${out}"
}

# What: Fail unless a release tag matches configure.ac.
# Why: POL-RELEASE-05/07; require_new=false once pushed.
# From: Issue #479, PR #544
_ci_check_release_version() {
    local tag="${1:?tag required}" require_new="${2:-true}" version configured
    version="${tag#v}"
    cd "${CI_REPO_ROOT}"
    [ -f configure.ac ] || { ci_log "[CI-ERROR-RELEASE-0001]" "no configure.ac"; return 1; }
    configured="$(sed -n 's/^AC_INIT(\[distcc-ng\],\[\([^]]*\)\].*/\1/p' configure.ac)"
    [ -n "${configured}" ] || { ci_log "[CI-ERROR-RELEASE-0002]" "cannot parse AC_INIT version"; return 1; }
    if [ "${configured}" != "${version}" ]; then
        ci_log "[CI-ERROR-RELEASE-0003]" "configure.ac=${configured} != tag ${tag}"
        return 1
    fi
    if [ "${require_new}" = "true" ] && git rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1; then
        ci_log "[CI-ERROR-RELEASE-0004]" "tag ${tag} already exists"
        return 1
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
            image="$(_ci_release_image nightly latest)" || return 2
            _ci_image_build release.images.distcc-ng-nightly nightly --tag "${image}" || return 1
            _ci_registry_push "${image}" || return 1
            _ci_output image "${image}" ;;
        verify-image)
            short="$(git -C "${CI_REPO_ROOT}" rev-parse --short HEAD)" || return 1
            _ci_image_build release.images.distcc-ng-buildtools "${short}" ;;
        buildtools)
            short="$(git -C "${CI_REPO_ROOT}" rev-parse --short HEAD)" || return 1
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
            case "${variant}" in
                plain|pump) ;;
                *) ci_log "[CI-ERROR-CONTAINER-0002]" "release variant=${variant} (plain|pump)"; return 2 ;;
            esac
            image="$(_ci_release_image "${variant}" "${version}" "${platform}")" || return 2
            pkg="${image##*/}"
            _ci_image_build "release.images.${pkg%%:*}" "${version}" \
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

# What: Print the built release assets the SOT globs match.
# Why: Nightly and release ship one set; none found fails.
# From: Issue #362, Issue #479, PR #544
_ci_release_assets() {
    local pats pat found=0
    pats="$(_ci_sot_list release.assets)" || return 2
    cd "${CI_REPO_ROOT}" || return 1
    while IFS= read -r pat; do
        compgen -G "${pat}" && found=1
    done <<< "${pats}"
    if [ "${found}" -eq 0 ]; then
        ci_log "[CI-ERROR-PUBLISH-0007]" "no release asset matches release.assets"
        return 1
    fi
}

# What: Force-move the nightly tag; republish its prerelease.
# Why: It refuses to move a real v* release tag.
# From: Issue #479
_ci_publish_nightly() {
    local tag="${NIGHTLY_TAG:?NIGHTLY_TAG required}" ref repo notes image
    local assets=()
    case "${tag}" in
        v*) ci_log "[CI-ERROR-PUBLISH-0002]" "refusing to force-move a v* tag: ${tag}"; return 1 ;;
    esac
    image="$(_ci_release_image nightly latest)" || return 2
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    repo="${GITHUB_REPOSITORY}"
    cd "${CI_REPO_ROOT}" || return 1
    ref="${BUILT_SHA:-$(git rev-parse HEAD)}" || return 1
    mapfile -t assets < <(_ci_release_assets)
    [ "${#assets[@]}" -gt 0 ] || return 1
    _ci_git_identity || return 1
    _ci_mutate git tag -f "${tag}" || return 1
    _ci_git_auth_setup || return 1
    _ci_mutate git push -f origin "refs/tags/${tag}" || return 1
    notes="$(mktemp)" || return 1
    {
        printf 'Automated nightly build of current_dev (%s).\n\n' "${ref}"
        printf 'Unstable nightly channel -- NOT a real release; overwritten each run.\n\n'
        printf 'Container image: %s\n' "${image}"
    } > "${notes}"
    if gh release view "${tag}" --repo "${repo}" >/dev/null 2>&1; then
        _ci_mutate gh release delete "${tag}" --repo "${repo}" --yes || return 1
    fi
    _ci_mutate gh release create "${tag}" "${assets[@]}" --repo "${repo}" \
        --title "distcc-ng nightly" --notes-file "${notes}" \
        --prerelease --latest=false --target "${ref}"
}

# What: Create the multi-arch manifest from pushed tags.
# Why: imagetools reads the registry; no artifact handoff.
# From: Issue #479
_ci_publish_manifest() {
    local variant="${1:?variant required}" base out ctx=()
    mapfile -t ctx < <(_ci_release_context) || return 2
    [ "${#ctx[@]}" -eq 4 ] || return 2
    base="$(_ci_release_image "${variant}" "${ctx[0]}")" || return 2
    local tags=("${base}-amd64")
    _ci_registry_login || return 1
    if out="$(docker buildx imagetools inspect "${base}-arm64" 2>&1)"; then
        tags+=("${base}-arm64")
    elif grep -qi 'not found' <<< "${out}"; then
        ci_log "[CI-PUBLISH]" "no arm64 image; amd64-only manifest for ${variant}"
    else
        ci_error "[CI-ERROR-PUBLISH-0006]" "cannot inspect ${base}-arm64" "${out}"
        return 1
    fi
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
    local tag="${1:?tag required}" repo notes
    local assets=()
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    repo="${GITHUB_REPOSITORY}"
    _ci_check_release_version "${tag}" || return 1
    mapfile -t assets < <(_ci_release_assets)
    [ "${#assets[@]}" -gt 0 ] || return 1
    notes="$(mktemp)" || return 1
    printf 'distcc-ng %s\n' "${tag}" > "${notes}" || return 1
    _ci_mutate gh release create "${tag}" "${assets[@]}" --repo "${repo}" \
        --target "${GITHUB_SHA:?GITHUB_SHA required}" \
        --title "distcc-ng ${tag}" --notes-file "${notes}" --latest
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

# What: Insert the notes a release or a dispatch carries.
# Why: A pre-release or a dispatch without notes adds nothing.
# From: Issue #479, PR #544
_ci_publish_changelog_event() {
    local tag body
    : "${GITHUB_EVENT_PATH:?GITHUB_EVENT_PATH required}"
    case "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME required}" in
        release)
            if [ "$(jq -r '.release.prerelease' "${GITHUB_EVENT_PATH}")" != "false" ]; then
                ci_log "[CI-PUBLISH-CHANGELOG]" "skipped: pre-release"
                return 0
            fi
            tag="$(jq -er '.release.tag_name' "${GITHUB_EVENT_PATH}")" || return 2
            body="$(jq -r '.release.body // ""' "${GITHUB_EVENT_PATH}")" || return 2 ;;
        workflow_dispatch)
            tag="$(jq -er '.inputs.tag' "${GITHUB_EVENT_PATH}")" || return 2
            body="$(jq -r '.inputs.release_notes // ""' "${GITHUB_EVENT_PATH}")" || return 2
            if [ -z "${body}" ]; then
                ci_log "[CI-PUBLISH-CHANGELOG]" "skipped: no release_notes on this dispatch"
                return 0
            fi ;;
        *) ci_log "[CI-ERROR-PUBLISH-0007]" "event ${GITHUB_EVENT_NAME} carries no release notes"; return 2 ;;
    esac
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
    date="$(date -u +%Y-%m-%d)"
    cd "${CI_REPO_ROOT}"
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
    } > "${tmp}"
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
    rm -f "${tmp}"
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
    local -n out_ref="$1" heading="$2"
    shift 2
    [ "$#" -eq 0 ] && return 0
    out_ref="${out_ref}### ${heading}
$(printf '%s\n' "$@")
"
}

# What: Rebuild the draft release from PR titles + rule 71.
# Why: Category comes from rule 71's type prefix, not regex.
# From: Issue #479
_ci_publish_draft_release() {
    : "${GH_TOKEN:?GH_TOKEN required}"
    : "${REPO:?REPO required}"
    local since since_date pr_json number title category
    local security=() bug=() enhancement=() documentation=()
    since="$(gh release list --repo "${REPO}" --exclude-drafts \
        --exclude-pre-releases --json tagName,publishedAt \
        --jq 'sort_by(.publishedAt) | last | .publishedAt // empty')"
    since_date="${since:-2000-01-01}"
    pr_json="$(gh pr list --repo "${REPO}" --state merged --base current_dev \
        --search "merged:>=${since_date}" --json number,title --limit 200)"
    while IFS=$'\t' read -r number title; do
        [ -n "${number}" ] || continue
        category="$(_ci_pr_category_label "${title}")"
        case "${category}" in
            security)      security+=("* #${number} | ${title}") ;;
            bug)           bug+=("* #${number} | ${title}") ;;
            enhancement)   enhancement+=("* #${number} | ${title}") ;;
            documentation) documentation+=("* #${number} | ${title}") ;;
        esac
    done < <(printf '%s' "${pr_json}" | jq -r '.[] | [.number, .title] | @tsv')

    local body=""
    _ci_draft_release_append body "Security" "${security[@]}"
    _ci_draft_release_append body "Fixed" "${bug[@]}"
    _ci_draft_release_append body "Added" "${enhancement[@]}"
    _ci_draft_release_append body "Documentation" "${documentation[@]}"

    local notes; notes="$(mktemp)"
    printf '%s' "${body}" > "${notes}"
    if gh release view draft-current_dev --repo "${REPO}" >/dev/null 2>&1; then
        gh release edit draft-current_dev --repo "${REPO}" --notes-file "${notes}"
    else
        gh release create draft-current_dev --repo "${REPO}" --draft \
            --title "Next release (draft)" --notes-file "${notes}" \
            --target current_dev
    fi
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
        draft-release)  _ci_publish_draft_release ;;
        *) ci_log "[CI-ERROR-PUBLISH-0001]" "unimplemented publish target=\"${sub}\""; return 2 ;;
    esac
}

# What: Release subcommands; only version-check exists.
# Why: The version guardrail runs anywhere, side-effect free.
# From: Issue #479
ci_cmd_release() {
    local sub="${1:-}"
    if [ "$#" -gt 0 ]; then shift; fi
    case "${sub}" in
        version-check) _ci_release_version_check "$@" ;;
        *) ci_log "[CI-ERROR-RELEASE-0005]" "unknown release subcommand=\"${sub}\" (version-check)"; return 2 ;;
    esac
}

# What: Print tag, require_new, publish, tag_push of this run.
# Why: A dispatch names its tag in inputs; a tag push is one.
# From: Issue #479, PR #544, POL-RELEASE-05, POL-RELEASE-07
_ci_release_context() {
    local tag publish
    case "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME required}" in
        workflow_dispatch)
            : "${GITHUB_EVENT_PATH:?GITHUB_EVENT_PATH required}"
            tag="$(jq -er '.inputs.tag' "${GITHUB_EVENT_PATH}")" || {
                ci_log "[CI-ERROR-RELEASE-0006]" "dispatch without inputs.tag"
                return 2
            }
            publish="$(jq -r '.inputs.publish_container // false' "${GITHUB_EVENT_PATH}")" || return 2
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
# From: Issue #479, PR #544, POL-RELEASE-05, POL-RELEASE-06
_ci_release_version_check() {
    local ctx=()
    if [ "$#" -gt 0 ]; then
        _ci_check_release_version "$1" true
        return
    fi
    mapfile -t ctx < <(_ci_release_context) || return 2
    [ "${#ctx[@]}" -eq 4 ] || return 2
    _ci_check_release_version "${ctx[0]}" "${ctx[1]}" || return 1
    _ci_output tag "${ctx[0]}" publish "${ctx[2]}" tag_push "${ctx[3]}"
}

# What: Print the GHCR reference of a published image.
# Why: One owner of variant->package and tag naming.
# From: Issue #359, Issue #479, PR #544
_ci_release_image() {
    local variant="$1" tag="$2" platform="${3:-}" pkg
    case "${variant}" in
        plain) pkg="distcc-ng" ;;
        pump) pkg="distcc-ng-pump" ;;
        nightly) pkg="distcc-ng-nightly" ;;
        *) ci_log "[CI-ERROR-CONTAINER-0002]" "image variant=${variant} (plain|pump|nightly)"; return 2 ;;
    esac
    printf 'ghcr.io/%s/%s:%s%s\n' "${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER required}" \
        "${pkg}" "${tag}" "${platform:+-${platform}}"
}

# What: JSON array of digests a live multi-arch index holds.
# Why: Deleting such a child breaks pulls; errors abort.
# From: Issue #479, PR #544
_ci_gc_protected_digests() {
    local pkg="$1" versions="$2" tag raw children=""
    while IFS= read -r tag; do
        [ -n "${tag}" ] || continue
        if ! raw="$(docker buildx imagetools inspect --raw "ghcr.io/${OWNER:?OWNER required}/${pkg}:${tag}")"; then
            ci_log "[CI-ERROR-GC-0002]" "cannot inspect ${pkg}:${tag}; refusing to prune ${pkg}"
            return 1
        fi
        children+="$(jq -r '.manifests[]?.digest' <<< "${raw}")"$'\n'
    done < <(jq -r '[.[].metadata.container.tags[]?] | unique | .[]' <<< "${versions}")
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
    : "${OWNER:?OWNER required, e.g. wiki-mod}"
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
    _ci_registry_login
    for pkg in ${pkgs}; do
        echo "::group::${pkg}"
        versions="$(gh api --paginate "orgs/${OWNER}/packages/container/${pkg}/versions" | jq -s 'add // []')" || return 1
        protected="$(_ci_gc_protected_digests "${pkg}" "${versions}")" || return 1
        candidates="$(_ci_gc_candidates "${versions}" "${protected}" "${ku}" "${re}" "${ks}")" || return 1
        while IFS=$'\t' read -r id why; do
            [ -n "${id}" ] || continue
            ci_log "[CI-GC]" "${pkg}#${id}: delete (${why})"
            _ci_mutate gh api --method DELETE "orgs/${OWNER}/packages/container/${pkg}/versions/${id}" --silent
        done <<< "${candidates}"
        echo "::endgroup::"
    done
}

# =========================================================
# SOT PIN REFRESH (ci.sh owns every pin update)
# =========================================================

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
    done <<< "${tags}" | sort -V | tail -n 1)"
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
        ci_log "[CI-ERROR-SOT-0006]" "${src} ${tag}: no recorded sha256 for ${asset}"
        return 1
    fi
    printf '%s\n' "${sha#sha256:}"
}

# What: Move every SOT pin to its channel's newest release.
# Why: Prints one markdown row per change for the PR body.
# From: Issue #479, PR #544
_ci_sot_refresh() {
    local sect key keys path ref tag old new src ver latest sha
    for sect in base_images external_services; do
        keys="$(_ci_sot_children "${sect}")" || return 2
        for key in ${keys}; do
            path="${sect}.${key}"
            ref="$(_ci_sot_scalar "${path}")" || return 2
            tag="${ref%@*}"
            old="${ref##*@}"
            if [ "${tag}" = "${ref}" ] || [[ "${tag##*/}" != *:* ]]; then
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
        if [ -n "$(_ci_sot_optional "${path}.url")" ]; then
            sha="$(_ci_release_asset_sha "${path}" "${latest}")" || return 1
            _ci_sot_set "${path}.sha256" "${sha}" || return 2
        fi
        printf "| \`%s\` | \`%s\` | \`%s\` | \`%s\` |\n" "${path}" "${src}" "${ver}" "${latest}"
    done
}

# What: Open or refresh the one SOT pin update pull request.
# Why: GITHUB_TOKEN PRs start no CI, so a dispatch runs it.
# From: Issue #479, PR #544
ci_cmd_sot_update() {
    : "${GH_TOKEN:?GH_TOKEN required}"
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    local branch="sot-update" title="chore(deps): refresh SOT pins" rows body open wf
    cd "${CI_REPO_ROOT}" || return 1
    rows="$(_ci_sot_refresh)" || return 1
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
    cat "${body}"
    _ci_git_identity || return 1
    _ci_mutate git checkout -q -B "${branch}" || return 1
    _ci_mutate git commit -q -m "${title}" -- "${CI_MANIFEST}" || return 1
    _ci_git_auth_setup || return 1
    _ci_mutate git push -q -f origin "HEAD:refs/heads/${branch}" || return 1
    open="$(gh pr list --repo "${GITHUB_REPOSITORY}" --head "${branch}" --state open \
        --json number --jq '.[0].number // empty')" || return 1
    if [ -z "${open}" ]; then
        _ci_mutate gh pr create --repo "${GITHUB_REPOSITORY}" --base current_dev --head "${branch}" \
            --title "${title}" --body-file "${body}" \
            --label dependencies --label no-changelog-needed || return 1
    else
        _ci_mutate gh pr edit "${open}" --repo "${GITHUB_REPOSITORY}" --body-file "${body}" || return 1
    fi
    for wf in validate.yml security.yml; do
        _ci_mutate gh workflow run "${wf}" --repo "${GITHUB_REPOSITORY}" --ref "${branch}" || return 1
    done
}

# =========================================================
# SCHEDULED-CI STATUS REPORT
# =========================================================

# What: Print names of failed or cancelled jobs from pairs.
# Why: A skip means an upstream job failed, not this one.
# From: Issue #479, PR #476
_ci_failed_jobs() {
    local pairs="$1" jname jresult out=""
    while IFS='=' read -r jname jresult; do
        [ -z "${jname}" ] && continue
        case "${jresult}" in
            failure|cancelled) out="${out} ${jname}" ;;
        esac
    done <<< "${pairs}"
    printf '%s\n' "${out# }"
}

# =========================================================
# REQUIRED-CHECK GATE (one stable name over a skippable matrix)
# =========================================================

# What: Fail if JOBS has any real failure/cancelled entry.
# Why: Skipped jobs have no name a ruleset can require.
# From: Issue #479, PR #544
ci_cmd_gate() {
    : "${JOBS:?JOBS required}"
    local failed
    failed="$(_ci_failed_jobs "${JOBS}")"
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
        echo "::warning::PROJECT_AUTOMATION_PAT not configured; ${url} was not added to the board."
        return 0
    fi
    GH_TOKEN="${token}" _ci_mutate gh project item-add "${PROJECT_NUMBER}" \
        --owner "${PROJECT_OWNER}" --url "${url}"
}

# What: Give issue $1 the Bug type unless it has a type.
# Why: Retrying on each failure heals a missed one-shot.
# From: Issue #479, PR #476
_ci_report_ensure_bug_type() {
    : "${REPO:?REPO required}"
    local issue_number="$1" owner name issue_query_result issue_node_id current_type bug_type_id
    owner="${REPO%%/*}"
    name="${REPO##*/}"
    issue_query_result="$(gh api graphql -f query="
      query(\$owner: String!, \$name: String!, \$number: Int!) {
        repository(owner: \$owner, name: \$name) {
          issue(number: \$number) { id issueType { name } }
        }
      }" -F owner="${owner}" -F name="${name}" -F number="${issue_number}" \
      --jq '.data.repository.issue | .id + " " + (.issueType.name // "-")')"
    read -r issue_node_id current_type <<<"${issue_query_result}"
    [ "${current_type}" != "-" ] && return 0
    bug_type_id="$(gh api graphql -f query="
      query(\$owner: String!, \$name: String!) {
        repository(owner: \$owner, name: \$name) {
          issueTypes(first: 20) { nodes { id name } }
        }
      }" -F owner="${owner}" -F name="${name}" \
      --jq '.data.repository.issueTypes.nodes[] | select(.name == "Bug") | .id')"
    if [ -z "${bug_type_id}" ]; then
        ci_log "[CI-ERROR-REPORT-0001]" "no 'Bug' issue type configured for ${REPO}"
        return 1
    fi
    _ci_mutate gh api graphql -f query="
      mutation(\$issueId: ID!, \$typeId: ID!) {
        updateIssue(input: {id: \$issueId, issueTypeId: \$typeId}) { issue { id } }
      }" -F issueId="${issue_node_id}" -F typeId="${bug_type_id}"
}

# What: File, update or close the standing tracking issue.
# Why: All schedules share it; any success closes it.
# From: Issue #479, Issue #81, PR #89, PR #476
ci_cmd_report() {
    : "${GH_TOKEN:?GH_TOKEN required}"
    : "${REPO:?REPO required, e.g. wiki-mod/distcc-ng}"
    : "${OUTCOME:?OUTCOME required (success|failure)}"
    : "${SCOPE:?SCOPE required, e.g. 'weekly ccache heartbeat (master)'}"
    : "${RUN_URL:?RUN_URL required}"
    local LABEL="${LABEL:-nightly-broken}" existing detail new_issue_url
    local FAILED_JOBS="${FAILED_JOBS:-}"
    # What: Derive FAILED_JOBS from JOBS name=result lines.
    # Why: Only failure/cancelled are real; skips are upstream.
    # From: Issue #479, PR #476
    local JOBS="${JOBS:-}"
    [ -n "${JOBS}" ] && FAILED_JOBS="$(_ci_failed_jobs "${JOBS}")"
    existing="$(gh issue list --repo "${REPO}" --label "${LABEL}" --state open \
        --json number --jq 'sort_by(.number) | .[0].number // empty')"
    if [ "${OUTCOME}" = "success" ]; then
        if [ -n "${existing}" ]; then
            _ci_report_ensure_bug_type "${existing}" || return 1
            _ci_board_add "https://github.com/${REPO}/issues/${existing}" "${PROJECT_PAT:-}" || return 1
            echo "success: closing standing ${LABEL} issue #${existing}"
            _ci_mutate gh issue comment "${existing}" --repo "${REPO}" \
                --body "Recovered: ${SCOPE} succeeded in ${RUN_URL}. Closing this standing tracking issue automatically; it will re-open if a later scheduled run fails."
            _ci_mutate gh issue close "${existing}" --repo "${REPO}"
        else
            echo "success and no open ${LABEL} issue: nothing to do"
        fi
        return 0
    fi
    _ci_mutate gh label create "${LABEL}" --repo "${REPO}" --color b60205 --force \
        --description "A scheduled nightly/heartbeat CI run is failing" || return 1
    detail="${SCOPE} failed in ${RUN_URL}"
    [ -n "${FAILED_JOBS}" ] && detail="${detail} (failed: ${FAILED_JOBS})"
    if [ -n "${existing}" ]; then
        echo "failure: commenting on standing ${LABEL} issue #${existing}"
        _ci_mutate gh issue comment "${existing}" --repo "${REPO}" \
            --body "Still failing: ${detail}."
        _ci_report_ensure_bug_type "${existing}" || return 1
        _ci_board_add "https://github.com/${REPO}/issues/${existing}" "${PROJECT_PAT:-}" || return 1
    else
        echo "failure: opening a new standing ${LABEL} issue"
        new_issue_url="$(_ci_mutate gh issue create --repo "${REPO}" --label "${LABEL}" \
            --title "[${LABEL}] a scheduled CI run is failing" \
            --body "A scheduled CI run failed. This standing issue is reused across consecutive failures and closed automatically on the next successful run.

${detail}.")"
        # What: A dry run has no new issue url to act on.
        # Why: Bug type and board both need the created issue.
        # From: Issue #479, PR #544
        if [ "${DRY_RUN:-false}" = "true" ]; then
            printf '%s\n' "${new_issue_url}"
            return 0
        fi
        _ci_report_ensure_bug_type "${new_issue_url##*/}" || return 1
        _ci_board_add "${new_issue_url}" "${PROJECT_PAT:-}" || return 1
    fi
}

# =========================================================
# VARIABLES (workflow output helpers)
# =========================================================

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

# What: Write available=true|false from SECRET_VALUE.
# Why: GitHub forbids the secrets context inside an if:.
# From: Issue #479, PR #329
_ci_variables_secret_present() {
    if [ -n "${SECRET_VALUE:-}" ]; then
        _ci_output available true
    else
        _ci_output available false
    fi
}

# What: Add an issue/PR to the org project board via gh CLI.
# Why: gh project item-add is native; no marketplace action.
# From: Issue #479
_ci_variables_add_to_project() {
    : "${ITEM_URL:?ITEM_URL required}"
    _ci_board_add "${ITEM_URL}" "${GH_TOKEN:-}"
}

# What: True if a file is under doc/ or a non-CHANGELOG .md.
# Why: labeler.yml's any:/negation rule needs own logic.
# From: Issue #479
_ci_labeler_documentation_match() {
    local files="$1" f
    while IFS= read -r f; do
        case "${f}" in doc/*) return 0 ;; esac
        case "${f}" in *.md) [ "${f}" != "CHANGELOG.md" ] && return 0 ;; esac
    done <<< "${files}"
    return 1
}

# What: True if pat matches any line of files (one per line).
# Why: Shared by every simple rule; a herestring, no subshell.
# From: Issue #479
_ci_labeler_glob_matches_any() {
    local pat="$1" files="$2" f
    while IFS= read -r f; do
        _ci_glob_match "${pat}" "${f}" && return 0
    done <<< "${files}"
    return 1
}

# What: Print "label glob" for labeler.yml's simple rules.
# Why: Only the documentation label needs any:/negation.
# From: Issue #479
_ci_labeler_simple_rules() {
    awk '
        /^documentation:$/ { label = ""; collecting = 0; next }
        /^[a-z_-]+:$/ { label = $0; sub(/:$/, "", label); collecting = 0; next }
        label == "" { next }
        /any-glob-to-any-file:/ {
            rest = $0
            sub(/.*any-glob-to-any-file:[[:space:]]*/, "", rest)
            gsub(/"/, "", rest)
            if (rest != "") { print label, rest; collecting = 0 } else { collecting = 1 }
            next
        }
        collecting && /^[[:space:]]*-[[:space:]]*"/ {
            val = $0; gsub(/^[[:space:]]*-[[:space:]]*"|"[[:space:]]*$/, "", val)
            print label, val
            next
        }
        { collecting = 0 }
    ' "${CI_REPO_ROOT}/.github/labeler.yml"
}

# What: Map a Commit type prefix to a category label.
# Why: rule 71 already structures titles; no regex needed.
# From: Issue #479
_ci_pr_category_label() {
    local title="$1" type=""
    [[ "${title}" =~ ^([a-zA-Z]+) ]] && type="${BASH_REMATCH[1]}"
    case "${type}" in
        security) printf 'security' ;;
        fix)      printf 'bug' ;;
        feat)     printf 'enhancement' ;;
        docs)     printf 'documentation' ;;
    esac
}

# What: Apply path- and title-based labels to a PR.
# Why: Replaces both actions/labeler and release-drafter.
# From: Issue #479
_ci_variables_label_pr() {
    : "${PR_NUMBER:?PR_NUMBER required}"
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    local files label pat labels=() category
    files="$(gh pr diff "${PR_NUMBER}" --repo "${GITHUB_REPOSITORY}" --name-only)"
    if _ci_labeler_documentation_match "${files}"; then
        labels+=("documentation")
    fi
    while read -r label pat; do
        [ -n "${label}" ] || continue
        _ci_labeler_glob_matches_any "${pat}" "${files}" && labels+=("${label}")
    done < <(_ci_labeler_simple_rules)
    if _ci_metadata_fetch_live; then
        category="$(_ci_pr_category_label "${PR_TITLE:-}")"
        [ -n "${category}" ] && labels+=("${category}")
    fi
    if [ "${#labels[@]}" -gt 0 ]; then
        gh pr edit "${PR_NUMBER}" --repo "${GITHUB_REPOSITORY}" \
            --add-label "$(IFS=,; printf '%s' "${labels[*]}")"
    fi
}

# What: Workflow variable/output helpers dispatch.
# Why: One owner for gate logic YAML cannot express.
# From: Issue #479
ci_cmd_variables() {
    local sub="${1:?variables subcommand required}"
    case "${sub}" in
        secret-present)  _ci_variables_secret_present ;;
        add-to-project)  _ci_variables_add_to_project ;;
        label-pr)        _ci_variables_label_pr ;;
        *) ci_log "[CI-ERROR-VARIABLES-0001]" "unknown variables subcommand=\"${sub}\""; return 2 ;;
    esac
}

# =========================================================
# SECURITY SCAN (OpenSSF Baseline recheck)
# =========================================================

# What: Print Met if a pattern is in a file (-i), else NotMet.
# Why: One owner for the many grep-based baseline checks.
# From: Issue #479, Issue #312
_ci_ossf_grep() {
    local file="$1" pattern="$2" ci="${3:-}"
    if [ -n "${ci}" ]; then
        grep -qi -- "${pattern}" "${file}" && { echo "Met"; return; }
    else
        grep -q -- "${pattern}" "${file}" && { echo "Met"; return; }
    fi
    echo "NotMet"
}

# What: URL-encode one argument via jq @uri.
# Why: Justification text must survive in a query string.
# From: Issue #312
_ci_ossf_urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

# What: Append one status=Met&justification query pair.
# Why: Only currently-Met criteria enter the proposal URL.
# From: Issue #312
_ci_ossf_add_met() {
    local -n _qs="$1"
    local osps_id="$2" justification="$3" param_key enc_just
    param_key="$(echo "${osps_id}" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"
    enc_just="$(_ci_ossf_urlencode "${justification}")"
    [ -n "${_qs}" ] && _qs="${_qs}&"
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
    local types
    types="$(gh api "repos/${REPO}/rulesets/18300729" --jq '[.rules[].type]')" || { echo "NotMet"; return; }
    if echo "${types}" | jq -e 'contains(["pull_request"]) and contains(["deletion"])' >/dev/null; then
        echo "Met"; else echo "NotMet"; fi
}

# What: No pull_request_target fork code, no raw event text.
# Why: Only a ci.sh checkout given a ref can fetch PR code.
# From: Issue #312, PR #544
_ci_ossf_check_br01() {
    local hits=0 f
    for f in .github/workflows/*.yml; do
        if grep -q "pull_request_target" "${f}" \
            && grep -qE 'bash -s -- checkout [0-9]+ [^[:space:]]' "${f}"; then
            hits=1
        fi
    done
    if grep -v '^[[:space:]]*#' .github/workflows/*.yml \
        | grep -qE 'github\.event\.(pull_request|issue|comment)\.(title|body)'; then
        hits=1
    fi
    [ "${hits}" -eq 0 ] && echo "Met" || echo "NotMet"
}

# What: Secret scanning and push protection are enabled.
# Why: Needs an admin token; github.token hides the field.
# From: Issue #312
_ci_ossf_check_br07() {
    local analysis
    analysis="$(gh api "repos/${REPO}" --jq '.security_and_analysis')"
    if echo "${analysis}" | jq -e '.secret_scanning.status == "enabled" and .secret_scanning_push_protection.status == "enabled"' >/dev/null; then
        echo "Met"; else echo "NotMet"; fi
}

# What: No compiled binary is tracked in the git tree.
# Why: Build outputs must be produced, never committed.
# From: Issue #312
_ci_ossf_check_qa05() {
    if git ls-tree -r HEAD --name-only | grep -Ei '\.(o|so|a|exe|dll|bin)$' >/dev/null; then
        echo "NotMet"; else echo "Met"; fi
}

# What: Each workflow has a narrow top-level permissions key.
# Why: A missing or write-all default is not least-privilege.
# From: Issue #312
_ci_ossf_check_ac04() {
    local f block
    for f in .github/workflows/*.yml; do
        block="$(awk '/^permissions:/{flag=1} /^jobs:/{flag=0} flag' "${f}")"
        [ -z "${block}" ] && { echo "NotMet"; return; }
        if echo "${block}" | grep -qE 'permissions:[[:space:]]*write-all|^[[:space:]]*contents:[[:space:]]*write'; then
            echo "NotMet"; return
        fi
    done
    echo "Met"
}

# What: Some workflow attests the release assets via ci.sh.
# Why: Scanning all workflows survives a workflow rename.
# From: Issue #312, Issue #479, PR #544
_ci_ossf_check_br06() {
    if grep -rq "ci.sh attest release" .github/workflows/; then
        echo "Met"; else echo "NotMet"; fi
}

# What: The SOT pin refresh is scheduled; its policy is doc'd.
# Why: Both must hold for OSPS-BR-05.01/DO-06.01.
# From: Issue #312, PR #544
_ci_ossf_check_br05_do06() {
    if grep -q 'ci.sh sot-update' .github/workflows/housekeeping.yml \
        && grep -q "## Dependency management policy" doc/compatibility-policy.md; then
        echo "Met"; else echo "NotMet"; fi
}

# What: Run every baseline check; post the tracking comment.
# Why: One recheck owner; workflows only call the phase.
# From: Issue #479, Issue #312
_ci_scan_openssf() {
    : "${REPO:?REPO required, e.g. wiki-mod/distcc-ng}"
    : "${ISSUE_NUMBER:?ISSUE_NUMBER required (the tracking issue)}"
    local PROJECT_ID="${PROJECT_ID:-13760}"
    local MARKER="<!-- openssf-baseline-recheck -->" RUN_URL="${RUN_URL:-}"
    local TODAY; TODAY="$(date -u +%Y-%m-%d)"
    local ac03 br01 br07 qa05 vm02 ac04 br06 br05_do06 gv01 vm01_vm03 do04_do05
    ac03="$(_ci_ossf_check_ac03)"
    br01="$(_ci_ossf_check_br01)"
    br07="$(_ci_ossf_check_br07)"
    qa05="$(_ci_ossf_check_qa05)"
    vm02="$([ -f SECURITY.md ] && echo Met || echo NotMet)"
    ac04="$(_ci_ossf_check_ac04)"
    br06="$(_ci_ossf_check_br06)"
    br05_do06="$(_ci_ossf_check_br05_do06)"
    gv01="$(_ci_ossf_grep AGENTS.md 'grant maintainer-level approval')"
    vm01_vm03="$(_ci_ossf_grep SECURITY.md 'Security Advisor' -i)"
    do04_do05="$(_ci_ossf_grep SECURITY.md '## Supported Versions')"
    local new_state
    new_state="$(jq -nc \
        --arg ac03 "${ac03}" --arg br01 "${br01}" --arg br07 "${br07}" \
        --arg qa05 "${qa05}" --arg vm02 "${vm02}" --arg ac04 "${ac04}" \
        --arg br06 "${br06}" --arg br05_do06 "${br05_do06}" --arg gv01 "${gv01}" \
        --arg vm01_vm03 "${vm01_vm03}" --arg do04_do05 "${do04_do05}" \
        '{"AC-03":$ac03,"BR-01":$br01,"BR-07":$br07,"QA-05":$qa05,"VM-02":$vm02,
          "AC-04":$ac04,"BR-06":$br06,"BR-05_DO-06":$br05_do06,"GV-01":$gv01,
          "VM-01_VM-03":$vm01_vm03,"DO-04_DO-05":$do04_do05}')"
    local existing_id prev_state regressed_keys
    existing_id="$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}/comments" --paginate \
        --jq "[.[] | select(.body | startswith(\"${MARKER}\"))] | sort_by(.id) | last | .id // empty")"
    if [ -z "${existing_id}" ]; then
        prev_state="{}"
    else
        local prev_body state_line
        prev_body="$(gh api "repos/${REPO}/issues/comments/${existing_id}" --jq '.body')"
        state_line="$(echo "${prev_body}" | grep -o '<!-- openssf-baseline-recheck-state: .*-->')" || [ "$?" -eq 1 ] || return 2
        if [ -z "${state_line}" ]; then
            prev_state="{}"
        else
            prev_state="$(echo "${state_line}" | sed -e 's/^<!-- openssf-baseline-recheck-state: //' -e 's/ -->$//')"
        fi
    fi
    regressed_keys="$(jq -rn --argjson prev "${prev_state}" --argjson new "${new_state}" '
        $new | to_entries[] | select(.value == "NotMet" and ($prev[.key] // "") == "Met") | .key')"
    local qs1="" qs2="" qs3="" l1 l2 l3 url1 url2 url3 regressed_block=""
    [ "${ac03}" = "Met" ] && _ci_ossf_add_met qs1 "OSPS-AC-03.01" "Ruleset 18300729 on ${REPO} has a pull_request and a deletion rule, re-verified ${TODAY}."
    [ "${ac03}" = "Met" ] && _ci_ossf_add_met qs1 "OSPS-AC-03.02" "Same ruleset re-verified ${TODAY}; deletion rule present."
    [ "${br01}" = "Met" ] && _ci_ossf_add_met qs1 "OSPS-BR-01.01" "No workflow runs fork code under pull_request_target, re-verified ${TODAY}."
    [ "${br01}" = "Met" ] && _ci_ossf_add_met qs1 "OSPS-BR-01.03" "No workflow interpolates untrusted event title/body, re-verified ${TODAY}."
    [ "${br07}" = "Met" ] && _ci_ossf_add_met qs1 "OSPS-BR-07.01" "Secret scanning and push protection are enabled on ${REPO}, re-verified ${TODAY}."
    [ "${qa05}" = "Met" ] && _ci_ossf_add_met qs1 "OSPS-QA-05.01" "No compiled binary is tracked in the git tree, re-verified ${TODAY}."
    [ "${qa05}" = "Met" ] && _ci_ossf_add_met qs1 "OSPS-QA-05.02" "Same check, re-verified ${TODAY}."
    [ "${vm02}" = "Met" ] && _ci_ossf_add_met qs1 "OSPS-VM-02.01" "SECURITY.md still exists at the repo root, re-verified ${TODAY}."
    l1="- AC-03.01/03.02 (ruleset PR+deletion rules): ${ac03}
- BR-01.01/01.03 (no fork-code pull_request_target / no unsanitized event interpolation): ${br01}
- BR-07.01 (secret scanning + push protection): ${br07}
- QA-05.01/05.02 (no tracked binary artifacts): ${qa05}
- VM-02.01 (SECURITY.md present): ${vm02}"
    [ "${ac04}" = "Met" ] && _ci_ossf_add_met qs2 "OSPS-AC-04.01" "Every workflow top-level permissions block is contents:read or narrower, re-verified ${TODAY}."
    [ "${br06}" = "Met" ] && _ci_ossf_add_met qs2 "OSPS-BR-06.01" "A build-provenance attestation step is present, re-verified ${TODAY}."
    [ "${br05_do06}" = "Met" ] && _ci_ossf_add_met qs2 "OSPS-BR-05.01" "housekeeping.yml schedules the ci.sh SOT pin refresh, re-verified ${TODAY}."
    [ "${br05_do06}" = "Met" ] && _ci_ossf_add_met qs2 "OSPS-DO-06.01" "doc/compatibility-policy.md documents the dependency policy, re-verified ${TODAY}."
    [ "${gv01}" = "Met" ] && _ci_ossf_add_met qs2 "OSPS-GV-01.01" "AGENTS.md documents maintainer approval authority, re-verified ${TODAY}."
    [ "${gv01}" = "Met" ] && _ci_ossf_add_met qs2 "OSPS-GV-01.02" "Same rule, re-verified ${TODAY}."
    [ "${vm01_vm03}" = "Met" ] && _ci_ossf_add_met qs2 "OSPS-VM-01.01" "SECURITY.md documents GitHub Security Advisories as the channel, re-verified ${TODAY}."
    [ "${vm01_vm03}" = "Met" ] && _ci_ossf_add_met qs2 "OSPS-VM-03.01" "Same document, re-verified ${TODAY}."
    l2="- AC-04.01 (workflow permissions spot-check): ${ac04}
- BR-06.01 (build provenance attestation present): ${br06}
- BR-05.01/DO-06.01 (scheduled SOT pin refresh + dependency policy doc): ${br05_do06}
- GV-01.01/01.02 (AGENTS.md maintainer authority): ${gv01}
- VM-01.01/03.01 (SECURITY.md documents GH Security Advisories): ${vm01_vm03}"
    [ "${ac04}" = "Met" ] && _ci_ossf_add_met qs3 "OSPS-AC-04.02" "Same workflow-permissions spot-check as AC-04.01, re-verified ${TODAY}."
    [ "${br01}" = "Met" ] && _ci_ossf_add_met qs3 "OSPS-BR-01.04" "Same untrusted-input grep as BR-01.01, re-verified ${TODAY}."
    [ "${do04_do05}" = "Met" ] && _ci_ossf_add_met qs3 "OSPS-DO-04.01" "SECURITY.md documents a Supported Versions table, re-verified ${TODAY}."
    [ "${do04_do05}" = "Met" ] && _ci_ossf_add_met qs3 "OSPS-DO-05.01" "Same table, re-verified ${TODAY}."
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
)"
    local body_file
    body_file="$(mktemp)" || return 1
    printf '%s\n' "${body}" | tee "${body_file}"
    if [ -n "${existing_id}" ]; then
        _ci_mutate gh api --method PATCH "repos/${REPO}/issues/comments/${existing_id}" \
            -F "body=@${body_file}" || return 1
    else
        _ci_mutate gh api --method POST "repos/${REPO}/issues/${ISSUE_NUMBER}/comments" \
            -F "body=@${body_file}" || return 1
    fi
}

# What: Expand {version} and {bare} in a SOT tool url.
# Why: One url owner for fetch and the sot-update digest.
# From: Issue #479, PR #544
_ci_tool_url() {
    local spec="$1" ver="$2" url
    url="$(_ci_sot_scalar "${spec}.url")" || return 2
    url="${url//\{version\}/${ver}}"
    printf '%s\n' "${url//\{bare\}/${ver#v}}"
}

# What: Download one URL to a file in up to three attempts.
# Why: curl --retry never retries a dropped connection.
# From: Issue #479, PR #544
_ci_download() {
    local url="$1" file="$2" try
    for try in 1 2 3; do
        if curl -fsSL --retry 3 -o "${file}" "${url}"; then
            return 0
        fi
        ci_log "[CI-FETCH]" "attempt ${try}/3 failed: ${url}"
        [ "${try}" -eq 3 ] || sleep "${try}"
    done
    ci_log "[CI-ERROR-FETCH-0003]" "download failed: ${url}"
    return 1
}

# What: Fetch, sha256-check and cache one SOT tool; print dir.
# Why: One tool fetcher; a missing sha256 pin fails closed.
# From: Issue #479, PR #544
_ci_fetch_tool() {
    local spec="$1" ver sha url kind dest file
    ver="$(_ci_sot_scalar "${spec}.version")" || return 2
    sha="$(_ci_sot_scalar "${spec}.sha256")" || return 2
    url="$(_ci_tool_url "${spec}" "${ver}")" || return 2
    kind="$(_ci_sot_optional "${spec}.archive")" || return 2
    dest="${RUNNER_TEMP:-/tmp}/${spec##*.}-${ver}"
    if [ ! -f "${dest}/.complete" ]; then
        rm -rf "${dest}"
        mkdir -p "${dest}" || return 2
        file="${dest}.download"
        _ci_download "${url}" "${file}" || return 2
        if ! printf '%s  %s\n' "${sha}" "${file}" | sha256sum -c --quiet -; then
            ci_log "[CI-ERROR-FETCH-0001]" "sha256 mismatch for ${spec} ${ver}"
            rm -f "${file}"
            return 2
        fi
        case "${kind:-tar.gz}" in
            tar.gz) tar -xzf "${file}" -C "${dest}" || return 2; rm -f "${file}" ;;
            binary) mv "${file}" "${dest}/$(_ci_sot_scalar "${spec}.bin")" || return 2 ;;
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

# What: Scan a local image ref for HIGH/CRITICAL vulns.
# Why: Folds trivy-action; scans before any registry push.
# From: Issue #479
ci_cmd_trivy_scan() {
    local image_ref="${1:?image ref required}" bin
    bin="$(_ci_tool_bin external_versions.trivy)" || return 2
    "${bin}" image --scanners vuln,secret --severity HIGH,CRITICAL \
        --ignore-unfixed --ignorefile "${CI_REPO_ROOT}/.trivyignore.yaml" \
        --exit-code 1 --timeout 10m "${image_ref}"
}

# What: Generate an SPDX-JSON SBOM for an image/path.
# Why: Folds anchore/sbom-action; OSPS-QA-02.02 baseline.
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

# =========================================================
# VERIFY IMAGE (buildtools/verify container)
# =========================================================

# What: Run one verify check in the local buildtools image.
# Why: Each check is a workload; ptrace ones get the profile.
# From: Issue #285, Issue #286, PR #528, PR #544
ci_cmd_verify() {
    local sub="${1:?verify subcommand required}" image
    local ptrace=(--cap-add=SYS_PTRACE
        --security-opt "seccomp=${CI_REPO_ROOT}/docker/verify/seccomp-verify.json")
    image="$(_ci_sot_scalar release.images.distcc-ng-buildtools.tag)" || return 2
    case "${sub}" in
        ptrace-selftest)
            _ci_container_run "${image}" "${ptrace[@]}" -- \
                bash "${CI_CONTAINER_SH}" workload ptrace ;;
        build-test)
            _ci_container_run "${image}" "${ptrace[@]}" -- \
                bash "${CI_CONTAINER_SH}" workload checkout check /tmp/checkout ;;
        ccache-redis)
            _ci_stack_run "$(_ci_run_name ccache-redis)" _ci_verify_ccache_redis "${image}" ;;
        samba-configure-dryrun)
            _ci_container_run "${image}" -- \
                bash "${CI_CONTAINER_SH}" workload samba configure /tmp/samba ;;
        *) ci_log "[CI-ERROR-VERIFY-0001]" "unknown verify subcommand=\"${sub}\""; return 2 ;;
    esac
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

# =========================================================
# METADATA CHECKS (PR context)
# =========================================================

# What: True if PR_AUTHOR is a SOT dependency-bump bot.
# Why: Bots cannot set milestones; AG-VAL-007 reviews them.
# From: Issue #479, PR #544
_ci_is_dependency_bot() {
    local bots
    bots="$(_ci_sot_list ci_engine.dependency_bots)" || return 2
    grep -qxF -- "${PR_AUTHOR:-}" <<< "${bots}"
}

# What: Validate a PR title against the rule-71 taxonomy.
# Why: A dependency bot titles its own PRs; it is exempt.
# From: Issue #479, rule 71
_ci_check_pr_title() {
    local title="${PR_TITLE:-}"
    if _ci_is_dependency_bot; then
        ci_log "[CI-META-TITLE]" "skipped: dependency bot ${PR_AUTHOR} sets its own title"
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
# Why: AG-GH-002 requires hard-fail, not best-effort.
# From: Issue #479, PR #544
_ci_check_pr_board() {
    if [ -z "${PROJECT_PAT:-}" ]; then
        ci_log "[CI-META-BOARD]" "skipped: PROJECT_AUTOMATION_PAT not configured"
        return 0
    fi
    _ci_project_board_load || return 2
    if [ "${PR_IS_FORK:-false}" = "true" ]; then
        ci_log "[CI-META-BOARD]" "skipped: fork PR, PAT withheld by GitHub"
        return 0
    fi
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
# Why: Board fails once the PAT is configured.
# From: Issue #479, PR #544
_ci_check_pr_tracking() {
    if _ci_is_dependency_bot; then
        ci_log "[CI-META-TRACKING]" "skipped: dependency bot ${PR_AUTHOR}"
        return 0
    fi
    local errs=()
    local pr_labels="${PR_LABELS:-}"
    [ -n "${pr_labels//[[:space:]]/}" ] || errs+=("no labels set")
    [ -n "${PR_MILESTONE_TITLE:-}" ] || errs+=("no milestone set")
    _ci_check_pr_board || errs+=("not on project board")
    if [ "${#errs[@]}" -eq 0 ]; then
        ci_log "[CI-META-TRACKING]" "OK: labels + milestone + board set"
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
    if _ci_is_dependency_bot; then
        ci_log "[CI-META-CHANGELOG]" "skipped: dependency bot ${PR_AUTHOR}"
        return 0
    fi
    case " ${PR_LABELS:-} " in
        *" no-changelog-needed "*)
            ci_log "[CI-META-CHANGELOG]" "skipped: no-changelog-needed label"
            return 0 ;;
    esac
    local changed
    cd "${CI_REPO_ROOT}" || return 1
    if ! changed="$(git diff --name-only "${BASE:?BASE required}" "${HEAD:-HEAD}")"; then
        ci_log "[CI-ERROR-META-CHANGELOG-0002]" "cannot diff ${BASE}..${HEAD:-HEAD}"
        return 1
    fi
    if grep -qx 'CHANGELOG.md' <<< "${changed}"; then
        ci_log "[CI-META-CHANGELOG]" "OK: CHANGELOG.md touched"
        return 0
    fi
    ci_log "[CI-ERROR-META-CHANGELOG-0001]" "no CHANGELOG.md change and no no-changelog-needed label"
    return 1
}

# What: Fetch one PR's live title/labels/tracking fields.
# Why: An event snapshot can go stale (rule 3/71).
# From: Issue #479
_ci_metadata_fetch_live() {
    : "${PR_NUMBER:?PR_NUMBER required}"
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    local json
    json="$(gh pr view "${PR_NUMBER}" --repo "${GITHUB_REPOSITORY}" \
        --json title,labels,milestone,isDraft,author,isCrossRepository)" || return 2
    PR_TITLE="$(printf '%s' "${json}" | jq -r '.title')"
    PR_LABELS="$(printf '%s' "${json}" | jq -r '[.labels[].name] | join(" ")')"
    PR_MILESTONE_TITLE="$(printf '%s' "${json}" | jq -r '.milestone.title // ""')"
    PR_DRAFT="$(printf '%s' "${json}" | jq -r '.isDraft')"
    PR_AUTHOR="$(printf '%s' "${json}" | jq -r '.author.login')"
    PR_IS_FORK="$(printf '%s' "${json}" | jq -r '.isCrossRepository')"
}

# What: Runs metadata check(s); fetches live PR data first.
# Why: Replaces changelog-check.yml's PR-context jobs.
# From: Issue #479
ci_cmd_metadata() {
    local sub="${1:-all}" rc=0
    if [ -n "${PR_NUMBER:-}" ]; then
        _ci_metadata_fetch_live || return 2
    fi
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
    local root="${1:-${CI_REPO_ROOT}/.github}" rc=0 f hits
    hits="$(grep -rlU "$(printf '\r')" "${root}")" || [ "$?" -eq 1 ] || return 2
    while IFS= read -r f; do
        [ -n "${f}" ] || continue
        rc=1
        ci_log "[CI-ERROR-GUARD-EOL-0001]" "CR/CRLF found: ${f}"
    done <<< "${hits}"
    return "${rc}"
}

# What: Fail on any sha256 digest not 64 lowercase hex.
# Why: Full-length SHAs only; no abbreviated forms.
# From: Issue #479
ci_guard_full_sha() {
    local root="${1:-${CI_REPO_ROOT}/.github}" rc=0 hit hits
    hits="$(grep -rhoE 'sha256:[0-9a-fA-F]+' "${root}")" || [ "$?" -eq 1 ] || return 2
    while IFS= read -r hit; do
        [ -n "${hit}" ] || continue
        rc=1
        ci_log "[CI-ERROR-GUARD-SHA-0001]" "not a full 64-hex sha256: ${hit}"
    done < <(awk -F: 'length($2) != 64 || $2 ~ /[A-F]/ { print }' <<< "${hits}")
    return "${rc}"
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
    local root="${1:-${CI_REPO_ROOT}}" rc=0 f out line text kind ref pins pin
    local files=() wfs=()
    for f in "${root}"/.github/workflows/*.yml; do
        [ -f "${f}" ] || continue
        wfs+=("${f}")
        out="$(grep -nE '@([0-9a-f]{40}|sha256:)|^ {4,}(image|container):' "${f}")" \
            || [ "$?" -eq 1 ] || return 2
        while IFS=: read -r line text; do
            [ -n "${line}" ] || continue
            # What: uses: lines belong to the orchestrator guard.
            # Why: It matches each one against the SOT action pins.
            # From: Issue #479, PR #544
            [[ "${text}" =~ ^[[:space:]]*(-[[:space:]]+)?uses: ]] && continue
            rc=1
            ci_log "[CI-ERROR-GUARD-PIN-0001]" "${f}:${line}: image or action pin outside the SOT"
        done <<< "${out}"
    done
    pins="$(_ci_action_pins)" || return 2
    while IFS= read -r pin; do
        [ -n "${pin}" ] || continue
        if [ "${#wfs[@]}" -eq 0 ] || ! grep -qF -- "uses: ${pin}" "${wfs[@]}"; then
            rc=1
            ci_log "[CI-ERROR-GUARD-PIN-0003]" "SOT action ${pin} is used by no workflow"
        fi
    done <<< "${pins}"
    mapfile -t files < <(find "${root}" -name Dockerfile -type f -not -path '*/.git/*')
    for f in "${files[@]}"; do
        out="$(_ci_dockerfile_pins "${f}")" || return 2
        while read -r line kind ref; do
            [ -n "${line}" ] || continue
            rc=1
            ci_log "[CI-ERROR-GUARD-PIN-0002]" "${f}:${line}: ${kind} ${ref} bypasses the SOT ARG"
        done <<< "${out}"
    done
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
    local rc=0 f hit pins out
    pins="$(_ci_action_pins)" || return 2
    for f in "$@"; do
        [ -f "${f}" ] || continue
        out="$(_ci_scan_run_blocks "${f}" "${pins}")" || return 2
        while IFS= read -r hit; do
            [ -n "${hit}" ] || continue
            rc=1
            ci_log "[CI-ERROR-GUARD-ORCH-0001]" "${hit}"
        done <<< "${out}"
    done
    return "${rc}"
}

# What: Run the ci.bats regression suite in parallel.
# Why: The engine tests itself when .github/scripts changes.
# From: Issue #479
ci_cmd_selftest() {
    bats --jobs "$(_ci_jobs)" "${CI_SCRIPT_DIR}/ci.bats"
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
    while IFS= read -r f; do files+=("${f}"); done \
        < <(cd "${CI_REPO_ROOT}" && find .github/workflows -name "*.yml" -type f)
    _ci_lint_run actionlint -color "${files[@]}"
}

# What: Shellcheck ci.sh, this repo's real shell engine.
# Why: test/e2e*/*.sh stay explicitly out of scope.
# From: Issue #479
_ci_lint_shellcheck() {
    _ci_lint_run shellcheck .github/scripts/ci.sh
}

# What: Run the governance guards over the CI-owned tree.
# Why: One phase enforces the repo's CI hygiene invariants.
# From: Issue #479
ci_cmd_lint() {
    local rc=0 d
    for d in .github docker test/e2e .clusterfuzzlite; do
        ci_guard_line_endings "${CI_REPO_ROOT}/${d}" || rc=1
    done
    # What: Full-SHA scan of the dirs that may carry a pin.
    # Why: Scripts hold none; ci.bats holds test fixtures.
    # From: Issue #479
    for d in .github/workflows .github/yaml docker; do
        [ -e "${CI_REPO_ROOT}/${d}" ] || continue
        ci_guard_full_sha "${CI_REPO_ROOT}/${d}" || rc=1
    done
    ci_guard_pins_in_sot "${CI_REPO_ROOT}" || rc=1
    # What: Every workflow must be a pure orchestrator.
    # Why: No legacy exemption remains after the rewrite.
    # From: Issue #479, PR #544
    ci_guard_orchestrator_only "${CI_REPO_ROOT}"/.github/workflows/*.yml || rc=1
    _ci_lint_actionlint || rc=1
    _ci_lint_shellcheck || rc=1
    return "${rc}"
}

# =========================================================
# INSTALL (apt/brew dependency installers)
# =========================================================

# What: apt-get update+install, bounded 2x3-minute retry.
# Why: ubuntu-latest's default mirror has hung indefinitely.
# From: Issue #493, Issue #479
_ci_apt_install() {
    local packages="${1:?package list required}" mode="${2:-runner}" max_attempts=2 attempt=1
    local as_root=(sudo) apt_opts="" upgrade=""
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
            # What: Image builds apply pending security updates first.
            # Why: A fixable HIGH CVE in a base package blocks a release.
            # From: Issue #479, PR #544
            upgrade="apt-get upgrade -y ${apt_opts} &&" ;;
        *) ci_log "[CI-ERROR-INSTALL-0003]" "apt mode=${mode} (runner|image)"; return 2 ;;
    esac
    while true; do
        if "${as_root[@]}" timeout -k 10s 3m env DEBIAN_FRONTEND=noninteractive \
            bash -c "apt-get update && ${upgrade} apt-get install -y ${apt_opts} ${packages}"; then
            if [ "${mode}" = "image" ]; then
                rm -rf /var/lib/apt/lists/* || return 1
            fi
            return 0
        fi
        if [ "${attempt}" -ge "${max_attempts}" ]; then
            ci_log "[CI-ERROR-INSTALL-0001]" "apt install failed after ${max_attempts} attempts"
            return 1
        fi
        ci_log "[CI-INSTALL-APT]" "attempt ${attempt} failed or timed out, retrying"
        attempt=$((attempt + 1))
        sleep 10
    done
}

# What: brew install for a space-separated package list.
# Why: brew is preinstalled; no retry needed here.
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

# =========================================================
# CHECKOUT (bootstrap; must not depend on the repo or SOT)
# =========================================================

# What: Fetch+checkout the triggering commit via plain git.
# Why: No action, no SHA; ci.sh isn't on disk pre-checkout.
# From: Issue #479
ci_cmd_checkout() {
    local depth="${1:-1}" ref="${2:-${GITHUB_SHA:-}}"
    : "${GITHUB_SERVER_URL:?GITHUB_SERVER_URL required}"
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
    : "${ref:?ref required (pass one, or set GITHUB_SHA)}"
    git init -q .
    git remote add origin "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}"
    if [ "${depth}" = "0" ]; then
        git fetch -q origin "${ref}"
    else
        git fetch -q --depth="${depth}" origin "${ref}"
    fi
    git checkout -q FETCH_HEAD
}

# =========================================================
# BUILD-PROVENANCE ATTESTATION (cosign, GitHub attestations)
# =========================================================

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
    payload="$(tr '_-' '/+' <<< "${payload}")"
    pad=$(( (4 - ${#payload} % 4) % 4 ))
    [ "${pad}" -eq 0 ] || payload="${payload}$(printf '=%.0s' $(seq 1 "${pad}"))"
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
            if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
                ci_log "[CI-ATTEST]" "build attestation NotRun: no id-token (fork PR or local run)"
                return 0
            fi
            files=(distcc distccd) ;;
        release)
            mapfile -t files < <(_ci_release_assets)
            [ "${#files[@]}" -gt 0 ] || return 1
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

# =========================================================
# HARDEN RUNNER (StepSecurity agent, audit-only egress)
# =========================================================

# What: Agent home; fixed by the agent's own systemd unit.
# Why: The unit's ExecStart/WorkingDirectory hardcode it.
# From: Issue #479, PR #544
_CI_HARDEN_DIR="/home/agent"

# What: Print why the agent cannot run on this runner, if so.
# Why: Non-TLS agent ships for GitHub-hosted Linux x64 only.
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
    local private bin
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
    cid="$(cat /proc/sys/kernel/random/uuid)"
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
        otk="$(jq -r '.one_time_key // ""' "${resp}")"
        summary="$(jq -r 'if .monitoring_started then "true" else "false" end' "${resp}")"
    fi
    private="$(jq -r '.repository.private // false' "${GITHUB_EVENT_PATH}")"
    bin="$(_ci_tool_bin external_versions.harden_runner_agent)" || return 2
    sudo mkdir -p "${_CI_HARDEN_DIR}"
    sudo chown -R "${USER}" "${_CI_HARDEN_DIR}"
    cp "${bin}" "${_CI_HARDEN_DIR}/agent"
    chmod +x "${_CI_HARDEN_DIR}/agent"
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
        > "${_CI_HARDEN_DIR}/agent.json"
    printf 'correlation_id=%s\nadd_summary=%s\n' "${cid}" "${summary}" \
        > "${RUNNER_TEMP}/ci-harden.state"
    _ci_harden_service_unit | sudo tee /etc/systemd/system/agent.service >/dev/null
    sudo systemctl daemon-reload
    timeout 15 sudo service agent start
    for _ in $(seq 1 30); do
        if [ -f "${_CI_HARDEN_DIR}/agent.status" ]; then
            ci_log "[CI-HARDEN]" "agent status: $(cat "${_CI_HARDEN_DIR}/agent.status")"
            ci_log "[CI-HARDEN]" "insights: ${web}/github/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
            return 0
        fi
        sleep 0.3
    done
    ci_log "[CI-ERROR-HARDEN-0002]" "agent wrote no agent.status within 9s"
    cat "${_CI_HARDEN_DIR}/agent.log" 2>/dev/null || ci_log "[CI-ERROR-HARDEN-0002]" "no agent.log either"
    return 1
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
    cid="$(sed -n 's/^correlation_id=//p' "${state}")"
    summary="$(sed -n 's/^add_summary=//p' "${state}")"
    printf '{"event":"post"}' > "${_CI_HARDEN_DIR}/post_event.json"
    for _ in $(seq 1 10); do
        if [ -f "${_CI_HARDEN_DIR}/done.json" ]; then
            break
        fi
        sleep 1
    done
    if [ ! -f "${_CI_HARDEN_DIR}/done.json" ]; then
        ci_log "[CI-ERROR-HARDEN-0003]" "agent did not confirm job end within 10s"
        cat "${_CI_HARDEN_DIR}/agent.log" 2>/dev/null || ci_log "[CI-ERROR-HARDEN-0003]" "no agent.log either"
        return 1
    fi
    if [ "${summary}" != "true" ]; then
        return 0
    fi
    : "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY required}"
    api="$(_ci_sot_scalar harden_runner.api_url)" || return 2
    out="${RUNNER_TEMP:-/tmp}/harden-summary.md"
    code="$(curl -sS --max-time 3 -o "${out}" -w '%{http_code}' \
        "${api}/github/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}/actions/runs/${GITHUB_RUN_ID:?GITHUB_RUN_ID required}/correlation/${cid}/job-markdown-summary")" || code="000"
    if [ "${code}" = "200" ]; then
        cat "${out}" >> "${GITHUB_STEP_SUMMARY}"
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

# =========================================================
# SECURITY TOOLS (own CLI invocations; no marketplace actions)
# =========================================================

# What: Map language+suite to a CodeQL query-pack reference.
# Why: One mapping; callers pass only a plain suite name.
# From: Issue #479
_ci_codeql_query_pack() {
    local lang="$1" suite="${2:-security-extended}"
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
    local lang="${1:?language required}" suite="${2:-security-extended}" \
        out="${3:-results-${1}.sarif}" bin db pack
    bin="$(_ci_tool_bin external_versions.codeql_cli)" || return 2
    db="${RUNNER_TEMP:-/tmp}/codeql-db-${lang}"
    pack="$(_ci_codeql_query_pack "${lang}" "${suite}")"
    rm -rf "${db}"
    case "${lang}" in
        c-cpp)
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

# What: Upload one SARIF file via the code-scanning API.
# Why: The body goes in a file; a large SARIF overflows argv.
# From: Issue #479, PR #544
ci_cmd_sarif_upload() {
    local file="${1:?sarif file required}" work
    : "${GH_TOKEN:?GH_TOKEN required}"
    work="$(mktemp -d)" || return 1
    gzip -c "${file}" | base64 -w0 > "${work}/sarif.b64" || return 1
    jq -n --arg c "${GITHUB_SHA:?GITHUB_SHA required}" --arg r "${GITHUB_REF:?GITHUB_REF required}" \
        --rawfile s "${work}/sarif.b64" '{commit_sha: $c, ref: $r, sarif: $s}' > "${work}/body.json" || return 1
    gh api --method POST "repos/${GITHUB_REPOSITORY}/code-scanning/sarifs" \
        --input "${work}/body.json" --jq '"[CI-SCAN] SARIF upload id \(.id)"' || return 1
    rm -rf "${work}"
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
# Why: No CLI sarif format; ci.sh owns the conversion.
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

# What: Scan the repo with OSV-Scanner, writing a SARIF file.
# Why: CLI-native; no osv-scanner reusable workflow.
# From: Issue #479
ci_cmd_osv_scan() {
    local out="${1:-osv-results.sarif}" bin base_sot old new added
    local dirs=()
    bin="$(_ci_tool_bin external_versions.osv_scanner)" || return 2
    mapfile -t dirs < <(_ci_osv_tool_dirs)
    [ "${#dirs[@]}" -gt 0 ] || return 2
    _ci_osv_run "${bin}" sarif "${out}" "${dirs[@]}" || return 2
    if [ -z "${BASE:-}" ]; then
        return 0
    fi
    # What: PR gate: fail on vuln ids the head's tools add.
    # Why: Same scanner and DB on both SOTs; only versions differ.
    # From: Issue #267, Issue #479, PR #544
    base_sot="$(mktemp)" || return 1
    git -C "${CI_REPO_ROOT}" fetch -q --depth=1 origin "${BASE}" || return 1
    if ! git -C "${CI_REPO_ROOT}" cat-file -e "${BASE}:.github/yaml/build-manifest.yml"; then
        ci_log "[CI-SCAN]" "OSV PR gate NotRun: base ${BASE} has no SOT yet"
        return 0
    fi
    git -C "${CI_REPO_ROOT}" show "${BASE}:.github/yaml/build-manifest.yml" > "${base_sot}" || return 1
    if ! grep -q '^    bin:' "${base_sot}"; then
        ci_log "[CI-SCAN]" "OSV PR gate NotRun: base SOT has no tool pins to compare"
        return 0
    fi
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
    local keys key dest
    keys="$(_ci_sot_children external_versions)" || return 2
    for key in ${keys}; do
        [ -n "$(_ci_sot_optional "external_versions.${key}.bin")" ] || continue
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
    local bin="$1" sot="$2" json dirs_raw
    local dirs=()
    json="$(mktemp)" || return 1
    dirs_raw="$(CI_MANIFEST="${sot}" _ci_osv_tool_dirs)" || return 2
    mapfile -t dirs <<< "${dirs_raw}"
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
    local sanitizer="${1:-address}"
    _ci_image_alias security.cfl_base || return 1
    _ci_cfl_run build -e "SANITIZER=${sanitizer}"
}

# What: Run the built fuzzers for a bounded time.
# Why: Code-change mode on PRs; SARIF feeds code scanning.
# From: Issue #267, Issue #479
ci_cmd_clusterfuzzlite_run() {
    local sanitizer="${1:-address}" fuzz_seconds="${2:-300}" mode="${3:-code-change}"
    local rc=0 crashes found
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

# =========================================================
# BUILD / TEST
# =========================================================

# What: Print every real gcc/clang warning line of a log.
# Why: Warnings are errors (rule 31); anchored to diag shape.
# From: Issue #479
_ci_compiler_warnings() {
    grep -E '^[^: ]+\.(c|h|cc|cpp):[0-9]+:([0-9]+:)? *[Ww]arning:' "$1"
}

# What: autogen and configure the tree in cwd; log to $1.
# Why: One configure owner; stdout stays free for callers.
# From: Issue #479, PR #544
_ci_configure_tree() {
    local log="$1"
    shift
    if ! { ./autogen.sh && ./configure "$@"; } 2>&1 | tee "${log}" >&2; then
        ci_log "[CI-ERROR-BUILD-0003]" "autogen/configure failed: $*"
        return 1
    fi
}

# What: make in cwd; fail on an error or a compiler warning.
# Why: One make owner, so every tree build gets the gate.
# From: Issue #479, PR #544
_ci_make_gated() {
    local log="$1" warnings
    shift
    if ! make "$@" 2>&1 | tee "${log}" >&2; then
        ci_log "[CI-ERROR-BUILD-0004]" "make $* failed"
        return 1
    fi
    if warnings="$(_ci_compiler_warnings "${log}")"; then
        ci_error "[CI-ERROR-BUILD-WARN-0001]" "make $* emitted compiler warnings (rule 31)" "${warnings}"
        return 1
    fi
}

# What: Compile vendored popt/*.c under this repo's flags.
# Why: popt-vendor proves bundled popt builds Werror-clean.
# From: Issue #479, Issue #63
_ci_popt_strict_compile() {
    local out="${RUNNER_TEMP:-/tmp}/popt-strict-check" f
    mkdir -p "${out}"
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

# What: Succeed if a variant compiles through ccache.
# Why: Build and cache plan must name the same variants.
# From: Issue #54, Issue #479, PR #544
_ci_variant_ccache() {
    [ "$1" = "default" ]
}

# What: Write the compile-cache path, key and restore keys.
# Why: actions/cache only transports; ci.sh owns the policy.
# From: Issue #54, Issue #362, Issue #479, PR #166, PR #544
ci_cmd_cache() {
    local variant="${1:?variant required}" dir sum scope
    if ! _ci_variant_ccache "${variant}"; then
        ci_log "[CI-CACHE]" "variant=${variant} has no compile cache"
        return 0
    fi
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

# What: Build one configure variant from the SOT matrix.
# Why: Variants differ only in configure; warnings fail.
# From: Issue #479
ci_cmd_build() {
    local variant="${1:?variant required}" log py cc="cc"
    local flags=()
    log="${RUNNER_TEMP:-/tmp}/ci-build-${variant}.log"
    py="$(command -v python3)" || return 1
    # What: Use ccache only where the job installed it.
    # Why: CodeQL's build has none; a cache hit would hide code.
    # From: Issue #54, Issue #479, PR #544
    if _ci_variant_ccache "${variant}" && command -v ccache >/dev/null 2>&1; then
        cc="$(command -v ccache) cc"
    fi
    case "${variant}" in
        default)
            flags=(CC="${cc}" PYTHON="$(command -v python3.13 || command -v python3)") ;;
        popt-fallback) flags=(PYTHON="${py}") ;;
        popt-vendor) flags=(--without-system-popt PYTHON="${py}") ;;
        coverage) flags=(PYTHON="${py}" CFLAGS="--coverage -O0" LDFLAGS="--coverage" --with-seccomp) ;;
        sanitizer)
            flags=(PYTHON="${py}" --without-seccomp
                CFLAGS="-O2 -fsanitize=address,undefined -fno-sanitize=alignment -fno-sanitize-recover=address -fsanitize-recover=undefined -fno-omit-frame-pointer -g -Wno-stringop-truncation") ;;
        *) ci_log "[CI-ERROR-BUILD-0002]" "unknown variant=\"${variant}\""; return 2 ;;
    esac
    cd "${CI_REPO_ROOT}" || return 1
    _ci_configure_tree "${log}.configure" "${flags[@]}" || return 1
    case "${variant}" in
        popt-fallback)
            if ! grep -q "system libpopt not found (or disabled); building bundled popt" "${log}.configure"; then
                ci_log "[CI-ERROR-BUILD-POPT-0001]" "configure did not fall back to bundled popt (libpopt-dev leaking?)"
                return 1
            fi ;;
        popt-vendor)
            _ci_popt_cve_fingerprint_check || return 1
            _ci_popt_strict_compile
            return ;;
    esac
    _ci_make_gated "${log}" || return 1
    if [ "${cc}" != "cc" ]; then
        ccache --show-stats || return 1
    fi
    if [ "${variant}" = "popt-fallback" ]; then
        _ci_popt_fallback_smoke_test || return 1
    fi
}

# What: Prove the bundled-popt binary parses real options.
# Why: A poptGetNextOpt() regression compiles fine.
# From: Issue #479
_ci_popt_fallback_smoke_test() {
    local help opt
    help="$(./distccd --help 2>&1)"
    for opt in --jobs --nice --listen --daemon --log-file --allow --user --port; do
        printf '%s' "${help}" | grep -qF -- "${opt}" || {
            ci_log "[CI-ERROR-BUILD-POPT-0002]" "distccd --help missing ${opt}"
            return 1
        }
    done
}

# What: Parse comfychair make-check output into a verdict.
# Why: 0/0/0 parsed is a hard fail (rule 66), not a pass.
# From: Issue #479
_ci_parse_comfychair() {
    local log="$1" ok notrun failed
    if [ ! -r "${log}" ]; then
        ci_log "[CI-ERROR-TEST-0007]" "make check log ${log} is not readable"
        return 1
    fi
    ok="$(grep -cE '^[A-Za-z0-9_]+[[:space:]]+OK[[:space:]]*$' "${log}")" || [ "$?" -eq 1 ] || return 1
    notrun="$(grep -cE '^[A-Za-z0-9_]+[[:space:]]+NOTRUN,' "${log}")" || [ "$?" -eq 1 ] || return 1
    failed="$(grep -cE '^[A-Za-z0-9_]+[[:space:]]+FAIL[[:space:]]*$' "${log}")" || [ "$?" -eq 1 ] || return 1
    ci_log "[CI-TEST-SUMMARY]" "OK=${ok} NOTRUN=${notrun} FAILED=${failed}"
    if [ "$(( ok + notrun + failed ))" -eq 0 ]; then
        ci_log "[CI-ERROR-TEST-0001]" "parsed zero comfychair result lines"
        return 1
    fi
    if [ "${failed}" -gt 0 ]; then
        grep -E '^[A-Za-z0-9_]+[[:space:]]+FAIL[[:space:]]*$' "${log}" >&2
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
    # What: The verify-image workload runs this test without root.
    # Why: That container is unprivileged; it has no sudo.
    # From: Issue #285, Issue #479, PR #544
    if [ "${CI_TEST_UNPRIVILEGED:-false}" = "true" ]; then
        ci_log "[CI-TEST-NOTRUN]" "AutogroupNicenessPrivilegeDrop_Case: unprivileged verify container"
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

# What: Write the coverage PYTHON wrapper; print its path.
# Why: include_server/*.py joins the coverage denominator.
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

# What: Run python3-coverage on include_server's data file.
# Why: make check runs those tests from include_server/.
# From: Issue #479, PR #370, PR #544
_ci_coverage_python() {
    python3-coverage "$@" --data-file="${CI_REPO_ROOT}/include_server/.coverage" \
        --include="${CI_REPO_ROOT}/include_server/*"
}

# What: Append C+Python coverage to the job summary.
# Why: The run page shows coverage without a download.
# From: Issue #479, PR #370
_ci_coverage_step_summary() {
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
    local fence
    fence='```'
    {
        printf '## Coverage summary\n\n### C (lcov)\n%s\n' "${fence}"
        lcov --list coverage.info --rc branch_coverage=1
        printf '%s\n\n### Python (include_server)\n%s\n' "${fence}" "${fence}"
        _ci_coverage_python report
        printf '%s\n' "${fence}"
    } >> "${GITHUB_STEP_SUMMARY}"
}

# What: Run make check for a variant and verify the result.
# Why: Folds run-tests.sh parse + c-build.yml per-variant env.
# From: Issue #479
ci_cmd_test() {
    local variant="${1:-default}" log wrapper warnings st=0
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
    if warnings="$(_ci_compiler_warnings "${log}")"; then
        ci_error "[CI-ERROR-TEST-WARN-0001]" "variant=${variant} make check warning (rule 31)" "${warnings}"
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
    if [ "${variant}" = "coverage" ]; then
        _ci_coverage_lcov || return 1
        _ci_coverage_python xml -o "${CI_REPO_ROOT}/coverage-python.xml" || return 1
        _ci_coverage_step_summary || return 1
        _ci_artifact_offer coverage "" "${CI_REPO_ROOT}/coverage.info" \
            "${CI_REPO_ROOT}/coverage-python.xml" || return 1
    fi
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
            if [ "${command}" = "checkout" ]; then
                ci_cmd_checkout "$@"
                return "$?"
            fi
            ci_require_manifest || return "$?"
            case "${command}" in
                impact) ci_cmd_impact "$@" ;;
                impact-hit) ci_cmd_impact_hit "$@" ;;
                plan) ci_cmd_plan "$@" ;;
                build) ci_cmd_build "$@" ;;
                cache) ci_cmd_cache "$@" ;;
                test) ci_cmd_test "$@" ;;
                e2e) ci_cmd_e2e "$@" ;;
                selftest) ci_cmd_selftest "$@" ;;
                metadata) ci_cmd_metadata "$@" ;;
                package) ci_cmd_package "$@" ;;
                container) ci_cmd_container "$@" ;;
                publish) ci_cmd_publish "$@" ;;
                gc) ci_cmd_gc "$@" ;;
                report) ci_cmd_report "$@" ;;
                gate) ci_cmd_gate "$@" ;;
                scan) ci_cmd_scan "$@" ;;
                variables) ci_cmd_variables "$@" ;;
                verify) ci_cmd_verify "$@" ;;
                release) ci_cmd_release "$@" ;;
                lint) ci_cmd_lint "$@" ;;
                install) ci_cmd_install "$@" ;;
                harden) ci_cmd_harden "$@" ;;
                workload) ci_cmd_workload "$@" ;;
                image) ci_cmd_image "$@" ;;
                sot-update) ci_cmd_sot_update "$@" ;;
                attest) ci_cmd_attest "$@" ;;
                *) ci_log "[CI-ERROR-CORE-0001]" "command=${command} has no dispatch arm"; return 2 ;;
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
if [ "${BASH_SOURCE[0]:-${0}}" = "${0}" ]; then
    ci_main "$@"
fi
