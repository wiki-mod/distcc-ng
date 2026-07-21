# `tweak_arguments_for_server()` never rewrites `-f*-prefix-map=` build-path prefixes

**Fork issue:** [wiki-mod/distcc-ng#76](https://github.com/wiki-mod/distcc-ng/issues/76)
**Fixed by:** [wiki-mod/distcc-ng#276](https://github.com/wiki-mod/distcc-ng/pull/276)
**Upstream location:** `src/serve.c`, function `tweak_arguments_for_server()`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-21)
**Searched upstream issues/PRs for:** `prefix-map` — found upstream's own **open, unmerged** PR that proposes exactly this fix: [distcc/distcc#459](https://github.com/distcc/distcc/pull/459) ("Support `-f*-prefix-map` compiler options"), opened 2022-04-29. **Verified live via `gh pr view 459 --repo distcc/distcc --json state,mergedAt,createdAt,updatedAt` on 2026-07-21: `state: OPEN`, `mergedAt: null`, last activity 2025-11-03.** This is a point-in-time observation, not a standing fact — re-check the PR's live state before citing it as still-open in any future work; it could merge or close at any time after this date.

## Note on scope: an open upstream PR, not a fork-only finding

This isn't a bug this fork found independently — issue #76 was opened specifically to port upstream PR #459's own fix. It is documented here anyway because rule 57 requires a support-upstream check on every code-changing PR, and the underlying condition (`src/serve.c`'s current `master` still lacks any prefix-map handling) is a real, still-live gap in upstream's own source, not something upstream already fixed elsewhere that PR #459 merely duplicates. The correct status, as of the 2026-07-21 live check above: **upstream has an accepted-in-spirit-but-never-merged fix sitting unreviewed for roughly four years (opened 2022-04-29)**, and this fork adopted it directly rather than waiting. That "roughly four years" is anchored to the 2026-07-21 check date, not a fixed fact — it grows the longer PR #459 stays unmerged, and should be recomputed from the live `createdAt` if this entry is read much later.

## The problem

`tweak_arguments_for_server()` already rewrites the compiled-in-mirror-relative absolute path for `-I`/`-include`/... include options (`tweak_include_arguments_for_server()`) and for the source file argument itself (`tweak_input_argument_for_server()`), but does nothing for the `-ffile-prefix-map=`/`-fmacro-prefix-map=`/`-fdebug-prefix-map=`/`-fprofile-prefix-map=` family of GCC/Clang options. These options tell the compiler to rewrite an embedded absolute build-path prefix (in debug info, in `__FILE__`/`__LINE__` macro expansions, or in profile data) to something portable, for reproducible builds. When distcc's server-side `root_dir` mirror puts the same source at a different absolute path than the client sees, the `OLD` half of an unrewritten `OPTION=OLD=NEW` argument no longer matches anything the compiler actually sees server-side, so the substitution silently never fires — the client-visible symptom is a `-fdebug-prefix-map=` invocation whose debug info still contains the server's own build root instead of the mapped, portable path.

## Upstream code (unchanged as of the commit above, upstream)

```c
static const char *include_options[] = {
    "-I",
    "-include",
    ...
    NULL
};

/* tweak_include_arguments_for_server() as shown below, unchanged */

static int tweak_arguments_for_server(char **argv,
                                      const char *root_dir,
                                      const char *deps_fname,
                                      char **dotd_target,
                                      char ***tweaked_argv)
{
    ...
    tweak_include_arguments_for_server(*tweaked_argv, root_dir);
    tweak_input_argument_for_server(*tweaked_argv, root_dir);
    return 0;
}
```

No `prefix_map_options[]` array and no `tweak_prefix_map_arguments_for_server()` function exist anywhere in upstream's current `src/serve.c` — confirmed by `git show upstream/master:src/serve.c | grep prefix_map` returning no matches.

## Fixed code (changed code as of the commit from distcc-ng fork)

Ported PR #459's own diff verbatim into this fork's current `src/serve.c` (the surrounding function had not drifted from what PR #459 was written against, so it applied cleanly):

```c
static const char *prefix_map_options[] = {
    "-ffile-prefix-map=",
    "-fmacro-prefix-map=",
    "-fdebug-prefix-map=",
    "-fprofile-prefix-map=",
    NULL
};

static int tweak_prefix_map_arguments_for_server(char **argv,
                                                 const char *root_dir)
{
    int index_of_first_filename_char = 0;
    const char *prefix_map_option;
    unsigned int i, j;
    for (i = 0; argv[i]; ++i) {
        for (j = 0; prefix_map_options[j]; ++j) {
            if (str_startswith(prefix_map_options[j], argv[i])) {
                prefix_map_option = prefix_map_options[j];
                index_of_first_filename_char = strlen(prefix_map_option);
                if (argv[i][index_of_first_filename_char] == '/') {
                    char *buf;
                    checked_asprintf(&buf, "%s%s%s",
                                prefix_map_option,
                                root_dir,
                                argv[i] + index_of_first_filename_char);
                    if (buf == NULL) {
                        return EXIT_OUT_OF_MEMORY;
                    }
                    free(argv[i]);
                    argv[i] = buf;
                }
                break;
            }
        }
    }
    return 0;
}
```

...and added the call alongside the existing two tweaks in `tweak_arguments_for_server()`:

```c
    tweak_include_arguments_for_server(*tweaked_argv, root_dir);
    tweak_prefix_map_arguments_for_server(*tweaked_argv, root_dir);
    tweak_input_argument_for_server(*tweaked_argv, root_dir);
```

Also ported PR #459's `GdbPrefixMap_Case` test into `test/testdistcc.py`, adapted to this fork's current `Gdb_Case`/`GdbOpt*_Case` layout (our copy already differed slightly from what PR #459 patched — see PR body for the exact adaptation).

## Empirical verification

Full build/`make check`/real distributed-compile evidence is in the fixing PR's body (linked above). Summary of the decisive before/after check: `GdbPrefixMap_Case`'s own pass/fail doesn't actually distinguish patched from unpatched (upstream's own comment on the test candidly says checking the substitution automatically "doesn't add much value" — the test only confirms gdb can still debug the binary via an explicit `directory` workaround), so the real proof is in the compiled debug info itself. Reproducing the exact scenario `tweak_prefix_map_arguments_for_server()` targets (server compiles in a per-job mirror directory whose absolute path differs from the client's `-fdebug-prefix-map=OLD=NEW` argument) on the 2026-07-21 real-host verification:

- **Unpatched** (`OLD` left as the bare client-side path, not rewritten with the server's real per-job `root_dir`): `readelf --debug-dump=info` on the resulting object shows `DW_AT_comp_dir: /tmp/rootdir_sim/work/_testtmp/GdbPrefixMap_Case` — the raw, un-substituted server-side directory leaks into the debug info; the compiler's `-fdebug-prefix-map=` substitution silently never fired because `OLD` didn't match its actual compile-time working directory.
- **Patched** (`OLD` has `root_dir` prepended, matching the real per-job mirror directory): same `readelf` check on the resulting object shows `DW_AT_comp_dir: .` — exactly the portable, mapped value the flag was supposed to produce.
