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

# Oldest open standing issue for this label, if any. --jq yields the number or
# nothing; no `grep -q` pipe here, to avoid the SIGPIPE-under-pipefail trap.
existing="$(gh issue list --repo "${REPO}" --label "${LABEL}" --state open \
  --json number --jq 'sort_by(.number) | .[0].number // empty')"

if [ "${OUTCOME}" = "success" ]; then
  if [ -n "${existing}" ]; then
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
else
  echo "failure: opening a new standing ${LABEL} issue"
  run gh issue create --repo "${REPO}" --label "${LABEL}" \
    --title "[${LABEL}] a scheduled CI run is failing" \
    --body "A scheduled CI run failed. This standing issue is reused across consecutive failures (the nightly publish and the weekly heartbeat both feed it) and closed automatically on the next successful run.

${detail}."
fi
