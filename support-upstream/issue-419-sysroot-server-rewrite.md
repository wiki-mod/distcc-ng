# `-isysroot`/`--sysroot=` never rewritten for the server in pump mode

**Fork issue:** none filed
**Fixed by:** [wiki-mod/distcc-ng#419](https://github.com/wiki-mod/distcc-ng/pull/419)
**Upstream location:** `src/serve.c`, function `tweak_include_arguments_for_server` (`include_options[]`)
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-08-05)
**Searched upstream issues/PRs for:** `isysroot`, `sysroot`, `tweak_include_arguments_for_server` — found PR #531 ("Add sysroot option and allow -specs option from compiler", merged, touches `src/serve.c`/`src/dopt.c`). Checked its actual diff/description directly rather than assuming from the title: it is unrelated to this finding — it adds `distccd`'s own `--sysroot` *daemon* command-line flag (`arg_sysroot`, used only to resolve a `-specs=` file server-side), not any handling of the compiler's own client-supplied `-isysroot`/`--sysroot=` argument. No report matching this specific rewriting gap found.

## The problem

Unlike `--include=`/`--imacros=` (`issue-416-...`/`issue-418-...`, where only the `=`-joined form was missing), `-isysroot`/`--sysroot=` have **no entry at all** in `tweak_include_arguments_for_server()`'s `include_options[]` — neither form, in either shape.

`include_server/parse_command.py` already tracks both forms (`-isysroot` via `CPP_OPTIONS_MAYBE_TWO_WORDS`, `--sysroot=` via `CPP_OPTIONS_APPEARING_AS_ASSIGNMENTS`) and uses the resolved sysroot to compute which absolute system-include directories need mirroring to the server (`compiler_defaults.py`'s `SetSystemDirsDefaults()`/`_SystemSearchdirsGCC()`, which runs the real compiler locally with the client's sysroot to ask what its default header search directories are). So the header *content* under a client-supplied sysroot correctly lands in the server's mirrored `root_dir` tree.

But the compile command actually sent to and executed on the server still names the client's own, un-mirrored absolute sysroot path (e.g. `-isysroot /Users/dev/sdk`). The server compiler then looks for headers under that literal path — which does not exist on the server — instead of where the include server actually mirrored them (`root_dir` + that path). This affects any pump-mode cross-compile-style build that passes an explicit sysroot (common for macOS SDK targeting, Android NDK, and other embedded toolchains).

## Upstream code (unchanged as of the commit above, upstream)

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

(`-isysroot`/`--sysroot=` absent; the only `sysroot`-related code in `serve.c` is `arg_sysroot`, an unrelated `distccd --sysroot` *daemon* command-line flag used only for `-specs=` file resolution — not the compiler's own client-supplied sysroot argument.)

## Fixed code (changed code as of the commit from distcc-ng fork)

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
    "-isysroot",
    "--sysroot=",
    NULL
};
```

`tweak_include_arguments_for_server()`'s existing rewrite is plain string prefixing (`checked_asprintf(&buf, "%s%s%s", include_option, root_dir, argv[i] + index_of_first_filename_char)`) with no assumption distinguishing a file argument from a directory argument, so adding these two entries is sufficient on its own — no other logic change needed.

## Empirical verification

Found via the same deliberate sweep that found `--imacros=`'s gap (after fixing `--include=`, #416), cross-checking every option in `serve.c`'s table against what `include_server/parse_command.py` already tracks. Confirmed the rewrite fix works via a real CI run: the compile command in the server's log correctly showed `root_dir` prepended to the sysroot path (`-isysroot <root_dir><original client path>`) after the fix, versus the bare, unrewritten original path before it.

The added regression test, `SysrootAbsolutePath_Case` (`test/testdistcc.py`), deliberately checks the server's own log for this rewritten argument directly, rather than requiring a full successful compile against a fully self-contained fake sysroot: coupling both in one test proved fragile across compilers during development (a real, reproduced CI failure on macOS/clang, not on Linux/gcc, traced to `compiler_defaults.py`'s system-directory *discovery* for a non-standard sysroot — a separate, pre-existing question from whether `serve.c` rewrites the sysroot argument's own path, which is the only thing this specific fix addresses). See PR #419 for the full before/after CI evidence.
