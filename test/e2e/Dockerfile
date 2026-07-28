# syntax=docker/dockerfile:1.7
#
# Image for the distributed-compile end-to-end test. A single image is built
# once and run twice by docker-compose: once as the distccd compile server,
# once as the distcc client that self-compiles distcc-ng's own source tree
# across the network. Both roles share the image so the client and server run
# byte-identical compiler toolchains -- a prerequisite for comparing a
# distributed compile against a local-only one.

#
# Deliberately NOT pinned to a fixed digest, unlike docker/release/Dockerfile
# and docker/verify/Dockerfile (whose DEBIAN_IMAGE pins exist specifically so
# OSSF Scorecard's PinnedDependenciesID doesn't flag an unpinned tag as a
# supply-chain risk). This image's whole purpose (maintainer decision,
# 2026-07-28) is the opposite: it's rebuilt from scratch once a day
# (.github/workflows/e2e-image-build.yml's schedule trigger) specifically so
# it always carries the latest trixie-slim security/backport updates, acting
# as an early-warning canary for an upstream Debian package update breaking
# this project's build -- pinning to a fixed digest would defeat that
# purpose outright. "trixie-slim" (a suite name, not the literal "latest"
# tag) still bounds it to the current Debian stable generation, matching
# docker/release/Dockerfile and docker/verify/Dockerfile's own lineage
# (this image previously tracked the older bookworm-slim lineage on its
# own, a divergence with no remaining reason once this image gets its own
# maintained, validated publish pipeline like those two).
ARG DEBIAN_IMAGE=debian:trixie-slim

FROM ${DEBIAN_IMAGE}

# noninteractive keeps apt from blocking on tzdata-style prompts in CI.
ENV DEBIAN_FRONTEND=noninteractive

# build-essential brings gcc/g++/cc/c++, which the server actually execs once
# a job passes the compiler whitelist; the autotools + python packages are
# needed both to build distcc-ng here and for the client's self-compile
# (pump mode's include server is a Python C extension). procps provides ps,
# which the pump wrapper calls during shutdown -- without it pump prints a
# "ps: not found" warning. cmake/git/ca-certificates and the zstd/hiredis dev
# libraries let the weekly heartbeat client clone and build ccache's own CMake
# project distributed through the same daemon.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      autoconf \
      automake \
      build-essential \
      ca-certificates \
      cmake \
      git \
      libhiredis-dev \
      libpopt-dev \
      libzstd-dev \
      pkg-config \
      procps \
      python3 \
      python3-dev \
      python3-setuptools && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /work
COPY . /work

# Build and install distcc-ng into /usr/local so the server runs the installed
# distccd and the client runs the installed distcc, both independent of the
# /work tree the client later rebuilds. Build WITH zstd support (present in
# installed libzstd-dev above) to enable real testing of zstd compression in
# both plain and pump modes. LZO is always available regardless.
# "make clean" leaves a configured-but-unbuilt tree so the client's self-compile
# recompiles every object through distcc rather than reusing these artifacts.
RUN ./autogen.sh && \
    ./configure PYTHON=python3 --prefix=/usr/local && \
    make -j"$(nproc)" && \
    make install && \
    make clean

# Masquerade whitelist. Without --enable-tcp-insecure, distccd requires the
# requested compiler name to resolve inside LIBDIR/distcc (here
# /usr/local/lib/distcc) -- see src/serve.c dcc_check_compiler_whitelist and
# src/daemon.c dcc_warn_masquerade_whitelist. The client sends the arch-triplet
# name it resolved (e.g. x86_64-linux-gnu-gcc), not a bare "gcc", so the
# whitelist must contain that exact variant. The project's own
# update-distcc-symlinks discovers every gcc/g++ variant under /usr/lib/gcc and
# symlinks it into the masquerade dir, which gets this right independent of the
# host architecture. The dir is a name whitelist only -- it is deliberately NOT
# on distccd's PATH, so the daemon execs the real /usr/bin compiler rather than
# recursing back into distcc.
RUN /usr/local/sbin/update-distcc-symlinks

# distccd refuses to run as root unless handed --user; running the whole
# container as an unprivileged user avoids that and matches how the daemon is
# meant to be deployed. The build tree must be writable by this user because
# the client rebuilds it in place.
RUN useradd --create-home --uid 1000 builder && \
    chown -R builder /work
USER builder

# Real build-time self-test (maintainer decision, 2026-07-28): this image is
# meant to be pre-built, validated, and pulled by the actual test workflows
# rather than reassembled from scratch on every CI run (see
# .github/workflows/e2e-image-build.yml), so it needs the same "fails the
# image build itself, not a later consumer" bar as docker/verify/Dockerfile's
# own self-test -- not just an existence/--version check, a real distccd
# round trip on this single image (both roles it's actually used for in
# docker-compose). Runs as the same unprivileged `builder` user the real
# test workflows use, on the loopback interface only (--allow 127.0.0.1),
# entirely self-contained within this one build step.
#
# Both checks below poll with a bounded wait rather than assuming a fixed
# delay is enough: distccd forking, initializing, and binding its port is
# itself an async operation the client's first attempt could race (a fixed
# `sleep 1` before the first compile attempt is exactly the same class of
# flake as the immediate-grep issue below, just one step earlier -- Codex
# review finding on this Dockerfile), and separately distcc can return as
# soon as it receives the compiled output (DOTO), while distccd's own
# job-summary write (the COMPILE_OK line) happens afterward in its cleanup
# path, so an immediate log check could flake too.
RUN set -eux; \
    mkdir -p /tmp/e2e-selftest && cd /tmp/e2e-selftest; \
    echo 'int main(void) { return 0; }' > ok.c; \
    /usr/local/bin/distccd --daemon --allow 127.0.0.1 --port 3633 --log-file distccd.log; \
    compiled=0; \
    for _ in 1 2 3 4 5 6 7 8 9 10; do \
      DISTCC_HOSTS="127.0.0.1:3633" DISTCC_FALLBACK=0 /usr/local/bin/distcc gcc -o ok.o -c ok.c 2>/tmp/e2e-selftest-distcc.log \
        && { compiled=1; break; }; \
      sleep 0.5; \
    done; \
    [ "${compiled}" = "1" ] \
      || { echo "ERROR: self-test distributed compile never succeeded after waiting for distccd"; cat /tmp/e2e-selftest-distcc.log distccd.log; exit 1; }; \
    test -f ok.o \
      || { echo "ERROR: self-test distributed compile did not produce ok.o"; cat distccd.log; exit 1; }; \
    found=0; \
    for _ in 1 2 3 4 5 6 7 8 9 10; do \
      grep -q "COMPILE_OK" distccd.log && { found=1; break; }; \
      sleep 0.5; \
    done; \
    [ "${found}" = "1" ] \
      || { echo "ERROR: distccd's own log does not show a COMPILE_OK entry after waiting"; cat distccd.log; exit 1; }; \
    pkill -u "$(id -u)" distccd || true; \
    cd / && rm -rf /tmp/e2e-selftest

EXPOSE 3632/tcp
