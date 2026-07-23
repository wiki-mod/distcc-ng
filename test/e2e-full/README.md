# Full bidirectional native-compatibility E2E test (issue #264)

This is the "full automated distributed-build E2E test" designed across
issue #264's later comments (2026-07-21) -- distinct from `test/e2e/`'s
existing quick two-container hello-world-style check, which stays as-is.

## What it proves

- **Bidirectional native compatibility** (doc/verification-checklist.md
  section 4): this fork's `-NG` client against a real, independently-built
  native `distccd` (Debian's own packaged `distccd`), AND a real,
  independently-built native `distcc` client against this fork's `-NG`
  `distccd`. Both directions, both in plain mode and pump mode (Debian ships
  `distcc-pump` as a genuinely separate package from `distcc`).
- **A real, substantial workload**: Samba by default (`WORKLOAD=samba`),
  Apache httpd present but flagged off (`WORKLOAD=apache`) -- see
  `docker/verify/Dockerfile`'s own sizing research for why Samba (51 real
  Debian build-deps) is the larger reference vs. Apache httpd (20).
- **Server-side, independently-observed success**: the distccd server's own
  log must show at least as many real `COMPILE_OK` entries (attributed to
  the client's own compose-network IP) as the build actually produced real
  `.o` files -- not just the client's exit code, which `DISTCC_FALLBACK=0`
  already guards separately.

## Files

- `Dockerfile` -- one file, three stages: `workload_base` (shared OS +
  build toolchain for both Samba and Apache httpd, reused from
  `docker/verify/Dockerfile`'s own sizing research), `ng` (throwaway,
  builds `current_dev`'s own distcc/distccd/pump fresh from the checkout
  under test), `native` (stable, Debian's packaged `distcc`+`distcc-pump`
  via `apt`, pinned to the same Debian release as
  `docker/release/Dockerfile`'s base image).
- `docker-compose.yml` -- brings both containers up idle (`sleep infinity`);
  the orchestrator flips which one runs `distccd` per leg.
- `lib.sh` -- shared tarball-fetch+GPG-verify and server-log-counting
  helpers.
- `workload-samba.sh` / `workload-apache.sh` -- one real workload script
  each, same shape, only one enabled by default (see WORKLOAD above).
- `run-bidirectional-e2e.sh` -- orchestrator: builds both images, runs all
  four legs (direction A/B x plain/pump), tears the stack down always.

## Running it

```bash
cd test/e2e-full
WORKLOAD=samba bash run-bidirectional-e2e.sh
```

Needs Docker + the Compose plugin. No other host-side dependency -- both
images carry everything they need (this is why the CI job (see
`.github/workflows/nightly-publish.yml`) needs no extra `apt`/package steps
beyond `docker compose build`).

### Scoping a bounded run (`WAF_TARGETS`)

A full, unrestricted Samba build compiles thousands of files per leg (four
legs in total) -- real, honest evidence, but genuinely heavy. `WAF_TARGETS`
passes a `--targets=...` value through to `workload-samba.sh`'s real `waf
build` invocation, restricting the build to a smaller (but still completely
real, unmodified Samba source) subset -- useful for a CI-time-bounded or
quick manual smoke run without inventing a fake substitute workload. Leave
it unset for the full production run.

## Execution model

Per the maintainer's design: this is `workflow_dispatch`-only (manual),
targeting `current_dev`, never a per-PR gate -- a real full-scale Samba
build is expected to take meaningfully longer than this repo's other CI
jobs. The intended way to run the *full, unrestricted* Samba build is
**agent-driven on the project's own hosts** (the real SSH-reachable Docker
hosts this project already uses for verification work), not raw
GitHub-hosted Actions compute for the heavy lift -- the GitHub Actions job
wired into `nightly-publish.yml` exists so the *mechanism* (both images
build, both directions/modes actually distribute, the server-log check is
real) can be proven on every manual dispatch, scoped via `WAF_TARGETS` to
fit a GitHub-hosted runner's practical time budget; a human or agent with
access to a beefier host runs the same `run-bidirectional-e2e.sh` there,
unscoped, for the real full-scale evidence.

A weekly schedule (Fridays 02:00 CET, `WORKLOAD=apache` as the lighter
workload) is written into `.github/workflows/nightly-publish.yml` already,
but is **commented out and explicitly not armed** -- see that file's own
comment for why turning it on is a separate, not-yet-made decision.

## Reused container lessons (issue #264, doc/verification-checklist.md section 9)

- `--cap-add=SYS_PTRACE` + `--security-opt seccomp=unconfined` on both
  services in `docker-compose.yml`, carried over directly from
  `docker/verify/Dockerfile`'s own hard-won fix, so `gdb`/`strace` actually
  work inside either container if a failed leg needs live debugging.
- Both container stages run as a non-root user (`e2e`) by default, matching
  how `distccd`'s own privilege-drop test suite expects to be exercised
  (root-owned bind mounts breaking that behavior was the *other* real
  permission trap `docker/verify/Dockerfile` hit -- this design has no
  bind-mounted host checkout at all, `ng`'s stage `COPY`s the checkout into
  the image instead, so that specific trap does not apply here, but the
  non-root convention is kept for consistency and because a future
  bind-mount-based iteration of this test could reintroduce it otherwise).
