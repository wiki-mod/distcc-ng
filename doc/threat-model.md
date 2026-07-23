# Threat model and attack surface analysis

This document is the real threat model referenced by `doc/security-assessment.md`
and required by the OpenSSF Best Practices Baseline's `OSPS-SA-03.02`
("perform threat modeling and attack surface analysis upon release", raised
by issue #267). Unlike `doc/security-assessment.md` (deliberately a minimal
index), this is meant to be read: it enumerates the real actors, trust
boundaries, and attack surface of this codebase, grounded in this project's
own source and its own fixed-vulnerability history, not generic
distributed-build boilerplate.

## Actors

- **`distcc` client** — runs on a developer/CI machine, connects outbound to
  one or more `distccd` hosts, sends a compile command plus preprocessed
  source. Untrusted from `distccd`'s point of view: anyone who can reach a
  `distccd` port and speak the wire protocol is "a client", regardless of
  whether they run a real, unmodified `distcc` binary.
- **`distccd` daemon** — accepts connections, runs the requested compiler
  invocation, returns the result. Trusted by the client (a compromised
  `distccd` can return arbitrary object code to a build), and the *trust
  anchor* this document is mostly about protecting: what should `distccd`
  refuse to do even when a "client" asks for it.
- **Include-server (`pump` mode)** — a separate Python process
  (`include_server/`) that runs on the *client* side, analyzes header
  dependencies, and mirrors a minimal source tree to send to `distccd` for
  server-side preprocessing. Talks to both the local `distcc` client
  invocation and, via the same wire protocol, to `distccd`'s file-receive
  path. Its C extension (`include_server/c_extensions/`) is linked directly
  into that same Python process — a memory-safety bug there is a
  client-side, not server-side, compromise.
- **On-path network attacker** — anyone who can observe or inject on the
  network path between `distcc` and `distccd`. Relevant because of one fact
  stated plainly in `SECURITY.md`: **the wire protocol is not encrypted by
  default** (`doc/tls-transport-design.md` is a design, not yet shipped).
- **Malicious/compromised build input** — a source file, header, or build
  script that a legitimate `distcc` client is asked to compile. This is a
  different actor from "malicious client": here the *client itself* is
  trusted infrastructure, but the code it's told to compile is not (think:
  building an untrusted third-party dependency, or a compromised upstream
  package). `-fplugin=`/`-specs=` handling in `src/serve.c` exists
  specifically because a compiler invocation can itself be turned into
  arbitrary code execution via compiler-level extension mechanisms.

## Trust boundary: what `distccd` does and doesn't trust from a client

`SECURITY.md`'s "Known Security Tradeoffs" section states the top-level
model: `distccd` is built for a trusted LAN/access-controlled network, not
the open internet, and access control (`--allow`/`--listen`) plus privilege
drop (`dcc_discard_root()`) are the primary controls. This section extends
that with the concrete attack surface behind it — what specifically a
network-reachable, protocol-speaking client can and cannot make `distccd` do.

**Not trusted, and defended against on the wire-protocol boundary itself:**

- **File paths and names** (`NAME`/`CDIR`/`LINK` tokens parsed in
  `src/srvrpc.c`). A client fully controls every filename and the working
  directory it claims. `dcc_r_many_files()` (`src/srvrpc.c`) is the
  multi-file receive path pump mode uses to mirror a source tree into the
  daemon's per-job temp directory — and it is the single largest historical
  source of real, fixed vulnerabilities in this fork:
  - **#95 / #289**: an absolute-style `LINK` token's `link_target`
    containing a `..` component could escape the per-job temp directory —
    closed by rejecting `..` in that specific case.
  - **#292 / #293 (CWE-59)**: a *relative* `link_target` (deliberately left
    unvalidated by #95's fix, because pump mode's own legitimate mirroring
    symlinks have the same shape) combined with a second, nested `NAME` in
    the *same* `NFIL` batch let a malicious client create a symlink and then
    write through it — a write-anywhere-the-daemon-can-write primitive that
    a purely textual `..`-check on `NAME` alone could never catch, because
    neither token contained `..`. The fix (`dcc_open_parent_beneath()`,
    `dcc_r_file_beneath()`) stopped trusting path *strings* at all: every
    intermediate path component is now resolved one `openat(..., O_NOFOLLOW)`
    step at a time relative to an fd anchored at the job directory, and any
    component that turns out to be a symlink or non-directory is rejected
    with `EXIT_PROTOCOL_ERROR` instead of silently followed.

  The lesson generalizes: **any place this codebase joins a client-supplied
  string onto a filesystem path and calls a path-based syscall
  (`open()`/`mkdir()`/`symlink()` instead of the `*at()` + `O_NOFOLLOW`
  family) is a candidate for the same CWE-59 class**, not just the two
  fixed instances above. `src/pathsafety.c`'s `dcc_name_has_path_traversal()`
  remains a useful first-line textual check (it is what catches direct
  `NAME`/`CDIR` traversal, and closed the `CDIR` traversal vector on PR #37),
  but #292/#293 is the concrete, empirical proof that a textual check alone
  is not sufficient against a symlink-based escape — component-by-component
  `*at()` resolution is the actual control, the string check is defense in
  depth on top of it.

- **The compiler invocation itself** (`src/compile.c`, `src/serve.c`). A
  client chooses `argv[0]` and every argument. `src/serve.c`'s
  `dcc_run_job()` explicitly refuses `-fplugin=` (arbitrary shared-object
  loading into the compiler process) and heavily restricts `-specs=`
  (only accepted if it resolves, under an explicitly configured sysroot, to
  a real regular file — otherwise refused) before ever exec'ing the
  compiler. Both are compiler-level code-execution primitives that have
  nothing to do with the wire protocol's own parsing; they exist because a
  compiler command line is itself an attack surface once you accept that
  the person choosing it may be hostile.
- **The exec'd compiler process's syscalls** — even after the argv-level
  checks above, `distccd` still execs a real, external compiler binary with
  attacker-chosen arguments. `src/sandbox-seccomp.c`'s optional seccomp
  denylist (see `doc/seccomp-sandbox.md`) is the last line of defense here:
  it runs in the forked child, immediately before exec, and denies a
  curated list of syscalls a legitimate compiler invocation has no
  business making. Its own trust boundary is documented in "Fail-open vs.
  fail-closed" below.

**Explicitly trusted (deliberate design, not an oversight):**

- Anyone who can complete a TCP connection to `distccd`'s port and pass
  `--allow` access control is trusted to submit compile jobs — there is no
  authentication of the *client identity* beyond network-level ACLs.
  `SECURITY.md` states this plainly: `distccd` is LAN/access-controlled-
  network software, not internet-facing software.
- The content of a compile once seccomp/argv checks pass — `distccd` does
  not sandbox the *filesystem contents* the compiler is allowed to read
  once it's running (only which syscalls it's allowed to make), since a
  real build legitimately reads headers, sysroots, and compiler-internal
  data files that can't be enumerated in advance.

## Attack surface enumeration

1. **Wire protocol token parsers** (`src/srvrpc.c`, `src/rpc.c`). Every
   `dcc_r_token_*()` call is a boundary where an attacker fully controls
   the bytes; #95/#292/#293 above are the concrete, fixed proof that this
   surface is real, not theoretical. `src/dopt.c`'s option parsing is a
   *local*, not remote, attack surface (command-line arguments to `distccd`
   itself, not client-controlled) and is out of scope for a remote-attacker
   threat model, but is still worth noting as the place `--job-file-mode`,
   `--allow`, and `--user` are validated (see #293's addition of
   `--job-file-mode`, closing a related gap: per-job files were previously
   created without an explicit, documented permission policy).
2. **`src/bulk.c`'s multi-file receive** — the data-plane counterpart to
   `src/srvrpc.c`'s token parsing; #292/#293's fix touched both files
   because the vulnerable sequence spanned the token-level `NAME`/`LINK`
   parsing (`srvrpc.c`) and the actual file-creation syscalls (`bulk.c`).
   Any future change to either file that reintroduces a plain-string
   `open()`/`mkdir()`/`symlink()` call operating on a client-supplied name,
   instead of the `*at()` + `O_NOFOLLOW` pattern `dcc_open_parent_beneath()`/
   `dcc_r_file_beneath()` established, reopens this exact class of bug.
3. **The seccomp sandbox's fail-open/fail-closed boundary**
   (`src/sandbox-seccomp.c`, configured via `/etc/distcc/seccomp.conf`, see
   `doc/seccomp-sandbox.md`). Two independent switches govern what happens
   when the sandbox *can't* do its job:
   - `fail-open` (default `true`): if a `distccd` build that *has*
     libseccomp support fails to install the filter at runtime (unsupported
     kernel, libseccomp error), the compile still proceeds, unsandboxed.
     This is a deliberate availability-over-security default (a transient
     sandbox-install failure shouldn't take down a whole compile farm), but
     it means an operator who assumes "seccomp is compiled in" therefore
     "every compile is sandboxed" is wrong unless they've also set
     `fail-open = false`.
   - `require-seccomp` (default `false`): governs the *orthogonal* case of
     a `distccd` binary built entirely `--without-seccomp` (or a non-Linux
     host) — by default it still runs remote compiles, unsandboxed, with no
     runtime failure at all to notice.
   Both defaults favor "the compile farm keeps working" over "refuse rather
   than run unsandboxed" — a deliberate tradeoff, but one worth an operator
   consciously overriding (`fail-open = false`, `require-seccomp = true`) on
   a deployment where the compiled input is genuinely untrusted (see the
   "malicious/compromised build input" actor above).
4. **The include-server's Python C extension**
   (`include_server/c_extensions/`, built by `include_server/setup.py`).
   Runs in-process with the Python include-server on the *client* side —
   a memory-safety bug here is a client-machine compromise via a malicious
   header-dependency graph, not a `distccd`-side privilege escalation. It
   is the one piece of this codebase's remote-facing surface written in a
   memory-unsafe language embedded in a memory-managed host process, so a
   bug class here (buffer overflow, use-after-free) has different blast
   radius than a plain Python bug would.
5. **Compiler-argument-level surface** (`src/serve.c`'s `-fplugin=`/
   `-specs=` handling, `src/compile.c`'s option rewriting for
   cross-compilation/masquerade detection). Distinct from the wire-protocol
   parsers above: even a `distccd` that perfectly validates every filename
   and symlink can still be compromised by a compiler command line that
   asks the compiler itself to load attacker-controlled code
   (`-fplugin=`) or configuration (`-specs=`).

## What's mitigated vs. residual risk

**Mitigated, with real evidence:**

- Server-side path-traversal write-escape via `NAME`/`LINK`/`CDIR` tokens:
  closed by `dcc_name_has_path_traversal()` (textual first line) plus
  `dcc_open_parent_beneath()`/`dcc_r_file_beneath()` (the actual
  component-by-component `O_NOFOLLOW` control) — see #95/#289/#292/#293
  above, each with its own regression test (`h_srvrpc`, `PathSafety_Case`).
- Compiler-level code execution via `-fplugin=`: refused outright.
- Compiler-level code execution via `-specs=`: only accepted when it
  resolves to a real file under an explicitly configured sysroot.
- A curated seccomp denylist further restricts the exec'd compiler's own
  syscalls, when enabled and successfully installed.
- Zero-tolerance CodeQL policy on the default branch (`SECURITY.md`'s
  "Continuous static and supply-chain analysis" section) — enforced via a
  repository ruleset, not just aspirational, catching classes of bug like
  the TOCTOU pattern fixed in #268 (`dcc_fresh_dependency_exists()`,
  CodeQL alert #3) before they reach a tagged release.

**Residual risk, stated plainly:**

- **No transport encryption or authentication of client identity.** The
  entire model above assumes an on-path network attacker is *out of scope*
  because `distccd` is deployed on a trusted LAN, per `SECURITY.md`. If
  that assumption is violated — `distccd` exposed to the internet, or run
  on a network shared with untrusted parties, against the documented
  recommendation — every mitigation in this document still holds (the
  path-traversal and compiler-argument fixes don't depend on network
  trust), but two things change substantively:
  1. **Confidentiality/integrity of compile traffic** — source code,
     object code, and compiler diagnostics all cross the network in the
     clear and unauthenticated; an on-path attacker can read or tamper
     with any of it, including substituting a different compiled result
     than the one actually built.
  2. **Who counts as "a client" at all** — `--allow`/`--listen` become the
     *entire* access-control story with no secondary factor, so exposing
     the port to an untrusted network is equivalent to granting compile-job
     submission to anyone who can reach it, not merely "anyone on our LAN".
  This is not a gap this document is claiming to close — it's `doc/tls-
  transport-design.md`'s explicitly *planned, not-yet-shipped* work, and
  the honest current answer for "what if someone exposes distccd to the
  internet" is: don't; if you must, put it behind a VPN/tunnel that
  provides the encryption and authentication this project's own wire
  protocol does not yet provide itself.
- **seccomp's fail-open default.** As described above, the out-of-the-box
  configuration prioritizes farm availability over strict sandboxing on a
  sandbox-install failure. An operator relying on seccomp as a hard
  guarantee against a malicious compile input (rather than defense-in-depth
  against a *compromised* one) needs to explicitly set `fail-open = false`.
- **The include-server's C extension** remains the one part of this
  project's remote-facing-ish surface (it processes data derived from
  files a build touches) written in a memory-unsafe language embedded in a
  host process — CodeQL's `python` and general C analysis both cover it,
  but a targeted fuzzing/hardening pass has not been done specifically for
  this component as of this writing.
- **Any future `srvrpc.c`/`bulk.c` change that reintroduces a plain path-
  string syscall** is the single most likely way this document's central
  fixed vulnerability class (CWE-59 via symlink-following) recurs — it has
  already happened twice in this fork's own history (#95, then the
  residual case in #292/#293) precisely because the first fix addressed
  only the reachable case at the time, not the general pattern.

## See also

- `doc/security-assessment.md` — the index this document is linked from.
- `SECURITY.md` — the top-level tradeoffs this document extends with
  concrete attack-surface detail.
- `doc/seccomp-sandbox.md` — full seccomp configuration reference.
- `doc/tls-transport-design.md` — the planned transport-encryption work
  referenced under "Residual risk" above.
- `CHANGELOG.md`'s dated sections — the full, ongoing record of fixed
  vulnerabilities this document draws its concrete examples from.
