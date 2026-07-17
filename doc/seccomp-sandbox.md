# `distccd`'s Linux seccomp sandbox

This document describes the optional Linux seccomp syscall sandbox `distccd`
installs around a remote client's compiler child process (issue #68, PR
#171), and the runtime configuration surface added on top of it (issue #192).

## What this protects against, and what it doesn't

Previously, a remote client's compile job ran with the daemon's own full
process privileges: a compromised or malicious client-supplied compile job
had no containment beyond the argv-level checks `src/serve.c` already
performs (compiler whitelist, `-fplugin=`/`-specs=` rejection, compiler
masquerade check). `distccd` now installs a curated Linux seccomp syscall
**denylist** (`src/sandbox-seccomp.c`) in the forked child, immediately
before it execs the client-supplied compiler. The filter survives
`execve()`, so it constrains the compiler process itself, not just the fork
that leads up to it.

This is explicitly **defense-in-depth layered on top of** the existing
whitelist/masquerade/unsafe-option checks in `src/serve.c`, not the sole
boundary between a hostile client and the host:

- **Denylist, not allowlist.** `distccd` has to run whatever compiler a
  client names (gcc, clang, any cross-compiler), each of which may itself
  fork further sub-processes (cc1, as, ld, collect2, LTO plugins).
  Enumerating a syscall allowlist complete enough to cover all of that,
  for every compiler this fork's users might point `distccd` at, is not
  something that can be verified by testing one compiler locally. This
  denylist instead targets syscalls no legitimate compiler invocation
  needs — it is weaker as a security boundary than a true allowlist, but
  it's something that can actually be validated end-to-end against a real
  compile.
- **Network syscalls are not part of the built-in denylist.** A malicious
  compile could attempt to reach the network the daemon itself can reach,
  unless the admin turns on `deny-network` (below).
- **`ptrace`/introspection primitives, kernel/module tampering, raw
  hardware access, kernel keyring/eBPF/perf, and host clock/identity
  syscalls** are always denied (unless explicitly removed via
  `allow-override`, below) — see the built-in list in the example config
  file further down, which is kept in sync with
  `dcc_seccomp_denied_syscalls[]` in `src/sandbox-seccomp.c`.

### Important limitation: `deny-network` is a binary switch, not a policy engine

`deny-network = true` denies the entire group of network-establishing/
data-transfer syscalls (`socket`, `connect`, `sendto`, `recvfrom`, `bind`,
`listen`, `accept`, `accept4`, `socketpair`, `sendmsg`, `recvmsg`,
`sendmmsg`, `recvmmsg`, `shutdown`) outright for the sandboxed compiler
child. It is **all-or-nothing**.

A finer-grained policy — e.g. "only allow connections within the same
subnet" — is **not achievable via this mechanism, and is explicitly out of
scope**: seccomp/BPF filters can only inspect the syscall number and scalar
arguments, never the contents of a pointer argument like `connect()`'s
`sockaddr *`. Implementing a destination-aware restriction would need a
materially different mechanism entirely (a network namespace plus routing
restriction, or per-process iptables/nftables rules), and is not attempted
here. Do not read `deny-network` as anything more precise than "no
networking at all for this compile."

## Configuration: `/etc/distcc/seccomp.conf`

The sandbox's runtime behavior is controlled by an optional, minimal
`key = value` config file read once at `distccd` startup (before the first
remote compile can be spawned). It is deliberately **not** built on popt's
alias/config mechanism — that is a macro/shortcut system requiring explicit
command-line invocation, not a "silently apply defaults from a file"
mechanism, so it was not a clean fit.

- **Location**: `/etc/distcc/seccomp.conf` (fixed; not currently
  configurable via a command-line flag — see "Precedence" below).
- **Format**: simple `key = value` lines. `#`-prefixed lines and blank
  lines are ignored. No includes, no variable interpolation, no nested
  structures — deliberately minimal, matching the small, fixed set of keys
  below.
- **If absent, empty, or comment-only**: every key falls back to its
  documented default. This is not an error and does not prevent `distccd`
  from starting.
- **Permissions**: checked when the file is present. A world-writable file
  logs a warning (any local user could otherwise silently change the
  sandbox's effective behavior for a privileged `distccd`) but is still
  read and used — the daemon does not refuse to start over a config file's
  permissions. This follows the same defense-in-depth spirit as this
  codebase's existing world-writable-file-creation finding class
  (issue #157 / PR #158).

### Precedence

**Config file value > compiled-in default.**

This pass implements config-file-only configuration; it does **not** add
matching `distccd` command-line flags. Issue #192 allowed for CLI flags
"if it turns out to be natural", but doing so for all six keys (including
the two comma-separated list keys) would have meant a second, parallel
input path with its own precedence-merging logic for every key, which is
significant scope beyond the config file itself. **CLI flags remain a
documented, explicitly deferred follow-up**, not an oversight — if added
later, the precedence would become CLI flag > config file value > compiled
default, per issue #192's original design note.

### Recognized keys

The reference file below is what this fork ships/documents as the
canonical example. Five of its six keys (`extra-deny`, `allow-override`,
`enabled`, `deny-network`, `fail-open`) are issue #192's maintainer-approved
design, reproduced verbatim. `require-seccomp` is a sixth key added after
#192 (a separate, later maintainer decision, not part of #192 itself) — see
its own explanation below the file.

```
## /etc/distcc/seccomp.conf
# # are comments. Blank lines are ignored.
# Missing keys fall back to these same built-in defaults.
# Boolean values: true/false (case-insensitive). No other spellings accepted.

## --- Built-in denylist (always active unless removed via allow-override) ---
### kernel/module tampering:
#   reboot, init_module, finit_module, delete_module,
#   kexec_load, kexec_file_load, mount, umount2, pivot_root,
#   swapon, swapoff, quotactl, acct
#
### raw hardware access:
#   iopl, ioperm
#
## introspection/escape primitives:
#   ptrace, process_vm_readv, process_vm_writev, kcmp,
#   setns, unshare, personality
#
# kernel keyring/eBPF/perf:
#   add_key, request_key, keyctl, bpf, perf_event_open
#
## host clock/identity:
#   settimeofday, clock_settime, adjtimex, clock_adjtime,
#   sethostname, setdomainname
# ---------------------------------------------------------------------

## Additional Syscall Allow/Deny-Calls
#
# Additional syscalls to deny, beyond the built-in list above.
# Comma-separated syscall names.
# Default: empty.
extra-deny =
# Remove specific syscalls from the built-in list above, if a
# legitimate compiler/toolchain genuinely needs one of them.
# Comma-separated. WARNING: weakens the sandbox — every removal is
# logged at startup.
# Default: empty (full built-in list stays active).
allow-override =

## Enable or disable Sandbox
# even if distccd was built with --with-seccomp.
# Default: true (sandbox active).
enabled = true

## Sandbox Behavior
#
# Block all network syscalls (socket/connect/sendto/...) in the
# sandboxed compiler child.
# Default: false (network unrestricted).
deny-network = false

## Compile or not to Compile, this is the question!
#
# If the sandbox fails to install (unsupported kernel, libseccomp
# error, etc.) on a distccd that WAS built with libseccomp support, let
# the compile proceed unsandboxed (fail-open) instead of refusing it
# (fail-closed). Fail-closed means the compile will fail when the
# sandbox can't be established while being enforced. Has no effect on
# a distccd built without libseccomp support at all -- see
# require-seccomp below for that separate case.
# We tend to compile instead of blocking.
# Default: true.
fail-open = true

## Require the sandbox to exist in the build at all
#
# If this distccd was built WITHOUT libseccomp support in the first
# place (--without-seccomp, or a non-Linux host), refuse every remote
# compile outright instead of running it unsandboxed. A separate,
# independent switch from fail-open above: fail-open is about a
# sandbox that exists but broke at runtime; this is about a sandbox
# that was never compiled in to begin with. Setting this to true does
# not change fail-open's behavior on a host that does have libseccomp,
# and vice versa.
# Default: false (a --without-seccomp build always runs remote
# compiles unsandboxed, unchanged from this fork's behavior before
# this config file existed).
require-seccomp = false
```

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `enabled` | bool | `true` | Master on/off switch for the whole sandbox at runtime, distinct from the `--with-seccomp`/`--without-seccomp` compile-time gate. `false` makes the sandbox a genuine no-op — the compile runs exactly as if `--without-seccomp` had been used. |
| `deny-network` | bool | `false` | `true` additionally denies the network-syscall group (see above) in the sandboxed compiler child. |
| `fail-open` | bool | `true` | `false` (fail-closed) means a sandbox-install failure refuses the compile instead of letting it proceed unsandboxed. Scope is deliberately narrow: this only governs a build that *can* sandbox (compiled with libseccomp, on Linux) failing to install the filter at runtime. It has **no effect** on a build compiled **without** libseccomp at all — see `require-seccomp` for that case. |
| `require-seccomp` | bool | `false` | `true` refuses every remote compile outright if this `distccd` was built **without** libseccomp support in the first place (`--without-seccomp`, or a non-Linux host) — "this host must have the sandbox available at all, don't even try without it." Has **no effect** on a build that does have libseccomp support (there, the sandbox is available regardless of this key — see `fail-open` for what happens if it fails at runtime on such a build). Default `false` preserves this fork's original behavior: a `--without-seccomp` build always runs remote compiles unsandboxed. |
| `extra-deny` | comma-separated syscall names | empty | Additional syscalls to deny, beyond the built-in curated list. Unresolvable names (typo, or a syscall that doesn't exist on this architecture/libseccomp version) log a warning at startup and are skipped — never a hard failure. |
| `allow-override` | comma-separated syscall names | empty | Removes specific syscalls from the built-in curated list, if a legitimate compiler/toolchain genuinely needs one of them. Every syscall actually removed this way is logged by name at startup (not just a count) — deliberately visible, since this weakens the sandbox. |

`fail-open` and `require-seccomp` are independent switches that answer two
different questions and can be set in any combination — e.g. `fail-open =
false` with `require-seccomp = false` means: on a host built with
libseccomp, a runtime sandbox-install failure refuses the compile, but a
host built `--without-seccomp` entirely still runs compiles unsandboxed,
same as always. Neither setting has any effect on the other's build
configuration.

Boolean values accept exactly `true`/`false`, case-insensitively (`True`,
`TRUE`, `false`, `FALSE`, ...). Any other spelling (`yes`, `1`, `on`, ...)
is rejected: the invalid value is logged and the key keeps its default,
rather than silently guessing at what was meant.

### Effective denylist computation

The syscall set actually installed in the sandboxed child is:

```
effective_denylist = built_in_denylist  +  extra-deny  −  allow-override
```

computed once at `distccd` startup (`dcc_seccomp_configure()` in
`src/sandbox-seccomp.c`), not re-parsed per compile. Syscall names are
resolved to kernel syscall numbers at runtime via libseccomp's
`seccomp_syscall_resolve_name()`, exactly like the pre-existing built-in
list — an unrecognized or architecture-missing name degrades to "skip it
and warn", never a build failure or a crash.

## Verification performed

All verification was done in a real Linux environment (WSL2 Debian, per
the same setup PR #171 used) with `libseccomp-dev` installed, following
this repo's `./autogen.sh && ./configure PYTHON=python3 && make && make
check` workflow. See the PR description for exact commands/output.
