# Zstd + server-side cpp (pump mode) combination has no protocol version

**Fork issue:** [wiki-mod/distcc-ng#101](https://github.com/wiki-mod/distcc-ng/issues/101)
**Fixed by:** wiki-mod/distcc-ng#TBD (opened alongside this entry)

## Note on scope: this is not a "still-broken upstream" entry

Zstd compression (`DCC_COMPRESS_ZSTD`) is itself a distcc-ng-only addition —
see `issue-225-zstd-protover-guard.md` in this same folder, which already
established that upstream `distcc/distcc`'s `dcc_get_features_from_protover()`
(`src/hosts.c`) has no `DCC_COMPRESS_ZSTD` case at all. Upstream's
`enum dcc_protover` (`src/distcc.h`) tops out at `DCC_VER_3` (verified
against upstream commit
[`8d569d1`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d),
`master`, checked 2026-07-23 — no `DCC_VER_4` or `DCC_VER_5` at all).
Zstd support was proposed upstream as
[distcc/distcc#232](https://github.com/distcc/distcc/pull/232) (2017,
closed unmerged) and again as
[distcc/distcc#236](https://github.com/distcc/distcc/pull/236) ("protocol
version 4: zstd compression support, -gsplit-dwarf support", opened 2020,
still open/unmerged as of the check above) — this fork's `DCC_VER_4`
(recovered per `CLAUDE.md`'s Key Design Decisions) is this fork's own
adoption of that same unmerged work.

Since zstd doesn't exist upstream at all, the *combination* this entry is
about — zstd plus server-side cpp (pump mode) — cannot exist as a gap
upstream either: there is no zstd protocol version for pump mode to be
missing from. Searched upstream issues and pull requests for `zstd pump`
and `zstd cpp`: no results beyond the two zstd PRs above, neither of which
mentions pump mode / server-side cpp at all. This entry documents that
absence explicitly, per this folder's convention (see
`issue-225-zstd-protover-guard.md`), rather than silently skipping a
support-upstream entry for a code-changing PR.

## What happened in this fork

Before this fix, `src/hosts.c`'s `dcc_get_protover_from_features()` had
cases for every other `(compr, cpp_where)` pairing distcc-ng supports —
`(NONE, CLIENT)` → `DCC_VER_1`, `(LZO1X, CLIENT)` → `DCC_VER_2`,
`(LZO1X, SERVER)` → `DCC_VER_3`, `(ZSTD, CLIENT)` → `DCC_VER_4` — but no
case for `(ZSTD, SERVER)`. A host specification combining `,zstd` and
`,cpp` therefore left `*protover` at its initialized `-1` sentinel, and
`dcc_parse_options()` rejected the whole host with "invalid host options"
at parse time (issue #87's investigation surfaced this as a real user-
facing gap, worked around there by making `,lzo` the auto-appended default
rather than fixing the underlying gap).

## Fixed code (changed code as of the commit from distcc-ng fork)

`src/distcc.h` gained `DCC_VER_5` for `(ZSTD, SERVER)`; `src/hosts.c`'s
`dcc_get_protover_from_features()`/`dcc_get_features_from_protover()` now
recognize it symmetrically. Wiring the two previously-independent features
(zstd compression, server-side cpp) together surfaced two real interaction
bugs, not just an additive change:

- `src/serve.c`'s `dcc_r_many_files()` call (the header-closure receive,
  used only in pump mode) was passing the top-level negotiated `compr`
  straight through. For `DCC_VER_3` that happened to be `DCC_COMPRESS_LZO1X`
  already, so the bug was invisible; for `DCC_VER_5` it would have been
  `DCC_COMPRESS_ZSTD` — but the include server
  (`include_server/compress_files.py`) always LZO-compresses that closure
  regardless of the negotiated wire protocol, so this would have fed
  LZO-compressed bytes into zstd decompression. Fixed by pinning that one
  call site to `DCC_COMPRESS_LZO1X` explicitly.
- `src/clirpc.c`'s `dcc_retrieve_results()` read the `DOTD` (dependency
  file) token with the single-int length format unconditionally whenever
  `cpp_where == DCC_CPP_ON_SERVER`, because until `DCC_VER_5` that
  combination only ever paired with LZO (`DCC_VER_3`), whose format needs
  no separate uncompressed length. `DCC_VER_5` sends `DOTD` zstd-compressed
  (2-int format, needed because `dcc_r_bulk_zstd()` requires the real
  uncompressed size up front), so the client would have desynced reading
  it. Fixed by keying the format choice off `host->compr` instead.

Split dwarf (`DDWO`) was deliberately *not* extended to `DCC_VER_5`: pump
mode's result-header ordering ends at `DOTD`, with no slot for a `DDWO`
token in between without a further wire-format bump, and split dwarf has
never been wired for server-side cpp in any prior protocol version either.
See `doc/protocol-5.txt` and `src/distcc.h`'s `DCC_VER_5` comment.

## Empirical verification

See the PR body for wiki-mod/distcc-ng#101's fix for the full real
two-host verification (real `distccd` + real pump client, `DISTCC_FALLBACK=0`,
server log confirming `DCC_VER_5` negotiation) and `make check` results —
not duplicated here since none of it involves upstream code.
