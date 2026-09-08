# `dcc_fix_debug_info()` silently fails to rewrite compressed ELF debug sections

**Fork issue:** [wiki-mod/distcc-ng#398](https://github.com/wiki-mod/distcc-ng/issues/398)
**Fixed by:** [wiki-mod/distcc-ng#487](https://github.com/wiki-mod/distcc-ng/pull/487) (`SHF_COMPRESSED`) and [wiki-mod/distcc-ng#526](https://github.com/wiki-mod/distcc-ng/pull/526) (legacy GNU `.zdebug_*`)
**Upstream location:** `src/fix_debug_info.c`, functions `update_section`/`replace_string`/`update_debug_info`/`dcc_fix_debug_info`
**Checked against upstream commit:** [`1ff5357c`](https://github.com/distcc/distcc/commit/1ff5357cb2dd570501d07114aceb90260059ad3f) (`master`, checked 2026-08-14) for the `SHF_COMPRESSED` case; re-confirmed still unfixed on `master` [`8d569d1`](https://github.com/distcc/distcc/commit/8d569d1) (checked 2026-09-07) for the GNU `.zdebug_*` case -- upstream's `update_debug_info()` walks only `.debug_info`/`.debug_str`/`.debug_line_str` (no `.zdebug_*` names) and has no `SHF_COMPRESSED`, `elf_compress`, or `elf_compress_gnu` handling anywhere.
**Searched upstream issues/PRs for:** `SHF_COMPRESSED compressed debug`, `fix_debug_info compressed`, `compressed debug section`, `gz=zlib gdb`, `elf_compress`, `compress-debug-sections`, `zdebug` -- no matching report or fix attempt found, open or closed.

## The problem

In pump mode, `dcc_fix_debug_info()` rewrites the server-side compilation
directory baked into a compiled object's DWARF debug info back to the
client-side path, via a raw byte search-and-replace directly on the
mmap'd `.debug_info`/`.debug_str`/`.debug_line_str` section contents
(`update_section`/`replace_string`). This assumes the search string is
still present byte-for-byte in the section's raw bytes -- true only when
the section is uncompressed.

When the assembler compresses a debug section (`SHF_COMPRESSED`, e.g. via
`as --compress-debug-sections=zlib`, dispatched by `gcc -gz=zlib` or by
some distros'/toolchains' own default flags), the search string only
exists in *decompressed* form; the raw compressed bytes never contain it.
`replace_string()`'s `memcmp` scan finds zero occurrences, and the
function returns success anyway -- the rewrite silently never happens.
The binary keeps its server-side compilation directory baked in; `gdb`
(client-side) then cannot locate the source file.

This is not specific to any one distro's toolchain: it is
size-dependent (the assembler only compresses a section once its content
crosses a size threshold), so it can pass on a short build path and fail
on a longer, more realistic one -- e.g. a CI runner's deeper workspace
path, or (in `distccd`'s own case) its server-side temp-directory path
concatenated with the client's own working directory.

### GNU `.zdebug_*` variant (fork PR #526)

There is a second, older compression form: GNU-style, produced by
`-Wa,--compress-debug-sections=zlib-gnu`. It carries **no**
`SHF_COMPRESSED` flag; instead the section is renamed with a `z` prefix
(`.debug_info` -> `.zdebug_info`) and holds a `ZLIB` magic + size header.
Upstream is doubly blind to it: `update_debug_info()` never lists any
`.zdebug_*` name, and even if it did, the raw scan would still see
compressed bytes. The same silent no-rewrite results.

## Upstream code (unchanged as of the commit above, upstream)

```c
static int replace_string(void *base, size_t size,
                           const char *search, const char *replace) {
  char *start = (char *) base;
  char *end = (char *) base + size;
  int count = 0;
  char *p;
  size_t search_len = strlen(search);
  size_t replace_len = strlen(replace);

  assert(replace_len == search_len);

  if (size < search_len + 1)
    return 0;
  for (p = start; p < end - search_len - 1; p++) {
    if (memcmp(p, search, search_len) == 0) {
      memcpy(p, replace, replace_len);
      count++;
    }
  }
  return count;
}
```

No check anywhere in `update_section()`/`FindElfSection()` for the
section's `sh_flags & SHF_COMPRESSED` bit before running this scan.

## Fixed code (changed code as of the commit from distcc-ng fork)

Adds an optional `libelf` (elfutils) code path, preferred over the raw
`<elf.h>` one when available, that decompresses the section before the
same `replace_string()` scan runs unchanged, then recompresses it and
writes the file back via `elf_update()`, which recomputes the ELF layout
itself (a same-length decompressed edit can still change the
*compressed* size):

```c
was_compressed = (shdr.sh_flags & SHF_COMPRESSED) != 0;
if (was_compressed && elf_compress(scn, 0, 0) < 0) {
  /* trace + return 0, leaving this section unrewritten */
}

data = elf_getdata(scn, NULL);
count = replace_string(data->d_buf, data->d_size, search, replace);
if (count > 0) {
  elf_flagdata(data, ELF_C_SET, ELF_F_DIRTY);
}

if (was_compressed) {
  int rc = elf_compress(scn, ELFCOMPRESS_ZLIB, 0);
  if (rc == 0) {
    rc = elf_compress(scn, ELFCOMPRESS_ZLIB, ELF_CHF_FORCE);
  }
  /* rc < 0: abort without calling elf_update(), leaving the file
   * untouched rather than half-edited */
}
```

PR #526 extends this: a `.zdebug_*` section (detected by name prefix,
since it has no `SHF_COMPRESSED` flag) is (de)compressed with
`elf_compress_gnu()` instead of `elf_compress()`, with the same
`ELF_CHF_FORCE` retry and the same abort-the-write-on-failed-recompress
contract; the `.zdebug_*` name is preserved so no rename is needed. The
three `.zdebug_*` names are added to the section list `update_debug_info_libelf()` walks. This also makes the pre-existing
`AC_CHECK_FUNCS([elf_compress_gnu])` probe load-bearing (it was checked
but never called).

`configure.ac` gains a `--with-libelf` probe (`PKG_CHECK_MODULES` plus a
real `AC_CHECK_FUNCS([elf_compress elf_compress_gnu])` probe, not an
assumed minimum elfutils version) with graceful degradation to the
existing raw path -- never a hard configure failure -- when a new-enough
`libelf` isn't present, matching this fork's existing optional-dependency
pattern for `zstd`/`libseccomp`.

## Empirical verification

Built and ran the project's own `h_fix_debug_info` `TEST`-mode harness
against a real `gcc -gz=zlib -g -c` object with a long, realistic
compilation-directory path (reliably crosses the compression threshold on
`.debug_line_str`, confirmed via `readelf -SW`'s `C` flag) inside
`ghcr.io/wiki-mod/distcc-ng-buildtools` on a real host: the unfixed code
traces "has no occurrences" and leaves `DW_AT_comp_dir` unchanged; the
`libelf`-fixed code correctly rewrites it, the section stays compressed,
and the resulting object still links and runs correctly. Also verified
end-to-end through the real `distcc`/`distccd` pump-mode pipeline via a
new `GdbCompressedDebugInfo_Case` test (`test/testdistcc.py`, forces
`-gz=zlib` on `Gdb_Case`'s existing compile-link-gdb-verify flow): passes
with the fix, and confirmed `--without-libelf` still builds and links
cleanly with the prior (raw-path, unfixed-for-compression) behavior
unchanged.

For the GNU `.zdebug_*` variant (PR #526): built `h_fix_debug_info` from
the unfixed and fixed trees against a fixture whose `DW_AT_comp_dir` lands
in `.zdebug_info` (`-gdwarf-4 -gstrict-dwarf -fno-merge-debug-strings
-Wa,--compress-debug-sections=zlib-gnu`), inside
`ghcr.io/wiki-mod/distcc-ng-buildtools` on a real host: the unfixed code
traces `has no ".debug_info" section` and leaves the path unrewritten; the
fixed code rewrites it, the section stays `.zdebug_info`, and the object
relinks and runs. Covered end-to-end by a new `FixDebugInfoGnuCompressed_Case` (`test/testdistcc.py`), which skips
where the toolchain emits no `.zdebug_*` section so it never passes
vacuously; the plain and `SHF_COMPRESSED` `Gdb_Case`s still pass unchanged.

Full details: [wiki-mod/distcc-ng#398](https://github.com/wiki-mod/distcc-ng/issues/398).
