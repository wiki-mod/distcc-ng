# Masquerade-whitelist warning ignores `DISTCC_CMDLIST` — upstream still nags after opt-in

**Fork issue:** [wiki-mod/distcc-ng#75](https://github.com/wiki-mod/distcc-ng/issues/75)
**Fixed by:** [wiki-mod/distcc-ng#205](https://github.com/wiki-mod/distcc-ng/pull/205)
**Upstream location:** `src/daemon.c`, `dcc_warn_masquerade_whitelist()`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-18)
**Searched upstream issues/PRs for:** `DISTCC_CMDLIST`, `masquerade whitelist` — found the same idea already landed upstream as [distcc/distcc#445](https://github.com/distcc/distcc/pull/445), but `master` doesn't have it.

## The problem

`dcc_warn_masquerade_whitelist()` always emits its "you must set up masquerade" critical warning (and exits with `EXIT_COMPILER_MISSING`) whenever the masquerade directory (`/usr/lib/distcc` or `LIBDIR/distcc`) is missing or empty — even when the operator has already opted in via the documented `DISTCC_CMDLIST` environment variable, which is a legitimate alternative way to tell distcc which compilers it may run/masquerade as. In that case an empty masquerade directory is expected, not a misconfiguration, but the warning doesn't know that and doesn't mention `DISTCC_CMDLIST` as a way out for operators who haven't set it yet either.

## Upstream code (unchanged as of the commit above, upstream `master`)

```c
static void dcc_warn_masquerade_whitelist(void) {
    DIR *d, *e;
    const char *warn = "You must set up masquerade" \
                       " (see distcc(1)) to list whitelisted compilers or pass" \
                       " --enable-tcp-insecure. To set up masquerade automatically" \
                       " run update-distcc-symlinks.";

    e = opendir("/usr/lib/distcc");
    d = opendir(LIBDIR "/distcc");
    if (!e && !d) {
        rs_log_crit(LIBDIR "/distcc not found. %s", warn);
        dcc_exit(EXIT_COMPILER_MISSING);
    }
    if ((!e || !readdir(e)) && (!d || !readdir(d))) {
        rs_log_crit(LIBDIR "/distcc empty. %s", warn);
        dcc_exit(EXIT_COMPILER_MISSING);
    }
    ...
```

No `DISTCC_CMDLIST` check anywhere in the function — it fires and exits unconditionally whenever the masquerade directory is missing/empty, regardless of environment.

## This fork's fix (`src/daemon.c`, `dcc_warn_masquerade_whitelist()`)

```c
static void dcc_warn_masquerade_whitelist(void) {
    DIR *d, *e;
    const char *warn = "You must set up masquerade" \
                       " (see distcc(1)) to list whitelisted compilers, set" \
                       " DISTCC_CMDLIST, or pass --enable-tcp-insecure. To set up" \
                       " masquerade automatically run update-distcc-symlinks.";

    if (getenv("DISTCC_CMDLIST")) {
        return;
    }

    e = opendir("/usr/lib/distcc");
    d = opendir(LIBDIR "/distcc");
    ...
```

Returns early when `DISTCC_CMDLIST` is set (an empty/absent masquerade directory is then expected, not a misconfiguration — see `dcc_remap_compiler()` in `src/serve.c` for how the variable is actually consumed), and the warning text itself now mentions the variable for operators who haven't set it yet.

## Note on scope: upstream already knows about this one

Same situation as `issue-073`: upstream has its own PR attempting exactly this, [distcc/distcc#445](https://github.com/distcc/distcc/pull/445), but it was never merged and `master` still has the unconditional-warning behavior today. No new bugs were found in upstream's draft this time (it's a small, self-contained change) — this entry mainly confirms the gap is still live upstream, for whatever it's worth to an upstream maintainer who revisits #445.

## Empirical verification

Real functional test (not just a read-through), per this fork's PR #205:

- With `/usr/lib/distcc` genuinely absent and `DISTCC_CMDLIST` unset: `distccd --no-detach --log-stderr` prints `CRITICAL! ... You must set up masquerade ... set DISTCC_CMDLIST, or pass --enable-tcp-insecure ...` and exits `110` (`EXIT_COMPILER_MISSING`).
- Same setup with `DISTCC_CMDLIST=cc,gcc` set: no warning, daemon starts and runs normally.

Full detail in PR #205.
