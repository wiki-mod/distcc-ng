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

/* config-parser.c */

#ifndef _DISTCC_CONFIG_PARSER_H
#define _DISTCC_CONFIG_PARSER_H

#include <stdio.h>

/**
 * Signature for a caller-supplied `key = value` handler, invoked once per
 * real (non-blank, non-comment) line dcc_config_load() successfully splits
 * on '='. @p cfg is whatever opaque state the caller passed to
 * dcc_config_load(); @p key and @p value are already trimmed. Unknown keys
 * or malformed values are the callback's own responsibility to warn about
 * and ignore -- this parser never treats an unrecognized key as a hard
 * error, so one typo can't take down every key below it in the file.
 **/
typedef void (dcc_config_apply_kv_fn)(void *cfg, const char *key,
                                        const char *value);

/**
 * Strip leading/trailing ASCII whitespace from @p s in place and return it,
 * so callers can chain this directly onto a line/token buffer they already
 * own without a separate copy.
 **/
char *dcc_config_trim(char *s);

/**
 * Parse a config boolean: exactly "true"/"false", case-insensitive. Any
 * other spelling ("yes", "1", "on", ...) is deliberately rejected rather
 * than guessed at -- silently accepting near-misses would make a typo in
 * the config file look like it was honored when it wasn't. On rejection,
 * @p out is left untouched (caller should pre-set it to the compiled-in
 * default) and 0 is returned so the caller can log what was rejected.
 **/
int dcc_config_parse_bool(const char *value, int *out);

/**
 * Split a comma-separated @p value into a freshly allocated NULL-terminated
 * array of freshly allocated strings, trimming whitespace around each
 * token and dropping empty ones (so "a, ,b" and "a,b" behave identically).
 * Returns an empty-list array (a single-element array holding just the
 * NULL terminator) for a blank/whitespace-only value, never NULL, so
 * callers can always iterate without a null-check. Caller owns the
 * returned array and every string in it.
 **/
char **dcc_config_parse_list(const char *value);

/**
 * Read @p path (a `key = value`, `#`-comment config file) line by line,
 * calling @p apply_kv once per real line with @p cfg and the trimmed
 * key/value pair. @p log_prefix is used in every warning this function
 * itself emits (a missing/malformed file, a world-writable file), so two
 * different config files sharing this parser produce distinguishable log
 * output (e.g. "distccd config" vs "distcc config").
 *
 * Never fails the caller: a missing file is silently fine (this config
 * file is always optional; every key keeps whatever default @p cfg already
 * holds before this call). A file that exists but can't be opened for
 * another reason (permission denied, not a regular file, ...) logs a
 * warning and is likewise skipped, rather than treating an unreadable
 * *optional* config file as a reason to fail the caller's own startup.
 * A world-writable file logs a warning (defense-in-depth, matching this
 * codebase's own world-writable-file CodeQL finding class) but is still
 * read and used -- neither distcc nor distccd refuses to start over file
 * permissions it doesn't own.
 **/
void dcc_config_load(const char *path, const char *log_prefix,
                      dcc_config_apply_kv_fn *apply_kv, void *cfg);

#endif /* _DISTCC_CONFIG_PARSER_H */
