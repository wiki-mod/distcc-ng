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

## 4. External-host / network compatibility changes

Relevant to: protocol changes, compiler masquerade/rewrite logic
(`dcc_gcc_rewrite_fqn` and similar), anything that could affect
interop with a distccd this fork didn't build.

- [ ] Test against a **real, independently-built `distccd`** (e.g. a
      stock distro package, not this fork's own binary on both ends) —
      round-tripping against yourself proves internal consistency, not
      compatibility.
- [ ] Real, non-trivial compile load (an actual third-party C project,
      not a single hello-world file) with real parallelism, so protocol
      edge cases (large files, many concurrent jobs, varied compiler
      flags) get real exercise.
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

## 7. Cleanup (always required for anything that started a process/container)

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

## Keeping this checklist current

This list is not closed — it only covers the categories of change this
repo has actually hit so far. When a change touches something none of
the existing sections fit (a new subsystem, a new kind of external
interaction, a new failure mode discovered the hard way), add a new
section for it as part of that same PR, rather than stretching an
existing section to cover it loosely or skipping real verification
because "there's no checklist item for this." Section 6 (config file
changes) was added this way, prompted by issue #207 introducing this
repo's first client-side config file.

## Reporting

State explicitly, per section used, which checks were actually run and
what the real evidence was (log excerpt, `stat` output, exit code) — "I
ran X, saw Y" — not "this should work" or "the diff looks correct." If a
check in a relevant section genuinely couldn't be performed (no access to
a required resource, environment limitation), say so plainly rather than
omitting it silently.
