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

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      autoconf \
      automake \
      build-essential \
      ccache \
      libpopt-dev \
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

# Pump-mode output tree (issue #181), built from these exact same compiled
# objects -- pump mode is enabled by default (only --disable-pump-mode
# turns it off, not passed above), so nothing above needs to be rebuilt.
# `make install` (not a manual file-by-file copy) is deliberate: pump's own
# install step needs to know where include_server.py ends up installed
# (it embeds that path into the installed `pump` wrapper via setup.py's
# --record output, see Makefile.in's install-include-server target's own
# comment) -- a naive `install -D` of the built files would skip that
# wiring and produce a `pump` that can't find its include server.
RUN make install DESTDIR=/out-pump

FROM ${DEBIAN_IMAGE} AS runtime

ARG VCS_REF=unknown
ARG VERSION=allinkl

LABEL org.opencontainers.image.title="distcc-ng" \
      org.opencontainers.image.description="distcc-ng runtime image." \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /work

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      libpopt0 \
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

# --- Pump-mode variant (issue #181): published separately as distcc-ng-pump,
# not a second tag on plain distcc-ng, matching this repo's existing
# distcc-ng-nightly/distcc-ng-buildtools precedent for build variants. ---
FROM ${DEBIAN_IMAGE} AS runtime-pump

ARG VCS_REF=unknown
ARG VERSION=allinkl

LABEL org.opencontainers.image.title="distcc-ng-pump" \
      org.opencontainers.image.description="distcc-ng runtime image with pump mode (server-side preprocessing via the Python include-server) enabled." \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /work

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      libpopt0 \
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
