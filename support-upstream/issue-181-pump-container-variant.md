# distcc-ng-pump: an actively-maintained pump-mode container variant — not a live upstream bug, a fork-only tooling addition

**Note on scope:** this entry does not document a live bug in upstream's
source, following the exception carve-out this README describes (see
`issue-264-verification-container.md` for the same pattern). This is a new,
fork-only packaging/release addition; the required support-upstream check
(AGENTS.md rule 57) is documented here as a negative finding, not skipped.

**Fork issue:** [wiki-mod/distcc-ng#181](https://github.com/wiki-mod/distcc-ng/issues/181)
**Fixed by:** [wiki-mod/distcc-ng#296](https://github.com/wiki-mod/distcc-ng/pull/296)
**Upstream location:** `docker/` (root of `distcc/distcc`)
**Checked against upstream commit:** upstream `master` tip at the time of
this check (2026-07-22) -- `docker/README.md`, `docker/base/Dockerfile`,
`docker/build.sh`, `docker/compilers/Dockerfile.{clang-3.8,gcc-4.8,gcc-5}`.
**Searched upstream issues/PRs for:** `pump container`, `pump docker`,
`distcc-pump image` -- no matching open or closed issue/PR found; upstream's
own `docker/` tree is a narrow compiler-version compatibility-testing
harness (build distcc against old gcc-4.8/gcc-5/clang-3.8 toolchains inside
a container), not a general release/runtime image, pump-capable or
otherwise. Upstream has no equivalent to compare this fork's release
container pipeline against at all -- `docker/release/Dockerfile` and
`.github/workflows/package-release.yml` are both fork-only additions
predating this specific change.

## The gap this closes

The currently-active `docker/release/Dockerfile` (built/pushed by
`package-release.yml` on every tagged release) only installed `distcc`,
`distccd`, `lsdistcc`, `distccmon-text` -- no `pump` wrapper, no
`include_server` Python package. Pump mode was not available in the current
`ghcr.io/wiki-mod/distcc-ng` image at all. A real, working pump-mode build
existed once (the old, pre-`-NG` `distcc-ng-with-pump:3.4.1` GHCR package,
since renamed to a legacy suffix per #40), but nothing rebuilds it.

## Fix

`docker/release/Dockerfile` gained a second runtime stage (`runtime-pump`)
reusing the exact same compiled build-stage artifacts (pump mode is built
by default; nothing needed recompiling), installed via `make install
DESTDIR=/out-pump` rather than a manual file copy -- `pump`'s own install
step needs to record where `include_server.py` ends up (see
`Makefile.in`'s `install-include-server` target) so the installed `pump`
wrapper can actually find it; a naive copy would produce a `pump` that
can't locate its include server.

`package-release.yml`'s `build_container`/`publish_manifest` jobs gained a
`variant: [plain, pump]` matrix dimension, published as the separate
`ghcr.io/wiki-mod/distcc-ng-pump` package (matching this repo's existing
`distcc-ng-nightly`/`distcc-ng-buildtools` separate-package precedent).

## Verification

Real, on a real Docker host (228-lxc-ssh, not WSL2): both `runtime` and
`runtime-pump` targets built clean. A genuine two-container end-to-end
test -- a `distccd` server container and a `pump distcc gcc -c` client
container, both from the new pump image, connected over a real Docker
network -- was run with `DISTCC_FALLBACK=0` (so a real distribution
failure couldn't silently fall back to local compilation and produce a
false pass). The real wire-protocol trace showed genuine server-side
compilation (`exec on pump-server,cpp,lzo`, not `running locally instead`),
the real symlink-mirroring mechanism from issues #95/#292 in action
(`LINK` tokens with relative `../../..` targets for system include
directories), and a successful compile (`STAT=0`, real `.o` file returned
and linked into a binary that ran and printed its expected output). The
plain `runtime` target was also rebuilt and confirmed to still have no
`pump` binary, ruling out a regression from the shared Dockerfile edit.
