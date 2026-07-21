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
| 6 | [#75](https://github.com/wiki-mod/distcc-ng/issues/75) | [#205](https://github.com/wiki-mod/distcc-ng/pull/205) | [Masquerade-whitelist warning ignores `DISTCC_CMDLIST`](issue-075-cmdlist-masquerade-warning.md) | Upstream `master` still nags unconditionally; upstream's own open PR #445 was never merged |
| 7 | [#74](https://github.com/wiki-mod/distcc-ng/issues/74) | [#204](https://github.com/wiki-mod/distcc-ng/pull/204) / [#207](https://github.com/wiki-mod/distcc-ng/pull/207) | [Skip distributing LTO invocations — upstream tried this exact idea, then reverted it with contradicting evidence](issue-074-lto-distribution-revert.md) | Not a live upstream bug — upstream merged the same fix (PR #413) then reverted it with real evidence it was wrong; this fork made its own version configurable/off-by-default in response |
| 8 | [#14](https://github.com/wiki-mod/distcc-ng/issues/14) | [#25](https://github.com/wiki-mod/distcc-ng/pull/25) | [Unbounded strcat command-line construction overflows fixed 261-byte buffer in `dcc_execvp_cyg` (Cygwin)](issue-014-cygwin-cmdline-overflow.md) | Still present in upstream's live source, unreported |
| 9 | [#93](https://github.com/wiki-mod/distcc-ng/issues/93) | [#94](https://github.com/wiki-mod/distcc-ng/pull/94) | [distccd: unvalidated client-supplied NAME allows path traversal in `dcc_r_many_files()`](issue-093-name-path-traversal.md) | Still present in upstream's live source (own acknowledging `FIXME` comment), unreported |
| 10 | [#100](https://github.com/wiki-mod/distcc-ng/issues/100) | [#103](https://github.com/wiki-mod/distcc-ng/pull/103) | [distccd: unvalidated client-supplied CDIR allows path traversal in `make_temp_dir_and_chdir_for_cpp()`](issue-100-cdir-path-traversal.md) | Still present in upstream's live source, unreported |
| 11 | none filed | [#2](https://github.com/wiki-mod/distcc-ng/pull/2) | [`strtok()` on `getenv("DISTCC_SSH")` corrupts the process's own environment](issue-002-ssh-distcc-env.md) | Still present in upstream's live source; also self-closed without a fix on distcc/distcc#583 |
| 12 | none filed | [#3](https://github.com/wiki-mod/distcc-ng/pull/3) | [`-iquote` is never stripped from remote compile arguments](issue-003-strip-iquote.md) | Still present in upstream's live source; also self-closed without a fix on distcc/distcc#582, open on distcc/distcc#504 |
| 13 | none filed | [#4](https://github.com/wiki-mod/distcc-ng/pull/4) | [NULL-pointer dereference pruning the stats list's head entry](issue-004-stats-null-deref.md) | Still present in upstream's live source; also self-closed without a fix on distcc/distcc#585 |
| 14 | [#13](https://github.com/wiki-mod/distcc-ng/issues/13) | [#24](https://github.com/wiki-mod/distcc-ng/pull/24) | [Unchecked second `readlinkat()` return value used as array index in `dcc_rewrite_generic_compiler()`](issue-013-readlinkat-unchecked.md) | Still present in upstream's live source, unreported |
| 15 | [#22](https://github.com/wiki-mod/distcc-ng/issues/22) | [#23](https://github.com/wiki-mod/distcc-ng/pull/23) | [A bare `/* fallthrough */` comment is invisible once distcc preprocesses its own source](issue-022-fallthrough-comment.md) | Still present in upstream's live source; already reported and open as distcc/distcc#242 |
| 16 | [#69](https://github.com/wiki-mod/distcc-ng/issues/69) | [#172](https://github.com/wiki-mod/distcc-ng/pull/172) | [`--disable-pump-mode` doesn't actually skip the Python dependency probe](issue-069-configure-python-gate.md) | Still present in upstream's live source; also reported on distcc/distcc#258 |
| 17 | [#87](https://github.com/wiki-mod/distcc-ng/issues/87) | [#99](https://github.com/wiki-mod/distcc-ng/pull/99) | [pump mode's manual DISTCC_HOSTS path requires a different host-list format than plain distcc](issue-087-hostlist-format.md) | Still present in upstream's live source, unreported |
| 18 | [#145](https://github.com/wiki-mod/distcc-ng/issues/145) | [#146](https://github.com/wiki-mod/distcc-ng/pull/146) | [Unbounded sprintf/strcpy/strcat into a fixed 256-byte stack buffer in lsdistcc's `get_thename()`](issue-145-lsdistcc-buffer-overflow.md) | Still present in upstream's live source, unreported |
| 19 | [#157](https://github.com/wiki-mod/distcc-ng/issues/157) | [#158](https://github.com/wiki-mod/distcc-ng/pull/158) | [Several distccd/lsdistcc files created world-writable (0666) with no local-tampering justification](issue-157-world-writable-files.md) | Still present in upstream's live source, unreported |
| 20 | [#159](https://github.com/wiki-mod/distcc-ng/issues/159) | [#160](https://github.com/wiki-mod/distcc-ng/pull/160) | [umask silently defeats `dcc_open_lockfile()`'s intended shared-lock-dir 0666 mode](issue-159-lock-umask-fchmod.md) | Still present in upstream's live source, unreported |
| 21 | none filed | [#6](https://github.com/wiki-mod/distcc-ng/pull/6) | [Non-atomic, in-place O_TRUNC state-file write lets a monitor observe a truncated file](issue-006-state-atomic-write.md) | Still present in upstream's live source, unreported |
| 22 | none filed | [#7](https://github.com/wiki-mod/distcc-ng/pull/7) | [pump's shutdown and startup handshakes can block/hang forever with no timeout](issue-007-pump-fail-closed.md) | Still present in upstream's live source, unreported |
| 23 | none filed | [#8](https://github.com/wiki-mod/distcc-ng/pull/8) | [Bare `os.wait()` in the test harness's `killDaemon()` can reap the wrong child process](issue-008-testdistcc-oswait.md) | Still present in upstream's live source, unreported |
| 24 | [#72](https://github.com/wiki-mod/distcc-ng/issues/72) | [#174](https://github.com/wiki-mod/distcc-ng/pull/174) | [`dcc_lock_one()`'s per-scan CPU-slot cap of 10000 is too low for large hosts](issue-072-lock-retry-limit.md) | Still present in upstream's live source; upstream's own unmerged PR #349 already raises the same cap |
| 25 | [#224](https://github.com/wiki-mod/distcc-ng/issues/224) | [#230](https://github.com/wiki-mod/distcc-ng/pull/230) | [Unbounded allocation size from wire-protocol input in `dcc_r_str_alloc()`/`dcc_r_argv()`/bulk receivers](issue-224-unbounded-rpc-allocation.md) | Still present in upstream's live source, unreported |
| 26 | [#225](https://github.com/wiki-mod/distcc-ng/issues/225) | [#231](https://github.com/wiki-mod/distcc-ng/pull/231) | [Protocol version 4 (zstd) could silently misconfigure a distccd built without zstd support](issue-225-zstd-protover-guard.md) | Not applicable -- zstd/protover 4 is a distcc-ng-only feature, no upstream equivalent |
| 27 | [#226](https://github.com/wiki-mod/distcc-ng/issues/226) | [#242](https://github.com/wiki-mod/distcc-ng/pull/242) | [lsdistcc's get_thename() treats "contains %d" as safe to use as a printf format string](issue-226-lsdistcc-format-string.md) | Still present in upstream's live source, unreported |
| 28 | [#226](https://github.com/wiki-mod/distcc-ng/issues/226) | [#242](https://github.com/wiki-mod/distcc-ng/pull/242) | [alloca() inside the -specs= argument loop accumulates unbounded stack allocation](issue-226-serve-specs-alloca-loop.md) | Still present in upstream's live source, unreported |
| 29 | [#246](https://github.com/wiki-mod/distcc-ng/issues/246) | [#247](https://github.com/wiki-mod/distcc-ng/pull/247) | [`-Xclang <arg>` cc1 payload mis-stripped / re-interpreted as a distcc flag](issue-246-xclang-payload-strip.md) | Argv-scanner code live and unchanged in upstream; reliable trigger is fork-only (`-march=native` resolution) but a user-supplied `-Xclang -l…/-x…` hits it upstream too |
| 30 | [#143](https://github.com/wiki-mod/distcc-ng/issues/143) | [#249](https://github.com/wiki-mod/distcc-ng/pull/249) | [Unbounded sprintf from caller-controlled input in lsdistcc `generate_query()` and the masquerade PATH idiom (`climasq.c`; same idiom noted in `util.c`'s dead-code `dcc_trim_path()`)](issue-143-lsdistcc-masquerade-unbounded-sprintf.md) | Still present in upstream's live source, unreported |
| 31 | [#248](https://github.com/wiki-mod/distcc-ng/issues/248) | not yet implemented | [Native TLS transport with mutual identity — this fork's design work traces back to upstream's own original author](issue-248-tls-native-transport.md) | Not a bug — a feature-design entry, included as an explicit exception since the direction traces to sourcefrog's own stated long-term intent in distcc/distcc discussion #517 |
| 32 | [#143](https://github.com/wiki-mod/distcc-ng/issues/143) | [#252](https://github.com/wiki-mod/distcc-ng/pull/252) | [SSH transport command passed to `execvp()` without a plausibility check (Group H)](issue-143-ssh-execvp-command-sanity.md) | Not a live upstream bug — a client-side defensive-hardening note; the unvalidated `$DISTCC_SSH`→`execvp` pattern is byte-for-byte present in upstream but crosses no privilege boundary |
| 33 | [#143](https://github.com/wiki-mod/distcc-ng/issues/143) | [#253](https://github.com/wiki-mod/distcc-ng/pull/253) | [CodeQL `cpp/missing-check-scanf` on `dcc_get_proc_meminfo_mem_available`/`dcc_get_disk_io_stats` — analysis-confirmed false positives](issue-143-scanf-check-false-positives.md) | Not a bug — both alerts are false positives (guard exists, CodeQL model does not cross the `break`); identical code live upstream, defensive-init hardening optional |
| 34 | [#227](https://github.com/wiki-mod/distcc-ng/issues/227) | [#245](https://github.com/wiki-mod/distcc-ng/pull/245) | [Compiler family (gcc vs clang) trusted from argv[0] basename only in three functions — one has its own admitting TODO](issue-227-compiler-family-basename-trust.md) | Still present in upstream's live source; `dcc_add_clang_target()` carries its own unaddressed TODO naming this exact gap |
| 35 | [#256](https://github.com/wiki-mod/distcc-ng/issues/256) | [#257](https://github.com/wiki-mod/distcc-ng/pull/257) | [1-byte heap NUL overflow in `dcc_fresh_dependency_exists()` (`.d` TOCTOU)](issue-256-dotd-nul-overflow.md) | Still present in upstream's live source, unreported |
| 36 | [#268](https://github.com/wiki-mod/distcc-ng/issues/268) | [#271](https://github.com/wiki-mod/distcc-ng/pull/271) | [stat-then-open TOCTOU pattern itself in `dcc_fresh_dependency_exists()` (CodeQL alert #3), addendum to row 35's file](issue-256-dotd-nul-overflow.md) | Still present in upstream's live source (same `stat()`/`fopen()` pair, commit `8d569d19`), unreported |
| 37 | [#76](https://github.com/wiki-mod/distcc-ng/issues/76) | [#PENDING](https://github.com/wiki-mod/distcc-ng/pull/PENDING) | [`tweak_arguments_for_server()` never rewrites `-f*-prefix-map=` build-path prefixes](issue-076-serve-prefix-map.md) | Still present in upstream's live source; upstream's own open PR #459 (opened 2022-04-29) proposes the same fix, never merged |
