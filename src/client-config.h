/* -*- c-file-style: "java"; indent-tabs-mode: nil; tab-width: 4; fill-column: 78 -*-
 *
 * distcc -- A simple distributed compiler system
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

/* client-config.c */

#ifndef _DISTCC_CLIENT_CONFIG_H
#define _DISTCC_CLIENT_CONFIG_H

/* Default location of distcc's (the client's) runtime config file. A
 * sibling of distccd.conf (src/sandbox-config.h) -- same directory, same
 * `key = value` parser (src/config-parser.c), but a distinct file, since
 * client and daemon settings are read by different processes with
 * different lifetimes. See doc/distcc-conf.md for the full format. */
#define DCC_CLIENT_CONFIG_DEFAULT_PATH "/etc/distcc/distcc.conf"

/**
 * Effective client configuration: compiled-in defaults, overridden by
 * whatever /etc/distcc/distcc.conf actually sets. Populated once by
 * dcc_client_config_load() and read-only from then on -- this is a
 * per-client-invocation setting, read once at startup like every other
 * client-side config source, not re-read per compile (a single `distcc`
 * invocation only ever does one compile anyway).
 *
 * Every setting here can also be overridden per-invocation by an
 * environment variable, taking precedence over both the compiled-in
 * default and the config file -- the same precedence order used
 * throughout this codebase's existing DISTCC_* environment variables
 * (compiled-in default < config file < environment variable). Call sites
 * are expected to do that override themselves via dcc_getenv_bool()
 * (src/util.c), passing this struct's value as that function's own
 * default -- e.g. `dcc_getenv_bool("DISTCC_LOCAL_LTO",
 * dcc_client_config_get()->local_lto)` -- rather than this module
 * duplicating environment-variable handling that already exists.
 **/
struct dcc_client_config {
    /* default 0 (false): distribute -flto/-flto=<value> invocations
     * normally, matching upstream distcc/distcc's current behavior (see
     * support-upstream/issue-074-lto-distribution-revert.md -- upstream
     * tried forcing these local too, then reverted it with real evidence
     * that distributing LTO compiles reduces build time in practice, not
     * wastes it). Set true to force local-only compilation for these
     * instead, if that suits a particular build's actual (measured, not
     * assumed) LTO cost profile. */
    int local_lto;
};

/**
 * Load the client config file at @p path (pass NULL for the default,
 * DCC_CLIENT_CONFIG_DEFAULT_PATH) and populate the process-wide effective
 * configuration returned by dcc_client_config_get().
 *
 * Never fails the caller: a missing, empty, or comment-only file is not an
 * error -- every key simply keeps its compiled-in default. See
 * src/config-parser.c's dcc_config_load() for the full missing-file/
 * unreadable-file/world-writable-file handling shared with distccd.conf.
 *
 * Must be called exactly once, early in the client's startup (see
 * src/distcc.c's main() or equivalent), before dcc_scan_args() can
 * possibly run -- dcc_client_config_get() is undefined before this runs.
 **/
void dcc_client_config_load(const char *path);

/**
 * Return the effective configuration populated by the most recent
 * dcc_client_config_load() call. Read-only: callers must not modify the
 * returned struct.
 **/
const struct dcc_client_config *dcc_client_config_get(void);

#endif /* _DISTCC_CLIENT_CONFIG_H */
