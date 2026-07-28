# test/e2e/

Two-container distributed-compile end-to-end harness: one `distccd` compile
server, one `distcc` client, talking over a dedicated bridge network. Both
containers run the same image (`Dockerfile`), built once and started twice
by `docker-compose.yml` -- see that file's own comments for why (byte-
identical toolchains on both sides).

Used by:
- `c-build.yml`'s `Distributed compile E2E (2-container)` job, on every push
  (client workload: `client-build.sh`, distcc-ng's own source tree).
- `master-heartbeat.yml`'s weekly `ccache_heartbeat` job (client workload:
  `client-heartbeat.sh`, ccache's own source).
- `nightly-publish.yml`/`package-release.yml`'s own `distributed_e2e` gates.

Not to be confused with `test/e2e-full/` (Samba/Apache bidirectional
native-compatibility test, issue #264) or `docker/verify/` (the general
build/debug/verification image) -- three separate images/harnesses serving
three different purposes, see `doc/docker.md` for the other two.

## The image is pre-built and published, not assembled live

Maintainer decision, 2026-07-28: `Dockerfile` used to be rebuilt from
scratch by every single test run (`docker compose build`). It is now
built, validated (via its own embedded self-test -- a real
distcc-through-distccd compile, checked against the daemon's own
`COMPILE_OK` log line, not just an existence check), and published to GHCR
by `.github/workflows/e2e-image-build.yml`, which the actual test workflows
then pull from instead of reassembling it each time.

That workflow also rebuilds this image **once a day** (`0 2 * * *` UTC),
deliberately not pinned to a fixed base-image digest the way
`docker/release/Dockerfile`/`docker/verify/Dockerfile` are -- the daily
rebuild picks up Debian trixie-slim's latest security/backport updates on
purpose, so a break caused by an upstream package update surfaces quickly
(the same "nightly-broken"-style standing-issue reporting the other
scheduled workflows use) rather than sitting undetected for weeks.

## Pulling the published image

```bash
docker pull ghcr.io/wiki-mod/distcc-ng-e2e:latest
```

Also tagged with the short commit SHA it was built from, for pinning to an
exact revision (`ghcr.io/wiki-mod/distcc-ng-e2e:<short-sha>`).
