# distcc-ng release images

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

## Pulling

```bash
docker pull ghcr.io/wiki-mod/distcc-ng:latest
docker pull ghcr.io/wiki-mod/distcc-ng-pump:latest
```

## Running as a server

```bash
docker run -d --name distccd -p 3632:3632 ghcr.io/wiki-mod/distcc-ng:latest
```

The default `CMD` starts `distccd --daemon --no-detach --log-stderr --allow
127.0.0.1 --enable-tcp-insecure` -- override `--allow` for a real network
deployment (see the main `README.md`/`man distccd` for `--allow` syntax).

## Not what you're looking for?

- Doing verification/debug work on this repo's own source? See
  `docker/verify/README.md` (`ghcr.io/wiki-mod/distcc-ng-buildtools`) instead.
- Testing distcc against an old compiler toolchain? See `docker/README.md`
  (`docker/base/`/`docker/compilers/`).
