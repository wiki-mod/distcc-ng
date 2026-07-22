# docker/

`docker/` has two independent purposes -- don't confuse them:

- **`docker/release/`**: this fork's own published runtime images.
- **`docker/verify/`**: a verification/debug image for contributors/agents
  working on this repo's own source -- not a runtime image.

## Release images (`docker/release/`)

Built and pushed to GHCR by `.github/workflows/package-release.yml` on
every tagged release (or a manual `workflow_dispatch` with
`publish_container: true`). Two separately-published variants, from the
same `Dockerfile` via different build targets:

- **`ghcr.io/wiki-mod/distcc-ng`** (`--target runtime`): plain
  `distcc`/`distccd`/`lsdistcc`/`distccmon-text`, no pump mode.
- **`ghcr.io/wiki-mod/distcc-ng-pump`** (`--target runtime-pump`,
  issue #181): the same binaries plus `pump` and the Python
  `include_server` package, for pump-mode (server-side preprocessing)
  distributed compiles.

Both are published as multi-arch (`amd64`, `arm64` best-effort) manifests,
scanned with Trivy, and shipped with an SPDX SBOM.

### Pulling

```bash
docker pull ghcr.io/wiki-mod/distcc-ng:latest
docker pull ghcr.io/wiki-mod/distcc-ng-pump:latest
```

### Running as a server

```bash
docker run -d --name distccd -p 3632:3632 ghcr.io/wiki-mod/distcc-ng:latest
```

The default `CMD` starts `distccd --daemon --no-detach --log-stderr --allow
127.0.0.1 --enable-tcp-insecure` -- override `--allow` for a real network
deployment (see the main `README.md`/`man distccd` for `--allow` syntax).

## Verification/debug image (`docker/verify/`)

Tracks issue #264. Published to GHCR as `distcc-ng-buildtools` (see
"Pulling the published image" below) -- a pre-built, fully self-contained
Debian-based image with distcc-ng's own build toolchain plus a dependency
surface sized to match **Samba** (found to have the larger/more demanding
real-world build-dependency list compared to Apache httpd -- 51 vs. 20
distinct Debian `Build-Depends` packages, see the issue #264 research
comment for the full comparison), debug tools (`gdb`, `strace`, `ltrace`,
`python3-dbg` for `gdb`'s `py-bt`/`py-list` against the Python-based
include_server and its C extension), a sanitizer/memory-debug toolchain
(ASan/UBSan via gcc, `valgrind`), `binutils`
(`objdump`/`readelf`/`nm`/`addr2line`), network/socket-debugging tools
(`lsof`, `ss`/`iproute2`, `dig`/`nslookup`/`dnsutils`), and search/inspection
tools (`ripgrep`, `grep`, `less`). Python's own built-in debugger (`pdb`)
needs no extra package, it already ships inside plain `python3`.

**Hard requirement (maintainer, issue #264): pre-built and fully
self-contained.** Downloading and starting this image is the entire setup
step -- nothing installs or fetches anything at container start or first
use. Every tool listed above is baked into the image layers and gets a real
build-time self-test (see the Dockerfile's self-test `RUN` step); the image
build itself fails if any tool is missing or non-functional.

### Pulling the published image

```bash
docker pull ghcr.io/wiki-mod/distcc-ng-buildtools:latest
```

Published automatically by `.github/workflows/verify-image-build.yml`'s
`publish` job on every push to `current_dev` that touches `docker/verify/**`
(after `build_and_selftest` proves the image still works), and on a manual
`workflow_dispatch` run -- never from a pull request. `:latest` is a moving
tag (same channel philosophy as `distcc-ng-nightly`); each publish is also
tagged with the short commit SHA it was built from, for pinning to an exact
revision.
