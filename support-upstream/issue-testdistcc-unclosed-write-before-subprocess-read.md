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

`BinFalse_Case`/`BinTrue_Case` themselves are upstream-only classes this
fork doesn't currently carry verbatim under those names, so this entry
documents the pattern at its original upstream location rather than a
byte-identical fork diff; the fix shape is the same regardless of which
class it's applied to.

## Empirical verification

Not included: this is a latent portability risk under a Python
implementation with deferred garbage collection, not a reproducible failure
under CPython (the implementation both this fork's and upstream's CI
actually run) -- there is no CPython-observable behavior difference to
demonstrate before/after.
