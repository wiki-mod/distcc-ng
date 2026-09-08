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
 * What: Public API of the split-DWARF-in-pump-mode module (protocols
 * DCC_VER_6000/6001), which carry a server-produced external ".dwo" back to
 * the client via a DDWO wire slot between DOTO and DOTD.
 * Why: keeps the split-DWARF substance (arg detection, per-job protocol
 * upgrade, DDWO retrieval) in one place; core files only call in, guarded by
 * HAVE_SPLIT_DWARF_PUMP -- when the feature is disabled these become stubs so
 * the client never selects 600x and the server rejects it as unknown.
 * From: Issue #398
 */

#ifndef _DISTCC_SPLIT_DWARF_H
#define _DISTCC_SPLIT_DWARF_H

/* Per this tree's convention, headers do not include "distcc.h" (which has no
 * include guard); a .c file includes "distcc.h" (for enum dcc_protover) and
 * "hosts.h" (for struct dcc_hostdef) before this header, as rpc.h relies on
 * too. */

/*
 * What: True if @p argv requests an *external* split-DWARF (".dwo") file.
 * Why: only such a job needs the 600x DDWO transport; empirically (GCC 14,
 * Clang 19) "-gsplit-dwarf" and "-gsplit-dwarf=split" enable it while
 * "-gsplit-dwarf=single" and "-gno-split-dwarf" disable it, last flag wins.
 * From: Issue #398
 */
int dcc_argv_wants_split_dwarf(char **argv);

/*
 * What: True if @p protover is a split-DWARF pump protocol (6000 or 6001),
 * i.e. one whose result header carries a DDWO slot between DOTO and DOTD.
 * From: Issue #398
 */
int dcc_protover_is_split_dwarf_pump(enum dcc_protover protover);

/*
 * What: Upgrades a server-side-cpp base protocol to its split-DWARF variant:
 * DCC_VER_3 -> DCC_VER_6000, DCC_VER_5000 -> DCC_VER_6001; any other value
 * (including an already-upgraded 600x) is returned unchanged.
 * Why: called only for a job that stays server-side cpp and wants an external
 * .dwo, so the base is always 3 or 5000 at that point.
 * From: Issue #398
 */
enum dcc_protover dcc_split_dwarf_upgrade_protover(enum dcc_protover base);

/*
 * What: Reads the DDWO token that 600x sends between DOTO and DOTD, storing a
 * non-empty payload as the ".dwo" beside @p output_fname; an empty DDWO is
 * skipped (the compiler emitted no .dwo) so DOTD still follows.
 * Why: unlike DCC_VER_4000's DDWO (client-side cpp, nothing follows), a
 * zero-length DDWO here must NOT end result retrieval -- the dependency file
 * (DOTD) is still on the wire. Length format follows @p host's compression
 * (1-int for LZO/6000, 2-int for Zstd/6001), like every other token.
 * From: Issue #398
 */
int dcc_retrieve_dwo(int net_fd, const char *output_fname,
                     struct dcc_hostdef *host);

#endif /* _DISTCC_SPLIT_DWARF_H */
