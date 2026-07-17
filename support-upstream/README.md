# Support Upstream

This directory is a passive, read-only offering to upstream
[`distcc/distcc`](https://github.com/distcc/distcc). It exists because
upstream does not accept AI-assisted contributions, and this fork does (see
`AGENTS.md`) — but a bug found and fixed here may still be a real bug in
upstream's own, independently-maintained source, whether or not upstream
ever adopts anything from this fork.

Rather than opening issues or pull requests against `distcc/distcc` (which
this fork's governance forbids unconditionally — see `AGENTS.md`'s "What Not
To Do" and the read-only rule on the upstream repository), every entry here
is a self-contained Markdown writeup that:

- names the exact file and line in upstream's current source where the
  problem lives (pinned to the upstream commit it was checked against, since
  upstream keeps moving independently of this fork),
- shows the actual "before" code and this fork's "after" fix,
- explains *why* it's a real bug, not a stylistic preference or a
  fork-specific design choice,
- and — where the finding is significant enough to warrant it — includes
  real empirical verification evidence (not just "the diff looks right"),
  typically gathered by actually building and testing both the old and
  fixed code on independent real hosts.

If an upstream maintainer or contributor ever wants to look, everything is
here to read, cited with exact file:line references and real reproducible
evidence — no upstream issue tracker noise, no pull request, no obligation
on their part to respond either way.

## Required template

Every entry documenting a bug still live in upstream (the common case)
**must** use these section headers, in this order — not a freestyle
title of similar meaning. This keeps entries scannable and comparable
without reading each one in full; `issue-012-tempfile-entropy.md` is the
canonical example to copy from:

```markdown
# <short, specific title>

**Fork issue:** [wiki-mod/distcc-ng#NN](...)
**Fixed by:** [wiki-mod/distcc-ng#NN](...)
**Upstream location:** `src/foo.c`, function `bar`
**Checked against upstream commit:** [`<sha>`](<commit url>) (`master`, checked <date>)
**Searched upstream issues/PRs for:** `<terms>` — <what was/wasn't found>

## The problem

## Upstream code (unchanged as of the commit above, upstream)

## Fixed code (changed code as of the commit from distcc-ng fork)

## Empirical verification
```

`## Empirical verification` may be omitted only when the finding is
trivial enough that no build/test evidence is needed to see it's real —
default to including it.

**Exception:** an entry that isn't documenting a still-live upstream bug
at all (e.g. `issue-063-popt-current-vendor-alternative.md`'s design-
reconsideration note, or `issue-074-lto-distribution-revert.md`'s
"upstream already fixed their own version of this" case) doesn't force-
fit this template — but must say so explicitly near the top (see those
two entries' own "Note on scope" framing) rather than silently
deviating.

## Index

| # | Fork Issue | Fixed By | Title | Upstream Status |
|---|---|---|---|---|
| 1 | [#12](https://github.com/wiki-mod/distcc-ng/issues/12) | [#19](https://github.com/wiki-mod/distcc-ng/pull/19) | [Weak temp-file name entropy in `dcc_make_tmpnam`](issue-012-tempfile-entropy.md) | Still present in upstream's live source, unreported |
| 2 | [#63](https://github.com/wiki-mod/distcc-ng/issues/63) | [#170](https://github.com/wiki-mod/distcc-ng/pull/170) | [Bundled popt fallback removed for staleness — a current-vendor alternative exists](issue-063-popt-current-vendor-alternative.md) | Not a bug — a design-reconsideration note for a deliberate past removal |
| 3 | [#179](https://github.com/wiki-mod/distcc-ng/issues/179) | [#180](https://github.com/wiki-mod/distcc-ng/pull/180) | [dcc_mkdir() lacks parent-directory (mkdir -p) creation](issue-179-mkdir-parent-dirs.md) | Still present in upstream's live source, unreported |
| 4 | [#196](https://github.com/wiki-mod/distcc-ng/issues/196) | [#198](https://github.com/wiki-mod/distcc-ng/pull/198) | [Flaky `Compile_c_Case` test: `time_ref` int-truncation races with dotd mtime under load](issue-196-flaky-compile-c-case-timing.md) | Still present in upstream's live source, unreported |
| 5 | [#73](https://github.com/wiki-mod/distcc-ng/issues/73) | [#175](https://github.com/wiki-mod/distcc-ng/pull/175) | [-march=native/-mtune=native hard-fail to local — upstream has an open, unmerged fix with real bugs of its own](issue-073-march-native-resolve.md) | Upstream `master` still hard-fails; upstream's own open PRs #350/#384 have real unfixed bugs this fork's port found |
