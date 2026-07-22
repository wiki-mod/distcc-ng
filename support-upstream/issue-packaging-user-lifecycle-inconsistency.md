# `rpm.spec` disagrees with itself, and with Debian's own real package, on the `distcc` service user's lifecycle

**Fork issue:** none filed yet — found while investigating this fork's own `distccd` privilege-drop behavior (see `issue-077-autogroup-niceness.md`)
**Fixed by:** [wiki-mod/distcc-ng#284](https://github.com/wiki-mod/distcc-ng/pull/284)
**Upstream location:** `packaging/RedHat/rpm.spec` — Debian branch's `deluser`/`delgroup` at line 217; Red Hat branch's `useradd` calls at lines 140/143; Debian branch's `adduser` at line 151-152
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-22)
**Searched upstream issues/PRs for:** `useradd distcc`, `deluser distcc`, `distcc home directory` — no matching report or fix attempt found, open or closed.

## The problem

Two separate but related inconsistencies in the same file, both stemming from the same underlying question — does the `distcc` service user need a home directory, and should it survive a package purge — which upstream never answered consistently:

**1. Purge behavior.** `rpm.spec`'s Debian branch `%postun` (line 217) does `deluser --quiet --system distcc` / `delgroup --quiet --system distcc` on purge. Debian's own actual, independently-maintained `distcc` package (verified live on a running Debian host, 2026-07-22) never removes the user/group on purge at all — its `postrm` only removes `/etc/default/distcc`, log files, and the pid file.

**2. Home directory.** The Red Hat branch:
```
/usr/sbin/useradd -d /var/run/distcc -m -r $DISTCC_USER &>/dev/null || :
...
/usr/sbin/useradd -d /var/run/distcc -m -r -s /sbin/nologin $DISTCC_USER &>/dev/null || :
```
uses `-m` (create home directory) with `-d /var/run/distcc` — a writable home under `/var/run`. The Debian branch:
```
adduser --quiet --system --gid 11 \
  --home / --no-create-home --uid 15 $DISTCC_USER
```
uses `--no-create-home` but `--home /` — a nominal-but-nonsensical home directory (the filesystem root). Neither matches Debian's own real `distcc` package, which uses `--home /nonexistent --no-create-home` (a genuinely inert path, confirmed live on a running host) — and the maintainer's own standing decision for this fork's service user is the same: it has no need for a home directory at all.

## Upstream code (unchanged as of the commit above, upstream)

```
deluser --quiet --system distcc
delgroup --quiet --system distcc
```
(`rpm.spec` lines 217-218)

```
/usr/sbin/useradd -d /var/run/distcc -m -r $DISTCC_USER &>/dev/null || :
...
/usr/sbin/useradd -d /var/run/distcc -m -r -s /sbin/nologin $DISTCC_USER &>/dev/null || :
...
adduser --quiet --system --gid 11 \
  --home / --no-create-home --uid 15 $DISTCC_USER
```
(`rpm.spec` lines 140/143/151-152), all confirmed via `git show 8d569d19:packaging/RedHat/rpm.spec`.

## Fixed code (this fork)

This fork's `packaging/RedHat/rpm.spec` `%postun` no longer removes the `distcc` user/group on Debian-based purge. Both the Red Hat branch (`useradd -d /nonexistent -r ...`, `-m` removed) and the Debian branch (`adduser ... --home /nonexistent --no-create-home ...`) now use `--home /nonexistent`/no home creation, consistently across both distro families and matching Debian's own real package convention. `docker/release/Dockerfile` (a fork-only file, no upstream equivalent) already used `--no-create-home --home-dir /nonexistent` for the same reason.

## Empirical verification

Confirmed against a real, running Debian host's actual installed `distcc` package (`3.4+really3.4-12`) that its `postrm` never calls `deluser`/`delgroup` on purge, and its `postinst` uses `adduser --quiet --system --home /nonexistent --no-create-home distccd`. See this repo's own CHANGELOG entry for this change for the full comparison.

The changed `%post server`/`%postun` scriptlets were extracted from `rpm.spec` and checked with `sh -n` (clean, no syntax errors) on a real Linux host. A full `rpmbuild` run was attempted on the same host but blocked by two pre-existing environment issues unrelated to this change: the host's `rpm` installation has no initialized `rpmdb` (not a real RPM-based distro), and `rpm.spec`'s `%prep`/`%setup` step doesn't account for this fork's own `VERSION`/`RPM_VERSION` split (`packaging/rpm.sh`'s own `-NG`-suffix handling) when deriving the source directory name inside the tarball — both pre-date this change and are out of its scope.
