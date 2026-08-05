# `--include=` (GCC/Clang's combined-form force-include flag) never rewritten for the server in pump mode

**Fork issue:** none filed
**Fixed by:** [wiki-mod/distcc-ng#416](https://github.com/wiki-mod/distcc-ng/pull/416)
**Upstream location:** `src/serve.c`, function `tweak_include_arguments_for_server` (`include_options[]`); `include_server/parse_command.py` (`CPP_OPTIONS_APPEARING_AS_ASSIGNMENTS`)
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-08-05)
**Searched upstream issues/PRs for:** `--include=`, `tweak_include_arguments_for_server`, `force-include`, `isysroot`, `sysroot` — found PR #589 (`strip -iquote from remote compile argv`, a different mechanism entirely: `src/strip.c`'s client-side plain-mode argument stripping, not `serve.c`'s server-side pump-mode path rewriting) and general include-server issues (#40, #106, #474, #516, #48, #141), none matching this specific gap. No matching report found.

## The problem

GCC/Clang accept `-include file` (a two-token form) and `--include=file` (a combined, `=`-joined form) as equivalent ways to force-include a header. Server-side cpp (pump) mode needs to rewrite a client-supplied *absolute* path in either form so the server's compile step, running rooted at a per-job mirrored temp directory (`root_dir`), finds the file where the include server actually mirrored it — not at the client's own original path, which does not exist on the server.

`tweak_include_arguments_for_server()`'s `include_options[]` array recognizes the two-token `-include` form (and the combined, no-`=` form `-includefoo`) via a `str_startswith()` prefix match, but has no entry at all for `--include=`. Since `--include=/abs/path`'s second character (`-`) does not match `-include`'s second character (`i`), the array never matches it, so the path is never rewritten.

Separately, the Python include server's own option parser (`include_server/parse_command.py`) has the identical gap: it recognizes `-include` (`CPP_OPTIONS_MAYBE_TWO_WORDS`) but not `--include=` (`CPP_OPTIONS_APPEARING_AS_ASSIGNMENTS`, which already has exactly this shape of dict for `--sysroot=`). So a header pulled in only via `--include=` is never even identified as a dependency to mirror to the server in the first place, independent of the `serve.c` gap.

Both bugs need fixing together: without the include-server fix, the header never reaches the server's mirrored directory at all; without the `serve.c` fix, its path in the compile command still points at the client's own un-mirrored location even once the file has been mirrored.

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
}
```

`tweak_include_arguments_for_server()`'s existing rewrite logic (`str_startswith()` prefix match, then `checked_asprintf(&buf, "%s%s%s", include_option, root_dir, argv[i] + index_of_first_filename_char)`) is plain string prefixing with no other assumption about the matched option's shape, so listing `"--include="` (with the trailing `=` baked into the array entry, matching `prefix_map_options[]`'s own `"-ffile-prefix-map="`-style entries) is sufficient — no other logic change needed. Likewise, `parse_command.py`'s assignment-dict dispatch (`args[i].split('=', 1)`, then dict lookup on the left side) needed only the new `'--include'` key mapped to the same `include_files.append(arg)` action `-include` already uses.

## Empirical verification

Found investigating a real build failure compiling `aws-lc-sys` (BoringSSL) through pump mode — that crate's build uses `--include=` to force-include a generated header. Added a real regression test, `IncludeEqualsForceInclude_Case` (`test/testdistcc.py`): a pump-mode compile where the referenced macro comes exclusively from `--include=<absolute path>`, never from a normal `#include` (so a regression shows up as a genuine "undefined macro" compile failure, not ambiguously alongside a working normal include), and an extension to `parse_command_test.py`'s existing `test_ParseCommandArgs` coverage. Both pass on real GitHub Actions CI (`make_check`, ubuntu-latest and macOS-latest, both plain and pump-mode passes) against the actual, unmodified `distcc`/`distccd`/include-server code — see PR #416.
