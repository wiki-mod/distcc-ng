# Building distcc with different compilers

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

## Runtime configuration

The runtime images start `distccd` through a small entrypoint script. The
default allow list is `127.0.0.1`.

Set `DISTCCD_ALLOW` to permit a LAN subnet or a single host:

```sh
docker run --rm ghcr.io/wiki-mod/distcc-ng-nopump:3.4.1
docker run --rm --network host \
  -e DISTCCD_ALLOW=192.168.1.0/24 \
  ghcr.io/wiki-mod/distcc-ng-zstd-with-pump:3.4.1
docker run --rm --network host \
  -e DISTCCD_ALLOW=192.168.1.100 \
  ghcr.io/wiki-mod/distcc-ng-with-pump:3.4.1
```

The `with-pump` images provide both `pump` and `distcc-pump`. All runtime
images include `include_server`, `ps`, `bash`, and `file`.
