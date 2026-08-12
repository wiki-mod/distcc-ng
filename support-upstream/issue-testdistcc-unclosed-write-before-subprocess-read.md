# Test-fixture file write is not explicitly closed before the next test step

**Fork issue:** none filed separately (Issue #460 Finding 3)
**Fixed by:** [wiki-mod/distcc-ng#466](https://github.com/wiki-mod/distcc-ng/pull/466)
**Upstream location:** `test/testdistcc.py`, `BinFalse_Case.createSource()` and `BinTrue_Case.createSource()`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-08-12)
**Searched upstream issues/PRs for:** `testtmp.i`, `createSource close`, `unclosed file testdistcc` — no matching report or fix attempt found, open or closed.

## The problem

Both `BinFalse_Case.createSource()` and `BinTrue_Case.createSource()` write
the shared `.i` fixture file with a bare, unassigned `open(...).write(...)`
expression and never explicitly close it. `runtest()` (the very next method
comfychair calls) then passes this path through distcc to `false` or `true`.
Those fake compilers intentionally ignore the input, so these particular
tests do not make their result depend on the fixture contents.

Relying on the temporary file object being garbage-collected -- and its
`__del__` closing and flushing it -- before the subprocess opens the same
path is an implementation detail of CPython's reference-counting GC, not a
language guarantee. A Python implementation whose garbage collector doesn't
collect this promptly (e.g. PyPy, which primarily uses a tracing/generational
collector) can leave the fixture's on-disk content stale when the next method
starts. For these cases that is a file-lifetime hygiene defect, not an
empirically demonstrated test failure: the invoked programs and the test
assertions do not inspect the source text.

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

This fork's applicable call sites, including both upstream-equivalent cases,
now use an explicit `with` block:

```python
def createSource(self):
    with open("testtmp.i", "wt") as f:
        f.write("int main() {}")
```

## Empirical verification

Real evidence, not just an assertion, produced in response to review
question: does the lifetime mechanism differ between implementations?
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

This proves that the bare expression can leave an unflushed file visible to
a following process under PyPy. It does **not** prove that the affected
`BinFalse_Case` or `BinTrue_Case` test path fails: the probe deliberately
used a reader whose result depends on the file contents, while `false` and
`true` ignore those contents and the harness asserts only their exit status.
The `with` block therefore makes file ownership and flush timing explicit
and portable without claiming a reproduced failure of those tests.
