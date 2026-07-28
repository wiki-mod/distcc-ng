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

## The image is built and published, but not yet consumed

Maintainer decision, 2026-07-28: `Dockerfile` used to be rebuilt from
scratch by every single test run (`docker compose build`), never
independently validated. It is now built, validated (via its own embedded
self-test -- a real distcc-through-distccd compile, checked against the
daemon's own `COMPILE_OK` log line, not just an existence check), and
published to GHCR by `.github/workflows/e2e-image-build.yml`.

**`c-build.yml`, `master-heartbeat.yml`, `nightly-publish.yml`, and
`package-release.yml` do not pull this image yet** -- they still build
`Dockerfile` themselves via `docker compose build`/`run-e2e.sh`. Switching
them over is a deliberately separate follow-up, not part of the PR that
added this publish pipeline, because of a real design constraint found in
review (see below) that the follow-up needs to account for.

### Constraint the follow-up must solve: `COPY . /work` bakes a source snapshot

`Dockerfile` currently does `COPY . /work` and builds+installs distcc-ng
*at image-build time*. That's fine for `client-heartbeat.sh` (clones
ccache fresh at container-*run*-time, unrelated to what's baked into
`/work`), but it is **not** fine for `client-build.sh`'s self-compile
workload (`c-build.yml`/`nightly-publish.yml`/`package-release.yml`'s own
`distributed_e2e` gates): if those switch to pulling this daily-rebuilt
image as-is, the self-compile test would silently compile whatever source
was baked in at the last daily rebuild -- not the actual commit/PR/tag
under test -- letting the distribution gate pass without ever exercising
the reviewed revision. The follow-up needs either a toolchain-only image
(no `COPY .`/no baked-in distcc-ng, source bind-mounted or copied in at
container-*run*-time instead) or a per-revision build step layered on top
of the pulled base, not a naive `docker pull && docker compose up` using
today's `Dockerfile` unchanged.

That workflow also rebuilds this image **once a day** (`0 2 * * *` UTC),
deliberately not pinned to a fixed base-image digest the way
`docker/release/Dockerfile`/`docker/verify/Dockerfile` are -- the daily
rebuild picks up Debian trixie-slim's latest security/backport updates on
purpose, so a break caused by an upstream package update surfaces quickly
(the same "nightly-broken"-style standing-issue reporting the other
scheduled workflows use) rather than sitting undetected for weeks. Note:
GitHub only honors a workflow's `schedule` trigger from the copy on the
default branch (`master`) -- this daily rebuild has no effect until the
next `current_dev`->`master` promotion, same structural limitation as
`nightly-publish.yml`/`master-heartbeat.yml` (see issue #81's history).

## Pulling the published image

```bash
docker pull ghcr.io/wiki-mod/distcc-ng-e2e:latest
```

Also tagged as `ghcr.io/wiki-mod/distcc-ng-e2e:<short-sha>-<build-date>`
for pinning to a specific build -- the date is part of the tag (not just
the commit SHA) because the daily schedule can rebuild on a day
`current_dev`'s HEAD hasn't moved, and since the base image is
deliberately unpinned, that rebuild can still produce different image
content; a bare commit-SHA tag would then silently point at different
content across runs.
