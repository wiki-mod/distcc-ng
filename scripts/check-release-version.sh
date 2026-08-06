#!/bin/sh
# distcc-ng (https://github.com/wiki-mod/distcc-ng)
#
# Fail-closed guardrail for cutting a release, per doc/release-versioning.md:
#   - refuses if the release tag already exists
#   - refuses if configure.ac's AC_INIT version does not match the tag
#
# Usage: scripts/check-release-version.sh vX.Y.Z-NG

set -eu

if [ $# -ne 1 ]; then
    echo "usage: $0 vX.Y.Z-NG" >&2
    exit 2
fi

tag="$1"
version="${tag#v}"

configure_ac="$(dirname "$0")/../configure.ac"

if [ ! -f "$configure_ac" ]; then
    echo "error: cannot find configure.ac at $configure_ac" >&2
    exit 1
fi

# AC_INIT's package-name argument is "distcc-ng", not "distcc" -- the RPM/
# deb package name is deliberately distinct from the distcc/distccd/pump
# binary names, which keep their own upstream names unchanged. Match the
# actual package name literally rather than assuming it equals a binary name.
configured_version="$(sed -n 's/^AC_INIT(\[distcc-ng\],\[\([^]]*\)\].*/\1/p' "$configure_ac")"

if [ -z "$configured_version" ]; then
    echo "error: could not parse AC_INIT version out of $configure_ac" >&2
    exit 1
fi

if [ "$configured_version" != "$version" ]; then
    echo "error: configure.ac declares version '$configured_version', but tag '$tag' implies '$version' -- these must match exactly" >&2
    exit 1
fi

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then
    echo "error: tag '$tag' already exists -- refusing to reuse a release version. Bump configure.ac and choose a new version." >&2
    exit 1
fi

echo "ok: '$tag' matches configure.ac and does not already exist -- safe to tag."
