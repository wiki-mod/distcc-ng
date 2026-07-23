# ClusterFuzzLite build environment for distcc-ng (refs #267, Scorecard's
# FuzzingID -- OSS-Fuzz itself was evaluated and rejected as not realistic
# for a young fork without "a significant user base and/or critical to
# the global IT infrastructure", OSS-Fuzz's own stated acceptance bar;
# ClusterFuzzLite is the self-hosted alternative with no such gate).
#
# base-builder's default "v1" tag is Ubuntu 20.04-based, which only ships
# autoconf 2.69 via apt (confirmed live: "configure.ac:12: error: Autoconf
# version 2.71 or higher is required"). Tried switching to the newer
# "ubuntu-24-04" tag instead (a real, published tag, verified via GCR's
# tags/list API) to get autoconf 2.71 via apt directly -- but that
# introduced a WORSE, harder-to-diagnose problem: ClusterFuzzLite's
# post-build "bad build check" runs the built binary directly on the
# GitHub Actions HOST runner (not inside this build container) -- so a
# binary linked against Ubuntu 24.04's newer glibc (2.38) fails there
# with "version `GLIBC_2.38' not found", since the host runner's own
# glibc is older. Ubuntu 20.04's glibc is old enough to be compatible
# with that host runner (this is exactly why ClusterFuzzLite's own
# documented examples default to :v1, not a newer tag) -- so :v1 stays,
# and autoconf 2.71 is built from source instead (small, no compile-heavy
# dependency; sha256 verified against the actual downloaded tarball, not
# copied from an unverified third-party listing).
#
# Not pinned to a digest like this repo's other Dockerfiles
# (docker/release/Dockerfile, docker/verify/Dockerfile) -- OSS-Fuzz
# actively maintains this image as its own build environment (clang,
# libFuzzer, sanitizer runtimes), and pinning it to a point-in-time
# digest would mean missing exactly the clang/sanitizer updates this
# image exists to track. This is ClusterFuzzLite's own documented
# convention, not a deviation invented here.
FROM gcr.io/oss-fuzz-base/base-builder:v1

RUN apt-get update && apt-get install -y --no-install-recommends \
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
      # found"). libkrb5-dev provides it, same package docker/verify/Dockerfile
      # already installs for its Samba-sized dependency surface.
      libkrb5-dev && \
    rm -rf /var/lib/apt/lists/*

# autoconf 2.71+ built from source -- :v1's Ubuntu 20.04 base only ships
# 2.69 via apt, but configure.ac requires AC_PREREQ([2.71]). sha256
# computed directly from the real downloaded tarball, not copied from an
# unverified third-party listing.
RUN set -euo pipefail; \
    curl -fsSL https://ftp.gnu.org/gnu/autoconf/autoconf-2.71.tar.gz -o /tmp/autoconf-2.71.tar.gz; \
    echo "431075ad0bf529ef13cb41e9042c542381103e80015686222b8a9d4abef42a1c  /tmp/autoconf-2.71.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/autoconf-2.71.tar.gz -C /tmp; \
    ( cd /tmp/autoconf-2.71 && ./configure && make -j"$(nproc)" && make install ); \
    rm -rf /tmp/autoconf-2.71 /tmp/autoconf-2.71.tar.gz; \
    autoconf --version | head -1

COPY . $SRC/distcc-ng
COPY ./.clusterfuzzlite/build.sh $SRC/
WORKDIR $SRC/distcc-ng
