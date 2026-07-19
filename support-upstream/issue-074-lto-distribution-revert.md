# Skip distributing LTO invocations — upstream tried this exact idea, then reverted it with contradicting evidence

**Fork issue:** [wiki-mod/distcc-ng#74](https://github.com/wiki-mod/distcc-ng/issues/74)
**Fixed by:** [wiki-mod/distcc-ng#204](https://github.com/wiki-mod/distcc-ng/pull/204), made configurable by [wiki-mod/distcc-ng#207](https://github.com/wiki-mod/distcc-ng/pull/207) (this entry documents the finding that motivated #207, not a live upstream bug)
**Upstream location:** `src/arg.c`, `dcc_scan_args()`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-18)
**Searched upstream issues/PRs for:** `flto`, `LTO` — found upstream's own PR that did exactly this: [distcc/distcc#413](https://github.com/distcc/distcc/pull/413), merged 2021-03-11 (`8dacd28d`), then **reverted** the same day (`47a19b96`).

## Note on scope: this is not a "still-broken upstream" entry

Every other entry in this folder documents a bug that's still live in upstream's current source, unfixed. This one is different, and is being recorded for the opposite reason: **upstream tried this fork's exact idea, and their own maintainers reverted it with real, measured evidence that it was wrong.** This fork's PR #204 (skip distributing `-flto`/`-flto=` invocations, treating them as local-only) shipped with the same "not worth distributing" premise upstream's PR #413 had — before upstream found out empirically that the premise doesn't hold.

## The claim PR #204 (and upstream's #413) made

> LTO defers the bulk of the optimization work to link time, so distributing the per-translation-unit compile step wastes network/scheduling overhead for no benefit, and some LTO intermediate representations aren't valid standalone object files, so a remote invocation could produce an unusable result.

## Upstream's revert, and why

Commit `47a19b96` reverts `8dacd28d` ("Skip distributing LTO cc invocations", upstream PR #413) with this message:

```
Revert "Skip distributing LTO cc invocations"

This reverts commit 8dacd28d888210753e9457eb31175d8e2a1c348e.
The "LTO invocations are not worth distributing" statement is in
general wrong. GCC generates the (target) machine code for every
compilation unit even with `-flto` (so it makes sense to distribute
these). And the whole program analysis is not guaranteed to be
the bottleneck of the build. As a matter of fact distributing
LTO compilations reduces the build time of LLVM/clang, GCC, and
other programs (especially C++ ones).

Closes: #428
```

In other words: the premise that LTO compiles are "just deferred work with no real per-TU output" is factually wrong for GCC's actual `-flto` implementation, and upstream's own maintainers measured a **real build-time improvement** from distributing these compiles on real, large C++ projects (LLVM/clang, GCC itself), not the waste PR #413 (and this fork's #204) assumed.

## What this fork did in response (issue #207)

Rather than reverting #204 outright (a genuine "not worth distributing" case may still exist for some toolchains/LTO modes this fork's users actually run — the point of upstream's revert is that it's not true *in general*, not that it's never true), #204's unconditional local-only forcing was made an opt-in, off-by-default setting (`local-lto` in the new `/etc/distcc/distcc.conf`, or `DISTCC_LOCAL_LTO`) — defaulting to upstream's current, evidence-based behavior (distribute normally), while still letting an operator opt into the fork's original assumption for their own environment if their own measurements support it, rather than assuming it's universally true.

## Empirical verification

See PR #207's own validation section for the real build/functional verification of the new configurable behavior. This entry's own claim (that upstream reverted #413 for the reason quoted above) is independently verifiable via `gh api repos/distcc/distcc/commits?path=src/arg.c` on this fork's side, or directly on GitHub at the commit URLs above.
