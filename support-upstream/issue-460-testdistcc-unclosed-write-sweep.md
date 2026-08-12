# Test-fixture file writes never closed before an external subprocess reads them back (whole-file sweep)

**Fork issue:** [wiki-mod/distcc-ng#460](https://github.com/wiki-mod/distcc-ng/issues/460) (Finding 3)
**Fixed by:** this PR (sibling/follow-up to [wiki-mod/distcc-ng#466](https://github.com/wiki-mod/distcc-ng/pull/466), which fixed the 10 sites a Copilot review happened to flag)
**Upstream location:** `test/testdistcc.py` — `MultipleCompile_Case.setup()` (lines 1467-1468), `BinFalse_Case.createSource()` (line 1866), `BinTrue_Case.createSource()` (line 1892), `RemoteAssemble_Case.setup()` (line 2057), `PreprocessAsm_Case.setup()` (line 2084), `HostFile_Case.setup()` (line 2208)
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-08-12)
**Searched upstream issues/PRs for:** `testtmp.i`, `MultipleCompile`, `RemoteAssemble`, `unclosed file testdistcc` — no matching report or fix attempt found, open or closed.

## Note on scope and a correction to #466's own entry

[#466](https://github.com/wiki-mod/distcc-ng/pull/466) fixed exactly the 10
call sites a Copilot code-quality review happened to flag (issue #460
Finding 3) and added
`support-upstream/issue-testdistcc-unclosed-write-before-subprocess-read.md`
documenting the pattern using `BinFalse_Case`/`BinTrue_Case` as the
illustrative upstream example. That entry states those two classes "are
upstream-only classes this fork doesn't currently carry verbatim under
those names" — this is incorrect: this fork's `test/testdistcc.py` (before
this PR) carried both classes byte-for-byte identical to upstream, `open`
call included, at the same lines this entry's own sweep found and fixed.
Both classes are fixed by this PR (see below); a comment correcting this
was posted on #466 rather than editing its branch directly.

Per AGENTS.md rule 73 (a found bug's minimum sweep is the whole file it was
found in), this PR swept the rest of `test/testdistcc.py` for the same
`open(...).write(...)`/`open(...).read()` pattern beyond #466's 10 flagged
lines. Of the ~28 additional sites fixed, six exist upstream in the same
unclosed shape (listed above); the rest (`AssemblyIncludeLocalOnly_Case`,
`HostFileDistccDirUnset_Case`, `ServerKilledMidJob_Case`, and every pure
`open(...).read()` site) are either fork-only additions (issue #275's own
test-coverage work, not present upstream at all) or reads with no
subprocess-ordering risk, and so are not part of this upstream note.

## The problem

Each of the six call sites above writes a test fixture file with a bare,
unassigned `open(...).write(...)` expression and never explicitly closes
it. In every case, the very next thing the test does is exec a real
subprocess that reads that exact file back: `MultipleCompile_Case`/
`BinFalse_Case`/`BinTrue_Case` hand their file straight to a `distcc`
client subprocess (which itself reads and forwards the file — see
`src/remote.c`'s `dcc_x_file()` call in `dcc_send_header()`);
`RemoteAssemble_Case`/`PreprocessAsm_Case` hand theirs to a real assembler
subprocess; `HostFile_Case` writes `$DISTCC_DIR/hosts`, which the `distcc`
client subprocess reads on its very next invocation.

Relying on the temporary file object being garbage-collected -- and its
`__del__` closing and flushing it -- before the subprocess opens the same
path is an implementation detail of CPython's reference-counting GC, not a
language guarantee. A Python implementation whose garbage collector doesn't
collect this promptly (e.g. PyPy, which primarily uses a tracing/
generational collector) could hand the subprocess a file that has been
written to but not yet flushed to disk, making the test's actual on-disk
content non-deterministic. This has not been observed to fail under
CPython (the only Python implementation upstream's CI actually exercises),
which is exactly why it can sit unnoticed indefinitely.

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

Each site now uses an explicit `with` block, so the write is guaranteed
flushed before control returns to the caller, regardless of Python
implementation:

```python
def createSource(self):
    with open("testtmp.i", "wt") as f:
        f.write("int main() {}")
```

## Empirical verification

Not included: this is a latent portability risk under a Python
implementation with deferred garbage collection, not a reproducible
failure under CPython (the implementation both this fork's and upstream's
CI actually run) -- there is no CPython-observable behavior difference to
demonstrate before/after.
