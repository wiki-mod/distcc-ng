#!/bin/bash -eu
# What: ClusterFuzzLite build entry; CFL runs $SRC/build.sh.
# Why: Orchestration only; ci.sh owns the fuzz build logic.
# From: Issue #267, Issue #479, PR #544
exec bash "${SRC}/distcc-ng/.github/scripts/ci.sh" workload fuzz-build
