# syntax=docker/dockerfile:1.7

ARG DEBIAN_IMAGE=debian@sha256:d07d1b51c39f51188e60be9b64e6bf769fa94e187f092bc32b91305cfa34ba5a
ARG PUMP_VARIANT=nopump

FROM ${DEBIAN_IMAGE} AS build

ARG VCS_REF=unknown
ARG VERSION=allinkl
ARG PUMP_VARIANT=nopump

LABEL org.opencontainers.image.title="distcc-ng-zstd ${VERSION} builder" \
      org.opencontainers.image.description="Build stage for the distcc-ng zstd release branch ${VERSION} (${PUMP_VARIANT} image)." \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"
LABEL org.opencontainers.image.variant="${PUMP_VARIANT}"

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
    configure_args="--prefix=/usr/local --with-zstd --enable-Werror"; \
    if [ "${PUMP_VARIANT}" = "nopump" ]; then \
      configure_args="${configure_args} --disable-pump-mode"; \
    fi; \
    ./configure PYTHON=python3 ${configure_args} && \
    make -j"$(nproc)" && \
    make DESTDIR=/out install-programs; \
    if [ "${PUMP_VARIANT}" = "with-pump" ]; then \
      make DESTDIR=/out install-include-server || exit 1; \
      if [ ! -x /out/usr/local/bin/pump ]; then \
        echo "with-pump variant requires /out/usr/local/bin/pump" >&2; \
        exit 1; \
      fi; \
    else \
      distcc_version="$(printf '%s' "${VERSION}" | tr -cd '0-9.')"; \
      if [ -z "${distcc_version}" ]; then \
        distcc_version="0"; \
      fi; \
      include_server_cppflags="-I./src -I./lzo"; \
      mkdir -p /tmp/include_server; \
      PYTHON=python3 \
      SRCDIR=/src \
      DISTCC_VERSION="${distcc_version}" \
      CFLAGS="${CFLAGS} ${PYTHON_CFLAGS}" \
      CPPFLAGS="${CPPFLAGS} ${include_server_cppflags}" \
      python3 /src/include_server/setup.py build \
        --build-base=/tmp/include_server \
        --build-temp=/tmp/include_server \
        install \
        --prefix=/usr/local \
        --root=/out \
        --record=/tmp/include_server/install.log.pre || exit 1; \
      if [ -x /out/usr/local/bin/pump ]; then \
        echo "nopump variant must not install /usr/local/bin/pump" >&2; \
        exit 1; \
      fi; \
    fi; \
    if [ "${PUMP_VARIANT}" = "with-pump" ]; then \
      ln -sf /out/usr/local/bin/pump /out/usr/local/bin/distcc-pump; \
    fi; \
    found_include_server=""; \
    for path in /out/usr/local/lib/python*/dist-packages/include_server/include_server.py; do \
      if [ -f "${path}" ]; then \
        found_include_server="${path}"; \
        break; \
      fi; \
    done; \
    if [ -z "${found_include_server}" ]; then \
      echo "all variants require installed include_server module" >&2; \
      exit 1; \
    fi; \
    echo "include_server artifact check passed: ${found_include_server}"

FROM ${DEBIAN_IMAGE} AS runtime

ARG VCS_REF=unknown
ARG VERSION=allinkl
ARG PUMP_VARIANT=nopump

LABEL org.opencontainers.image.title="distcc-ng-zstd ${VERSION}" \
      org.opencontainers.image.description="distcc-ng-zstd runtime image ${VERSION} with zstd-capable distccd (${PUMP_VARIANT} image)." \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"
LABEL org.opencontainers.image.variant="${PUMP_VARIANT}"

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /work

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      libpopt0 \
      libzstd1 \
      procps \
      python3 && \
    rm -rf /var/lib/apt/lists/* && \
    useradd --create-home --shell /usr/sbin/nologin distcc

COPY --from=build /out/ /

RUN /usr/local/sbin/update-distcc-symlinks && \
    if [ "${PUMP_VARIANT}" = "with-pump" ] && [ -x /usr/local/bin/pump ]; then \
      ln -sf /usr/local/bin/pump /usr/local/bin/distcc-pump; \
    fi

USER distcc
EXPOSE 3632/tcp

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD distccd --version >/dev/null 2>&1 || exit 1

CMD ["distccd", "--daemon", "--no-detach", "--log-stderr", "--allow", "127.0.0.1"]
