# lsdistcc / masquerade: unbounded `sprintf` from caller-controlled input

**Fork issue:** [wiki-mod/distcc-ng#143](https://github.com/wiki-mod/distcc-ng/issues/143)
**Fixed by:** [wiki-mod/distcc-ng#PRNUM](https://github.com/wiki-mod/distcc-ng/pull/PRNUM)
**Upstream location:** `src/lsdistcc.c`, function `generate_query`; `src/climasq.c`, function `dcc_support_masquerade`; `src/util.c`, function `dcc_trim_path`
**Checked against upstream commit:** [`8d569d192141615e26a3f0b65315822e7c814c3d`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-18)
**Searched upstream issues/PRs for:** `lsdistcc sprintf`, `canned_query` — no matching issue or PR found (0 results); not tracked upstream.

## The problem

Three call sites write into a buffer with a bare `sprintf` from input whose
length is caller-controlled:

1. `src/lsdistcc.c:314/332/359` — `generate_query()` formats the compiler
   name from the `-p` command-line option into the fixed global
   `char canned_query[1000]` with `sprintf`. A compiler name longer than the
   fixed format overhead overflows the global buffer. Reachable directly:
   `generate_query()` runs at startup whenever `-p` is given, before any
   network activity.
2. `src/climasq.c:109` — `dcc_support_masquerade()` does
   `sprintf(buf + len, "/%s", progname)`. In-bounds by construction today
   (`len` is one `':'`-separated `PATH` component, always
   `<= strlen(envpath)`, and `buf` is sized
   `strlen(envpath)+1+strlen(progname)+1`), but written unboundedly.
3. `src/util.c:378` — `dcc_trim_path()` does the identical
   `sprintf(buf + len, "/%s", compiler_name)` masquerade idiom, same
   provable-but-unbounded shape. Not even flagged by CodeQL; it is the
   un-flagged twin of #2, found by grepping for the idiom rather than
   trusting the scanner's coverage.

Site 1 is a genuine overflow (caller controls the length). Sites 2/3 are
defensive hardening of a provably-safe-today idiom so the bound is explicit
rather than resting on an invariant a future edit could break.

## Upstream code (unchanged as of the commit above, upstream)

```c
/* src/lsdistcc.c, generate_query() */
sprintf(canned_query,
        canned_query_fmt_protocol_1,
         (unsigned)strlen(opt_compiler), opt_compiler,
         (unsigned)strlen(program), program);

/* src/climasq.c, dcc_support_masquerade() */
strncpy(buf, p, (size_t) len);
sprintf(buf + len, "/%s", progname);

/* src/util.c, dcc_trim_path() */
strncpy(buf, p, len);
sprintf(buf + len, "/%s", compiler_name);
```

## Fixed code (changed code as of the commit from distcc-ng fork)

```c
/* src/lsdistcc.c: bounded, plus a guard on the trailing binary memcpy so a
 * truncated header cannot overrun canned_query on protocol 2/3. */
snprintf(canned_query, sizeof(canned_query),
        canned_query_fmt_protocol_1,
         (unsigned)strlen(opt_compiler), opt_compiler,
         (unsigned)strlen(program), program);

/* src/climasq.c and src/util.c: keep the allocation size in a variable and
 * bound the write with it (bufsize - len is always >= strlen(progname)+2). */
size_t bufsize = strlen(envpath) + 1 + strlen(progname) + 1;
...
snprintf(buf + len, bufsize - len, "/%s", progname);
```

## Empirical verification

Built `lsdistcc` under AddressSanitizer (`-fsanitize=address`) on real Linux
(x86_64, gcc 14, WSL2 ext4) and drove `generate_query()` via
`lsdistcc -P<1|2|3> -p<2000-byte-name> no.such.host.invalid`.

Upstream/pristine `current_dev` code — AddressSanitizer reports a real
global-buffer-overflow write past `canned_query`:

```
==4638==ERROR: AddressSanitizer: global-buffer-overflow ...
WRITE of size 2135 at 0x... thread T0
    #2 ... in generate_query src/lsdistcc.c:315
0x... is located 0 bytes to the right of global variable 'canned_query'
    defined in 'src/lsdistcc.c:147:6' of size 1000
SUMMARY: AddressSanitizer: global-buffer-overflow ... in __interceptor_vsprintf
```
(also fires from `src/lsdistcc.c:360`, protocol 3, WRITE of size 2160).

Fork/fixed code — clean exit, no AddressSanitizer error (protocol 1 truncates
safely; protocol 2/3 hit the explicit over-size guard and exit with a logged
error). Full `make check` (comfychair suite, `test/testdistcc.py`) passes with
the fix in place, including `ModeBits_Case`.
