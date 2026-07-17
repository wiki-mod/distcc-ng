# Flaky `Compile_c_Case` test: `time_ref` int-truncation races with dotd mtime under load

**Fork issue:** [wiki-mod/distcc-ng#196](https://github.com/wiki-mod/distcc-ng/issues/196)
**Fixed by:** [wiki-mod/distcc-ng#198](https://github.com/wiki-mod/distcc-ng/pull/198)
**Upstream location:** `test/testdistcc.py`, `Compile_c_Case.runtest()` and `Compile_c_Case.getDep()`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-17)
**Searched upstream issues/PRs for:** `Compile_c_Case`, `dcc_fresh_dependency_exists`, `time_ref`, `Checking dependency`, `flaky`, `old dotd file` — no matching report or fix attempt found, open or closed.

## The problem

`Compile_c_Case.runtest()` (upstream `test/testdistcc.py:765`) computes the
reference timestamp it passes to `dcc_fresh_dependency_exists()` as:

```python
time_ref = time.time() + 1
# Let real-time advance to time_ref.
while time.time() < time_ref:
    time.sleep(1)
```

and then invokes the C test harness with that value formatted via `"%i"`
(upstream `test/testdistcc.py`, the `h_compile dcc_fresh_dependency_exists`
call a few lines below). `"%i"` string formatting of a Python float
truncates towards zero rather than rounding, so the *actual*
`reference_time` the C side receives is `int(time_ref)`, not `time_ref`
itself — silently shrinking the intended one-second safety margin between
the `.d` test file's mtime and the reference time down to (in the worst
case) a hair under zero extra margin.

Separately, `getDep()` (upstream `test/testdistcc.py:722`, called from a loop
at line 781) parses every non-blank line of the harness's stderr output and
asserts each one matches `"Checking dependency: ..."`:

```python
m_obj = re.search(r"Checking dependency: ((\w|[.])*)", line)
assert m_obj, line
```

This is called from the following loop, which decides which lines to feed
into `getDep()`:

```python
for line in err.split("\n"):
    if re.search("[^ ]", line):
        # Line is non-blank
        checked_deps[self.getDep(line)] = 1
```

`dcc_fresh_dependency_exists()` (`src/compile.c`, upstream and fork alike)
can legitimately emit other `rs_trace()` lines on this same code path —
most notably `"old dotd file \"%s\""` when it decides the `.d` file's mtime
looks too old relative to `reference_time` (this is intentional,
correct behavior: the function is declining to trust a stale `.d` file).
That trace line does not match `"Checking dependency: ..."`, so it trips
the blind `assert` in `getDep()` and fails the whole test outright, on a
condition that is otherwise entirely legitimate control flow.

## Why this is a real, if rare, bug

Under light load, the one-second sleep granularity plus the truncation
still normally leaves enough margin that the `.d` file's real mtime lands
at or after the (truncated) `reference_time`. Under CPU/IO contention —
this fork's CI runs the equivalent suite twice per job (`make check`, then
`maintainer-check-no-set-path`) — process-scheduling jitter around the
`time.sleep(1)` calls and the file write can close that shrunk margin
enough for the race to occasionally flip, landing the `.d` file's real
mtime just below the truncated `reference_time`. `dcc_fresh_dependency_exists()`
then correctly (from its own point of view) treats the file as untrustworthy
and emits `"old dotd file ..."` — which the test then turns into a hard,
misleading failure via the unconditional `getDep()` assert, rather than
recognizing it as legitimate, expected output for that (rare) scheduling
outcome.

This fork observed the failure once in real CI (2026-07-17, an unrelated
PR's build job) and root-caused it from the log plus source reading;
see fork issue #196 for the original incident detail. It could not be
reproduced on demand locally, including under artificially induced heavy
CPU load (28-way `yes` stress alongside repeated `make check` runs) as
part of validating the fork's own fix — consistent with this being a
genuine but low-probability scheduling race, not a deterministic bug.

## Fixed code (fork, `test/testdistcc.py`)

```python
# time_ref is computed as an already-rounded whole integer (not a float)
# with a 2-second safety margin ... Computing an integer margin up front
# removes the truncation surprise entirely and adds a full extra second
# of headroom against scheduling jitter.
time_ref = int(time.time()) + 2
# Let real-time advance to time_ref, polling finely so we don't
# overshoot by up to a full second per iteration.
while time.time() < time_ref:
    time.sleep(0.1)
```

```python
checked_deps = {}
for line in err.split("\n"):
    # Only feed lines carrying the expected marker to getDep() ...
    if "Checking dependency:" in line:
        checked_deps[self.getDep(line)] = 1
```

`getDep()` itself is unchanged — its internal `assert` is still a
reasonable sanity check, now a true invariant since the caller only feeds
it lines that should match.

Landed via [wiki-mod/distcc-ng#198](https://github.com/wiki-mod/distcc-ng/pull/198).

## Empirical verification

Validated on a real Linux build (WSL2 Debian, full autoconf/automake
toolchain): `./autogen.sh && ./configure PYTHON=python3 && make`, then
`make check`. The fixed tree passed `make check` cleanly across many
repeated and load-induced runs (8 consecutive clean runs, plus further
runs under artificially induced heavy CPU load via a 28-way `yes > /dev/null`
stress loop on a 28-core host) with `Compile_c_Case` reporting `OK` in both
the `make check` and `maintainer-check-no-set-path` sub-runs every time.

The pre-fix code (this fork's `test/testdistcc.py` as it stood before
PR #198, functionally identical to upstream's current version for this
code path) was also run repeatedly under the same induced heavy load
(4 full `make check` runs plus 40 isolated `Compile_c_Case` invocations,
all under a 28-to-40-way `yes` stress loop) without reproducing the race —
consistent with this being a genuine but rare scheduling-dependent failure
rather than one reliably triggerable outside the specific contention
pattern seen in the original CI incident.
