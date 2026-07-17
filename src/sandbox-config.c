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
 * Minimal `key = value` config file reader for the seccomp sandbox
 * (src/sandbox-seccomp.c), following the design finalized in issue #192
 * (follow-up on PR #171 / issue #68).
 *
 * Deliberately not built on popt's alias/config mechanism: that is a
 * macro/shortcut system requiring explicit invocation on the command line,
 * not a "silently apply defaults from a file at startup" mechanism, so it
 * isn't a clean fit here. This is instead a small, standalone parser with
 * no includes, no variable interpolation, and no nested structures --
 * kept deliberately minimal since the only consumer is a handful of
 * fixed, known keys, not a general-purpose config language.
 **/

#include <config.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/types.h>

#include "distcc.h"
#include "trace.h"
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
 * Strip leading/trailing ASCII whitespace from @p s in place and return it,
 * so callers can chain this directly onto a line/token buffer they already
 * own without a separate copy.
 **/
static char *dcc_seccomp_trim(char *s)
{
    char *end;

    while (*s && isspace((unsigned char) *s))
        s++;

    if (*s == '\0')
        return s;

    end = s + strlen(s) - 1;
    while (end > s && isspace((unsigned char) *end))
        *end-- = '\0';

    return s;
}

/**
 * Parse a config boolean: exactly "true"/"false", case-insensitive. Any
 * other spelling ("yes", "1", "on", ...) is deliberately rejected rather
 * than guessed at -- issue #192 specifies these two spellings only, and
 * silently accepting near-misses would make a typo in the config file look
 * like it was honored when it wasn't. On rejection, @p out is left
 * untouched (caller should pre-set it to the compiled-in default) and 0 is
 * returned so the caller can log what was rejected.
 **/
static int dcc_seccomp_parse_bool(const char *value, int *out)
{
    if (strcasecmp(value, "true") == 0) {
        *out = 1;
        return 1;
    }
    if (strcasecmp(value, "false") == 0) {
        *out = 0;
        return 1;
    }
    return 0;
}

/**
 * Split a comma-separated list of syscall names into a freshly allocated
 * NULL-terminated array of freshly allocated strings, trimming whitespace
 * around each name and dropping empty tokens (so "a, ,b" and "a,b" behave
 * identically). Returns an empty-list array (see dcc_seccomp_empty_list())
 * for a blank/whitespace-only value, never NULL, so callers can always
 * iterate without a null-check.
 **/
static char **dcc_seccomp_parse_list(const char *value)
{
    char *copy, *saveptr, *tok;
    char **list;
    size_t count, cap;

    copy = strdup(value);
    if (copy == NULL)
        return dcc_seccomp_empty_list();

    cap = 4;
    count = 0;
    list = (char **) malloc(cap * sizeof(char *));
    if (list == NULL) {
        free(copy);
        return dcc_seccomp_empty_list();
    }

    for (tok = strtok_r(copy, ",", &saveptr); tok != NULL;
         tok = strtok_r(NULL, ",", &saveptr)) {
        char *trimmed = dcc_seccomp_trim(tok);
        if (*trimmed == '\0')
            continue;

        if (count + 1 >= cap) {
            cap *= 2;
            list = (char **) realloc(list, cap * sizeof(char *));
            if (list == NULL) {
                free(copy);
                return dcc_seccomp_empty_list();
            }
        }
        list[count++] = strdup(trimmed);
    }
    list[count] = NULL;

    free(copy);
    return list;
}

/**
 * Check whether @p path is a real, world-writable regular file and warn if
 * so (defense-in-depth: an unprivileged local user could otherwise flip
 * `enabled = false` or `fail-open = true` under a privileged distccd,
 * silently disabling the hardening this file configures). Mirrors this
 * codebase's existing world-writable-file finding class (issue #157 /
 * PR #158) rather than inventing a new permissions convention. Never
 * refuses to read the file over this -- only warns.
 **/
static void dcc_seccomp_warn_if_world_writable(const char *path, FILE *fp)
{
    struct stat st;

    if (fstat(fileno(fp), &st) != 0) {
        rs_log_warning("seccomp config %s: fstat() failed: %s; continuing "
                        "anyway", path, strerror(errno));
        return;
    }

    if (st.st_mode & S_IWOTH) {
        rs_log_warning("seccomp config %s is world-writable (mode %#o); any "
                        "local user could change the seccomp sandbox's "
                        "effective behavior -- consider tightening its "
                        "permissions", path, (unsigned) (st.st_mode & 07777));
    }
}

/**
 * Apply one already-split `key = value` pair to @p cfg. Unknown keys are
 * warned about and ignored rather than treated as a hard parse error --
 * this file is meant to degrade gracefully, not make an unrelated typo on
 * one line take down every key below it.
 **/
static void dcc_seccomp_apply_kv(struct dcc_seccomp_config *cfg,
                                  const char *key, const char *value)
{
    int parsed;

    if (strcmp(key, "enabled") == 0) {
        if (!dcc_seccomp_parse_bool(value, &parsed))
            rs_log_warning("seccomp config: invalid boolean '%s' for "
                            "'enabled' (expected true/false); keeping "
                            "default (%s)", value,
                            cfg->enabled ? "true" : "false");
        else
            cfg->enabled = parsed;
    } else if (strcmp(key, "deny-network") == 0) {
        if (!dcc_seccomp_parse_bool(value, &parsed))
            rs_log_warning("seccomp config: invalid boolean '%s' for "
                            "'deny-network' (expected true/false); keeping "
                            "default (%s)", value,
                            cfg->deny_network ? "true" : "false");
        else
            cfg->deny_network = parsed;
    } else if (strcmp(key, "fail-open") == 0) {
        if (!dcc_seccomp_parse_bool(value, &parsed))
            rs_log_warning("seccomp config: invalid boolean '%s' for "
                            "'fail-open' (expected true/false); keeping "
                            "default (%s)", value,
                            cfg->fail_open ? "true" : "false");
        else
            cfg->fail_open = parsed;
    } else if (strcmp(key, "extra-deny") == 0) {
        char **parsed_list = dcc_seccomp_parse_list(value);
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
        char **parsed_list = dcc_seccomp_parse_list(value);
        char **old = cfg->allow_override;
        cfg->allow_override = parsed_list;
        if (old != NULL) {
            size_t i;
            for (i = 0; old[i] != NULL; i++)
                free(old[i]);
            free(old);
        }
    } else {
        rs_log_warning("seccomp config: unknown key '%s'; ignoring", key);
    }
}

/**
 * Parse one line already known to contain a real `key = value` pair (blank
 * lines and `#` comments are filtered out by the caller before this is
 * reached). A line with no `=` is warned about and skipped rather than
 * guessed at.
 **/
static void dcc_seccomp_parse_line(struct dcc_seccomp_config *cfg, char *line)
{
    char *eq = strchr(line, '=');
    char *key, *value;

    if (eq == NULL) {
        rs_log_warning("seccomp config: ignoring malformed line (no '='): "
                        "'%s'", line);
        return;
    }

    *eq = '\0';
    key = dcc_seccomp_trim(line);
    value = dcc_seccomp_trim(eq + 1);

    if (*key == '\0') {
        rs_log_warning("seccomp config: ignoring line with empty key: "
                        "'= %s'", value);
        return;
    }

    dcc_seccomp_apply_kv(cfg, key, value);
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
    FILE *fp;
    char line[1024];

    if (path == NULL)
        path = DCC_SECCOMP_CONFIG_DEFAULT_PATH;

    dcc_seccomp_config_defaults(&dcc_seccomp_cfg);
    dcc_seccomp_cfg_loaded = 1;

    fp = fopen(path, "r");
    if (fp == NULL) {
        if (errno != ENOENT)
            rs_log_warning("seccomp config %s: could not open (%s); using "
                            "built-in defaults", path, strerror(errno));
        /* ENOENT: the file is genuinely optional -- not an error, not even
         * worth a log line, so a default install without this file doesn't
         * spam the log every startup. */
        return;
    }

    dcc_seccomp_warn_if_world_writable(path, fp);

    while (fgets(line, sizeof(line), fp) != NULL) {
        char *trimmed = dcc_seccomp_trim(line);
        if (*trimmed == '\0' || *trimmed == '#')
            continue;
        dcc_seccomp_parse_line(&dcc_seccomp_cfg, trimmed);
    }

    fclose(fp);
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
