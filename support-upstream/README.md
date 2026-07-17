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

## Index

| # | Fork Issue | Fixed By | Title | Upstream Status |
|---|---|---|---|---|
| 1 | [#12](https://github.com/wiki-mod/distcc-ng/issues/12) | [#19](https://github.com/wiki-mod/distcc-ng/pull/19) | [Weak temp-file name entropy in `dcc_make_tmpnam`](issue-012-tempfile-entropy.md) | Still present in upstream's live source, unreported |
| 2 | [#63](https://github.com/wiki-mod/distcc-ng/issues/63) | [#170](https://github.com/wiki-mod/distcc-ng/pull/170) | [Bundled popt fallback removed for staleness — a current-vendor alternative exists](issue-063-popt-current-vendor-alternative.md) | Not a bug — a design-reconsideration note for a deliberate past removal |
| 3 | [#179](https://github.com/wiki-mod/distcc-ng/issues/179) | [#180](https://github.com/wiki-mod/distcc-ng/pull/180) | [dcc_mkdir() lacks parent-directory (mkdir -p) creation](issue-179-mkdir-parent-dirs.md) | Still present in upstream's live source, unreported |
