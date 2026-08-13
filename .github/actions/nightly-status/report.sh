#!/usr/bin/env bash
#
# What: Files, updates, or closes one standing "nightly-broken" issue for a
# scheduled run's outcome, reused across consecutive failures and closed on
# the next success.
# Why: Every scheduled workflow (see doc/ci-workflows.md's "Callers" list)
# shares this one issue by design, so a success in one caller can close what
# another filed; the next real failure re-files it.
# From: Issue #81

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN required}"
: "${REPO:?REPO required}"
: "${OUTCOME:?OUTCOME required (success|failure)}"
: "${SCOPE:?SCOPE required, e.g. 'nightly build+publish (current_dev)'}"
: "${RUN_URL:?RUN_URL required}"
LABEL="${LABEL:-nightly-broken}"
DRY_RUN="${DRY_RUN:-false}"
FAILED_JOBS="${FAILED_JOBS:-}"
PROJECT_PAT="${PROJECT_PAT:-}"
PROJECT_OWNER="${PROJECT_OWNER:-wiki-mod}"
PROJECT_NUMBER="${PROJECT_NUMBER:-11}"

# What: Adds the standing issue to the project board via a separate
# PROJECT_PAT-authenticated call, on every touch (create, comment, close),
# skipping silently when PROJECT_PAT is unset (AGENTS.md rule 3).
# Why: GH_TOKEN cannot write Projects v2 data and PROJECT_AUTOMATION_PAT's
# project-only scope cannot mutate issues, so the two calls need separate
# tokens; retrying on every touch self-heals a transient board-add failure,
# since addProjectV2ItemById is idempotent.
# From: PR #476
add_to_project_board() {
  local issue_url="$1"
  if [ -z "${PROJECT_PAT}" ]; then
    return 0
  fi
  if [ "${DRY_RUN}" = "true" ]; then
    echo "DRY_RUN would run: GH_TOKEN=*** gh project item-add ${PROJECT_NUMBER} --owner ${PROJECT_OWNER} --url ${issue_url}"
    return 0
  fi
  GH_TOKEN="${PROJECT_PAT}" gh project item-add "${PROJECT_NUMBER}" \
    --owner "${PROJECT_OWNER}" --url "${issue_url}" >/dev/null
}

# What: Echoes a mutating command instead of running it when DRY_RUN=true.
# Why: Lets the branch logic be exercised locally without touching real
# issues/labels.
run() {
  if [ "${DRY_RUN}" = "true" ]; then
    printf 'DRY_RUN would run:'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

# What: Assigns the "Bug" issue type to $1 via a GraphQL updateIssue
# mutation if it doesn't already have one; called on every failure path,
# not just at creation, and only the actual mutation is gated by DRY_RUN.
# Why: A one-shot best-effort attempt at creation time could otherwise
# leave an issue permanently untyped if that one attempt failed; retrying
# on every subsequent failure self-heals it instead of giving up for good.
# From: PR #476
ensure_bug_type() {
  local issue_number="$1" owner name issue_query_result issue_node_id current_type bug_type_id
  owner="${REPO%%/*}"
  name="${REPO##*/}"
  # What: Single-quoted because the string holds GraphQL's own $owner/$name/
  # $number syntax bound via -F, not shell variables; captured as its own
  # assignment rather than fed straight into `read <<<...`.
  # Why: A command substitution's exit status is lost when used directly as
  # a here-string source, which would let `read` silently "succeed" on an
  # empty string if `gh api` failed; capturing it separately lets `set -e`
  # catch that failure.
  # From: PR #476
  # shellcheck disable=SC2016
  issue_query_result="$(gh api graphql -f query='
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        issue(number: $number) { id issueType { name } }
      }
    }' -F owner="${owner}" -F name="${name}" -F number="${issue_number}" \
    --jq '.data.repository.issue | .id + " " + (.issueType.name // "-")')"
  read -r issue_node_id current_type <<<"${issue_query_result}"
  if [ "${current_type}" != "-" ]; then
    return 0
  fi
  # shellcheck disable=SC2016
  bug_type_id="$(gh api graphql -f query='
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        issueTypes(first: 20) { nodes { id name } }
      }
    }' -F owner="${owner}" -F name="${name}" \
    --jq '.data.repository.issueTypes.nodes[] | select(.name == "Bug") | .id')"
  if [ -z "${bug_type_id}" ]; then
    echo "::error::No 'Bug' issue type configured for ${REPO}; cannot type issue #${issue_number} as repository governance requires."
    return 1
  fi
  if [ "${DRY_RUN}" = "true" ]; then
    echo "DRY_RUN would run: assign Bug type to issue #${issue_number}"
    return 0
  fi
  # shellcheck disable=SC2016
  gh api graphql -f query='
    mutation($issueId: ID!, $typeId: ID!) {
      updateIssue(input: {id: $issueId, issueTypeId: $typeId}) {
        issue { id }
      }
    }' -F issueId="${issue_node_id}" -F typeId="${bug_type_id}" >/dev/null
}

# What: Finds the oldest open standing issue for this label, if any.
# Why: --jq yields the number or nothing directly, avoiding a `grep -q`
# pipe that would trip the SIGPIPE-under-pipefail trap.
existing="$(gh issue list --repo "${REPO}" --label "${LABEL}" --state open \
  --json number --jq 'sort_by(.number) | .[0].number // empty')"

if [ "${OUTCOME}" = "success" ]; then
  if [ -n "${existing}" ]; then
    # What: Ensures the type is set and the issue is on the project board
    # before closing it.
    # Why: Otherwise an issue where either mutation failed transiently (or
    # predates this action having them) gets closed with no further
    # failure to retry on; `set -e` aborts before the close if this fails.
    # From: PR #476
    ensure_bug_type "${existing}"
    add_to_project_board "https://github.com/${REPO}/issues/${existing}"
    echo "success: closing standing ${LABEL} issue #${existing}"
    run gh issue comment "${existing}" --repo "${REPO}" \
      --body "Recovered: ${SCOPE} succeeded in ${RUN_URL}. Closing this standing tracking issue automatically; it will re-open if a later scheduled run fails."
    run gh issue close "${existing}" --repo "${REPO}"
  else
    echo "success and no open ${LABEL} issue: nothing to do"
  fi
  exit 0
fi

# What: OUTCOME is a failure. Ensures the label exists, then reuses the
# standing issue or opens one.
# Why: `gh label create` erroring because the label already exists is
# harmless and expected, since the label is optional tracking infra.
run gh label create "${LABEL}" --repo "${REPO}" --color b60205 \
  --description "A scheduled nightly/heartbeat CI run is failing" 2>/dev/null || true

# What: Records which specific job(s) failed, not just "the pipeline
# failed".
# Why: Otherwise the standing issue has no independently actionable
# evidence once the linked run log expires or becomes inaccessible.
# From: PR #476
detail="${SCOPE} failed in ${RUN_URL}"
if [ -n "${FAILED_JOBS}" ]; then
  detail="${detail} (failed: ${FAILED_JOBS})"
fi
if [ -n "${existing}" ]; then
  echo "failure: commenting on standing ${LABEL} issue #${existing}"
  run gh issue comment "${existing}" --repo "${REPO}" \
    --body "Still failing: ${detail}."
  ensure_bug_type "${existing}"
  add_to_project_board "https://github.com/${REPO}/issues/${existing}"
else
  echo "failure: opening a new standing ${LABEL} issue"
  new_issue_url="$(run gh issue create --repo "${REPO}" --label "${LABEL}" \
    --title "[${LABEL}] a scheduled CI run is failing" \
    --body "A scheduled CI run failed. This standing issue is reused across consecutive failures (every scheduled workflow that feeds it can comment on or close it, not just the one that filed it) and closed automatically on the next successful run.

${detail}.")"
  # What: Re-emits `run()`'s echoed command in DRY_RUN.
  # Why: The command substitution above captures that echoed text instead
  # of printing it, so without this, dry-run would silently look like it
  # did nothing for this mutation.
  # From: PR #476
  if [ "${DRY_RUN}" = "true" ]; then
    echo "${new_issue_url}"
  fi
  if [ "${DRY_RUN}" != "true" ]; then
    ensure_bug_type "${new_issue_url##*/}"
    # What: Explicitly adds the new issue to the project board instead of
    # relying on add-to-project.yml's issues:opened handler; skipped in
    # DRY_RUN, matching ensure_bug_type above.
    # Why: GitHub suppresses downstream workflow events for content created
    # by the default GITHUB_TOKEN (the same anti-recursion behavior already
    # seen for release publishing), so that handler never fires here; in
    # DRY_RUN, new_issue_url also holds run()'s echoed command text rather
    # than a real URL, which would otherwise pass through as a garbled
    # --url value.
    # From: PR #476
    add_to_project_board "${new_issue_url}"
  fi
fi
