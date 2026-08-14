# `dcc_fix_debug_info()` silently fails to rewrite compressed ELF debug sections

**Fork issue:** [wiki-mod/distcc-ng#398](https://github.com/wiki-mod/distcc-ng/issues/398)
**Fixed by:** [wiki-mod/distcc-ng#487](https://github.com/wiki-mod/distcc-ng/pull/487)
**Upstream location:** `src/fix_debug_info.c`, functions `update_section`/`replace_string`/`dcc_fix_debug_info`
**Checked against upstream commit:** [`1ff5357c`](https://github.com/distcc/distcc/commit/1ff5357cb2dd570501d07114aceb90260059ad3f) (`master`, checked 2026-08-14) -- the same commit that added `.debug_line_str` handling for DWARF 5's `comp_dir` relocation; this fork's copy of the file is otherwise byte-identical to upstream's at this commit (`replace_string`/`update_section` at the same line numbers, 236/362).
**Searched upstream issues/PRs for:** `SHF_COMPRESSED compressed debug`, `fix_debug_info compressed`, `compressed debug section`, `gz=zlib gdb`, `elf_compress`, `compress-debug-sections` -- no matching report or fix attempt found, open or closed.

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

Full details: [wiki-mod/distcc-ng#398](https://github.com/wiki-mod/distcc-ng/issues/398).
