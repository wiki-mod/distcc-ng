# `--imacros=` (GCC/Clang's combined form of `-imacros`) never rewritten for the server in pump mode

**Fork issue:** none filed
**Fixed by:** [wiki-mod/distcc-ng#418](https://github.com/wiki-mod/distcc-ng/pull/418)
**Upstream location:** `src/serve.c`, function `tweak_include_arguments_for_server` (`include_options[]`); `include_server/parse_command.py` (`CPP_OPTIONS_APPEARING_AS_ASSIGNMENTS`)
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-08-05)
**Searched upstream issues/PRs for:** `--imacros=`, `imacros`, `tweak_include_arguments_for_server` — no matching report found (see `issue-416-include-equals-server-rewrite.md` for the general search on this option family).

## The problem

Same gap as `--include=` (`issue-416-include-equals-server-rewrite.md`), for `-imacros`'s combined form. GCC/Clang document `-imacros file`, `--imacros=file`, and `--imacros file` as equivalent (`-imacros` only processes a file's macro definitions, discarding any other preprocessor output — irrelevant to this bug, which is about the *path* never being rewritten/mirrored at all, regardless of what's done with the file's contents once found).

`tweak_include_arguments_for_server()`'s `include_options[]` recognizes `-imacros` (two-token and no-`=` combined forms) but not `--imacros=`. `include_server/parse_command.py`'s `CPP_OPTIONS_MAYBE_TWO_WORDS` recognizes `-imacros` the same way, but `CPP_OPTIONS_APPEARING_AS_ASSIGNMENTS` has no `--imacros` entry.

## Upstream code (unchanged as of the commit above, upstream)

`src/serve.c`:

```c
static const char *include_options[] = {
    "-I",
    "-include",
    "-imacros",
    "-idirafter",
    "-iprefix",
    "-iwithprefix",
    "-iwithprefixbefore",
    "-isystem",
    "-iquote",
    NULL
};
```

`include_server/parse_command.py`:

```python
CPP_OPTIONS_APPEARING_AS_ASSIGNMENTS = {
  '--sysroot':     lambda ps, arg: ps.set_sysroot(arg)
}
```

## Fixed code (changed code as of the commit from distcc-ng fork)

`src/serve.c`:

```c
static const char *include_options[] = {
    "-I",
    "-include",
    "--include=",
    "-imacros",
    "--imacros=",
    "-idirafter",
    "-iprefix",
    "-iwithprefix",
    "-iwithprefixbefore",
    "-isystem",
    "-iquote",
    NULL
};
```

`include_server/parse_command.py`:

```python
CPP_OPTIONS_APPEARING_AS_ASSIGNMENTS = {
  '--sysroot':     lambda ps, arg: ps.set_sysroot(arg),
  '--include':     lambda ps, arg: ps.include_files.append(arg),
  '--imacros':     lambda ps, arg: ps.include_files.append(arg),
}
```

Same rewrite/dispatch mechanism as `--include=`, so no other logic change needed — just the two missing table entries.

## Empirical verification

Found via a deliberate sweep for the same bug pattern elsewhere, immediately after fixing `--include=` (#416) — cross-checked every option already in both files' tables against GCC's and Clang's actual documented option-summary pages (not assumed from memory). Added a real regression test, `ImacrosEqualsForceInclude_Case` (`test/testdistcc.py`), mirroring `IncludeEqualsForceInclude_Case`'s exact structure, and an extension to `parse_command_test.py`'s existing coverage. Both pass on real GitHub Actions CI (`make_check`, ubuntu-latest and macOS-latest, both plain and pump-mode passes) — see PR #418.
