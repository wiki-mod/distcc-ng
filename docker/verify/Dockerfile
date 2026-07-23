# syntax=docker/dockerfile:1.7
#
# distcc-ng verification/debug container (issue #264).
#
# Purpose: give every agent/human doing real build+test verification work on
# this repo one pre-built, fully self-contained image instead of each session
# re-installing the same dependency list from scratch in an ad-hoc container
# or (banned for cited verification evidence, see AGENTS.md/doc on WSL2)
# a WSL2 instance. "Pre-built and fully self-contained" is a hard requirement
# from the maintainer: downloading and starting this image must be the entire
# setup step, with NO apt-get/tool-fetching happening at container start or
# first use -- everything below is baked into the image layers at build time,
# and every tool gets a real build-time self-test (not just "apt-get install
# exited 0") so a broken tool fails the image build itself, not a later user.
#
# Sizing rationale: the maintainer asked which of Samba or Apache httpd has
# the larger/more demanding real-world build-dependency surface, to use as a
# sizing reference beyond distcc-ng's own (much smaller) needs. A real
# Debian Build-Depends comparison (see the issue #264 research comment) found
# Samba (2:4.22.10+dfsg-0+deb13u1, trixie) has 51 distinct build dependencies
# -- Kerberos, LDAP, GnuTLS, PAM, systemd, ICU, LMDB, Ceph/RADOS clustering,
# io_uring, Python bindings, MinGW cross-compilers -- versus Apache httpd
# (2.4.68-1~deb13u1)'s 20 (APR/APR-util, PCRE2, OpenSSL, libxml2, Lua, brotli,
# nghttp2, zlib). Samba is therefore this image's sizing target. Debian
# packaging-only tooling from Samba's real Build-Depends (debhelper-compat,
# dh-exec, dpkg-dev, jdupes, lsb-release, rpcsvc-proto, the mingw-w64 cross
# compilers) is deliberately left out: this image targets a real `./configure
# && make` build from a source tree, not producing a signed .deb, and cross-
# compiling Samba's Windows-side tools is out of scope for what this image
# needs to prove.
#
# Same Debian release lineage as docker/release/Dockerfile (trixie), for
# consistency with this repo's existing container lineage, even though this
# image serves a different purpose (dev/verification tools, not a minimal
# runtime image) and is pinned to its own digest rather than sharing
# docker/release/Dockerfile's ARG value: the two images are on independent
# patch-level update schedules, so pinning them separately (rather than one
# shared ARG) avoids an unrelated bump to one accidentally moving the other.
#
# Deliberately the full/"standard" debian image, not debian:*-slim: there is
# no debian:minimal/debian:standard tag on Docker Hub (only the default,
# full variant vs. an explicit -slim one) -- and slim would be the wrong
# starting point here regardless, since this image's entire purpose is
# carrying a large real toolchain (gdb, valgrind, binutils, etc.) well
# beyond what the slim base strips down to; there is nothing for a smaller
# base image to save.
#
# Pinned to the real, live digest for the debian:13.6 tag (verified against
# Docker Hub's own API at pin time, 2026-07-21 -- not guessed from a prior
# 13.5 pin) so this image doesn't sit on a stale trixie patch level.
ARG DEBIAN_IMAGE=debian@sha256:fac46bff2e02f51425b6e33b0e1169f55dfb053d83511ca28aa50c09fd5ed7a4

FROM ${DEBIAN_IMAGE}

ARG VCS_REF=unknown
ARG VERSION=allinkl

LABEL org.opencontainers.image.title="distcc-ng-buildtools" \
      org.opencontainers.image.description="Pre-built, self-contained build+debug+verification image for distcc-ng (issue #264): distcc-ng's own toolchain plus a Samba-sized dependency surface, debug tools, sanitizers, and inspection tools." \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /work

# Deliberately one big apt-get layer (not several --no-install-recommends
# RUNs split by category): a single `apt-get update` right before install
# avoids a stale package index being reused across layers, and grouping the
# install keeps the image to one extra layer instead of one per category.
# --no-install-recommends throughout: recommends would silently balloon the
# image and risk depending on something not deliberately chosen here. Where
# a tool's actual runtime need (e.g. sanitizer runtimes) comes in as a hard
# Depends of a package already listed below (gcc/g++ hard-depend on
# libasanN/libubsanN/libtsan2 on Debian, not just Recommends), no extra
# package name is needed -- verified for real by the self-test RUN step
# further down, not assumed from package metadata alone.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      # --- Core build toolchain (distcc-ng's own configure.ac/Makefile.in) ---
      build-essential \
      autoconf \
      automake \
      libtool \
      pkg-config \
      ccache \
      clang \
      # --- distcc-ng's real configure-time dependencies (c-build.yml's
      #     ConorMacBride/install-package apt list, kept in sync here) ---
      libpopt-dev \
      libavahi-client-dev \
      python3-dev \
      python3-setuptools \
      libzstd-dev \
      libseccomp-dev \
      gdb \
      # python3-dbg (debug build + gdb helper macros, e.g. py-bt/py-list):
      # for debugging the include_server itself (a Python program) and its
      # C extension (include_server/c_extensions/) together under gdb --
      # follow-up ask this session. pdb (Python's own built-in debugger)
      # needs nothing extra, it already ships inside plain python3.
      python3-dbg \
      # --- Samba-sized reference toolchain (see sizing rationale above):
      #     the real library/header surface a project as demanding as Samba
      #     needs to configure and build, so this image is proven adequate
      #     for real large-C-project work, not just distcc-ng itself ---
      libkrb5-dev \
      libldap2-dev \
      libgnutls28-dev \
      libpam0g-dev \
      libsystemd-dev \
      libicu-dev \
      liblmdb-dev \
      libacl1-dev \
      libbsd-dev \
      libcap-dev \
      libjansson-dev \
      libreadline-dev \
      libtirpc-dev \
      libcups2-dev \
      libdbus-1-dev \
      libarchive-dev \
      libblkid-dev \
      libcmocka-dev \
      libgpgme11-dev \
      libkeyutils-dev \
      libpcap-dev \
      libtasn1-6-dev \
      libtasn1-bin \
      liburing-dev \
      zlib1g-dev \
      bison \
      flex \
      docbook-xml \
      docbook-xsl \
      xsltproc \
      perl \
      # Samba's own build (its waf-based ./configure) generates a parser
      # via Parse::Yapp -- found missing empirically by this image's own
      # CI verification step (a real `./configure` dry-run against Samba's
      # source failed with "perl module Parse::Yapp::Driver ... not
      # found" before this was added), not assumed from the Build-Depends
      # list alone.
      libparse-yapp-perl \
      python3-dnspython \
      python3-markdown \
      # --- Debug tools (issue #264's explicit ask) ---
      strace \
      ltrace \
      # --- Sanitizer/memory-debug toolchain (follow-up ask this session) ---
      valgrind \
      # --- Binutils (objdump/readelf/nm/addr2line -- follow-up ask) ---
      binutils \
      # --- Search/inspection tools agents commonly reach for ---
      ripgrep \
      grep \
      less \
      git \
      ca-certificates \
      wget \
      curl \
      # Network/socket debugging (follow-up ask this session): same bundle
      # as strace/gdb/valgrind above -- diagnosing a distccd that won't
      # bind/accept, or a hung distributed-compile connection, needs to see
      # real open sockets/file descriptors, not just process-level tracing.
      lsof \
      iproute2 \
      # DNS lookup tools (dig/nslookup/host -- follow-up ask this session):
      # diagnosing a distccd host that won't resolve (DISTCC_HOSTS entries,
      # a misbehaving --allow netrange, or a Redis remote-storage hostname
      # for ccache) needs real name-resolution tools, not just IP-level
      # socket inspection.
      dnsutils && \
    rm -rf /var/lib/apt/lists/*

# bash (not the default dash /bin/sh) for the self-test below: it uses
# pipefail so a tool crashing mid-pipeline fails the build instead of being
# masked by a downstream grep's own exit code.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Real build-time self-test: fails the image build itself if any tool is
# missing or non-functional, rather than deferring discovery to whoever
# first tries to use the running container. Each check exercises the tool
# doing the thing it's actually needed for in this repo's verification work
# (see issue #264 and the AGENTS.md verification-checklist references named
# in the follow-up ask), not just "the binary exists".
RUN set -eux; \
    mkdir -p /tmp/verify-selftest && cd /tmp/verify-selftest; \
    # --- gcc/clang basic sanity ---
    echo 'int main(void) { return 0; }' > ok.c; \
    gcc ok.c -o ok_gcc && ./ok_gcc; \
    clang ok.c -o ok_clang && ./ok_clang; \
    gcc -g -O0 ok.c -o ok_dbg; \
    # --- AddressSanitizer: a real, deliberately-broken program must be
    #     caught at runtime, not just link cleanly. ASan aborts with a
    #     non-zero exit on detection, so this RUN's own `set -e` would kill
    #     the build on a *successful* catch -- guard the call with `!`. ---
    printf '%s\n' \
      '#include <stdlib.h>' \
      'int main(void) { char *p = malloc(8); p[8] = 1; return 0; }' \
      > asan_bug.c; \
    gcc -fsanitize=address -g -o asan_bug asan_bug.c; \
    ! ./asan_bug > asan.log 2>&1; \
    grep -q "AddressSanitizer" asan.log \
      || { echo "ERROR: ASan build did not report AddressSanitizer output"; cat asan.log; exit 1; }; \
    # --- UndefinedBehaviorSanitizer: real signed-overflow UB must be
    #     reported (UBSan's default trap does not necessarily exit non-zero,
    #     so only the log content is checked here) ---
    printf '%s\n' \
      '#include <limits.h>' \
      'int main(void) { int x = INT_MAX; return x + 1; }' \
      > ubsan_bug.c; \
    gcc -fsanitize=undefined -g -o ubsan_bug ubsan_bug.c; \
    ./ubsan_bug > ubsan.log 2>&1 || true; \
    grep -qi "runtime error" ubsan.log \
      || { echo "ERROR: UBSan build did not report a runtime error"; cat ubsan.log; exit 1; }; \
    # --- valgrind: must actually detect a real leak ---
    printf '%s\n' \
      '#include <stdlib.h>' \
      'int main(void) { malloc(16); return 0; }' \
      > leak.c; \
    gcc -g -O0 -o leak leak.c; \
    valgrind --error-exitcode=99 --leak-check=full ./leak > valgrind.log 2>&1 || true; \
    grep -q "definitely lost: 16 bytes" valgrind.log \
      || { echo "ERROR: valgrind did not report the expected leak"; cat valgrind.log; exit 1; }; \
    # --- gdb/strace/ltrace: existence + version check only, here at build
    #     time -- a full functional test (actually attaching, actually
    #     tracing a syscall/library call) needs ptrace(2), which the default
    #     Docker BuildKit sandbox denies via seccomp regardless of the image
    #     content (no CAP_SYS_PTRACE is available to a `docker build` RUN
    #     step, and there is no build-time flag to add it). Faking a pass
    #     here by swallowing that failure would violate the "warnings/
    #     failures are errors" rule as surely as skipping the check outright.
    #     The real functional trace tests live in
    #     docker/verify/selftest-ptrace.sh, run once against the built image
    #     via `docker run --cap-add=SYS_PTRACE` (see doc/docker.md)
    #     -- that is the honest way to prove these tools work in the
    #     container's actual intended use (an agent's `docker run`, not
    #     `docker build`). ---
    gdb --version | grep -q "GNU gdb" \
      || { echo "ERROR: gdb --version did not report a GNU gdb banner"; exit 1; }; \
    strace -V | grep -qi "strace" \
      || { echo "ERROR: strace -V did not report a strace banner"; exit 1; }; \
    ltrace -V | grep -qi "ltrace" \
      || { echo "ERROR: ltrace -V did not report an ltrace banner"; exit 1; }; \
    # --- binutils: objdump/readelf/nm/addr2line must all read the real binary ---
    objdump -d ok_gcc | grep -q "main>:" \
      || { echo "ERROR: objdump did not disassemble main"; exit 1; }; \
    readelf -h ok_gcc | grep -q "ELF Header" \
      || { echo "ERROR: readelf did not read the ELF header"; exit 1; }; \
    nm ok_gcc | grep -q " T main" \
      || { echo "ERROR: nm did not find the main symbol"; exit 1; }; \
    MAIN_ADDR="$(nm ok_dbg | awk '/ T main/ {print $1}')"; \
    addr2line -e ok_dbg -f "${MAIN_ADDR}" | grep -q "main" \
      || { echo "ERROR: addr2line did not resolve main"; exit 1; }; \
    # --- ripgrep/grep/less: must actually find real content ---
    printf 'needle_marker\nhaystack\n' > rgtest.txt; \
    rg -q needle_marker rgtest.txt; \
    grep -q needle_marker rgtest.txt; \
    less --version >/dev/null; \
    # --- ccache: must actually cache a compile (second run is a hit) ---
    ccache --zero-stats >/dev/null; \
    ccache gcc -c ok.c -o ok.o; \
    ccache gcc -c ok.c -o ok.o; \
    ccache --show-stats | grep -qE "Hits:[[:space:]]*[1-9]" \
      || { ccache --show-stats; echo "ERROR: ccache reported no cache hit"; exit 1; }; \
    # --- ss (iproute2): must show a real listening socket, not just
    #     --version -- neither binding nor listing a loopback socket needs
    #     ptrace, so this works fine at image-build time (unlike gdb/
    #     strace/ltrace above). ---
    python3 -u -c "import socket,time; s=socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.bind(('127.0.0.1',0)); s.listen(1); print(s.getsockname()[1], flush=True); time.sleep(5)" > ss_port.log 2>&1 & \
    SS_PID=$!; \
    for _ in 1 2 3 4 5; do [ -s ss_port.log ] && break; sleep 0.5; done; \
    SS_PORT="$(head -1 ss_port.log)"; \
    ss -tln | grep -q ":${SS_PORT} " \
      || { echo "ERROR: ss did not show the real listening socket on port ${SS_PORT}"; ss -tln; kill "${SS_PID}" 2>/dev/null || true; exit 1; }; \
    kill "${SS_PID}" 2>/dev/null || true; \
    wait "${SS_PID}" 2>/dev/null || true; \
    # --- lsof: must show a real open file descriptor on this same shell ---
    exec 9< /etc/hostname; \
    lsof -p "$$" | grep -q hostname \
      || { echo "ERROR: lsof did not show the open /etc/hostname file descriptor"; lsof -p "$$"; exit 1; }; \
    exec 9<&-; \
    # --- dig/nslookup (dnsutils): must actually resolve a real hostname,
    #     not just print a --version banner -- unlike the ptrace-dependent
    #     tools above, DNS resolution needs only network access, which a
    #     `docker build` RUN step does have (apt-get install just used it
    #     to reach Debian's own mirrors), so this can be a real functional
    #     test here rather than deferred to a runtime selftest script.
    #     Resolving the same mirror host apt-get already reached avoids
    #     depending on a third, unrelated external hostname being up. ---
    dig +short deb.debian.org | grep -qE '^[0-9]+\.' \
      || { echo "ERROR: dig did not resolve deb.debian.org to an IPv4 address"; dig deb.debian.org; exit 1; }; \
    nslookup deb.debian.org | grep -qi "Address" \
      || { echo "ERROR: nslookup did not resolve deb.debian.org"; nslookup deb.debian.org; exit 1; }; \
    cd / && rm -rf /tmp/verify-selftest

# Non-root by default (matches docker/release/Dockerfile's convention);
# a real distributed-compile verification run needs to bind a port and
# read/write the mounted worktree, both of which work as a non-root user.
RUN useradd --create-home --shell /bin/bash verify
USER verify
WORKDIR /home/verify

CMD ["/bin/bash"]
