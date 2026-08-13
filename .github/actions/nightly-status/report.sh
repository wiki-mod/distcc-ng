#!/usr/bin/env bash
#
# Files, updates, or closes a single standing "nightly-broken" tracking issue
# based on the outcome of a scheduled run. It reuses ONE issue per the
# nightly-broken label -- commenting on the existing one across consecutive
# failures instead of opening a new issue every night -- and closes it
# automatically on the next success.
#
# Every scheduled workflow that calls this action feeds this same standing
# issue by design (issue #81; currently: c-build.yml, e2e-image-build.yml,
# master-heartbeat.yml, nightly-publish.yml -- see doc/ci-workflows.md's
# "Callers" list for the current, authoritative set). That means a success
# in one can close an issue a different one filed; this self-corrects,
# because the next genuine failure re-files/re-opens the issue. Per-workflow
# issues were deliberately not used, to match the single-label design.

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

# Adds the standing issue to the distcc-ng project board (AGENTS.md rule
# 3), using PROJECT_PAT specifically -- GH_TOKEN (the default
# GITHUB_TOKEN) cannot write org-owned Projects v2 data, and
# PROJECT_AUTOMATION_PAT's own documented scope (`project` only, see
# add-to-project.yml) cannot create/comment/close issues, so this is
# deliberately a separate call with a separate token, not a GH_TOKEN
# override. Called on every touch (creation, still-failing comment,
# recovery close), not just at creation -- addProjectV2ItemById (what
# `gh project item-add` calls) is idempotent, so retrying here self-heals
# a transient failure or an issue that predates this mechanism, same
# self-healing shape as ensure_bug_type() above. Matches
# add-to-project.yml's own graceful-skip-when-unconfigured behavior:
# silently does nothing when PROJECT_PAT is empty, rather than failing
# the whole run over an optional board placement.
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

# Echo mutating actions instead of performing them when DRY_RUN=true, so the
# branch logic can be exercised locally without touching real issues/labels.
run() {
  if [ "${DRY_RUN}" = "true" ]; then
    printf 'DRY_RUN would run:'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

# Assign the "Bug" issue type to $1 if it doesn't already have one, via a
# GraphQL mutation (Issue.issueTypeId via updateIssue). A create-time flag
# for this exists in newer gh versions, but is not sufficient on its own:
# this is called on every failure path (both a freshly created issue and
# an existing one being commented on), not just at create time, because
# repository governance requires every issue to have a type, and a
# one-shot best-effort attempt at creation time could otherwise leave a
# standing issue permanently untyped if that one attempt failed (e.g. no
# "Bug" type configured yet, or a transient API error) -- retrying here on
# every subsequent failure self-heals that instead of giving up for good.
# Not skipped in DRY_RUN for the read-only lookups (safe), only the actual
# mutation is gated.
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
    # Ensure the type is set, and the issue is on the project board, before
    # closing -- otherwise an issue where either mutation failed
    # transiently at creation time (or predates this action having them at
    # all) gets closed while still permanently untyped/unassigned, with no
    # further failure to retry on. `set -e` means a failure here aborts
    # before the close below runs. addProjectV2ItemById (what `gh project
    # item-add` calls) is idempotent -- re-adding an already-assigned issue
    # is a safe no-op, not an error, so this is always safe to call.
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

# OUTCOME is a failure. Ensure the label exists (idempotent: gh errors if it
# already exists, which is fine -- the label is optional tracking infra), then
# reuse the standing issue or open one.
run gh label create "${LABEL}" --repo "${REPO}" --color b60205 \
  --description "A scheduled nightly/heartbeat CI run is failing" 2>/dev/null || true

# Records which specific job(s) failed, not just "the pipeline failed" --
# otherwise the standing issue has no independently actionable evidence
# once the linked run log expires or the run is inaccessible.
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
  # In DRY_RUN, `run()`'s own echoed command is what got captured above
  # (there's no real gh call to print it) -- re-emit it here, otherwise
  # the command substitution silently swallows it and dry-run mode looks
  # like it did nothing for this specific mutation.
  if [ "${DRY_RUN}" = "true" ]; then
    echo "${new_issue_url}"
  fi
  if [ "${DRY_RUN}" != "true" ]; then
    ensure_bug_type "${new_issue_url##*/}"
    # gh issue create's own token (GH_TOKEN, the default GITHUB_TOKEN)
    # never triggers add-to-project.yml's issues:opened handler -- GitHub
    # suppresses downstream workflow events for anything created by the
    # default token, the same anti-recursion behavior already found for
    # release publishing. Add it explicitly instead of relying on that
    # event. Skipped in DRY_RUN along with ensure_bug_type above --
    # new_issue_url only holds a real URL when gh issue create actually
    # ran; in DRY_RUN it holds run()'s own echoed command text instead,
    # which would otherwise get passed straight through as a garbled
    # --url value.
    add_to_project_board "${new_issue_url}"
  fi
fi
