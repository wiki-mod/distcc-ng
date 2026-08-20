# syntax=docker/dockerfile:1.7

ARG DEBIAN_IMAGE=debian@sha256:d07d1b51c39f51188e60be9b64e6bf769fa94e187f092bc32b91305cfa34ba5a

FROM ${DEBIAN_IMAGE} AS build

ARG VCS_REF=unknown
ARG VERSION=allinkl

LABEL org.opencontainers.image.title="distcc-ng builder" \
      org.opencontainers.image.description="Build stage for the distcc-ng release branch." \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /src

# What: Package list adds libelf-dev. No libpopt-dev.
# Why: Enables configure's --with-libelf probe; without it distccd
#   silently keeps the pre-fix, compressed-debug-info bug. libpopt-dev is
#   deliberately absent so --without-system-popt below always builds
#   against this fork's own vendored, CVE-fixed popt/ tree instead of
#   Debian's own libpopt package, whose CVE-2026-18739 fix is not yet in
#   trixie as of this writing (checked against Debian's security tracker).
# From: Issue #398, PR #487
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      autoconf \
      automake \
      build-essential \
      ccache \
      libelf-dev \
      libseccomp-dev \
      libzstd-dev \
      pkg-config \
      python3-dev \
      python3-setuptools && \
    rm -rf /var/lib/apt/lists/*

COPY . .

# What: --without-system-popt forces the vendored popt/ tree.
# Why: Statically links our own fork's fixed popt into distccd (the only
#   binary that uses popt, via src/dopt.c) instead of linking Debian's own
#   libpopt0 at runtime, whose known CVEs this image would otherwise ship
#   unpatched (see the apt-get comment above). This is an explicit build
#   choice, not just "no libpopt-dev installed" relying on configure's
#   autodetection to fall back correctly -- it stays correct even if a
#   future base image change adds libpopt back in as a transitive
#   dependency of something else.
# From: PR #504
RUN ./autogen.sh && \
    ./configure PYTHON=python3 --prefix=/usr/local --enable-Werror --without-system-popt && \
    make -j"$(nproc)" && \
    install -D distcc /out/usr/local/bin/distcc && \
    install -D distccd /out/usr/local/bin/distccd && \
    install -D lsdistcc /out/usr/local/bin/lsdistcc && \
    install -D distccmon-text /out/usr/local/bin/distccmon-text

# What: `make install`, then renames the installed `pump` wrapper to
#   `distcc-pump`.
# Why: `make install` (not a manual copy) embeds the include-server's
#   path into the wrapper; the rename matches Debian's real package.
# From: Issue #181, Issue #485
RUN make install DESTDIR=/out-pump && \
    mv /out-pump/usr/local/bin/pump /out-pump/usr/local/bin/distcc-pump

FROM ${DEBIAN_IMAGE} AS runtime

ARG VCS_REF=unknown
ARG VERSION=allinkl

LABEL org.opencontainers.image.title="distcc-ng" \
      org.opencontainers.image.description="distcc-ng runtime image." \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /work

# What: Package list adds libelf1, the runtime counterpart to
#   libelf-dev above.
# Why: distccd links against it when built; without libelf1 here the
#   binary copied in below fails to start (missing shared library).
# From: Issue #398, PR #487
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      libelf1 \
      libseccomp2 \
      libzstd1 \
      python3 && \
    rm -rf /var/lib/apt/lists/* && \
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin distcc

COPY --from=build /out/ /

USER distcc
EXPOSE 3632/tcp

# What: HEALTHCHECK only proves the binary starts (--version), not a
#   real compile round-trip.
# Why: A liveness probe must stay cheap; a real compile would need a
#   client/toolchain this image doesn't ship.
# From: doc/docker.md
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD distccd --version >/dev/null 2>&1 || exit 1

# What: Default CMD binds only --allow 127.0.0.1, not a real network.
# Why: Safe-by-default; doc/docker.md's own "Running as a server"
#   section documents overriding --allow for real deployment.
# From: doc/docker.md
CMD ["distccd", "--daemon", "--no-detach", "--log-stderr", "--allow", "127.0.0.1", "--enable-tcp-insecure"]

# What: Pump-mode variant, published separately as distcc-ng-pump.
# Why: Matches this repo's existing distcc-ng-nightly/distcc-ng-buildtools
#   precedent of a separate package per build variant, not a second tag
#   on plain distcc-ng.
# From: Issue #181
FROM ${DEBIAN_IMAGE} AS runtime-pump

ARG VCS_REF=unknown
ARG VERSION=allinkl

LABEL org.opencontainers.image.title="distcc-ng-pump" \
      org.opencontainers.image.description="distcc-ng runtime image with pump mode (server-side preprocessing via the Python include-server) enabled." \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /work

# What: libelf1 here for the same reason as the plain `runtime` stage
#   above.
# Why: This stage's distccd is the exact same build output, so it needs
#   the identical runtime library or it fails to start (issue #398).
# From: PR #487
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      libelf1 \
      libseccomp2 \
      libzstd1 \
      python3 && \
    rm -rf /var/lib/apt/lists/* && \
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin distcc

COPY --from=build /out-pump/usr/local/ /usr/local/

USER distcc
EXPOSE 3632/tcp

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD distccd --version >/dev/null 2>&1 || exit 1

CMD ["distccd", "--daemon", "--no-detach", "--log-stderr", "--allow", "127.0.0.1", "--enable-tcp-insecure"]
