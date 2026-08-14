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

# What: libelf-dev is included so configure's --with-libelf probe finds
#   elf_compress and enables it.
# Why: Without it, distccd falls back to the pre-fix raw <elf.h> path,
#   which silently fails to rewrite a compressed (SHF_COMPRESSED) debug
#   section (issue #398) -- a real, shippable regression, not just a
#   local build-config choice.
# From: PR #487
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      autoconf \
      automake \
      build-essential \
      ccache \
      libelf-dev \
      libpopt-dev \
      libseccomp-dev \
      libzstd-dev \
      pkg-config \
      python3-dev \
      python3-setuptools && \
    rm -rf /var/lib/apt/lists/*

COPY . .

RUN ./autogen.sh && \
    ./configure PYTHON=python3 --prefix=/usr/local --enable-Werror && \
    make -j"$(nproc)" && \
    install -D distcc /out/usr/local/bin/distcc && \
    install -D distccd /out/usr/local/bin/distccd && \
    install -D lsdistcc /out/usr/local/bin/lsdistcc && \
    install -D distccmon-text /out/usr/local/bin/distccmon-text

# What: Builds the pump-mode output tree via `make install` (same
#   compiled objects as above) and renames the installed `pump` wrapper
#   to `distcc-pump`.
# Why: `make install`, not a manual file copy, is required because
#   pump's install step embeds the include-server's install path into
#   the wrapper via setup.py's --record output, which a manual copy
#   would skip; the rename afterward matches Debian's own real
#   distcc-pump package, done in this same packaging layer.
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

# What: libelf1 is the runtime counterpart to the build stage's
#   libelf-dev.
# Why: distccd is now dynamically linked against libelf (issue #398's
#   compressed-debug-info fix) whenever the build stage detects it --
#   without libelf1 here, the binary copied in below would fail to
#   start at all (missing shared library), not just lose the fix.
# From: PR #487
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      libelf1 \
      libpopt0 \
      libseccomp2 \
      libzstd1 \
      python3 && \
    rm -rf /var/lib/apt/lists/* && \
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin distcc

COPY --from=build /out/ /

USER distcc
EXPOSE 3632/tcp

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD distccd --version >/dev/null 2>&1 || exit 1

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
      libpopt0 \
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
