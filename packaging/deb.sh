#!/bin/sh -e

# This takes a package name and version,
# and a list of rpms to convert to .deb files.
# It puts them all under a debian-* directory under the current directory.
#
# Run this from the 'packaging' directory, just under rootdir

PACKAGE="$1";
VERSION="$2";
shift; shift;

# Clean out any old .deb files from a previous build. Bare *.deb, not a
# $PACKAGE/$VERSION-derived pattern: alien rewrites the RPM version string
# into Debian's own syntax (e.g. "3.7.0-NG" -> "3.7.0-1.NG", inserting a
# Debian revision and turning the "-NG" suffix into ".NG" since Debian
# version syntax disallows a second hyphen in the upstream-version part),
# so $VERSION never appears as a literal substring of the real filename --
# the previous pattern here silently matched nothing on every run (masked
# by rm -f's own error suppression), same root cause as the patching loop
# below, found while fixing that one for issue #412.
rm -f *.deb

for file in "$@"; do
  fakeroot alien -c -k -v "$file"
done

# alien does not carry Provides/Conflicts/Obsoletes from the source RPM
# into the generated .deb's control file at all (confirmed by reading
# Alien::Package::Deb::prep() in alien's own source,
# github.com/mildred/alien -- it only ever writes Source/Section/Priority/
# Maintainer/Package/Architecture/Depends/Description). Without this, the
# rpm.spec Conflicts/Obsoletes added for issue #412 never reaches the .deb
# side at all, so patch every .deb this run just produced directly.
#
# Debian's real "distcc" package bundles both client and server
# functionality into one unified package (confirmed live,
# packages.debian.org/search?keywords=distcc -- unlike this fork's split
# client/server RPM subpackages, there is no separate "distcc-server" in
# Debian), so every .deb produced here needs the same Conflicts/Replaces
# regardless of which RPM subpackage it came from. Debian Policy §7.6.1's
# standard "this package supersedes that one" idiom is Replaces + Conflicts
# together -- Debian has no direct equivalent of RPM's Obsoletes.
#
# Matched with a bare *.deb (see the cleanup line's own comment above for
# why a $PACKAGE/$VERSION-derived pattern doesn't work here) -- safe
# because that cleanup already removed any pre-existing .deb, so every one
# present at this point was produced by the alien loop just above.
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

  fakeroot dpkg-deb -b "$work_dir" "$deb"
  rm -rf "$work_dir"
done

echo
echo "The Debian package files are located in $PWD:"
ls *.deb
