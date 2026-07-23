#!/usr/bin/env bash
# Validates a pull request TITLE against this repo's Conventional-Commit
# taxonomy, enforced from AGENTS.md rule 71. Adapted from
# wiki-mod/lancache-ng's own scripts/check-pr-title-convention.sh (their
# AG-GH-018) -- see issue #307 for the real-history audit this taxonomy
# was derived from (unlike lancache-ng's audit, almost none of this
# repo's real PR-title history already followed the convention, so this
# is establishing it going forward, not codifying existing practice).
#
# Expected shape: type(scope)!: subject
#   - type    required, one of $allowed_types below (lowercase, exact match)
#   - (scope) optional, one of $allowed_scopes below (lowercase)
#   - !       optional, marks a breaking change (informational only here --
#             this project has no automated version-bump tooling and
#             doesn't follow SemVer, see AGENTS.md rule 71)
#   - subject required, non-empty after the mandatory ": " separator
#
# `security` IS one of the allowed types (matching lancache-ng's own
# addition, and this project's own real history of deliberate
# `security:`-prefixed titles, e.g. the CodeQL-remediation series in #143).
#
# For draft PRs: prints warnings but exits 0 (non-blocking) -- title
# convention is expected to settle before a PR leaves draft, not before
# the first push.
#
# Grace-period switch: PR_TITLE_LINT_MODE controls whether a non-draft PR
# with a non-conforming title fails the job ("block") or only warns
# ("warn"). Defaults to "warn" for now: a transitional grace period, NOT a
# permanent downgrade. A warn result is still a real rule-71 violation
# that should be fixed before merge -- it simply does not hard-block CI
# yet.
#
# Usage:
#   check-pr-title-convention.sh <title-file>
#
# Environment variables (for CI):
#   PR_TITLE            - PR title content (used if no file argument)
#   PR_DRAFT            - "true" or "false" (if not set, defaults to non-draft enforcement)
#   PR_AUTHOR           - github.event.pull_request.user.login; a literal
#                         "dependabot[bot]" short-circuits this check entirely
#                         (see the exemption below for why)
#   PR_TITLE_LINT_MODE  - "warn" (current default, transitional grace period)
#                         or "block" (full enforcement); see the note above
#
# Runs directly on the GitHub-hosted ubuntu-latest runner in CI (this
# repo's CI runs exclusively on GitHub-hosted runners, no self-hosted
# concern to route around) -- see the pr_title_convention job in
# .github/workflows/changelog-check.yml.
set -euo pipefail

# Dependabot writes its own fixed dependency-bump titles (e.g. "Bump foo
# from 1.0 to 1.1") and has no way to conform to this repo's
# Conventional-Commit taxonomy on its own -- exempting it here (matching
# check-pr-tracking-metadata.sh's identical exemption) rather than
# skipping the whole CI job, so the required-status-check gate sees an
# explicit pass, not an ambiguous skip.
if [ "${PR_AUTHOR:-}" = "dependabot[bot]" ]; then
    echo "PR title convention check skipped: PR authored by dependabot[bot], which cannot conform to this repo's Conventional-Commit title taxonomy."
    exit 0
fi

# Grace-period switch -- see the header comment above.
pr_title_lint_mode="${PR_TITLE_LINT_MODE:-warn}"

pr_draft="${PR_DRAFT:-false}"

title_file="${1:-}"
title=""

# Read the PR title from a file or environment variable.
if [ -n "$title_file" ] && [ -f "$title_file" ]; then
    title="$(<"$title_file")"
elif [ -n "${PR_TITLE:-}" ]; then
    title="$PR_TITLE"
else
    echo "::error::No PR title provided. Pass a file path as argument or set PR_TITLE environment variable." >&2
    exit 1
fi

# `gh pr view --json title` (and GitHub's API generally) can return a
# trailing CRLF; strip both a trailing \r and any trailing whitespace so a
# clean title isn't rejected purely on invisible trailing bytes.
title="${title%$'\r'}"
title="$(printf '%s' "$title" | sed 's/[[:space:]]*$//')"

# Allowed types: the standard Conventional Commits set, plus `security`
# (a project-specific addition -- see the header comment; maps to a
# Z/patch bump like `fix` if version-bump automation is ever added).
allowed_types=(feat fix docs refactor perf test build ci chore style revert security)

# Allowed scopes: optional, lowercase, drawn from this repo's real
# architecture (CLAUDE.md's "Architecture" section) plus non-component
# project areas already in real use (governance, support-upstream).
allowed_scopes=(distcc distccd pump protocol seccomp zstd config packaging docker ci docs scripts tests governance support-upstream)

array_contains() {
    local needle="$1"
    shift
    local candidate
    for candidate in "$@"; do
        if [ "$candidate" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

errors=()

# type(scope)!: subject -- scope and the breaking-change `!` are both
# optional. Capture groups (BASH_REMATCH indices): 1=type, 2=(scope) with
# parens, 3=scope alone, 4=!, 5=subject. `: ` (colon-space) is mandatory,
# matching Conventional Commits' own separator convention.
conventional_commit_pattern='^([a-zA-Z]+)(\(([a-z0-9-]+)\))?(!)?:[[:space:]](.+)$'

if [[ "$title" =~ $conventional_commit_pattern ]]; then
    commit_type="${BASH_REMATCH[1]}"
    commit_scope="${BASH_REMATCH[3]}"
    commit_subject="${BASH_REMATCH[5]}"

    # Trim the subject and reject a subject that is only whitespace -- the
    # regex's `.+` already requires at least one character, but that
    # character could be a stray trailing space with nothing meaningful
    # before it (e.g. "fix:    ").
    trimmed_subject="$(printf '%s' "$commit_subject" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

    if ! array_contains "$commit_type" "${allowed_types[@]}"; then
        lowercase_type="$(printf '%s' "$commit_type" | tr '[:upper:]' '[:lower:]')"
        if array_contains "$lowercase_type" "${allowed_types[@]}"; then
            errors+=("Type '$commit_type' must be lowercase ('$lowercase_type').")
        else
            errors+=("Type '$commit_type' is not one of the allowed types: ${allowed_types[*]}.")
        fi
    fi

    if [ -n "$commit_scope" ] && ! array_contains "$commit_scope" "${allowed_scopes[@]}"; then
        errors+=("Scope '($commit_scope)' is not one of the documented areas: ${allowed_scopes[*]} (see AGENTS.md rule 71).")
    fi

    if [ -z "$trimmed_subject" ]; then
        errors+=("Subject is empty or whitespace-only after 'type(scope)!: '.")
    fi
else
    errors+=("Title does not start with a Conventional-Commit prefix ('type(scope)!: subject', e.g. 'feat(pump): add IPv6 support' or 'fix: correct build flag handling'). Allowed types: ${allowed_types[*]}.")
fi

if [ "${#errors[@]}" -eq 0 ]; then
    echo "PR title convention check passed: '$title'"
    exit 0
fi

error_message="PR title convention check failed (AGENTS.md rule 71) for title: '$title'"
for e in "${errors[@]}"; do
    error_message="$error_message"$'\n'"  - $e"
done

if [ "$pr_draft" = "true" ]; then
    # Draft PR: warn but don't fail, so a PR can be opened before its final
    # title is settled.
    echo "::warning::$error_message" >&2
    echo "" >&2
    echo "This is a draft PR, so the title convention check is non-blocking. Fix the title before marking ready for review." >&2
    exit 0
elif [ "$pr_title_lint_mode" = "warn" ]; then
    # Grace-period mode: report the same failure but do not block the PR.
    # A warn result here is still a real rule-71 violation, just not a
    # hard CI gate yet.
    echo "::warning::$error_message" >&2
    echo "" >&2
    echo "PR_TITLE_LINT_MODE=warn: this is a transitional grace period, not a permanent downgrade. The title above is still a rule violation (AGENTS.md rule 71) and should be fixed before this PR merges -- it simply does not hard-block CI while the grace period is active." >&2
    exit 0
else
    echo "::error::$error_message" >&2
    exit 1
fi
