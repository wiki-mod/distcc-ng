# syntax=docker/dockerfile:1.7
# What: ClusterFuzzLite image on the SOT-pinned base-builder.
# Why: CFL passes no build-args; ci.sh tags the SOT pin first.
# From: Issue #267, Issue #479, PR #544
FROM distcc-ng-cfl-base:local
# What: Bind-mount the checkout for this one step only.
# Why: ci.sh and the SOT must never be baked into a layer.
# From: Issue #479, PR #544
RUN --mount=type=bind,target=/ci bash /ci/.github/scripts/ci.sh image cfl-toolchain
COPY . $SRC/distcc-ng
COPY ./.clusterfuzzlite/build.sh $SRC/
WORKDIR $SRC/distcc-ng
