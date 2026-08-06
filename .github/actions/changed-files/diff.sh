#!/usr/bin/env bash
#
# See action.yml's description for the full behavior contract. Extracted
# to its own file (same pattern as .github/actions/nightly-status) rather
# than inlined, since this is genuinely reused logic, not a one-off.

set -euo pipefail

if [ "${EVENT_NAME}" = "workflow_dispatch" ] || [ "${EVENT_NAME}" = "schedule" ]; then
  echo "forced=true" >> "${GITHUB_OUTPUT}"
  echo "changed_files=" >> "${GITHUB_OUTPUT}"
  echo "forced by ${EVENT_NAME} -- caller should treat everything as relevant"
  exit 0
fi

if [ "${EVENT_NAME}" = "pull_request" ]; then
  from="${BASE_SHA}"
else
  from="${BEFORE_SHA}"
fi

if [ -z "${from}" ] || [ "${from}" = "0000000000000000000000000000000000000000" ]; then
  echo "forced=true" >> "${GITHUB_OUTPUT}"
  echo "changed_files=" >> "${GITHUB_OUTPUT}"
  echo "no diffable base (${from}) -- failing open"
  exit 0
fi

changed="$(git diff --name-only "${from}" "${HEAD_SHA}")"
echo "changed files:"
echo "${changed}"

echo "forced=false" >> "${GITHUB_OUTPUT}"
{
  echo "changed_files<<CHANGED_FILES_EOF"
  echo "${changed}"
  echo "CHANGED_FILES_EOF"
} >> "${GITHUB_OUTPUT}"
