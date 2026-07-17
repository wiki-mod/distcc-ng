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

/**
 * @file
 *
 * distccd's runtime config file (/etc/distcc/distccd.conf). Originally
 * seccomp.conf, seccomp-only (issue #192, follow-up on PR #171/issue #68);
 * renamed to the general daemon-config name once a second, non-seccomp
 * daemon setting was on the horizon (issue #207) -- no back-compat shim
 * needed, since no real deployment of the old name predates this rename.
 * Line-parsing itself now lives in src/config-parser.c, shared with the
 * client's distcc.conf (src/client-config.c); this file owns only the
 * seccomp-specific struct, its keys, and its defaults.
 **/

#include <config.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "distcc.h"
#include "trace.h"
#include "config-parser.h"
#include "sandbox-config.h"

/* Process-wide effective configuration, populated once by
 * dcc_seccomp_config_load() and read thereafter via dcc_seccomp_config_get().
 * Static storage duration: the string arrays it owns must outlive every
 * caller, which is true for the daemon's whole lifetime. */
static struct dcc_seccomp_config dcc_seccomp_cfg;
static int dcc_seccomp_cfg_loaded = 0;

/**
 * A NULL-terminated array holding just the terminator -- the "empty list"
 * representation shared by extra_deny/allow_override so callers never have
 * to special-case "no list was set" versus "list was set to empty".
 **/
static char **dcc_seccomp_empty_list(void)
{
    char **list = (char **) malloc(sizeof(char *));
    if (list != NULL)
        list[0] = NULL;
    return list;
}

/**
 * Apply one already-split `key = value` pair to @p cfg_ptr (a
 * struct dcc_seccomp_config *, passed as void * to match
 * dcc_config_apply_kv_fn). Unknown keys are warned about and ignored
 * rather than treated as a hard parse error -- this file is meant to
 * degrade gracefully, not make an unrelated typo on one line take down
 * every key below it.
 **/
static void dcc_seccomp_apply_kv(void *cfg_ptr, const char *key,
                                   const char *value)
{
    struct dcc_seccomp_config *cfg = (struct dcc_seccomp_config *) cfg_ptr;
    int parsed;

    if (strcmp(key, "enabled") == 0) {
        if (!dcc_config_parse_bool(value, &parsed))
            rs_log_warning("distccd config: invalid boolean '%s' for "
                            "'enabled' (expected true/false); keeping "
                            "default (%s)", value,
                            cfg->enabled ? "true" : "false");
        else
            cfg->enabled = parsed;
    } else if (strcmp(key, "deny-network") == 0) {
        if (!dcc_config_parse_bool(value, &parsed))
            rs_log_warning("distccd config: invalid boolean '%s' for "
                            "'deny-network' (expected true/false); keeping "
                            "default (%s)", value,
                            cfg->deny_network ? "true" : "false");
        else
            cfg->deny_network = parsed;
    } else if (strcmp(key, "fail-open") == 0) {
        if (!dcc_config_parse_bool(value, &parsed))
            rs_log_warning("distccd config: invalid boolean '%s' for "
                            "'fail-open' (expected true/false); keeping "
                            "default (%s)", value,
                            cfg->fail_open ? "true" : "false");
        else
            cfg->fail_open = parsed;
    } else if (strcmp(key, "require-seccomp") == 0) {
        if (!dcc_config_parse_bool(value, &parsed))
            rs_log_warning("distccd config: invalid boolean '%s' for "
                            "'require-seccomp' (expected true/false); "
                            "keeping default (%s)", value,
                            cfg->require_seccomp ? "true" : "false");
        else
            cfg->require_seccomp = parsed;
    } else if (strcmp(key, "extra-deny") == 0) {
        char **parsed_list = dcc_config_parse_list(value);
        char **old = cfg->extra_deny;
        cfg->extra_deny = parsed_list;
        if (old != NULL) {
            /* A key repeated later in the file overrides the earlier one,
             * same convention as most `key = value` config formats. */
            size_t i;
            for (i = 0; old[i] != NULL; i++)
                free(old[i]);
            free(old);
        }
    } else if (strcmp(key, "allow-override") == 0) {
        char **parsed_list = dcc_config_parse_list(value);
        char **old = cfg->allow_override;
        cfg->allow_override = parsed_list;
        if (old != NULL) {
            size_t i;
            for (i = 0; old[i] != NULL; i++)
                free(old[i]);
            free(old);
        }
    } else {
        rs_log_warning("distccd config: unknown key '%s'; ignoring", key);
    }
}

/**
 * Reset @p cfg to the compiled-in defaults documented in issue #192 and
 * mirrored verbatim in doc/seccomp-sandbox.md's example file. Called
 * before parsing so every key that the file doesn't mention (including
 * "the file doesn't exist at all") ends up at its documented default,
 * without the parser needing a separate "was this key seen" bitmap.
 **/
static void dcc_seccomp_config_defaults(struct dcc_seccomp_config *cfg)
{
    cfg->enabled = 1;
    cfg->deny_network = 0;
    cfg->fail_open = 1;
    cfg->require_seccomp = 0;
    cfg->extra_deny = dcc_seccomp_empty_list();
    cfg->allow_override = dcc_seccomp_empty_list();
}

/**
 * See sandbox-config.h. Reads @p path (or the default location when NULL),
 * applying whatever it finds on top of the compiled-in defaults; never
 * fails, since every key has a safe default and this config file is
 * always optional.
 **/
void dcc_seccomp_config_load(const char *path)
{
    if (path == NULL)
        path = DCC_DAEMON_CONFIG_DEFAULT_PATH;

    dcc_seccomp_config_defaults(&dcc_seccomp_cfg);
    dcc_seccomp_cfg_loaded = 1;

    dcc_config_load(path, "distccd config", dcc_seccomp_apply_kv,
                     &dcc_seccomp_cfg);
}

/**
 * See sandbox-config.h. Returns the struct populated by the most recent
 * dcc_seccomp_config_load() call.
 **/
const struct dcc_seccomp_config *dcc_seccomp_config_get(void)
{
    if (!dcc_seccomp_cfg_loaded) {
        /* Defensive fallback for a caller that reads the config before
         * daemon.c's main() has loaded it (e.g. a future standalone test
         * harness) -- still returns safe compiled-in defaults rather than
         * uninitialized memory. */
        dcc_seccomp_config_defaults(&dcc_seccomp_cfg);
        dcc_seccomp_cfg_loaded = 1;
    }
    return &dcc_seccomp_cfg;
}
