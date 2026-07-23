#!/bin/bash -eu
#
# ClusterFuzzLite build script for distcc-ng (refs #267). Runs inside the
# .clusterfuzzlite/Dockerfile environment, with $CC/$CXX/$CFLAGS/$CXXFLAGS/
# $LIB_FUZZING_ENGINE/$OUT already set by that environment (OSS-Fuzz/
# ClusterFuzzLite convention, not defined by this script).

./autogen.sh
# --disable-pump-mode: the fuzz target only exercises src/rpc.c's wire-
# protocol parsing, not the Python include-server -- skips a real Python
# C-extension build this target doesn't need, reducing build surface.
# PYTHON=python3 matches this repo's own documented convention (CLAUDE.md).
# --with-auth: this build compiles every non-main src/*.c file together
# (see below), which includes src/auth_common.c -- but that file is only
# ever compiled by the real Makefile.in when --with-auth was given
# (configure.ac's AUTH_COMMON_OBJS assignment), and it uses
# EXIT_GSSAPI_FAILED unconditionally, which is only defined when
# HAVE_GSSAPI is set (also only set by --with-auth's own AC_SEARCH_LIBS
# check succeeding). Confirmed live: without --with-auth, this fails with
# "use of undeclared identifier 'EXIT_GSSAPI_FAILED'". libkrb5-dev
# (already installed above for gssapi.h) also provides libgssapi_krb5,
# which configure.ac's AC_SEARCH_LIBS([gss_init_sec_context], [gssapi
# gssapi_krb5 gss], ...) successfully finds.
./configure PYTHON=python3 --disable-pump-mode --with-auth

# Compile every source file distcc-ng's real binaries share (see
# Makefile.in's SRC list), except the ones that define their own main() --
# only one main is allowed in the final fuzz binary, provided by
# $LIB_FUZZING_ENGINE. Compiled directly with $CC/$CFLAGS (which already
# carry the sanitizer/instrumentation flags this environment injects),
# not through `make`, so those flags aren't overridden by Makefile.in's
# own CFLAGS assignment.
main_having_files="daemon distcc fix_debug_info h_argvtostr h_compile h_dopt h_dotd h_exten h_getline h_hosts h_includesort h_issource h_parsemask h_pathsafety h_sa2str h_scanargs h_srvrpc h_ssh h_state h_stats h_strip lsdistcc mon-gnome mon-text stringmap"

objs=()
for f in src/*.c; do
    base="$(basename "$f" .c)"
    skip=0
    for ex in $main_having_files; do
        if [ "$base" = "$ex" ]; then
            skip=1
            break
        fi
    done
    [ "$skip" -eq 1 ] && continue
    obj="$OUT/${base}.o"
    $CC $CFLAGS -Isrc -Ilzo -DHAVE_CONFIG_H -c "$f" -o "$obj"
    objs+=("$obj")
done

# lzo/minilzo.c: the bundled LZO compressor (always built, per Makefile.in's
# own dist_lzo/distcc_obj lists) -- src/compress-lzox1.c #includes
# "minilzo.h" from this directory, and the symbols it defines are needed
# at final link time too. Confirmed live: without -Ilzo, compress-lzox1.c
# fails with "fatal error: 'minilzo.h' file not found".
$CC $CFLAGS -Isrc -Ilzo -DHAVE_CONFIG_H -c lzo/minilzo.c -o "$OUT/minilzo.o"
objs+=("$OUT/minilzo.o")

# Same libraries the real distccd/distcc binaries link against (Makefile.in's
# LIBS = @LIBS@ @POPT_LIBS@, resolved by the ./configure just run) -- read
# from the generated Makefile rather than hand-guessed, so this stays
# correct if configure's library detection ever changes.
resolved_libs="$(sed -n 's/^LIBS = //p' Makefile)"

# ClusterFuzzLite requires linking fuzz target binaries with $CXX even for
# a pure-C project (its own documented convention) -- $CXX still compiles
# a .c file as C based on its extension.
$CXX $CXXFLAGS -Isrc -Ilzo -DHAVE_CONFIG_H \
    test/fuzz/fuzz_rpc_argv.c "${objs[@]}" \
    -o "$OUT/fuzz_rpc_argv" \
    $LIB_FUZZING_ENGINE $resolved_libs
