# `distccd` never sets its Linux autogroup niceness, so `nice(2)`'s effect can be silently defeated by `setsid()`

**Fork issue:** [wiki-mod/distcc-ng#77](https://github.com/wiki-mod/distcc-ng/issues/77)
**Fixed by:** [wiki-mod/distcc-ng#279](https://github.com/wiki-mod/distcc-ng/pull/279)
**Upstream location:** `src/dparent.c`, function `dcc_detach()` (lines 343-369, `setsid()` call at lines 366-369)
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-21; exact lines confirmed via `git show 8d569d19:src/dparent.c | grep -n "setsid\|dcc_detach"`)
**Searched upstream issues/PRs for:** `autogroup` — found upstream's own **open, unmerged** PR that proposes exactly this fix: [distcc/distcc#468](https://github.com/distcc/distcc/pull/468) ("distccd: set autogroup niceness"). **Verified live via `gh api repos/distcc/distcc/pulls/468` on 2026-07-21: `state: open`, `merged: false`, last activity 2024-03-27.** This is a point-in-time observation, not a standing fact — re-check the PR's live state before citing it as still-open in any future work.

## The problem

Not a bug this fork found independently — issue #77 was opened specifically to port upstream PR #468's own fix (same situation as `issue-076-serve-prefix-map.md`). Documented here anyway per rule 57 (a support-upstream check is required on every code-changing PR), since the underlying gap — `src/dparent.c`'s current `master` has no autogroup handling at all — is a real, still-live condition in upstream's own source, not something upstream already addressed elsewhere. As of the 2026-07-21 check: **upstream has its own fix sitting open and unreviewed for close to two years** (last activity 2024-03-27); this fork adopted the underlying idea directly rather than waiting, though — see "Fixed code" below — not as a literal port of #468's diff.

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

## Known limitation: negative autogroup nice after a `--user` privilege drop

Found by a Codex review on PR #279 (`src/dparent.c:454`, "Preserve privilege for negative autogroup nice") and empirically confirmed live (root access, kernel 7.0.12, `sched_autogroup_enabled=1`): when `distccd` is started **as root** with a **negative** final niceness and `--user <unprivileged account>`, the autogroup write in `dcc_set_autogroup_niceness()` runs *after* `dcc_discard_root()` (`src/daemon.c`'s `main()`) has already permanently dropped root/`CAP_SYS_NICE` — by the time `dcc_detach()` calls `setsid()` and this function, the process can no longer lower its own (or its session's) niceness. The kernel's `proc_sched_autogroup_set_nice()` rejects the write with `EPERM`, so the new autogroup is left at `nice 0` even though the plain per-process niceness (set earlier, while still root) is correctly negative:

```
sudo ./distccd -N -5 --user nobody --daemon --allow 127.0.0.1 --port 43334 --log-file /tmp/distccd_test.log --log-level debug
```
```
distccd[1673816] (dcc_detach) setsid to session 1673816
distccd[1673816] (dcc_set_autogroup_niceness) autogroup niceness: -5
distccd[1673816] (dcc_set_autogroup_niceness) Warning: autogroup nice -5 failed: Operation not permitted
```
`/proc/<pid>/autogroup` reads `nice 0` after startup; `ps -o pid,ni,cmd` for the same pid shows the real process `NI` as `-5` — so only the autogroup write is rejected, not the plain per-process niceness.

This is a real, reproducible gap, but not a silent one: the existing `rs_log_warning` in `dcc_set_autogroup_niceness()` already surfaces it, which is why this is tracked here as a **known, deliberate limitation** rather than fixed in PR #279 itself. Fix options considered on the PR #279 review thread: (1) restructure `dcc_detach()`'s fork/`setsid()`/privilege-drop ordering — rejected as too invasive, risks the documented "errors go to stdout before detach" behavior and classic double-fork daemonization semantics; (2) retain `CAP_SYS_NICE` across the privilege drop via `prctl(PR_SET_KEEPCAPS)`/`capset()` — a nontrivial, security-sensitive change to `src/setuid.c` needing either a new `libcap` dependency (compatibility-policy sign-off) or hand-rolled raw capability syscalls. Neither has been decided on by the maintainer as of this writing; the PR #279 review thread is left open pending that decision, not resolved.

**Test coverage**: `test/testdistcc.py`'s `AutogroupNicenessPrivilegeDrop_Case` (root-only, Linux-only, skips everywhere else via `require_root()`/`sys.platform` checks) starts a real `distccd -N -5 --user nobody --daemon`, reads `/proc/<pid>/autogroup` directly, and asserts the write is rejected (`nice 0`) with the expected `Operation not permitted` warning in the daemon log — i.e. it documents and pins down *current* behavior, it does not fix it. If either fix option above is ever implemented, this test's assertions (and this section) need updating to match, not silencing.
