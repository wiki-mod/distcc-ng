# syntax=docker/dockerfile:1.7
# What: Release images: build, runtime, runtime-pump stages.
# Why: Orchestration only; ci.sh and SOT own pins and logic.
# From: Issue #181, Issue #359, Issue #479, PR #544
ARG DEBIAN_IMAGE

FROM ${DEBIAN_IMAGE} AS build
# What: Bind-mount the checkout for this one step only.
# Why: ci.sh and the SOT must never be baked into a layer.
# From: Issue #479, PR #544
RUN --mount=type=bind,target=/ci,rw bash /ci/.github/scripts/ci.sh image release-build

FROM ${DEBIAN_IMAGE} AS runtime
RUN --mount=type=bind,target=/ci bash /ci/.github/scripts/ci.sh image release-runtime
COPY --from=build /out/ /
USER distcc
EXPOSE 3632/tcp
# What: Liveness only: distccd starts, no compile round-trip.
# Why: A probe must stay cheap; this image ships no client.
# From: Issue #44, PR #487
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["distccd", "--version"]
# What: Loopback-only default; deployments override --allow.
# Why: Safe by default (doc/docker.md, Running as a server).
# From: Issue #44, PR #487
CMD ["distccd", "--daemon", "--no-detach", "--log-stderr", "--allow", "127.0.0.1", "--enable-tcp-insecure"]

FROM runtime AS runtime-pump
COPY --from=build /out-pump/usr/local/ /usr/local/
