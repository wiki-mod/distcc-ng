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

/* sandbox-config.c */

#ifndef _DISTCC_SANDBOX_CONFIG_H
#define _DISTCC_SANDBOX_CONFIG_H

/* Default location of the seccomp sandbox's runtime config file. See
 * doc/seccomp-sandbox.md for the full format and the finalized design
 * (issue #192). */
#define DCC_SECCOMP_CONFIG_DEFAULT_PATH "/etc/distcc/seccomp.conf"

/**
 * Effective seccomp sandbox configuration: compiled-in defaults, overridden
 * by whatever /etc/distcc/seccomp.conf actually sets. Populated once by
 * dcc_seccomp_config_load() and read-only from then on -- this is a
 * per-daemon-lifetime setting, not something re-read per compile.
 **/
struct dcc_seccomp_config {
    int enabled;           /* master on/off switch; default 1 (true) */
    int deny_network;      /* default 0 (false): network unrestricted */
    int fail_open;         /* default 1 (true): proceed unsandboxed on failure */

    /* NULL-terminated arrays of syscall names, owned by this struct.
     * Never NULL themselves (an empty list is a single-element array
     * holding just the NULL terminator) so callers can always iterate
     * without a separate "is this list present" check. */
    char **extra_deny;
    char **allow_override;
};

/**
 * Load the seccomp sandbox config file at @p path (pass NULL for the
 * default, DCC_SECCOMP_CONFIG_DEFAULT_PATH) and populate the process-wide
 * effective configuration returned by dcc_seccomp_config_get().
 *
 * Never fails the caller: a missing, empty, or comment-only file is not an
 * error -- every key simply keeps its compiled-in default. A file that
 * exists but can't be opened for another reason (permission denied, not a
 * regular file, ...) logs a warning and also falls back to the defaults,
 * since refusing to start the daemon over an unreadable *optional* config
 * file would be a worse outcome than running with defaults. A world-
 * writable file logs a warning (defense-in-depth, matching this codebase's
 * existing world-writable-file CodeQL finding class) but is still read and
 * used -- distccd doesn't refuse to start over file permissions it doesn't
 * own.
 *
 * Must be called exactly once, early in distccd's startup (see
 * src/daemon.c's main()), before the first remote compile can be spawned --
 * dcc_seccomp_config_get() is undefined before this runs.
 **/
void dcc_seccomp_config_load(const char *path);

/**
 * Return the effective configuration populated by the most recent
 * dcc_seccomp_config_load() call. Read-only: callers must not modify the
 * returned struct or the arrays it points to.
 **/
const struct dcc_seccomp_config *dcc_seccomp_config_get(void);

#endif /* _DISTCC_SANDBOX_CONFIG_H */
