# Several `distccd`/`lsdistcc` files are created world-writable (mode `0666`) with no local-tampering justification

**Fork issue:** [wiki-mod/distcc-ng#157](https://github.com/wiki-mod/distcc-ng/issues/157)
**Fixed by:** [wiki-mod/distcc-ng#158](https://github.com/wiki-mod/distcc-ng/pull/158)
**Upstream location:** `src/compile.c` (`dcc_note_discrepancy()`), `src/daemon.c` (`dcc_setup_real_log()`), `src/dparent.c` (`dcc_save_pid()`), `src/state.c` (`dcc_open_state()`), `src/zeroconf.c` (three call sites: daemon lock file, daemon host file, client-side lock file)
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-17)
**Searched upstream issues/PRs for:** `world-writable`, `0666`, `distccd log permission`, `pid file permission` — no matching report or fix attempt found, open or closed.

## The problem

Several files `distccd`/`lsdistcc` create on disk are opened with an
explicit `0666` mode (or `fopen()`'s implicit `0666` default), meaning
under a permissive/zero umask (plausible for a long-running daemon) any
other local user on the same host can *write* to them, not just read them:

- the daemon's own log file (`dcc_setup_real_log()`) — can contain client
  hostnames, compiler command lines, and file paths; a second local user
  should not be able to tamper with it,
- the daemon's pid file (`dcc_save_pid()`) — writable by any local user,
- a per-user discrepancy counter (`dcc_note_discrepancy()`) — meant to be
  private per-user, not shared,
- the per-process state file (`dcc_open_state()`) — read cross-user by
  `distccmon-text`/`distccmon-gnome` (a legitimate, documented
  shared-build-cluster monitoring use case — see `man distcc.1` — so
  world-*read* is correct by design here, but world-*write* is not),
  and
- the zeroconf daemon's lock file and discovered-host file, plus the
  zeroconf client-side lock file, all in `src/zeroconf.c` — the discovered-
  host file is legitimately read by every user's `distcc` invocations
  (again by design), but none of these need to be world-*writable*.

This matches CodeQL's `cpp/world-writable-file-creation` rule class. Two
related call sites this fork's own PR deliberately left at `0666` are
**not** included here since they are correct by design, not a bug:
`src/bulk.c`'s received-compiler-output file (must reproduce the same
permissions a real local compile would give it) and `src/lock.c`'s
lock-slot file (intentionally shared across users in a multi-user
`DISTCC_DIR` — see the separate `issue-159-lock-umask-fchmod.md` entry for
that file's own distinct umask-related bug).

## Upstream code (unchanged as of the commit above, upstream)

`src/compile.c`, `dcc_note_discrepancy()`:
```c
if (!(discrepancy_file = fopen(discrepancy_filename, "a"))) {
```

`src/daemon.c`, `dcc_setup_real_log()`:
```c
if ((fd = open(arg_log_file, O_CREAT|O_APPEND|O_WRONLY, 0666)) == -1) {
```

`src/dparent.c`, `dcc_save_pid()`:
```c
if (!(fp = fopen(arg_pid_file, "wt"))) {
```

`src/state.c`, `dcc_open_state()`:
```c
fd = open(fname, O_CREAT|O_WRONLY|O_TRUNC|O_BINARY, 0666);
```

`src/zeroconf.c`, three call sites:
```c
if ((lock_fd = open(lock_file, O_RDWR|O_CREAT, 0666)) < 0) {   /* daemon_proc(), lock file */
...
if ((d.fd = open(host_file, O_RDWR|O_CREAT, 0666)) < 0) {      /* daemon_proc(), host file */
...
if ((lock_fd = open(lock_file, O_RDWR|O_CREAT, 0666)) < 0) {   /* dcc_zeroconf_add_hosts(), client lock */
```

All six sites still create at (or default to) `0666` with no mode-narrowing
of any kind.

## Fixed code (this fork, PR #158)

Each site now uses an explicit, deliberately-chosen mode instead of the
umask-modified `0666` default — switching `fopen()` calls to
`open()`+`fdopen()` where an explicit mode is needed:

```c
/* src/compile.c, dcc_note_discrepancy(): private per-user counter -> 0600 */
fd = open(discrepancy_filename, O_WRONLY|O_APPEND|O_CREAT, 0600);
...
discrepancy_file = fdopen(fd, "a");

/* src/daemon.c, dcc_setup_real_log(): can contain hostnames/cmdlines -> 0600 */
fd = open(arg_log_file, O_CREAT|O_APPEND|O_WRONLY, 0600);

/* src/dparent.c, dcc_save_pid(): readable by monitoring tools, not writable -> 0644 */
fd = open(arg_pid_file, O_WRONLY|O_CREAT|O_TRUNC, 0644);
...
fp = fdopen(fd, "wt");

/* src/state.c, dcc_open_state(): keep world-read for distccmon-*, drop world-write -> 0644 */
fd = open(fname, O_CREAT|O_WRONLY|O_TRUNC|O_BINARY, 0644);

/* src/zeroconf.c: daemon's own coordination lock -> 0600 */
lock_fd = open(lock_file, O_RDWR|O_CREAT, 0600);
/* src/zeroconf.c: discovered-host file, kept world-read for every client -> 0644 */
d.fd = open(host_file, O_RDWR|O_CREAT, 0644);
/* src/zeroconf.c: client-side coordination lock -> 0600 */
lock_fd = open(lock_file, O_RDWR|O_CREAT, 0600);
```

Only the world-*write* bit is dropped where CodeQL actually flagged it;
`state.c`'s state file and `zeroconf.c`'s discovered-host file deliberately
keep world-*read* (`0644`) since both have a legitimate documented
cross-user reader (`distccmon-*` and every local `distcc` invocation,
respectively) — narrowing further would silently break the
shared-build-cluster deployment this fork documents in `man distcc.1`.

Landed via [wiki-mod/distcc-ng#158](https://github.com/wiki-mod/distcc-ng/pull/158).
