# `-iquote` is never stripped from remote compile arguments in `dcc_strip_local_args()`

**Fork issue:** none filed separately (see upstream reports below)
**Fixed by:** [wiki-mod/distcc-ng#3](https://github.com/wiki-mod/distcc-ng/pull/3)
**Upstream location:** `src/strip.c`, function `dcc_strip_local_args()`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-17)
**Also reported upstream (read-only reference):** [distcc/distcc#582](https://github.com/distcc/distcc/issues/582) ("pump: local include-search arguments can leak into remote compile argv") and [distcc/distcc#504](https://github.com/distcc/distcc/issues/504) ("distcc incorrectly claims that iquote parameter is not used with clang++ 16, breaking my -Werror build") — #582 closed by its own reporter without a fix landing; #504 still open.

## The problem

`dcc_strip_local_args()` strips compiler flags that only make sense on the
local machine (because they reference local filesystem paths) before
shipping the remaining arguments to the remote compile host — `-I`,
`-isystem`, `-iwithprefixbefore`, `-idirafter`, etc. are all handled. `-iquote
<dir>` (GCC/Clang's "quote-only" local include-search flag, functionally the
same class of local-path option as `-I`) is missing from this list entirely,
so it is not stripped and is sent to the remote compiler as-is, where the
referenced local directory typically does not exist. Depending on the
remote toolchain this either silently no-ops the search path (functional
divergence between local and distributed builds) or breaks a build using
`-Werror` when the remote compiler warns about the unresolvable path.

## Upstream code (unchanged as of the commit above, upstream)

`src/strip.c`, `dcc_strip_local_args()`:

```c
if (str_equal("-D", from[from_i])
    || str_equal("-I", from[from_i])
    || str_equal("-U", from[from_i])
    || str_equal("-L", from[from_i])
    || str_equal("-l", from[from_i])
    || str_equal("-MF", from[from_i])
    || str_equal("-MT", from[from_i])
    || str_equal("-MQ", from[from_i])
    || str_equal("-include", from[from_i])
    || str_equal("-imacros", from[from_i])
    || str_equal("-iprefix", from[from_i])
    || str_equal("-isystem", from[from_i])
    || str_equal("-iwithprefixbefore", from[from_i])
    || str_equal("-idirafter", from[from_i])
    || str_equal("-Xpreprocessor", from[from_i])) {
    /* skip next word, being option argument */
    ...
```

No `-iquote` anywhere in either the `str_equal` (space-separated form) or
`str_startswith` (`-iquote<dir>` glued form) checks in this function.

## Fixed code (this fork, PR #3)

```c
if (str_equal("-D", from[from_i])
    ...
    || str_equal("-idirafter", from[from_i])
    || str_equal("-iquote", from[from_i])
    || str_equal("-Xpreprocessor", from[from_i])) {
    ...
} else if (str_startswith("-D", from[from_i])
             ...
             || str_startswith("-isystem", from[from_i])
             || str_startswith("-iquote", from[from_i])
             || str_startswith("-stdlib", from[from_i])) {
    ...
```

Both the space-separated (`-iquote <dir>`) and glued (`-iquote<dir>`) forms
of the flag are now stripped, matching how `-isystem`/`-idirafter` are
already handled. A new pair of cases were added to the existing
`StripArgs_Case` regression test in `test/testdistcc.py` covering both
forms.

Landed via [wiki-mod/distcc-ng#3](https://github.com/wiki-mod/distcc-ng/pull/3).
