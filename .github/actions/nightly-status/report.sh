#!/usr/bin/env bash
#
# Files, updates, or closes a single standing "nightly-broken" tracking issue
# based on the outcome of a scheduled run (the nightly publish or the weekly
# heartbeat). It reuses ONE issue per the nightly-broken label -- commenting on
# the existing one across consecutive failures instead of opening a new issue
# every night -- and closes it automatically on the next success.
#
# Both scheduled workflows feed this same standing issue by design (see #81).
# That means a success in one can close an issue the other filed; this
# self-corrects, because the next genuine failure re-files/re-opens the issue.
# Per-workflow issues were deliberately not used, to match the single-label
# design.

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN required}"
: "${REPO:?REPO required}"
: "${OUTCOME:?OUTCOME required (success|failure)}"
: "${SCOPE:?SCOPE required, e.g. 'nightly build+publish (current_dev)'}"
: "${RUN_URL:?RUN_URL required}"
LABEL="${LABEL:-nightly-broken}"
DRY_RUN="${DRY_RUN:-false}"

# Echo mutating actions instead of performing them when DRY_RUN=true, so the
# branch logic can be exercised locally without touching real issues/labels.
run() {
  if [ "${DRY_RUN}" = "true" ]; then
    printf 'DRY_RUN would run:'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

# Assign the "Bug" issue type to $1 if it doesn't already have one. Issue
# types require a separate GraphQL mutation (Issue.issueTypeId via
# updateIssue) -- there is no create-time flag for this. Called on every
# failure path (both a freshly created issue and an existing one being
# commented on), not just at create time: repository governance requires
# every issue to have a type, and a one-shot best-effort attempt at
# creation time could otherwise leave a standing issue permanently untyped
# if that one attempt failed (e.g. no "Bug" type configured yet, or a
# transient API error) -- retrying here on every subsequent failure
# self-heals that instead of giving up for good. Not skipped in DRY_RUN for
# the read-only lookups (safe), only the actual mutation is gated.
ensure_bug_type() {
  local issue_number="$1" owner name issue_query_result issue_node_id current_type bug_type_id
  owner="${REPO%%/*}"
  name="${REPO##*/}"
  # The single quotes below are deliberate -- the string contains GraphQL's
  # own "$owner"/"$name"/"$number" variable syntax (unrelated to shell),
  # bound via -F below, same pattern already used in
  # scripts/check-pr-tracking-metadata.sh.
  # Captured as its own assignment (not fed directly into `read <<<...`) so
  # a failed gh api call actually trips `set -e` here -- a command
  # substitution's exit status is lost when it's used as a here-string's
  # source, which would otherwise let `read` "succeed" against an empty
  # string and this function wrongly report success.
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

# Oldest open standing issue for this label, if any. --jq yields the number or
# nothing; no `grep -q` pipe here, to avoid the SIGPIPE-under-pipefail trap.
existing="$(gh issue list --repo "${REPO}" --label "${LABEL}" --state open \
  --json number --jq 'sort_by(.number) | .[0].number // empty')"

if [ "${OUTCOME}" = "success" ]; then
  if [ -n "${existing}" ]; then
    # Ensure the type is set before closing -- otherwise an issue that was
    # created untyped (e.g. the creation-time mutation failed transiently)
    # and then never fails again gets closed while still permanently
    # untyped, with no further failure to retry the assignment on. `set -e`
    # means a failure here aborts before the close below runs.
    ensure_bug_type "${existing}"
    echo "success: closing standing ${LABEL} issue #${existing}"
    run gh issue comment "${existing}" --repo "${REPO}" \
      --body "Recovered: ${SCOPE} succeeded in ${RUN_URL}. Closing this standing tracking issue automatically; it will re-open if a later scheduled run fails."
    run gh issue close "${existing}" --repo "${REPO}"
  else
    echo "success and no open ${LABEL} issue: nothing to do"
  fi
  exit 0
fi

# OUTCOME is a failure. Ensure the label exists (idempotent: gh errors if it
# already exists, which is fine -- the label is optional tracking infra), then
# reuse the standing issue or open one.
run gh label create "${LABEL}" --repo "${REPO}" --color b60205 \
  --description "A scheduled nightly/heartbeat CI run is failing" 2>/dev/null || true

detail="${SCOPE} failed in ${RUN_URL}"
if [ -n "${existing}" ]; then
  echo "failure: commenting on standing ${LABEL} issue #${existing}"
  run gh issue comment "${existing}" --repo "${REPO}" \
    --body "Still failing: ${detail}."
  ensure_bug_type "${existing}"
else
  echo "failure: opening a new standing ${LABEL} issue"
  new_issue_url="$(run gh issue create --repo "${REPO}" --label "${LABEL}" \
    --title "[${LABEL}] a scheduled CI run is failing" \
    --body "A scheduled CI run failed. This standing issue is reused across consecutive failures (the nightly publish and the weekly heartbeat both feed it) and closed automatically on the next successful run.

${detail}.")"
  if [ "${DRY_RUN}" != "true" ]; then
    ensure_bug_type "${new_issue_url##*/}"
  fi
fi
