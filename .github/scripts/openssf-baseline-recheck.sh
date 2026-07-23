#!/usr/bin/env bash
#
# Re-verifies the mechanically-checkable OpenSSF Best Practices Baseline
# criteria (bestpractices.dev project 13760) against this repo/org's live
# state, and posts (or updates) a single status comment on the recurring
# recheck tracking issue (see ISSUE_NUMBER) with a per-level breakdown and
# ready-to-click bestpractices.dev proposal URLs.
#
# This script never writes anything to bestpractices.dev itself -- that
# platform's badge-criteria-update mechanism is a URL-query-parameter form
# meant to be opened and submitted by a logged-in human (there is no API
# token / headless write endpoint), so the only output this script produces
# is (a) re-verified facts and (b) a proposal URL for a human to click through
# manually. Criteria that need a human-written document that doesn't exist
# yet (a threat-model doc, DCO/CLA policy, a full security-assessment doc,
# SBOM generation) are intentionally NOT covered here: they are not
# "recheck-able" against live state, they are either done or not, and polling
# them would just repeat "still not done" forever.
#
# Requires: gh (authenticated via GH_TOKEN), jq, git, bash. Run from the root
# of a checkout of current_dev (the workflow that calls this script checks
# that branch out first).
#
# Can be dry-run locally: DRY_RUN=true skips the gh comment POST/PATCH and
# instead prints the composed comment body to stdout, so the check logic can
# be exercised without a real GH_TOKEN/issue write.

set -euo pipefail

: "${REPO:?REPO required, e.g. wiki-mod/distcc-ng}"
: "${ISSUE_NUMBER:?ISSUE_NUMBER required (the tracking issue to comment on)}"
PROJECT_ID="${PROJECT_ID:-13760}"
DRY_RUN="${DRY_RUN:-false}"
MARKER="<!-- openssf-baseline-recheck -->"
RUN_URL="${RUN_URL:-}"
TODAY="$(date -u +%Y-%m-%d)"

# URL-encodes a single argument via jq's @uri filter, so justification text
# with spaces/punctuation survives as a valid query-string value. jq is
# preinstalled on GitHub-hosted ubuntu-latest runners.
urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}

# Appends one "status=Met&justification=..." pair to the given proposal-URL
# query-string accumulator (a bash nameref), for one bestpractices.dev
# criterion ID. Only ever called for criteria that verified as currently Met
# -- criteria that regressed or were never met are deliberately excluded from
# the proposal URL (see the REGRESSED handling in main()).
add_met_param() {
  local -n _qs="$1"
  local osps_id="$2" justification="$3"
  local param_key
  param_key="$(echo "${osps_id}" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"
  local enc_just
  enc_just="$(urlencode "${justification}")"
  if [ -n "${_qs}" ]; then
    _qs="${_qs}&"
  fi
  _qs="${_qs}${param_key}_status=Met&${param_key}_justification=${enc_just}"
}

# Builds the full bestpractices.dev edit-form proposal URL for one baseline
# level from an already-assembled query string of Met criteria.
build_proposal_url() {
  local level="$1" qs="$2"
  echo "https://www.bestpractices.dev/en/projects/${PROJECT_ID}/baseline-${level}/edit?${qs}"
}

# --- Level 1 checks -----------------------------------------------------

# OSPS-AC-03.01 / OSPS-AC-03.02: the repo ruleset still enforces a
# pull_request review rule and a deletion-protection rule. Ruleset ID
# 18300729 is this repo's specific current_dev/master protection ruleset,
# recorded during the manual assessment; if the ruleset is ever recreated
# under a different ID this check needs updating alongside it (a renamed/
# recreated ruleset is exactly the kind of drift this recheck exists to
# surface -- if the ID 404s, that itself is reported as NotMet/regressed
# rather than silently skipped).
check_ac03() {
  local types
  if ! types="$(gh api "repos/${REPO}/rulesets/18300729" --jq '[.rules[].type]' 2>/dev/null)"; then
    echo "NotMet"
    return
  fi
  if echo "${types}" | jq -e 'contains(["pull_request"]) and contains(["deletion"])' >/dev/null; then
    echo "Met"
  else
    echo "NotMet"
  fi
}

# OSPS-BR-01.01 / OSPS-BR-01.03: no workflow uses the dangerous
# pull_request_target trigger, and no workflow interpolates untrusted
# PR/issue/comment title or body text directly (this is a conservative,
# over-inclusive grep across the whole file rather than a real YAML/shell
# parse of run: step bodies -- it will flag a file that merely mentions the
# pattern in a comment too, which is the safe direction for a recheck).
check_br01() {
  local hits=0
  if grep -rl "pull_request_target" .github/workflows/*.yml >/dev/null 2>&1; then
    hits=1
  fi
  if grep -rE 'github\.event\.(pull_request|issue|comment)\.(title|body)' \
      .github/workflows/*.yml >/dev/null 2>&1; then
    hits=1
  fi
  if [ "${hits}" -eq 0 ]; then
    echo "Met"
  else
    echo "NotMet"
  fi
}

# OSPS-BR-07.01: secret scanning and its push-protection are both enabled at
# the repo level.
check_br07() {
  local analysis
  analysis="$(gh api "repos/${REPO}" --jq '.security_and_analysis')"
  if echo "${analysis}" | jq -e '
      .secret_scanning.status == "enabled" and
      .secret_scanning_push_protection.status == "enabled"
    ' >/dev/null; then
    echo "Met"
  else
    echo "NotMet"
  fi
}

# OSPS-QA-05.01 / OSPS-QA-05.02: no compiled binary artifact is tracked in
# current_dev's git tree (build outputs must be produced, not committed).
check_qa05() {
  if git ls-tree -r HEAD --name-only \
      | grep -Ei '\.(o|so|a|exe|dll|bin)$' >/dev/null; then
    echo "NotMet"
  else
    echo "Met"
  fi
}

# OSPS-VM-02.01: SECURITY.md still exists at the repo root.
check_vm02() {
  if [ -f SECURITY.md ]; then
    echo "Met"
  else
    echo "NotMet"
  fi
}

# --- Level 2 checks -----------------------------------------------------

# Shared by OSPS-AC-04.01 (level 2) and OSPS-AC-04.02 (level 3): spot-checks
# that every workflow declares an explicit top-level `permissions:` block
# (the block before the first `jobs:` key, i.e. the workflow-wide default)
# and that block never grants the broadest legacy scopes (`write-all`, or
# `contents: write` at the workflow-wide default). This deliberately does
# NOT reject every non-"read" scope at the top level -- a workflow that
# needs to post PR review comments legitimately declares a scoped
# `pull-requests: write` default (see actionlint.yml), and that is the
# recommended least-privilege pattern, not a violation of it. Job-level
# permissions blocks further down the same file may narrow or widen a
# specific job's scope and are not part of this check.
check_ac04() {
  local f block
  for f in .github/workflows/*.yml; do
    block="$(awk '/^permissions:/{flag=1} /^jobs:/{flag=0} flag' "${f}")"
    if [ -z "${block}" ]; then
      # No top-level permissions: block at all means this workflow inherits
      # the (broader) legacy default token scope -- not least-privilege.
      echo "NotMet"
      return
    fi
    if echo "${block}" | grep -qE 'permissions:\s*write-all|^\s*contents:\s*write'; then
      echo "NotMet"
      return
    fi
  done
  echo "Met"
}

# OSPS-BR-06.01: package-release.yml still generates a build-provenance
# attestation (checked as a static file grep, not by cutting a real release).
check_br06() {
  if grep -q "actions/attest-build-provenance" .github/workflows/package-release.yml 2>/dev/null; then
    echo "Met"
  else
    echo "NotMet"
  fi
}

# OSPS-BR-05.01 / OSPS-DO-06.01: dependabot.yml still exists, and
# compatibility-policy.md still documents the dependency-management policy.
check_br05_do06() {
  if [ -f .github/dependabot.yml ] \
      && grep -q "## Dependency management policy" doc/compatibility-policy.md 2>/dev/null; then
    echo "Met"
  else
    echo "NotMet"
  fi
}

# OSPS-GV-01.01 / OSPS-GV-01.02: AGENTS.md still documents actual project
# membership/roles.
check_gv01() {
  if grep -q "## Project Roles" AGENTS.md 2>/dev/null; then
    echo "Met"
  else
    echo "NotMet"
  fi
}

# OSPS-VM-01.01 / OSPS-VM-03.01: SECURITY.md still documents GitHub Security
# Advisories as the reporting channel.
check_vm01_vm03() {
  if grep -qi "Security Advisor" SECURITY.md 2>/dev/null; then
    echo "Met"
  else
    echo "NotMet"
  fi
}

# --- Level 3 checks -----------------------------------------------------

# OSPS-DO-04.01 / OSPS-DO-05.01: SECURITY.md still documents a Supported
# Versions table.
check_do04_do05() {
  if grep -q "## Supported Versions" SECURITY.md 2>/dev/null; then
    echo "Met"
  else
    echo "NotMet"
  fi
}

# --- Comment marker / previous-state handling ---------------------------

# Finds the existing marker comment (if any) on the tracking issue, printing
# its comment ID (for a PATCH) or nothing (a POST is needed instead).
find_existing_comment_id() {
  gh api "repos/${REPO}/issues/${ISSUE_NUMBER}/comments" --paginate \
    --jq "[.[] | select(.body | startswith(\"${MARKER}\"))] | sort_by(.id) | last | .id // empty"
}

# Extracts the previously-recorded per-criterion status JSON blob embedded in
# an existing marker comment's body, so this run can detect regressions
# (a criterion that was Met last run and is NotMet now). Prints "{}" (no
# prior state) if the comment doesn't exist or has no parseable state line.
extract_previous_state() {
  local comment_id="$1"
  [ -z "${comment_id}" ] && { echo "{}"; return; }
  local body state_line
  body="$(gh api "repos/${REPO}/issues/comments/${comment_id}" --jq '.body')"
  state_line="$(echo "${body}" | grep -o '<!-- openssf-baseline-recheck-state: .*-->' || true)"
  if [ -z "${state_line}" ]; then
    echo "{}"
    return
  fi
  echo "${state_line}" | sed -e 's/^<!-- openssf-baseline-recheck-state: //' -e 's/ -->$//'
}

main() {
  echo "Re-checking OpenSSF Best Practices Baseline criteria for ${REPO}, project ${PROJECT_ID}..."

  # --- run every check --------------------------------------------------
  local ac03 br01 br07 qa05 vm02
  ac03="$(check_ac03)"
  br01="$(check_br01)"
  br07="$(check_br07)"
  qa05="$(check_qa05)"
  vm02="$(check_vm02)"

  local ac04 br06 br05_do06 gv01 vm01_vm03
  ac04="$(check_ac04)"
  br06="$(check_br06)"
  br05_do06="$(check_br05_do06)"
  gv01="$(check_gv01)"
  vm01_vm03="$(check_vm01_vm03)"

  local do04_do05
  do04_do05="$(check_do04_do05)"
  # OSPS-QA-04.02 is static N/A -- single-repo project, no live check exists
  # for it; it is reported as such and never included in a proposal URL.

  # --- new-state JSON, for next run's regression comparison --------------
  local new_state
  new_state="$(jq -nc \
    --arg ac03 "${ac03}" --arg br01 "${br01}" --arg br07 "${br07}" \
    --arg qa05 "${qa05}" --arg vm02 "${vm02}" --arg ac04 "${ac04}" \
    --arg br06 "${br06}" --arg br05_do06 "${br05_do06}" --arg gv01 "${gv01}" \
    --arg vm01_vm03 "${vm01_vm03}" --arg do04_do05 "${do04_do05}" \
    '{"AC-03":$ac03,"BR-01":$br01,"BR-07":$br07,"QA-05":$qa05,"VM-02":$vm02,
      "AC-04":$ac04,"BR-06":$br06,"BR-05_DO-06":$br05_do06,"GV-01":$gv01,
      "VM-01_VM-03":$vm01_vm03,"DO-04_DO-05":$do04_do05}')"

  local existing_id prev_state
  existing_id="$(find_existing_comment_id)"
  prev_state="$(extract_previous_state "${existing_id}")"

  # Reports REGRESSED for any key that was Met last run and is NotMet now.
  # A key with no prior recorded state (first run, or a criterion added
  # later) is never reported as regressed -- there is nothing to regress
  # from yet, it is simply "not yet met".
  regressed_keys="$(jq -rn --argjson prev "${prev_state}" --argjson new "${new_state}" '
    $new | to_entries[] | select(.value == "NotMet" and ($prev[.key] // "") == "Met") | .key
  ')"

  # --- Level 1 proposal URL / summary -----------------------------------
  local qs1="" l1_lines=""
  [ "${ac03}" = "Met" ] && add_met_param qs1 "OSPS-AC-03.01" "Ruleset 18300729 on ${REPO} contains both a pull_request rule and a deletion rule, re-verified via the GitHub API on ${TODAY}."
  [ "${ac03}" = "Met" ] && add_met_param qs1 "OSPS-AC-03.02" "Same ruleset re-verified on ${TODAY}; deletion rule present."
  [ "${br01}" = "Met" ] && add_met_param qs1 "OSPS-BR-01.01" "No workflow under .github/workflows uses pull_request_target, re-verified by grep on ${TODAY}."
  [ "${br01}" = "Met" ] && add_met_param qs1 "OSPS-BR-01.03" "No workflow interpolates untrusted PR/issue/comment title or body text directly, re-verified by grep on ${TODAY}."
  [ "${br07}" = "Met" ] && add_met_param qs1 "OSPS-BR-07.01" "GitHub secret scanning and secret scanning push protection are both enabled on ${REPO}, re-verified via the API on ${TODAY}."
  [ "${qa05}" = "Met" ] && add_met_param qs1 "OSPS-QA-05.01" "No compiled binary (.o/.so/.a/.exe/.dll/.bin) is tracked in current_dev's git tree, re-verified on ${TODAY}."
  [ "${qa05}" = "Met" ] && add_met_param qs1 "OSPS-QA-05.02" "Same check, re-verified on ${TODAY}."
  [ "${vm02}" = "Met" ] && add_met_param qs1 "OSPS-VM-02.01" "SECURITY.md still exists at the repo root, re-verified on ${TODAY}."
  l1_lines="- AC-03.01/03.02 (ruleset PR+deletion rules): ${ac03}
- BR-01.01/01.03 (no pull_request_target / no unsanitized event interpolation): ${br01}
- BR-07.01 (secret scanning + push protection enabled): ${br07}
- QA-05.01/05.02 (no tracked binary artifacts): ${qa05}
- VM-02.01 (SECURITY.md present): ${vm02}"

  # --- Level 2 proposal URL / summary -----------------------------------
  local qs2="" l2_lines=""
  [ "${ac04}" = "Met" ] && add_met_param qs2 "OSPS-AC-04.01" "Every .github/workflows/*.yml top-level permissions: block is contents:read or narrower, re-verified on ${TODAY}."
  [ "${br06}" = "Met" ] && add_met_param qs2 "OSPS-BR-06.01" "package-release.yml still contains an actions/attest-build-provenance step, re-verified by grep on ${TODAY}."
  [ "${br05_do06}" = "Met" ] && add_met_param qs2 "OSPS-BR-05.01" ".github/dependabot.yml still exists, re-verified on ${TODAY}."
  [ "${br05_do06}" = "Met" ] && add_met_param qs2 "OSPS-DO-06.01" "doc/compatibility-policy.md still documents the dependency-management policy, re-verified on ${TODAY}."
  [ "${gv01}" = "Met" ] && add_met_param qs2 "OSPS-GV-01.01" "AGENTS.md still documents project roles/membership, re-verified on ${TODAY}."
  [ "${gv01}" = "Met" ] && add_met_param qs2 "OSPS-GV-01.02" "Same section, re-verified on ${TODAY}."
  [ "${vm01_vm03}" = "Met" ] && add_met_param qs2 "OSPS-VM-01.01" "SECURITY.md still documents GitHub Security Advisories as the reporting channel, re-verified on ${TODAY}."
  [ "${vm01_vm03}" = "Met" ] && add_met_param qs2 "OSPS-VM-03.01" "Same document, re-verified on ${TODAY}."
  l2_lines="- AC-04.01 (workflow permissions spot-check): ${ac04}
- BR-06.01 (build provenance attestation step present): ${br06}
- BR-05.01/DO-06.01 (dependabot.yml + dependency policy doc): ${br05_do06}
- GV-01.01/01.02 (AGENTS.md Project Roles section): ${gv01}
- VM-01.01/03.01 (SECURITY.md documents GH Security Advisories): ${vm01_vm03}"

  # --- Level 3 proposal URL / summary -----------------------------------
  local qs3="" l3_lines=""
  [ "${ac04}" = "Met" ] && add_met_param qs3 "OSPS-AC-04.02" "Same workflow-permissions spot-check as level 2's AC-04.01, re-verified on ${TODAY}."
  [ "${br01}" = "Met" ] && add_met_param qs3 "OSPS-BR-01.04" "Same untrusted-input-sanitization grep as level 1's BR-01.01, re-verified on ${TODAY}."
  [ "${do04_do05}" = "Met" ] && add_met_param qs3 "OSPS-DO-04.01" "SECURITY.md still documents a Supported Versions table, re-verified on ${TODAY}."
  [ "${do04_do05}" = "Met" ] && add_met_param qs3 "OSPS-DO-05.01" "Same table, re-verified on ${TODAY}."
  l3_lines="- AC-04.02 (workflow permissions spot-check, stricter framing): ${ac04}
- BR-01.04 (untrusted-input sanitization, stricter framing): ${br01}
- DO-04.01/05.01 (SECURITY.md Supported Versions table): ${do04_do05}
- QA-04.02 (single-repo N/A): static N/A, no live check applicable"

  local url1 url2 url3
  url1="$(build_proposal_url 1 "${qs1}")"
  url2="$(build_proposal_url 2 "${qs2}")"
  url3="$(build_proposal_url 3 "${qs3}")"

  # --- Regression callout -------------------------------------------------
  local regressed_block=""
  if [ -n "${regressed_keys}" ]; then
    regressed_block="## REGRESSED -- was Met on the previous recheck, now NotMet

$(echo "${regressed_keys}" | sed 's/^/- /')

These were intentionally excluded from the proposal links above/below; investigate before re-proposing them as Met."
  fi

  # --- compose the full comment body -------------------------------------
  local body
  body="$(cat <<EOF
${MARKER}
# OpenSSF Best Practices Baseline recheck -- ${TODAY}

Automated re-verification of the mechanically-checkable criteria for [project ${PROJECT_ID}](https://www.bestpractices.dev/projects/${PROJECT_ID}). This does not submit anything to bestpractices.dev -- a logged-in human must open a proposal link below and submit the form there.

${regressed_block}

## Level 1
${l1_lines}

Proposal link (Level 1, currently-Met criteria only): ${url1}

## Level 2
${l2_lines}

Proposal link (Level 2, currently-Met criteria only): ${url2}

## Level 3
${l3_lines}

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
    echo "Updating existing marker comment ${existing_id} on issue #${ISSUE_NUMBER}"
    gh api --method PATCH "repos/${REPO}/issues/comments/${existing_id}" \
      -f body="${body}" >/dev/null
  else
    echo "Posting new marker comment on issue #${ISSUE_NUMBER}"
    gh api --method POST "repos/${REPO}/issues/${ISSUE_NUMBER}/comments" \
      -f body="${body}" >/dev/null
  fi
}

main "$@"
