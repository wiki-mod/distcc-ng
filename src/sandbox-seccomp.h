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

/* sandbox-seccomp.c */

#ifndef _DISTCC_SANDBOX_SECCOMP_H
#define _DISTCC_SANDBOX_SECCOMP_H

/**
 * Restrict the calling process to a curated Linux seccomp syscall
 * denylist, if this build was configured with libseccomp support
 * (`--with-seccomp` / `configure.ac`'s HAVE_SECCOMP detection).
 *
 * Must be called in the forked child that is about to exec() a
 * client-supplied compiler for a remote job (see dcc_inside_child() in
 * exec.c), after any setup in that child that still needs a blocked
 * syscall (fd redirection, etc.) and before the exec -- the filter
 * survives execve() and constrains the compiler process itself, which is
 * the actual point of this sandbox.
 *
 * Never fails the caller: if libseccomp is unavailable at build time, or
 * filter installation fails at runtime (unsupported/misconfigured
 * kernel), this logs a warning and returns without restricting anything,
 * so a single incompatible host cannot turn every remote compile into a
 * hard failure. See sandbox-seccomp.c for the full fail-open rationale.
 **/
void dcc_seccomp_sandbox_child(void);

/**
 * Log, once at daemon startup, whether the seccomp sandbox above is
 * actually available on this build/host. Intended to be called from
 * distccd's main() so an administrator relying on this hardening layer
 * notices immediately if it silently isn't active, rather than only
 * discovering it later from a security audit.
 **/
void dcc_seccomp_log_availability(void);

#endif /* _DISTCC_SANDBOX_SECCOMP_H */
