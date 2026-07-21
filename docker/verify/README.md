# distcc-ng verification/debug container

Tracks issue #264. A pre-built, fully self-contained Debian-based image with
distcc-ng's own build toolchain plus a dependency surface sized to match
**Samba** (found to have the larger/more demanding real-world build-dependency
list compared to Apache httpd — 51 vs. 20 distinct Debian `Build-Depends`
packages, see the issue #264 research comment for the full comparison), debug
tools (`gdb`, `strace`, `ltrace`), a sanitizer/memory-debug toolchain
(ASan/UBSan via gcc, `valgrind`), `binutils` (`objdump`/`readelf`/`nm`/
`addr2line`), and search/inspection tools (`ripgrep`, `grep`, `less`).

**Hard requirement (maintainer, issue #264): pre-built and fully
self-contained.** Downloading and starting this image is the entire setup
step — nothing installs or fetches anything at container start or first use.
Every tool listed above is baked into the image layers and gets a real
build-time self-test (see the Dockerfile's self-test `RUN` step); the image
build itself fails if any tool is missing or non-functional.

## Building

```bash
docker build -f docker/verify/Dockerfile -t distcc-ng-verify:local .
```

## Using it to verify a distcc-ng change

```bash
docker run --rm -it --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
  -v "$(pwd):/work/src:rw" distcc-ng-verify:local bash -c \
  'cd /work/src && ./autogen.sh && ./configure PYTHON=python3 && make && make check'
```

Both `--cap-add=SYS_PTRACE` and `--security-opt seccomp=unconfined` are
required, not optional, for a full `make check` to pass: `test/testdistcc.py`'s
`Gdb_Case` runs a real `gdb`, which disables ASLR for the debuggee via
`personality(2)` by default. This was found live, empirically, in this
image's own CI verification (see the introducing PR's history) as two
separate real failures:

- `--cap-add=SYS_PTRACE` alone was tried first and did **not** fix it — the
  identical "warning: Error disabling address space randomization:
  Operation not permitted" reappeared verbatim in the next run. Capabilities
  and seccomp are two independent Docker security layers; a capability
  being present doesn't matter if the (default) seccomp profile denies the
  syscall/argument combination outright.
- Docker's default seccomp profile denies `personality()`'s
  `ADDR_NO_RANDOMIZE` flag regardless of capabilities, so
  `--security-opt seccomp=unconfined` is what actually fixed it. This is
  scoped to running this verification/debug image specifically — never
  appropriate for the shipped runtime image (`docker/release/Dockerfile`)
  or a multi-tenant host — but is a reasonable trade-off for a container
  whose whole purpose is real debugging with `gdb`/`strace`/`ltrace`.

## Ptrace-dependent tool self-test (gdb/strace/ltrace)

`docker build`'s `RUN` steps have no `CAP_SYS_PTRACE` and the default seccomp
profile denies `ptrace(2)` regardless of image content — so gdb/strace/ltrace
can only get an existence/`--version` check at build time (see the
Dockerfile), not a real functional one. `docker/verify/selftest-ptrace.sh` is
the real functional proof, run once against the *running* container (which
can be granted the capability a `docker build` step cannot):

```bash
docker run --rm --cap-add=SYS_PTRACE \
  -v "$(pwd)/docker/verify:/verify:ro" \
  distcc-ng-verify:local bash /verify/selftest-ptrace.sh
```

## Sizing reference: why Samba, not Apache httpd

See the issue #264 research comment for the full package-by-package
comparison. Summary: Samba's real Debian `Build-Depends`
(`2:4.22.10+dfsg-0+deb13u1`, trixie) lists 51 distinct packages spanning
Kerberos, LDAP, GnuTLS, PAM, systemd, ICU, LMDB, Ceph/RADOS clustering,
io_uring, and Python bindings; Apache httpd's (`2.4.68-1~deb13u1`) lists 20,
essentially just the HTTP-stack libraries (APR/APR-util, PCRE2, OpenSSL,
libxml2, Lua, brotli, nghttp2, zlib). Samba is therefore the sizing target
used for this image's package inventory. Debian packaging-only tooling from
Samba's own `Build-Depends` (`debhelper-compat`, `dh-exec`, `dpkg-dev`,
`jdupes`, `lsb-release`, `rpcsvc-proto`, the `gcc-mingw-w64-*` cross
compilers) is deliberately left out — this image targets a real
`./configure && make` build from a source tree, not producing a signed
`.deb`, and cross-compiling Samba's Windows-side tools is out of scope for
what this image needs to prove.

## Proving the sizing claim against the real Samba source

```bash
docker run --rm distcc-ng-verify:local bash -c '
  set -e
  cd /tmp
  wget -q https://download.samba.org/pub/samba/stable/samba-4.22.4.tar.gz
  wget -q https://download.samba.org/pub/samba/stable/samba-4.22.4.tar.asc
  wget -q https://download.samba.org/pub/samba/samba-pubkey.asc
  # Verification method exactly as documented on
  # https://www.samba.org/samba/download/ -- import samba.orgs own
  # published key, then verify the signature against the *uncompressed*
  # tarball (verification-checklist section 5: check a downloaded artifact
  # against the upstream projects own published value, not "it downloaded
  # without error").
  gpg --batch --import samba-pubkey.asc
  gunzip -k samba-4.22.4.tar.gz
  gpg --batch --verify samba-4.22.4.tar.asc samba-4.22.4.tar
  tar xf samba-4.22.4.tar
  cd samba-4.22.4
  ./configure 2>&1 | tee configure.log
  ! grep -qi "not found" configure.log
'
```

A clean `./configure` run (Samba uses its own `waf`-based configure wrapper,
bundled in its source tree — no separate `waf` package needed) with no
"not found"/missing-dependency lines is the real evidence that this image's
package inventory is actually sufficient for a Samba-sized project, not just
asserted from the Build-Depends comparison alone.

## Not yet implemented: publishing to GHCR

This image is not yet published anywhere — see the PR that introduced this
directory for a sketched (not implemented) release-pipeline design analogous
to `nightly-publish.yml`/`package-release.yml`.
