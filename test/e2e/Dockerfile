# syntax=docker/dockerfile:1.7
# What: e2e images ng and native, one ci.sh call each.
# Why: Dockerfile only orchestrates; ci.sh/SOT own logic.
# From: Issue #264, Issue #479, PR #544
ARG TOOLCHAIN_IMAGE

FROM ${TOOLCHAIN_IMAGE} AS ng
USER root
# What: Bind-mount the checkout for this one step only.
# Why: ci.sh and the SOT must never be baked into a layer.
# From: Issue #479, PR #544
RUN --mount=type=bind,target=/ci,rw bash /ci/.github/scripts/ci.sh image e2e-ng
USER e2e
WORKDIR /work

FROM ${TOOLCHAIN_IMAGE} AS native
USER root
RUN --mount=type=bind,target=/ci bash /ci/.github/scripts/ci.sh image e2e-native
USER e2e
WORKDIR /work
