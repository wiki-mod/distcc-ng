# distccd: unvalidated client-supplied NAME allows path traversal in dcc_r_many_files()

**Fork issue:** [wiki-mod/distcc-ng#93](https://github.com/wiki-mod/distcc-ng/issues/93)
**Fixed by:** [wiki-mod/distcc-ng#94](https://github.com/wiki-mod/distcc-ng/pull/94)
**Upstream location:** `src/srvrpc.c`, `dcc_r_many_files()`
**Checked against upstream commit:** [`76d8dc6c`](https://github.com/distcc/distcc/commit/76d8dc6c5eb65e2b3fb151db0338566f1f55dcee) (latest commit touching `src/srvrpc.c`, `master`, checked 2026-07-17)

## The problem

`distccd` receives a list of files/symlinks from the client via the `NAME`
token in `dcc_r_many_files()`, then prepends the server's own per-job temp
directory (`dirname`) to build the on-disk path where the file gets written
or the symlink gets created. `NAME` is client-controlled and, before this
fix, was never validated: a crafted `NAME` containing `..` components (or
not rooted at `/`) could walk the resulting concatenated path outside the
intended temp directory entirely, letting a malicious/compromised client
write a `FILE` or create a `LINK` anywhere the `distccd` process has
permission to.

Upstream's own source has carried an acknowledging `FIXME` at this exact
spot since long before this fork existed — the gap is known, not obscure,
and still unaddressed.

## Upstream code (unchanged as of the commit above, upstream `master`)

`src/srvrpc.c`, inside `dcc_r_many_files()`:

```c
if ((ret = dcc_r_token_string(in_fd, "NAME", &name)))
    goto out_cleanup;

/* FIXME: verify that name starts with '/' and doesn't contain '..'. */
if ((ret = prepend_dir_to_name(dirname, &name)))
    goto out_cleanup;
```

No validation of `name` happens between the token read and the
`prepend_dir_to_name()` concatenation — the `FIXME` comment is the only
acknowledgement of the gap, and it is still exactly as unaddressed today
as it evidently was when the comment was written.

## Fixed code (this fork, PR #94)

A new, deliberately dependency-free `src/pathsafety.c`/`.h` pair adds
`dcc_name_has_path_traversal()`, called from `dcc_r_many_files()` before
the same `prepend_dir_to_name()` call:

```c
/* Reject a client-supplied absolute-style path (as received in a NAME
 * token, before it is prepended with the server's own temp dirname) that
 * could escape the intended directory tree.
 *
 * "escape" means: not rooted at '/', or containing a ".." path component
 * (leading "/../", embedded "/../", or trailing "/.."). Any of those,
 * concatenated onto a dirname, can walk the resulting path outside dirname
 * entirely -- e.g. dirname "/var/tmp/distccd-XXXXXX" + name
 * "/../../../etc/cron.d/evil" resolves outside the server's temp dir.
 *
 * Returns 1 (unsafe, reject) or 0 (safe to use).
 */
int dcc_name_has_path_traversal(const char *name)
{
    size_t len = strlen(name);

    if (name[0] != '/')
        return 1;

    if (strstr(name, "/../") != NULL)
        return 1;

    if (len >= 3 && strcmp(name + len - 3, "/..") == 0)
        return 1;

    return 0;
}
```

`dcc_r_many_files()` now rejects the request outright if
`dcc_name_has_path_traversal(name)` is true, before `prepend_dir_to_name()`
ever runs. A new `h_pathsafety` unit-test binary exercises the check
directly from `test/testdistcc.py` without needing a full client/server
round trip.

## Known deliberate scope limit (not a gap in this analysis)

This fix intentionally does **not** validate a `LINK` entry's separate
`link_target` (the symlink's target, as opposed to the `NAME` naming the
symlink itself): the include-server's own mirroring logic
(`_MakeLinkFromMirrorToRealLocation` in
`include_server/compiler_defaults.py`) legitimately relies on a leading
`..` in `link_target` to reference real system directories from a mirror
tree, so rejecting `..` there the same way would break existing, intended
behavior. That remaining gap is tracked separately by this fork
(wiki-mod/distcc-ng#95) and is out of scope for this entry, which is about
the `NAME`-only traversal upstream's `FIXME` already flags.

Landed via [wiki-mod/distcc-ng#94](https://github.com/wiki-mod/distcc-ng/pull/94).
