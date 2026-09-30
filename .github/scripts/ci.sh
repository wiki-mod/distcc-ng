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

# What: Local tag for the locally-built verify/buildtools image.
# Why: One owner; a build-time tag, not a published version.
# From: Issue #479
CI_VERIFY_IMAGE_TAG="distcc-ng-verify:ci"

# What: The published buildtools image lint and e2e build on.
# Why: One owner; the e2e images take it as their toolchain.
# From: Issue #479, PR #544
CI_BUILDTOOLS_IMAGE="ghcr.io/wiki-mod/distcc-ng-buildtools:latest"

# What: The known ci.sh subcommands.
# Why: One list drives dispatch and error text (no twin).
# From: Issue #479
CI_COMMANDS="checkout plan impact impact-hit identity resolve build test e2e analyze scan lint selftest metadata package container publish release gc report gate verify variables install harden workload image"

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

# What: Print the items of an inline list `key: [a, b]` at a path.
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
        | grep -v '^[[:space:]]*$' || true
}

# =========================================================
# PATH CLASSIFICATION (impact)
# =========================================================

# What: Match one SOT path glob to a path.
# Why: The SOT owns patterns; this owns the matching semantics.
# From: Issue #479
_ci_glob_match() {
    local pat="$1" path="$2" re
    # What: Escape regex metachars, then turn '*' runs into '.*'.
    # Why: =~ needs a real regex; case/[[ == both warn on this use.
    # From: Issue #479
    re="${pat//\*/$'\x01'}"
    re="$(printf '%s' "${re}" | sed 's/[.^$+?()[\]{}|]/\\&/g')"
    re="${re//$'\x01'/.*}"
    [[ "${path}" =~ ^${re}$ ]]
}

# What: Print the impact classes matched by the paths on stdin.
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

# What: Print the ci.sh phases selected by the paths on stdin.
# Why: NOOP when nothing matches; docs select doc-lint, not build.
# From: Issue #479
_ci_phases_for_paths() {
    local classes cls
    classes="$(_ci_classify_paths)"
    [ -n "${classes}" ] || { printf 'NOOP\n'; return 0; }
    for cls in ${classes}; do
        _ci_sot_list "impact_classes.${cls}.phases" || return 2
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
    local pair val
    for pair in \
        debian_verify=base_images.debian_verify \
        debian_release=base_images.debian_release \
        golang_actionlint=base_images.golang_actionlint \
        samba=external_versions.samba.version \
        actionlint=external_versions.actionlint.version \
        ccache_heartbeat=external_versions.ccache_heartbeat.version \
        codeql_cli=external_versions.codeql_cli.version \
        scorecard=external_versions.scorecard.version \
        osv_scanner=external_versions.osv_scanner.version \
        clusterfuzzlite=external_versions.clusterfuzzlite.version \
        redis=external_services.redis; do
        val="$(_ci_sot_scalar "${pair#*=}")" || return 2
        printf '%s=%s\n' "${pair%%=*}" "${val}"
    done
}

# What: Print the phases selected by the base..head diff.
# Why: A docs-only diff selects doc-lint, never a compile.
# From: Issue #479
ci_cmd_impact() {
    local base="${1:?base ref required}" head="${2:?head ref required}"
    cd "${CI_REPO_ROOT}"
    git diff --name-only "${base}" "${head}" | _ci_phases_for_paths
}

# What: Write hit=true/false for one impact class.
# Why: One command; no pipe/&& chain lives in the calling workflow.
# From: Issue #479
ci_cmd_impact_hit() {
    local class="${1:?class required}" base="${2:?base ref required}" head="${3:?head ref required}"
    : "${GITHUB_OUTPUT:?GITHUB_OUTPUT required}"
    cd "${CI_REPO_ROOT}"
    if git diff --name-only "${base}" "${head}" | _ci_classify_paths | grep -qx "${class}"; then
        echo "hit=true" >> "${GITHUB_OUTPUT}"
    else
        echo "hit=false" >> "${GITHUB_OUTPUT}"
    fi
}

# What: Emit the build matrix JSON (variant x os) from the SOT.
# Why: One owner feeds strategy.matrix; opt-in variants excluded.
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

# What: Log each harness container's tail, remove it all.
# Why: A leaked stack breaks the next run; so it must fail.
# From: Issue #479, PR #544
_ci_e2e_teardown() {
    local net="$1" rc=0 c
    local ctrs=() vols=()
    mapfile -t ctrs < <(docker ps -aq --filter "label=ci-e2e=${net}") || rc=1
    for c in "${ctrs[@]}"; do
        echo "== ${net}: last 100 log lines of ${c} =="
        docker logs --tail 100 "${c}" || rc=1
    done
    if [ "${#ctrs[@]}" -gt 0 ]; then
        docker rm -f "${ctrs[@]}" >/dev/null || rc=1
    fi
    mapfile -t vols < <(docker volume ls -q --filter "label=ci-e2e=${net}") || rc=1
    if [ "${#vols[@]}" -gt 0 ]; then
        docker volume rm "${vols[@]}" >/dev/null || rc=1
    fi
    if docker network inspect "${net}" >/dev/null 2>&1; then
        docker network rm "${net}" >/dev/null || rc=1
    fi
    if [ "${rc}" -ne 0 ]; then
        ci_log "[CI-ERROR-E2E-0003]" "teardown of ${net} failed; resources may leak"
    fi
    return "${rc}"
}

# What: Run a body on a fresh labelled net, then tear down.
# Why: A failed teardown fails an otherwise green run.
# From: Issue #479, PR #544
_ci_e2e_in_stack() {
    local net="$1" rc=0
    shift
    ( "$@" "${net}" ) || rc=$?
    if ! _ci_e2e_teardown "${net}" && [ "${rc}" -eq 0 ]; then
        rc=1
    fi
    return "${rc}"
}

# What: Wait for distccd's own "listening on" log line.
# Why: A TCP probe is a denied client; listen() follows it.
# From: Issue #479, PR #544
_ci_e2e_wait_port() {
    local ctr="$1" logs
    for _ in $(seq 1 30); do
        logs="$(docker logs "${ctr}" 2>&1)" || return 1
        if grep -q 'listening on' <<< "${logs}"; then
            return 0
        fi
        sleep 1
    done
    ci_log "[CI-ERROR-E2E-0014]" "distccd in ${ctr} never logged listening on"
    printf '%s\n' "${logs}" >&2
    return 1
}

# What: Build ng and native e2e images on the toolchain.
# Why: ng is the checkout under test; native is Debian's.
# From: Issue #264, Issue #479, PR #544
_ci_e2e_images() {
    local flavor
    for flavor in ng native; do
        docker build --file "${CI_REPO_ROOT}/test/e2e/Dockerfile" --target "${flavor}" \
            --build-arg "TOOLCHAIN_IMAGE=${CI_BUILDTOOLS_IMAGE}" \
            --tag "distcc-ng-e2e-${flavor}:local" "${CI_REPO_ROOT}" || return 1
    done
}

# What: One leg+pass: fresh server, workload, server proof.
# Why: A client exit code alone cannot rule out fallback.
# From: Issue #479, Issue #264, PR #544
_ci_e2e_leg() {
    local mode="$1" leg="$2" pass="$3" workload="$4" extra="$5" floor="$6" net="$7"
    local subnet="$8" cli="${leg%%:*}" srv_flavor="${leg##*:}" id srv out client_rc=0 need n warn
    id="${cli}-${srv_flavor}-${pass}"
    srv="${net}-server"
    out="${RUNNER_TEMP:-/tmp}/${net}-${id}"
    ci_log "[CI-E2E]" "${mode}: leg ${cli} -> ${srv_flavor}, pass ${pass}"
    docker run -d --init --name "${srv}" --label "ci-e2e=${net}" --network "${net}" \
        --network-alias distccd-server "distcc-ng-e2e-${srv_flavor}:local" \
        distccd --no-detach --daemon --verbose --log-stderr --port 3632 \
        --allow "${subnet}" --jobs "$(nproc)" >/dev/null || return 1
    _ci_e2e_wait_port "${srv}" || return 1
    docker run --rm --init --label "ci-e2e=${net}" --network "${net}" \
        -v "${CI_REPO_ROOT}:/ci:ro" -v "${net}-cache:/work/cache" -e CI_WORKLOAD_CACHE=/work/cache \
        -e DISTCC_HOSTS=distccd-server:3632 -e DISTCC_FALLBACK=0 -e DISTCC_VERBOSE=1 \
        "distcc-ng-e2e-${cli}:local" bash /ci/.github/scripts/ci.sh workload \
        "${workload}" "${pass}" "/work/workload/${id}" "${extra}" > "${out}.client" 2>&1 || client_rc=$?
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
    subnet="$(docker network create --label "ci-e2e=${net}" "${net}" >/dev/null \
        && docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "${net}")" || return 1
    docker volume create --label "ci-e2e=${net}" "${net}-cache" >/dev/null || return 1
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
        net="ci-e2e-${mode}-${GITHUB_RUN_ID:-local}-$$-${attempt}"
        ci_log "[CI-E2E]" "${mode}: attempt ${attempt}/${attempts}"
        if _ci_e2e_in_stack "${net}" _ci_e2e_mode_run "${mode}" "${workload}" "${extra}" "${floor}"; then
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
    local mode="${1:-distributed}" st=0
    case "${mode}" in
        control)
            _ci_e2e_images || return 1
            docker run --rm -v "${CI_REPO_ROOT}:/ci:ro" distcc-ng-e2e-ng:local \
                bash /ci/.github/scripts/ci.sh workload ccache local /work/workload/control "" || st=$?
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

# What: Build step of an e2e image, run by its Dockerfile.
# Why: Packages come from the SOT; the checkout is mounted.
# From: Issue #264, Issue #479, PR #544
ci_cmd_image() {
    local target="${1:-}" pkgs
    case "${target}" in
        e2e-ng|e2e-native) ;;
        *) ci_log "[CI-ERROR-IMAGE-0001]" "unknown image target=\"${target}\" (e2e-ng|e2e-native)"; return 2 ;;
    esac
    pkgs="$(_ci_sot_scalar e2e.image_apt)" || return 2
    if [ "${target}" = "e2e-native" ]; then
        pkgs="${pkgs} $(_ci_sot_scalar e2e.native_apt)" || return 2
    fi
    _ci_apt_install "${pkgs}" || return 1
    useradd --create-home --shell /bin/bash e2e || return 1
    mkdir -p /work/workload /work/cache || return 1
    chown -R e2e:e2e /work || return 1
    if [ "${target}" = "e2e-ng" ]; then
        cd "${CI_REPO_ROOT}" || return 1
        ./autogen.sh || return 1
        ./configure PYTHON=python3 --prefix=/usr/local || return 1
        make -j"$(nproc)" || return 1
        make install || return 1
    fi
    update-distcc-symlinks || return 1
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
        wget -q --tries=3 -O "${cache}/src.tar.gz" "${rel[0]}" || return 1
        wget -q --tries=3 -O "${cache}/sig" "${rel[1]}" || return 1
        wget -q --tries=3 -O "${cache}/key" "${rel[2]}" || return 1
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
    { ./autogen.sh && ./configure PYTHON=python3; } >&2 || return 1
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
        *) ci_log "[CI-ERROR-WORKLOAD-0006]" "unknown workload=\"${name}\" (self-compile|ccache|samba)"; return 2 ;;
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

# What: Fail unless a release tag matches configure.ac (POL-RELEASE-05/07).
# Why: require_new=false for a real, already-pushed tag; true pre-tag.
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

# What: docker build of docker/verify with base+actionlint from the SOT.
# Why: One owner for the verify build-args; callers add tags/extra args.
# From: Issue #479
_ci_build_verify_image() {
    local debian actionlint
    debian="$(_ci_sot_scalar base_images.debian_verify)" || return 2
    actionlint="$(_ci_sot_scalar external_versions.actionlint.version)" || return 2
    docker build --file docker/verify/Dockerfile \
        --build-arg "DEBIAN_IMAGE=${debian}" \
        --build-arg "ACTIONLINT_VERSION=${actionlint}" \
        "$@"
}

# What: docker login ghcr.io as GITHUB_ACTOR via stdin token.
# Why: Token varies per job; gc needs the delete:packages PAT.
# From: Issue #479, PR #544
_ci_registry_login() {
    : "${REGISTRY_TOKEN:?REGISTRY_TOKEN required}"
    : "${GITHUB_ACTOR:?GITHUB_ACTOR required}"
    printf '%s\n' "${REGISTRY_TOKEN}" | docker login ghcr.io -u "${GITHUB_ACTOR}" --password-stdin
}

# What: Build and push a release-family container image.
# Why: Base image ARG comes from the SOT; folds nightly's docker build.
# From: Issue #479
ci_cmd_container() {
    local first="${1:?variant or build/push required}"
    if [ "${first}" = "build" ] || [ "${first}" = "push" ]; then
        _ci_container_release "$@"
        return
    fi
    local variant="${first}" platform="${2:-}" ref debian
    cd "${CI_REPO_ROOT}"
    ref="${BUILT_SHA:-$(git rev-parse HEAD)}"
    debian="$(_ci_sot_scalar base_images.debian_release)" || return 2
    case "${variant}" in
        nightly)
            docker build --file docker/release/Dockerfile \
                --build-arg "DEBIAN_IMAGE=${debian}" \
                --build-arg "VCS_REF=${ref}" \
                --build-arg "VERSION=nightly" \
                --build-arg "CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                --tag "${IMAGE_TAG:?IMAGE_TAG required}" .
            _ci_registry_login
            docker push "${IMAGE_TAG}" ;;
        verify-image)
            _ci_build_verify_image --tag "${VERIFY_IMAGE:-${CI_VERIFY_IMAGE_TAG}}" . ;;
        buildtools)
            local short; short="$(git rev-parse --short HEAD)"
            local base="ghcr.io/${OWNER:?OWNER required}/distcc-ng-buildtools"
            _ci_build_verify_image \
                --build-arg "VCS_REF=${ref}" --build-arg "VERSION=${short}" \
                --tag "${base}:latest" --tag "${base}:${short}" .
            _ci_registry_login
            docker push "${base}:latest"
            docker push "${base}:${short}" ;;
        *) ci_log "[CI-ERROR-CONTAINER-0001]" "unimplemented container variant=\"${variant}\""; return 2 ;;
    esac
}

# What: Build (no push) or push a release plain/pump image.
# Why: Trivy scan needs the built, unpushed image.
# From: Issue #479
_ci_container_release() {
    local action="$1" variant platform ref debian target
    cd "${CI_REPO_ROOT}"
    case "${action}" in
        build)
            variant="${2:?variant required}"
            platform="${3:?platform required (amd64|arm64)}"
            : "${IMAGE_TAG:?IMAGE_TAG required}"
            ref="${BUILT_SHA:-$(git rev-parse HEAD)}"
            debian="$(_ci_sot_scalar base_images.debian_release)" || return 2
            target="runtime"
            [ "${variant}" = "pump" ] && target="runtime-pump"
            docker build --platform "linux/${platform}" \
                --file docker/release/Dockerfile --target "${target}" \
                --build-arg "DEBIAN_IMAGE=${debian}" \
                --build-arg "VCS_REF=${ref}" \
                --build-arg "VERSION=${VERSION:-${ref}}" \
                --build-arg "CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                --tag "${IMAGE_TAG}" . ;;
        push)
            local image_tag="${2:?image tag required}"
            _ci_registry_login
            docker push "${image_tag}" ;;
    esac
}

# What: Wire GH_TOKEN into git's own credential helper.
# Why: ci_cmd_checkout's remote has no credentials at all.
# From: Issue #479, PR #544
_ci_git_auth_setup() {
    : "${GH_TOKEN:?GH_TOKEN required}"
    gh auth setup-git
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
    _ci_git_auth_setup
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

# What: Create the multi-arch manifest from the pushed platform tags.
# Why: imagetools reads tags from the registry; no artifact handoff.
# From: Issue #479
_ci_publish_manifest() {
    local variant="${1:?variant required}"
    : "${IMAGE_BASE:?IMAGE_BASE required}"
    _ci_registry_login
    local tags=("${IMAGE_BASE}-amd64")
    if docker buildx imagetools inspect "${IMAGE_BASE}-arm64" >/dev/null 2>&1; then
        tags+=("${IMAGE_BASE}-arm64")
    else
        ci_log "[CI-PUBLISH]" "no arm64 image; amd64-only manifest for ${variant}"
    fi
    docker buildx imagetools create --tag "${IMAGE_BASE}" "${tags[@]}"
    if [ "${TAG_PUSH:-false}" = "true" ]; then
        docker buildx imagetools create --tag "${IMAGE_BASE%:*}:latest" "${tags[@]}"
    fi
}

# What: Cut the GitHub release for a version tag with built assets.
# Why: Version-check gates it; assets are the built packages/tarballs.
# From: Issue #479
_ci_publish_github_release() {
    local tag="${1:?tag required}" repo notes
    repo="${GITHUB_REPOSITORY:-wiki-mod/distcc-ng}"
    _ci_check_release_version "${tag}" || return 1
    cd "${CI_REPO_ROOT}"
    shopt -s nullglob
    local assets=(distcc-*.tar.gz distcc-*.tar.bz2 packaging/*.rpm packaging/*.deb)
    notes="$(mktemp)"
    printf 'distcc-ng %s\n' "${tag}" > "${notes}"
    gh release create "${tag}" "${assets[@]}" --repo "${repo}" \
        --target "${GITHUB_SHA:?GITHUB_SHA required}" \
        --title "distcc-ng ${tag}" --notes-file "${notes}" --latest
}

# What: Add a CHANGELOG.md section; commit to current_dev.
# Why: Folds two marketplace actions into one git commit.
# From: Issue #479
_ci_publish_changelog_update() {
    local tag="${1:?tag required}"
    : "${RELEASE_BODY:?RELEASE_BODY required}"
    local version date tmp
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
    tmp="$(mktemp)"
    {
        printf '## [%s] - %s\n\n' "${version}" "${date}"
        printf '%s\n' "${RELEASE_BODY}"
    } > "${tmp}"
    awk -v insertfile="${tmp}" '
        /<!-- insertion marker -->/ {
            print
            print ""
            while ((getline line < insertfile) > 0) print line
            next
        }
        { print }
    ' CHANGELOG.md > CHANGELOG.md.new
    mv CHANGELOG.md.new CHANGELOG.md
    rm -f "${tmp}"
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git add CHANGELOG.md
    git commit -m "CHANGELOG.md: add ${tag}"
    _ci_git_auth_setup
    git push origin HEAD:current_dev
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
# Why: Outward; real release cut/manifest are maintainer-driven.
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

# What: JSON array of digests a live multi-arch index holds.
# Why: Deleting such a child breaks pulls; errors abort.
# From: Issue #479, PR #544
_ci_gc_protected_digests() {
    local pkg="$1" versions="$2" tag raw children=""
    while IFS= read -r tag; do
        [ -n "${tag}" ] || continue
        if ! raw="$(docker buildx imagetools inspect --raw "ghcr.io/${OWNER}/${pkg}:${tag}")"; then
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
# SCHEDULED-CI STATUS REPORT
# =========================================================

# What: Echo space-separated names of failed/cancelled jobs from pairs.
# Why: A skip means an upstream dep failed first, not this job.
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
# Why: A matrix/impact-skipped job has no fixed context name
#   a branch ruleset can require; this one name always reports.
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

# What: Add the standing issue to the project board via the project PAT.
# Why: Only GH_TOKEN's own board touch needs a real project scope.
# From: Issue #479, Issue #81, PR #476
_ci_report_board() {
    local issue_url="$1"
    _ci_project_board_load || return 2
    if [ -z "${PROJECT_PAT:-}" ]; then
        echo "::warning::PROJECT_AUTOMATION_PAT not configured; ${issue_url} was not added to the board."
        return 0
    fi
    if [ "${DRY_RUN:-false}" = "true" ]; then
        echo "DRY_RUN would run: gh project item-add ${PROJECT_NUMBER} --owner ${PROJECT_OWNER} --url ${issue_url}"
        return 0
    fi
    GH_TOKEN="${PROJECT_PAT}" gh project item-add "${PROJECT_NUMBER}" \
        --owner "${PROJECT_OWNER}" --url "${issue_url}" >/dev/null
}

# What: Assign the Bug issue type to issue $1 unless it already has one.
# Why: Retrying on every failure self-heals an issue a one-shot attempt missed.
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
    if [ "${DRY_RUN:-false}" = "true" ]; then
        echo "DRY_RUN would run: assign Bug type to issue #${issue_number}"
        return 0
    fi
    gh api graphql -f query="
      mutation(\$issueId: ID!, \$typeId: ID!) {
        updateIssue(input: {id: \$issueId, issueTypeId: \$typeId}) { issue { id } }
      }" -F issueId="${issue_node_id}" -F typeId="${bug_type_id}" >/dev/null
}

# What: File, update, or close the one standing nightly-broken tracking issue.
# Why: Every scheduled workflow shares this issue, so a success anywhere closes
#   what another filed; the next real failure re-files it.
# From: Issue #479, Issue #81, PR #89, PR #476
ci_cmd_report() {
    : "${GH_TOKEN:?GH_TOKEN required}"
    : "${REPO:?REPO required, e.g. wiki-mod/distcc-ng}"
    : "${OUTCOME:?OUTCOME required (success|failure)}"
    : "${SCOPE:?SCOPE required, e.g. 'weekly ccache heartbeat (master)'}"
    : "${RUN_URL:?RUN_URL required}"
    local LABEL="${LABEL:-nightly-broken}" existing detail new_issue_url
    local DRY_RUN="${DRY_RUN:-false}" FAILED_JOBS="${FAILED_JOBS:-}"
    local PROJECT_PAT="${PROJECT_PAT:-}"
    local PROJECT_OWNER PROJECT_NUMBER
    _ci_project_board_load || return 2
    # What: Derive FAILED_JOBS from JOBS (name=result lines) when provided.
    # Why: Only failure/cancelled are real; a skip means an upstream dep failed.
    # From: Issue #479, PR #476
    local JOBS="${JOBS:-}"
    [ -n "${JOBS}" ] && FAILED_JOBS="$(_ci_failed_jobs "${JOBS}")"
    existing="$(gh issue list --repo "${REPO}" --label "${LABEL}" --state open \
        --json number --jq 'sort_by(.number) | .[0].number // empty')"
    if [ "${OUTCOME}" = "success" ]; then
        if [ -n "${existing}" ]; then
            _ci_report_ensure_bug_type "${existing}"
            _ci_report_board "https://github.com/${REPO}/issues/${existing}"
            echo "success: closing standing ${LABEL} issue #${existing}"
            _ci_mutate gh issue comment "${existing}" --repo "${REPO}" \
                --body "Recovered: ${SCOPE} succeeded in ${RUN_URL}. Closing this standing tracking issue automatically; it will re-open if a later scheduled run fails."
            _ci_mutate gh issue close "${existing}" --repo "${REPO}"
        else
            echo "success and no open ${LABEL} issue: nothing to do"
        fi
        return 0
    fi
    _ci_mutate gh label create "${LABEL}" --repo "${REPO}" --color b60205 \
        --description "A scheduled nightly/heartbeat CI run is failing" 2>/dev/null || true
    detail="${SCOPE} failed in ${RUN_URL}"
    [ -n "${FAILED_JOBS}" ] && detail="${detail} (failed: ${FAILED_JOBS})"
    if [ -n "${existing}" ]; then
        echo "failure: commenting on standing ${LABEL} issue #${existing}"
        _ci_mutate gh issue comment "${existing}" --repo "${REPO}" \
            --body "Still failing: ${detail}."
        _ci_report_ensure_bug_type "${existing}"
        _ci_report_board "https://github.com/${REPO}/issues/${existing}"
    else
        echo "failure: opening a new standing ${LABEL} issue"
        new_issue_url="$(_ci_mutate gh issue create --repo "${REPO}" --label "${LABEL}" \
            --title "[${LABEL}] a scheduled CI run is failing" \
            --body "A scheduled CI run failed. This standing issue is reused across consecutive failures and closed automatically on the next successful run.

${detail}.")"
        if [ "${DRY_RUN}" = "true" ]; then
            echo "${new_issue_url}"
            echo "DRY_RUN would run: assign Bug type to the newly created issue"
            if [ -z "${PROJECT_PAT}" ]; then
                echo "::warning::PROJECT_PAT not configured; the newly created issue would not be added to the project board."
            else
                echo "DRY_RUN would run: gh project item-add ${PROJECT_NUMBER} --owner ${PROJECT_OWNER} --url <new issue URL>"
            fi
        else
            _ci_report_ensure_bug_type "${new_issue_url##*/}"
            _ci_report_board "${new_issue_url}"
        fi
    fi
}

# =========================================================
# VARIABLES (workflow output helpers)
# =========================================================

# What: Write available=true/false to GITHUB_OUTPUT from SECRET_VALUE.
# Why: GitHub forbids the secrets context in an if:, so the gate lives here.
# From: Issue #479, PR #329
_ci_variables_secret_present() {
    : "${GITHUB_OUTPUT:?GITHUB_OUTPUT required}"
    if [ -n "${SECRET_VALUE:-}" ]; then
        echo "available=true" >> "${GITHUB_OUTPUT}"
    else
        echo "available=false" >> "${GITHUB_OUTPUT}"
    fi
}

# What: Add an issue/PR to the org project board via gh CLI.
# Why: Replaces actions/add-to-project; gh project item-add is native.
# From: Issue #479
_ci_variables_add_to_project() {
    : "${ITEM_URL:?ITEM_URL required}"
    _ci_project_board_load || return 2
    gh project item-add "${PROJECT_NUMBER}" --owner "${PROJECT_OWNER}" --url "${ITEM_URL}"
}

# What: True if a changed file is under doc/ or a non-CHANGELOG .md.
# Why: Mirrors labeler.yml's documentation label's any:/negation rule.
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
# Why: Shared by every simple labeler rule; herestring avoids a subshell.
# From: Issue #479
_ci_labeler_glob_matches_any() {
    local pat="$1" files="$2" f
    while IFS= read -r f; do
        _ci_glob_match "${pat}" "${f}" && return 0
    done <<< "${files}"
    return 1
}

# What: Print "label glob" lines for labeler.yml's simple OR rules.
# Why: One purpose-built reader; only documentation needs any:/negation.
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
# Why: One owner for the small gate logic GitHub can't express in YAML.
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

# What: Echo Met when pattern is in file (opt -i), else NotMet.
# Why: One owner for the many grep-based baseline checks.
# From: Issue #479, Issue #312
_ci_ossf_grep() {
    local file="$1" pattern="$2" ci="${3:-}"
    if [ -n "${ci}" ]; then
        grep -qi -- "${pattern}" "${file}" 2>/dev/null && { echo "Met"; return; }
    else
        grep -q -- "${pattern}" "${file}" 2>/dev/null && { echo "Met"; return; }
    fi
    echo "NotMet"
}

# What: URL-encode one argument via jq @uri.
# Why: Justification text must survive as a valid query-string value.
# From: Issue #312
_ci_ossf_urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

# What: Append one status=Met&justification pair to a query-string nameref.
# Why: Only currently-Met criteria are offered in the proposal URL.
# From: Issue #312
_ci_ossf_add_met() {
    local -n _qs="$1"
    local osps_id="$2" justification="$3" param_key enc_just
    param_key="$(echo "${osps_id}" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"
    enc_just="$(_ci_ossf_urlencode "${justification}")"
    [ -n "${_qs}" ] && _qs="${_qs}&"
    _qs="${_qs}${param_key}_status=Met&${param_key}_justification=${enc_just}"
}

# What: Build the bestpractices.dev edit-form URL for one baseline level.
# Why: Callers pass an assembled Met-criteria query string.
# From: Issue #312
_ci_ossf_url() { echo "https://www.bestpractices.dev/en/projects/${PROJECT_ID}/baseline-$1/edit?$2"; }

# What: Ruleset still enforces a pull_request and a deletion rule.
# Why: A recreated-under-new-ID ruleset is the drift this catches.
# From: Issue #312
_ci_ossf_check_ac03() {
    local types
    types="$(gh api "repos/${REPO}/rulesets/18300729" --jq '[.rules[].type]' 2>/dev/null)" || { echo "NotMet"; return; }
    if echo "${types}" | jq -e 'contains(["pull_request"]) and contains(["deletion"])' >/dev/null; then
        echo "Met"; else echo "NotMet"; fi
}

# What: No workflow runs untrusted fork code under pull_request_target,
#   and none interpolates untrusted event title/body text.
# Why: pull_request_target is only risky when it also checks out PR head.
# From: Issue #312
_ci_ossf_check_br01() {
    local hits=0 f
    for f in .github/workflows/*.yml; do
        if grep -q "pull_request_target" "${f}" 2>/dev/null \
            && grep -qE 'pull_request\.head\.(sha|ref)' "${f}" 2>/dev/null; then
            hits=1
        fi
    done
    if grep -v '^[[:space:]]*#' .github/workflows/*.yml 2>/dev/null \
        | grep -qE 'github\.event\.(pull_request|issue|comment)\.(title|body)'; then
        hits=1
    fi
    [ "${hits}" -eq 0 ] && echo "Met" || echo "NotMet"
}

# What: Secret scanning and its push protection are both enabled.
# Why: Needs an admin-scoped token; github.token never returns the field.
# From: Issue #312
_ci_ossf_check_br07() {
    local analysis
    analysis="$(gh api "repos/${REPO}" --jq '.security_and_analysis')"
    if echo "${analysis}" | jq -e '.secret_scanning.status == "enabled" and .secret_scanning_push_protection.status == "enabled"' >/dev/null; then
        echo "Met"; else echo "NotMet"; fi
}

# What: No compiled binary artifact is tracked in the git tree.
# Why: Build outputs must be produced, never committed.
# From: Issue #312
_ci_ossf_check_qa05() {
    if git ls-tree -r HEAD --name-only | grep -Ei '\.(o|so|a|exe|dll|bin)$' >/dev/null; then
        echo "NotMet"; else echo "Met"; fi
}

# What: Every workflow declares a top-level permissions block, none broad.
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

# What: A build-provenance attestation step exists in some workflow.
# Why: Scans all workflows so it survives the package->release rename.
# From: Issue #312, Issue #479
_ci_ossf_check_br06() {
    if grep -rq "actions/attest-build-provenance" .github/workflows/ 2>/dev/null; then
        echo "Met"; else echo "NotMet"; fi
}

# What: dependabot.yml exists and the dependency policy is documented.
# Why: Both must hold for OSPS-BR-05.01/DO-06.01.
# From: Issue #312
_ci_ossf_check_br05_do06() {
    if [ -f .github/dependabot.yml ] && grep -q "## Dependency management policy" doc/compatibility-policy.md 2>/dev/null; then
        echo "Met"; else echo "NotMet"; fi
}

# What: Run every OpenSSF baseline check, post/update the tracking comment.
# Why: One owner for the recheck logic; workflows only call the phase.
# From: Issue #479, Issue #312
_ci_scan_openssf() {
    : "${REPO:?REPO required, e.g. wiki-mod/distcc-ng}"
    : "${ISSUE_NUMBER:?ISSUE_NUMBER required (the tracking issue)}"
    local PROJECT_ID="${PROJECT_ID:-13760}" DRY_RUN="${DRY_RUN:-false}"
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
        state_line="$(echo "${prev_body}" | grep -o '<!-- openssf-baseline-recheck-state: .*-->' || true)"
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
    [ "${br05_do06}" = "Met" ] && _ci_ossf_add_met qs2 "OSPS-BR-05.01" ".github/dependabot.yml still exists, re-verified ${TODAY}."
    [ "${br05_do06}" = "Met" ] && _ci_ossf_add_met qs2 "OSPS-DO-06.01" "doc/compatibility-policy.md documents the dependency policy, re-verified ${TODAY}."
    [ "${gv01}" = "Met" ] && _ci_ossf_add_met qs2 "OSPS-GV-01.01" "AGENTS.md documents maintainer approval authority, re-verified ${TODAY}."
    [ "${gv01}" = "Met" ] && _ci_ossf_add_met qs2 "OSPS-GV-01.02" "Same rule, re-verified ${TODAY}."
    [ "${vm01_vm03}" = "Met" ] && _ci_ossf_add_met qs2 "OSPS-VM-01.01" "SECURITY.md documents GitHub Security Advisories as the channel, re-verified ${TODAY}."
    [ "${vm01_vm03}" = "Met" ] && _ci_ossf_add_met qs2 "OSPS-VM-03.01" "Same document, re-verified ${TODAY}."
    l2="- AC-04.01 (workflow permissions spot-check): ${ac04}
- BR-06.01 (build provenance attestation present): ${br06}
- BR-05.01/DO-06.01 (dependabot.yml + dependency policy doc): ${br05_do06}
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
    if [ "${DRY_RUN}" = "true" ]; then
        echo "--- DRY_RUN: composed comment body ---"
        echo "${body}"
        return 0
    fi
    if [ -n "${existing_id}" ]; then
        gh api --method PATCH "repos/${REPO}/issues/comments/${existing_id}" -f body="${body}" >/dev/null
    else
        gh api --method POST "repos/${REPO}/issues/${ISSUE_NUMBER}/comments" -f body="${body}" >/dev/null
    fi
}

# What: Download, verify, cache a release tarball; print dir.
# Why: One owner for every SOT-pinned tool download.
# From: Issue #479, PR #544
_ci_fetch_release_tarball() {
    local name="${1:?name required}" ver="${2:?version required}"
    local url="${3:?url required}" sha256="${4:-}" dest archive
    dest="${RUNNER_TEMP:-/tmp}/${name}-${ver}"
    if [ ! -f "${dest}/.complete" ]; then
        rm -rf "${dest}"
        mkdir -p "${dest}"
        archive="${dest}.tar.gz"
        curl -fsSL --retry 3 -o "${archive}" "${url}" || return 2
        if [ -n "${sha256}" ] && ! printf '%s  %s\n' "${sha256}" "${archive}" | sha256sum -c --quiet -; then
            ci_log "[CI-ERROR-FETCH-0001]" "sha256 mismatch for ${name} ${ver}"
            return 2
        fi
        tar -xzf "${archive}" -C "${dest}" || return 2
        rm -f "${archive}"
        touch "${dest}/.complete"
    fi
    printf '%s' "${dest}"
}

# What: Download+cache the pinned Trivy CLI; print its path.
# Why: No marketplace action; version owned by SOT.
# From: Issue #479
_ci_trivy_bin() {
    local ver dest
    ver="$(_ci_sot_scalar external_versions.trivy.version)" || return 2
    dest="$(_ci_fetch_release_tarball trivy "${ver}" \
        "https://github.com/aquasecurity/trivy/releases/download/${ver}/trivy_${ver#v}_Linux-64bit.tar.gz")" || return 2
    printf '%s/trivy' "${dest}"
}

# What: Scan a local image ref for HIGH/CRITICAL vulns.
# Why: Folds trivy-action; scans before any registry push.
# From: Issue #479
ci_cmd_trivy_scan() {
    local image_ref="${1:?image ref required}" bin
    bin="$(_ci_trivy_bin)" || return 2
    "${bin}" image --scanners vuln,secret --severity HIGH,CRITICAL \
        --ignore-unfixed --ignorefile "${CI_REPO_ROOT}/.trivyignore.yaml" \
        --exit-code 1 --timeout 10m "${image_ref}"
}

# What: Download+cache the pinned Syft CLI; print its path.
# Why: No marketplace action; version owned by SOT.
# From: Issue #479
_ci_syft_bin() {
    local ver dest
    ver="$(_ci_sot_scalar external_versions.syft.version)" || return 2
    dest="$(_ci_fetch_release_tarball syft "${ver}" \
        "https://github.com/anchore/syft/releases/download/${ver}/syft_${ver#v}_linux_amd64.tar.gz")" || return 2
    printf '%s/syft' "${dest}"
}

# What: Generate an SPDX-JSON SBOM for an image/path.
# Why: Folds anchore/sbom-action; OSPS-QA-02.02 baseline.
# From: Issue #479
ci_cmd_sbom() {
    local target="${1:?image ref or path required}" out="${2:?output file required}" bin
    bin="$(_ci_syft_bin)" || return 2
    "${bin}" "${target}" -o "spdx-json=${out}"
}

# What: Security scan dispatch (currently the OpenSSF baseline recheck).
# Why: One phase owner; codeql/osv/scorecard/fuzz are pure workflow actions.
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

# What: docker run with SYS_PTRACE + this repo's narrow seccomp profile.
# Why: the two ptrace steps must share one flag set, not drift apart.
# From: Issue #285, PR #528
_ci_docker_run_ptrace() {
    docker run --rm --cap-add=SYS_PTRACE \
        --security-opt seccomp="${VERIFY_SECCOMP:-${CI_REPO_ROOT}/docker/verify/seccomp-verify.json}" \
        "$@"
}

# What: run one verify-image check inside distcc-ng-verify:ci.
# Why: keeps all verify logic in ci.sh; workflows only call phases.
# From: Issue #285, Issue #286, PR #528
ci_cmd_verify() {
    local sub="${1:?verify subcommand required}"
    local image="${VERIFY_IMAGE:-${CI_VERIFY_IMAGE_TAG}}"
    cd "${CI_REPO_ROOT}"
    case "${sub}" in
        prepare-etc)
            mkdir -p "${RUNNER_TEMP}/verify-etc"
            docker run --rm "${image}" cat /etc/passwd > "${RUNNER_TEMP}/verify-etc/passwd"
            docker run --rm "${image}" cat /etc/group > "${RUNNER_TEMP}/verify-etc/group"
            printf 'ci-runner:x:%s:%s:GitHub Actions runner uid:/tmp/distcc-ng-verify-home:/bin/bash\n' \
                "$(id -u)" "$(id -g)" >> "${RUNNER_TEMP}/verify-etc/passwd"
            printf 'ci-runner:x:%s:\n' "$(id -g)" >> "${RUNNER_TEMP}/verify-etc/group" ;;
        ptrace-selftest)
            _ci_docker_run_ptrace -e ASLR_MUST_DISABLE=1 \
                -v "${CI_REPO_ROOT}/docker/verify:/verify:ro" \
                "${image}" bash /verify/selftest-ptrace.sh ;;
        build-test)
            _ci_docker_run_ptrace \
                --user "$(id -u):$(id -g)" --init \
                -v "${CI_REPO_ROOT}:/work/src:rw" \
                -v "${RUNNER_TEMP}/verify-etc/passwd:/etc/passwd:ro" \
                -v "${RUNNER_TEMP}/verify-etc/group:/etc/group:ro" \
                -w /work/src -e HOME=/tmp/distcc-ng-verify-home \
                "${image}" bash -c "
                    set -euo pipefail
                    mkdir -p \"\${HOME}\"; id
                    ./autogen.sh
                    ./configure PYTHON=python3
                    make
                    make check
                " ;;
        ccache-redis)
            _ci_verify_ccache_redis "${image}" ;;
        samba-configure-dryrun)
            # What: Verified Samba configure inside the verify image.
            # Why: Proves the image's build-deps; same fetch owner.
            # From: Issue #479, Issue #285, PR #544
            docker run --rm -v "${CI_REPO_ROOT}:/ci:ro" "${image}" \
                bash /ci/.github/scripts/ci.sh workload samba configure /tmp/samba ;;
        *) ci_log "[CI-ERROR-VERIFY-0001]" "unknown verify subcommand=\"${sub}\""; return 2 ;;
    esac
}

# What: Block until the SOT-pinned Redis container answers PING, or fail.
# Why: The ccache builds must not race a not-yet-ready Redis backend.
# From: Issue #479, Issue #285
_ci_wait_for_redis() {
    local cid="$1" tries=0
    while [ "${tries}" -lt 30 ]; do
        [ "$(docker exec "${cid}" redis-cli ping 2>/dev/null)" = "PONG" ] && return 0
        tries=$((tries + 1)); sleep 1
    done
    ci_log "[CI-ERROR-VERIFY-0004]" "Redis backend did not become ready within 30s"
    return 1
}

# What: prove ccache's Redis remote backend serves a real cross-container hit.
# Why: a single container's local dir would false-hit without Redis involved.
# From: Issue #285, Issue #479, PR #528
_ci_verify_ccache_redis() {
    local image="$1" redis_image redis_cid rc=0
    # What: Redis digest comes from the SOT; ci.sh starts it with a 2g cap.
    # Why: The ccache-remote-storage workload needs the maintainer's ~2GB budget.
    # From: Issue #479, Issue #285
    redis_image="$(_ci_sot_scalar external_services.redis)" || return 2
    redis_cid="$(docker run -d --memory=2g --network host "${redis_image}")"
    _ci_verify_ccache_build() {
        docker run --rm --network host --user "$(id -u):$(id -g)" \
            -v "${CI_REPO_ROOT}:/work/src:rw" -w /work/src \
            -e CCACHE_REMOTE_STORAGE="redis://127.0.0.1:6379" \
            -e HOME=/tmp/ccache-home \
            "${image}" bash -c "
                set -euo pipefail
                mkdir -p \"\${HOME}\"; cd /work/src
                ccache --zero-stats >/dev/null
                touch src/dopt.c
                make CC=\"ccache gcc\" src/dopt.o
                ccache --show-stats
            " | tee "$2"
    }
    if ! _ci_wait_for_redis "${redis_cid}"; then rc=1; fi
    if [ "${rc}" -eq 0 ]; then
        _ci_verify_ccache_build "first (MISS, pushes to Redis)" "${RUNNER_TEMP}/first-run-stats.log" || rc=$?
    fi
    if [ "${rc}" -eq 0 ]; then
        _ci_verify_ccache_build "second (fresh, a Hit can only come from Redis)" "${RUNNER_TEMP}/second-run-stats.log" || rc=$?
    fi
    docker rm -f "${redis_cid}" >/dev/null 2>&1 || true
    if [ "${rc}" -ne 0 ]; then
        ci_log "[CI-ERROR-VERIFY-0003]" "ccache/Redis verify step failed (rc=${rc})"
        return "${rc}"
    fi
    if ! grep -qE "Hits:[[:space:]]*[1-9]" "${RUNNER_TEMP}/second-run-stats.log"; then
        ci_log "[CI-ERROR-VERIFY-0002]" "no ccache hit on the fresh container -- Redis backend did not serve the object"
        return 1
    fi
    echo "Real cache hit confirmed against the SOT-pinned, ci.sh-managed Redis backend."
}

# =========================================================
# METADATA CHECKS (PR context)
# =========================================================

# What: Validate a PR title against the rule-71 taxonomy.
# Why: Folds check-pr-title-convention.sh; dependabot exempt.
# From: Issue #479, rule 71
_ci_check_pr_title() {
    local title="${PR_TITLE:-}"
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
    if [ "${PR_AUTHOR:-}" = "dependabot[bot]" ]; then
        ci_log "[CI-META-TRACKING]" "skipped: dependabot[bot]"
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
        if ! sot="$(_ci_sot_scalar "base_images.${key}")"; then
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
# Why: YAML stays an orchestrator; run: calls one ci.sh command only.
# From: Issue #479
_ci_scan_run_blocks() {
    awk -v F="$1" '
        function flag(r){ print F":"NR": "r }
        /^[ ]*(- )?uses:[ ]/ { flag("uses: step (only ci.sh may run)"); next }
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

# What: Run a command inside the published buildtools image.
# Why: uid-matched, read-only; shared by every lint check.
# From: Issue #479
_ci_lint_buildtools_run() {
    docker run --rm --user "$(id -u):$(id -g)" \
        -v "${CI_REPO_ROOT}:/work:ro" -w /work \
        "${CI_BUILDTOOLS_IMAGE}" "$@"
}

# What: Lint every workflow file with actionlint.
# Why: File list built on the host; no nested-shell expansion.
# From: Issue #479
_ci_lint_actionlint() {
    local files=()
    while IFS= read -r f; do files+=("${f}"); done \
        < <(cd "${CI_REPO_ROOT}" && find .github/workflows -name "*.yml" -type f)
    _ci_lint_buildtools_run actionlint -color "${files[@]}"
}

# What: Shellcheck ci.sh, this repo's real shell engine.
# Why: test/e2e*/*.sh stay explicitly out of scope.
# From: Issue #479
_ci_lint_shellcheck() {
    _ci_lint_buildtools_run shellcheck .github/scripts/ci.sh
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
    for d in .github/workflows .github/yaml docker; do
        [ -e "${CI_REPO_ROOT}/${d}" ] || continue
        ci_guard_full_sha "${CI_REPO_ROOT}/${d}" || rc=1
    done
    ci_guard_dependabot_consistency "${CI_REPO_ROOT}" || rc=1
    # Every shipped workflow is an orchestrator; there is no legacy exemption.
    ci_guard_orchestrator_only "${CI_REPO_ROOT}"/.github/workflows/*.yml || rc=1
    ci_guard_action_pin_sot "${CI_REPO_ROOT}"/.github/workflows/*.yml || rc=1
    _ci_lint_actionlint || rc=1
    _ci_lint_shellcheck || rc=1
    return "${rc}"
}

# =========================================================
# INSTALL (apt/brew dependency installers)
# =========================================================

# What: apt-get update+install with a bounded 2x3-minute retry.
# Why: ubuntu-latest's default mirror has hung indefinitely.
# From: Issue #493, Issue #479
_ci_apt_install() {
    local packages="${1:?package list required}" max_attempts=2 attempt=1
    local as_root=(sudo)
    if [ "$(id -u)" -eq 0 ]; then
        as_root=()
    fi
    while true; do
        if "${as_root[@]}" timeout -k 10s 3m bash -c "apt-get update && apt-get install -y ${packages}"; then
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
    local why ver sha api tel web egress cid resp code otk="" summary="false"
    local private dest
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
    ver="$(_ci_sot_scalar external_versions.harden_runner_agent.version)" || return 2
    sha="$(_ci_sot_scalar external_versions.harden_runner_agent.sha256)" || return 2
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
    dest="$(_ci_fetch_release_tarball harden-runner-agent "${ver}" \
        "https://github.com/step-security/agent/releases/download/${ver}/agent_${ver#v}_linux_amd64.tar.gz" \
        "${sha}")" || return 2
    sudo mkdir -p "${_CI_HARDEN_DIR}"
    sudo chown -R "${USER}" "${_CI_HARDEN_DIR}"
    cp "${dest}/agent" "${_CI_HARDEN_DIR}/agent"
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
# ACTION-PIN GUARD (build-manifest.yml is the sole SHA owner)
# =========================================================

# What: Fail if any given file carries an action SHA pin.
# Why: SOT is the only owner; ci.sh runs tools itself.
# From: Issue #479, PR #544
ci_guard_action_pin_sot() {
    local rc=0 f
    for f in "$@"; do
        [ -f "${f}" ] || continue
        if grep -qE '@[0-9a-f]{40}' "${f}" 2>/dev/null; then
            rc=1
            ci_log "[CI-ERROR-GUARD-APIN-0001]" \
                "file=\"${f}\" reason=\"SHA pin outside SOT\""
        fi
    done
    return "${rc}"
}

# =========================================================
# SECURITY TOOLS (own CLI invocations; no marketplace actions)
# =========================================================

# What: Download+cache the pinned CodeQL CLI; print its path.
# Why: Own invocation, no JS action; version owned by SOT.
# From: Issue #479
_ci_codeql_bin() {
    local ver dest
    ver="$(_ci_sot_scalar external_versions.codeql_cli.version)" || return 2
    dest="$(_ci_fetch_release_tarball codeql "${ver}" \
        "https://github.com/github/codeql-action/releases/download/codeql-bundle-${ver}/codeql-bundle-linux64.tar.gz")" || return 2
    printf '%s/codeql/codeql' "${dest}"
}

# What: Map language+suite to a CodeQL query-pack reference.
# Why: One mapping; callers pass a plain suite name like init did.
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
# Why: CLI-native flow; c-cpp traces the repo's own build command.
# From: Issue #479
ci_cmd_codeql_scan() {
    local lang="${1:?language required}" suite="${2:-security-extended}" \
        out="${3:-results-${1}.sarif}" bin db pack
    bin="$(_ci_codeql_bin)" || return 2
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
# Why: Replaces codeql-action/upload-sarif; no marketplace action.
# From: Issue #479
ci_cmd_sarif_upload() {
    local file="${1:?sarif file required}" payload
    : "${GH_TOKEN:?GH_TOKEN required}"
    payload="$(gzip -c "${file}" | base64 -w0)"
    gh api "repos/${GITHUB_REPOSITORY}/code-scanning/sarifs" \
        -f "commit_sha=${GITHUB_SHA}" \
        -f "ref=${GITHUB_REF}" \
        -f "sarif=${payload}" >/dev/null
}

# What: Download+cache the pinned Scorecard CLI; print its path.
# Why: Own invocation, no marketplace action; version owned by SOT.
# From: Issue #479
_ci_scorecard_bin() {
    local ver dest
    ver="$(_ci_sot_scalar external_versions.scorecard.version)" || return 2
    dest="$(_ci_fetch_release_tarball scorecard "${ver}" \
        "https://github.com/ossf/scorecard/releases/download/${ver}/scorecard_${ver#v}_linux_amd64.tar.gz")" || return 2
    printf '%s/scorecard' "${dest}"
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
    bin="$(_ci_scorecard_bin)" || return 2
    json="${RUNNER_TEMP:-/tmp}/scorecard-results.json"
    "${bin}" --repo="github.com/${GITHUB_REPOSITORY}" \
        --format=json --show-details > "${json}"
    _ci_scorecard_json_to_sarif < "${json}" > "${out}"
}

# What: Download+cache the pinned OSV-Scanner CLI; print its path.
# Why: Own invocation, no reusable workflow; version owned by SOT.
# From: Issue #479
_ci_osv_scanner_bin() {
    local ver dest bin
    ver="$(_ci_sot_scalar external_versions.osv_scanner.version)" || return 2
    dest="${RUNNER_TEMP:-/tmp}/osv-scanner-${ver}"
    bin="${dest}/osv-scanner"
    if [ ! -x "${bin}" ]; then
        mkdir -p "${dest}"
        curl -fsSL --retry 3 -o "${bin}" \
            "https://github.com/google/osv-scanner/releases/download/${ver}/osv-scanner_linux_amd64"
        chmod +x "${bin}"
    fi
    printf '%s' "${bin}"
}

# What: Scan the repo with OSV-Scanner, writing a SARIF file.
# Why: CLI-native flow; no osv-scanner-action reusable workflow.
# From: Issue #479
ci_cmd_osv_scan() {
    local out="${1:-osv-results.sarif}" bin rc=0
    bin="$(_ci_osv_scanner_bin)" || return 2
    "${bin}" scan source --format=sarif --output-file="${out}" \
        --allow-no-lockfiles -r . || rc=$?
    # osv-scanner exit 1-126 means "vulnerabilities found", not a tool
    # failure; only 127+ (general/non-result error) is a real failure.
    if [ "${rc}" -ge 127 ]; then
        ci_log "[CI-ERROR-SCAN-0002]" "tool=osv-scanner exit=${rc} reason=\"scan failed\""
        return 2
    fi
}

# What: Print the pinned ClusterFuzzLite step image for a step.
# Why: One lookup; build/run share the SOT-owned image tag.
# From: Issue #479
_ci_clusterfuzzlite_image() {
    local step="${1:?build or run required}" tag
    tag="$(_ci_sot_scalar external_versions.clusterfuzzlite.version)" || return 2
    printf 'gcr.io/oss-fuzz-base/clusterfuzzlite-%s-fuzzers:%s' "${step}" "${tag}"
}

# What: Run the ClusterFuzzLite build-fuzzers step via docker.
# Why: Own docker run, no marketplace Docker action; SOT-pinned tag.
# From: Issue #479
ci_cmd_clusterfuzzlite_build() {
    local sanitizer="${1:-address}" image
    image="$(_ci_clusterfuzzlite_image build)" || return 2
    docker run --rm -v "$(pwd):/src/${GITHUB_REPOSITORY#*/}" \
        -e LANGUAGE=c -e SANITIZER="${sanitizer}" -e CFL_PLATFORM=standalone \
        -e FILESTORE_ROOT_DIR=/tmp/cfl-filestore -e LOW_DISK_SPACE=True \
        -e WORKSPACE=/tmp/cfl-workspace -e "REPOSITORY=${GITHUB_REPOSITORY#*/}" \
        "${image}"
}

# What: Run the ClusterFuzzLite run-fuzzers step via docker.
# Why: Own docker run, no marketplace Docker action; SOT-pinned tag.
# From: Issue #479
ci_cmd_clusterfuzzlite_run() {
    local sanitizer="${1:-address}" fuzz_seconds="${2:-300}" mode="${3:-code-change}" image
    image="$(_ci_clusterfuzzlite_image run)" || return 2
    docker run --rm -v "$(pwd):/src/${GITHUB_REPOSITORY#*/}" \
        -e FUZZ_SECONDS="${fuzz_seconds}" -e MODE="${mode}" \
        -e SANITIZER="${sanitizer}" -e CFL_PLATFORM=standalone \
        -e FILESTORE_ROOT_DIR=/tmp/cfl-filestore \
        -e WORKSPACE=/tmp/cfl-workspace -e "REPOSITORY=${GITHUB_REPOSITORY#*/}" \
        -e LOW_DISK_SPACE=True -e OUTPUT_SARIF=true \
        "${image}"
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
        gcc "${cflags[@]}" -c "${f}" -o "${out}/$(basename "${f}").o"
    done
}

# What: Verify the vendored popt/ tree has 3 CVE fixes.
# Why: A silent revert to a pre-fix snapshot would compile fine.
# From: Issue #479
_ci_popt_cve_fingerprint_check() {
    local want got rc=0
    want="$(_ci_sot_scalar external_versions.popt_vendor.version)" || return 2
    got="$(cat popt/POPT_VERSION 2>/dev/null || true)"
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
            _ci_popt_cve_fingerprint_check || return 1
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

# What: Report include_server/*.py coverage from the run.
# Why: lcov alone hides Python's coverage.
# From: Issue #479
_ci_coverage_python_report() {
    python3-coverage report --include="${CI_REPO_ROOT}/include_server/*"
}

# What: Append C+Python coverage to the job summary.
# Why: No artifact upload; summary page is the readout.
# From: Issue #479
_ci_coverage_step_summary() {
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
    local fence
    fence='```'
    {
        printf '## Coverage summary\n\n### C (lcov)\n%s\n' "${fence}"
        lcov --list coverage.info --rc branch_coverage=1
        printf '%s\n\n### Python (include_server)\n%s\n' "${fence}" "${fence}"
        _ci_coverage_python_report
        printf '%s\n' "${fence}"
    } >> "${GITHUB_STEP_SUMMARY}"
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
    if [ "${variant}" = "coverage" ]; then
        _ci_coverage_lcov
        _ci_coverage_step_summary
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
                resolve) ci_cmd_resolve "$@" ;;
                impact) ci_cmd_impact "$@" ;;
                impact-hit) ci_cmd_impact_hit "$@" ;;
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
if [ "${BASH_SOURCE[0]:-${0}}" = "${0}" ]; then
    ci_main "$@"
fi
