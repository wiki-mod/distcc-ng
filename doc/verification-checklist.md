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
- [ ] If the change claims an OS-visible runtime effect that isn't
      observable through `distcc`/`distccd`'s own log output (a `/proc`
      entry, a scheduler/priority setting, a file-mode bit, a signal
      disposition, etc.), read that OS state directly after triggering the
      change (e.g. `cat /proc/<pid>/autogroup`) rather than trusting a
      trace line claiming the syscall/write succeeded — a trace line only
      proves the code was reached, not that the OS actually applied the
      effect. Added after issue #77's autogroup-niceness fix, verified by
      reading `/proc/<pid>/autogroup` directly rather than just trusting
      `distccd`'s own trace log.
- [ ] State explicitly which user/uid `distcc` and `distccd` actually ran as
      during this verification: root with no privilege drop, root that then
      drops via `--user`, or already non-root/non-root-in-container. Several
      categories below (permission/file-mode, sandbox/seccomp) can behave
      differently under root than under a dropped-privilege user — root
      often bypasses a check a non-root run would actually exercise (e.g.
      `open()`/`fopen()` mode restrictions, or a seccomp filter that a
      privileged process interacts with differently) — so "it worked"
      without saying which case was exercised leaves the other case
      unverified. If only one case was tested, say so and name which.

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
- [ ] **The daemon's compiler-name whitelist rejects an absolute/
      directory-qualified compiler name outright, before `dcc_execvp()`'s
      own fallback logic is ever reached, unless `--enable-tcp-insecure`
      (or `DISTCC_CMDLIST`) is set.** `dcc_check_compiler_whitelist()`
      (`src/serve.c`) runs first; a test scenario built around an absolute
      `argv[0]` against a plain `distccd` (no `--enable-tcp-insecure`) gets
      rejected with `CRITICAL! compiler name <...> cannot be an absolute
      path` and never touches the exec path at all — a real, separate
      defense layer, but not evidence about `dcc_execvp()` itself. Found
      verifying issue #287/PR #406's fix over a real two-container setup:
      the first attempt (whitelist active) proved the whitelist's own
      absolute-path rejection is a real, independent safety net, not that
      the fix worked; only a second run with `--enable-tcp-insecure` (the
      mode `test/testdistcc.py`'s own `startDaemon()` already uses by
      default) actually exercised `dcc_execvp()`'s fallback removal.
      **Test both configurations when a change touches this exec path** —
      one confirms the whitelist's own defense-in-depth, the other
      confirms the actual code change.
- [ ] **Real two-container technique for compiler-identity/substitution
      bugs**: place a substitute "marker" script under the compiler's
      *real, already-whitelisted* name (e.g. the container's actual
      `x86_64-linux-gnu-gcc`) earlier on the **server** container's own
      `$PATH` than the real compiler (the client's `$PATH` must stay
      untouched, so only the server-side fallback is exercised); have the
      marker `touch` a sentinel file and exit 0 without compiling anything.
      From the client, send a directory-qualified compiler path sharing
      that same basename but existing nowhere on the server. Verify from
      the **server's own log** (not the client's exit code alone): the
      real fix's trace line appears, the sentinel file was never created,
      and no `COMPILE_OK` was logged for that job — then run the identical
      compile against the compiler's real, existing path as a positive
      control confirming legitimate compiles still succeed and produce a
      real `COMPILE_OK`. Used to verify issue #287/PR #406 over `docker
      network create` + two `docker run` containers (not `docker-compose`
      — full control over each container's own `$PATH`/env needed a plain
      `docker run` per side rather than the fixed service definitions in
      `test/e2e/docker-compose.yml`).

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
- [ ] For any container-based run: no persistent `[distccd] <defunct>`
      zombie owned by PID 1 in `ps auxf`/`docker top` — a zombie by itself
      is not the signal (a live parent that simply hasn't called
      `waitpid()` yet is completely normal and briefly produces one too);
      specifically a *reparented* `distccd` zombie whose parent is PID 1
      means a real init process was missing and a hang was only narrowly
      avoided. See Section 9's `--init`/zombie-accumulation entry.
- [ ] No dangling images/networks left from a one-off test build, unless
      deliberately kept for reuse (say so explicitly rather than leaving
      it ambiguous whether cleanup was forgotten or intentional).
- [ ] Any temporarily moved/renamed system state (e.g. a masquerade
      directory moved aside to test its absence) restored to its original
      state.
- [ ] Report any leftovers found that **predate this run** (a container,
      process, or file that was already there before this verification
      started) rather than silently cleaning it up or leaving it
      unmentioned — say explicitly "found and left/removed pre-existing X",
      not just "no leftovers" when what's meant is "no *new* leftovers".
      Conflating the two hides whether an earlier session's cleanup already
      failed.

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
- [ ] **A bind-mounted host checkout owned by a different uid than the
      image's own non-root user needs `docker run --user`, not root.**
      When the bind-mounted checkout's owning uid (e.g. a CI runner's own
      uid, or a local host user) differs from the image's baked-in
      non-root user's uid, the container can't write into it under that
      baked-in user at all ("Permission denied", or `autom4te: error:
      cannot create autom4te.cache in ...: Permission denied"). Reaching
      for `--user root` plus a transient `chown` to the image's own user,
      then dropping to that user for the actual build+test (`su -s
      /bin/bash <user> -c '...'`), was this repo's first working fix
      (issue #264) — but running the whole step as container root along
      the way arms `distccd`'s real `dcc_discard_root()` privilege-drop-
      to-`uid=65534`/nobody behavior (`test/testdistcc.py`'s `Unicode_Case`,
      exercised via `make check`'s `maintainer-check-no-set-path` target),
      which then fails with a real "Permission denied" writing into the
      still-root-owned test directory — not a bug in the drop behavior
      itself, only a mismatch between "root in the container" and "a test
      that deliberately changes uid mid-run."
      **Resolved (issue #286): root is not actually necessary at all.**
      `docker run --user "$(id -u):$(id -g)"` makes the container process
      itself run as the *caller's* own uid, so it already owns the
      bind-mounted checkout with no `chown`/`su`/root step anywhere —
      confirmed empirically by a real CI run (PR #405) comparing the old
      root+chown+su pattern against `--user $(id -u):$(id -g)` (and,
      separately, against a build-arg-parameterized image rebuild matching
      the host uid) on the exact same `docker/verify/Dockerfile` image and
      the same real `./autogen.sh && ./configure && make && make check`:
      all three produced byte-identical `test/testdistcc.py`/comfychair
      results (138 OK, 16 NOTRUN, 0 FAIL, including root-only cases like
      `Unicode_Case` and `AutogroupNicenessPrivilegeDrop_Case` correctly
      NOTRUN-skipping identically under all three). `--user` was adopted
      over the build-arg approach specifically because it needs no image
      rebuild at all and works directly against the exact, unmodified,
      already-published image — the build-arg approach would otherwise
      have reintroduced a local build step for any caller whose own uid
      doesn't match the image's baked-in default, which is exactly what
      issue #264's "pull and run, nothing to build" requirement exists to
      avoid. See `.github/workflows/verify-image-build.yml`'s "Real
      distcc-ng build+test inside the image" step for the current, real
      invocation.
      **One real, empirically-confirmed companion requirement**: pass an
      explicit `-e HOME=<a plain container-internal path, e.g.
      /tmp/some-name>` and `mkdir -p "$HOME"` **inside the container's own
      script**, before anything else runs. Docker does not synthesize an
      `/etc/passwd` entry for a numeric `--user` uid with no matching name
      in the image, so without an explicit `HOME`, such a uid gets
      `$HOME=/`, which it cannot write to — breaking anything that
      resolves a cache/config dir off `$HOME` (`ccache`'s own local cache
      dir, in particular). Confirmed twice, once each way: first that the
      override is necessary at all (the earlier build+test step's `make
      check` failing without it), and separately that a *host*-side path
      does not work as the value — an earlier version of the "ccache +
      Redis remote-storage self-test" job set `-e HOME="$RUNNER_TEMP/some-
      name"` and `mkdir -p` on that path **on the runner**, without
      bind-mounting it into the container, so the container saw `$HOME`
      pointing at a path that simply doesn't exist inside its own
      filesystem at all — a real `ccache: error: Permission denied` CI
      failure, not a permission-bits problem. The fix is a plain
      container-internal path (`/tmp/...`) created by `mkdir -p` run as
      part of the container's own command, never a host path assumed to
      be visible inside the container without an explicit bind mount.
      Rootless Docker/user-namespace remapping (the issue's third proposed
      alternative) was not empirically tested: it wasn't needed once
      `--user` was confirmed to work cleanly, and GitHub-hosted runners
      don't offer a rootless Docker daemon to test it against anyway.
- [ ] **`make check`'s `distcc-maintainer-check`/`maintainer-check-no-
      set-path` chain can fail with `distccd: not found` on some Docker
      hosts even though the target's own `PATH="`pwd`:$(RESTRICTED_PATH)"`
      setup looks correct on read — unresolved, host-specific, not a code
      defect.** Found running a full `./autogen.sh && ./configure && make
      && make check` inside the buildtools image on an SSH-reachable Linux
      host (not GitHub Actions): every real `test/testdistcc.py` case
      passes cleanly (including a genuinely new one), but the final
      `maintainer-check-no-set-path` re-run then fails immediately with
      `/bin/sh: 1: distccd: not found` trying to start the very first
      daemon. Confirmed this is **not** caused by whatever change is being
      verified — reproduces identically on a clean, unmodified `current_dev`
      checkout on the same host — and **not** a general regression, since
      the identical `make check` invocation passes in this repo's own
      GitHub Actions `make_check` job for the same commits. Root cause not
      determined (plausibly something about how this specific host's
      Docker/shell setup propagates the Makefile-set `PATH` into
      `test/testdistcc.py`'s own Python subprocess calls, but not
      confirmed). **Until root-caused: treat a full local `make check`
      run's real signal as everything up to and including the last
      `test/testdistcc.py`-driven comfychair case line (`Lsdistcc_Case`
      through the final real test case) — a failure strictly in the
      trailing `maintainer-check-no-set-path` re-run, with every real test
      case already having reported `OK`/`NOTRUN` moments earlier in the
      same log, is this known host quirk, not a new defect** — but verify
      that pattern matches exactly (all real cases already passed) before
      assuming it, don't pattern-match on the target name alone.
- [ ] **A root-only test needs the specific capability its own syscall
      requires, not just "run as root."** Docker's default root capability
      set is not the same as a real host root's — `AutogroupNicenessPrivilegeDrop_Case`
      (root-only, exercises `dcc_set_autogroup_niceness()`'s `nice(2)` call
      in `src/dparent.c`) failed inside a container run as root with
      `nice -5 failed: Operation not permitted`, an error that reads
      identically to a genuine code regression. The real cause: Docker's
      default root capability set does not include `CAP_SYS_NICE`, which
      `nice(2)`'s negative-value case requires regardless of uid. Fixed by
      adding `--cap-add=SYS_NICE` explicitly — same failure shape and same
      lesson as this section's `SYS_PTRACE`/seccomp entry above (root
      inside a container is not equivalent to root on a real host; check
      which specific capability the syscall under test actually needs
      before treating an "Operation not permitted" as a code bug). Found
      verifying the 3.6.1-NG release (2026-07-23).
- [ ] **A container with no real init process silently hangs `make check`
      via zombie accumulation — confirmed to be a container-tooling gap,
      not a distcc-ng code bug.** `distccd --daemon` deliberately
      daemonizes via `dcc_detach()` (`src/dparent.c`): it `fork()`s, the
      immediate parent calls `_exit(0)` right away ("this guy is about to
      go away so as to detach from the controlling process" — borrowed
      from rsync, the function's own doc comment says so), and the child
      calls `setsid()` to leave its controlling session. This is the
      textbook, correct Unix daemonization pattern every pre-systemd
      daemon uses — its whole point is to orphan the daemon so it
      survives its spawner exiting, which necessarily reparents it to
      whatever process is PID 1 in that namespace. Running the build+test
      step via `docker run ... bash -c '... su -s /bin/bash <user> -c
      "..."'` (the pattern the two entries above already use to drop from
      root to the image's non-root user) makes `su` that PID 1 in place of
      a real init — and `su`, like `bash`, never reaps a reparented
      zombie. The actual hang is in `test/testdistcc.py`'s own
      `WithDaemon_Case.killDaemon()`: since the harness can't `wait()` a
      detached daemon (its own comment says so), it sends `SIGTERM` and
      then polls with `os.kill(pid, 0)` in a `while 1` loop until that
      call raises `OSError` (`ESRCH`) -- but a zombie still has a live PID
      table entry, so `kill(pid, 0)` keeps succeeding against it
      indefinitely, and the loop only exits once something actually reaps
      the zombie. With no real init to do that, the loop spins forever at
      0.2s intervals: a real, silent hang with the stuck process burning
      near-zero CPU (`ps aux`'s `TIME` column stays at seconds while
      wall-clock elapses in hours) and no error output at all —
      indistinguishable at a glance from "still running a slow test."
      Diagnostic signal: `ps
      auxf` inside the container shows multiple `[distccd] <defunct>`
      entries whose parent is PID 1 (or the `su`/`bash` wrapper), not a
      live test process. Fix: add `--init` to the `docker run` invocation
      (runs `tini` as real PID 1, which does reap reparented zombies)
      rather than assuming a slow run is just... slow, or suspecting
      `dcc_detach()`'s daemonization itself — any daemonizing program in
      any init-less container hits this identically; it is not specific
      to distcc-ng. Found and confirmed (killed the hung run, reproduced
      the zombie tree via `ps auxf`, re-ran clean with `--init` added)
      cutting the 3.6.3-NG release (2026-07-30). See Section 8's matching
      cleanup check.
- [ ] **A toolchain whose assembler emits compressed ELF debug sections
      (size-dependent, not a fixed default) breaks
      `Gdb_Case`/`GdbOpt1-3_Case` in pump mode — a real distccd-side bug,
      not an environment quirk, and not specific to an old Alpine
      release.** `src/fix_debug_info.c`'s `dcc_fix_debug_info()` rewrites
      the server-side compilation directory baked into a compiled
      object's DWARF debug info (`.debug_info`, `.debug_str`,
      `.debug_line_str`) back to the client-side path, via a raw byte
      search-and-replace directly on the mmap'd ELF section contents —
      which assumes the server-side path string is still present
      byte-for-byte in the section's raw, uncompressed bytes, not that
      the section itself is plain text (`.debug_info`/`.debug_line_str`
      are structured binary DWARF data even when uncompressed;
      `replace_string()` deliberately does a raw `memcmp`/`memcpy`
      substring scan over that binary buffer without parsing its
      structure, confirmed by reading `src/fix_debug_info.c`'s
      `replace_string()`). On a
      real, current `alpine:latest` container (Alpine 3.24.1, `gcc
      (Alpine) 15.2.0`, checked 2026-08-01), `.debug_line_str` carries the
      ELF `SHF_COMPRESSED` flag (visible as `C` in `readelf -SW`, zlib
      magic `789c...` visible in the raw section bytes) once the
      compilation directory string is long enough to cross a
      compression-worthwhile size threshold. This is not a GCC-internal
      decision: `gcc -### -gz -g -c t.c -o t.o` (a real source file is
      required for this trace -- omitting it prints only GCC driver
      metadata with no `as` invocation at all) shows GCC dispatching to
      `as --compress-debug-sections=zlib` -- the GNU assembler is what
      actually decides and performs the compression, not gcc itself.
      Confirmed this is size-dependent, not a fixed default: a short test
      path (e.g. `/tmp/check2`) produced an uncompressed section and the
      test appeared to pass, while a longer, more realistic distccd
      compile-working-directory path (e.g.
      `/tmp/distccd_<6-char-mkdtemp-suffix>/<client-cwd>` -- formed by
      `make_temp_dir_and_chdir_for_cpp()` in `src/serve.c` concatenating
      `dcc_get_new_tmpdir()`'s directory with the client's cwd; a
      different function from `dcc_make_tmpnam()`, which only names
      individual files like the object output, not this working
      directory, and whose `mkdtemp()` 6-character suffix is not
      guaranteed to be hex) reliably triggers compression — so a
      short-path smoke test can miss this bug entirely. The search string
      is genuine plain text once decompressed (confirmed via
      `readelf --debug-dump=info`), but never appears in the section's
      raw compressed bytes, so `update_section()`'s `replace_string()`
      call finds zero occurrences; this is non-fatal and traced, not
      silent -- `update_section()` itself still logs
      `rs_trace("\"%s\" section of file %s has no occurrences of \"%s\"",
      ...)` (`src/fix_debug_info.c:365`), visible under `distccd
      --verbose`, but the function still returns success and the rewrite
      itself never happens. The binary keeps its server-side compilation
      directory baked in; gdb (client-side) then can't find the source
      file (`warning: <line>\t<file>: No such file or directory`). A real
      Debian 13 container (`gcc (Debian 14.2.0-19)`, this repo's own
      release base image -- a different gcc version on a different
      distro/container than the Alpine case above, not a controlled
      same-compiler comparison; Debian 13/trixie's own repos, including
      trixie-backports, top out at gcc-14, no gcc-15 package exists there
      as of this writing) produces uncompressed debug sections at the
      same path lengths — same test passes there. `-gz=none` on the same
      Alpine gcc removes the `SHF_COMPRESSED` flag entirely (verified via
      `readelf -SW`), which only shows the assembler flag controls
      compression -- it does not by itself distinguish a GCC-version
      effect from Alpine's own GCC build/packaging configuration, since
      this was not tested with matched GCC versions across both
      platforms. Describe this as toolchain/distro-configuration-dependent
      behavior, not attributed to a specific cause, until reproduced with
      controlled GCC versions. Not related to this repo's own
      network-level zstd compression work (issue #101/pump-mode transport
      compression) — this is the toolchain's own debug-info encoding,
      unrelated code path, confirmed no shared code between them.
      Isolated independently of `distccd` itself, by building
      `src/fix_debug_info.c`'s own `TEST` main() standalone and running
      `dcc_fix_debug_info()` directly against a real compiled `.o` file
      with a known compilation directory — same failure, confirming the
      bug is in this file's raw-byte-search design, not somewhere else in
      the daemon pipeline. Found evaluating Alpine support (issue #398);
      not yet fixed as of this writing — see that issue's comment thread
      for the full analysis and fix-direction discussion.

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

Every example above was added *after* a gap actually caused a real
diagnosis cost — reactively, once the missing coverage had already bitten
once. Don't wait for that as the only trigger: as part of verifying any
non-trivial change, explicitly ask "did anything about this change's
actual behavior not fit cleanly into an existing section?" — not just
"did an existing section's checks pass." A change that technically
satisfies the letter of an existing section while clearly testing
something the section wasn't written for is itself a signal this list
needs extending, in the same PR, not a note for later. This is a
standing habit for every relevant PR, not a one-time backfill exercise —
the list will never reach a final, complete state, because the set of
changes this repo makes keeps growing too.

## Reporting

State explicitly, per section used, which checks were actually run and
what the real evidence was (log excerpt, `stat` output, exit code) — "I
ran X, saw Y" — not "this should work" or "the diff looks correct." If a
check in a relevant section genuinely couldn't be performed (no access to
a required resource, environment limitation), say so plainly rather than
omitting it silently.
