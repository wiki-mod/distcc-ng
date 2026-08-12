# Test-fixture file write is never closed before a subprocess reads it back

**Fork issue:** none filed separately (Issue #460 Finding 3)
**Fixed by:** [wiki-mod/distcc-ng#466](https://github.com/wiki-mod/distcc-ng/pull/466)
**Upstream location:** `test/testdistcc.py`, `BinFalse_Case.createSource()` and `BinTrue_Case.createSource()`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-08-12)
**Searched upstream issues/PRs for:** `testtmp.i`, `createSource close`, `unclosed file testdistcc` — no matching report or fix attempt found, open or closed.

## The problem

Both `BinFalse_Case.createSource()` and `BinTrue_Case.createSource()` write
the shared `.i` fixture file with a bare, unassigned `open(...).write(...)`
expression and never explicitly close it. `runtest()` (the very next method
comfychair calls) then execs a real subprocess (`distcc false -c testtmp.i`
or `distcc true -c testtmp.i`) that reads this exact file back.

Relying on the temporary file object being garbage-collected -- and its
`__del__` closing and flushing it -- before the subprocess opens the same
path is an implementation detail of CPython's reference-counting GC, not a
language guarantee. A Python implementation whose garbage collector doesn't
collect this promptly (e.g. PyPy, which primarily uses a tracing/generational
collector) could hand the subprocess a file that has been written to but not
yet flushed to disk, making the test's actual on-disk content
non-deterministic. This has not been observed to fail under CPython (the
only Python implementation upstream's CI actually exercises), which is
exactly why it can sit unnoticed indefinitely.

## Upstream code (unchanged as of the commit above, upstream)

`test/testdistcc.py`:

```python
class BinFalse_Case(Compilation_Case):
    """Compiler that fails without reading input.
    ...
    """
    def createSource(self):
        open("testtmp.i", "wt").write("int main() {}")

    def runtest(self):
        ...
        self.runcmd(self.distcc() + "false -c testtmp.i", ...)


class BinTrue_Case(Compilation_Case):
    """Compiler that succeeds without reading input.
    ...
    """
    def createSource(self):
        open("testtmp.i", "wt").write("int main() {}")

    def runtest(self):
        self.runcmd(self.distcc() + "true -c testtmp.i", 0)
```

## Fixed code (changed code as of the commit from distcc-ng fork)

This fork's equivalent call sites (five total, all sharing this exact
write-then-subprocess-read shape: `UserPrivilegeDropFunctional_Case`,
`ZeroByteOutputCompiler_Case`, `NastyCppWritesStdout_Case`,
`CrashingCompiler_Case`, `ClientDisconnectKillsServerChild_Case`) now use an
explicit `with` block:

```python
def createSource(self):
    with open("testtmp.i", "wt") as f:
        f.write("int main() {}")
```

**Correction (2026-08-12):** the previous version of this entry stated
`BinFalse_Case`/`BinTrue_Case` "are upstream-only classes this fork doesn't
currently carry verbatim under those names." That was wrong: this fork's
`test/testdistcc.py` carried both classes byte-for-byte identical to
upstream, `open()` call included -- confirmed via `git show
upstream/master:test/testdistcc.py`. Both classes' own unclosed-write sites
are fixed by [wiki-mod/distcc-ng#472](https://github.com/wiki-mod/distcc-ng/pull/472),
which swept the rest of the file for the same pattern beyond this PR's
own 10 flagged sites.

## Empirical verification

Real evidence, not just an assertion, produced in response to review
question: is this a reproducible failure, or only a theoretical risk?
`probe_refcount_close_timing.py` ran on real GitHub Actions `ubuntu-latest`
CI (run [31587298529](https://github.com/wiki-mod/distcc-ng/actions/runs/31587298529)),
checking two things -- (a) mechanistically, via a `weakref.finalize`
tripwire, whether the file object's close-and-flush actually runs before
the very next statement executes; (b) empirically, 5000 real iterations of
the exact flagged pattern (`open(...).write(...)`, no `with`, no explicit
close), each followed by a real separate subprocess reading the same path
back, checking the full content round-trips correctly:

| Implementation | Finalize before next statement? | Stress test (subprocess round-trip) |
|---|---|---|
| CPython 3.14.7 | `True` (proven deterministic, not probabilistic) | 5000/5000 passed |
| PyPy 7.3.19 (3.10) | `False` | **0/5000 passed** -- every subprocess read 0 bytes |

This confirms both halves of the claim with real evidence instead of an
assertion: under CPython, the fix is provably unnecessary for correctness
(the object's `__del__` runs synchronously and deterministically before
control returns to the caller, not merely "hasn't been observed to fail")
-- and under PyPy, the exact same pattern is not just theoretically risky
but **reliably broken, 100% of the time**, because PyPy's tracing GC does
not finalize the temporary file object before the next statement runs, so
the subprocess consistently sees an empty, unflushed file. The `with`-block
fix is real, verified insurance against a real, verified failure mode --
just one CPython's own CI (this fork's and upstream's) can never surface on
its own.
