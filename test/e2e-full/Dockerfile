# syntax=docker/dockerfile:1.7
#
# Full bidirectional native-compatibility E2E containers (issue #264's later
# design comments -- the "full automated distributed-build E2E test" idea,
# distinct from test/e2e/Dockerfile's quick two-container hello-world-style
# check). Two roles, one Dockerfile, two named build stages sharing a common
# base so both sides carry byte-identical OS packages/build toolchain and
# only differ in which distcc/distccd binaries they run:
#
#   - `ng`:     throwaway container built fresh from the actual current_dev
#               checkout being tested (issue #264 design point 3) -- built
#               via `docker build --target ng`, discarded after the run.
#   - `native`: stable native-reference container, Debian's own packaged
#               `distcc` AND `distcc-pump` (two separate Debian packages,
#               both exercised -- design point 3/4) via `apt`, pinned to the
#               same Debian release as docker/release/Dockerfile's base image
#               (trixie/13). Stays constant across runs.
#
# Two separate containers (not one), per the maintainer's explicit design:
# this avoids the distcc/distccd binary-name collision between this fork's
# own build and the native package cleanly (no PATH tricks), and as a side
# effect makes parallel runs possible.
#
# Both stages carry the SAME real-workload build toolchain (Samba's own
# waf-based ./configure needs a Samba-sized dependency surface -- reused
# verbatim from docker/verify/Dockerfile's own sizing research, issue #264,
# rather than re-deriving it) because each container takes a turn being the
# *client* half of the bidirectional matrix below, and it's the client that
# runs the project's own build system (`waf`) -- the *server* half only ever
# needs a matching compiler to actually execute a received compile job
# (distcc's client-side preprocessing means the server never needs the
# project's source tree or headers, only the same compiler).
#
# Workload source (Samba/Apache httpd tarballs) is fetched and verified at
# *test run time* by test/e2e-full/workload-*.sh, not baked into either image
# at build time -- keeps both images generic/reusable across runs and avoids
# a large tarball download landing in every image layer when only one
# workload is actually exercised per run.
ARG DEBIAN_IMAGE=debian@sha256:fac46bff2e02f51425b6e33b0e1169f55dfb053d83511ca28aa50c09fd5ed7a4

FROM ${DEBIAN_IMAGE} AS workload_base

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /work

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      # --- Real compiler + tools needed to run distcc/distccd itself ---
      build-essential \
      gcc \
      g++ \
      pkg-config \
      ca-certificates \
      wget \
      gnupg \
      procps \
      # --- distcc-ng's own configure-time build deps (`ng` stage builds
      #     this repo from source -- same list as docker/verify/Dockerfile
      #     and c-build.yml's install-package apt list, kept in sync) ---
      autoconf \
      automake \
      libtool \
      libpopt-dev \
      libavahi-client-dev \
      python3-setuptools \
      libzstd-dev \
      libseccomp-dev \
      # --- Samba's own waf-based build toolchain (client role only -- see
      #     the Dockerfile-level comment above). Reused verbatim from
      #     docker/verify/Dockerfile's own Samba-sizing research (issue
      #     #264) rather than re-derived here. ---
      python3 \
      python3-dev \
      python3-setuptools \
      python3-dnspython \
      python3-markdown \
      libkrb5-dev \
      libldap2-dev \
      libgnutls28-dev \
      libpam0g-dev \
      libsystemd-dev \
      libicu-dev \
      liblmdb-dev \
      libacl1-dev \
      libbsd-dev \
      libcap-dev \
      libjansson-dev \
      libreadline-dev \
      libtirpc-dev \
      libcups2-dev \
      libdbus-1-dev \
      libarchive-dev \
      libblkid-dev \
      libcmocka-dev \
      libgpgme11-dev \
      libkeyutils-dev \
      libpcap-dev \
      libtasn1-6-dev \
      libtasn1-bin \
      liburing-dev \
      zlib1g-dev \
      bison \
      flex \
      docbook-xml \
      docbook-xsl \
      xsltproc \
      perl \
      libparse-yapp-perl \
      # --- Apache httpd's own build toolchain (feature-flagged-off
      #     workload, workload-apache.sh -- present so the toggle really is
      #     a one-line change, not a rewrite that also needs a new image) ---
      libapr1-dev \
      libaprutil1-dev \
      libpcre2-dev \
      libssl-dev \
      libxml2-dev \
      liblua5.4-dev \
      libbrotli-dev \
      libnghttp2-dev && \
    rm -rf /var/lib/apt/lists/*

# Non-root by default, matching this repo's other containers -- distccd
# refuses to run as real root without --user, and a real distributed-compile
# run needs to bind a port and read/write the workload tree, both of which
# work fine as a non-root user.
RUN useradd --create-home --shell /bin/bash e2e
RUN mkdir -p /work/workload && chown -R e2e:e2e /work

# --- Throwaway build container: current_dev's own distcc/distccd/pump, ------
# built fresh from the actual checkout under test (issue #264 design point 3:
# "this job builds distcc/distccd/pump fresh inside the test itself, not
# reusing an earlier CI artifact"). Discarded after this one run.
FROM workload_base AS ng

COPY --chown=e2e:e2e . /work/src

RUN cd /work/src && \
    ./autogen.sh && \
    ./configure PYTHON=python3 --prefix=/usr/local && \
    make -j"$(nproc)" && \
    make install && \
    make clean

# Masquerade whitelist (see test/e2e/Dockerfile's identical step for the
# full rationale): without --enable-tcp-insecure, distccd requires the
# requested compiler name to resolve inside LIBDIR/distcc.
RUN /usr/local/sbin/update-distcc-symlinks

USER e2e
WORKDIR /work
EXPOSE 3632/tcp
CMD ["sleep", "infinity"]

# --- Stable native-reference container: Debian's own packaged distcc AND ---
# distcc-pump (separate packages, both exercised -- design point 3), pinned
# to the same Debian release as docker/release/Dockerfile's base image.
# Stays constant across runs, unlike the `ng` stage above.
FROM workload_base AS native

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      distcc \
      distcc-pump && \
    rm -rf /var/lib/apt/lists/*

# Debian's own distcc package's postinst normally populates the masquerade
# dir (/usr/lib/distcc) via debconf during a real `dpkg -i`/interactive
# install; --no-install-recommends plus DEBIAN_FRONTEND=noninteractive can
# leave that step incomplete in a container build, so this is run explicitly
# and defensively rather than assumed -- matching how `ng`'s own masquerade
# step above is never assumed either.
RUN command -v update-distcc-symlinks >/dev/null && update-distcc-symlinks || true

USER e2e
WORKDIR /work
EXPOSE 3632/tcp
CMD ["sleep", "infinity"]
