# syntax=docker/dockerfile:1.7
#
# What: distcc-ng's pre-built, fully self-contained verification/debug
#   image: build toolchain, sanitizers, and inspection tools, all baked in
#   with real build-time self-tests.
# Why: Verification evidence must run in one image with nothing installed
#   at container start, never an ad-hoc container or WSL2 (AGENTS.md rule
#   87).
# From: Issue #264

# What: Pins the base image to a specific debian:13.6 digest, full (not
#   slim) variant.
# Why: This image's whole point is carrying a large toolchain that the
#   slim base would strip down.
# From: Issue #264
ARG DEBIAN_IMAGE=debian@sha256:fac46bff2e02f51425b6e33b0e1169f55dfb053d83511ca28aa50c09fd5ed7a4

# What: Builds actionlint from source instead of using its release binary.
# Why: Go statically embeds its stdlib, so an official actionlint release
#   binary can carry a stale, CVE-affected stdlib version that only a
#   fresh source build fixes.
# From: Issue #267
FROM golang@sha256:2005724102f45917a63e9d092fc0e4ea56ea575048ce147caad5f5f61502c365 AS actionlint-builder
ARG ACTIONLINT_VERSION=1.7.12
# What: Uses `set -eu` instead of `set -eo pipefail`.
# Why: This stage has no SHELL override, so RUN runs under dash, which
#   rejects the bash-only `pipefail`; no pipe exists here anyway, so `-eu`
#   gives the same fail-fast guarantee.
RUN set -eu; \
    GOBIN=/out go install "github.com/rhysd/actionlint/cmd/actionlint@v${ACTIONLINT_VERSION}"; \
    /out/actionlint --version

FROM ${DEBIAN_IMAGE}

ARG VCS_REF=unknown
ARG VERSION=allinkl

LABEL org.opencontainers.image.title="distcc-ng-buildtools" \
      org.opencontainers.image.description="Pre-built, self-contained build+debug+verification image for distcc-ng (issue #264): distcc-ng's own toolchain plus a Samba-sized dependency surface, debug tools, sanitizers, and inspection tools." \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /work

# What: Installs the full toolchain in one apt-get layer with
#   --no-install-recommends.
# Why: --no-install-recommends keeps only deliberately-chosen packages; a
#   hard Depends already covers real runtime needs (e.g. sanitizer
#   runtimes via gcc/g++), verified by the self-test below.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      # What: Core build toolchain (distcc-ng's own configure.ac/Makefile.in).
      build-essential \
      autoconf \
      automake \
      libtool \
      pkg-config \
      ccache \
      clang \
      # What: distcc-ng's real configure-time dependencies, kept in sync
      #   with c-build.yml's install-package apt list.
      libpopt-dev \
      libavahi-client-dev \
      python3-dev \
      python3-setuptools \
      libzstd-dev \
      libseccomp-dev \
      gdb \
      # What: python3-dbg adds gdb helper macros (py-bt/py-list).
      # Why: include_server is Python plus a C extension
      #   (include_server/c_extensions/), and debugging both together needs
      #   gdb's Python macros; pdb needs nothing extra since it already
      #   ships in plain python3.
      python3-dbg \
      # What: Reference toolchain sized to build a real, demanding C project.
      # Why: Samba's real Debian build-dependency surface (51 packages) is
      #   far larger than a comparable large project like Apache httpd's
      #   (20), so matching it proves this image adequate for
      #   large-C-project work beyond distcc-ng's own needs.
      # From: Issue #264
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
      # What: libparse-yapp-perl is required by Samba's waf-based ./configure.
      # Why: Missing it fails a real ./configure dry-run against Samba's
      #   source ("perl module Parse::Yapp::Driver ... not found").
      # From: Issue #264
      libparse-yapp-perl \
      python3-dnspython \
      python3-markdown \
      # What: strace/ltrace for tracing distccd/include_server syscalls and
      #   library calls without attaching a debugger.
      # From: Issue #264
      strace \
      ltrace \
      # What: valgrind for memory-safety debugging without a
      #   sanitizer-instrumented rebuild.
      valgrind \
      # What: objdump/readelf/nm/addr2line for inspecting distccd/
      #   include_server binaries and symbols.
      binutils \
      # What: libelf-dev adds the libelf.h/gelf.h programming API.
      # Why: elf.h (already present via libc6-dev) only defines raw ELF
      #   struct layouts, with no API for safely reading, decompressing, or
      #   rewriting an ELF section's contents.
      # From: Issue #398
      libelf-dev \
      # What: search/inspection tools agents commonly reach for.
      ripgrep \
      grep \
      less \
      git \
      ca-certificates \
      wget \
      curl \
      # What: lsof/iproute2 for network/socket debugging.
      # Why: Diagnosing a distccd that won't bind/accept needs real
      #   open-socket visibility, not just process-level tracing.
      lsof \
      iproute2 \
      # What: dig/nslookup/host for DNS lookup diagnostics.
      # Why: A distccd host that won't resolve needs real name-resolution
      #   tools, not just IP-level socket inspection.
      dnsutils \
      # What: shellcheck/jq, apt-installed rather than built from source.
      # Why: Neither is a statically-linked Go binary like actionlint
      #   (shellcheck is Haskell, jq is plain C), so Debian's packaged
      #   versions carry no stale-stdlib risk.
      # From: Issue #267
      shellcheck \
      jq \
      # What: openssh-server/openssh-client for SSHMode_Case's real sshd
      #   test.
      # Why: This image was the one place SSHMode_Case silently
      #   NOTRUN-skipped, since GitHub's runner images ship both already
      #   but this one didn't.
      # From: Issue #275, Issue #440
      openssh-server \
      openssh-client && \
    rm -rf /var/lib/apt/lists/*

# What: Copies the source-built actionlint binary into the final image.
# Why: Replaces a curl|bash fetch at CI runtime with a pinned, source-built
#   binary.
# From: Issue #267
COPY --from=actionlint-builder /out/actionlint /usr/local/bin/actionlint

# What: Switches SHELL to bash for the self-test RUN block below.
# Why: pipefail is bash-only and this stage's default dash would reject
#   it, which would let a mid-pipeline tool crash go undetected.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# What: Build-time self-test exercising every installed tool for real use,
#   not just checking the binary exists.
# Why: Fails the image build itself on a missing/broken tool, instead of
#   deferring discovery to whoever first uses the running container.
# From: Issue #264
RUN set -eux; \
    mkdir -p /tmp/verify-selftest && cd /tmp/verify-selftest; \
    # What: Confirms gcc/clang produce a real, runnable binary.
    echo 'int main(void) { return 0; }' > ok.c; \
    gcc ok.c -o ok_gcc && ./ok_gcc; \
    clang ok.c -o ok_clang && ./ok_clang; \
    gcc -g -O0 ok.c -o ok_dbg; \
    # What: Confirms ASan catches a real heap-overflow at runtime.
    # Why: ASan aborts non-zero on a real catch, which would otherwise trip
    #   this RUN's own `set -e`; the `!` guard lets that expected abort pass.
    printf '%s\n' \
      '#include <stdlib.h>' \
      'int main(void) { char *p = malloc(8); p[8] = 1; return 0; }' \
      > asan_bug.c; \
    gcc -fsanitize=address -g -o asan_bug asan_bug.c; \
    ! ./asan_bug > asan.log 2>&1; \
    grep -q "AddressSanitizer" asan.log \
      || { echo "ERROR: ASan build did not report AddressSanitizer output"; cat asan.log; exit 1; }; \
    # What: Confirms UBSan reports a real signed-overflow.
    # Why: UBSan's default trap does not reliably exit non-zero, so only
    #   the log content is checked here.
    printf '%s\n' \
      '#include <limits.h>' \
      'int main(void) { int x = INT_MAX; return x + 1; }' \
      > ubsan_bug.c; \
    gcc -fsanitize=undefined -g -o ubsan_bug ubsan_bug.c; \
    ./ubsan_bug > ubsan.log 2>&1 || true; \
    grep -qi "runtime error" ubsan.log \
      || { echo "ERROR: UBSan build did not report a runtime error"; cat ubsan.log; exit 1; }; \
    # What: Confirms valgrind detects a real memory leak.
    printf '%s\n' \
      '#include <stdlib.h>' \
      'int main(void) { malloc(16); return 0; }' \
      > leak.c; \
    gcc -g -O0 -o leak leak.c; \
    valgrind --error-exitcode=99 --leak-check=full ./leak > valgrind.log 2>&1 || true; \
    grep -q "definitely lost: 16 bytes" valgrind.log \
      || { echo "ERROR: valgrind did not report the expected leak"; cat valgrind.log; exit 1; }; \
    # What: gdb/strace/ltrace get only an existence + version check here.
    # Why: A real functional test needs ptrace(2), which BuildKit's build
    #   sandbox denies with no way to add CAP_SYS_PTRACE; the real test
    #   runs later, in docker/verify/selftest-ptrace.sh via `docker run
    #   --cap-add=SYS_PTRACE` (see doc/docker.md).
    gdb --version | grep -q "GNU gdb" \
      || { echo "ERROR: gdb --version did not report a GNU gdb banner"; exit 1; }; \
    strace -V | grep -qi "strace" \
      || { echo "ERROR: strace -V did not report a strace banner"; exit 1; }; \
    ltrace -V | grep -qi "ltrace" \
      || { echo "ERROR: ltrace -V did not report an ltrace banner"; exit 1; }; \
    # What: Confirms objdump/readelf/nm/addr2line all read the real binary.
    objdump -d ok_gcc | grep -q "main>:" \
      || { echo "ERROR: objdump did not disassemble main"; exit 1; }; \
    readelf -h ok_gcc | grep -q "ELF Header" \
      || { echo "ERROR: readelf did not read the ELF header"; exit 1; }; \
    nm ok_gcc | grep -q " T main" \
      || { echo "ERROR: nm did not find the main symbol"; exit 1; }; \
    MAIN_ADDR="$(nm ok_dbg | awk '/ T main/ {print $1}')"; \
    addr2line -e ok_dbg -f "${MAIN_ADDR}" | grep -q "main" \
      || { echo "ERROR: addr2line did not resolve main"; exit 1; }; \
    # What: Confirms libelf-dev works: compiles, links -lelf, and reads a
    #   real ELF header from ok_gcc via the libelf API.
    # Why: Proves the API actually works, not just that the headers exist
    #   on disk.
    # From: Issue #398
    printf '%s\n' \
      '#include <fcntl.h>' \
      '#include <stdio.h>' \
      '#include <unistd.h>' \
      '#include <libelf.h>' \
      '#include <gelf.h>' \
      'int main(void) {' \
      '  if (elf_version(EV_CURRENT) == EV_NONE) { fprintf(stderr, "elf_version failed\n"); return 1; }' \
      '  int fd = open("ok_gcc", O_RDONLY);' \
      '  if (fd < 0) { perror("open"); return 1; }' \
      '  Elf *e = elf_begin(fd, ELF_C_READ, NULL);' \
      '  if (!e || elf_kind(e) != ELF_K_ELF) { fprintf(stderr, "elf_begin/elf_kind failed\n"); return 1; }' \
      '  GElf_Ehdr ehdr;' \
      '  if (!gelf_getehdr(e, &ehdr)) { fprintf(stderr, "gelf_getehdr failed\n"); return 1; }' \
      '  printf("libelf_selftest_ok e_type=%d\n", ehdr.e_type);' \
      '  elf_end(e); close(fd);' \
      '  return 0;' \
      '}' \
      > libelf_selftest.c; \
    gcc libelf_selftest.c -lelf -o libelf_selftest; \
    ./libelf_selftest > libelf_selftest.log 2>&1; \
    grep -q "libelf_selftest_ok" libelf_selftest.log \
      || { echo "ERROR: libelf selftest did not report success"; cat libelf_selftest.log; exit 1; }; \
    # What: Confirms ripgrep/grep/less actually find real content.
    printf 'needle_marker\nhaystack\n' > rgtest.txt; \
    rg -q needle_marker rgtest.txt; \
    grep -q needle_marker rgtest.txt; \
    less --version >/dev/null; \
    # What: Confirms ccache actually caches a compile (second run hits).
    ccache --zero-stats >/dev/null; \
    ccache gcc -c ok.c -o ok.o; \
    ccache gcc -c ok.c -o ok.o; \
    ccache --show-stats | grep -qE "Hits:[[:space:]]*[1-9]" \
      || { ccache --show-stats; echo "ERROR: ccache reported no cache hit"; exit 1; }; \
    # What: Confirms ss shows a real listening loopback socket.
    # Why: Binding/listing a loopback socket needs no ptrace, so this runs
    #   as a real test at build time, unlike the gdb/strace/ltrace checks
    #   above.
    python3 -u -c "import socket,time; s=socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.bind(('127.0.0.1',0)); s.listen(1); print(s.getsockname()[1], flush=True); time.sleep(5)" > ss_port.log 2>&1 & \
    SS_PID=$!; \
    for _ in 1 2 3 4 5; do [ -s ss_port.log ] && break; sleep 0.5; done; \
    SS_PORT="$(head -1 ss_port.log)"; \
    ss -tln | grep -q ":${SS_PORT} " \
      || { echo "ERROR: ss did not show the real listening socket on port ${SS_PORT}"; ss -tln; kill "${SS_PID}" 2>/dev/null || true; exit 1; }; \
    kill "${SS_PID}" 2>/dev/null || true; \
    wait "${SS_PID}" 2>/dev/null || true; \
    # What: Confirms lsof shows a real open file descriptor on this shell.
    exec 9< /etc/hostname; \
    lsof -p "$$" | grep -q hostname \
      || { echo "ERROR: lsof did not show the open /etc/hostname file descriptor"; lsof -p "$$"; exit 1; }; \
    exec 9<&-; \
    # What: Confirms dig/nslookup actually resolve a real hostname.
    # Why: DNS resolution needs only network access, available at build
    #   time unlike ptrace, so this is a real test here rather than
    #   deferred.
    dig +short deb.debian.org | grep -qE '^[0-9]+\.' \
      || { echo "ERROR: dig did not resolve deb.debian.org to an IPv4 address"; dig deb.debian.org; exit 1; }; \
    nslookup deb.debian.org | grep -qi "Address" \
      || { echo "ERROR: nslookup did not resolve deb.debian.org"; nslookup deb.debian.org; exit 1; }; \
    # What: Confirms a real sshd/ssh client round-trip, mirroring
    #   SSHMode_Case's real session.
    # Why: Runs as root (before `USER verify` below) since
    #   privilege-dropping is SSHMode_Case's own runtime concern, not what
    #   this build-time check proves.
    # From: Issue #275, Issue #440
    ssh-keygen -q -t ed25519 -f ssh_host_key -N ''; \
    ssh-keygen -q -t ed25519 -f ssh_client_key -N ''; \
    cp ssh_client_key.pub ssh_authorized_keys; \
    printf '%s\n' \
      'Port 2222' \
      'ListenAddress 127.0.0.1' \
      'HostKey /tmp/verify-selftest/ssh_host_key' \
      'AuthorizedKeysFile /tmp/verify-selftest/ssh_authorized_keys' \
      'UsePAM no' \
      'StrictModes no' \
      'PasswordAuthentication no' \
      'PrintMotd no' \
      'Subsystem sftp none' \
      > sshd_selftest_config; \
    # What: Creates /run/sshd before starting sshd.
    # Why: Debian's sshd expects this directory already created by the
    #   package's own postinst/init-script, neither of which runs in a
    #   plain Dockerfile RUN.
    mkdir -p /run/sshd; \
    /usr/sbin/sshd -f /tmp/verify-selftest/sshd_selftest_config \
      -E /tmp/verify-selftest/sshd_selftest.log; \
    SSH_OK=0; \
    for _ in 1 2 3 4 5; do \
      if ssh -p 2222 -i ssh_client_key -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
           -o ConnectTimeout=2 -o LogLevel=ERROR \
           127.0.0.1 'echo ssh_selftest_marker' > ssh_selftest_out.log 2>&1; then \
        SSH_OK=1; break; \
      fi; \
      sleep 1; \
    done; \
    [ "${SSH_OK}" = "1" ] && grep -q "ssh_selftest_marker" ssh_selftest_out.log \
      || { echo "ERROR: ssh did not receive the expected remote command output"; \
           cat ssh_selftest_out.log; cat /tmp/verify-selftest/sshd_selftest.log; exit 1; }; \
    # What: Confirms jq actually parses and queries real JSON.
    echo '{"tool":"jq","ok":true}' | jq -e '.ok == true' >/dev/null \
      || { echo "ERROR: jq did not correctly query the test JSON document"; exit 1; }; \
    # What: Confirms shellcheck flags a real SC2086 (unquoted variable) bug.
    printf '%s\n' '#!/bin/sh' 'x="a b"' 'echo $x' > shellcheck_bug.sh; \
    shellcheck shellcheck_bug.sh > shellcheck.log 2>&1 && \
      { echo "ERROR: shellcheck did not flag the deliberately broken script"; cat shellcheck.log; exit 1; } \
      || grep -q "SC2086" shellcheck.log \
      || { echo "ERROR: shellcheck did not report the expected SC2086 finding"; cat shellcheck.log; exit 1; }; \
    # What: Confirms actionlint flags a real missing-`runs-on:` bug.
    mkdir -p actionlint_test/.github/workflows; \
    printf '%s\n' 'on: push' 'jobs:' '  test:' '    steps:' '      - run: echo hi' \
      > actionlint_test/.github/workflows/broken.yml; \
    ( cd actionlint_test && actionlint .github/workflows/broken.yml > ../actionlint.log 2>&1 ) && \
      { echo "ERROR: actionlint did not flag the deliberately broken workflow"; cat actionlint.log; exit 1; } \
      || grep -qi "runs-on" actionlint.log \
      || { echo "ERROR: actionlint did not report the expected missing runs-on finding"; cat actionlint.log; exit 1; }; \
    cd / && rm -rf /tmp/verify-selftest

# What: Runs as a fixed non-root `verify` user (uid/gid 1000).
# Why: A HOST_UID/HOST_GID build-arg (issue #286) was rejected since it
#   would need a local rebuild per caller uid; `docker run --user
#   $(id -u):$(id -g)` (doc/verification-checklist.md section 9) solves
#   the same problem against the unmodified published image.
# From: Issue #264, Issue #286
RUN useradd --create-home --shell /bin/bash verify
USER verify
WORKDIR /home/verify

CMD ["/bin/bash"]
