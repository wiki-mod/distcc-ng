# ClusterFuzzLite build environment for distcc-ng (refs #267, Scorecard's
# FuzzingID -- OSS-Fuzz itself was evaluated and rejected as not realistic
# for a young fork without "a significant user base and/or critical to
# the global IT infrastructure", OSS-Fuzz's own stated acceptance bar;
# ClusterFuzzLite is the self-hosted alternative with no such gate).
#
# base-builder's default "v1" tag is Ubuntu 20.04-based, which only ships
# autoconf 2.69 via apt -- confirmed live, the first real build attempt
# against :v1 failed with "configure.ac:12: error: Autoconf version 2.71
# or higher is required" (configure.ac's AC_PREREQ([2.71])). Using the
# "ubuntu-24-04" tag instead (a real, actively-published tag on this
# image -- verified via the GCR registry's own tags/list API, and used
# the same way by other real OSS-Fuzz projects, e.g. memcached's own
# harness) resolves this at the source: Ubuntu 24.04 packages autoconf
# 2.71-3 (verified via Launchpad's own package-archive API), so no
# from-source autoconf build is needed.
#
# Not pinned to a digest like this repo's other Dockerfiles
# (docker/release/Dockerfile, docker/verify/Dockerfile) -- OSS-Fuzz
# actively maintains this image as its own build environment (clang,
# libFuzzer, sanitizer runtimes), and pinning it to a point-in-time
# digest would mean missing exactly the clang/sanitizer updates this
# image exists to track. This is ClusterFuzzLite's own documented
# convention, not a deviation invented here.
FROM gcr.io/oss-fuzz-base/base-builder:ubuntu-24-04

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
      python3-setuptools \
      # src/auth.h unconditionally includes <gssapi/gssapi.h> -- confirmed
      # live (build failure: "fatal error: 'gssapi/gssapi.h' file not
      # found"). libkrb5-dev provides it (verified via Ubuntu's own
      # packages.ubuntu.com file-list for noble/libkrb5-dev), same package
      # docker/verify/Dockerfile already installs for its Samba-sized
      # dependency surface.
      libkrb5-dev && \
    rm -rf /var/lib/apt/lists/*

COPY . $SRC/distcc-ng
COPY ./.clusterfuzzlite/build.sh $SRC/
WORKDIR $SRC/distcc-ng
