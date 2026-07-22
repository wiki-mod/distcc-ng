# docker/

This directory has three independent purposes -- don't confuse them:

- **`docker/release/`**: this fork's own published runtime images,
  `ghcr.io/wiki-mod/distcc-ng` (plain) and `ghcr.io/wiki-mod/distcc-ng-pump`
  (with pump mode built in, issue #181), built and pushed by
  `.github/workflows/package-release.yml` on every tagged release. See
  `docker/release/Dockerfile`.
- **`docker/verify/`**: `ghcr.io/wiki-mod/distcc-ng-buildtools`, a
  pre-built, fully self-contained build+debug+verification image for
  contributors/agents doing real verification work on this repo (gdb,
  strace, ltrace, valgrind, ASan/UBSan, binutils, ripgrep, etc.) -- not a
  runtime image, issue #264. See `docker/verify/README.md`.
- **`docker/base/`/`docker/compilers/`**: the original upstream
  compiler-compatibility test harness described below (builds distcc
  against old gcc-4.8/gcc-5/clang-3.8 toolchains) -- unrelated to either
  of the above, kept as-is.

## Building distcc with different compilers

## Requirements:

Docker 1.9.1

## Build
The following command will create three images based on Ubuntu 16.04 using gcc 4.8, 5.4 and clang 3.8 and
build distcc inside the container.

```
$ cd docker
$ ./build.sh
```

In order to build only one variant use the following command:

```
$ cd docker
$ ./build.sh clang-3.8|gcc-4.8|gcc-5
```
