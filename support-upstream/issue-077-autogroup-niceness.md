# `distccd` never sets its Linux autogroup niceness, so `nice(2)`'s effect can be silently defeated by `setsid()`

**Fork issue:** [wiki-mod/distcc-ng#77](https://github.com/wiki-mod/distcc-ng/issues/77)
**Fixed by:** [wiki-mod/distcc-ng#279](https://github.com/wiki-mod/distcc-ng/pull/279)
**Upstream location:** `src/dparent.c`, function `dcc_detach()`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-21)
**Searched upstream issues/PRs for:** `autogroup` — found upstream's own **open, unmerged** PR that proposes exactly this fix: [distcc/distcc#468](https://github.com/distcc/distcc/pull/468) ("distccd: set autogroup niceness"). **Verified live via `gh api repos/distcc/distcc/pulls/468` on 2026-07-21: `state: open`, `merged: false`, last activity 2024-03-27.** This is a point-in-time observation, not a standing fact — re-check the PR's live state before citing it as still-open in any future work.

## Note on scope: an open upstream PR, not a fork-only finding

Same situation as `issue-076-serve-prefix-map.md`: issue #77 was opened specifically to port upstream PR #468's own fix, not from an independently-found fork bug. Documented here anyway per rule 57 (a support-upstream check is required on every code-changing PR), and the underlying gap — `src/dparent.c`'s current `master` has no autogroup handling at all — is a real, still-live condition in upstream's own source, not something upstream already addressed elsewhere. As of the 2026-07-21 check: **upstream has its own fix sitting open and unreviewed for close to two years** (last activity 2024-03-27); this fork adopted the underlying idea directly rather than waiting, though — see below — not as a literal port of #468's diff.

## The problem

`distccd`'s `main()` (`src/daemon.c`) calls `nice(opt_niceness)` early, before dropping root, to give the whole daemon process a lower CPU scheduling priority than interactive/foreground work on the same host — the sensible default for a background compile-farm daemon. But `dcc_detach()` (`src/dparent.c`) later calls `setsid()` to daemonize, and on a kernel with Linux's autogroup scheduling enabled (the default on most modern distros), `setsid()` allocates a **brand-new autogroup for the new session, starting at niceness 0** — independent of the per-process nice value already set. Autogroup scheduling ranks *groups* of processes (roughly: sessions) against each other first, then niceness within a group second; since the daemon's session was just reset to autogroup-niceness 0, the earlier `nice(2)` call only affects how the daemon's own child processes rank against each other, not how the daemon's session as a whole competes against an interactive user's shell session on the same machine — silently defeating the whole point of niceing the daemon in the first place.

## Upstream code (unchanged as of the commit above, upstream)

```c
#ifdef HAVE_SETSID
    if ((sid = setsid()) == -1) {
        rs_log_error("setsid failed: %s", strerror(errno));
    } else {
        rs_trace("setsid to session %d", (int) sid);
    }
#else
```

No autogroup handling anywhere in `dcc_detach()` or elsewhere in upstream's tree.

## Fixed code (this fork, PR #279)

Adds `dcc_set_autogroup_niceness(void)` in `src/dparent.c`, called immediately after a successful `setsid()`. Unlike upstream PR #468's own diff (which passes the raw `-N`/`opt_niceness` CLI value straight into the autogroup write), this fork's version reads the **actual, final process niceness via `getpriority(PRIO_PROCESS, 0)`** after `main()`'s earlier `nice(opt_niceness)` call, rather than trusting the raw option value:

```c
static void dcc_set_autogroup_niceness(void)
{
#ifdef HAVE_LINUX
    FILE *fp;
    int error = 0;
    int niceness;

    errno = 0;
    niceness = getpriority(PRIO_PROCESS, 0);
    if (niceness == -1 && errno != 0) {
        rs_log_warning("getpriority failed: %s", strerror(errno));
        return;
    }

    fp = fopen("/proc/self/autogroup", "r+");
    if (fp) {
        if (fprintf(fp, "%d\n", niceness) < 0) {
            error = errno;
        } else {
            rs_trace("autogroup niceness: %d", niceness);
        }
        if (fclose(fp) == EOF && !error)
            error = errno;
    } else if (errno != ENOENT) {
        error = errno;
    }
    if (error)
        rs_log_warning("autogroup nice %d failed: %s", niceness, strerror(error));
#endif
}
```

### Why not just port #468's diff directly

`-N`/`opt_niceness` is documented (`distccd.1`) as an **increment** applied on top of whatever niceness the daemon process already has, and POSIX `nice(2)` clamps the resulting value to `[-20,19]`. Both facts mean the raw CLI option value can diverge from the process's real, final niceness in either direction: `distccd -N 20` gets clamped by `nice(2)` to a real niceness of 19, but writing the raw `20` into `/proc/self/autogroup` (which enforces the same `[-20,19]` range) fails with `EINVAL`; `nice -n 10 distccd -N 5` ends up at a real niceness of 15 (10 inherited + 5 requested), but writing the raw `5` would autogroup the daemon far less aggressively than its actual scheduling priority. Reading the value back via `getpriority()` after `nice()` has already run sidesteps both cases structurally, rather than requiring the caller to duplicate `nice(2)`'s own clamping/increment arithmetic. (`getpriority()` legitimately returns `-1` for a process at real niceness `-1`, so `errno` is cleared before the call and checked after, per its own man page, to distinguish that from a genuine failure.)

## Empirical verification

Built and tested on a real Linux host: `distccd -N 7` (no inherited niceness) showed `/proc/<pid>/autogroup` reporting `nice 7`, matching `getpriority()`'s post-`nice(2)` value, confirmed via the daemon's own `autogroup niceness: 7` trace line. `make check` passes cleanly on both the Linux (`HAVE_LINUX`) and non-Linux (compiled with `-UHAVE_LINUX -Wunused-parameter -Werror` to confirm no dead-parameter warning) code paths.
