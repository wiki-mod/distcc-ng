#!/usr/bin/env bash
# Enforces AGENTS.md rule 3: a pull request must carry at least one label
# and a milestone, and (when a project-read token is configured) must be
# on the repository's Project board, before it counts as properly filed.
# See AGENTS.md's "Issue And PR Tracking" section for the rule text --
# adapted from wiki-mod/lancache-ng's own scripts/check-pr-tracking-metadata.sh
# (their AG-GH-008), itself the mechanism this repo lacked: CHANGELOG.md
# went unmaintained for ~10 merged PRs before anyone noticed (issue #50),
# and this is the CI-enforced fix at the actual root (missing metadata),
# rather than changelog-check.yml's narrower "did the file get touched"
# symptom-level check.
#
# For draft PRs: prints warnings but exits 0 (non-blocking) -- metadata is
# expected to settle before a PR leaves draft, not before the first push.
#
# Usage (CI):
#   PR_LABELS_JSON, PR_MILESTONE_TITLE, PR_DRAFT, PR_NUMBER, REPO set by
#   the workflow from a live `gh pr view` fetch (see the workflow job --
#   github.event.pull_request.labels/.milestone is a webhook-time snapshot
#   that can go stale if metadata changes after the triggering event).
#   PROJECT_NUMBER, PROJECT_OWNER identify the project board to check
#   (distcc-ng's board: https://github.com/orgs/wiki-mod/projects/11).
#   GH_TOKEN, if set to a token with read:project scope, enables the
#   project-board check via a raw GraphQL call against api.github.com. The
#   default Actions GITHUB_TOKEN cannot read Projects v2 data for an
#   org-owned board, so without a configured PROJECT_AUTOMATION_PAT this
#   check is skipped with a warning, not failed. Once a token IS supplied,
#   a rejected/invalid/insufficient-scope token (HTTP 401/403, or a
#   GraphQL response body with a top-level "errors" array) fails the check
#   instead of warning -- that's a configuration problem with the secret
#   itself, not the documented no-token gap. Only a genuine infrastructure
#   hiccup (other non-200 statuses, an unparseable-but-non-error response)
#   still degrades to a warning.
#   PR_IS_FORK (true/false), set by the workflow by comparing head/base
#   repo, distinguishes "no token configured" from "token withheld because
#   this run is from a forked repository" when GH_TOKEN is empty -- GitHub
#   does not pass repository secrets to pull_request runs from forks
#   regardless of whether PROJECT_AUTOMATION_PAT is set.
#   PR_AUTHOR, set from github.event.pull_request.user.login: a literal
#   "dependabot[bot]" short-circuits this check entirely (see the exemption
#   below for why).
#
# Runs directly on the GitHub-hosted ubuntu-latest runner in CI (python3
# and curl are part of that image's standard toolset) -- see the
# pr_tracking_metadata job in .github/workflows/changelog-check.yml.
# Unlike lancache-ng's self-hosted-runner original, this repo's CI runs
# exclusively on GitHub-hosted runners, so there's no stale/absent
# host-tool risk that would justify running this inside a container.
set -euo pipefail

# Dependabot cannot set a milestone or add itself to the project board on
# its own PRs -- exempt it here so the required-status-check gate sees an
# explicit pass, not an ambiguous skip.
if [ "${PR_AUTHOR:-}" = "dependabot[bot]" ]; then
    echo "PR tracking metadata check skipped: PR authored by dependabot[bot], which cannot set its own milestone or project-board placement."
    exit 0
fi

pr_draft="${PR_DRAFT:-false}"
pr_number="${PR_NUMBER:?PR_NUMBER is required}"
repo="${REPO:?REPO is required (owner/name)}"
project_number="${PROJECT_NUMBER:-11}"
project_owner="${PROJECT_OWNER:-wiki-mod}"

errors=()
warnings=()

# --- Labels ---------------------------------------------------------------
label_count=$(printf '%s' "${PR_LABELS_JSON:-[]}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
if [ "$label_count" -eq 0 ]; then
    errors+=("No labels set. Add at least one component/type label (see AGENTS.md rule 3).")
fi

# --- Milestone --------------------------------------------------------------
if [ -z "${PR_MILESTONE_TITLE:-}" ]; then
    errors+=("No milestone set. Set a milestone (see AGENTS.md rule 3).")
fi

# --- Project board ----------------------------------------------------------
# Projects v2 read access needs a token with read:project scope; the default
# GITHUB_TOKEN issued to a workflow run cannot query it. Degrade gracefully
# rather than failing every PR check on an org-level permission gap that has
# nothing to do with the PR itself.
if [ -z "${GH_TOKEN:-}" ]; then
    if [ "${PR_IS_FORK:-false}" = "true" ]; then
        warnings+=("Project-board membership not checked: PROJECT_AUTOMATION_PAT (even if configured) is not passed to pull_request runs from forked repositories -- this is a GitHub Actions security restriction, not a missing secret. Labels and milestone are still fully enforced. A maintainer must add this PR to the project board manually: gh project item-add $project_number --owner $project_owner --url <pr-url>. See AGENTS.md rule 3.")
    else
        warnings+=("Project-board membership not checked: no read:project-scoped token configured (GH_TOKEN unset). See AGENTS.md rule 3.")
    fi
else
    repo_name="${repo#*/}"
    query=$(python3 -c '
import json
q = """
query($owner: String!, $pr: Int!, $repo: String!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      projectItems(first: 10) {
        nodes { project { number } }
      }
    }
  }
}
"""
print(json.dumps({"query": q, "variables": {"owner": "'"$project_owner"'", "pr": '"$pr_number"', "repo": "'"$repo_name"'"}}))
')
    response_file="$(mktemp)"
    status=$(curl -sS -o "$response_file" -w '%{http_code}' \
        -H "Authorization: Bearer ${GH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        -d "$query" \
        "https://api.github.com/graphql") || status="000"
    if [ "$status" = "401" ] || [ "$status" = "403" ]; then
        errors+=("Project-board lookup rejected (HTTP $status): the configured token (PROJECT_AUTOMATION_PAT) was rejected or lacks the required read:project scope. A token was supplied, so this is a configuration problem -- fix or rotate the secret.")
    elif [ "$status" != "200" ]; then
        warnings+=("Could not query project-board membership (HTTP $status) -- not failing the check on an infrastructure issue, but this should be investigated.")
    else
        # Read the response over stdin rather than having Python open
        # $response_file itself: bash's mktemp path and a separately
        # invoked Python interpreter can disagree about path translation
        # under Git Bash on Windows -- piping keeps path resolution
        # entirely inside the shell that already wrote the file.
        project_item_count=$(python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    if 'errors' in d:
        print('TOKEN_ERROR')
    else:
        nodes = d['data']['repository']['pullRequest']['projectItems']['nodes']
        print(sum(1 for n in nodes if n['project']['number'] == $project_number))
except Exception:
    print('')
" < "$response_file")
        if [ "$project_item_count" = "TOKEN_ERROR" ]; then
            errors+=("Project-board lookup failed: the GraphQL response contained an error (commonly an invalid/expired token or a token missing read:project scope). A token was supplied, so this is a configuration problem -- fix or rotate PROJECT_AUTOMATION_PAT (see AGENTS.md rule 3).")
        elif [ -z "$project_item_count" ]; then
            warnings+=("Could not parse project-board membership response -- not failing the check on an infrastructure issue, but this should be investigated.")
        elif [ "$project_item_count" -eq 0 ]; then
            errors+=("Not on project board #$project_number ($project_owner). Add it with: gh project item-add $project_number --owner $project_owner --url <pr-url> (see AGENTS.md rule 3).")
        fi
    fi
    rm -f "$response_file"
fi

for w in "${warnings[@]:-}"; do
    [ -n "$w" ] && echo "::warning::$w" >&2
done

if [ "${#errors[@]}" -eq 0 ]; then
    echo "PR tracking metadata check passed: labels, milestone$( [ -n "${GH_TOKEN:-}" ] && echo ", and project board" ) are set."
    exit 0
fi

error_message="PR tracking metadata check failed (AGENTS.md rule 3):"
for e in "${errors[@]}"; do
    error_message="$error_message"$'\n'"  - $e"
done

if [ "$pr_draft" = "true" ]; then
    echo "::warning::$error_message" >&2
    echo "" >&2
    echo "This is a draft PR, so this check is non-blocking. Set these before marking ready for review." >&2
    exit 0
else
    echo "::error::$error_message" >&2
    exit 1
fi
