# No full bidirectional native-compatibility distributed-build E2E test — not a live upstream bug, a fork-only tooling addition

**Note on scope:** this entry does not document a live bug in upstream's
source, following the exception carve-out this README describes (same
pattern as `issue-264-verification-container.md`, `issue-063-popt-current-
vendor-alternative.md`, `issue-074-lto-distribution-revert.md`). The required
support-upstream check (AGENTS.md rule 57) is documented here as a negative
finding, not skipped.

**Fork issue:** [wiki-mod/distcc-ng#264](https://github.com/wiki-mod/distcc-ng/issues/264)
**Fixed by:** not yet merged (this fork's full bidirectional E2E test, `test/e2e-full/`)
**Upstream location:** `.github/workflows/c-build.yml`, `test/testdistcc.py`
(root of `distcc/distcc`)
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-23)
**Searched upstream issues/PRs for:** `distributed test`, `two container`,
`e2e`, `bidirectional`, `interop` — no matching open or closed issue/PR
found beyond generic CI-flakiness reports; upstream's own CI
(`.github/workflows/c-build.yml`, fetched directly from `distcc/distcc`'s
`master` at the commit above) runs only `make check` on a single host per OS
(macOS/Ubuntu matrix) — a real `distccd`+`distcc` pair is exercised
(`test/testdistcc.py`'s `WithDaemon_Case`/`CompileHello_Case`), but always
against `localhost`, always the same freshly-built binary on both sides of
the connection. There is no two-container (or two-host) job anywhere in
upstream's workflow file, no job that builds or installs a second,
independently-built `distcc`/`distccd` to compile against, and no job that
builds a real third-party project (Samba, Apache httpd, or anything else)
distributed across a network boundary.

## Why this isn't a live upstream bug

This fork's own history has a real, concrete reason a same-binary,
localhost-only test is not sufficient: issue #225 was exactly the shape of
bug a one-directional/same-build test cannot catch (a distcc-ng client
against a distcc-ng-but-`--without-zstd` server negotiated the wrong
protocol version and silently misbehaved) — see
`support-upstream/issue-225-zstd-protover-guard.md`. Upstream's test suite,
as it exists at the commit above, structurally cannot catch that class of
bug: `test/testdistcc.py` never builds or runs a *second*, independently-
configured `distcc`/`distccd` pair, and its CI workflow never brings up two
separate hosts/containers with different builds on each side. This is a
missing test capability, not a broken or incorrect one — there is nothing
to point at as "here is the bug", only an absent category of coverage. Per
this README's own exception carve-out, that is recorded here as a negative
finding rather than force-fit into the bug-report template.

This fork's `test/e2e-full/` (issue #264's later design comments,
2026-07-21) closes that specific gap for this fork's own code: a real
Debian-packaged `distcc`/`distcc-pump` (independently built by Debian, not
this fork) is exercised against this fork's own `-NG` binaries in both
directions (this fork's client against the native server, and the native
client against this fork's server), in both plain and pump mode, building a
real third-party project (Samba). Porting an equivalent capability into
upstream's own CI is out of scope for this fork's own governance (this
fork never opens anything against `distcc/distcc` itself — see AGENTS.md
rule 50); this entry exists so the gap and the reasoning are on record.

## Empirical verification

Not applicable in the "before/after" sense this template usually asks for
(there is no upstream code being changed) — see the introducing PR's own
description for the real evidence gathered building and running
`test/e2e-full/` against this fork's own `current_dev`.
