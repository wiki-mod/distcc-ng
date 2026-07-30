# syntax=docker/dockerfile:1.7
#
# Image for the distributed-compile end-to-end test. A single image is built
# once and run twice by docker-compose: once as the distccd compile server,
# once as the distcc client that self-compiles distcc-ng's own source tree
# across the network. Both roles share the image so the client and server run
# byte-identical compiler toolchains -- a prerequisite for comparing a
# distributed compile against a local-only one.

#
# Was deliberately left unpinned (maintainer decision, 2026-07-28): this
# image is rebuilt from scratch once a day
# (.github/workflows/e2e-image-build.yml's schedule trigger), and tracking
# the floating "trixie-slim" tag meant every rebuild picked up that day's
# latest Debian security/backport updates -- an early-warning canary for an
# upstream Debian package update breaking this project's build.
#
# Superseded (maintainer decision, 2026-07-30, issue #267): now pinned to a
# fixed digest like docker/release/Dockerfile and docker/verify/Dockerfile,
# to close Scorecard's PinnedDependenciesID finding. This measurably weakens
# the canary's granularity -- the daily rebuild now produces a byte-identical
# image until Dependabot's weekly docker-ecosystem scan (.github/dependabot.yml,
# now covering this directory too) bumps the pinned digest, so an upstream
# break is caught within a week rather than within a day. "trixie-slim" (a
# suite name, not the literal "latest" tag) still bounds the tracked lineage
# to the current Debian stable generation, matching docker/release/Dockerfile
# and docker/verify/Dockerfile's own lineage.
ARG DEBIAN_IMAGE=debian@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd

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
#
# libseccomp-dev is not optional decoration here: without it configure builds
# distccd with no seccomp sandbox, so every remote compile in this image runs
# unsandboxed and the daemon logs a warning on each startup saying exactly
# that. It also meant this image -- the one gating distributed-compile
# behavior on every push -- never exercised the sandboxed code path a real
# deployment with libseccomp installed actually takes. docker/verify/ and
# test/e2e-full/ already install it; this image was the sole holdout.
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
      libseccomp-dev \
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
# The compile itself runs exactly once and is never retried. There is no
# daemon-readiness race to absorb: dcc_standalone_server() calls
# dcc_socket_listen() before dcc_detach(), and that code's own comment says
# so explicitly -- "Don't go into the background until we're listening and
# ready. This is useful for testing -- when the daemon detaches, we know we
# can go ahead and try to connect" (src/dparent.c). Since distccd is started
# here without --no-detach, the shell command above only returns once the
# daemon has detached, which by that design means the socket is already
# listening. Retrying would also be actively harmful rather than merely
# redundant: the distributed compile is the very thing this self-test exists
# to validate, so a loop around it would swallow an intermittent
# client/server regression, overwrite the failing attempt's captured output
# with a later attempt's, and let the image publish on a retry.
#
# The COMPILE_OK check below does poll, and that is a genuinely different
# situation -- not an inconsistency: distcc returns as soon as it has
# received the compiled object, while distccd writes its job summary
# afterwards in its own cleanup path, so that line is legitimately async
# with respect to a compile that has already fully succeeded. Polling there
# waits for a *report* of the result, not for the operation under test to
# eventually work.
#
# The successful attempt's own stderr is checked for emptiness, not just
# discarded once a compile succeeds: distcc/the compiler exiting 0 does not
# mean it produced no warning, and silently dropping that output the moment
# the exit code looks fine would let a real warning through unnoticed --
# this repository treats a hidden warning signal as a failed check, not a
# passing one, the same bar as a real compile error.
#
# The client's stderr is only half of that signal, though, so the daemon's
# own log is scanned for warning-or-worse severities too. The two are
# genuinely independent: distccd can complete a compile successfully -- so
# the client sees a clean exit and COMPILE_OK appears -- while still having
# logged an operational problem on its own side (a restricted
# /proc/self/autogroup making the niceness adjustment fail, a masquerade
# whitelist complaint), none of which ever reaches the client. Publishing an
# image whose daemon warns on every startup would be exactly the hidden-signal
# case the stderr check above exists to prevent, just on the other end of the
# connection. The pattern matches distcc's own severity prefixes rather than
# an ad-hoc word list -- see rs_severities[] in src/trace.c, where levels at
# notice and below deliberately render with no prefix at all, so this catches
# precisely the levels that indicate something actually went wrong.
RUN set -eux; \
    mkdir -p /tmp/e2e-selftest && cd /tmp/e2e-selftest; \
    echo 'int main(void) { return 0; }' > ok.c; \
    /usr/local/bin/distccd --daemon --allow 127.0.0.1 --port 3633 --log-file distccd.log; \
    DISTCC_HOSTS="127.0.0.1:3633" DISTCC_FALLBACK=0 /usr/local/bin/distcc gcc -o ok.o -c ok.c >/tmp/e2e-selftest-distcc.log 2>&1 \
      || { echo "ERROR: self-test distributed compile failed"; cat /tmp/e2e-selftest-distcc.log distccd.log; exit 1; }; \
    [ -s /tmp/e2e-selftest-distcc.log ] \
      && { echo "ERROR: self-test distributed compile succeeded but emitted output/warnings, treating as a failed check"; cat /tmp/e2e-selftest-distcc.log; exit 1; }; \
    test -f ok.o \
      || { echo "ERROR: self-test distributed compile did not produce ok.o"; cat distccd.log; exit 1; }; \
    found=0; \
    for _ in 1 2 3 4 5 6 7 8 9 10; do \
      grep -q "COMPILE_OK" distccd.log && { found=1; break; }; \
      sleep 0.5; \
    done; \
    [ "${found}" = "1" ] \
      || { echo "ERROR: distccd's own log does not show a COMPILE_OK entry after waiting"; cat distccd.log; exit 1; }; \
    grep -Eq 'EMERGENCY! |ALERT! |CRITICAL! |ERROR: |Warning: ' distccd.log \
      && { echo "ERROR: distccd's own log contains a warning-or-worse severity line; treating as a failed self-test"; cat distccd.log; exit 1; }; \
    pkill -u "$(id -u)" distccd || true; \
    cd / && rm -rf /tmp/e2e-selftest

EXPOSE 3632/tcp
