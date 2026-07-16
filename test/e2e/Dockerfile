# syntax=docker/dockerfile:1.7
#
# Image for the distributed-compile end-to-end test. A single image is built
# once and run twice by docker-compose: once as the distccd compile server,
# once as the distcc client that self-compiles distcc-ng's own source tree
# across the network. Both roles share the image so the client and server run
# byte-identical compiler toolchains -- a prerequisite for comparing a
# distributed compile against a local-only one.

ARG DEBIAN_IMAGE=debian:bookworm-slim

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
# /work tree the client later rebuilds. --without-zstd keeps the dependency
# surface identical to the release image; LZO is always available regardless.
# "make clean" leaves a configured-but-unbuilt tree so the client's self-compile
# recompiles every object through distcc rather than reusing these artifacts.
RUN ./autogen.sh && \
    ./configure PYTHON=python3 --prefix=/usr/local --without-zstd && \
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

EXPOSE 3632/tcp
