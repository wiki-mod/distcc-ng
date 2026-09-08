# Split DWARF (`-gsplit-dwarf`) has no external-`.dwo` transport for server-side cpp (pump mode)

**Fork issue:** [wiki-mod/distcc-ng#398](https://github.com/wiki-mod/distcc-ng/issues/398) section C (original design plan: [#305](https://github.com/wiki-mod/distcc-ng/issues/305), closed as consolidated)
**Fixed by:** [wiki-mod/distcc-ng#527](https://github.com/wiki-mod/distcc-ng/pull/527)
**Upstream location:** `src/serve.c` (`dcc_run_job` result path), `src/clirpc.c` (`dcc_retrieve_results`), `src/distcc.h` (`enum dcc_protover`)
**Checked against upstream commit:** `upstream/master` [`8d569d1`](https://github.com/distcc/distcc/commit/8d569d1) (checked 2026-09-07) -- upstream defines only protocols 1/2/3 (`src/distcc.h`), and neither `src/serve.c` nor `src/clirpc.c` contains any `DDWO`/`.dwo`/split-DWARF handling at all (verified: zero matches for `DDWO`/`dwo`/`split-dwarf` in both files; `clirpc.c` still carries only the `/* TODO: This code is highly specific to DCC_VER_3 */` note).

## The problem

In pump mode (server-side cpp), the compiler runs on the distccd server. When
a job is compiled with `-gsplit-dwarf`, the compiler emits an external `.dwo`
file next to the object file. Upstream's server-side-cpp result header is
`DOTO` (object) followed by `DOTD` (dependency file) with nothing between
them, and the client's `dcc_retrieve_results()` reads exactly that sequence.
There is no wire slot to carry the server-produced `.dwo` back, so it is
silently left on the server and never reaches the client. The resulting build
is missing its split-DWARF side files: debuggers cannot find the DWARF that
was split out, defeating the point of `-gsplit-dwarf`.

This is not distccd rejecting the flag -- the compile "succeeds" and the `.o`
is returned, so the loss is silent. It affects any pump-mode build that uses
`-gsplit-dwarf`.

## Upstream code (unchanged as of the commit above, upstream)

`src/distcc.h` -- only three protocol versions, none with a DDWO slot:

```c
enum dcc_protover {
    DCC_VER_1   = 1,            /**< vanilla */
    DCC_VER_2   = 2,            /**< LZO sprinkles */
    DCC_VER_3   = 3             /**< server-side cpp */
};
```

`src/serve.c`'s success path sends `DOTO` then (for server-side cpp) `DOTD`,
with no `DDWO` in between; `src/clirpc.c`'s `dcc_retrieve_results()` reads the
same, and has no `.dwo` handling anywhere.

## Fixed code (distcc-ng fork)

Two new fork protocol versions add a `DDWO` slot between `DOTO` and `DOTD`
(the 4000+ fork range, per issue #304's numbering policy): `DCC_VER_6000`
(LZO) and `DCC_VER_6001` (Zstd). The feature is a self-contained module,
`src/split_dwarf.c`, holding the `-gsplit-dwarf` argument detection, the
per-job protocol upgrade (3 -> 6000, 5000 -> 6001, only when the job stays
server-side cpp and requests an external `.dwo`), and the client-side DDWO
retrieval; core files only call in, all under `HAVE_SPLIT_DWARF_PUMP`
(`--disable-split-dwarf-pump`, on by default). An empty DDWO is skipped
without ending result retrieval, since DOTD still follows.

Per-job selection keeps ordinary pump jobs on protocol 3/5000, so a stock
`distccd` that does not know 600x rejects it cleanly rather than silently
dropping the `.dwo`.

## Empirical verification

Built inside `ghcr.io/wiki-mod/distcc-ng-buildtools` on a real host and driven
through the real `distcc`/`distccd`/pump pipeline (`make pump-single-test`):
`SplitDwarfLzoPumpCompile_Case` and `SplitDwarfZstdPumpCompile_Case`
(`test/testdistcc.py`) compile `-g -gsplit-dwarf -MD` and assert from the
server's own log that protocol 6000 / 6001 was negotiated, that the external
`.dwo` arrived (DDWO), and that the `.d` arrived after it (DOTD) -- both pass;
`ZstdPumpCompile_Case` (protocol 5000) still passes unchanged. A
`--disable-split-dwarf-pump` build compiles and the split-DWARF cases skip
cleanly (NotRunError).

Full details: [wiki-mod/distcc-ng#398](https://github.com/wiki-mod/distcc-ng/issues/398).
