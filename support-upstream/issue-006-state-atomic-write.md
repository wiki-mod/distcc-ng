# Non-atomic, in-place `O_TRUNC` state-file write lets a monitor observe a truncated file

**Fork issue:** none filed separately
**Fixed by:** [wiki-mod/distcc-ng#6](https://github.com/wiki-mod/distcc-ng/pull/6)
**Upstream location:** `src/state.c`, functions `dcc_open_state()` and `dcc_note_state()`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-17)

## The problem

`dcc_note_state()` writes each compile task's current phase/status directly
into its per-process state file by opening it with `O_TRUNC` and writing the
new contents in place. This file is meant to be read concurrently by
`distccmon-text`/`distccmon-gnome` (which `opendir()` the whole state
directory and read each process's state file to show live build progress).
Because the write is `O_TRUNC`-then-write-in-place rather than
write-to-temp-then-`rename()`, a monitor can open and read the file at the
exact moment between the `O_TRUNC` (which immediately empties the file) and
the new content actually landing on disk — observing a truncated or
partially-written state record instead of either the old or new complete
one.

## Upstream code (unchanged as of the commit above, upstream)

`src/state.c`, `dcc_open_state()`:

```c
static int dcc_open_state(int *p_fd, const char *fname)
{
    int fd;

    fd = open(fname, O_CREAT|O_WRONLY|O_TRUNC|O_BINARY, 0666);
    if (fd == -1) {
        rs_log_error("failed to open %s: %s", fname, strerror(errno));
        return EXIT_IO_ERROR;
    }
    ...
```

`dcc_note_state()` calls `dcc_open_state()` directly on the real state
filename, writes the new state via `dcc_write_state()`, and closes the file
— no temporary file or `rename()` anywhere in the path.

## Fixed code (this fork, PR #6)

```c
static int dcc_write_state_file(const char *fname)
{
    char *tmp_fname;
    int fd;
    int ret;

    if ((ret = dcc_get_state_tmp_filename(fname, &tmp_fname)))
        return ret;

    if ((ret = dcc_open_state(&fd, tmp_fname))) {
        free(tmp_fname);
        return ret;
    }

    if ((ret = dcc_write_state(fd))) {
        dcc_close(fd);
        unlink(tmp_fname);
        free(tmp_fname);
        return ret;
    }

    if ((ret = dcc_close(fd))) {
        unlink(tmp_fname);
        free(tmp_fname);
        return ret;
    }

    /* Keep monitors from observing a truncated state file during updates. */
    if (rename(tmp_fname, fname) == -1) {
        rs_log_error("failed to replace %s: %s", fname, strerror(errno));
        unlink(tmp_fname);
        free(tmp_fname);
        return EXIT_IO_ERROR;
    }

    free(tmp_fname);
    return 0;
}
```

`dcc_note_state()` now calls `dcc_write_state_file(fname)` instead of
opening/writing/closing the real filename directly: the new state is
written to a `.tmp` sibling file first, and only atomically `rename()`d
into place once fully written — a monitor reading the real filename
concurrently now always sees either the complete old content or the
complete new content, never a truncated in-between state.
`dcc_remove_state_file()` was also updated to clean up any stray `.tmp`
sibling on exit.

Landed via [wiki-mod/distcc-ng#6](https://github.com/wiki-mod/distcc-ng/pull/6).
