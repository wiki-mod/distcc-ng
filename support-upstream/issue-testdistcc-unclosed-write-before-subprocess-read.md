# Test-fixture file writes not explicitly closed before the next test step

**Fork issue:** [wiki-mod/distcc-ng#460](https://github.com/wiki-mod/distcc-ng/issues/460) (Finding 3)
**Fixed by:** [wiki-mod/distcc-ng#466](https://github.com/wiki-mod/distcc-ng/pull/466) (full whole-file sweep, AGENTS.md rule 73)
**Upstream location:** `test/testdistcc.py` — `MultipleCompile_Case.setup()` (lines 1467-1468), `BinFalse_Case.createSource()` (line 1866), `BinTrue_Case.createSource()` (line 1892), `RemoteAssemble_Case.setup()` (line 2057), `PreprocessAsm_Case.setup()` (line 2084), `HostFile_Case.setup()` (line 2208)
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-08-12)
**Searched upstream issues/PRs for:** `testtmp.i`, `createSource close`, `MultipleCompile`, `RemoteAssemble`, `unclosed file testdistcc` — no matching report or fix attempt found, open or closed.

## The problem

Each of the six call sites above writes a test fixture file with a bare,
unassigned `open(...).write(...)` expression and never explicitly closes
it. Relying on the temporary file object being garbage-collected -- and
its `__del__` closing and flushing it -- before the next statement runs is
an implementation detail of CPython's reference-counting GC, not a
language guarantee. A Python implementation whose garbage collector
doesn't collect this promptly (e.g. PyPy, which primarily uses a
tracing/generational collector) can leave the fixture's on-disk content
stale when the next method starts.

Whether that is only a hygiene defect or an actual reproducible test
failure depends on what happens next:

- **`BinFalse_Case`/`BinTrue_Case`**: `runtest()` passes the fixture path
  through `distcc` to `false`/`true`. Those fake compilers intentionally
  ignore their input, and the test's own assertions check only the exit
  status -- so a stale/unflushed file here is a real lifetime-hygiene
  defect, not something these two tests could ever observably fail from.
- **`MultipleCompile_Case`, `RemoteAssemble_Case`, `PreprocessAsm_Case`,
  `HostFile_Case`**: the very next step genuinely depends on the written
  content -- a real compiler/assembler subprocess compiles the source it
  just wrote, or the `distcc` client itself parses the just-written hosts
  file to build its host list. For these four, an unflushed/truncated file
  under a delayed-GC implementation would produce an observably wrong or
  failing test (a compile of empty/partial source, or no hosts to
  distribute to), not just a hygiene concern.

## Upstream code (unchanged as of the commit above, upstream)

`test/testdistcc.py`:

```python
class MultipleCompile_Case(Compilation_Case):
    """Test compiling several files from one line"""
    def setup(self):
        WithDaemon_Case.setup(self)
        open("test1.c", "w").write("const char *msg = \"hello foreigner\";")
        open("test2.c", "w").write("""#include <stdio.h>
...
""")

class BinFalse_Case(Compilation_Case):
    def createSource(self):
        open("testtmp.i", "wt").write("int main() {}")

class BinTrue_Case(Compilation_Case):
    def createSource(self):
        open("testtmp.i", "wt").write("int main() {}")

class RemoteAssemble_Case(WithDaemon_Case):
    def setup(self):
        WithDaemon_Case.setup(self)
        open(self.asm_filename, 'wt').write(self.asm_source)

class PreprocessAsm_Case(WithDaemon_Case):
    def setup(self):
        WithDaemon_Case.setup(self)
        open('test2.S', 'wt').write(self.asm_source)

class HostFile_Case(CompileHello_Case):
    def setup(self):
        CompileHello_Case.setup(self)
        del os.environ['DISTCC_HOSTS']
        self.save_home = os.environ['HOME']
        os.environ['HOME'] = os.getcwd()
        # DISTCC_DIR is set to 'distccdir'
        open(os.environ['DISTCC_DIR'] + '/hosts', 'w').write('127.0.0.1:%d%s' %
            (self.server_port, _server_options))
```

## Fixed code (changed code as of the commit from distcc-ng fork)

Every applicable call site in this fork, including both the six
upstream-shared locations above and this file's other fork-only additions
(the full sweep this PR performs, per AGENTS.md rule 73), now uses an
explicit `with` block:

```python
def createSource(self):
    with open("testtmp.i", "wt") as f:
        f.write("int main() {}")
```

## Empirical verification

Real evidence, not just an assertion, produced in response to a review
question: does the lifetime mechanism actually differ between
implementations? `probe_refcount_close_timing.py` ran on real GitHub
Actions `ubuntu-latest` CI (run
[31587298529](https://github.com/wiki-mod/distcc-ng/actions/runs/31587298529)),
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

This proves the underlying lifetime mechanism is real: under CPython the
fix is provably unnecessary for correctness (the object's `__del__` runs
synchronously and deterministically, not merely "hasn't been observed to
fail"); under PyPy the same bare-expression pattern reliably leaves an
unflushed, empty file visible to whatever reads it next, 100% of the time
in this test. It does **not**, by itself, prove that `BinFalse_Case`'s or
`BinTrue_Case`'s own test path would fail -- the probe used a reader whose
result depends on the file's content, while `false`/`true` ignore it and
the harness only checks their exit status (see "The problem" above for the
distinction). For `MultipleCompile_Case`, `RemoteAssemble_Case`,
`PreprocessAsm_Case`, and `HostFile_Case`, the downstream consumer *does*
depend on the content, so the same probe result applies to them directly:
under a delayed-GC implementation, this pattern would produce an
observably wrong or failing test, not just a latent hygiene issue.
