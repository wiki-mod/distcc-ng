/* -*- c-file-style: "java"; indent-tabs-mode: nil; tab-width: 4; fill-column: 78 -*-
 *
 * distcc -- A simple distributed compiler system
 *
 * Copyright (C) 2026 by the distcc-ng maintainers
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,
 * USA.
 */

/*
 * What: Split-DWARF-in-pump-mode module -- the DCC_VER_6000 (LZO) and
 * DCC_VER_6001 (Zstd) protocols that return a server-produced external ".dwo"
 * to the client via a DDWO slot between DOTO and DOTD.
 * Why: the whole feature lives here so core files only call in; all active
 * code is under HAVE_SPLIT_DWARF_PUMP and degrades to stubs when the feature
 * is configured out (--disable-split-dwarf-pump), so the client never selects
 * 600x and the server rejects it as an unknown protocol.
 * From: Issue #398
 */

#include <config.h>

#include <stdlib.h>
#include <string.h>

#include "distcc.h"
#include "trace.h"
#include "rpc.h"
#include "bulk.h"
#include "util.h"
#include "hosts.h"
#include "exitcode.h"
#include "split_dwarf.h"

/* See split_dwarf.h for the contract of each function. */

int dcc_argv_wants_split_dwarf(char **argv)
{
#ifdef HAVE_SPLIT_DWARF_PUMP
    /* What: last matching flag wins, matching real GCC/Clang precedence.
     * Why: "-gsplit-dwarf -gno-split-dwarf" emits no .dwo and the reverse
     *      does, verified against GCC 14 / Clang 19 before encoding this.
     * From: Issue #398 */
    int wants = 0;
    int i;

    for (i = 0; argv[i] != NULL; i++) {
        if (strcmp(argv[i], "-gsplit-dwarf") == 0 ||
            strcmp(argv[i], "-gsplit-dwarf=split") == 0)
            wants = 1;
        else if (strcmp(argv[i], "-gsplit-dwarf=single") == 0 ||
                 strcmp(argv[i], "-gno-split-dwarf") == 0)
            wants = 0;
    }
    return wants;
#else
    (void) argv;
    return 0;
#endif
}

int dcc_protover_is_split_dwarf_pump(enum dcc_protover protover)
{
#ifdef HAVE_SPLIT_DWARF_PUMP
    return protover == DCC_VER_6000 || protover == DCC_VER_6001;
#else
    (void) protover;
    return 0;
#endif
}

enum dcc_protover dcc_split_dwarf_upgrade_protover(enum dcc_protover base)
{
#ifdef HAVE_SPLIT_DWARF_PUMP
    if (base == DCC_VER_3)
        return DCC_VER_6000;
    if (base == DCC_VER_5000)
        return DCC_VER_6001;
#endif
    return base;
}

int dcc_retrieve_dwo(int net_fd, const char *output_fname,
                     struct dcc_hostdef *host)
{
#ifdef HAVE_SPLIT_DWARF_PUMP
    unsigned len, uncompr_len = 0;
    int ret;
    char *dwo_fname;

    /* What: the length format follows the negotiated compression, like every
     *       other token (2-int for Zstd/6001, 1-int for LZO/6000).
     * Why: keying off host->compr, not the protocol number, keeps this
     *      consistent with dcc_retrieve_results()' other token reads.
     * From: Issue #398 */
    if (host->compr == DCC_COMPRESS_ZSTD) {
        if ((ret = dcc_r_token_2int(net_fd, "DDWO", &len, &uncompr_len)))
            return ret;
    } else if ((ret = dcc_r_token_int(net_fd, "DDWO", &len))) {
        return ret;
    }

    /* What: an empty DDWO is skipped, not treated as end-of-results.
     * Why: unlike DCC_VER_4000 (nothing follows DDWO), 600x still sends DOTD
     *      after it, so returning early here would desync the wire.
     * From: Issue #398 */
    if (len == 0)
        return 0;

    dwo_fname = dcc_make_dwo_fname(output_fname);
    if (!dwo_fname)
        return EXIT_OUT_OF_MEMORY;

    ret = dcc_r_file_timed(net_fd, dwo_fname, len, uncompr_len, host->compr);
    free(dwo_fname);
    return ret;
#else
    (void) net_fd;
    (void) output_fname;
    (void) host;
    return 0;
#endif
}
