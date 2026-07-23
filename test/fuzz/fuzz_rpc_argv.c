/* Fuzz target for dcc_r_argv() (src/rpc.c), part of the OSSF Fuzzing
 * integration (ClusterFuzzLite -- see .clusterfuzzlite/, refs #267).
 *
 * dcc_r_argv() reads a full argument list off a peer-controlled file
 * descriptor -- this is the exact kind of untrusted-network-input parsing
 * Scorecard's FuzzingID/OSS-Fuzz's own scope targets, and the same class
 * of surface (wire-protocol-derived lengths/counts) that previously
 * produced real findings in this codebase (the compile.c TOCTOU/heap
 * overflow fixes, and the rpc.c/compress-*.c allocation-size capping for
 * wire-protocol-derived sizes).
 *
 * libFuzzer only hands this a raw byte buffer, but dcc_r_argv() reads
 * from a real file descriptor (as it would from a live network socket) --
 * a temp file, written once with the fuzz input then rewound, gives it
 * exactly that fd-based interface without needing a real socket pair or
 * risking a blocking pipe-buffer write for inputs larger than the pipe's
 * default buffer size.
 */

#include <config.h>

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "rpc.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    char path[] = "/tmp/dcc_fuzz_argv_XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0)
        return 0;

    /* Unlink immediately -- the fd stays valid and the backing file is
     * removed from the filesystem namespace as soon as we close it, no
     * leftover temp files to accumulate across fuzzer iterations. */
    unlink(path);

    if (size > 0) {
        ssize_t written = write(fd, data, size);
        (void) written; /* short/failed write just means less input to parse, not a harness bug */
    }

    if (lseek(fd, 0, SEEK_SET) != 0) {
        close(fd);
        return 0;
    }

    char **argv = NULL;
    /* Token names match what dcc_r_argv()'s real callers use on the wire
     * (verified via grep, not guessed): src/serve.c:805 (the server's job
     * submission path) and src/include_server_if.c:103 both call this
     * with the literal "ARGC"/"ARGV" token pair. */
    (void) dcc_r_argv(fd, "ARGC", "ARGV", &argv);

    if (argv != NULL) {
        for (unsigned i = 0; argv[i] != NULL; i++)
            free(argv[i]);
        free(argv);
    }

    close(fd);
    return 0;
}
