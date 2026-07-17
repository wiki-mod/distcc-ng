# `--disable-pump-mode` doesn't actually skip the Python dependency probe in `configure.ac`

**Fork issue:** [wiki-mod/distcc-ng#69](https://github.com/wiki-mod/distcc-ng/issues/69)
**Fixed by:** [wiki-mod/distcc-ng#172](https://github.com/wiki-mod/distcc-ng/pull/172)
**Upstream location:** `configure.ac`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-17)
**Searched upstream issues/PRs for:** `disable-pump-mode`, `AM_PATH_PYTHON`, `pump_mode configure` — found [distcc/distcc#258](https://github.com/distcc/distcc/pull/258) ("configure: allow disabling pump mode", merged), the original PR that introduced `--disable-pump-mode` itself; it never gated `AM_PATH_PYTHON` on the new flag, which is the gap this entry documents. No separate bug report about the gating gap itself found, open or closed.

## The problem

`configure.ac` defines `--disable-pump-mode` and records the result in the
`pump_mode` shell variable, but the `AM_PATH_PYTHON` Python-interpreter
probe that immediately follows runs unconditionally, regardless of
`pump_mode`'s value. Pump mode (the include-server) is the only part of
this codebase that actually needs Python — the rest of `distcc`/`distccd`
build and run with no Python dependency at all. Passing
`--disable-pump-mode` on a system with no Python interpreter therefore
still fails (or hangs, depending on `AM_PATH_PYTHON`'s configured
fallback), defeating the entire point of the flag: it cannot be used to
build on a Python-less system.

## Upstream code (unchanged as of the commit above, upstream)

`configure.ac`:

```
AC_ARG_ENABLE(pump-mode,
	AS_HELP_STRING([--disable-pump-mode],[include server support (pump mode), requires python]),
		[pump_mode=${enableval}], [pump_mode=yes])

AM_PATH_PYTHON([3.1],,[:])
AC_ARG_VAR(PYTHON, [Python interpreter])
AC_SUBST(PYTHON_RELATIVE_LIB)
```

`pump_mode` is set above but never referenced again anywhere in
`configure.ac` — `AM_PATH_PYTHON` and the two following macros always run,
whatever `--disable-pump-mode` was passed.

## Fixed code (this fork, PR #172)

```
AC_ARG_ENABLE(pump-mode,
	AS_HELP_STRING([--disable-pump-mode],[include server support (pump mode), requires python]),
		[pump_mode=${enableval}], [pump_mode=yes])

# The include server (pump mode) is implemented in Python, so only probe
# for a Python interpreter when pump mode is actually going to be built;
# otherwise --disable-pump-mode would still fail/hang on a system with no
# Python at all, defeating the point of the flag.
if test "x${pump_mode}" = xyes; then
	AM_PATH_PYTHON([3.1],,[:])
	AC_ARG_VAR(PYTHON, [Python interpreter])
	AC_SUBST(PYTHON_RELATIVE_LIB)
fi
```

The Python probe and its associated `AC_ARG_VAR`/`AC_SUBST` now only run
when `pump_mode` is actually `yes`.

Landed via [wiki-mod/distcc-ng#172](https://github.com/wiki-mod/distcc-ng/pull/172).
