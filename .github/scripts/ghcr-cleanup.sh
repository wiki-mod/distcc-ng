#!/usr/bin/env bash
#
# Deletes stale GHCR container package versions for one or more of this
# repo's own packages: every genuinely untagged version (never pullable by
# any tag, so keeping it around serves no purpose), and old disposable
# "manual-N" workflow_dispatch test builds (package-release.yml's manual
# test-build path) beyond the KEEP_MANUAL most recent run numbers. Never
# touches a real version tag (X.Y.Z-NG...), "latest", or "nightly" -- those
# are matched against an explicit allow-nothing-else regex, not inferred by
# exclusion.
#
# Safety: an "untagged" version can, in principle, still be referenced as a
# platform-specific child of a multi-arch manifest list that some OTHER tag
# still points to -- deleting it would silently break pulls for that tag on
# that platform. This repo's own package-release.yml pipeline always tags
# each platform child explicitly before merging it into a list (see
# publish_manifest's `docker buildx imagetools create`), so today no
# genuinely untagged version is ever such a child (verified empirically
# against the live registry while designing this script). This script
# re-verifies that per run rather than trusting the invariant to hold
# forever: it resolves every currently-tagged reference's manifest first and
# excludes any digest still referenced by a live multi-arch list from the
# untagged-deletion candidates.
#
# Requires: gh (authenticated via GH_TOKEN -- needs delete:packages scope
# when DRY_RUN=false, a classic PAT; the default GITHUB_TOKEN cannot delete
# org package versions regardless of the packages: write permission),
# docker buildx, jq. Run on a GitHub-hosted ubuntu-latest runner (all three
# preinstalled there).
#
# DRY_RUN=true (default) only lists what would be deleted, no API writes.

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN required (delete:packages scope when DRY_RUN=false)}"
: "${OWNER:?OWNER required, e.g. wiki-mod}"
: "${PACKAGES:?PACKAGES required, space-separated container package names}"
DRY_RUN="${DRY_RUN:-true}"
KEEP_MANUAL="${KEEP_MANUAL:-2}"

delete_version() {
  local pkg="$1" id="$2" reason="$3"
  if [ "${DRY_RUN}" = "true" ]; then
    echo "[dry-run] would delete ${pkg}#${id} (${reason})"
  else
    echo "deleting ${pkg}#${id} (${reason})"
    gh api --method DELETE "orgs/${OWNER}/packages/container/${pkg}/versions/${id}" --silent
  fi
}

for pkg in ${PACKAGES}; do
  echo "::group::${pkg}"

  versions_json="$(gh api --paginate "orgs/${OWNER}/packages/container/${pkg}/versions")"

  # --- Resolve protected digests: children of every live multi-arch list ---
  declare -A protected=()
  all_tags="$(jq -r '.[].metadata.container.tags[]?' <<< "${versions_json}" | sort -u)"
  while IFS= read -r tag; do
    [ -z "${tag}" ] && continue
    raw="$(docker buildx imagetools inspect --raw "ghcr.io/${OWNER}/${pkg}:${tag}" 2>/dev/null)" || continue
    if grep -q 'manifest\.list\.v2\|image\.index\.v1' <<< "${raw}"; then
      while IFS= read -r child; do
        protected["${child}"]=1
      done < <(jq -r '.manifests[]?.digest' <<< "${raw}")
    fi
  done <<< "${all_tags}"

  # --- Untagged versions, minus anything a live manifest list still points
  # to -------------------------------------------------------------------
  while IFS=$'\t' read -r id digest; do
    [ -z "${id}" ] && continue
    if [ -n "${protected[${digest}]+x}" ]; then
      echo "SKIP untagged ${digest} (${pkg}#${id}): still referenced by a live multi-arch manifest"
      continue
    fi
    delete_version "${pkg}" "${id}" "untagged ${digest}"
  done < <(jq -r '.[] | select((.metadata.container.tags | length) == 0) | [.id, .name] | @tsv' <<< "${versions_json}")

  # --- Old manual-N groups beyond the KEEP_MANUAL most recent run numbers -
  manual_numbers="$(jq -r '.[].metadata.container.tags[]?' <<< "${versions_json}" \
    | sed -nE 's/^manual-([0-9]+)(-amd64|-arm64)?$/\1/p' | sort -un)"
  keep_numbers="$(printf '%s\n' "${manual_numbers}" | sort -urn | head -n "${KEEP_MANUAL}")"

  while IFS=$'\t' read -r id tag; do
    [ -z "${id}" ] && continue
    num="$(sed -E 's/^manual-([0-9]+).*/\1/' <<< "${tag}")"
    if grep -qx "${num}" <<< "${keep_numbers}"; then
      continue
    fi
    delete_version "${pkg}" "${id}" "old manual tag ${tag}"
  done < <(jq -r '.[] | .id as $id | .metadata.container.tags[]? | select(test("^manual-[0-9]+(-amd64|-arm64)?$")) | [$id, .] | @tsv' <<< "${versions_json}")

  unset protected
  echo "::endgroup::"
done
