# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

distcc-ng is a maintained fork of [distcc/distcc](https://github.com/distcc/distcc) — a distributed C/C++ compiler that lets `make -jN` (or any build) farm out compile jobs to other machines on the network. This fork exists because upstream distcc does not accept AI-assisted contributions; wiki-mod/distcc-ng does, under the governance in `AGENTS.md`.

Core pieces: `distcc` (client), `distccd` (compile server daemon), `pump` (the include-server-backed "pump mode" that lets distcc safely preprocess headers server-side for a much bigger speedup), `include_server/` (the Python include-server itself), plus the usual monitoring tools (`distccmon-text`, `distccmon-gnome`, `lsdistcc`).

## Key Constraints

- Chat language: German. GitHub content (issues, PRs, commits, comments, docs, code comments): **English**, no exceptions.
- Build system is autoconf/automake (`configure.ac`/`Makefile.in`) — this is a deliberate choice, not an oversight; see the Meson feasibility investigation referenced below before assuming otherwise.

## Governance

**Mandatory at the start of every session/task in this repo**: read `AGENTS.md` (repo root) **completely, start to finish, no summarizing, no skipping sections, no reading only the parts that seem relevant** — and follow it as binding rules for this repository, not optional background reading. It is not auto-loaded into context the way this file is; you must actively read it yourself. This applies equally to every delegated subagent working in this repo, not just the top-level session. If it changes during a session (e.g. after a `git pull` or merge), re-read it in full again before continuing work that it governs. A `.github/AGENTS.md` pointer file exists for tools that only look there — it just redirects here, the root file is the real source.

The bullets below restate a few of `AGENTS.md`'s highest-stakes rules **word-for-word** (per `AGENTS.md` rule 65) so they're visible without a separate read — but they are excerpts, not a substitute for reading the full file, and are not necessarily current if `AGENTS.md` has changed since this file's own last edit; the numbered rule is always the authoritative source.

- **GitHub content language**: English.
- **Rule 21**: "Do not push directly to `master`. All changes to `master` go through a pull request, and merging into `master` requires the maintainer's **explicit** approval — a prior approval for one PR does not carry over to the next. `current_dev` may be merged into more routinely (standard PR review), but the same "verify before claiming done" discipline still applies."
- **Rule 50**: "**`distcc/distcc` (upstream) is off-limits, full stop — read-only, forever, no exceptions.** Never push a branch, open/comment/edit a PR or issue, or take any write action of any kind against `distcc/distcc`. The only legitimate interaction with it is read-only reference (fetching its history, reading its issues/PRs for the periodic upstream survey). This is a hard, absolute rule, not a "be careful" one — it exists because this fork exists *specifically* because upstream does not accept AI-assisted contributions, and a past incident (a delegated agent's `gh pr create` without `--repo`, landing a real PR on `distcc/distcc` itself) is exactly the failure this rule prevents. Always pass `--repo wiki-mod/distcc-ng` explicitly on every `gh` subcommand that resolves a repository ambiently, and follow rule 18's `gh api`-specific mechanism (literal endpoint paths, or `GH_REPO`/literal field values) for `gh api` calls, as the mechanical safeguard — but the rule itself is the point: never write to upstream, regardless of what any tool's default behavior would otherwise do."
- **Rule 51**: "**More generally, beyond `distcc/distcc` specifically: read access is unrestricted anywhere, but write access to any repo other than `wiki-mod/distcc-ng` requires the maintainer's explicit, per-action authorization first.** Opening, commenting on, editing, labeling, or closing an issue or PR; pushing a branch; merging; any mutating API call — against any repo that isn't `wiki-mod/distcc-ng` is forbidden without being asked for that specific action, no exceptions, and never assumed from a past approval on a different item or repo. This applies retroactively too: treat any past write outside `wiki-mod/distcc-ng` as subject to this same standard when reviewing history."
- **Rule 56**: "**Never bypass the local git hooks that enforce the rules above (`pre-commit`, `commit-msg`, `pre-push` in `.git/hooks/`, deliberately untracked).** No `git commit --no-verify` / `git push --no-verify` or equivalent flags, no editing/disabling/deleting/moving those hook files, no `core.hooksPath` override, no working from a clone or worktree that lacks them, and no routing around them via a GitHub API call that writes content without going through a normal local push (e.g. the Contents API). This applies to me directly and to every delegated agent. A hook blocking something is not an obstacle to route around because it's inconvenient — it is the enforcement of a rule stated elsewhere in this file (upstream is off-limits; no personal/employer info leaves this machine). If a hook blocks something that seems wrong, stop and ask the maintainer instead of finding a way past it."

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

CHANGELOG.md follows [Keep a Changelog](https://keepachangelog.com/) format and is maintained fully automatically by a three-step chain — no manual generator run needed (this replaced an earlier git-cliff-based approach, see #122):

1. **`release-drafter`** (`.github/release-drafter.yml`, `.github/workflows/release-drafter.yml`) auto-maintains a draft GitHub Release (visible in the Releases tab), refreshed on every push to `current_dev`, zero manual trigger. PRs are categorized (`Security`/`Fixed`/`Added`/`Documentation`) by a label auto-assigned from the PR title via its `autolabeler`. Entries use `#N | title`.
2. A maintainer publishes that release as part of the existing manual release-cut process (`doc/release-versioning.md`) — unchanged.
3. On that `release: released` event, `.github/workflows/changelog-update-on-release.yml` runs [`stefanzweifel/changelog-updater-action`](https://github.com/marketplace/actions/changelog-updater) to insert the release's notes as a new dated section into `CHANGELOG.md`, then [`stefanzweifel/git-auto-commit-action`](https://github.com/stefanzweifel/git-auto-commit-action) commits it to `current_dev` (tags are cut from `current_dev`'s tip, so that's always where the update belongs).

`release-drafter`'s config-loading is hardcoded to the repo's **default branch** (`master`) — this affected both the draft-release-update and the PR autolabeler (both failed with "Invalid config file" on every run since #121, confirmed live 2026-07-16, correcting an earlier too-optimistic note here that assumed only the draft-notes side was affected). Fixed by giving `master` its own copy of `.github/release-drafter.yml` as a one-off exception ahead of the real promotion (#132/#133), same precedent as the AGENTS.md/CLAUDE.md exception (#126/#127). Historical PRs merged before this fix mostly lack category labels as a result — see #132 for the backfill follow-up.

The existing `changelog-check.yml` workflow still requires PRs to touch `CHANGELOG.md` (or carry `no-changelog-needed`) — with this automated chain, that per-PR requirement may no longer be the right gate (the file now only changes automatically at release-publish time), but relaxing it is a separate, not-yet-made decision.

## Running (development)

```bash
./autogen.sh
./configure PYTHON=python3   # add --without-zstd, --disable-pump-mode, etc. as needed
make
make check
```
