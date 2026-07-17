# NULL-pointer dereference pruning the stats list's head entry in `dcc_stats_update_compile_times()`

**Fork issue:** none filed separately (see upstream report below)
**Fixed by:** [wiki-mod/distcc-ng#4](https://github.com/wiki-mod/distcc-ng/pull/4)
**Upstream location:** `src/stats.c`, function `dcc_stats_update_compile_times()`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-17)
**Also reported upstream (read-only reference):** [distcc/distcc#585](https://github.com/distcc/distcc/issues/585) ("distccd: stale stats entries can affect job accounting") — closed by its own reporter without a fix landing ("since it seems my efforts are not liked, i will close it").

## The problem

`dcc_stats_update_compile_times()` maintains a singly-linked list of recent
compile-time samples (`dcc_stats.sd_root`) and prunes entries older than two
minutes on every call. The prune loop frees a stale node and then advances
`curr_sd` by reading `prev_sd->next` — but when the *just-inserted head*
entry itself is the one being pruned (i.e. `prev_sd` is still `NULL`, since
the loop hasn't advanced past it yet), the code takes the `prev_sd == NULL`
branch to unlink the head, frees `curr_sd`, and then unconditionally
dereferences `prev_sd->next` — which is a NULL-pointer dereference, since
`prev_sd` is still `NULL` at that point.

This is reachable whenever `dcc_stats_update_compile_times()` is called with
a `sd->stop` timestamp already more than two minutes old — plausible under a
backlogged/async stats pipe, clock skew, or simply a burst of stats records
processed with a delay — crashing `distccd`'s stats-maintenance path.

## Upstream code (unchanged as of the commit above, upstream)

`src/stats.c`, `dcc_stats_update_compile_times()`:

```c
/* drop elements older than 2min */
curr_sd = dcc_stats.sd_root;
while (curr_sd != NULL) {
    if (curr_sd->stop.tv_sec < two_min_ago) {
        /* delete the stat */
        if (prev_sd == NULL) {
            dcc_stats.sd_root = curr_sd->next;
        } else {
            prev_sd->next = curr_sd->next;
        }
        free(curr_sd);
        curr_sd = prev_sd->next;
    } else {
        /* we didn't delete anything. move forward by one */
        prev_sd = curr_sd;
        curr_sd = curr_sd->next;
    }
}
```

When the `prev_sd == NULL` branch is taken (pruning the head), the very next
line still unconditionally evaluates `prev_sd->next` — dereferencing the
NULL pointer that was just checked two lines above.

## Fixed code (this fork, PR #4)

```c
curr_sd = dcc_stats.sd_root;
while (curr_sd != NULL) {
    if (curr_sd->stop.tv_sec < two_min_ago) {
        /* delete the stat */
        struct statsdata *next_sd = curr_sd->next;
        if (prev_sd == NULL) {
            dcc_stats.sd_root = next_sd;
        } else {
            prev_sd->next = next_sd;
        }
        free(curr_sd);
        curr_sd = next_sd;
    } else {
        prev_sd = curr_sd;
        curr_sd = curr_sd->next;
    }
}
```

`curr_sd->next` is captured into a local (`next_sd`) *before* `curr_sd` is
freed, and used directly instead of re-reading it through `prev_sd`, which
may legitimately still be `NULL`. A new `TEST`-only unit
(`dcc_stats_test_prune_old_head()` in `src/h_stats.c`/`src/stats.c`)
exercises exactly this head-pruning path.

Landed via [wiki-mod/distcc-ng#4](https://github.com/wiki-mod/distcc-ng/pull/4).
