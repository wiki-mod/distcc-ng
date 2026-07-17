# `dcc_lock_one()`'s per-scan CPU-slot cap of 10000 is too low for large hosts

**Fork issue:** [wiki-mod/distcc-ng#72](https://github.com/wiki-mod/distcc-ng/issues/72)
**Fixed by:** [wiki-mod/distcc-ng#174](https://github.com/wiki-mod/distcc-ng/pull/174)
**Upstream location:** `src/where.c`, function `dcc_pick_host_from_list_and_lock_it()` (via `dcc_lock_one()`)
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-17)
**Searched upstream issues/PRs for:** `dcc_lock_one`, `i_cpu 10000`, `lock slot limit` — no independent report found; this fix is itself a direct port of upstream's own unmerged [distcc/distcc#349](https://github.com/distcc/distcc/pull/349), which raises the identical cap and has not been merged.

## The problem

`dcc_pick_host_from_list_and_lock_it()` scans candidate CPU "slots" for a
lockable one, capping the scan at a hardcoded `10000` iterations
(`i_cpu < 10000`). A host configured with a very large number of local/
remote CPU slots (a big distributed-build farm, or a host list with many
entries each contributing slots) can legitimately need to scan past 10000
before finding a free slot under heavy concurrent load, silently failing to
lock any host once that cap is hit — even though free slots exist beyond
the cap.

## Upstream code (unchanged as of the commit above, upstream)

`src/where.c`:

```c
for (i_cpu = 0; i_cpu < 10000; i_cpu++) {
    char i_cpu_is_usable = 0;

    for (h = hostlist; h; h = h->next) {
        if (i_cpu >= h->n_slots)
            continue;
        i_cpu_is_usable = 1;
        ret = dcc_lock_host("cpu", h, i_cpu, 0, cpu_lock_fd);
        ...
```

The cap is still the literal `10000` upstream, exactly as it was before
this fork's fix, and exactly as upstream's own unmerged PR #349 already
identified as too low.

## Fixed code (this fork, PR #174)

```c
for (i_cpu = 0; i_cpu < 50000; i_cpu++) {
```

This fork's PR ports upstream's own unmerged
[distcc/distcc#349](https://github.com/distcc/distcc/pull/349), raising the
cap from `10000` to `50000`, and brings the surrounding functions in
`src/where.c` up to this fork's function-comment convention while touching
the file.

Landed via [wiki-mod/distcc-ng#174](https://github.com/wiki-mod/distcc-ng/pull/174).
