# A bare `/* fallthrough */` comment is invisible once distcc preprocesses its own source for a distributed self-build

**Fork issue:** [wiki-mod/distcc-ng#22](https://github.com/wiki-mod/distcc-ng/issues/22)
**Fixed by:** [wiki-mod/distcc-ng#23](https://github.com/wiki-mod/distcc-ng/pull/23)
**Upstream location:** `src/stats.c` (`dcc_stats_process()`) and `src/util.c` (`dcc_get_proc_meminfo_mem_available()`)
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-17)
**Searched upstream issues/PRs for:** `fallthrough`, `Wimplicit-fallthrough` — found [distcc/distcc#242](https://github.com/distcc/distcc/issues/242) ("-Wimplicit-fallthrough warnings", still open, describing this exact mechanism: "`-Wimplicit-fallthrough` will usually ignore lines which have comments. The way distcc works it strips those comments, which makes this warnings appear."), unaddressed since filing. Also found the historical origin of the bare-comment marker itself: [distcc/distcc#207](https://github.com/distcc/distcc/pull/207) ("Add fallthrough comment to avoid GCC 7 error", merged) — the very comment this bug shows is not actually effective for a distcc-distributed build.

## The problem

GCC's `-Wimplicit-fallthrough` accepts a bare `/* fallthrough */` comment as
an intentional-fallthrough marker, but only because its *own preprocessing
pass sees the comment in the source it is compiling*. distcc's entire
purpose is to preprocess client-side and ship the client-preprocessed
(comment-stripped) source to the remote compile server — so when distcc (or
any project) builds itself, or any of its own source, *through* distcc/pump
with `-Wimplicit-fallthrough -Werror` enabled, the remote compiler never
sees the comment (comments do not survive preprocessing) and treats the
fallthrough as unintentional, failing the build. A purely local,
non-distributed build of the identical source does not hit this, since the
local compiler preprocesses and compiles in one invocation and still sees
the original comment. This produced real, previously-unexplained remote
compile failures in this fork's own CI (`ERROR: compile src/util.c ...
failed`, `ERROR: compile src/stats.c ... failed`), silently masked by
distcc's retry-locally-on-discrepancy fallback until the fallback path was
itself scrutinized.

## Upstream code (unchanged as of the commit above, upstream)

`src/stats.c`, `dcc_stats_process()`:

```c
case STATS_COMPILE_OK:
    dcc_stats_update_compile_times(sd);
    /* fallthrough */
case STATS_COMPILE_ERROR:
```

`src/util.c`, `dcc_get_proc_meminfo_mem_available()`:

```c
switch (magnitude) {
    case 'T':
        mem_available *= 1024;
        /* fallthrough */
    case 'G':
        mem_available *= 1024;
        /* fallthrough */
    case 'M':
        break;
```

Both still rely on the bare comment form; `src/distcc.h` has no
`__attribute__((fallthrough))`-based macro anywhere.

## Fixed code (this fork, PR #23)

`src/distcc.h` gains a `FALLTHROUGH` macro that survives preprocessing
(an attribute, not a comment):

```c
/* Marks an intentional switch-case fallthrough. A bare fallthrough
 * comment only works when gcc's own fallthrough heuristic sees the comment
 * in the source it is compiling -- but distcc ships a client-preprocessed,
 * comment-free source file to the compile server, so the same code compiled
 * through distcc loses the comment and -Wimplicit-fallthrough (part of -W /
 * -Wextra) fires there under -Werror even though a local, non-distributed
 * build of the identical source does not. An attribute survives
 * preprocessing (it isn't a comment), so it works identically whether the
 * file is compiled directly or via distcc. */
#if defined(__GNUC__) && __GNUC__ >= 7
#  define FALLTHROUGH __attribute__((fallthrough))
#else
#  define FALLTHROUGH ((void) 0)
#endif
```

Both call sites in `src/stats.c` and `src/util.c` replace `/* fallthrough
*/` with `FALLTHROUGH;`.

Landed via [wiki-mod/distcc-ng#23](https://github.com/wiki-mod/distcc-ng/pull/23).
