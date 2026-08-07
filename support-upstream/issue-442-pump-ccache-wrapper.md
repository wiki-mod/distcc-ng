# Pump mode's include server can't see through a `ccache` wrapper (`compiler = args[0]`)

**Fork issue:** [wiki-mod/distcc-ng#442](https://github.com/wiki-mod/distcc-ng/issues/442) (briefly consolidated into #275 and closed, then reopened: #275 was a test-coverage sweep, not a fix-tracking issue, and closing it silently buried this still-real, unfixed bug with no live tracker -- #442 is the correct standalone home for actually fixing it)
**Fixed by:** [wiki-mod/distcc-ng#450](https://github.com/wiki-mod/distcc-ng/pull/450) (this fork only -- see "Fixed code" below)
**Upstream location:** `include_server/parse_command.py`, function `ParseCommandArgs`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-08-07)
**Searched upstream issues/PRs for:** `ccache`, `include server compiler`, `DISTCC_PREFIX` — found [distcc/distcc#230](https://github.com/distcc/distcc/issues/230) ("Allow DISTCC_PREFIX to use DistCC with other compiler wrappers such as CCache"), open, discussing a related but distinct problem: calling ccache *server-side* via a new `DISTCC_PREFIX` mechanism, and general ccache/distcc caching effectiveness. One comment on that thread independently corroborates this fork's own separate ccache+relative-path finding ("the reason that direct mode fails, is because the client source files are missing on the distcc server") and `distccd.1`'s own manpage already documents a related ccache caveat ("Because ccache does not cache compilation from .i files, it is not useful to call it from distccd."). No existing upstream report matches this entry's specific bug (pump mode's Python include server misidentifying the compiler when the client invokes `ccache <cc> ...`), open or closed.

## The problem

`ParseCommandArgs()` unconditionally treats the first argument of the compile command line as the compiler:

```python
compiler = args[0]
```

distcc itself correctly recognizes `ccache <cc> ...` as a normal, distributable compile command (`src/arg.c`'s `dcc_scan_args()` classifies it as "distribute" regardless of the `ccache` wrapper). But in pump mode, distcc also hands the *same* argv to the separate Python include server (over `$INCLUDE_SERVER_PORT`) for header-dependency analysis. That analyzer has no equivalent wrapper-awareness: it takes `args[0]` literally as "the compiler," so for `["ccache", "/bin/gcc", "-o", "out.o", "-c", "src.c"]` it sets `compiler = "ccache"` and then parses everything from index 1 onward -- starting with `/bin/gcc`, the real compiler -- as ordinary compile flags/file names instead.

## Upstream code (unchanged as of the commit above, upstream)

```python
def ParseCommandArgs(args, current_dir, includepath_map, dir_map,
                     compiler_defaults, timer=None):
  ...
  if len(args) < 2:
    raise NotCoveredError("Command line: too few arguments.")

  compiler = args[0]

  i = 1
  while i < len(args):
    ...
```

No check anywhere in this function (or its caller) for a known wrapper command (`ccache`, `distcc` itself via a masquerade symlink, or any other compiler-wrapper convention) before treating `args[0]` as the compiler.

## Fixed code (changed code as of the commit from distcc-ng fork)

Fixed in this fork (not upstream -- `distcc/distcc` is off-limits, see
`AGENTS.md` rule 50) by skipping a leading `ccache` wrapper before
treating `args[0]` as the compiler, deliberately narrow rather than a
general "detect any wrapper" mechanism -- a hardcoded arbitrary-name
heuristic would risk misparsing a genuine compiler invocation whose own
name happens to match, and `ccache` is the one wrapper this entry (and
`ScanArgs_Case`'s existing "distribute" classification) actually has
evidence for:

```python
  compiler = args[0]
  i = 1

  # A leading "ccache" wrapper (e.g. "ccache /usr/bin/gcc -c foo.c") is a
  # normal, distributable command -- src/arg.c's dcc_scan_args() already
  # classifies it as such on the C client side (ScanArgs_Case). Skip the
  # wrapper here too, so `compiler` is the real compiler and its argv
  # isn't misparsed as an extra file name (issue #442: two file_names
  # instead of one made ParseCommandArgs raise NotCoveredError below).
  if len(args) > 2 and os.path.basename(compiler) == 'ccache':
    compiler = args[1]
    i = 2

  while i < len(args):
    ...
```

## Empirical verification

Confirmed live (issue #442, 2026-08-07, buildtools container): before the
fix, `distcc ccache /bin/gcc -o testtmp.o -c testtmp.c` under pump mode
(`DISTCC_TESTING_INCLUDE_SERVER=1`, real `pump` wrapper, real include
server) failed outright with `DISTCC_FALLBACK=0`. The client's own
`DISTCC_LOG` trace showed:

```
distcc[78] (dcc_talk_to_include_server) Warning: include server gave up analyzing
distcc[78] (dcc_build_somewhere) Warning: failed to get includes from include server, preprocessing locally
distcc[78] (dcc_exit) exit: code 1
```

(`src/include_server_if.c:117`'s `rs_log_warning("include server gave up analyzing")` is the client-visible symptom of the include server's own parse failure returning an empty/error response.) Non-pump distcc, run with the identical `ccache <cc> ...` command line, was unaffected -- confirming the gap was specific to the Python include server's own argument parser, not `dcc_scan_args()`.

After the fix: `parse_command_test.py`'s new
`test_ParseCommandArgs_CcacheWrapper` unit test passes (a mock
`SetSystemDirsDefaults` raises if the wrong string is ever passed as
`compiler`, so it fails loudly if the wrapper isn't skipped correctly).
`CcacheHitThroughDistcc_Case` (`test/testdistcc.py`) now runs its real
compile-through-pump-mode calls for real instead of skipping, and a full
`make check` (both plain and pump mode, the complete real test suite)
passed clean: 174 OK, 26 NOTRUN, 0 FAIL.

A real ccache cache *hit* under pump mode is still not possible, for a
separate, deeper reason unrelated to this fix: distccd's server-side cpp
path (`src/serve.c`) reconstructs the client's directory tree under a
fresh `mkdtemp()`'d `temp_dir` (`/var/tmp/distccd-XXXXXX`) on literally
every job, so the absolute source path handed to the server-side
`ccache <cc> ...` invocation differs between compiles, defeating
ccache's cache key regardless of the source content being identical.
Confirmed live via `CCACHE_DEBUG`/`CCACHE_LOGFILE` tracing: both compiles
in `CcacheHitThroughDistcc_Case` show `Result: cache_miss` under pump
mode. Not yet tracked as its own issue.
