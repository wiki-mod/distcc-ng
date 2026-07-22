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



#include <config.h>

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/wait.h>

#include <ctype.h>

#ifdef HAVE_FNMATCH_H
  #include <fnmatch.h>
#endif

#include <sys/time.h>
#include <time.h>
#include <limits.h>
#include <assert.h>

#include "distcc.h"
#include "trace.h"
#include "exitcode.h"
#include "util.h"
#include "snprintf.h"
#include "hosts.h"
#include "bulk.h"
#include "implicit.h"
#include "exec.h"
#include "where.h"
#include "lock.h"
#include "timeval.h"
#include "compile.h"
#include "include_server_if.h"
#include "emaillog.h"
#include "dotd.h"
#include "pathsafety.h"

/**
 * This boolean is true iff --scan-includes option is enabled.
 * If so, distcc will just run the source file through the include server,
 * and print out the list of header files that might be #included,
 * rather than actually compiling the sources.
 */
int dcc_scan_includes = 0;

static const char *const include_server_port_suffix = "/socket";
static const char *const discrepancy_suffix = "/discrepancy_counter";

static void bad_host(struct dcc_hostdef *host, int *cpu_lock_fd , int *local_cpu_lock_fd)
{
   if (host)
       dcc_disliked_host(host);

   if (*cpu_lock_fd != -1) {
       dcc_unlock(*cpu_lock_fd);
       *cpu_lock_fd = -1;
   }
   if (*local_cpu_lock_fd != -1) {
       dcc_unlock(*local_cpu_lock_fd);
       *local_cpu_lock_fd = -1;
   }
}

static int dcc_get_max_discrepancies_before_demotion(void)
{
    /* Warning: the default setting here should have the same value as in the
     * pump.in script! */
    static const int default_setting = 1;
    static int current_setting = 0;

    if (current_setting > 0)
        return current_setting;

    const char *user_setting = getenv("DISTCC_MAX_DISCREPANCY");
    if (user_setting) {
        int parsed_user_setting = atoi(user_setting);
        if (parsed_user_setting <= 0) {
            rs_log_error("Bad DISTCC_MAX_DISCREPANCY value: %s", user_setting);
            exit(EXIT_BAD_ARGUMENTS);
        }
        current_setting = parsed_user_setting;
    } else {
        current_setting = default_setting;
    }
    return current_setting;
}

/**
 * Return in @param filename the name of the file we use as unary counter of
 * discrepancies (a compilation failing on the server, but succeeding
 * locally. This function may return NULL in @param filename if the name cannot
 * be determined.
 **/
int dcc_discrepancy_filename(char **filename)
{
    const char *include_server_port = getenv("INCLUDE_SERVER_PORT");
    *filename = NULL;
    if (include_server_port == NULL) {
        return 0;
    } else if (str_endswith(include_server_port_suffix,
                            include_server_port)) {
        /* We're going to make a longer string from include_server_port: one
         * that replaces include_server_port_suffix with discrepancy_suffix. */
        int delta = strlen(discrepancy_suffix) -
            strlen(include_server_port_suffix);
        assert (delta > 0);
        size_t include_server_port_len = strlen(include_server_port);
        *filename = malloc(include_server_port_len + 1 + delta);
        if (!*filename) {
            rs_log_error("failed to allocate space for filename");
            return EXIT_OUT_OF_MEMORY;
        }
        memcpy(*filename, include_server_port, include_server_port_len);
        int slash_pos = include_server_port_len
                        - strlen(include_server_port_suffix);
        /* Because include_server_port_suffix is a suffix of include_server_port
         * we expect to find a '/' at slash_pos in filename. */
        assert((*filename)[slash_pos] == '/');
        size_t discrepancy_suffix_len = strlen(discrepancy_suffix);
        memcpy(*filename + slash_pos, discrepancy_suffix, discrepancy_suffix_len);
        (*filename)[slash_pos + discrepancy_suffix_len] = '\0';
        return 0;
    } else
        return 0;
}


/**
 * Return the length of the @param discrepancy_filename in newly allocated
 * memory; return 0 if it's not possible to determine the length (if
 * e.g. @param discrepancy_filename is NULL).
 **/
static int dcc_read_number_discrepancies(const char *discrepancy_filename)
{
    if (!discrepancy_filename) return 0;
    struct stat stat_record;
    if (stat(discrepancy_filename, &stat_record) == 0) {
        size_t size = stat_record.st_size;
        /* Does size fit in an 'int'? */
        if ((((size_t) (int) size) == size) &&
            ((int) size) > 0)
            return ((int) size);
        else
            return INT_MAX;
    } else
        return 0;
}


/**
 *  Lengthen the file whose name is @param discrepancy_filename by one byte. Or,
 *  do nothing, if @param discrepancy_filename is NULL.
 **/
static int dcc_note_discrepancy(const char *discrepancy_filename)
{
    FILE *discrepancy_file;
    int fd;
    if (!discrepancy_filename) return 0;
    /* Open with an explicit mode rather than fopen() (which always creates
     * at the umask-modified default of 0666): 0600, since this is just a
     * private per-user discrepancy counter, not meant to be shared. */
    fd = open(discrepancy_filename, O_WRONLY|O_APPEND|O_CREAT, 0600);
    if (fd == -1 || !(discrepancy_file = fdopen(fd, "a"))) {
        rs_log_error("failed to open discrepancy_filename file: %s: %s",
                     discrepancy_filename,
                     strerror(errno));
        if (fd != -1)
            close(fd);
        return EXIT_IO_ERROR;
    }
    if (fputc('@', discrepancy_file) == EOF) {
        rs_log_error("failed to write to discrepancy_filename file: %s",
                     discrepancy_filename);
        fclose(discrepancy_file);
        return EXIT_IO_ERROR;
    }
    /* The file position is a property of the stream, so we are
    assured that exactly one process will take the 'if' branch when
    max_discrepancies_before_demotion failures is reached. */
    if (ftell(discrepancy_file) == 
        (long int)dcc_get_max_discrepancies_before_demotion()) {
        rs_log_warning("now using plain distcc, possibly due to "
                       "inconsistent file system changes during build");
    }
    fclose(discrepancy_file);
    return 0;
}


/**
 * In some cases, it is ill-advised to preprocess on the server. Check for such
 * situations. If they occur, then change protocol version.
 **/
static void dcc_perhaps_adjust_cpp_where_and_protover(
    char *input_fname,
    struct dcc_hostdef *host,
    char *discrepancy_filename)
{
    /* It's unfortunate that the variable that controls preprocessing is in the
       "host" datastructure. See elaborate complaint in dcc_build_somewhere. */

    /* Check whether there has been too much trouble running distcc-pump during
       this build. */
    if (dcc_read_number_discrepancies(discrepancy_filename) >=
        dcc_get_max_discrepancies_before_demotion()) {
        /* Give up on using distcc-pump */
        host->cpp_where = DCC_CPP_ON_CLIENT;
        dcc_get_protover_from_features(host->compr,
                                       host->cpp_where,
                                       &host->protover);
    }

    /* Don't do anything silly for already preprocessed files. */
    if (dcc_is_preprocessed(input_fname)) {
        /* Don't subject input file to include analysis. */
        rs_log_warning("cannot use distcc_pump on already preprocessed file"
                       " (such as emitted by ccache)");
        host->cpp_where = DCC_CPP_ON_CLIENT;
        dcc_get_protover_from_features(host->compr,
                                       host->cpp_where,
                                       &host->protover);
    }
    /* Environment variables CPATH and two friends are hidden ways of passing
     * -I's. Beware! */
    if (getenv("CPATH") || getenv("C_INCLUDE_PATH")
        || getenv("CPLUS_INCLUDE_PATH")) {
        rs_log_warning("cannot use distcc_pump with any of environment"
                       " variables CPATH, C_INCLUDE_PATH or CPLUS_INCLUDE_PATH"
                       " set, preprocessing locally");
        host->cpp_where = DCC_CPP_ON_CLIENT;
        dcc_get_protover_from_features(host->compr,
                                       host->cpp_where,
                                       &host->protover);
    }
}



/**
 * Do a time analysis of dependencies in dotd file.  First, if @param dotd_fname
 * is created before @param reference_time, then return NULL in result.  Second,
 * if one of the files mentioned in the @param dotd_fname is modified after time
 * @param reference_time, then return non-NULL in result. Otherwise return NULL
 * in result.  A non-NULL value in result is a pointer to a newly allocated
 * string describing the offending dependency.

 * If @param exclude_pattern is not NULL, then files matching the glob @param
 * exclude_pattern are not considered in the above comparison.
 *
 *  This function is not declared static --- for purposes of testing.
 **/
int dcc_fresh_dependency_exists(const char *dotd_fname,
                                const char *exclude_pattern,
                                time_t reference_time,
                                char **result)
{
    struct stat stat_dotd;
    off_t dotd_fname_size = 0;
    FILE *fp;
    int c;
    int res;
    char *dep_name;

    *result = NULL;
    /* Open the .d file first, then fstat() the resulting descriptor
     * instead of stat()-ing the path and opening it as a second, separate
     * step. fstat() on an already-open fd is guaranteed to describe
     * exactly the file this function goes on to read (same open file
     * description/inode) -- there is no window in which dotd_fname could
     * resolve to a different or replaced file between the freshness/size
     * check and the read. A stat(path) followed by a later open(path) (the
     * previous shape here) is the check-then-act pattern CodeQL's
     * cpp/toctou-race-condition flags, since those two syscalls can each
     * independently resolve the same path to different underlying files. */
    if ((fp = fopen(dotd_fname, "r")) == NULL) {
        rs_trace("could not open \"%s\": %s", dotd_fname, strerror(errno));
        return 0;
    }
    res = fstat(fileno(fp), &stat_dotd);
    if (res) {
        rs_trace("could not fstat \"%s\": %s", dotd_fname, strerror(errno));
        fclose(fp);
        return 0;
    }
    if (stat_dotd.st_mtime < reference_time) {
        /* That .d file appears to be too old; don't trust it for this
         * analysis. */
        rs_trace("old dotd file \"%s\"", dotd_fname);
        fclose(fp);
        return 0;
    }
    dotd_fname_size = stat_dotd.st_size;
    /* Is dotd_fname_size representable as a size_t value ? */
    if ((off_t) (size_t) dotd_fname_size == dotd_fname_size) {
        /* +1 reserves the NUL-terminator slot: the copy loop below bounds-
         * checks each byte it writes against dotd_fname_size (i >=
         * dotd_fname_size), but the terminator write after the loop
         * (dep_name[i] = '\0') does not re-check i. Kept even though the
         * fopen()-then-fstat() ordering above removes the path-level
         * TOCTOU: another writer sharing this same underlying file could
         * still append to it between this fstat() and the read loop below,
         * so i can still legitimately reach dotd_fname_size. */
        dep_name = malloc((size_t) dotd_fname_size + 1);
        if (!dep_name) {
            rs_log_error("failed to allocate space for dotd file");
            fclose(fp);
            return EXIT_OUT_OF_MEMORY;
        }
    } else { /* This is exceedingly unlikely. */
        rs_trace("file \"%s\" is too big", dotd_fname);
        fclose(fp);
        return 0;
    }

    /* Find ':'. */
    while ((c = getc(fp)) != EOF && c != ':');
    if (c != ':') goto return_0;

    /* Process dependencies. */
    while (c != EOF) {
        struct stat stat_dep;
        int i = 0;
        /* Skip whitespaces and backslashes. */
        while ((c = getc(fp)) != EOF && (isspace(c) || c == '\\'));
        /* Now, we're at start of file name. */
        ungetc(c, fp);
        while ((c = getc(fp)) != EOF &&
               (!isspace(c) || c == '\\')) {
            if (i >= dotd_fname_size) {
                /* Not actually impossible: this fires if the .d file grows
                 * between the fstat() above and this read (the file is
                 * still being written to by something else even though we
                 * hold it open), so a dependency name can be longer than
                 * what the buffer was sized for. Bail out rather than
                 * overrun dep_name. */
                rs_log_error("not enough room for dependency name");
                goto return_0;
            }
            if (c == '\\') {
                /* Skip the newline. */
                if ((c = getc(fp)) != EOF)
                    if (c != '\n') ungetc(c, fp);
            }
            else dep_name[i++] = c;
        }
        if (i != 0) {
            dep_name[i] = '\0';
#ifdef HAVE_FNMATCH_H
            if (exclude_pattern == NULL ||
                fnmatch(exclude_pattern, dep_name, 0) == FNM_NOMATCH) {
#else
            /* Tautology avoids compiler warning about unused variable. */
            if (exclude_pattern == exclude_pattern) {
#endif
                /* The dep_name is not excluded; now verify that it is not too
                 * young. */
                rs_log_info("Checking dependency: %s", dep_name);
                res = stat(dep_name, &stat_dep);
                if (res) goto return_0;
                if (stat_dep.st_ctime >= reference_time) {
                    fclose(fp);
                    *result = realloc(dep_name, strlen(dep_name) + 1);
                    if (*result == NULL) {
                        rs_log_error("realloc failed");
                        return EXIT_OUT_OF_MEMORY;
                    }
                    return 0;
                }
            }
        }
    }
  return_0:
    fclose(fp);
    free(dep_name);
    return 0;
}


/**
 * Invoke a compiler locally.  This is, obviously, the alternative to
 * dcc_compile_remote().
 *
 * The server does basically the same thing, but it doesn't call this
 * routine because it wants to overlap execution of the compiler with
 * copying the input from the network.
 *
 * This routine used to exec() the compiler in place of distcc.  That
 * is slightly more efficient, because it avoids the need to create,
 * schedule, etc another process.  The problem is that in that case we
 * can't clean up our temporary files, and (not so important) we can't
 * log our resource usage.
 *
 * This is called with a lock on localhost already held.
 **/
static int dcc_compile_local(char *argv[],
                             char *input_name)
{
    pid_t pid;
    int ret;
    int status;

    dcc_note_execution(dcc_hostdef_local, argv);
    dcc_note_state(DCC_PHASE_COMPILE, input_name, "localhost", DCC_LOCAL);

    /* We don't do any redirection of file descriptors when running locally,
     * so if for example cpp is being used in a pipeline we should be fine. */
    /* Not sandboxed: this is a trusted local build, not a remote client's
     * job -- see dcc_spawn_child()'s sandbox_seccomp parameter. */
    if ((ret = dcc_spawn_child(argv, &pid, NULL, NULL, NULL,
                              0 /* sandbox_seccomp */)) != 0)
        return ret;

    if ((ret = dcc_collect_child("cc", pid, &status, timeout_null_fd)))
        return ret;

    return dcc_critique_status(status, "compile", input_name,
                               dcc_hostdef_local, 1);
}


 /* Make the decision to send email about @param input_name, but only after a
  * little further investgation.
  *
  * We avoid sending email if there's a fresh dependency. To find out, we need
  * @param deps_fname, a .d file, created during the build.  We check each
  * dependency described there. If just one changed after the build started,
  * then we really don't want to hear about distcc-pump errors, because
  * dependencies shouldn't change. The files generated during the build are
  * exceptions. To disregard these, the distcc user may specify a glob pattern
  * in environment variable DISTCC_EXCLUDE_FRESH_FILES.
  *
  * Also, if there has been too many discrepancies (where the build has
  * succeeded remotely but failed locally), then we need to stop using
  * distcc-pump for the remainder of the build.  The present function
  * contributes to this logic: if it is determined that email must be sent, then
  * the count of such situations is incremented using the file @param
  * discrepancy_filename.
 */
static int dcc_please_send_email_after_investigation(
    const char *input_fname,
    const char *deps_fname,
    const char *discrepancy_filename) {

    int ret;
    char *fresh_dependency;
    const char *include_server_port = getenv("INCLUDE_SERVER_PORT");
    struct stat stat_port;
    rs_log_warning("remote compilation of '%s' failed, retried locally "
                   "and got a different result.", input_fname);
    if ((include_server_port != NULL) &&
        (stat(include_server_port, &stat_port)) == 0) {
        time_t build_start = stat_port.st_ctime;
        if (deps_fname) {
            const char *exclude_pattern =
                getenv("DISTCC_EXCLUDE_FRESH_FILES");

            if ((ret = dcc_fresh_dependency_exists(deps_fname,
                                                   exclude_pattern,
                                                   build_start,
                                                   &fresh_dependency))) {
                return ret;
            }
            if (fresh_dependency) {
                rs_log_warning("file '%s', a dependency of %s, "
                               "changed during the build", fresh_dependency,
                               input_fname);
                free(fresh_dependency);
                return dcc_note_discrepancy(discrepancy_filename);
            }
        }
    }
    dcc_please_send_email();
    return dcc_note_discrepancy(discrepancy_filename);
}

#ifdef HAVE_FSTATAT
/**
 * Probe @p path -- a resolved, executable compiler binary that is not
 * itself a symlink, so readlinkat() can't tell us anything about it -- by
 * running "<path> --version" and checking whether it self-identifies as
 * clang. Both gcc and clang always print their own family name in the
 * first line of "--version" output ("gcc (...) X.Y.Z" vs. "... clang
 * version X.Y.Z", verified against real gcc/clang output); this is a
 * cheaper probe than dcc_resolve_march_native()'s "-v -E" trick in arg.c
 * since only the family is needed here, not resolved CPU flags.
 *
 * @returns 1 if @p path self-identifies as clang, 0 if it doesn't (treated
 *     as gcc, the only other family dcc_rewrite_generic_compiler
 *     distinguishes), -1 if the probe itself failed (fork/exec/pipe error),
 *     @p path failed the pre-exec sanity checks below, or the caller must
 *     not guess.
 **/
static int dcc_probe_is_clang(const char *path)
{
    int fds[2];
    pid_t pid;
    FILE *in;
    char buff[4096];
    int is_clang = -1;

    /* @p path is caller's dcc_which()-resolved PATH lookup, so its value is
     * influenced by the invoking user's own environment -- expected for
     * this client-side, same-privilege context (see this function's
     * callers), but CodeQL's cpp/uncontrolled-process-operation flags any
     * execve-family call fed from environment-influenced data on principle,
     * without knowing the trust boundary here. Two concrete, real checks
     * before the fork rather than a bare suppression comment:
     * (1) refuse a non-absolute path outright -- dcc_which() always builds
     * one from a PATH entry, so a relative value here means something
     * upstream is already broken and must not be trusted further;
     * (2) re-verify executability right before the exec below rather than
     * only relying on dcc_which()'s own earlier access() check, closing the
     * TOCTOU window between that lookup and this actual exec. */
    if (path[0] != '/') {
        rs_log_warning("refusing to probe non-absolute compiler path '%s'",
                        path);
        return -1;
    }
    if (access(path, X_OK) != 0) {
        rs_log_warning("compiler path '%s' no longer executable, not probing: %s",
                        path, strerror(errno));
        return -1;
    }

    if (pipe(fds) == -1)
        return -1;

    pid = fork();
    if (pid == -1) {
        close(fds[0]);
        close(fds[1]);
        return -1;
    }

    if (pid == 0) {
        /* Child. This must never return into the caller's control flow --
         * doing so would fork the whole distcc client in two. Any failure
         * here must terminate the child via _exit(), never "return". */
        int devnull;

        close(fds[0]);
        dup2(fds[1], STDOUT_FILENO);
        dup2(fds[1], STDERR_FILENO);
        close(fds[1]);
        devnull = open("/dev/null", O_RDONLY);
        if (devnull != -1) {
            dup2(devnull, STDIN_FILENO);
            close(devnull);
        }
        execl(path, path, "--version", (char *) NULL);
        /* execl() only returns on failure. */
        _exit(127);
    }

    /* Parent. */
    close(fds[1]);
    in = fdopen(fds[0], "r");
    if (in == NULL) {
        close(fds[0]);
    } else {
        if (fgets(buff, sizeof(buff), in) != NULL)
            is_clang = (strstr(buff, "clang") != NULL) ? 1 : 0;
        fclose(in);          /* also closes fds[0] */
    }
    while (waitpid(pid, NULL, 0) == -1 && errno == EINTR)
        ;
    return is_clang;
}

/* Re-write "cc" to directly call gcc or clang
 */
static void dcc_rewrite_generic_compiler(char **argv)
{
    char linkbuf[MAXPATHLEN + 1], *link = NULL, *t;
    int ret, dir;
    ssize_t ssz;
    struct stat st;
    bool cpp = false;

    assert(argv);

    if (strcmp(argv[0], "cc") == 0)
        ;
    else if (strcmp(argv[0], "c++") == 0)
        cpp = true;
    else
        return;

    ret = dcc_which(cpp ? "c++" : "cc", &link);
    if (ret < 0)
        return;
    t = strrchr(link, '/');
    if (!t)
        return;
    *t = '\0';
    dir = open(link, O_RDONLY);
    if (dir < 0)
        return;
    *t = '/';
    ret = fstatat(dir, t + 1, &st, AT_SYMLINK_NOFOLLOW);
    if (ret < 0)
        return;
    if ((st.st_mode & S_IFMT) != S_IFLNK) {
        /* Not a symlink -- e.g. macOS's "cc", a small dispatch binary
         * rather than a symlink to the real compiler. There's no link
         * target to inspect, so ask the binary itself what it is. */
        int probed_is_clang = dcc_probe_is_clang(link);

        if (probed_is_clang < 0)
            return;
        free(argv[0]);
        argv[0] = strdup(probed_is_clang ? (cpp ? "clang++" : "clang")
                                          : (cpp ? "g++" : "gcc"));
        rs_trace("Rewriting '%s' to '%s'", cpp ? "c++" : "cc", argv[0]);
        return;
    }
    ssz = readlinkat(dir, t + 1, linkbuf, sizeof(linkbuf) - 1);
    if (ssz < 0)
        return;
    linkbuf[ssz] = '\0';
    fstatat(dir, linkbuf, &st, AT_SYMLINK_NOFOLLOW);
    if ((st.st_mode & S_IFMT) == S_IFLNK) {
        /* this is a Debian thing. Fedora just has /usr/bin/cc -> gcc */
        if (strcmp(linkbuf, cpp ? "/etc/alternatives/c++" : "/etc/alternatives/cc") == 0) {
            char m[MAXPATHLEN + 1];

            m[0] = '\0';
            strcpy(m, linkbuf);

            ssz = readlinkat(dir, m, linkbuf, sizeof(linkbuf) - 1);
            if (ssz < 0)
                return;
            linkbuf[ssz] = '\0';
        }
    }
    ret = faccessat(dir, linkbuf, X_OK, 0);
    if (ret < 0)
        return;

    if (        cpp && strcmp(strrchr(linkbuf, '/') ? strrchr(linkbuf, '/') + 1 : linkbuf, "clang++") == 0) {
        free(argv[0]);
        argv[0] = strdup("clang++");
        rs_trace("Rewriting '%s' to '%s'", "c++", "clang++");
    } else if (   cpp && strcmp(strrchr(linkbuf, '/') ? strrchr(linkbuf, '/') + 1 : linkbuf, "g++") == 0) {
        free(argv[0]);
        argv[0] = strdup("g++");
        rs_trace("Rewriting '%s' to '%s'", "c++", "g++");
    } else if (!cpp && strcmp(strrchr(linkbuf, '/') ? strrchr(linkbuf, '/') + 1 : linkbuf, "clang") == 0) {
        free(argv[0]);
        argv[0] = strdup("clang");
        rs_trace("Rewriting '%s' to '%s'", "cc", "clang");
    } else if (!cpp && strcmp(strrchr(linkbuf, '/') ? strrchr(linkbuf, '/') + 1 : linkbuf, "gcc") == 0) {
        free(argv[0]);
        argv[0] = strdup("gcc");
        rs_trace("Rewriting '%s' to '%s'", "cc", "gcc");
    } else
        return;
}
#endif


/* Clang is a native cross-compiler, but needs to be told to what target it is
 * building.
 * TODO: actually probe clang with clang --version, instead of trusting
 * autoheader.
 *
 * argv[0] may be a full path (e.g. the user ran "distcc /usr/bin/clang-15
 * ...", or a masquerade/wrapper resolved to an absolute path further up the
 * call chain) rather than a bare name found via PATH -- match against the
 * basename, not the raw argv[0], so this still fires in that case.
 *
 * CAUTION (found empirically, not just by inspection, when this match was
 * widened to cover full paths, not only bare names): this function itself
 * never execs argv[0], but that does NOT make a name-only match safe. If
 * the basename merely *says* "clang" -- a full-path dispatcher or wrapper
 * that actually invokes a different compiler family under that name -- the
 * "-target" flag this function appends is still forwarded to whatever that
 * binary really is by a later stage of dcc_build_somewhere(); a real gcc
 * executed via such a wrapper rejects "-target" outright ("error:
 * unrecognized command-line option") and the whole compile fails.
 * Reproduced with a real, non-symlink dispatcher script named "clang" that
 * execs gcc: matching only the raw argv[0] (a full path never equals the
 * bare name "clang"), invoking it by full path added no flag and the
 * compile succeeded; matching the basename instead, the same full-path
 * invocation matches "clang", "-target" gets appended, and the compile
 * hard-fails. This is the same class of "compiler family trusted from the
 * name alone" problem that dcc_probe_is_clang() (below) exists to close
 * for dcc_rewrite_generic_compiler(); whether the same probe should gate
 * this function too -- at the cost of an extra fork+exec on every clang
 * compile, not just the narrow one-shot "cc"/"c++" dispatch case that
 * function covers -- is a real design tradeoff (probe cost vs. a wrong
 * flag silently reaching a mismatched compiler), left as an open decision
 * rather than resolved unilaterally here.
 */
static void dcc_add_clang_target(char **argv)
{
        /* defined by autoheader */
    const char *target = NATIVE_COMPILER_TRIPLE;
    const char *base = dcc_find_basename(argv[0]);

    if (strcmp(base, "clang") == 0 || strncmp(base, "clang-", strlen("clang-")) == 0 ||
        strcmp(base, "clang++") == 0 || strncmp(base, "clang++-", strlen("clang++-")) == 0)
        ;
    else
        return;

    /* -target aarch64-linux-gnu */
    if (dcc_argv_search(argv, "-target"))
        return;

    /* --target=aarch64-linux-gnu */
    if (dcc_argv_startswith(argv, "--target"))
        return;

    rs_log_info("Adding '-target %s' to support clang cross-compilation.",
                target);
    dcc_argv_append(argv, strdup("-target"));
    dcc_argv_append(argv, strdup(target));
}

/*
 * Cross compilation for gcc
 *
 * As with dcc_add_clang_target() above, argv[0] may be a full path rather
 * than a bare name found via PATH -- match and rewrite against the
 * basename, not the raw argv[0], so a compiler invoked as e.g.
 * "/usr/bin/gcc-11" is still recognised as plain "gcc-11" for the
 * fully-qualified-name rewrite below. The rewritten command name itself
 * must also be built from the basename: concatenating the *original*
 * argv[0] here would produce a malformed name embedding the caller's
 * original path (e.g. "aarch64-linux-gnu-/usr/bin/gcc-11") instead of the
 * intended "aarch64-linux-gnu-gcc-11".
*/
static int dcc_gcc_rewrite_fqn(char **argv)
{
        /* defined by autoheader */
    const char *target_with_vendor = NATIVE_COMPILER_TRIPLE;
    const char *base = dcc_find_basename(argv[0]);
    char *newcmd, *t, *path;
    int pathlen = 0;
    int newcmd_len = 0;

    if (strcmp(base, "gcc") == 0 || strncmp(base, "gcc-", strlen("gcc-")) == 0 ||
        strcmp(base, "g++") == 0 || strncmp(base, "g++-", strlen("g++-")) == 0)
        ;
    else
        return -ENOENT;


    /* Built via snprintf (rather than malloc()+strcpy()+strcat()+strcat())
     * so the buffer size and the writes are both expressed in a single
     * call each -- CodeQL's cpp/unbounded-write check cannot trace a size
     * computed via separate strlen() calls forward to a later strcat(),
     * even when (as here) the arithmetic is in fact exact; snprintf makes
     * the bound self-evident at the write site instead of relying on a
     * remembered invariant from a few lines above. */
    newcmd_len = strlen(target_with_vendor) + 1 + strlen(base) + 1;
    newcmd = malloc(newcmd_len);
    if (!newcmd)
        return -ENOMEM;
    snprintf(newcmd, newcmd_len, "%s-%s", target_with_vendor, base);

    /* If the caller gave a directory (e.g. "/opt/toolchain/bin/gcc"), the
     * eventual execvp() of the rewritten name must still resolve inside
     * that same directory, not wherever $PATH happens to point -- a bare
     * rewritten name searched globally could silently pick up a different
     * cross-toolchain's same-named binary if one exists earlier on $PATH,
     * silently swapping toolchains instead of using the one the build
     * system explicitly selected. So: look for the target-prefixed binary
     * alongside the original directory first; only fall through to a
     * global $PATH search when argv[0] itself had no directory component
     * (i.e. it was already found via $PATH, so searching $PATH again for
     * the rewritten name carries the same resolution semantics as the
     * original invocation, not a change in them). */
    if (base != argv[0]) {
        size_t dirlen = (size_t) (base - argv[0]); /* includes trailing '/' */
        int dirbinlen = (int) dirlen + newcmd_len;
        char *dirbin = malloc(dirbinlen);

        if (!dirbin) {
            free(newcmd);
            return -ENOMEM;
        }
        memcpy(dirbin, argv[0], dirlen);
        memcpy(dirbin + dirlen, newcmd, newcmd_len);
        if (access(dirbin, X_OK) == 0) {
            rs_log_info("Re-writing call to '%s' to '%s' to support cross-compilation.",
                        argv[0], dirbin);
            free(argv[0]);
            free(newcmd);
            argv[0] = dirbin;
            return 0;
        }
        free(dirbin);
        free(newcmd);
        return -ENOENT;
    }

    /* TODO, is this the right PATH? */
    path = getenv("PATH");
    if (!path) {
        free(newcmd);
        return -ENOENT;
    }
    do {
        int binname_len = strlen(path) + 1 + strlen(newcmd) + 1;
        char binname[binname_len];
        int r;

        /* emulate strchrnul() */
        t = strchr(path, ':');
        if (!t)
            t = path + strlen(path);
        pathlen = t - path;
        if (*path == '\0')
            break;
        strncpy(binname, path, pathlen);
        binname[pathlen] = '\0';
        snprintf(binname + pathlen, binname_len - pathlen, "/%s", newcmd);
        r = access(binname, X_OK);
        if (r < 0)
            continue;
        /* good!, now rewrite */
        rs_log_info("Re-writing call to '%s' to '%s' to support cross-compilation.",
                    argv[0], newcmd);
        free(argv[0]);
        argv[0] = newcmd;
        return 0;
    } while ((path += pathlen + 1));
    free(newcmd);
    return -ENOENT;
}

static int dcc_get_max_retries(void)
{
    if (dcc_backoff_is_enabled()) {
        /* eventually distcc will either find a suitable host or mark
	 * all hosts as faulty (and fallback to a local compilation)
	 */
	return 0; /* no limit */
    } else {
	return 3; /* somewhat arbitrary */
    }
}

/**
 * Execute the commands in argv remotely or locally as appropriate.
 *
 * We may need to run cpp locally; we can do that in the background
 * while trying to open a remote connection.
 *
 * This function is slightly inefficient when it falls back to running
 * gcc locally, because cpp may be run twice.  Perhaps we could adjust
 * the command line to pass in the .i file.  On the other hand, if
 * something has gone wrong, we should probably take the most
 * conservative course and run the command unaltered.  It should not
 * be a big performance problem because this should occur only rarely.
 *
 * @param argv Command to execute.  Does not include 0='distcc'.
 * Must be dynamically allocated.  This routine deallocates it.
 *
 * @param status On return, contains the waitstatus of the compiler or
 * preprocessor.  This function can succeed (in running the compiler) even if
 * the compiler itself fails.  If either the compiler or preprocessor fails,
 * @p status is guaranteed to hold a failure value.
 *
 * Implementation notes:
 *
 * This code might be simpler if we would only acquire one lock
 * at a time.  But we need to choose the server host in order
 * to determine whether it supports pump mode or not,
 * and choosing the server host requires acquiring its lock
 * (otherwise it might be busy when we we try to acquire it).
 * So if the server chosen is not localhost, we need to hold the
 * remote host lock while we're doing local preprocessing or include
 * scanning.  Since local preprocessing/include scanning requires
 * us to acquire the local cpu lock, that means we need to hold two
 * locks at one time.
 *
 * TODO: make pump mode a global flag, and drop support for
 * building with cpp mode on some hosts and not on others.
 * Then change the code so that we only choose the remote
 * host after local preprocessing/include scanning is finished
 * and the local cpu lock is released.
 */
static int
dcc_build_somewhere(char *argv[],
                    int sg_level,
                    int *status)
{
    char *input_fname = NULL, *output_fname, *cpp_fname, *deps_fname = NULL;
    char **files;
    char **server_side_argv = NULL;
    char **localcpp_server_argv = NULL;
    char **remotecpp_server_argv = NULL;
    char *server_stderr_fname = NULL;
    int needs_dotd = 0;
    int sets_dotd_target = 0;
    pid_t cpp_pid = 0;
    int cpu_lock_fd = -1, local_cpu_lock_fd = -1;
    int ret;
    int remote_ret = 0;
    int retry_count = 0, max_retries, remote_unsupported = 0;
    struct dcc_hostdef *host = NULL;
    char *discrepancy_filename = NULL;
    char **new_argv;

    max_retries = dcc_get_max_retries();

    if ((ret = dcc_expand_preprocessor_options(&argv)) != 0)
        goto clean_up;

    if ((ret = dcc_discrepancy_filename(&discrepancy_filename)))
        goto clean_up;
    if (discrepancy_filename && !dcc_sane_env_path(discrepancy_filename)) {
        rs_log_warning("ignoring malformed discrepancy filename derived "
                        "from INCLUDE_SERVER_PORT");
        free(discrepancy_filename);
        discrepancy_filename = NULL;
    }

    if (sg_level) /* Recursive distcc - run locally, and skip all locking. */
        goto run_local;

    /* TODO: Perhaps tidy up these gotos. */

    /* FIXME: this may leak memory for argv. */

    ret = dcc_scan_args(argv, &input_fname, &output_fname, &new_argv);
    dcc_free_argv(argv);
    argv = new_argv;
    if (!getenv("DISTCC_NO_REWRITE_CROSS")) {
#ifdef HAVE_FSTATAT
        dcc_rewrite_generic_compiler(new_argv);
#endif
        dcc_add_clang_target(new_argv);
        dcc_gcc_rewrite_fqn(new_argv);
    }
    if (ret != 0) {
        /* we need to scan the arguments even if we already know it's
         * local, so that we can pick up distcc client options. */
        goto lock_local;
    }

#if 0
    /* turned off because we never spend long in this state. */
    dcc_note_state(DCC_PHASE_STARTUP, input_fname, NULL);
#endif
    if ((ret = dcc_make_tmpnam("distcc_server_stderr", ".txt",
                               &server_stderr_fname))) {
        /* So we are failing locally to make a temp file to store the
         * server-side errors in; it's unlikely anything else will
         * work, but let's try the compilation locally.
         * FIXME: this will blame the server for a failure that is
         * local. However, we don't make any distrinction between
         * all the reasons dcc_compile_remote can fail either;
         * and some of those reasons are local.
         */
        goto fallback;
    }

    /* Lock ordering invariant: always acquire the lock for the
     * remote host (if any) first. */

    /* Choose the distcc server host (which could be either a remote
     * host or localhost) and acquire the lock for it.  */
  choose_host:
    if ((ret = dcc_pick_host_from_list_and_lock_it(&host, &cpu_lock_fd)) != 0) {
        /* Doesn't happen at the moment: all failures are masked by
           returning localhost. */
        goto fallback;
    }
    if (host->mode == DCC_MODE_LOCAL) {
        /* We picked localhost and already have a lock on it so no
         * need to lock it now. */
        goto run_local;
    }

    if (!dcc_is_preprocessed(input_fname)) {
        /* Lock the local CPU, since we're going to be doing preprocessing
         * or include scanning. */
        if ((ret = dcc_lock_local_cpp(&local_cpu_lock_fd)) != 0) {
            goto fallback;
        }
    }

    if (host->cpp_where == DCC_CPP_ON_SERVER) {
        /* Perhaps it is not a good idea to preprocess on the server. */
        dcc_perhaps_adjust_cpp_where_and_protover(input_fname, host,
                                                  discrepancy_filename);
    }
    if (dcc_scan_includes) {
        ret = dcc_approximate_includes(host, argv);
        goto unlock_and_clean_up;
    }
    if (host->cpp_where == DCC_CPP_ON_SERVER) {
        if ((ret = dcc_talk_to_include_server(argv, &files))) {
            /* Fallback to doing cpp locally */
            /* It's unfortunate that the variable that controls that is in the
             * "host" datastructure, even though in this case it's the client
             * that fails to support it,  but "host" is what gets passed
             * around in the client code. We are, in essence, throwing away
             * the host's capability to do cpp, so if this code was to execute
             * again (it won't, not in the same process) we wouldn't know if
             * the server supports it or not.
             */
            rs_log_warning("failed to get includes from include server, "
                           "preprocessing locally");
            if (dcc_getenv_bool("DISTCC_TESTING_INCLUDE_SERVER", 0))
                dcc_exit(ret);
            host->cpp_where = DCC_CPP_ON_CLIENT;
            dcc_get_protover_from_features(host->compr,
                                           host->cpp_where,
                                           &host->protover);
        } else if (local_cpu_lock_fd != -1) {
            /* Include server succeeded. */
            /* We're done with local "preprocessing" (include scanning). */
            dcc_unlock(local_cpu_lock_fd);
            /* Don't try to unlock again in dcc_compile_remote. */
            local_cpu_lock_fd = -1;
        }

    }

    if (host->cpp_where == DCC_CPP_ON_CLIENT) {
        files = NULL;

        if ((ret = dcc_cpp_maybe(argv, input_fname, &cpp_fname, &cpp_pid) != 0))
            goto fallback;

        /* localcpp_server_argv may already be processed from a previous bad host */
        if (localcpp_server_argv == NULL) {
            if ((ret = dcc_strip_local_args(argv, &localcpp_server_argv)))
                goto fallback;
        }
        server_side_argv = localcpp_server_argv;
    } else {
        cpp_fname = NULL;
        cpp_pid = 0;
        /* remotecpp_server_argv may already be processed from a previous bad host */
        if (remotecpp_server_argv == NULL) {
            char *dotd_target = NULL;
            dcc_get_dotd_info(argv, &deps_fname, &needs_dotd,
                              &sets_dotd_target, &dotd_target);
            if (deps_fname && !dcc_sane_env_path(deps_fname)) {
                rs_log_warning("ignoring malformed dependency filename "
                                "derived from -MF/DEPENDENCIES_OUTPUT");
                free(deps_fname);
                deps_fname = NULL;
                needs_dotd = 0;
            }
            if ((ret = dcc_copy_argv(argv, &remotecpp_server_argv, 2)))
                goto fallback;
            if (needs_dotd && !sets_dotd_target) {
               dcc_argv_append(remotecpp_server_argv, strdup("-MT"));
               if (dotd_target == NULL)
                   dcc_argv_append(remotecpp_server_argv, strdup(output_fname));
               else
                   dcc_argv_append(remotecpp_server_argv, strdup(dotd_target));
            }
        }
        server_side_argv = remotecpp_server_argv;
    }
    if ((ret = dcc_compile_remote(server_side_argv,
                                  input_fname,
                                  cpp_fname,
                                  files,
                                  output_fname,
                                  needs_dotd ? deps_fname : NULL,
                                  server_stderr_fname,
                                  cpp_pid, local_cpu_lock_fd,
                  host, status, &remote_unsupported)) != 0) {
        /* Returns zero if we successfully ran the compiler, even if
         * the compiler itself bombed out. */

        if (remote_unsupported) {
	    /* Local files are necessary for compilation of the *preprocessed*
	     * source (i.e. due to .incbin assembler directive). */
	    goto fallback_unsupported;
	}

        /* dcc_compile_remote() already unlocked local_cpu_lock_fd. */
        local_cpu_lock_fd = -1;
        bad_host(host, &cpu_lock_fd, &local_cpu_lock_fd);
        retry_count++;
        if (max_retries == 0 || retry_count < max_retries)
            goto choose_host;
        else {
            rs_log_warning("Couldn't find a host in %d attempts, retrying locally",
                           retry_count);
            goto fallback;
	}
    }
    /* dcc_compile_remote() already unlocked local_cpu_lock_fd. */
    local_cpu_lock_fd = -1;

    dcc_enjoyed_host(host);

    dcc_unlock(cpu_lock_fd);
    cpu_lock_fd = -1;

    ret = dcc_critique_status(*status, "compile", input_fname, host, 1);
    if (ret == 0) {
        /* Try to copy the server-side errors on stderr.
         * If that fails, even though the compilation succeeded,
         * we haven't managed to give these errors to the user,
         * so we have to try again.
         * FIXME: Just like in the attempt to make a temporary file, this
         * is unlikely to fail, if it does it's unlikely any other
         * operation will work, and this makes the mistake of
         * blaming the server for what is (clearly?) a local failure.
         */
        if ((dcc_copy_file_to_fd(server_stderr_fname, STDERR_FILENO))) {
            rs_log_warning("Could not show server-side errors");
            goto fallback;
        }
        /* SUCCESS! */
        goto clean_up;
    }
    if (ret < 128) {
        /* Remote compile just failed, e.g. with syntax error.
           It may be that the remote compilation failed because
           the file has an error, or because we did something
           wrong (e.g. we did not send all the necessary files.)
           Retry locally. If the local compilation also fails,
           then we know it's the program that has the error,
           and it doesn't really matter that we recompile, because
           this is rare.
           If the local compilation succeeds, then we know it's our
           fault, and we should do something about it later.
           (Currently, we send email to an appropriate email address).
        */
        if (getenv("DISTCC_SKIP_LOCAL_RETRY")) {
            /* don't retry locally. We'll treat the remote failure as
               if it was a local one. But if we can't get the failures
               then we need to retry regardless.
            */
            if ((dcc_copy_file_to_fd(server_stderr_fname, STDERR_FILENO))) {
                rs_log_warning("remote compilation of '%s' failed",\
                               input_fname);
                rs_log_warning("Could not show server-side errors, retrying locally");
                goto fallback;
            }
            /* Not retrying */
            goto clean_up;
        } else {
            rs_log_warning("remote compilation of '%s' failed, retrying locally",
                           input_fname);
            remote_ret = ret;
            goto fallback;
        }
    }


  fallback:
    bad_host(host, &cpu_lock_fd, &local_cpu_lock_fd);

    if (!dcc_getenv_bool("DISTCC_FALLBACK", 1)) {
        rs_log_error("failed to distribute and fallbacks are disabled");
        /* Try copying any server-side error message to stderr;
         * If we fail the user will miss all the messages from the server; so
         * we pretend we failed remotely.
         */
        if ((dcc_copy_file_to_fd(server_stderr_fname, STDERR_FILENO))) {
            rs_log_error("Could not print error messages from '%s'",
                         server_stderr_fname);
        }
        goto clean_up;
    }

    /* At this point, we can abandon the remote errors. */

    /* "You guys are so lazy!  Do I have to do all the work myself??" */
    if (host) {
        rs_log(RS_LOG_WARNING|RS_LOG_NONAME,
               "failed to distribute %s to %s, running locally instead",
               input_fname ? input_fname : "(unknown)",
               host->hostdef_string);
    } else {
        rs_log_warning("failed to distribute, running locally instead");
    }

    fallback_unsupported:
    if (remote_unsupported) {
        rs_log_warning("%s: can't distribute due to unsupported directives, running locally",
                       input_fname ? input_fname : "(unknown)");
    }

  lock_local:
    dcc_read_localslots_configuration();
    if (ret == EXIT_LOCAL_CPP) {
        dcc_lock_local_cpp(&local_cpu_lock_fd);
    } else {
        dcc_lock_local(&cpu_lock_fd);
    }

  run_local:
    /* Either compile locally, after remote failure, or simply do other cc tasks
       as assembling, linking, etc. */
    ret = dcc_compile_local(argv, input_fname);
    if (remote_ret != 0) {
        if (remote_ret != ret) {
            /* Oops! it seems what we did remotely is not the same as what we did
              locally. We normally send email in such situations (if emailing is
              enabled), but we attempt an a time analysis of source files in order
              to avoid doing so in case source files we changed during the build.
            */
            (void) dcc_please_send_email_after_investigation(
                input_fname,
                deps_fname,
                discrepancy_filename);
        } else if (host) {
            /* Remote compilation failed, but we failed to compile this file too.
             * Don't punish that server, it's innocent.
             */
            dcc_enjoyed_host(host);
        }
    }

  unlock_and_clean_up:
    if (cpu_lock_fd != -1) {
        dcc_unlock(cpu_lock_fd);
        cpu_lock_fd = -1; /* Not really needed, just for consistency. */
    }
    /* For the --scan_includes case. */
    if (local_cpu_lock_fd != -1) {
        dcc_unlock(local_cpu_lock_fd);
        local_cpu_lock_fd = -1; /* Not really needed, just for consistency. */
    }

  clean_up:
    dcc_free_argv(argv);
    if (remotecpp_server_argv != NULL) {
        dcc_free_argv(remotecpp_server_argv);
    }
    if (localcpp_server_argv != NULL) {
        free(localcpp_server_argv);
    }
    free(discrepancy_filename);
    return ret;
}

/*
 * argv must be dynamically allocated.
 * This routine will deallocate it.
 */
int dcc_build_somewhere_timed(char *argv[],
                              int sg_level,
                              int *status)
{
    struct timeval before, after, delta;
    int ret;

    if (gettimeofday(&before, NULL))
        rs_log_warning("gettimeofday failed");

    ret = dcc_build_somewhere(argv, sg_level, status);

    if (gettimeofday(&after, NULL)) {
        rs_log_warning("gettimeofday failed");
    } else {
        /* TODO: Show rate based on cpp size?  Is that meaningful? */
        timeval_subtract(&delta, &after, &before);

        rs_log(RS_LOG_INFO|RS_LOG_NONAME,
               "elapsed compilation time %lld.%06lds",
               (long long) delta.tv_sec, (long) delta.tv_usec);
    }

    return ret;
}
