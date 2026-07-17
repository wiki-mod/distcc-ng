# `umask` silently defeats `dcc_open_lockfile()`'s intended shared-lock-dir `0666` mode

**Fork issue:** [wiki-mod/distcc-ng#159](https://github.com/wiki-mod/distcc-ng/issues/159)
**Fixed by:** [wiki-mod/distcc-ng#160](https://github.com/wiki-mod/distcc-ng/pull/160)
**Upstream location:** `src/lock.c`, function `dcc_open_lockfile()`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-17)

## The problem

`dcc_open_lockfile()` opens lock-slot files with an explicit `0666` mode, and
the surrounding code comment explains this is deliberate: `DISTCC_DIR` (and
so the lock directory inside it) can be pointed at a location shared across
multiple local users on the same build host, and each of them needs to be
able to create/open/lock slot files another user created first. This is a
functional-correctness concern, not a confidentiality one — the intent is
for the file to end up genuinely world-writable.

The problem is that `open()`'s mode argument is always masked by the
*creating process's own umask* — under a typical umask of `022` or `002`,
the requested `0666` actually lands on disk as `0644` or `0664`, not
`0666`. This silently defeats the shared-lock-dir support the code comment
documents as intentional: whichever user's process happens to create a
given lock-slot file first determines its on-disk owner and group, and a
different user then gets `EACCES` trying to reopen that same file `O_RDWR`
to relock it — exactly the deployment the `0666` was meant to support.

## Upstream code (unchanged as of the commit above, upstream)

`src/lock.c`, `dcc_open_lockfile()`:

```c
/* The file is created with the loosest permissions allowed by the user's
 * umask, to give the best chance of avoiding problems if they should
 * happen to use a shared lock dir. */
/* FIXME: If we fail to open with EPERM or something similar, try deleting
 * the file and try again.  That might fix problems with root-owned files
 * in user home directories. */
...
*plockfd = open(fname, O_WRONLY|O_CREAT, 0666);
```

No `fchmod()` (or any other umask-bypassing mechanism) follows the `open()`
call anywhere in this function — the comment already acknowledges the
umask dependency ("loosest permissions allowed by the user's umask") without
addressing it.

## Fixed code (this fork, PR #160)

```c
*plockfd = open(fname, O_WRONLY|O_CREAT, 0666);
...
/* open()'s mode argument is masked by the creating process's umask --
 * under a typical umask of 022 or 002, the 0666 above actually lands
 * on disk as 0644 or 0664, silently defeating the shared-lock-dir
 * support the comment above describes (verified live: a second user
 * outside the file's group got EACCES trying to reopen an existing
 * slot file O_RDWR). fchmod() is not subject to umask, so it's the
 * only way to actually get the requested 0666 regardless of who
 * created the file first. Best-effort: if this fails (e.g. the file
 * is owned by a different user and we don't have permission to
 * rechmod it), fall through and let the lock attempt itself succeed
 * or fail on its own terms rather than treating this as fatal. */
if (*plockfd != -1 && fchmod(*plockfd, 0666) == -1) {
    rs_log_warning("failed to chmod %s to 0666: %s", fname, strerror(errno));
}
```

`fchmod()`, unlike `open()`'s mode argument, is not subject to umask, so it
actually achieves the `0666` the surrounding code already intended.

## Empirical verification

Per this fork's own PR body: verified live on a real Docker host, not just
read from the diff — created a lock slot as one Unix user, and confirmed
via `stat` that the resulting on-disk mode was `0664` before the fix and
genuinely `0666` after. The fork's own follow-up notes that this fix does
not fully solve shared-lock-dir usage in every environment: a real
second-user relock can still fail on hosts with the kernel's
`fs.protected_regular` hardening enabled — a separate, pre-existing
limitation of the shared-lock-dir design itself, unrelated to this specific
umask-masking bug.

Landed via [wiki-mod/distcc-ng#160](https://github.com/wiki-mod/distcc-ng/pull/160).
