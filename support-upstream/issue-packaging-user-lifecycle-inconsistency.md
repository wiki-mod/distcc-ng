# `rpm.spec`'s Debian branch removes the `distcc` service user/group on purge, unlike Debian's own real package

**Fork issue:** none filed yet — found while investigating this fork's own `distccd` privilege-drop behavior (see `issue-077-autogroup-niceness.md`)
**Fixed by:** [wiki-mod/distcc-ng#284](https://github.com/wiki-mod/distcc-ng/pull/284) — purge/deletion behavior only; see "Related, NOT fixed here" below for a second, separate inconsistency found in the same file that this change does not touch
**Upstream location:** `packaging/RedHat/rpm.spec` — Debian branch's `deluser`/`delgroup` at line 217
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-22)
**Searched upstream issues/PRs for:** `useradd distcc`, `deluser distcc`, `distcc home directory` — no matching report or fix attempt found, open or closed.

## The problem

`rpm.spec`'s Debian branch `%postun` (line 217) does `deluser --quiet --system distcc` / `delgroup --quiet --system distcc` on purge. Debian's own actual, independently-maintained `distcc` package (verified live on a running Debian host, 2026-07-22) never removes the user/group on purge at all — its `postrm` only removes `/etc/default/distcc`, log files, and the pid file. Upstream's own packaging disagrees with the real distro convention it's meant to follow.

## Upstream code (unchanged as of the commit above, upstream)

```
deluser --quiet --system distcc
delgroup --quiet --system distcc
```
(`rpm.spec` lines 217-218), confirmed via `git show 8d569d19:packaging/RedHat/rpm.spec`.

## Fixed code (this fork)

This fork's `packaging/RedHat/rpm.spec` `%postun` no longer removes the `distcc` user/group on Debian-based purge, matching Debian's own real package behavior (confirmed live on a running host).

## Empirical verification

Confirmed against a real, running Debian host's actual installed `distcc` package (`3.4+really3.4-12`) that its `postrm` never calls `deluser`/`delgroup` on purge. See this repo's own CHANGELOG entry for this change for the full comparison.

## Related, NOT fixed here: a second, separate inconsistency in the same file

`rpm.spec`'s `%pre server` scriptlet also disagrees with itself on the service user's **home directory**, independent of the purge issue above and not touched by this change:

```
/usr/sbin/useradd -d /var/run/distcc -m -r $DISTCC_USER &>/dev/null || :
...
/usr/sbin/useradd -d /var/run/distcc -m -r -s /sbin/nologin $DISTCC_USER &>/dev/null || :
```
(Red Hat branch) uses `-m` (create home directory) with `-d /var/run/distcc` — a writable home under `/var/run`. The Debian branch:
```
adduser --quiet --system --gid 11 \
  --home / --no-create-home --uid 15 $DISTCC_USER
```
uses `--no-create-home` but `--home /` — a nominal-but-nonsensical home directory (the filesystem root), rather than a genuinely inert path like `/nonexistent` (which is what Debian's own real `distcc` package uses, per the empirical verification above). Both snippets confirmed unchanged as of `8d569d19`.

This is **not fixed by this PR**: `packaging/RedHat/rpm.spec` itself is untouched here beyond the `%postun` purge fix above — this fork's own RH branch and the upstream Debian branch's `--home /` both remain as-is (out of scope for this change). Separately, this PR's `docker/release/Dockerfile` (a fork-only file, no upstream equivalent, not part of `rpm.spec`) was changed to `--no-create-home --home-dir /nonexistent`, matching Debian's real package convention for the fork's own container image — this aligns the fork's Docker image with real-world practice, but does **not** resolve the `rpm.spec` home-directory inconsistency documented above, which remains a live, undecided upstream finding.
