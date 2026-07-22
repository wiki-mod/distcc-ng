/* -*- c-file-style: "java"; indent-tabs-mode: nil; tab-width: 4; fill-column: 78 -*-
 *
 * distcc -- A simple distributed compiler system
 *
 * Copyright (C) 2002, 2003, 2004 by Martin Pool <mbp@samba.org>
 * Copyright 2007 Google Inc.
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

int dcc_r_file(int ifd, const char *filename, unsigned size,
               unsigned uncompr_size,
               enum dcc_compress);
/* Symlink-safe variant of dcc_r_file() that creates the final component
 * @p leaf relative to an already-open directory @p parent_fd with
 * O_NOFOLLOW, used by the server's multi-file receive path to prevent a
 * symlink at the leaf from redirecting the write outside the job directory
 * (issue #292). @p mode is caller-supplied (rather than a hardcoded
 * constant) since this shared-object function is linked into both distcc
 * and distccd (see Makefile.in's common_obj) and must not depend on
 * distccd-only option state. See the definition in bulk.c for the full
 * rationale. */
int dcc_r_file_beneath(int ifd, int parent_fd, const char *leaf,
                       unsigned size,
                       unsigned uncompr_size,
                       enum dcc_compress,
                       mode_t mode);
int dcc_r_fifo(int ifd, const char *fifo_name, size_t len);

int dcc_x_file(int ofd, const char *fname, const char *token,
               enum dcc_compress compression,
               off_t *);

int dcc_r_file_timed(int ifd, const char *fname, unsigned size,
                     unsigned uncompr_size,
                     enum dcc_compress);

int dcc_r_token_file(int ifd,
                     const char *token,
                     const char *fname,
                     enum dcc_compress compr);

int dcc_open_read(const char *fname, int *ifd, off_t *fsize);
int dcc_copy_file_to_fd(const char *in_fname, int out_fd);

/* clirpc.c */
int dcc_x_many_files(int ofd,
                     unsigned int n_files,
                     char **fnames);

/* srvrpc.c. @p file_mode is the permission bits (subject to umask) for
 * received FILE entries -- caller-supplied since srvrpc.c is linked into
 * more than just distccd (see dcc_r_many_files()'s own comment in
 * srvrpc.c). distccd's real caller (src/serve.c) passes opt_job_file_mode. */
int dcc_r_many_files(int in_fd,
                     const char *dirname,
                     enum dcc_compress compr,
                     mode_t file_mode);
