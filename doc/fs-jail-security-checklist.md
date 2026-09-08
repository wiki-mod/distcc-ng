# Filesystem jail for pump-mode compile jobs (issue #289)

This is the living checklist and design record for distccd's Linux
filesystem jail: a kernel-enforced containment boundary around a server-side
(pump-mode) compile job's directory tree, on top of the include-server's
symlink mirroring, issue #95/#292's `link_target` validation, and the seccomp
sandbox.

It tracks the full plan from issue #289 (the maintainer's 100-section
implementation plan, comment dated 2026-08-10) point by point, so that no
case is silently discovered missing after a merge. Sections are grouped and
marked `[x]` (done in the current implementation), `[~]` (partial), or `[ ]`
(not started). "Phase 1" is the first landable slice; the large remainder is
explicitly future work.

## Scope and threat model

- **What it is:** even a successful symlink escape (issue #95's shape, or one
  not yet found) cannot reach anything outside the job's own tree plus a
  fixed, server-controlled read-only system allowlist, because the OS mount
  namespace, not per-path string validation, enforces the boundary.
- **What it is not:** it is a *filesystem* boundary only. It does not by
  itself bound CPU, memory, PIDs, disk, or the network (plan sections 38/39).
  Those remain the seccomp sandbox's / the OS's concern and are out of this
  feature's scope; do not treat "filesystem jail" as "full sandbox".
- **Platform:** Linux only. macOS/FreeBSD get a compiled no-op stub
  (`doc/compatibility-policy.md`); real backends there (sandbox-exec / jails)
  are a separate, unstarted effort (plan section 55).
- **Default:** off. The jail is opt-in via `distccd.conf`'s `fs-jail` key, so
  no existing deployment changes behaviour by upgrading.

## Trust model: the difference from the #289 prototype

The prototype (`dev/issue289_fs_jail_prototype`, kept frozen as a documented
proof-of-concept, never merged) derived its bind-mount set by walking the
job's client-supplied symlink farm and `realpath()`-resolving each link. Plan
section 5.1 forbids exactly that: a trust decision must not be made from
client input. The production implementation (`src/fs-jail.c`) instead mounts a
fixed, server-controlled allowlist of read-only system roots
(`/usr`, `/lib`, `/lib64`, `/bin`, `/sbin`), a minimal set of `/etc` and
`/dev` entries, and the job directory read-write; the include-server's
symlinks still resolve because the real system directories they target are
present, but a symlink pointing anywhere else simply finds nothing there.
`dcc_fs_jail_path_within_root()` performs the containment check at a real path-
component boundary (never a `strncmp` prefix), and is unit-tested by
`src/h_fs_jail.c` / `FsJailPathContainment_Case`.

## Configuration and fail modes (plan section 53)

`distccd.conf`'s `fs-jail` key (read once at daemon start, see
`src/sandbox-config.c`):

- `off` (default) — no jail; behaviour unchanged.
- `optional` — attempt the jail; if setup fails *before* the point of no
  return (`pivot_root`), log a warning and run the compile unjailed
  (fail-open). A failure *after* `pivot_root` always refuses the compile.
- `required` — attempt the jail; any setup failure refuses the compile
  (fail-closed).

The pre/post-`pivot_root` split is what makes `optional` safe: before the
pivot the process still sees the real root, so proceeding unjailed is
harmless; after it, the compiler would run in a half-built jail, so the
compile must fail regardless of mode.

## Verification status (issue #289, phase 1)

All runs inside `ghcr.io/wiki-mod/distcc-ng-buildtools` (rule 87) unless noted.

- [x] Clean build with `--with-seccomp`, no new warnings under `-Werror`.
- [x] `FsJailPathContainment_Case` / `h_fs_jail`: containment primitive unit
  test passes (exact match, real descendants, prefix tricks, root, NULLs).
- [x] `fs-jail = off`: `pump-single-test TESTNAME=CompileHello_Case` passes
  (no regression to the normal path).
- [x] `fs-jail = required`, mount unavailable: the daemon refuses the compile
  (fail-closed proven).
- [x] `fs-jail = optional`, mount unavailable: the daemon logs the failure,
  proceeds unjailed, and the compile completes (exit 0) with the output object
  allocated inside `temp_dir` (fail-open and the temp_o/deps relocation of
  plan sections 2.3/2.4 both exercised).
- [ ] **Jail happy path** (bind-mounts succeed, `pivot_root` engages, compile
  completes through the jail): NOT yet verified. The buildtools container's
  root is overlayfs, and bind-mounting an overlay subtree inside an
  unprivileged user namespace fails with `EINVAL` (`mount --bind` from
  util-linux fails identically, confirming this is an environment limit, not a
  code defect). This path needs a runner with a non-overlay root filesystem
  (a bare Linux host or a non-container CI job); wiring that is tracked as
  remaining work below.

### Known behaviour to revisit

- The jail's own `rs_log_warning`/`rs_trace` messages during a compile are
  captured into the client-returned stderr (via `dcc_add_log_to_file()`),
  the same as the seccomp sandbox's messages. Under a strict "compiler
  produced no stderr" check this shows up as noise. Whether server-side jail
  diagnostics should reach the client at all is a broader question that also
  touches seccomp (plan sections 95/96).
- A failed read-only *remount* of a system root (`/usr` etc.) in
  `dcc_jail_bind_mount()` is logged as a warning and the compile proceeds,
  even under `fs-jail = required` -- the root then stays bound read-write onto
  the host inode. Maintainer decision (2026-09-08): keep
  the compile working; compile availability outranks this hardening layer, and
  for a non-root `distccd` the real file uid still bounds the write (the host
  `/usr` is not writable by the daemon's own uid regardless). The residual
  risk only matters if `distccd` runs as real root, where the mapped-root
  compiler could then modify the host root; that is deferred to the later
  security audit rather than made fatal here.

## The full #289 plan, tracked

Grouped from the 100-section plan. `[x]`/`[~]`/`[ ]` = done/partial/not
started in the current implementation.

### Foundations
- [x] 1. Freeze and document the prototype (this file; the prototype branch).
- [x] 2.1 One unambiguous job root (the existing `temp_dir`).
- [~] 2.2 Identify all output artifacts (`.o`/`.d`/`.dwo` handled; `.gcda`/
  `.gcno`/PCH/LTO temporaries not yet audited).
- [x] 2.3 `temp_o` created inside the job root when jailed.
- [x] 2.4 `deps_fname` created inside the job root when jailed.
- [x] 2.5 Controlled `/tmp` (fresh private tmpfs) inside the jail; `/dev/shm`
  likewise (plan section 89).
- [~] 2.6 Job-root lifecycle (creation/populate reuse existing distccd flow;
  explicit teardown auditing pending).

### Mount architecture
- [x] 3.1/3.2 Mount + user namespace via `unshare(CLONE_NEWNS|CLONE_NEWUSER)`.
- [x] 3.3 UID/GID mapping to namespace root only.
- [x] 3.4 Private mount propagation (`MS_REC|MS_PRIVATE`).
- [x] 3.5/3.6 Dedicated jail root + `pivot_root`.
- [~] 3.7 Verify the old root is really gone (detached via `umount2`; explicit
  `mountinfo`/`/proc/self/root` assertions are a pending test).

### Trust model
- [x] 5.1 Do not derive mounts from client symlinks.
- [x] 5.2 Server-controlled allowed-root set.
- [x] 5.3/5.4 `realpath` + component-boundary containment (no prefix tricks).
- [ ] 5.5/5.6 Explicit symlink-chain / symlink-loop tests (`realpath` handles
  `ELOOP`; dedicated tests pending).

### Toolchain, devices, /proc, /etc  (largely future work — plan section 6+)
- [~] 6 Toolchain discovery (system gcc covered via `/usr`,`/lib*`; clang
  resource dir, cross toolchains, multilib, `ccache`/`sccache` wrappers not
  yet covered).
- [x] 7 `/dev`: minimal nodes only (`null`/`zero`/`full`/`random`/`urandom`),
  never the host `/dev`.
- [x] 8 `/proc`: deliberately absent.
- [x] 9 `/sys`: absent.
- [~] 70 `/etc`: minimal entries only (`ld.so.cache`/`ld.so.conf`/
  `ld.so.conf.d`/`alternatives`), never whole `/etc`.

### FD, seccomp ordering, immutability
- [x] 10 File-descriptor hygiene: every inherited fd above stderr is closed
  before exec (close_range / bounded loop). Dedicated leak *tests* pending
  (verification phase).
- [x] 11 Seccomp installed after the jail is built (ordering invariant in
  `dcc_inside_child`).
- [~] 12 Compiler cannot modify the jail (relies on the seccomp denylist;
  dedicated post-exec assertion pending).

### Behavioural and security test suites  (future — plan sections 13-100)
- [ ] 13/14 Plain and pump compile matrices (gcc/g++/clang/clang++).
- [ ] 15-18 Include-path, dependency-file, debug-info, output-path cases.
- [ ] 19-25 Error/crash/disconnect/timeout/parallelism/race handling.
- [ ] 26/60/68 Automated #95/#292 escape regressions and host canaries.
- [ ] 27-37 Hardlinks, rename/openat boundaries, TOCTOU, permissions,
  ownership, mount/process-leak tests.
- [ ] 43-51 Plugins/LTO/linker variants/multilib/large-and-many-files.
- [ ] 52/97 Structured jail error codes and diagnosable logging.
- [ ] 56/57 `dcc_discard_root()` sequence + privilege-drop regression tests.
- [ ] 64/65/66 CI wiring, performance comparison, deployment/container matrix.
- [~] 72-82 Environment and argument attack surface: `LD_PRELOAD`/
  `LD_LIBRARY_PATH`/`SSH_AUTH_SOCK` are stripped before exec (73/82/94), and
  the mount boundary neutralises host-path `-B`/`--sysroot`/`-L`/`-I` (a path
  not on the allowlist is simply absent in the jail) while `serve.c` already
  rejects `-fplugin`/`-specs`. A broader env sweep and explicit per-flag
  argument tests remain (verification phase).
- [ ] 83-89 ELF security probe, ptrace/proc/signal/IPC/shm containment.
- [ ] 90-94 Job-dir naming/race/permissions, environment sanitisation.
- [ ] 55 macOS/FreeBSD backends.
- [ ] AppArmor interaction: the `deny mount,` finding needs a host with an
  active AppArmor LSM to re-verify; not reproducible where AppArmor is absent.
