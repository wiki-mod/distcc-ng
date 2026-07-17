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

#include "sandbox-config.h"

/**
 * Resolve the effective denylist (built-in list, plus config's
 * `extra-deny`, minus config's `allow-override`) and the network-syscall
 * group used by `deny-network`, and cache the config's enabled/
 * deny-network/fail-open flags for dcc_seccomp_sandbox_child() to consult
 * on every fork without re-reading the config or re-resolving any syscall
 * name.
 *
 * Must be called exactly once at daemon startup (see src/daemon.c's
 * main()), after dcc_seccomp_config_load() and before the first remote
 * compile can be spawned. Logs a warning at startup (not per-compile) for
 * every `allow-override` entry that actually removed a built-in syscall,
 * and for every `extra-deny`/`allow-override` name that doesn't resolve to
 * a real syscall on this architecture/libseccomp version -- see
 * sandbox-seccomp.c for why validating and resolving once here, rather
 * than per forked child, keeps both the log output and the per-compile
 * cost sane.
 **/
void dcc_seccomp_configure(const struct dcc_seccomp_config *cfg);

/**
 * Restrict the calling process to the effective Linux seccomp syscall
 * denylist computed by dcc_seccomp_configure(), if this build was
 * configured with libseccomp support (`--with-seccomp` /
 * `configure.ac`'s HAVE_SECCOMP detection) and the config's `enabled` key
 * (default true) hasn't turned the sandbox off entirely.
 *
 * Must be called in the forked child that is about to exec() a
 * client-supplied compiler for a remote job (see dcc_inside_child() in
 * exec.c), after any setup in that child that still needs a blocked
 * syscall (fd redirection, etc.) and before the exec -- the filter
 * survives execve() and constrains the compiler process itself, which is
 * the actual point of this sandbox.
 *
 * Returns 0 if the caller may proceed to exec the compiler: either the
 * filter installed successfully, the config disabled the sandbox
 * entirely (`enabled = false`), or installation failed but the config's
 * `fail-open` (default true) says to proceed unsandboxed anyway. Returns
 * -1 only when installation failed *and* the config says `fail-open =
 * false` -- the caller must refuse the compile rather than exec it
 * unsandboxed; see dcc_inside_child() in exec.c for how that refusal is
 * surfaced as an ordinary compile failure rather than a new ad hoc error
 * path.
 **/
int dcc_seccomp_sandbox_child(void);

/**
 * Log, once at daemon startup, whether the seccomp sandbox above is
 * actually available on this build/host. Intended to be called from
 * distccd's main() so an administrator relying on this hardening layer
 * notices immediately if it silently isn't active, rather than only
 * discovering it later from a security audit.
 **/
void dcc_seccomp_log_availability(void);

#endif /* _DISTCC_SANDBOX_SECCOMP_H */
