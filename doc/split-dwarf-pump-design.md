# Split DWARF in pump mode: design

Tracking: [wiki-mod/distcc-ng#398](https://github.com/wiki-mod/distcc-ng/issues/398) section C (umbrella). Original design plan and rationale: issue #305's comment history (issue #305 itself is closed as consolidated into #398; the DCC_VER_6000/6001 plan there is the basis for this document).

Status: design, not yet implemented. This document is written before the wire-format specs `doc/protocol-6000.txt` / `doc/protocol-6001.txt`, which land with the implementation and must then match the code (per those files' own disclaimer).

## 1. Goal

Add `-gsplit-dwarf` support for server-side preprocessing (pump mode) without changing the semantics of any existing protocol version. The remotely produced external `.dwo` file must be transferred back to the client alongside the object file and the dependency file, while clients and servers remain independently upgradable.

## 2. Why a new protocol version is needed

Split DWARF has never been wired for server-side cpp in any protocol version:

- Protocol 3 (LZO + server-side cpp) has no `DDWO` token.
- Protocol 4000 (Zstd + client-side cpp) does carry `DDWO`, but only ever paired with client-side cpp: its result header has no `DOTD` (dependency file) in the same response, and its `DDWO` read terminates result processing on a zero length (`src/clirpc.c`, the `DCC_VER_4000` branch: `if (o_len == 0) return 0;`).
- Protocol 5000 (Zstd + server-side cpp) deliberately has no `DDWO`: pump mode's result header ends `DOTO` then `DOTD`, with no slot between them (`src/distcc.h`'s `DCC_VER_5000` comment, and the `cpp_where == DCC_CPP_ON_SERVER` branch in `src/clirpc.c` which reads `DOTD` right after `DOTO` and returns).

The only place to carry a server-produced `.dwo` back in pump mode is a new `DDWO` slot between `DOTO` and `DOTD`, which is a wire-format change and therefore a new protocol version.

## 3. Protocol design

Two new fork protocol versions (rule 80: fork extensions live at 4000+):

- `DCC_VER_6000` = LZO + server-side cpp + external split DWARF
- `DCC_VER_6001` = Zstd + server-side cpp + external split DWARF
- `__DCC_VER_MAX` becomes `6002`

Two versions are required because the server derives the compression mode (LZO vs Zstd) from the protocol version, and LZO and Zstd use different bulk-data framing. No third number is reserved without a concrete need.

Existing semantics are untouched: protocol 3 (LZO pump, no split DWARF), 5000 (Zstd pump, no split DWARF), and 4000 (client-side Zstd split DWARF) keep their exact current behavior. No existing protocol is reinterpreted.

### Successful response framing

Protocol 6000 (single-int LZO lengths, as protocol 3):

```text
DONE 6000
STAT
SERR <lzo-len>
SOUT <lzo-len>
DOTO <lzo-len>
DDWO <lzo-len>
DOTD <lzo-len>
```

Protocol 6001 (2-int compressed/uncompressed lengths, as protocol 5000):

```text
DONE 6001
STAT
SERR <compressed-len> <uncompressed-len>
SOUT <compressed-len> <uncompressed-len>
DOTO <compressed-len> <uncompressed-len>
DDWO <compressed-len> <uncompressed-len>
DOTD <compressed-len> <uncompressed-len>
```

The new slot is exactly `DDWO` between `DOTO` and `DOTD`; nothing else changes. The request side is unchanged from protocol 3 / 5000 — in particular the include-server header closure (`NFIL`/`NAME`/`FILE`) stays LZO-compressed regardless of version, because it is produced by `include_server/compress_files.py` independently of the negotiated wire version.

### Empty-`DDWO` handling

If external split DWARF was requested but the compiler legitimately produced no `.dwo` (e.g. no applicable debug info emitted), an empty `DDWO` is valid. Unlike the `DCC_VER_4000` branch, the client must **not** return early on a zero-length `DDWO`: `DOTD` still follows and must be read. The zero case simply skips creating the `.dwo` file and continues to dependency retrieval.

## 4. Split-DWARF detection (per job, empirically grounded)

Protocol upgrade happens per compile job, only when the effective compiler arguments request an *external* `.dwo`. The argument-state logic must be encoded from observed real GCC/Clang behavior, not assumed. Cases to characterize before finalizing:

- GCC `-gsplit-dwarf`: external `.dwo`.
- Clang `-gsplit-dwarf=split`: external `.dwo`.
- Clang `-gsplit-dwarf=single`: no external `.dwo` — stay on the normal pump protocol.
- `-gno-split-dwarf`: disables external split DWARF.
- Mixed positive/negative forms: verify real GCC and Clang option precedence rather than assuming.

Only the "does this job need the external `.dwo` transport" decision must be derived — not a full emulation of the compiler's debug-option state machine.

## 5. Client-side protocol selection

Host parsing is unchanged: `,lzo,cpp` still resolves to base protocol 3, `,zstd,cpp` to 5000. A pump host must never become permanently 6000/6001.

Only after the final per-job preprocessing-location decision (including any pump demotion / fallback to client-side cpp) is made, and only if the job is still using server-side cpp and needs an external `.dwo`, the protocol is upgraded for that job:

- base 3 → 6000
- base 5000 → 6001

No `600x` protocol survives a fallback to client-side cpp.

## 6. Server protocol handling

Extend the known protocol set so 6000 maps to LZO + server-side cpp and 6001 maps to Zstd + server-side cpp. 6001 remains guarded by `HAVE_ZSTD`: a build without Zstd must still handle 6000 and must reject 6001 cleanly as unsupported, never introducing a new hard Zstd dependency on the LZO path.

On a successful server-side compile with 6000/6001 the server sends `DOTO`, then `DDWO`, then `DOTD`. The existing `dcc_make_dwo_fname()` helper (already used at `src/serve.c` and `src/clirpc.c`) is reused for `.dwo` filename construction — not duplicated (rule 69).

## 7. Client result retrieval

The existing `DCC_VER_4000` `DDWO` receive logic (`src/clirpc.c`) is reused or factored so wire handling is not duplicated, while 4000's own semantics stay unchanged. For 6000/6001, `DDWO` is received immediately after `DOTO` and before `DOTD`, with the empty-`DDWO` continuation from section 3.

## 8. `.dwo` naming and debug-reference correctness

Successful transport of a `.dwo` is not sufficient: GCC/Clang embed split-DWARF name/path info in the debug data, and the server compiles to a temporary output path. Before finalizing, characterize the real server-produced output for distccd's temporary object name and verify:

- the client receives the expected `.o` and `.dwo` names,
- the skeleton/debug info references the `.dwo` that actually exists on the client,
- no server temporary pathname blocks debugger lookup,
- a real debugger / DWARF tool can consume the result.

Do **not** preemptively extend `dcc_fix_debug_info()` to `.dwo` sections. First prove from observed compiler output whether such rewriting is actually required. (Note: `dcc_fix_debug_info()`'s libelf-based section rewrite — the shared capability of rule 86 — is available if that proof shows rewriting is needed.)

## 9. Compatibility behavior

No silent downgrade from 6000/6001 to 3/5000 — that would let a compile succeed while silently dropping the required `.dwo`. Expected:

- new split-DWARF pump client vs old server: the old server rejects the unknown `600x` protocol cleanly.
- ordinary LZO pump job vs old server: still protocol 3.
- ordinary Zstd pump job vs old compatible distcc-ng server: still protocol 5000.
- old/stock client vs new server: existing behavior unchanged; stock clients cannot obtain the feature because they never request `600x`.
- with `DISTCC_FALLBACK=0`, an unsupported split-DWARF pump request fails visibly rather than being hidden by a local compile.

## 10. Expected code areas

At least: `src/distcc.h`, `src/hosts.c`, `src/compile.c`, `src/srvrpc.c`, `src/serve.c`, `src/clirpc.c`, `test/testdistcc.py`, `doc/protocol-6000.txt`, `doc/protocol-6001.txt`, `doc/protocol-5000.txt` (cross-reference), `man/distcc.1`, `CHANGELOG.md`. The final set may change based on what implementation proves necessary; existing helpers are reused before new ones are created (rules 69/86).

## 11. Verification plan

Beyond a build + `make check`, this changes the wire protocol and distributed behavior, so `doc/verification-checklist.md`'s matching sections apply. Minimum:

- LZO split-DWARF pump (`-g -gsplit-dwarf -MD`): protocol 6000 selected, remote compile, non-empty `.o`/`.dwo`/`.d`, skeleton references a usable client-side `.dwo`, debugger/DWARF tool consumes the result.
- Zstd split-DWARF pump: same, protocol 6001.
- Regression controls: normal LZO pump still 3, normal Zstd pump still 5000, 4000 split DWARF intact, non-split unchanged.
- Clang modes: `-gsplit-dwarf`, `=split`, `=single`, `-gno-split-dwarf`, mixed ordering — encode/test from observed behavior.
- Build without Zstd: 6000 works, 6001 rejected cleanly, no accidental Zstd dependency on the LZO path.
- Real two-container E2E (existing infrastructure, `DISTCC_FALLBACK=0`, independently observable server log proving remote execution).
- Cross-version compatibility both directions per `doc/verification-checklist.md`; for `600x` itself, an old server cleanly rejecting the unknown protocol is the expected result.

All verification evidence must come from `ghcr.io/wiki-mod/distcc-ng-buildtools` or real CI (rule 87), and real CI must be green on the branch before the change is considered ready (rule 78b).

## 12. Upstream tracking

The same functional gap is live in upstream `distcc/distcc` (only protocols 1-3; server-side-cpp response is `DOTO` then `DOTD` with no `DDWO` slot). A `support-upstream/` entry plus its README index row is required when the implementation lands (rule 57). No write to upstream (rule 50).
