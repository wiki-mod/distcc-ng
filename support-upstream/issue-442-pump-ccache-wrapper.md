# Pump mode's include server can't see through a `ccache` wrapper (`compiler = args[0]`)

**Fork issue:** [wiki-mod/distcc-ng#442](https://github.com/wiki-mod/distcc-ng/issues/442)
**Fixed by:** not yet implemented
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

Not implemented in this fork either. Teaching the include server to see through an arbitrary wrapper safely is a real design question for pump mode's own argument-parsing entry point -- it needs to decide *in general* how to recognize "this is a wrapper, the real compiler is the next token" (a hardcoded `"ccache"` special-case would miss any other wrapper, and a wrong guess risks misparsing a genuine compiler invocation whose own name happens to match). This fork's own `CcacheHitThroughDistcc_Case` (`test/testdistcc.py`, issue #275/PR #440) instead skips cleanly under pump mode with this exact reason, rather than asserting incorrect behavior or attempting a narrow, unreviewed fix to shared pump-mode parsing code.

## Empirical verification

Confirmed live (issue #275/PR #440, 2026-08-07): `distcc ccache /bin/gcc -o testtmp.o -c testtmp.c` under pump mode (`DISTCC_TESTING_INCLUDE_SERVER=1`, real `pump` wrapper, real include server) fails outright with `DISTCC_FALLBACK=0`. The client's own `DISTCC_LOG` trace shows:

```
distcc[78] (dcc_talk_to_include_server) Warning: include server gave up analyzing
distcc[78] (dcc_build_somewhere) Warning: failed to get includes from include server, preprocessing locally
distcc[78] (dcc_exit) exit: code 1
```

(`src/include_server_if.c:117`'s `rs_log_warning("include server gave up analyzing")` is the client-visible symptom of the include server's own parse failure returning an empty/error response.) Non-pump distcc, run with the identical `ccache <cc> ...` command line, is unaffected -- confirming the gap is specific to the Python include server's own argument parser, not `dcc_scan_args()`.
