# Verification Checklist

A reusable template for recording *what was actually checked* before a
change lands — not what the diff is claimed to do. Fill in the relevant
sections in the PR description (or a linked comment) for any change that
touches one of the categories below; skip sections that don't apply and
say so explicitly, don't just omit them silently.

This exists because `make check` passing answers "did I break anything
the existing suite already covers", not "does the new/changed behavior
actually do what I claim". Several fixes in this repo's history looked
correct on a diff read and passed CI, but only a real, targeted run
against the actual claimed behavior — often with a *known* expected
result to compare against — caught (or would have caught) that they
didn't. See `AGENTS.md`'s Required Validation section for the standing
rule this checklist operationalizes.

## 0. Baseline (always required)

- [ ] `./autogen.sh && ./configure ... && make` — clean build, no new
      warnings introduced by this change (warnings are errors, not noise
      — see `AGENTS.md`).
- [ ] `make check` — full existing suite passes. This is necessary, but
      **on its own proves nothing about new/changed behavior** — it only
      proves the change didn't break something already covered. Never
      report this alone as "verified."

## 1. Permission / file-mode changes (`open()`/`fopen()` modes, umask handling)

Relevant to: CodeQL `cpp/world-writable-file-creation` fixes, temp-file
handling, anything touching `src/lock.c`, `src/state.c`, `src/zeroconf.c`,
`src/daemon.c`, `src/bulk.c`, `src/dparent.c`, `src/dotd.c`,
`src/traceenv.c`, `src/compile.c`'s discrepancy-file path.

- [ ] Built and tested on a **real filesystem that honors Unix permission
      bits** — not a Windows-hosted WSL2 `/mnt/c/...` (9p/DrvFs) mount,
      which silently ignores mode bits and umask. Use a native WSL ext4
      path or a container.
- [ ] Real multi-user check, not just `stat`/`ls -la` in isolation: as a
      **second, genuinely different Linux user**, attempt to read/write
      each touched file. Confirm files intended to stay cross-user-
      readable (e.g. pid files, state files read by `distccmon-*`,
      zeroconf's discovered-host file) are actually readable by that
      second user, and files intended to be tightened (daemon log,
      lock files, discrepancy counter) actually deny that second user
      with a real "Permission denied", not just an assumption from the
      mode number.
- [ ] If a file's permissions are load-bearing for a documented
      deployment mode (shared `DISTCC_DIR`, `distccmon-*` cross-user
      monitoring, output-must-match-local-compile), confirm the specific
      test that encodes that expectation still passes (e.g.
      `test/testdistcc.py`'s `ModeBits_Case` for `src/bulk.c`'s received-
      output file) — this exact class of change broke that test once
      before (PR #158's first attempt) and was caught by CI, not by
      review.
- [ ] Any instance deliberately left unchanged has its reasoning
      documented in the PR/issue text, not just silently skipped.

## 2. Sandbox / seccomp / process-isolation changes (`src/sandbox-seccomp.c`, `src/sandbox-config.c`)

- [ ] Built with the sandbox actually compiled in (`--with-seccomp` /
      `libseccomp-dev` present) — a build that silently falls back to
      `--without-seccomp` behavior is not a test of the sandbox at all.
- [ ] Confirm the **effective denylist** actually installed at runtime
      matches what the change intends — log the filter's effect (e.g. via
      `dcc_seccomp_configure()`'s startup log line naming
      `extra-deny`/`allow-override` entries), don't just read the source
      and assume the computed set is right.
- [ ] Real positive test: a legitimate remote compile (a real compiler,
      real source file, through a real `distccd`) still succeeds under
      the sandbox as configured.
- [ ] Real negative test: deliberately trigger a syscall the filter is
      supposed to deny (or use `strace`/a minimal test binary that issues
      it) and confirm the sandboxed child is actually killed/blocked, not
      just that the compile happened to work.
- [ ] Check both `fail-open`/`fail-closed` and `require-seccomp` paths if
      touched: a runtime install failure and a `--without-seccomp` build
      are two independent scenarios (see `doc/seccomp-sandbox.md`) — don't
      verify one and assume the other follows.
- [ ] Confirm behavior on a host **without** libseccomp/non-Linux is
      unchanged (no new hard dependency introduced silently — see
      `doc/compatibility-policy.md`).

## 3. Distribution / scheduling behavior changes (`src/arg.c`'s `dcc_scan_args()`, host selection, fallback logic)

Relevant to: any change to what gets distributed vs. forced local
(`-march=native`, `-flto`, `-M*`, etc.), `DISTCC_FALLBACK`,
`DISTCC_HOSTS` parsing, lock/retry logic.

- [ ] A trace-line or single-host reasoning check is **not sufficient on
      its own** — it only proves the code path was reached, not that
      distribution actually did or didn't happen end-to-end.
- [ ] Real two-container (or more) test: a distinct client and server,
      an actual network hop between them, verified from the **server's
      own independent log** (not the client's claim) — see
      `test/e2e/run-e2e.sh`'s pattern of grepping the server log for
      `COMPILE_OK` entries tied to the client's subnet address.
- [ ] A known, predictable expected outcome stated *before* running the
      test (e.g. "the plain file must show exactly 1 remote `COMPILE_OK`;
      the `-flto` file must show 0") — not just "it ran and nothing
      crashed."
- [ ] If the change is meant to force local-only behavior, confirm with
      `DISTCC_FALLBACK=0` (disables the client's silent fallback-to-local
      path in `src/compile.c`) so a failure to correctly skip
      distribution surfaces as a hard error, not a quietly-successful
      local compile that happens to look the same.

### 3a. Compiler identity/family resolution (`argv[0]`/basename comparisons deciding *which physical compiler runs*)

Relevant to: any code that decides "is this gcc or clang", "is this a
cross-compiler", or otherwise branches on a compiler's name or path —
`src/arg.c`'s `dcc_resolve_march_native()`, `src/compile.c`'s
`dcc_add_clang_target()`/`dcc_gcc_rewrite_fqn()`/
`dcc_rewrite_generic_compiler()`, `src/climasq.c`'s masquerade path
matching. Added after issues #78/#278 both touched this exact theme from
opposite directions (one needed the *full path*, not a basename; the
other needed the *basename*, not the raw path) in the same review round.

- [ ] Test with a real dispatcher/wrapper binary that is **not** named
      after the compiler family it actually is (e.g. a `#!/bin/sh; exec
      /usr/bin/clang "$@"` script called `mycompiler`, or a real
      cross-toolchain-prefixed name like `arm-linux-gnueabihf-gcc`) — a
      bare, obviously-named invocation (`gcc`, `clang-19`) cannot
      distinguish "matches by basename" from "matches by raw `argv[0]`"
      bugs, since both happen to agree when there's no path and no
      family-obscuring name involved.
- [ ] If the fix execs or PATH-searches using the resolved name (not just
      appending a flag), verify a directory-qualified original invocation
      (e.g. `/opt/toolchain/bin/gcc`) still resolves to a binary in *that*
      directory, not wherever `$PATH` happens to point — a rewrite that
      drops the caller's directory can silently swap in a different
      toolchain's same-named binary.
- [ ] `docker/verify/`'s current toolchain does **not** include a real
      cross-compiler (no `arm-linux-gnueabihf-gcc`-style package) — this
      category's real-toolchain testing currently requires an external
      host or a hand-built fake dispatcher script, not the verification
      container. Note this limitation explicitly rather than silently
      working around it if you hit it again.

## 4. External-host / network compatibility changes

Relevant to: protocol changes, compiler masquerade/rewrite logic
(`dcc_gcc_rewrite_fqn` and similar), anything that could affect
interop with a distccd this fork didn't build.

Round-tripping distcc-ng against itself only proves internal
consistency, not compatibility — that needs **both** directions of the
matrix below tested, not just one. A change that only breaks one
direction (e.g. our client mis-negotiating against a stock server, or
our server mishandling a stock client's requests) can pass a one-
directional test cleanly and still be a real interop break — this is
exactly the shape of bug #225 turned out to be (a distcc-ng client
against a distcc-ng-but-`--without-zstd` server).

- [ ] **Direction A — our client, a real independently-built server**:
      distcc-ng's `distcc` against a **real, independently-built
      `distccd`** (e.g. a stock distro package, not this fork's own
      binary).
- [ ] **Direction B — a real independently-built client, our server**:
      a **real, independently-built `distcc`** (stock distro package)
      against distcc-ng's `distccd`. Don't assume symmetry with
      Direction A — client-side and server-side code paths differ, and
      a fix/regression can be one-directional.
- [ ] Each direction gets its own **real, non-trivial compile load** (an
      actual third-party C project, not a single hello-world file) with
      real parallelism, so protocol edge cases (large files, many
      concurrent jobs, varied compiler flags) get real exercise — not
      just a trivial connectivity check.
- [ ] `DISTCC_FALLBACK=0` for the same reason as above: if the whole
      build succeeds with fallback disabled, that's strong evidence every
      compiled file really round-tripped through the remote host.
- [ ] Never hardcode the test host's IP/hostname into a committed file —
      use a placeholder in docs and keep the real value only in the
      local test session (see `AGENTS.md`'s Secrets And Sensitive Data
      rule).

## 5. Downloaded external source / artifacts used in a test

- [ ] Verify the artifact's checksum against the **upstream project's own
      published value** (not just "it downloaded without error") before
      using it as a compile workload or dependency in a verification run.
      Fetch the checksum from a second, independent URL/mirror if one
      exists, rather than trusting a single source.

## 6. Config file / settings changes (`src/config-parser.c`, `distccd.conf`, `distcc.conf`, precedence between a config file and an environment variable)

Relevant to: adding or changing a key in `/etc/distcc/distccd.conf` or
`/etc/distcc/distcc.conf`, anything touching `src/config-parser.c`,
`src/sandbox-config.c`, `src/client-config.c`.

- [ ] Real functional test of the setting itself with a real config file
      on disk, not just a unit-level "the parser accepts this string"
      check — start the real client/daemon and confirm the setting's
      actual downstream effect (e.g. a trace line, a changed exit code, a
      changed file mode), the same bar as section 1/3's real-evidence
      requirement.
- [ ] If the setting has both a config-file key and an environment
      variable, confirm the **actual precedence** in both directions with
      real runs: env var set + file unset, file set + env var unset, and
      both set with different values — confirm the env var wins in the
      last case, not just documented as winning.
- [ ] A missing config file, an empty file, and an unknown key each
      degrade to the compiled-in default / a logged warning rather than a
      hard failure — confirm this with a real run per case, not just by
      reading `dcc_config_load()`'s doc comment.
- [ ] If a new object file is added for a new config module, confirm it's
      linked into **every binary that actually needs the symbol** — a
      function shared between the client and the daemon (e.g. anything
      reachable from `dcc_scan_args()`, which both `distcc` and `distccd`
      call) needs its dependencies in `common_obj`, not just the object
      list for the binary the change was written against. This exact
      mistake has broken a build in this repo before (`distccd` failing
      to link with an undefined reference) — a full `make` covering
      **both** binaries, not just the one you were focused on, is what
      catches it.

## 7. Input / argument validation (CLI argument parsing, config value parsing, format strings)

Relevant to: any change validating or rejecting a caller-supplied string
before it is used as a format string, size, path, or other structurally-
significant value — `lsdistcc`'s `get_thename()`, `dcc_sane_env_path()`,
`src/config-parser.c`, anything parsing a `-specs=`/`-M*`-style compiler
flag value.

- [ ] A "contains X" check is not the same as "is exactly X" or "consists
      only of X" — a validator that only confirms a required token's
      *presence* (e.g. `strstr(fmt, "%d")`) can still let attacker-
      controlled extra content through alongside it. State explicitly
      which of the two the validator actually enforces.
- [ ] Real before/after exploit attempt with a deliberately malicious
      input crafted to pass a *naive* version of the check — not just a
      well-formed valid input and a completely unrelated invalid one.
      Build an AddressSanitizer- or Valgrind-instrumented binary if the
      failure mode is a memory-safety issue, and show the crash/
      violation before the fix and its absence after (see issue #226's
      `lsdistcc` format-string fix for the pattern).
- [ ] Confirm the fix doesn't reject realistic valid input that
      legitimately varies (e.g. printf flags/width/precision before a
      conversion specifier) — a validator strict enough to reject an
      attack but wrong enough to also reject normal use is a regression,
      not a fix.
- [ ] If the same unvalidated input can also reach a *different* code
      path (a second caller, an alternate encoding), confirm the fix
      covers that path too, not just the one exercised by the specific
      proof-of-concept used to find the bug.

## 8. Cleanup (always required for anything that started a process/container)

- [ ] No leftover running containers (`docker ps -a` clean, or only
      pre-existing/unrelated entries explicitly identified as such).
- [ ] No leftover daemon/compiler processes (`ps aux | grep -i distcc`
      etc. clean).
- [ ] No dangling images/networks left from a one-off test build, unless
      deliberately kept for reuse (say so explicitly rather than leaving
      it ambiguous whether cleanup was forgotten or intentional).
- [ ] Any temporarily moved/renamed system state (e.g. a masquerade
      directory moved aside to test its absence) restored to its original
      state.

## 9. Container-based verification (Docker/`docker/verify/`-based build+test runs)

Relevant to: any verification claim backed by a `docker build`/`docker run`
against `docker/verify/Dockerfile` or a similar ad-hoc container, especially
one exercising `gdb`/`strace`/`ltrace`, a real `distccd` privilege drop, or
any other permission-sensitive behavior. Two real, non-obvious permission
traps were found and fixed building `docker/verify/Dockerfile` itself
(issue #264) — both produced a plausible-looking but wrong diagnosis before
the real cause was pinned down, so they're recorded here rather than left
for the next container-based verification effort (e.g. the fuller
Samba/Apache E2E work #264 anticipates) to rediscover from scratch.

- [ ] **Seccomp is not capabilities.** `--cap-add=SYS_PTRACE` alone does
      *not* guarantee `gdb`/`strace`/`ltrace`/ptrace-based syscalls
      (including `gdb`'s own default ASLR-disabling `personality(2)` call)
      actually work in the container — Docker's seccomp filter is a
      *separate* gate from Linux capabilities, and the default seccomp
      profile can still deny the syscall (or a specific argument value,
      e.g. `personality()`'s `ADDR_NO_RANDOMIZE` flag) even once the
      capability is granted. The failure mode is identical-looking to a
      missing-capability failure (the same "Operation not permitted" from
      the tool), which makes it easy to mistake for "the capability didn't
      take effect" rather than "a second, independent gate is still
      closed." Real verification: after adding `--cap-add=SYS_PTRACE`, if
      the identical error still reproduces verbatim, that itself is the
      diagnostic signal to add `--security-opt seccomp=unconfined` (or a
      custom seccomp profile explicitly allowing the denied syscall) rather
      than re-checking the capability flag again.
- [ ] **A root-owned bind mount breaks `distccd`'s own privilege-drop
      test.** Running the whole build+test step as container root (often
      needed to work around a bind-mounted host checkout being owned by a
      different uid than the image's own non-root user) arms `distccd`'s
      real `dcc_discard_root()` privilege-drop-to-`uid=65534`/nobody
      behavior (`test/testdistcc.py`'s `Unicode_Case`, exercised via `make
      check`'s `maintainer-check-no-set-path` target) — which then fails
      with a real "Permission denied" writing into the still-root-owned
      test directory. This is not a bug in the drop behavior itself, only
      a mismatch between "root in the container" and "a test that
      deliberately changes uid mid-run." Do not fix this by making the
      tree world-writable (masks real permission bugs) or skipping the
      test (loses real coverage). Fix by using root only transiently to
      `chown` the mounted tree to the image's own non-root user, then
      actually running the build+test as that non-root user (`su -s
      /bin/bash <user> -c '...'`) — matching how a real local `docker run`
      already behaves when the same host user owns both sides of the
      mount.

## Keeping this checklist current

This list is not closed — it only covers the categories of change this
repo has actually hit so far. When a change touches something none of
the existing sections fit (a new subsystem, a new kind of external
interaction, a new failure mode discovered the hard way), add a new
section for it as part of that same PR, rather than stretching an
existing section to cover it loosely or skipping real verification
because "there's no checklist item for this." Section 6 (config file
changes) was added this way, prompted by issue #207 introducing this
repo's first client-side config file. Section 7 (input/argument
validation) was added the same way, prompted by issue #226's `lsdistcc`
format-string fix having no matching section to verify against. Section 9
(container-based verification) was added the same way, prompted by issue
#264's `docker/verify/Dockerfile` work hitting two real, non-obvious
permission traps (seccomp-vs-capabilities, root-mount-vs-privilege-drop)
that cost real CI iterations to diagnose and had no matching section to
record them against.

## Reporting

State explicitly, per section used, which checks were actually run and
what the real evidence was (log excerpt, `stat` output, exit code) — "I
ran X, saw Y" — not "this should work" or "the diff looks correct." If a
check in a relevant section genuinely couldn't be performed (no access to
a required resource, environment limitation), say so plainly rather than
omitting it silently.
