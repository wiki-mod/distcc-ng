# Dedicated verification/debug container — not a live upstream bug, a fork-only tooling addition

**Note on scope:** this entry does not document a live bug in upstream's
source, following the exception carve-out this README describes (see
`issue-063-popt-current-vendor-alternative.md`/`issue-074-lto-distribution-
revert.md` for the same pattern). `docker/verify/Dockerfile` is a new,
fork-only development/verification tool; the required support-upstream check
(AGENTS.md rule 57) is documented here as a negative finding, not skipped.

**Fork issue:** [wiki-mod/distcc-ng#264](https://github.com/wiki-mod/distcc-ng/issues/264)
**Fixed by:** wiki-mod/distcc-ng PR introducing `docker/verify/`
**Upstream location:** `docker/` (root of `distcc/distcc`)
**Checked against upstream commit:** upstream `master` tip at the time of
this check (2026-07-21) — `docker/README.md`, `docker/base/Dockerfile`,
`docker/build.sh`, `docker/compilers/Dockerfile.clang-3.8`,
`docker/compilers/Dockerfile.gcc-4.8`, `docker/compilers/Dockerfile.gcc-5`.
**Searched upstream issues/PRs for:** `verification container`, `verify
docker`, `dev container`, `debug container` — no matching open or closed
issue/PR found; upstream's own `docker/` tree is a narrow compiler-version
compatibility-testing harness (build distcc against old gcc-4.8/gcc-5/
clang-3.8 toolchains inside a container), not a general build+debug+
verification environment. It has no `gdb`/`strace`/`ltrace`/sanitizer/
binutils/search-tooling, no attempt at a Samba-or-Apache-sized dependency
surface, and is not published as a reusable image.

## Why this isn't a live upstream bug

Upstream's `docker/` directory solves a genuinely different problem
(reproducing old-compiler build behavior for compatibility testing), not the
one issue #264 targets (a single pre-built, fully self-contained image an
agent or developer can pull and immediately build/test/debug distcc-ng in,
without re-installing dependencies ad hoc or falling back to a banned WSL2
verification path). There is nothing to port back or flag as broken — this
is a new fork-only capability, not a fix to something upstream already has
and got wrong.

## Empirical verification

Not applicable — this entry documents an absence (upstream has no
equivalent container), not a code change whose correctness needs before/
after evidence. See the introducing PR's own description for how
`docker/verify/Dockerfile` itself was verified.
