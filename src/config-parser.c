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
 * Minimal `key = value` config file reader, shared by the daemon's
 * `/etc/distcc/distccd.conf` (src/sandbox-config.c, originally the
 * seccomp-only `seccomp.conf` from issue #192/PR #171) and the client's
 * `/etc/distcc/distcc.conf` (src/client-config.c, issue #207). Factored out
 * once a second config file needed the exact same line-splitting/trimming/
 * bool-parsing logic, rather than duplicating it -- but still deliberately
 * minimal: no includes, no variable interpolation, no nested structures,
 * since every consumer so far is a handful of fixed, known keys, not a
 * general-purpose config language.
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
#include "config-parser.h"

char *dcc_config_trim(char *s)
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

int dcc_config_parse_bool(const char *value, int *out)
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
 * A NULL-terminated array holding just the terminator -- the "empty list"
 * representation returned by dcc_config_parse_list() for a blank value, so
 * callers never have to special-case "no list was set" versus "list was
 * set to empty".
 **/
static char **dcc_config_empty_list(void)
{
    char **list = (char **) malloc(sizeof(char *));
    if (list != NULL)
        list[0] = NULL;
    return list;
}

char **dcc_config_parse_list(const char *value)
{
    char *copy, *saveptr, *tok;
    char **list;
    size_t count, cap;

    copy = strdup(value);
    if (copy == NULL)
        return dcc_config_empty_list();

    cap = 4;
    count = 0;
    list = (char **) malloc(cap * sizeof(char *));
    if (list == NULL) {
        free(copy);
        return dcc_config_empty_list();
    }

    for (tok = strtok_r(copy, ",", &saveptr); tok != NULL;
         tok = strtok_r(NULL, ",", &saveptr)) {
        char *trimmed = dcc_config_trim(tok);
        if (*trimmed == '\0')
            continue;

        if (count + 1 >= cap) {
            cap *= 2;
            list = (char **) realloc(list, cap * sizeof(char *));
            if (list == NULL) {
                free(copy);
                return dcc_config_empty_list();
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
 * so (defense-in-depth: an unprivileged local user could otherwise flip an
 * effective setting under a privileged distccd, or a shared distcc.conf
 * under a build farm's other users). Mirrors this codebase's existing
 * world-writable-file finding class (issue #157) rather than inventing a
 * new permissions convention. Never refuses to read the file over this --
 * only warns.
 **/
static void dcc_config_warn_if_world_writable(const char *log_prefix,
                                                const char *path, FILE *fp)
{
    struct stat st;

    if (fstat(fileno(fp), &st) != 0) {
        rs_log_warning("%s %s: fstat() failed: %s; continuing anyway",
                        log_prefix, path, strerror(errno));
        return;
    }

    if (st.st_mode & S_IWOTH) {
        rs_log_warning("%s %s is world-writable (mode %#o); any local user "
                        "could change its effective settings -- consider "
                        "tightening its permissions", log_prefix, path,
                        (unsigned) (st.st_mode & 07777));
    }
}

/**
 * Parse one line already known to contain a real `key = value` pair (blank
 * lines and `#` comments are filtered out by dcc_config_load() before this
 * is reached). A line with no `=` is warned about and skipped rather than
 * guessed at.
 **/
static void dcc_config_parse_line(const char *log_prefix, void *cfg,
                                    dcc_config_apply_kv_fn *apply_kv,
                                    char *line)
{
    char *eq = strchr(line, '=');
    char *key, *value;

    if (eq == NULL) {
        rs_log_warning("%s: ignoring malformed line (no '='): '%s'",
                        log_prefix, line);
        return;
    }

    *eq = '\0';
    key = dcc_config_trim(line);
    value = dcc_config_trim(eq + 1);

    if (*key == '\0') {
        rs_log_warning("%s: ignoring line with empty key: '= %s'",
                        log_prefix, value);
        return;
    }

    apply_kv(cfg, key, value);
}

void dcc_config_load(const char *path, const char *log_prefix,
                      dcc_config_apply_kv_fn *apply_kv, void *cfg)
{
    FILE *fp;
    char line[1024];

    fp = fopen(path, "r");
    if (fp == NULL) {
        if (errno != ENOENT)
            rs_log_warning("%s %s: could not open (%s); using built-in "
                            "defaults", log_prefix, path, strerror(errno));
        /* ENOENT: the file is genuinely optional -- not an error, not even
         * worth a log line, so a default install without this file doesn't
         * spam the log every startup. */
        return;
    }

    dcc_config_warn_if_world_writable(log_prefix, path, fp);

    while (fgets(line, sizeof(line), fp) != NULL) {
        char *trimmed = dcc_config_trim(line);
        if (*trimmed == '\0' || *trimmed == '#')
            continue;
        dcc_config_parse_line(log_prefix, cfg, apply_kv, trimmed);
    }

    fclose(fp);
}
