# distccd: unvalidated client-supplied CDIR allows path traversal in make_temp_dir_and_chdir_for_cpp()

**Fork issue:** [wiki-mod/distcc-ng#100](https://github.com/wiki-mod/distcc-ng/issues/100)
**Fixed by:** [wiki-mod/distcc-ng#103](https://github.com/wiki-mod/distcc-ng/pull/103)
**Upstream location:** `src/serve.c`, `make_temp_dir_and_chdir_for_cpp()`
**Checked against upstream commit:** [`17b29cc3`](https://github.com/distcc/distcc/commit/17b29cc3e3581abd3c6c114a7f4274b34a7f7907) (latest commit touching `src/serve.c`, `master`, checked 2026-07-17)
**Searched upstream issues/PRs for:** `CDIR path traversal`, `make_temp_dir_and_chdir_for_cpp`, `server_side_cwd`, `distccd chdir traversal` — no matching report or fix attempt found, open or closed.

## The problem

`distccd` reads the client's current working directory (`CDIR`) over the
wire via `dcc_r_cwd()` and concatenates it directly onto the server's own
per-job temp directory to build `server_side_cwd`, which it then
`mkdir`s and `chdir()`s into. `CDIR` is client-controlled and, before this
fix, was never validated: a crafted `CDIR` containing `..` components
(e.g. `../../etc`) could walk the resulting concatenated path outside the
server's intended temp directory, letting the daemon create directories
and `chdir()` into arbitrary locations it has permission to reach. This
parallels the separate `NAME` traversal issue in `dcc_r_many_files()` (see
`issue-093-name-path-traversal.md`) but is a distinct code path with its
own separate client-controlled token.

## Upstream code (unchanged as of the commit above, upstream `master`)

`src/serve.c`, `make_temp_dir_and_chdir_for_cpp()`:

```c
static int make_temp_dir_and_chdir_for_cpp(int in_fd,
        char **temp_dir, char **client_side_cwd, char **server_side_cwd)
{

        int ret = 0;

        if ((ret = dcc_get_new_tmpdir(temp_dir)))
            return ret;
        if ((ret = dcc_r_cwd(in_fd, client_side_cwd)))
            return ret;

        checked_asprintf(server_side_cwd, "%s%s", *temp_dir, *client_side_cwd);
        if (*server_side_cwd == NULL) {
            ret = EXIT_OUT_OF_MEMORY;
        } else if ((ret = dcc_mk_tmp_ancestor_dirs(*server_side_cwd))) {
            ; /* leave ret the way it is */
        } else if ((ret = dcc_mk_tmpdir(*server_side_cwd))) {
            ; /* leave ret the way it is */
        } else if (chdir(*server_side_cwd) == -1) {
            ret = EXIT_IO_ERROR;
        }
        return ret;
```

`*client_side_cwd` (the raw `CDIR` value read straight from the socket) is
concatenated into `server_side_cwd` with no validation whatsoever between
the `dcc_r_cwd()` read and the `checked_asprintf()` call — identical to
this fork's own pre-fix code.

## Fixed code (this fork, PR #103)

Extends the same `src/pathsafety.c`/`.h` pair added for the `NAME` fix
(PR #94) with a CDIR-specific check, `dcc_cdir_has_path_traversal()`
(CDIR, unlike NAME, is not required to be absolute, so its safety rule
differs slightly — it only rejects embedded/leading/trailing `..`
components, not "must start with `/`"):

```c
int dcc_cdir_has_path_traversal(const char *cdir)
{
    size_t len = strlen(cdir);

    /* Reject ".." as the entire path */
    if (strcmp(cdir, "..") == 0)
        return 1;

    /* Reject ".." as a leading path component in relative paths (e.g., "../foo") */
    if (len >= 3 && strncmp(cdir, "../", 3) == 0)
        return 1;

    /* Reject ".." as an embedded path component (e.g., "a/../b" or "a/../../c") */
    if (strstr(cdir, "/../") != NULL)
        return 1;

    /* Reject ".." as a trailing path component (e.g., "a/.." or "/a/..") */
    if (len >= 3 && strcmp(cdir + len - 3, "/..") == 0)
        return 1;

    return 0;
}
```

`make_temp_dir_and_chdir_for_cpp()` now calls this immediately after
`dcc_r_cwd()` and rejects the request with `EXIT_PROTOCOL_ERROR` before the
`checked_asprintf()` concatenation ever runs:

```c
if ((ret = dcc_r_cwd(in_fd, client_side_cwd)))
    return ret;

/* Validate the client-supplied working directory to prevent
 * directory traversal attacks. If the CDIR token contains "..",
 * reject the request immediately. */
if (dcc_cdir_has_path_traversal(*client_side_cwd)) {
    rs_log_error("rejected CDIR with a path-traversal sequence "
                 "(must not contain '..'): %s",
                 *client_side_cwd);
    return EXIT_PROTOCOL_ERROR;
}

checked_asprintf(server_side_cwd, "%s%s", *temp_dir, *client_side_cwd);
```

Landed via [wiki-mod/distcc-ng#103](https://github.com/wiki-mod/distcc-ng/pull/103).
