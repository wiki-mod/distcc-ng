# distccd: server follows a symlink at an intermediate NAME component when materializing a later multi-file entry (compound path-traversal write-escape)

**Fork issue:** [wiki-mod/distcc-ng#292](https://github.com/wiki-mod/distcc-ng/issues/292)
**Fixed by:** [wiki-mod/distcc-ng#293](https://github.com/wiki-mod/distcc-ng/pull/293)
**Upstream location:** `src/srvrpc.c` (`dcc_r_many_files()`), `src/bulk.c` (`dcc_r_file()`), `src/tempfile.c` (`dcc_mk_tmpdir()`)
**Checked against upstream commit:** [`8d569d1`](https://github.com/distcc/distcc/commit/8d569d19) (upstream `master` tip, checked 2026-07-22)
**Searched upstream issues/PRs for:** `dcc_r_many_files symlink`, `srvrpc O_NOFOLLOW`, `distccd symlink traversal`, `NAME component symlink`, `CWE-59 distcc` — no matching report or fix attempt found, open or closed.

## Note on scope / relationship to the fork's #93 entry

This is a distinct bug from `issue-093-name-path-traversal.md` (that one is the
`NAME`-*string*-contains-`..` case, guarded by `dcc_name_has_path_traversal()`).
This entry is about the server following a real on-disk **symlink** that sits at
an *intermediate* component of an otherwise perfectly `..`-free `NAME`, created
by an earlier `LINK` entry in the same `NFIL` batch. No `NAME` in the escape
sequence contains `..`, so the string check cannot see it; the escape happens
entirely through ordinary kernel path-component resolution.

## The problem

`distccd` receives a batch of files/symlinks from the client in
`dcc_r_many_files()`. Each entry's client-supplied `NAME` is concatenated onto
the server's per-job temp directory (`prepend_dir_to_name()`) and the resulting
plain path string is handed to path-based OS calls with no `O_NOFOLLOW`:

- directory creation: `dcc_mk_tmp_ancestor_dirs()` → `dcc_mk_tmpdir()` →
  `mkdir(path, 0777)` (`src/tempfile.c`),
- file creation: `dcc_r_file()` → `open(filename, O_TRUNC|O_WRONLY|O_CREAT|O_BINARY, 0666)`
  (`src/bulk.c`),
- symlink creation: `symlink(link_target, name)` (`src/srvrpc.c`).

A `LINK` entry's *relative* `link_target` is deliberately not validated (the
include-server's own mirroring symlinks legitimately use a leading `..` run, so
a text-only check cannot distinguish them — see the in-source `FIXME`). That is
acceptable on its own, but it means a client can create a symlink at a `NAME` of
its choosing whose target points anywhere. Because the subsequent `mkdir()`/
`open()` for a *later* entry nested under that name follow symlinks, a two-entry
batch escapes the job directory entirely:

```
NAME /safe
LINK ../../../../etc          # relative target, passes every current check

NAME /safe/cron.d/evil
FILE ...                      # "/safe" resolves through the symlink just made;
                              # mkdir()/open() write to /etc/cron.d/evil
```

Neither `NAME` contains `..`. The escape is through OS path resolution, not
through anything the `NAME`/`LINK`-target string checks inspect. This is the
classic CWE-59 link-following write-primitive.

## Upstream code (unchanged as of the commit above, upstream `master`)

`src/srvrpc.c`, inside `dcc_r_many_files()` — no component-wise resolution, and
the two `FIXME`s that mark the gap are still present:

```c
if ((ret = dcc_r_token_string(in_fd, "NAME", &name)))
    goto out_cleanup;

/* FIXME: verify that name starts with '/' and doesn't contain '..'. */
if ((ret = prepend_dir_to_name(dirname, &name)))
    goto out_cleanup;
...
    if ((ret = dcc_mk_tmp_ancestor_dirs(name))) {
        goto out_cleanup;
    }
    if (symlink(link_target, name) != 0) {
```

`src/bulk.c`, `dcc_r_file()` — plain `open()`, no `O_NOFOLLOW`:

```c
ofd = open(filename, O_TRUNC|O_WRONLY|O_CREAT|O_BINARY, 0666);
```

`src/tempfile.c`, `dcc_mk_tmpdir()` — plain `mkdir()`:

```c
if (mkdir(path, 0777) == -1) {
```

None of these resolve the client-controlled path component-by-component or with
`O_NOFOLLOW`, so an intermediate symlink component is transparently followed.

## Fixed code (this fork, PR #293)

`dcc_r_many_files()` opens the job directory once as `root_fd`
(`O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC`) and resolves each `NAME` with a new
`dcc_open_parent_beneath()` helper that walks the components one at a time
relative to `root_fd`, `openat()`ing each intermediate directory with
`O_DIRECTORY|O_NOFOLLOW` (`mkdirat()`+reopen when missing) and rejecting any
component that resolves to a symlink or non-directory (`ELOOP`/`ENOTDIR`) with
`EXIT_PROTOCOL_ERROR`. The leaf is then created relative to the resolved parent
fd: `FILE` via a new `dcc_r_file_beneath()` using
`openat(parent_fd, leaf, O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW|O_BINARY, 0666)`
(preserving `dcc_r_file()`'s binutils-compat "unlink first if non-empty" step
via `fstatat`/`unlinkat`), and `LINK` via `symlinkat(link_target, parent_fd, leaf)`.
Because every step uses `O_NOFOLLOW`, the kernel itself refuses to traverse any
symlink component, closing the escape without the server having to judge whether
a given symlink is legitimate.

The fix deliberately does **not** attempt to distinguish a legitimate mirror
symlink from a malicious one (confirmed unnecessary against
`include_server/mirror_path.py`'s `DoPath()`, which never nests a later entry
beneath a symlink it created in the same batch), and does not add a
chroot/mount-namespace boundary (tracked separately as
[wiki-mod/distcc-ng#289](https://github.com/wiki-mod/distcc-ng/issues/289) as
defense-in-depth).

Landed via [wiki-mod/distcc-ng#293](https://github.com/wiki-mod/distcc-ng/pull/293).
