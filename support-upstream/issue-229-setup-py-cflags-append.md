# Note on scope

This entry does not document a bug that is *live and visible* in
upstream's own default build today — upstream never bumped its default
`CFLAGS` off autoconf's `-O2` default the way this fork's #229 did, so
the symptom described below (two conflicting optimization flags on the
same `gcc` invocation) does not currently appear in upstream's own CI.
What *is* identical, byte-for-byte, is the underlying mechanism that
would produce that exact symptom the moment anyone building upstream
overrides `CFLAGS` at `./configure` time (a distribution packaging
script adding hardening flags, a custom `-O3`, etc.) — a common enough
thing to do that it is worth documenting here rather than treating as
purely a fork-specific quirk.

**Fork issue:** [wiki-mod/distcc-ng#229](https://github.com/wiki-mod/distcc-ng/issues/229)
**Fixed by:** [wiki-mod/distcc-ng#277](https://github.com/wiki-mod/distcc-ng/pull/277)
**Upstream location:** `Makefile.in` (the `include-server` build rule, forwarding `CFLAGS` into `include_server/setup.py`'s environment) and `include_server/setup.py` itself
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-21)
**Searched upstream issues/PRs for:** `setup.py CFLAGS`, `distutils CFLAGS override`, `include_server optimization`, `-O2 -O3 setup.py` — no matching report or fix attempt found, open or closed. (`setuptools`/`distutils` upstream itself has long-standing, well-known discussion of `customize_compiler()`'s append-not-replace `CFLAGS` behavior, but nothing distcc-specific.)

## The problem

`Makefile.in`'s `include-server` build rule invokes `include_server/setup.py`
(a `setuptools`/`distutils`-driven build, not `Makefile.in`'s own compile
rules) with the project's `CFLAGS` passed as an environment variable:

```
CFLAGS="$(CFLAGS) $(PYTHON_CFLAGS)"           \
...
$(PYTHON) "$(srcdir)/include_server/setup.py" \
    build ...
```

`setup.py` itself does no CFLAGS handling of its own
(`extra_compile_args=[]` in its `setuptools.Extension(...)` call).
`setuptools`' vendored copy of `distutils` (`setuptools._distutils.sysconfig.
customize_compiler()`) reads Python's own sysconfig-baked `CFLAGS`/`OPT`
config vars (whatever optimization level Python itself was originally
built with — commonly `-O2`), and then does this (confirmed by reading the
actual function source):

```python
if 'CFLAGS' in os.environ:
    cflags = cflags + ' ' + os.environ['CFLAGS']
    ldshared = ldshared + ' ' + os.environ['CFLAGS']
```

It **appends** the environment `CFLAGS` after Python's own baked-in
value, rather than replacing it. Whatever optimization flag the caller
passes via `CFLAGS` therefore ends up on the same compiler invocation as
whatever flag Python's own sysconfig already had, not in place of it.

## Upstream code (unchanged as of the commit above, upstream)

Byte-for-byte identical to this fork's pre-fix state, in both files:

`Makefile.in` (upstream, exact lines 574, 934, and 1063 as of commit `8d569d19` — confirmed via `git show 8d569d19:Makefile.in | grep -n PYTHON_CFLAGS`, all three identical):
```
CFLAGS="$(CFLAGS) $(PYTHON_CFLAGS)"           \
CPPFLAGS="$(CPPFLAGS)"                        \
LIBS="$(LIBS)"                                \
$(PYTHON) "$(srcdir)/include_server/setup.py" \
    build ...
```

`include_server/setup.py` (upstream):
```python
ext = setuptools.Extension(
    name='include_server.distcc_pump_c_extensions',
    sources=[...],
    include_dirs=cpp_flags_includes,
    define_macros=[('_GNU_SOURCE', 1)],
    extra_compile_args=[]
    )
```

No patching of `sysconfig`'s config vars anywhere in upstream's `setup.py`.

## Fixed code (this fork, PR #277)

`include_server/setup.py` now patches `sysconfig.get_config_vars()`'s
`CFLAGS`/`OPT`/`LDSHARED` entries at module-import time (before
`setuptools.Extension()`/`setuptools.setup()` run), replacing only the
literal `-O2` substring — mirroring `configure.ac`'s own `-O2`->`-O3`
rewrite pattern rather than blindly overwriting the whole string:

```python
def _rebase_python_build_optimization_level():
  cfg_vars = sysconfig.get_config_vars()
  for key in ('CFLAGS', 'OPT', 'LDSHARED'):
    value = cfg_vars.get(key)
    if value and '-O2' in value:
      cfg_vars[key] = value.replace('-O2', '-O3')

_rebase_python_build_optimization_level()
```

Because `sysconfig.get_config_vars()` returns the same cached dict object
on every call within a process, mutating it here (before setuptools'
vendored `distutils` makes its own one-time copy of it) is visible to
every later reader, including the `customize_compiler()` call above.

Landed via [wiki-mod/distcc-ng#277](https://github.com/wiki-mod/distcc-ng/pull/277).

## Empirical verification

Confirmed directly against the actual `setuptools._distutils.sysconfig.
customize_compiler` source (Python 3.11, `setuptools` 66.1.1 — the same
CPython/setuptools family this fork's own CI uses, Python 3.11/3.12) that
the append behavior is real, then confirmed the fix eliminates it in a
real build: before the fix, `make include-server` produced
`... -O2 ... -O3 ...` on the same `gcc` invocation (reproduced locally by
temporarily disabling the fix and rebuilding, and independently confirmed
against two real GitHub Actions CI runs on `current_dev` predating this
fix — `c-build.yml` run 29828847651 and `package-release.yml` run
29841727713, both showing the identical line); after the fix, only `-O3`
appears, in both the compile and link steps. The built extension's own
functional test (`include_server/c_extensions_test.py`) still passes
after the fix.

Since upstream's own default `CFLAGS` is just `-O2` (matching Python's
own default, so the append is an invisible harmless duplicate under
upstream's own default configure invocation), this was not independently
re-verified by building upstream's actual tree with a custom `CFLAGS`
override — the mechanism is identical Python/setuptools behavior,
confirmed directly from the vendored `customize_compiler()` source
rather than re-derived by analogy.
