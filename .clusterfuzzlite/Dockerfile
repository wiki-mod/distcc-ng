# ClusterFuzzLite build environment for distcc-ng (refs #267, Scorecard's
# FuzzingID -- OSS-Fuzz itself was evaluated and rejected as not realistic
# for a young fork without "a significant user base and/or critical to
# the global IT infrastructure", OSS-Fuzz's own stated acceptance bar;
# ClusterFuzzLite is the self-hosted alternative with no such gate).
#
# base-builder:v1 is a deliberately floating tag, not pinned to a digest
# like this repo's other Dockerfiles (docker/release/Dockerfile,
# docker/verify/Dockerfile) -- OSS-Fuzz actively maintains this image as
# its own build environment (clang, libFuzzer, sanitizer runtimes), and
# pinning it to a point-in-time digest would mean missing exactly the
# clang/sanitizer updates this image exists to track. This is ClusterFuzzLite's
# own documented convention, not a deviation invented here.
FROM gcr.io/oss-fuzz-base/base-builder:v1

RUN apt-get update && apt-get install -y --no-install-recommends \
      autoconf \
      automake \
      libtool \
      pkg-config \
      libpopt-dev \
      libavahi-client-dev \
      libzstd-dev \
      libseccomp-dev \
      python3-dev \
      python3-setuptools && \
    rm -rf /var/lib/apt/lists/*

COPY . $SRC/distcc-ng
COPY ./.clusterfuzzlite/build.sh $SRC/
WORKDIR $SRC/distcc-ng
