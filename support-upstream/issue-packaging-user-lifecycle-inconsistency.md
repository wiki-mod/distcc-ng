# `rpm.spec`'s own Red Hat and Debian branches disagree on the `distcc` service user's lifecycle

**Fork issue:** none filed yet — found while investigating this fork's own `distccd` privilege-drop behavior (see `issue-077-autogroup-niceness.md`)
**Fixed by:** [wiki-mod/distcc-ng packaging-user-debian-parity branch](https://github.com/wiki-mod/distcc-ng) (this change)
**Upstream location:** `packaging/RedHat/rpm.spec` — Red Hat branch's `useradd` calls at lines 132 and 135; Debian branch's `deluser`/`delgroup` at line 217
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-22)
**Searched upstream issues/PRs for:** `useradd distcc`, `deluser distcc`, `distcc home directory` — no matching report or fix attempt found, open or closed.

## The problem

`rpm.spec`'s `%pre server` scriptlet branches on distro. The Red Hat branch:

```
/usr/sbin/useradd -d /var/run/distcc -m -r $DISTCC_USER &>/dev/null || :
...
/usr/sbin/useradd -d /var/run/distcc -m -r -s /sbin/nologin $DISTCC_USER &>/dev/null || :
```

uses `-m` (create home directory) with `-d /var/run/distcc` — giving the unprivileged `distcc` service user a writable home directory under `/var/run`. The Debian branch, a few lines later in the same file:

```
adduser --quiet --system --gid 11 \
  --home / --no-create-home --uid 15 $DISTCC_USER
```

is a strange middle ground: `--no-create-home` (so it won't try to create anything), but `--home /` — the user's recorded home directory is the filesystem root, not a genuinely empty/inert path like `/nonexistent`. The same package, in the same file, gives the service user a writable home on one distro family and a nominal-but-nonsensical one (`/`) on the other, with no stated reason for either choice. Separately, the Debian branch's `%postun` (line 217) does `deluser --quiet --system distcc` on purge, while Debian's own actual, independently-maintained `distcc` package (verified live on a running Debian host, 2026-07-22 — see this fork's own `packaging/RedHat/rpm.spec` fix in this same change) never removes the user on purge at all, and uses `--home /nonexistent` rather than `--home /`. Upstream's RH branch, upstream's own Debian branch, and Debian's actual shipped package all disagree — three different behaviors for what should be one policy decision.

## Upstream code (unchanged as of the commit above, upstream)

Both snippets above, byte-for-byte as shown, confirmed via `git show 8d569d19:packaging/RedHat/rpm.spec`.

## Fixed code (this fork)

This fork's `packaging/RedHat/rpm.spec` `%postun` no longer removes the `distcc` user/group on Debian-based purge, matching Debian's own real package behavior (confirmed live on a running host). `docker/release/Dockerfile` (a fork-only addition, no upstream equivalent) was changed to `--no-create-home --home-dir /nonexistent`, matching Debian's own actual, independently-maintained package (not upstream's own Debian branch, which uses `--home /` — this fork's fix deliberately follows the real distro convention over upstream's own inconsistent one). Upstream's Red Hat branch's own `-m`/`-d /var/run/distcc` behavior and upstream's own Debian branch's `--home /` are left as-is in this change (out of scope — this fork's RH branch wasn't touched, and the Debian branch itself is upstream code, not this fork's), documented here as a live upstream finding rather than silently worked around.

## Empirical verification

Confirmed against a real, running Debian host's actual installed `distcc` package (`3.4+really3.4-12`) that its `postrm` never calls `deluser`/`delgroup` on purge (only removes `/etc/default/distcc`, log files, and the pid file), and its `postinst` uses `adduser --quiet --system --home /nonexistent --no-create-home distccd`. See this repo's own CHANGELOG entry for this change for the full comparison.
