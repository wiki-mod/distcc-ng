#!/bin/sh -e

# What: Converts a list of RPMs into .deb packages via alien, given a
#   package name and version.
# Why: Must run from the packaging/ directory -- its relative paths
#   assume that as the working directory.

PACKAGE="$1";
VERSION="$2";
shift; shift;

# What: Deletes any old .deb files, matched with a bare *.deb glob
#   rather than a $PACKAGE/$VERSION-derived pattern.
# Why: alien rewrites the RPM version string into Debian's own syntax
#   (e.g. "3.7.0-NG" -> "3.7.0-1.NG"), so $VERSION never appears as a
#   literal substring of the real filename -- a version-derived pattern
#   here previously matched nothing, silently, on every run.
# From: Issue #412
rm -f *.deb

for file in "$@"; do
  fakeroot alien -c -k -v "$file"
done

# What: Patches Conflicts/Replaces into every .deb's control file.
# Why: alien doesn't carry Provides/Conflicts/Obsoletes from the source
#   RPM spec at all, and Debian's own distcc package is unified (no
#   split client/server subpackages like this fork's RPMs), so every
#   .deb needs the same patch regardless of which RPM subpackage
#   produced it.
# From: Issue #412
for deb in *.deb; do
  work_dir="$(mktemp -d)"
  fakeroot dpkg-deb -R "$deb" "$work_dir"
  if ! grep -q '^Conflicts:' "$work_dir/DEBIAN/control"; then
    printf 'Conflicts: distcc\n' >> "$work_dir/DEBIAN/control"
  fi
  if ! grep -q '^Replaces:' "$work_dir/DEBIAN/control"; then
    printf 'Replaces: distcc\n' >> "$work_dir/DEBIAN/control"
  fi

  # What: Renames usr/bin/pump to usr/bin/distcc-pump (and its man page)
  #   when present in this .deb -- only the client subpackage carries it.
  # Why: Debian's own real distcc-pump package does this exact rename in
  #   its own packaging layer (debian/rules' execute_before_dh_install),
  #   never in upstream's build system, to avoid a too-generic command
  #   name in the global PATH; no compatibility symlink is shipped either.
  # From: Issue #485
  if [ -f "$work_dir/usr/bin/pump" ]; then
    mv "$work_dir/usr/bin/pump" "$work_dir/usr/bin/distcc-pump"
  fi
  if [ -f "$work_dir/usr/share/man/man1/pump.1.gz" ]; then
    mv "$work_dir/usr/share/man/man1/pump.1.gz" \
       "$work_dir/usr/share/man/man1/distcc-pump.1.gz"
  fi

  # What: Regenerates DEBIAN/md5sums from the work_dir's actual current
  #   file tree.
  # Why: `dpkg-deb -b` packs whatever files exist without touching
  #   md5sums, so the renamed paths above would otherwise leave it
  #   listing the old, now-missing pump paths and omitting the new ones,
  #   breaking `dpkg -V` integrity checks against the built package.
  # From: Issue #485
  if [ -f "$work_dir/DEBIAN/md5sums" ]; then
    ( cd "$work_dir" && \
      find . -type f ! -path './DEBIAN/*' -exec md5sum {} \; \
        | sed 's|^\./||' > DEBIAN/md5sums )
  fi

  fakeroot dpkg-deb -b "$work_dir" "$deb"
  rm -rf "$work_dir"
done

echo
echo "The Debian package files are located in $PWD:"
ls *.deb
