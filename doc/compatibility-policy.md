# Old Hardware / Old Toolchain Compatibility Policy

distcc has historically supported a wide range of platforms and ages of
hardware and toolchains (see e.g. the project's own history of FreeBSD,
Solaris, and old macOS compatibility fixes). This fork continues that
commitment: **a change must not silently narrow platform/toolchain support**.

## The rule

Any change that could raise the minimum required compiler version, C
library version, or introduce a new hard external dependency must:

1. **State that explicitly** in its issue/PR body (what the new minimum is,
   and why it's needed), so it can be discussed and isn't a silent
   regression discovered later by someone on older hardware.
2. **Prefer graceful degradation over a hard requirement**, using one of
   these established patterns already in this codebase:
   - **Compiler-feature guards** for language/compiler extensions, e.g.
     `src/distcc.h`'s `FALLTHROUGH` macro:
     ```c
     #if defined(__GNUC__) && __GNUC__ >= 7
     #  define FALLTHROUGH __attribute__((fallthrough))
     #else
     #  define FALLTHROUGH ((void) 0)
     #endif
     ```
     On an older compiler, this compiles to a no-op rather than failing the
     build — acceptable here specifically because `-Wimplicit-fallthrough`
     (the warning this works around) doesn't exist before GCC 7 either, so
     there is nothing to suppress on older compilers in the first place.
   - **Configure-time optional detection** for new external libraries, e.g.
     the zstd support explored in `dev/allinkl*` (inspired by upstream
     distcc PR #236), which uses `PKG_CHECK_MODULES([ZSTD], [libzstd >= 1], ...)`
     and a `--without-zstd` configure flag so the feature is opt-in and
     absent entirely on systems without a compatible libzstd, rather than
     a hard build requirement.
3. If neither is possible and a real minimum-version bump is unavoidable,
   that is a maintainer decision requiring explicit sign-off, not something
   to land silently as a side effect of an unrelated fix.

## Why this specific concern keeps coming up

Real prior art from upstream distcc: the zstd protocol-4 work (upstream PR
#236, 2017) stalled for years partly because old Ubuntu Xenial's system
zstd (0.5.1) could not even decompress streams produced by zstd 1.0 —
a real, not hypothetical, old-system incompatibility. Any future work
building on that feature in this fork must keep it optional for exactly
this reason.

## Audit of recent fixes against this policy (2026-07-15)

- **`tempfile: /dev/urandom` + `uint64_t`** (issue #12 fix): safe.
  `/dev/urandom` has existed on every Unix-like platform this project
  targets since long before this code was written. `uint64_t`/`<stdint.h>`
  is C99 and was already used elsewhere in this codebase (`src/rpc.c`,
  `src/util.h`, `src/access.c`) before this fix — not a new dependency.
- **`FALLTHROUGH` attribute** (issue #22 fix): safe, per the guard pattern
  described above — no compatibility regression, since the warning it
  suppresses doesn't exist on compilers old enough for the guard to matter.
- **zstd/protocol-4** (not yet merged, `dev/allinkl*` branches): this is
  the case this policy exists for. Any PR bringing this in must keep zstd
  fully optional (configure-detected, `--without-zstd` fallback) exactly as
  the explored branches already do, and must not make libzstd a hard
  dependency of the base build.
