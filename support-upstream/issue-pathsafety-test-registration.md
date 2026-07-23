# `PathSafety_Case` was defined but never registered in `test/testdistcc.py`'s `tests` list

**Note on scope:** this entry does not document a live bug in upstream's
source, following the exception carve-out this README describes (see
`issue-264-verification-container.md` for the same pattern). `PathSafety_Case`
exercises `dcc_name_has_path_traversal()`, `dcc_cdir_has_path_traversal()`, and
`dcc_absolute_link_target_has_path_traversal()` -- three functions that only
exist in this fork (added for issues #93/#100/#95), so upstream has no
equivalent test to compare against; the required support-upstream check
(AGENTS.md rule 57) is documented here as a negative finding, not skipped.

**Fork issue:** discovered while implementing [wiki-mod/distcc-ng#292](https://github.com/wiki-mod/distcc-ng/issues/292)'s fix (PR #293)
**Fixed by:** [wiki-mod/distcc-ng#294](https://github.com/wiki-mod/distcc-ng/pull/294)
**Upstream location:** `test/testdistcc.py` (root of `distcc/distcc`)
**Checked against upstream commit:** upstream `master` tip at the time of
this check (2026-07-22) -- `test/testdistcc.py` has no `PathSafety_Case`,
no `dcc_name_has_path_traversal`/`dcc_cdir_has_path_traversal`/
`dcc_absolute_link_target_has_path_traversal` references at all, and no
`h_pathsafety` test harness. The tested functions and the test class are
both fork-only additions with no upstream counterpart.
**Searched upstream issues/PRs for:** `PathSafety_Case`, `path traversal
test`, `h_pathsafety`, `dcc_name_has_path_traversal` -- no matching report
or fix attempt found, open or closed (expected, since neither the
functions nor the test exist upstream).

## The problem

`test/testdistcc.py` defines `class PathSafety_Case(SimpleDistCC_Case)`
(originally added alongside issues #93/#100, most recently extended in
#290's fix for #95) to exercise the three path-traversal string checks
above via the `h_pathsafety` test harness. The class was never added to
the top-level `tests = [ ... ]` list near the bottom of the file that
comfychair actually iterates over on a plain `testdistcc.py` run (or
`make check`). The test case could still be run directly by name
(`onetest.py PathSafety_Case`), which is how earlier ad hoc verification
of #93/#100/#95's fixes appeared to pass -- but a full `make check` never
exercised it, silently, since the class was first added.

Found while implementing #292's follow-up fix (which correctly registered
its own new `SymlinkTraversal_Case` in the same list) -- registering the
pre-existing `PathSafety_Case` gap was kept out of that PR's scope (a
behavior change, tests newly running, deserving its own review) and fixed
separately here.

## Fix

One-line addition to the `tests = [ ... ]` list (`test/testdistcc.py`),
placing `PathSafety_Case` before `ScanArgs_Case` to match where
`SymlinkTraversal_Case` was added for #292. No changes to the test class
or the functions it exercises.

## Verification

Real build (`-Wall -Werror`) and full `make check` on a real Linux host
(not WSL2): `PathSafety_Case` now appears in the `make check` log and
passes, in both the non-pump and pump-mode runs. No other test's outcome
changed.

Not proposed as an upstream contribution -- this fork does not send
patches upstream (see `AGENTS.md`); recorded here only as the required
per-PR support-upstream cross-check, and because there is genuinely
nothing upstream to compare against.
