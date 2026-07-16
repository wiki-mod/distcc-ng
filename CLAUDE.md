# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

distcc-ng is a maintained fork of [distcc/distcc](https://github.com/distcc/distcc) — a distributed C/C++ compiler that lets `make -jN` (or any build) farm out compile jobs to other machines on the network. This fork exists because upstream distcc does not accept AI-assisted contributions; wiki-mod/distcc-ng does, under the governance in `AGENTS.md`.

Core pieces: `distcc` (client), `distccd` (compile server daemon), `pump` (the include-server-backed "pump mode" that lets distcc safely preprocess headers server-side for a much bigger speedup), `include_server/` (the Python include-server itself), plus the usual monitoring tools (`distccmon-text`, `distccmon-gnome`, `lsdistcc`).

## Key Constraints

- Chat language: German. GitHub content (issues, PRs, commits, comments, docs, code comments): **English**, no exceptions.
- Build system is autoconf/automake (`configure.ac`/`Makefile.in`) — this is a deliberate choice, not an oversight; see the Meson feasibility investigation referenced below before assuming otherwise.

## Governance

**Mandatory at the start of every session/task in this repo**: read `AGENTS.md` (repo root) in full and follow it as binding rules for this repository — not optional background reading. It is not auto-loaded into context the way this file is; you must actively read it yourself. If it changes during a session (e.g. after a `git pull` or merge), re-read it before continuing work that it governs.

- **GitHub content language**: English.
- **No direct pushes to `master`**: all changes go through pull requests, and merging into `master` requires the maintainer's explicit approval — this fork's hardest rule, restated because it's the one most likely to be assumed away by habit from other projects.

## Architecture

```
src/                     # distcc/distccd/pump C sources
include_server/          # Python include-server (pump mode's header-dependency analysis)
include_server/c_extensions/  # C extension backing the include-server's fast paths
lzo/                     # bundled minilzo (LZO compression, always available)
test/                    # comfychair-based test harness (testdistcc.py — real e2e-ish
                         # daemon+compile tests, not just unit tests)
packaging/               # RPM/.deb packaging (rpm.spec, rpm.sh, deb.sh)
docker/release/          # Release container image
doc/                     # release-versioning.md, compatibility-policy.md, protocol docs
scripts/                 # build-release-packages.sh, check-release-version.sh
.github/workflows/       # c-build.yml (build+test), package-release.yml (tagged releases),
                         # changelog-check.yml, actionlint.yml
```

## Branching Model

- `master`: the stable, released branch. Only ever updated via an explicitly maintainer-approved promotion PR from `current_dev`, paired with a real `vX.Y.Z-NG` tag (see `doc/release-versioning.md`).
- `current_dev`: active development branch. Individual fixes/features land here via `dev/issueNN_short-name` branches, one worktree per issue (see `AGENTS.md`'s Agent Workflow section) — not directly in the shared `repo/` clone, which can be stale.
- Versioning continues distcc's own numbering (currently based on distcc 3.4) with a `<version>-NG` suffix marking this fork's releases (e.g. `3.5.1-NG`). `scripts/check-release-version.sh` enforces tag/`configure.ac` consistency.

## Key Design Decisions

- **Wire protocol compression**: LZO (`src/compress-lzox1.c`) always available; **zstd** (`src/compress-zstd.c`) optional, configure-time auto-detected via `PKG_CHECK_MODULES([ZSTD], [libzstd >= 1])`, degrading gracefully (no hard dependency) when libzstd isn't present — recovered from this fork's own prior (unmerged) `v3.4.1-zstd` work, originally distcc/distcc#232 by Shawn Landden. The include-server's separate Python C-extension build (`include_server/setup.py`) needs `LIBS` forwarded from `Makefile.in` to pick up the same `-L` flags the main binaries get automatically — a real bug found and fixed when recovering this feature (macOS/Homebrew's keg-only zstd install isn't on the default linker path, unlike Linux).
- **Compatibility policy** (`doc/compatibility-policy.md`): a change must not silently raise the minimum compiler/library version or introduce a new hard dependency — state it explicitly and prefer a compiler-feature guard or configure-time optional detection instead. Solaris/IRIX/HP-UX/AIX are explicitly out of scope (maintainer decision, 2026-07-16) as genuinely unused today; FreeBSD/macOS/Cygwin remain real targets.
- **Meson build-system migration**: investigated and not (yet) adopted — see the tracking issue for the full feasibility analysis (build-file inventory, compatibility-policy tension, quantified upstream-divergence cost). Don't assume a build-system change is safe to make casually; it needs the same explicit-decision treatment as a compatibility-affecting one.
- **Upstream relationship**: this fork tracks and periodically surveys upstream `distcc/distcc`'s full issue/PR history for adoptable fixes — never adopted unverified. A recovered patch or a candidate found this way still needs a real cross-check against this fork's *current* source before landing, since both upstream and this fork have moved independently since any given patch was written.
- **CI build acceleration**: `make`/`make check` build through `ccache` in CI, with the object cache persisted across runs via `actions/cache` (explicit `CCACHE_DIR`, since ccache's own default differs by platform).

## Testing

`make check` runs the real test suite (`test/testdistcc.py`, a comfychair-based harness) — this includes genuine daemon+compile e2e-style tests (`WithDaemon_Case`, `CompileHello_Case`: a real `distccd` is started and a real compile is distributed through it), not just unit tests of argument parsing. Treat "does `make check` pass" as a meaningful bar, but not a substitute for an actual CI run when the change touches build/test machinery itself (see `AGENTS.md`'s Required Validation section) or when a real distributed-compile validation (beyond a single "hello world") is the more honest test for the change at hand.

## Changelog Maintenance

CHANGELOG.md follows [Keep a Changelog](https://keepachangelog.com/) format and is maintained with the aid of [git-changelog](https://pawamoy.github.io/git-changelog/) — a tool that automatically generates changelog entries from git commits while preserving hand-written narrative entries in released versions.

**Usage** (before creating a release):
```bash
# Install git-changelog if not already present
pip install git-changelog

# Run the tool to refresh [Unreleased] with recent commits
git-changelog
```

This updates the `[Unreleased]` section with automatically-generated entries for all commits since the last release. Developers should review the generated entries and enhance them with narrative context (the "why" behind changes, issue/PR references, etc.) as described in the existing changelog, then commit the updated `CHANGELOG.md` as part of the release process.

The tool is configured via `.git-changelog.toml` and uses the "basic" commit convention (no Conventional Commits requirement). The `<!-- insertion marker -->` comment in CHANGELOG.md marks the insertion point for new entries; do not remove this marker.

See `doc/release-versioning.md` for the overall release workflow. The existing `changelog-check.yml` workflow still enforces that PRs touch CHANGELOG.md; git-changelog assists with this but does not replace manual review and entry curation.

## Running (development)

```bash
./autogen.sh
./configure PYTHON=python3   # add --without-zstd, --disable-pump-mode, etc. as needed
make
make check
```
