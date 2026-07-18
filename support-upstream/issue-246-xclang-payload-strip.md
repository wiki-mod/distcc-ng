# `-Xclang <arg>` payload is mis-stripped / re-interpreted as a distcc flag

**Fork issue:** [wiki-mod/distcc-ng#246](https://github.com/wiki-mod/distcc-ng/issues/246)
**Fixed by:** [wiki-mod/distcc-ng#247](https://github.com/wiki-mod/distcc-ng/pull/247)
**Upstream location:** `src/strip.c`, function `dcc_strip_local_args()`; `src/arg.c`, function `dcc_scan_args()`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-18)
**Searched upstream issues/PRs for:** `Xclang`, `strip local args`, `target-feature`, `-x language` — no upstream report found describing `-Xclang`-introduced tokens being stripped or re-interpreted; the closest related strip-argv threads are distcc/distcc#582 and #589 (local include-search leakage, unrelated to `-Xclang`).

## The problem

clang's `-Xclang <arg>` passes `<arg>` verbatim to clang's `cc1` frontend; `<arg>` is not a driver/preprocessor/link flag and distcc must not interpret or remove it. Neither `dcc_strip_local_args()` nor `dcc_scan_args()` has any concept of this: each token is matched independently against distcc's own flag tests. When a `-Xclang` payload token happens to look like a recognized flag it is silently mishandled:

- In `dcc_strip_local_args()`, a payload beginning with `-l` matches the `-l<lib>` prefix test and a payload beginning with `-x` matches the `-x<lang>` prefix test, so the payload is **dropped** from the argv shipped to the remote host — leaving the preceding `-Xclang` dangling and producing an argv the remote clang rejects.
- In `dcc_scan_args()`, a payload beginning with `-x` satisfies the `str_startswith("-x", a)` "gcc's -x handling is complex" test and forces the whole compile local (`EXIT_DISTCC_FAILED`).

Upstream does not *auto-generate* such tokens (it has no `-march=native`-to-`cc1` resolution — that is this fork's feature, distcc/distcc#384 is still an unmerged draft), so the reliable trigger is fork-specific. But the mishandling itself is in upstream's own, unchanged argv-scanning code and is reachable in upstream whenever a user passes a `-Xclang <arg>` whose `<arg>` begins with `-l` or `-x` (e.g. `clang -Xclang -xop-style-frontend-arg …`, or any `-Xclang -l…` frontend option): the payload is stripped/forced-local rather than forwarded verbatim. It is a latent correctness bug in the general argv handling, not a fork-only artifact.

## Upstream code (unchanged as of the commit above, upstream)

`src/strip.c`, `dcc_strip_local_args()` — the `-l`/`-x` prefix tests with no `-Xclang` guard ahead of them:

```c
        if (str_equal("-D", from[from_i])
            || ...
            || str_equal("-l", from[from_i])
            || ...) {
            /* skip next word, being option argument */
            if (from[from_i+1])
                from_i++;
        }
        else if (str_startswith("-Wp,", from[from_i])
                 || ...
                 || str_startswith("-l", from[from_i])
                 || ...
                 || str_startswith("-stdlib", from[from_i])) {
            /* Something like "-DNDEBUG" ... Just skip this word */
            ;
        }
```

(`-x` is added to both lists in this fork; even upstream's stock list already
mis-strips a `-Xclang -l…` payload via the `-l` prefix.)

`src/arg.c`, `dcc_scan_args()` — the `-x` test with no `-Xclang` guard:

```c
            } else if (str_startswith("-x", a)
                       && argv[i+1]
                       && !str_startswith("c", argv[i+1])
                       && !str_startswith("c++", argv[i+1])
                       && !str_startswith("objective-c", argv[i+1])
                       && !str_startswith("objective-c++", argv[i+1])
                       && !str_startswith("go", argv[i+1])
                       ) {
                rs_log_info("gcc's -x handling is complex; running locally for %s", ...);
                return EXIT_DISTCC_FAILED;
```

Neither function has any special-casing of `-Xclang`, so a `-Xclang`-introduced payload is treated exactly like a user-typed driver flag.

## Fixed code (this fork, PR #247)

A uniform structural guard applied in every argv scanner that sees the resolved argv: a token immediately preceded by `-Xclang` is opaque cc1 payload and is passed through / skipped without matching any flag test.

`dcc_strip_local_args()` (and, for the same invariant, `dcc_strip_dasho()` — a no-op for today's tokens but kept consistent so the whole class is closed at every scanner):

```c
        if (str_equal("-Xclang", from[from_i]) && from[from_i+1]) {
            to[to_i++] = from[from_i++];        /* "-Xclang" */
            to[to_i++] = from[from_i];          /* its verbatim payload */
            continue;
        }
```

`dcc_scan_args()`:

```c
        if (i > 0 && !strcmp(argv[i-1], "-Xclang"))
            continue;
```

## Empirical verification

Built both the stock-shaped and fixed code and ran a real distributed `clang -march=native` compile through a real `distccd`, verdict taken from the server's own independent job log:

- **Baseline** (drop present): server log `COMPILE_ERROR exit:1 … clang probe.c`; the client's own trace shows the `-lwp`/`-xop` values present in the `dcc_strip_dasho` result line but gone from the very next `dcc_strip_local_args` result line — isolating the drop to that function.
- **`strip.c` fix only**: the values now reach the server, but the compile still fails — `dcc_job_summary … OTHER … ret:100` (`EXIT_DISTCC_FAILED`) — because the server's `dcc_scan_args()` `-x` test then rejects the transmitted `-xop`. This is the empirical proof the two sites are one class.
- **Both fixes**: server log `COMPILE_OK exit:0 … clang probe.c`, object produced.

Confirmed on both a two-container bridge and two independent physical hosts (fixed client → `COMPILE_OK`, unpatched client against the same server → `COMPILE_ERROR`, from the server's own log). gcc `-march=native` (bare `-m*` tokens, never `-Xclang`-wrapped) is unaffected in every configuration.
