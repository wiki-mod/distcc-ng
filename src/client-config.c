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
 * distcc's (the client's) runtime config file (/etc/distcc/distcc.conf,
 * issue #207). A sibling of the daemon's distccd.conf
 * (src/sandbox-config.c), sharing the same `key = value` parser
 * (src/config-parser.c), but read by the client process instead.
 **/

#include <config.h>

#include <string.h>

#include "distcc.h"
#include "trace.h"
#include "config-parser.h"
#include "client-config.h"

/* Process-wide effective configuration, populated once by
 * dcc_client_config_load() and read thereafter via dcc_client_config_get().
 */
static struct dcc_client_config dcc_client_cfg;
static int dcc_client_cfg_loaded = 0;

/**
 * Apply one already-split `key = value` pair to @p cfg_ptr (a
 * struct dcc_client_config *, passed as void * to match
 * dcc_config_apply_kv_fn). Unknown keys are warned about and ignored
 * rather than treated as a hard parse error, same convention as
 * distccd.conf's parser.
 **/
static void dcc_client_apply_kv(void *cfg_ptr, const char *key,
                                  const char *value)
{
    struct dcc_client_config *cfg = (struct dcc_client_config *) cfg_ptr;
    int parsed;

    if (strcmp(key, "local-lto") == 0) {
        if (!dcc_config_parse_bool(value, &parsed))
            rs_log_warning("distcc config: invalid boolean '%s' for "
                            "'local-lto' (expected true/false); keeping "
                            "default (%s)", value,
                            cfg->local_lto ? "true" : "false");
        else
            cfg->local_lto = parsed;
    } else {
        rs_log_warning("distcc config: unknown key '%s'; ignoring", key);
    }
}

/**
 * Reset @p cfg to its compiled-in defaults. Called before parsing so every
 * key the file doesn't mention (including "the file doesn't exist at all")
 * ends up at its documented default.
 **/
static void dcc_client_config_defaults(struct dcc_client_config *cfg)
{
    cfg->local_lto = 0;
}

/**
 * See client-config.h. Reads @p path (or the default location when NULL),
 * applying whatever it finds on top of the compiled-in defaults; never
 * fails, since every key has a safe default and this config file is
 * always optional.
 **/
void dcc_client_config_load(const char *path)
{
    if (path == NULL)
        path = DCC_CLIENT_CONFIG_DEFAULT_PATH;

    dcc_client_config_defaults(&dcc_client_cfg);
    dcc_client_cfg_loaded = 1;

    dcc_config_load(path, "distcc config", dcc_client_apply_kv,
                     &dcc_client_cfg);
}

/**
 * See client-config.h. Returns the struct populated by the most recent
 * dcc_client_config_load() call.
 **/
const struct dcc_client_config *dcc_client_config_get(void)
{
    if (!dcc_client_cfg_loaded) {
        /* Defensive fallback for a caller that reads the config before
         * main() has loaded it (e.g. a future standalone test harness) --
         * still returns safe compiled-in defaults rather than
         * uninitialized memory. */
        dcc_client_config_defaults(&dcc_client_cfg);
        dcc_client_cfg_loaded = 1;
    }
    return &dcc_client_cfg;
}
