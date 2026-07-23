# Old Hardware / Old Toolchain Compatibility Policy

distcc has historically supported a wide range of platforms and ages of
hardware and toolchains (see e.g. the project's own history of FreeBSD
and old macOS compatibility fixes). This fork continues that commitment
for platforms still in real use today: **a change must not silently
narrow platform/toolchain support**.

**Explicitly out of scope:** Solaris, IRIX, HP-UX, and AIX. These see no
realistic usage today, and treating them as compatibility targets would
block or complicate legitimate modernization work (e.g. a build-system
migration, tracked separately in issue #64) for no practical benefit.
This is a deliberate, one-time maintainer decision (issue #65, 2026-07-16)
carving out these specific platforms — not a precedent for silently
narrowing support for anything else still in real use.

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
- **popt fallback** (issue #63 fix): `libpopt` was, before this fix, a hard
  `PKG_CHECK_MODULES` requirement with no fallback -- an existing hard
  dependency, not a new one, but one this policy's "prefer graceful
  degradation" rule applies to just as much as a newly-proposed one.
  `configure.ac` now tries system libpopt >= 1.7 first and falls back to
  building the bundled copy in `popt/` (recovered from the last upstream
  distcc release that still carried one, before it was dropped in favor of
  system libpopt exclusively) when the system package isn't found, gated by
  `--with-system-popt`/`--without-system-popt` for forcing one path or the
  other. This reduces, rather than removes, a pre-existing hard requirement,
  and does not raise any minimum version.

## Dependency management policy

This section documents how this fork selects, obtains, and tracks its
dependencies (raised by issue #267's OSSF Scorecard/Baseline review,
criterion `OSPS-DO-06.01`).

- **GitHub Actions** (the workflows under `.github/workflows/`) are the one
  category of dependency with automated update tooling: `.github/dependabot.yml`
  opens a weekly update PR per action, for both `master` and `current_dev`.
  Each such PR still goes through the same review, CI, and (for `master`)
  explicit maintainer-approval gates as any other pull request — Dependabot
  only proposes the update, it never merges one itself. `.github/workflows/osv-scanner.yml`
  adds a real-time gate on top of that periodic cadence: every pull request
  and push is checked against OSV.dev's advisory database for known-
  vulnerable action versions (see `SECURITY.md`'s SCA policy section).
- **C library dependencies** (`libzstd`, `libseccomp`, `popt`, `avahi-client`)
  are detected at `./configure` time via `configure.ac`'s `PKG_CHECK_MODULES`
  calls against whatever the build host already provides, per the
  compatibility policy above (optional where possible, a documented
  minimum version otherwise). There is no package-manager-native manifest
  format for autoconf/C dependencies of this kind, so there is nothing for
  an automated dependency-update tool to act on here; version floors are
  reviewed manually as part of normal `configure.ac` changes.
- **`include_server/setup.py`** (the Python include-server build) declares
  no external Python dependencies (no `install_requires`) — nothing to
  track for that ecosystem either.
- **Vendored code** (e.g. `lzo/`'s bundled minilzo, `popt/`'s bundled popt
  fallback) is reviewed manually rather than through an automated tool:
  this project is actively maintained, and a proposal to replace vendored
  code is evaluated case by case against real alternatives when one is
  raised. For example, `lzo/`'s vendored minilzo has no alternative worth
  adopting, since upstream `distcc/distcc` itself vendors the identical
  minilzo implementation — replacing it here would create a divergence
  from upstream's own approach without a corresponding benefit.
