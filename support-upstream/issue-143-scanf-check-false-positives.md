# CodeQL `cpp/missing-check-scanf` on `dcc_get_proc_meminfo_mem_available` / `dcc_get_disk_io_stats` — analysis-confirmed false positives

**Note on scope:** this is **not** a still-live upstream bug. It is a
non-bug entry (see this folder's README "Exception" clause and
`issue-225-zstd-protover-guard.md` / `issue-074-lto-distribution-revert.md`
for the same framing). It is included only because rule 57 requires every
code-changing PR to record the upstream cross-check, and the flagged code is
byte-for-byte identical in upstream's live source — so if upstream ever runs
CodeQL's `security-extended` suite it will see the same two alerts, and this
entry documents that they are false positives plus the optional defensive
hardening this fork applied.

**Fork issue:** [wiki-mod/distcc-ng#143](https://github.com/wiki-mod/distcc-ng/issues/143) (Group G)
**Fixed by:** [wiki-mod/distcc-ng#253](https://github.com/wiki-mod/distcc-ng/pull/253) — defensive hardening only, no behavioural change
**Upstream location:** `src/util.c`, functions `dcc_get_proc_meminfo_mem_available()` and `dcc_get_disk_io_stats()`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-18)
**Searched upstream issues/PRs for:** `scanf return value`, `meminfo`, `diskstats`, `CodeQL util.c` — no upstream report found; upstream does not appear to run CodeQL on this code.

## Why these are false positives, not bugs

CodeQL flags two reads with *"This variable is read, but may not have been
written. It should be guarded by a check that the call to (f)scanf returns at
least N."* In both sites the guard exists; CodeQL's definite-assignment model
just does not carry the guard fact across the intervening `break`.

### `dcc_get_proc_meminfo_mem_available()` — `value`/`unit` read at `mem_available = value;`

```c
while (fgets(line, sizeof(line), f) != NULL) {
    if (sscanf(line, "%127s %ld %4s", key, &value, unit) != 3)
        continue;
    if (strncmp(key, "MemAvailable:", sizeof("MemAvailable:")) == 0)
        break;
}
if (feof(f) || ferror(f)) {
    fclose(f);
    return -1;
}
fclose(f);
mem_available = value;      /* flagged read */
magnitude = unit[0];
```

The flagged line is reachable **only** through the `break`, which fires
strictly after `sscanf(...) == 3` has just written `value` and `unit` on that
same iteration. The only other loop exit is `fgets()` returning NULL — which
happens exclusively at EOF or read error (C stdio guarantees `fgets` returns
NULL only in those cases, always setting `feof`/`ferror`), and the
`feof || ferror` guard returns `-1` before the flagged line. The zero-line
(empty-file) case is the same NULL/`feof` path. So `value`/`unit` are never
read uninitialised.

### `dcc_get_disk_io_stats()` — `minor`/`dev` read at the `if (minor % 64 == 0 ...)` line

```c
while (1) {
    if (kernel26)
        retval = fscanf(f, " %*d %d %s", &minor, dev);
    else
        retval = fscanf(f, " %*d %d %*d %s", &minor, dev);
    if (retval == EOF || retval != 2)
        break;
    if (minor % 64 == 0                /* flagged read of minor + dev */
            && ((dev[0] == 'h' && dev[1] == 'd' && dev[2] == 'a')
                || (dev[0] == 's' && dev[1] == 'd' && dev[2] == 'a'))) {
        ...
```

`fscanf` is the first statement of every iteration; the guard
`if (retval == EOF || retval != 2) break;` means the fall-through to the
flagged read implies `retval == 2`, i.e. both `minor` and `dev` were written.
A textbook guarded use.

## Defensive hardening applied in this fork (optional for upstream)

No behavioural change. The flagged locals are initialised at declaration so
the functions stay safe even if a future refactor breaks the control-flow
invariant above, and the CodeQL false positives are silenced:

```c
/* dcc_get_proc_meminfo_mem_available() */
long value = 0;
char unit[5] = "";

/* dcc_get_disk_io_stats() */
int minor = 0;
char dev[100] = "";
```

Each carries a WHY-comment in the source explaining that the read is already
unreachable-when-unwritten and that the initialisation is defence-in-depth.

## Note on a genuinely separate item

`dcc_get_disk_io_stats()` also uses an **unbounded** `%s` conversion into
`char dev[100]` at the two `fscanf` calls above. That is a distinct issue
class (`cpp/unbounded-write`, not `missing-check-scanf`); the input comes from
root-controlled `/proc`, CodeQL does not currently flag it, and it is
deliberately left out of the Group G change per rule 58. Recorded here only so
the observation is not lost; it is identical in upstream's live source.
