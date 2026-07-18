# Protocol version 4 (zstd) could silently misconfigure a distccd built without zstd support

**Fork issue:** [wiki-mod/distcc-ng#225](https://github.com/wiki-mod/distcc-ng/issues/225)
**Fixed by:** [wiki-mod/distcc-ng#231](https://github.com/wiki-mod/distcc-ng/pull/231)

## Note on scope: this is not a "still-broken upstream" entry

zstd compression (`DCC_COMPRESS_ZSTD`, protocol version 4) is a distcc-ng-only
addition -- upstream `distcc/distcc`'s `dcc_get_features_from_protover()`
(`src/hosts.c`) has no `DCC_COMPRESS_ZSTD` case at all (verified: zero matches
for that identifier in upstream's current source). This bug and its fix are
entirely specific to this fork's own zstd feature and have no upstream
equivalent to document, unlike most other entries in this folder. Recorded
here anyway per this fork's support-upstream/README.md convention of noting
every fix, so the reasoning for *not* filing a standard "still present
upstream" entry is explicit rather than the entry being silently skipped.

## What happened

`src/hosts.c`'s `dcc_get_features_from_protover()` mapped protocol version 4
to `DCC_COMPRESS_ZSTD` unconditionally, regardless of whether this build of
`distccd`/`distcc` actually has zstd support compiled in (`HAVE_ZSTD`). A
peer claiming protover 4 against a non-zstd-built binary reached
`src/bulk.c`'s `dcc_x_file_compressed()`'s send path with an uninitialized
`out_buf`/`out_len` (see issue #224's sibling finding), and separately, the
caller of `dcc_get_features_from_protover()` in `src/serve.c` never checked
its return value, so even the function's own existing rejection paths
(protover 0 or `>= __DCC_VER_MAX`) had no actual effect on the connection.

## Fixed code (changed code as of the commit from distcc-ng fork)

`dcc_get_features_from_protover()` now rejects protover 4 outright (returns
non-zero, logs an error) when `HAVE_ZSTD` is undefined, instead of silently
falling back to `DCC_COMPRESS_NONE` -- a silent fallback would have caused a
wire-format desync anyway, since LZO and zstd use different token formats
(`dcc_x_token_int` vs `dcc_x_token_2int`) and the client commits to one
before the server gets any chance to object. `src/serve.c`'s caller now
actually checks the return value and aborts the connection cleanly.
`src/bulk.c`'s `dcc_x_file_compressed()` also got a defense-in-depth
fallback for the same `DCC_COMPRESS_ZSTD`-without-`HAVE_ZSTD` case, in case
a future code path reaches it without going through this guard.

## Empirical verification

Two real builds (with and without `--without-zstd`) tested against each
other with a real `distcc` client explicitly requesting zstd
(`DISTCC_HOSTS=127.0.0.1:PORT,zstd`) against a real `distccd` built without
zstd support:

- **Before the fix** (original `hosts.c`, unpatched): the receiving side's
  existing, already-correct `#ifdef HAVE_ZSTD` guard in `pump.c`'s
  `dcc_r_bulk()` happened to catch this specific compile (non-empty
  preprocessed source), but the underlying `hosts.c`/`serve.c` gap remained
  live for any code path that guard doesn't cover (e.g. the send-back path
  in `bulk.c`, or a 0-byte input that bypasses `dcc_r_bulk()`'s length
  check entirely).
- **After the fix**: rejected immediately, before any argv or file data is
  exchanged --
  ```
  distccd (dcc_get_features_from_protover) ERROR: peer requested protocol
    version 4 (zstd), but this build has no zstd support
  distccd (dcc_run_job) ERROR: client requested unsupported protocol
    features (protover 4)
  distccd (dcc_job_summary) ... REJ_BAD_REQ ... time:0ms
  ```

`make check`'s full real test suite passed with zero regressions on both
the `--without-zstd` and normal (zstd-enabled) builds.
