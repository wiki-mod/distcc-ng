# syntax=docker/dockerfile:1.7
# What: Build, debug and verification image (buildtools).
# Why: Orchestration only; ci.sh and SOT own pins and logic.
# From: Issue #264, Issue #286, Issue #479, PR #544
ARG DEBIAN_IMAGE

FROM ${DEBIAN_IMAGE} AS verify
# What: Bind-mount the checkout for this one step only.
# Why: ci.sh and the SOT must never be baked into a layer.
# From: Issue #479, PR #544
RUN --mount=type=bind,target=/ci bash /ci/.github/scripts/ci.sh image verify
# What: Fixed non-root verify user; callers may pass --user.
# Why: A per-uid build-arg would need one rebuild per caller.
# From: Issue #264, Issue #286
USER verify
WORKDIR /home/verify
CMD ["/bin/bash"]
