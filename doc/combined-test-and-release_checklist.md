# Combined Release and Test Checklist

This document is the canonical combined checklist for development verification and release readiness.

It combines the requirements previously maintained in `doc/verification-checklist.md` and `doc/release-checklist.md` into one extensible checklist.

It defines:

1. What MUST be verified for a change during development.
2. What MUST additionally be verified before a release.
3. What evidence is sufficient or insufficient for each check.
4. Known verification environment constraints and known failure interpretations.
5. How this checklist MUST be extended when a new verification class is discovered.
6. How the complete checklist is periodically recertified against the actual `current_dev` code and repository state.

`doc/release-versioning.md` remains responsible for the mechanical release branch, version, tag, and publication process. This document defines what MUST actually be true and verified.

## Authority and AGENTS.md

`AGENTS.md` Rule 0 applies at all times.

Compliance with this checklist MUST NOT be interpreted as compliance with only the rules referenced by an individual check. Every affected file, artifact, generated output, behavior, test environment, workflow, package, and the complete change MUST still satisfy every applicable rule in `AGENTS.md`.

Passing one checklist item, one checklist section, or this checklist as a whole MUST NOT be used to bypass, weaken, replace, or omit any independently applicable `AGENTS.md` requirement.

The authoritative `AGENTS.md` is the complete copy from `current_dev`. It MUST be read as required by `AGENTS.md` Rules 83 and 84 before work governed by it is performed.

Verification evidence MUST satisfy the current `AGENTS.md` evidence requirements. In particular, evidence cited as actual verification MUST run in `ghcr.io/wiki-mod/distcc-ng-buildtools` or in the repository's actual CI when required by `AGENTS.md` Rule 87. A host-local, WSL2, ad hoc, or substitute environment MAY be used for non-authoritative development iteration where permitted, but MUST NOT be represented as qualifying verification evidence when Rule 87 applies.

## Normative language

The key words `MUST`, `MUST NOT`, `REQUIRED`, `SHALL`, `SHALL NOT`, `SHOULD`, `SHOULD NOT`, `RECOMMENDED`, `MAY`, and `OPTIONAL` are to be interpreted as described by RFC 2119.

The normative strength of an existing requirement MUST NOT be weakened when this document is edited.

A wording cleanup, restructuring, ID assignment, or removal of narrative text MUST preserve the original requirement, condition, exception, expected result, failure condition, evidence requirement, and reference.

## Stable IDs

Every actionable check has a stable ID.

Existing `REL-*` IDs retain their existing meanings and identifiers.

New development verification checks use `VER-*` IDs.

Recertification checks use `RECERT-*` IDs.

Once assigned:

* an ID MUST NOT be renumbered;
* an ID MUST NOT be reused for a different requirement;
* an ID MUST NOT silently change meaning;
* a new requirement MUST receive the next unused ID in the relevant family;
* a retired requirement MUST retain its ID and MUST identify why it was retired and, when applicable, which ID replaces it.

## Required check structure

Every new or materially restructured verification item SHOULD use this structure:

**ID**

**Applies when:** The condition that activates the check.

**Requirement:** The normative requirement.

**Procedure:** The required test or inspection.

**Pass criteria:** The observable result required for success.

**Invalid evidence:** Evidence that MUST NOT be treated as satisfying the check.

**Known constraints:** Relevant environment, implementation, or interpretation constraints.

**References:** Relevant issue, PR, source file, test, workflow, or documentation reference.

A field MAY be omitted only when it genuinely has no applicable content.

## Checklist execution rules

Every applicable item MUST be explicitly classified.

Allowed execution states are:

* `PASS`
* `FAIL`
* `BLOCKED`
* `N/A`

`N/A` MUST include a reason.

`BLOCKED` MUST identify the missing resource, environment, permission, artifact, or other blocker.

An applicable item MUST NOT be silently omitted.

A successful build, green CI job, source inspection, trace line, or lack of a crash MUST NOT be substituted for a behavioral test when the applicable check requires real behavior.

A check requiring evidence MUST record what was actually run and what was actually observed. Valid evidence includes the relevant real log excerpt, command result, exit status, filesystem state, package metadata, server-side log, or artifact state.

Statements such as `should work`, `looks correct`, `the diff is correct`, or equivalent reasoning MUST NOT be recorded as verification evidence.

A historical successful result MAY explain why a check exists or how it is performed. It MUST NOT automatically satisfy a new verification run.

## Verification record

For development verification, record:

Verification date: 2026-09-09

Verification SHA: e9f384b24cba9d6c346721fbc1b901bd607fbfec

Issue: #531

PR: (this PR)

Change scope: Re-verification of all VER-* and REL-* entries against current_dev at the recorded SHA by reference consistency (all referenced source files, tests, workflows, and CI jobs confirmed present) and status-claim currency (all time-bound and status assertions checked). One stale entry corrected: VER-CONTAINER-09.

Verification environment: ghcr.io/wiki-mod/distcc-ng-buildtools on an LXC host; documentation-vs-code consistency checks via git against current_dev.

Verification operator: maintainer

Evidence location: Issue #531 and this PR's description.

For a release, the release information section below MUST additionally be completed.

## Release information

This section MUST remain unfilled during ordinary development verification.

For a real release, it MUST be completed for that release so the release-specific state is preserved with the release record that reaches `master`.

Release version:

Candidate SHA:

Previous release tag:

Release branch:

Release PR:

Release date:

Maintainer:

Independent reviewer:

Pre-tag artifact workflow run:

Tag-triggered release workflow run:

Published release URL:

Release verification result:

# Development and behavioral verification

## Baseline

### **VER-BASE-01** Clean build without new warnings

**Applies when:** Always.

**Requirement:** The changed code MUST build cleanly and MUST NOT introduce new warnings. Warnings are failures, not informational noise.

**Procedure:** Run the real equivalent of:

`./autogen.sh && ./configure ... && make`

using an evidence-eligible environment.

**Pass criteria:** The complete build succeeds and the change introduces no warning.

**Invalid evidence:** A partially completed build, a build containing a warning, a silently degraded configuration, or a build whose failed setup was ignored.

**References:** `AGENTS.md` Required Validation.

### **VER-BASE-02** Existing test suite

**Applies when:** Always.

**Requirement:** The full existing test suite MUST pass.

**Procedure:** Run `make check` in an evidence-eligible environment.

**Pass criteria:** All applicable test execution required by the current suite completes with no unexplained failure.

**Invalid evidence:** `make check` alone MUST NOT be reported as proof that new or changed behavior works. It proves only that behavior already covered by the existing suite was not observably broken.

### **VER-BASE-03** Direct observation of OS-visible behavior

**Applies when:** A change claims an OS-visible runtime effect that is not itself observable through `distcc` or `distccd` output.

Examples include `/proc` state, scheduler state, process priority, file mode, signal disposition, and similar kernel-visible effects.

**Requirement:** The claimed operating-system state MUST be read directly after the behavior is triggered.

**Procedure:** Trigger the change and read the relevant OS state, for example `cat /proc/<pid>/autogroup`.

**Pass criteria:** The operating system reports the intended resulting state.

**Invalid evidence:** A trace line stating that a syscall, write, or code path executed. Such a trace proves the code was reached but does not prove the operating system applied the requested effect.

**References:** Issue #77, autogroup niceness verification.

### **VER-BASE-04** Runtime UID and privilege context

**Applies when:** Always.

**Requirement:** Verification MUST state which user and UID `distcc` and `distccd` actually ran as.

The record MUST distinguish at least:

* root without privilege drop;
* root followed by `--user` privilege drop;
* already non-root;
* non-root inside a container.

If only one privilege case was tested, the verification record MUST state which one and MUST NOT imply coverage of the others.

**Known constraints:** Permission, file-mode, sandbox, and seccomp behavior can differ between root and non-root execution. Root may bypass an access restriction that a non-root execution would exercise. A privileged process can also interact differently with a seccomp setup.

**Invalid evidence:** `It worked` without the actual UID and privilege model.

## Permission and file-mode changes

Relevant examples include CodeQL `cpp/world-writable-file-creation` fixes, temporary files, `src/lock.c`, `src/state.c`, `src/zeroconf.c`, `src/daemon.c`, `src/bulk.c`, `src/dparent.c`, `src/dotd.c`, `src/traceenv.c`, and the discrepancy-file path in `src/compile.c`.

### **VER-PERM-01** Real Unix permission semantics

**Applies when:** A change affects permissions, file modes, umask handling, `open()` modes, `fopen()` modes, or related behavior.

**Requirement:** The verification filesystem MUST actually enforce Unix permission bits and umask semantics.

**Procedure:** Run the permission test on a real Unix-permission filesystem.

**Pass criteria:** File modes and access behavior are enforced by the filesystem.

**Invalid evidence:** Windows-hosted WSL2 `/mnt/c/...` through 9p or DrvFs, because that environment can ignore the mode and umask behavior being tested.

A native WSL ext4 filesystem can exercise the filesystem semantic itself, but MUST NOT be cited as qualifying verification evidence when `AGENTS.md` Rule 87 requires the buildtools container or actual CI.

### **VER-PERM-02** Real second-user access test

**Applies when:** A touched file's permissions or cross-user accessibility can change.

**Requirement:** A second, genuinely different Linux user MUST attempt the relevant read and write operations.

**Procedure:** For every touched file whose access semantics matter:

1. Identify whether it is intended to remain cross-user readable or writable.
2. Attempt the applicable access as a different Linux user.
3. Record the actual result.

Files expected to remain cross-user readable include, where applicable:

* pid files;
* state files read by `distccmon-*`;
* zeroconf discovered-host files.

Files expected to be tightened include, where applicable:

* daemon logs;
* lock files;
* discrepancy counters.

**Pass criteria:** Cross-user readable files are actually readable by the second user. Files intended to deny access actually return a real permission failure such as `Permission denied`.

**Invalid evidence:** `stat` or `ls -la` alone, or an assumption based only on the numeric mode.

### **VER-PERM-03** Deployment-mode regression test

**Applies when:** A file's permission behavior is load-bearing for a documented deployment mode.

Relevant modes include:

* shared `DISTCC_DIR`;
* cross-user `distccmon-*` monitoring;
* output-must-match-local-compile behavior.

**Requirement:** The specific test encoding that deployment expectation MUST still pass.

**Procedure:** Run the relevant existing test, including `test/testdistcc.py`'s `ModeBits_Case` where applicable.

**Pass criteria:** The deployment behavior and its regression test both succeed.

**References:** PR #158. Its first attempt changed this class of behavior and CI, rather than review alone, caught the regression.

### **VER-PERM-04** Intentionally unchanged instances

**Applies when:** A review or sweep finds an instance that could have been changed but is deliberately left unchanged.

**Requirement:** The reason MUST be recorded in the PR or issue.

**Invalid evidence:** Silent omission.

## Sandbox, seccomp, and process isolation

Relevant files include `src/sandbox-seccomp.c` and `src/sandbox-config.c`.

### **VER-SECCOMP-01** Sandbox compiled into the tested binary

**Applies when:** Sandbox or seccomp behavior is tested.

**Requirement:** The tested build MUST actually contain seccomp support.

**Procedure:** Build with `--with-seccomp` and with the required `libseccomp-dev` support available, then confirm the resulting build is the seccomp-enabled build.

**Pass criteria:** The sandbox code is compiled into the tested artifact.

**Invalid evidence:** A build that silently falls back to `--without-seccomp`.

### **VER-SECCOMP-02** Effective runtime denylist

**Applies when:** The seccomp denylist, additional deny entries, allow overrides, or filter computation changes.

**Requirement:** The effective filter installed at runtime MUST match the intended filter.

**Procedure:** Observe the runtime filter effect or the startup information produced by `dcc_seccomp_configure()`, including applicable `extra-deny` and `allow-override` entries.

**Pass criteria:** The actually installed effective denylist matches the intended result.

**Invalid evidence:** Reading the source and assuming the computed filter is correct.

### **VER-SECCOMP-03** Positive sandbox control

**Applies when:** Sandbox or seccomp behavior changes.

**Requirement:** A legitimate distributed compile MUST still succeed while the sandbox is active.

**Procedure:** Send a real source file through a real compiler and a real `distccd` with the intended sandbox configuration.

**Pass criteria:** The compile succeeds under the sandbox.

**Invalid evidence:** Parser-only tests, filter-construction inspection, or a startup log without an actual compile.

### **VER-SECCOMP-04** Negative denied-syscall test

**Applies when:** Sandbox or seccomp behavior changes.

**Requirement:** A syscall intended to be denied MUST be executed inside the sandbox and its actual result MUST be observed.

**Procedure:**

1. Use a syscall in `src/sandbox-seccomp.c`'s `dcc_seccomp_denied_syscalls[]`.
2. `ptrace` is a suitable test syscall because real compilers do not normally call it.
3. A small C marker binary MAY be used.
4. The marker MUST record the raw return value and `errno` to a sentinel file.
5. The marker MUST be installed on the server under the compiler name the client actually transmits.
6. The transmitted compiler name MUST be confirmed from the server-side log.
7. A bare user-typed name MUST NOT be assumed to be the transmitted name because `dcc_gcc_rewrite_fqn()` can rewrite bare `gcc` to a target-triplet name such as `x86_64-linux-gnu-gcc`.
8. Send a real compile job through the marker.
9. Read the sentinel result on the server.

**Pass criteria:** The syscall is blocked using the action configured by the current filter.

For the implementation recorded by Issue #360 and PR #408, the configured action is `SCMP_ACT_ERRNO(EPERM)`. The expected result is therefore return value `-1` with `errno=EPERM`, not a kill signal.

The current filter action MUST be checked before assuming that this historical expected action is still current.

**Invalid evidence:**

* successful compilation alone;
* filter startup output alone;
* a marker installed only at `/usr/bin/gcc` when the client transmits another name;
* assuming that blocked means killed without checking the configured seccomp action.

**References:** Issue #360, PR #408.

### **VER-SECCOMP-05** Fail-open, fail-closed, require-seccomp, and no-seccomp paths

**Applies when:** These code paths are touched.

**Requirement:** Runtime filter-install failure and a build without seccomp MUST be treated as separate scenarios.

Both applicable `fail-open` or `fail-closed` behavior and `require-seccomp` behavior MUST be checked.

**Pass criteria:** Each touched scenario behaves according to `doc/seccomp-sandbox.md`.

**Invalid evidence:** Testing one scenario and assuming the other follows from it.

### **VER-SECCOMP-06** No-libseccomp and non-Linux behavior

**Applies when:** Sandbox support, seccomp build detection, or dependencies change.

**Requirement:** Behavior on a host without libseccomp and on non-Linux platforms MUST remain unchanged unless the change explicitly and validly changes support policy.

**Pass criteria:** No new hard dependency is introduced silently.

**References:** `doc/compatibility-policy.md`.

### **VER-SECCOMP-07** Release package dependency declaration

**Applies when:** `libseccomp-dev` or another library becomes a new mandatory dependency of a real release artifact rather than only a verification image.

**Requirement:** The actual built package MUST be inspected.

**Procedure:**

1. Use `ldd $(which distccd)` or the corresponding binary inspection to determine whether the built binary dynamically links `libseccomp.so.2`.
2. Inspect the actual `.rpm` with `rpm -qp --requires <file>.rpm`.
3. Inspect the actual `.deb` with `dpkg-deb -I <file>.deb`.
4. Confirm that automatic package dependency detection declared the new shared-library requirement in the real package.

RPM and `alien` shared-library dependency detection can generate dependencies automatically from the built binary. That behavior MUST be confirmed from the package rather than assumed.

**Pass criteria:** The package's actual dependency metadata matches the libraries required by its built binaries.

**Invalid evidence:** `configure` detecting the library, or local `ldd` output without inspecting the real package.

### **VER-SECCOMP-08** CI-built package acquisition without publishing a release

**Applies when:** A real release-package artifact is needed for verification before a tag exists.

**Requirement:** The real release packaging pipeline MAY be dispatched on a branch without publishing containers.

**Procedure:**

`gh workflow run package-release.yml --ref <branch> -f publish_container=false`

The resulting artifact can be downloaded through:

`gh api repos/<owner>/<repo>/actions/artifacts/<id>/zip`

A real tag is not required for this verification dispatch. A real published release still requires the real tag defined by `doc/release-versioning.md`.

**Known constraint:** `gh run download` can fail when the artifact ZIP contains a directory and another entry with the same name. In that case the raw artifact ZIP SHOULD be fetched through `gh api` and unpacked directly.

## Distribution and scheduling behavior

Relevant changes include `src/arg.c`'s `dcc_scan_args()`, host selection, fallback logic, distribution versus forced-local decisions such as `-march=native`, `-flto`, `-M*`, `DISTCC_FALLBACK`, `DISTCC_HOSTS`, lock logic, and retry logic.

### **VER-DIST-01** End-to-end evidence required

**Applies when:** Distribution or local-only behavior changes.

**Requirement:** Actual end-to-end distribution behavior MUST be tested.

**Invalid evidence:** A trace line, source reasoning, or a single-host execution alone. These can prove a path was reached but cannot prove whether a compile was or was not distributed end to end.

### **VER-DIST-02** Real client, server, and network hop

**Applies when:** Distribution behavior changes.

**Requirement:** The test MUST use a distinct client and server with a real network hop.

**Procedure:** A two-container or larger setup MAY be used.

**Pass criteria:** The server's own independent log confirms the expected remote compile behavior.

`test/e2e/run-e2e.sh` demonstrates the relevant pattern by checking server-side `COMPILE_OK` entries associated with the client subnet address.

**Invalid evidence:** The client alone claiming that the compile was remote.

### **VER-DIST-03** Expected result defined before execution

**Applies when:** A distribution behavior test is run.

**Requirement:** The expected result MUST be stated before the test.

Example:

* plain file: exactly one remote `COMPILE_OK`;
* `-flto` file: zero remote `COMPILE_OK`.

**Invalid evidence:** `It ran and nothing crashed`.

### **VER-DIST-04** Local-only behavior with fallback disabled

**Applies when:** The change is intended to force a compile local.

**Requirement:** The behavior MUST be tested with `DISTCC_FALLBACK=0`.

**Reason:** `DISTCC_FALLBACK=0` disables the silent local fallback path in `src/compile.c`. An incorrect attempt to distribute therefore becomes an observable hard failure instead of quietly succeeding locally.

**Pass criteria:** The intended local-only decision is observable without fallback masking an error.

## Compiler identity, family resolution, and physical compiler selection

Relevant code includes `src/arg.c`'s `dcc_resolve_march_native()`, `src/compile.c`'s `dcc_add_clang_target()`, `dcc_gcc_rewrite_fqn()`, `dcc_rewrite_generic_compiler()`, and `src/climasq.c` masquerade path matching.

Issues #78 and #278 established that some decisions require the full path while others require the basename. The verification MUST distinguish these cases rather than assuming one representation is universally correct.

### **VER-COMPILER-01** Family-obscuring compiler name

**Applies when:** Logic determines compiler family from `argv[0]`, path, basename, wrapper, dispatcher, or cross-toolchain name.

**Requirement:** Testing MUST include a compiler invocation whose visible name does not trivially reveal the actual compiler family.

Examples include:

* a script named `mycompiler` that executes `/usr/bin/clang`;
* a real cross-toolchain name such as `arm-linux-gnueabihf-gcc`.

**Invalid evidence:** Testing only names such as `gcc` or `clang-19`. Those names cannot distinguish a raw `argv[0]` bug from a basename comparison bug when both representations happen to agree.

**References:** Issues #78 and #278.

### **VER-COMPILER-02** Directory-qualified compiler preservation

**Applies when:** A fix resolves a compiler name and then executes or PATH-searches that result.

**Requirement:** A directory-qualified original invocation such as `/opt/toolchain/bin/gcc` MUST continue to resolve to the intended binary in that directory when the semantics require preserving the caller's selected toolchain.

**Pass criteria:** The rewrite does not silently drop the directory and substitute a same-named compiler found elsewhere in `$PATH`.

### **VER-COMPILER-03** Cross-compiler verification environment limitation

**Applies when:** A real cross-compiler is required for the test.

**Known constraint:** The verification toolchain recorded by the source checklist does not include a real `arm-linux-gnueabihf-gcc`-style cross compiler.

A suitable external real toolchain or a hand-built fake dispatcher was historically required for this test category.

Under the current `AGENTS.md` evidence rules, any cited verification MUST still use an evidence-eligible environment. If the required real toolchain is not available in such an environment, the check MUST be recorded as `BLOCKED` rather than silently replaced with weaker evidence.

### **VER-COMPILER-04** Whitelist path and exec path are separate checks

**Applies when:** A change touches `dcc_execvp()` behavior for absolute or directory-qualified compiler names.

**Requirement:** Both configurations MUST be tested:

1. compiler-name whitelist active;
2. execution path actually reachable with `--enable-tcp-insecure` or appropriate `DISTCC_CMDLIST`.

**Known behavior:** `dcc_check_compiler_whitelist()` in `src/serve.c` runs before `dcc_execvp()`. With the normal whitelist active, an absolute compiler name is rejected with:

`CRITICAL! compiler name <...> cannot be an absolute path`

That rejection proves the whitelist defense works. It does not prove anything about `dcc_execvp()` behavior because the execution path was never reached.

`test/testdistcc.py`'s `startDaemon()` historically uses `--enable-tcp-insecure` by default, which allows the deeper execution path to be exercised.

**Pass criteria:** One configuration confirms the whitelist defense. The other independently confirms the changed exec behavior.

**References:** Issue #287, PR #406.

### **VER-COMPILER-05** Real compiler-substitution marker test

**Applies when:** A compiler identity, fallback, or path-substitution bug is tested.

**Requirement:** The substitution test MUST isolate server-side fallback behavior.

**Procedure:**

1. Place a substitute marker script on the server.
2. Use the real, already-whitelisted compiler name actually transmitted by the client, for example `x86_64-linux-gnu-gcc`.
3. Place the marker earlier in the server's own `$PATH` than the real compiler.
4. Do not change the client's `$PATH`.
5. Confirm the actual compiler name received by the server from the server log.
6. The marker MUST touch a sentinel file and exit 0 without compiling.
7. From the client, send a directory-qualified compiler path that has the same basename but does not exist on the server.
8. Inspect the server log and sentinel.
9. Run the same compile using the real existing compiler path as a positive control.

**Pass criteria for the negative case:**

* the expected fix trace appears;
* the sentinel is not created;
* no `COMPILE_OK` is logged.

**Pass criteria for the positive control:**

* the legitimate compile succeeds;
* a real `COMPILE_OK` is logged.

**Invalid evidence:** A marker installed under literal `gcc` when `dcc_gcc_rewrite_fqn()` actually transmits a target-triplet compiler name.

**Environment note:** The Issue #287 and PR #406 verification used `docker network create` plus separate `docker run` invocations because each side required independent `$PATH` and environment control that the fixed definitions in `test/e2e/docker-compose.yml` did not provide.

**References:** Issue #287, PR #406, Issue #360, PR #408.

## External-host and network compatibility

Relevant changes include protocol changes, compiler masquerade and rewrite behavior such as `dcc_gcc_rewrite_fqn()`, and anything that could affect interoperability with a `distccd` that this fork did not build.

Round-tripping distcc-ng against itself proves internal consistency only. It does not prove compatibility.

Bug #225 demonstrated that a one-directional interoperability failure can exist while another direction passes.

### **VER-INTEROP-01** distcc-ng client against independent server

**Applies when:** External-host or protocol compatibility can change.

**Requirement:** distcc-ng's `distcc` MUST be tested against a real, independently built `distccd`, such as a stock distribution package rather than this fork's server binary.

**Pass criteria:** The required real compile workload completes through the independent server.

### **VER-INTEROP-02** Independent client against distcc-ng server

**Applies when:** External-host or protocol compatibility can change.

**Requirement:** A real independently built `distcc`, such as a stock distribution package, MUST be tested against distcc-ng's `distccd`.

**Invalid evidence:** Assuming Direction B from Direction A. Client and server code paths are different and a regression can affect only one direction.

### **VER-INTEROP-03** Non-trivial workload in both directions

**Applies when:** `VER-INTEROP-01` or `VER-INTEROP-02` applies.

**Requirement:** Each direction MUST use its own real, non-trivial compile workload.

The workload MUST be an actual third-party C project or equivalent non-trivial project rather than a single hello-world file.

It MUST use real parallelism so that large files, concurrency, and varied compiler flags receive meaningful exercise.

### **VER-INTEROP-04** Fallback disabled during compatibility load

**Applies when:** Interoperability is tested.

**Requirement:** `DISTCC_FALLBACK=0` MUST be used.

**Pass criteria:** The complete build succeeds with fallback disabled, providing evidence that compiled files actually round-tripped through the remote server instead of silently compiling locally.

### **VER-INTEROP-05** No committed private test host

**Applies when:** A real external host is involved.

**Requirement:** A private test IP address or hostname MUST NOT be committed.

Documentation MUST use placeholders. Environment-specific values MUST remain only in the permitted test environment or approved secret or variable mechanism.

**References:** `AGENTS.md` Secrets And Sensitive Data requirements.

## Downloaded external source and test artifacts

### **VER-SOURCE-01** Upstream checksum verification

**Applies when:** An external source archive or artifact is downloaded for use as a workload or test dependency.

**Requirement:** Its checksum MUST be verified against the upstream project's own published checksum before it is used.

When a second independent upstream URL or mirror exists, the checksum SHOULD also be obtained from that second source.

**Invalid evidence:** Successful download alone.

## Configuration file and settings changes

Relevant files and settings include `/etc/distcc/distccd.conf`, `/etc/distcc/distcc.conf`, `src/config-parser.c`, `src/sandbox-config.c`, and `src/client-config.c`.

### **VER-CONFIG-01** Real setting behavior

**Applies when:** A config key or configuration behavior changes.

**Requirement:** The actual setting MUST be tested through a real config file on disk and a real client or daemon.

**Procedure:** Start the real program with the real file and observe the setting's downstream effect, such as:

* changed trace behavior;
* changed exit status;
* changed file mode;
* other applicable runtime behavior.

**Invalid evidence:** A parser-only test proving only that the string can be parsed.

### **VER-CONFIG-02** Config versus environment precedence

**Applies when:** A setting has both a config-file form and an environment-variable form.

**Requirement:** All three cases MUST be run:

1. environment variable set, file value unset;
2. file value set, environment variable unset;
3. both set to different values.

**Pass criteria:** The actual precedence matches the intended contract. For the behavior recorded by the source checklist, the environment variable MUST win when both are set.

**Invalid evidence:** Documentation stating the precedence without a real run.

### **VER-CONFIG-03** Missing, empty, and unknown config cases

**Applies when:** Config loading or parser behavior changes.

**Requirement:** The following cases MUST be tested separately:

1. missing config file;
2. empty config file;
3. unknown key.

**Pass criteria:** Each case degrades to the compiled-in default or the intended logged warning rather than an unintended hard failure.

**Invalid evidence:** Reading `dcc_config_load()` documentation alone.

### **VER-CONFIG-04** Object linkage for shared config code

**Applies when:** A new object file is added for a new config module or another shared symbol dependency changes.

**Requirement:** The object MUST be linked into every binary that actually needs the symbol.

Anything reachable from `dcc_scan_args()` is relevant to both `distcc` and `distccd`, so dependencies shared by that path belong in the appropriate shared object list such as `common_obj`, not only the object list of the binary that motivated the change.

**Procedure:** Run a full `make` covering both binaries.

**Pass criteria:** Every required binary links successfully.

**Invalid evidence:** Building only the binary originally under development.

**Known failure class:** This repository has previously failed with an undefined reference in `distccd` because a new shared dependency was linked only into the initially targeted binary.

## Input and argument validation

Relevant changes include user-controlled strings used as format strings, sizes, paths, or structurally significant values, including `lsdistcc`'s `get_thename()`, `dcc_sane_env_path()`, `src/config-parser.c`, and compiler options such as `-specs=` and `-M*`.

### **VER-INPUT-01** Exact validator semantics

**Applies when:** A validator checks whether input contains, equals, or consists only of a required token or pattern.

**Requirement:** The verification MUST state which semantic the validator enforces.

`contains X` MUST NOT be treated as equivalent to `is exactly X` or `consists only of X`.

A check such as `strstr(fmt, "%d")` proves only that the token exists somewhere. It can still allow attacker-controlled additional content.

### **VER-INPUT-02** Before and after malicious-input reproduction

**Applies when:** Validation is introduced to stop a malicious or unsafe input.

**Requirement:** The test MUST use a deliberately malicious input crafted to pass a naive implementation of the check.

The behavior MUST be demonstrated before and after the fix where feasible.

For a memory-safety issue, an AddressSanitizer or Valgrind instrumented binary MUST be used where appropriate.

**Pass criteria:** The pre-fix code demonstrates the crash or violation, and the fixed code demonstrates its absence.

**Invalid evidence:** One valid input plus one completely unrelated invalid input.

**References:** Issue #226, `lsdistcc` format-string fix.

### **VER-INPUT-03** Valid-input regression control

**Applies when:** Input validation becomes stricter.

**Requirement:** Realistic valid inputs that legitimately vary MUST still work.

For printf-like format handling, this includes legitimate flags, width, and precision before a conversion specifier where supported.

**Pass criteria:** The attack is rejected while valid use remains accepted.

### **VER-INPUT-04** Alternate path coverage

**Applies when:** The same input can reach another caller, alternate encoding, or different execution path.

**Requirement:** The fix MUST be verified on those additional paths and MUST NOT be considered complete merely because the original proof of concept is blocked.

## Cleanup

These checks are required for any verification run that starts processes, daemons, containers, networks, temporary system state, or similar resources.

### **VER-CLEANUP-01** Containers

**Requirement:** No new test container may remain unintentionally after verification.

**Procedure:** Inspect `docker ps -a`.

**Pass criteria:** The result is clean or every remaining entry is explicitly identified as pre-existing, unrelated, or intentionally retained.

### **VER-CLEANUP-02** Daemon and compiler processes

**Requirement:** No new `distcc`, `distccd`, or compiler process may remain unintentionally.

**Procedure:** Inspect the process table, for example with an appropriate `ps` query.

### **VER-CLEANUP-03** Reparented distccd zombies

**Applies when:** Containers were used.

**Requirement:** No persistent `[distccd] <defunct>` process reparented to PID 1 may remain.

A transient zombie whose live parent has not yet called `waitpid()` is not by itself a failure.

The significant condition is a reparented `distccd` zombie owned by PID 1 or an equivalent non-reaping PID 1 wrapper.

**Procedure:** Use `ps auxf`, `docker top`, or equivalent process-tree evidence.

**References:** `VER-CONTAINER-08`.

### **VER-CLEANUP-04** Images and networks

**Requirement:** One-off images and networks MUST be removed unless intentionally retained for reuse.

An intentional retained resource MUST be recorded as such.

### **VER-CLEANUP-05** Temporarily modified system state

**Requirement:** Any temporarily moved, renamed, or otherwise altered system state MUST be restored.

Example: a masquerade directory temporarily moved away to verify its absence.

### **VER-CLEANUP-06** Pre-existing leftovers

**Requirement:** Any relevant leftover that existed before the current run MUST be reported separately.

The record MUST state whether the pre-existing resource was left or removed.

**Invalid evidence:** Reporting `no leftovers` when the actual meaning is only `no new leftovers`.

Pre-existing leftovers and leftovers created by the current run MUST NOT be conflated.

## Container-based verification

This section applies to Docker-based build and test execution, especially verification involving `gdb`, `strace`, `ltrace`, ptrace, privilege drops, UID mapping, seccomp, capabilities, daemonization, pump mode, or other permission-sensitive behavior.

### **VER-CONTAINER-01** SYS_PTRACE and Docker seccomp are independent gates

**Applies when:** `gdb`, `strace`, `ltrace`, ptrace, or `gdb`'s ASLR-disabling `personality(2)` operation is required.

**Requirement:** Linux capabilities and Docker seccomp MUST be treated as separate enforcement layers.

`--cap-add=SYS_PTRACE` alone does not guarantee that ptrace-related calls or `personality(ADDR_NO_RANDOMIZE)` are permitted.

**Procedure:**

1. Add `--cap-add=SYS_PTRACE`.
2. If the same `Operation not permitted` result still occurs, treat that as evidence that a second gate may still be closed.
3. Use the repository's narrow verification profile:

`--security-opt seccomp=./docker/verify/seccomp-verify.json`

The profile retains Docker's default filter and adds the required `personality(ADDR_NO_RANDOMIZE)` allowance.

**Requirement:** The narrow verification profile SHOULD be preferred over `--security-opt seccomp=unconfined`.

**Invalid evidence:** Repeatedly checking only the capability after the identical denial remains.

**References:** Issue #264, Issue #285.

### **VER-CONTAINER-02** Bind-mounted checkout UID mapping

**Applies when:** The host checkout is bind-mounted into the verification image and the host owner UID differs from the image's baked-in non-root UID.

**Requirement:** The container SHOULD run as the caller's own numeric UID and GID:

`docker run --user "$(id -u):$(id -g)" ...`

The normal verification path MUST NOT rely on running the whole build as container root merely to make the bind-mounted checkout writable.

**Known behavior:** Running as the image's unrelated non-root user can fail with errors such as:

`Permission denied`

or:

`autom4te: error: cannot create autom4te.cache in ...: Permission denied`

Running the whole step as root can activate `distccd`'s real `dcc_discard_root()` drop to `uid=65534` or nobody. Tests such as `Unicode_Case`, including the `maintainer-check-no-set-path` path, can then fail when the dropped process writes into a root-owned test directory.

That is an environment ownership mismatch, not evidence that the privilege-drop implementation is defective.

**Recorded verification:** PR #405 compared:

* root plus `chown` plus `su`;
* `--user $(id -u):$(id -g)`;
* an image rebuilt with a matching UID build argument.

At that time all three produced byte-identical `test/testdistcc.py` and comfychair results: 138 OK, 16 NOTRUN, 0 FAIL.

After PR #406 added `PathQualifiedCompilerNotSubstituted_Case`, the corresponding count became 142 OK, 16 NOTRUN, 0 FAIL at commit `caee881d`.

`--user` was adopted because it requires no image rebuild and works with the exact unmodified published image.

**References:** Issue #264, Issue #286, PR #405, PR #406, `.github/workflows/verify-image-build.yml`.

### **VER-CONTAINER-03** Explicit container-internal HOME

**Applies when:** `docker run --user <numeric-uid>:<numeric-gid>` is used.

**Requirement:** A writable container-internal `HOME` MUST be supplied explicitly.

Example:

`-e HOME=/tmp/some-name`

The directory MUST be created inside the container command before tools requiring it run.

**Known behavior:** Docker does not synthesize an `/etc/passwd` entry for an arbitrary numeric UID. Without an explicit usable home, `$HOME` can resolve to `/`, which the numeric user cannot write.

Tools such as `ccache` can therefore fail.

A host path such as `$RUNNER_TEMP/some-name` MUST NOT be used as the container's `HOME` unless that host path is actually bind-mounted into the container.

Creating the host path only on the runner does not make it exist inside the container.

**Recorded failure:** A ccache plus Redis remote-storage self-test used a runner-side `$RUNNER_TEMP` path as `HOME` without mounting it and failed with `ccache: error: Permission denied`.

### **VER-CONTAINER-04** Resolvable passwd and group entry

**Applies when:** A numeric `--user` UID is not present in the image's `/etc/passwd`.

**Requirement:** Tools that call `getpwuid(getuid())` MUST receive a resolvable user identity.

A writable `HOME` alone is not sufficient.

**Procedure:**

1. Read the image's real `/etc/passwd` and `/etc/group`.
2. Add a synthetic entry matching `$(id -u)` and `$(id -g)`.
3. Bind-mount the generated passwd and group files read-only over `/etc/passwd` and `/etc/group`.
4. Keep the container non-root.

**Known behavior:** OpenSSH `ssh-keygen` calls `getpwuid(getuid())` and exits with:

`No user exists for uid <uid>`

when no matching entry exists, even when `-f` is supplied.

This surfaced through `SSHMode_Case`.

**References:** `.github/workflows/verify-image-build.yml`, `CONTRIBUTING.md`.

### **VER-CONTAINER-05** Rootless Docker status and interpretation

**Type:** Recorded environment result and standing implementation decision.

**Requirement:** Rootless Docker MUST NOT be assumed either unsupported or required without rechecking the current repository environment.

The following facts were empirically established and are retained because they affect future decisions:

1. The unmodified `test/e2e/run-e2e.sh` and `test/e2e/docker-compose.yml` were run with `DOCKER_CONTEXT=rootless`.
2. The rootless two-container run completed 187 real remote compiles.
3. Server-side logs confirmed the remote compiles.
4. The distributed object was byte-identical to the local-only build.
5. Rootless Docker successfully managed the custom bridge network and fixed `10.88.0.0/24` subnet from its own namespace.
6. At commit `caee881d`, rootful `--user "$(id -u):$(id -g)"` and rootless `--user 1000:1000` produced 142 OK, 16 NOTRUN, 0 FAIL with line-for-line identical case-result lists, including `Gdb_Case`, `GdbOpt1-3_Case`, and `GdbPrefixMap_Case`.
7. A genuine GitHub `ubuntu-latest` runner was proven capable of running rootless Docker.
8. On that runner, installation alongside the already-running rootful daemon required `FORCE_ROOTLESS_INSTALL=1`.
9. Ubuntu 24.04's `kernel.apparmor_restrict_unprivileged_userns=1` required `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`.
10. The successful probe was job `rootless_docker_ghactions_probe` in Actions run `30935447301`.
11. That job concluded successfully even though the overall throwaway workflow run showed `cancelled` because two unrelated jobs were separately cancelled.
12. Rootless Docker was not adopted for normal repository CI.
13. The reason is setup cost rather than correctness. Rootless execution required two additional sudo-requiring setup operations for every job, while `--user` required no equivalent setup.
14. The repository CI at the time used `ubuntu-latest` and no self-hosted runner.
15. The isolation benefit was judged more relevant to persistent, multi-tenant self-hosted infrastructure than to GitHub's ephemeral single-job runners.
16. Rootless Docker remains a viable option to reconsider if persistent self-hosted runners are introduced.

**References:** Issue #286 follow-up, Actions run 30935447301.

### **VER-CONTAINER-06** Known host-specific maintainer-check-no-set-path failure

**Type:** Known unresolved environment-specific interpretation rule.

**Known condition:** On some Docker hosts, `make check` can reach the trailing `maintainer-check-no-set-path` rerun and fail with:

`/bin/sh: 1: distccd: not found`

even when every preceding real `test/testdistcc.py` case has already passed.

This has been reproduced on a clean unmodified `current_dev` checkout on the affected host.

The same commits pass the corresponding GitHub Actions `make_check` job.

The root cause has not been determined.

A hypothesis involving Makefile `PATH` propagation into Python subprocesses has not been confirmed and MUST NOT be stated as established fact.

**Requirement:** This known condition MAY be used to classify such a failure as the recorded host quirk only when the exact pattern matches.

**Required evidence:**

* every real case through the final `test/testdistcc.py` comfychair case has already reported `OK` or valid `NOTRUN`;
* the failure occurs strictly in the trailing `maintainer-check-no-set-path` rerun;
* the observed error matches the known failure.

**Invalid evidence:** Pattern-matching on the Make target name alone.

### **VER-CONTAINER-07** Root is not equivalent to host root

**Applies when:** A test needs a privileged syscall.

**Requirement:** The specific Linux capability required by the syscall MUST be provided. Merely running the container as UID 0 is insufficient.

**Known example:** `AutogroupNicenessPrivilegeDrop_Case` exercises a negative `nice(2)` value through `dcc_set_autogroup_niceness()` in `src/dparent.c`.

Container root without `CAP_SYS_NICE` produced:

`nice -5 failed: Operation not permitted`

Adding:

`--cap-add=SYS_NICE`

was required.

**Invalid evidence:** Treating `Operation not permitted` from container root as a code regression before checking the syscall's required capability.

**Reference context:** Verified while preparing release 3.6.1-NG on 2026-07-23.

### **VER-CONTAINER-08** Real init process required for daemonizing tests

**Applies when:** Container verification starts `distccd --daemon` or another daemonizing process whose children can be reparented.

**Requirement:** The container MUST have a PID 1 that reaps orphaned child processes.

For Docker verification, `--init` SHOULD be used.

**Implementation facts retained for diagnosis:**

1. `distccd --daemon` uses `dcc_detach()` in `src/dparent.c`.
2. `dcc_detach()` forks.
3. The immediate parent calls `_exit(0)`.
4. The child calls `setsid()`.
5. The daemon is therefore intentionally orphaned and reparented to PID 1 in the namespace.
6. `su` and `bash` do not act as a general init reaper for reparented zombies.
7. `test/testdistcc.py`'s `WithDaemon_Case.killDaemon()` cannot `wait()` the detached daemon.
8. It sends `SIGTERM`.
9. It polls `os.kill(pid, 0)` until `ESRCH`.
10. A zombie retains a PID table entry, so `os.kill(pid, 0)` continues to succeed.
11. Without a reaper, this loop can continue indefinitely at approximately 0.2 second intervals.
12. The hung process can consume near-zero CPU and produce no error output, making it look like a slow test.
13. `ps auxf` shows the diagnostic condition as one or more `[distccd] <defunct>` entries reparented to PID 1 or the non-reaping wrapper.
14. `--init` runs `tini`, which reaps the orphaned zombies.
15. The issue is a generic init-less container problem, not a defect in distcc-ng's normal daemonization mechanism.

**Pass criteria:** The test terminates and no persistent reparented `distccd` zombie remains.

**References:** Release 3.6.3-NG verification, 2026-07-30, and `VER-CLEANUP-03`.

### **VER-CONTAINER-09** Compressed ELF debug-section limitation

**Type:** Implementation limitation fixed in the libelf path (#487, #526); retained only in the raw fallback path built without libelf. Required verification interpretation.

**Affected behavior:** `Gdb_Case` and `GdbOpt1-3_Case` in pump mode when the toolchain emits compressed ELF debug sections.

**Implementation facts:**

1. `src/fix_debug_info.c`'s `dcc_fix_debug_info()` rewrites the server-side compilation directory embedded in DWARF debug information to the client-side directory.
2. Relevant sections include `.debug_info`, `.debug_str`, and `.debug_line_str`.
3. The implementation performs a raw byte search and replacement on mmap'd ELF section contents.
4. `replace_string()` uses raw `memcmp` and `memcpy` style substring handling rather than parsing DWARF structure.
5. `.debug_info` and `.debug_line_str` are structured binary DWARF data even when they are not compressed.
6. The current raw search assumes that the server-side path remains present byte-for-byte in the section buffer.
7. A compressed section breaks that assumption.
8. On `alpine:latest`, recorded as Alpine 3.24.1 with `gcc (Alpine) 15.2.0` on 2026-08-01, `.debug_line_str` acquired the ELF `SHF_COMPRESSED` flag when the compilation-directory string became sufficiently long.
9. `readelf -SW` showed the `C` compressed flag.
10. The raw section bytes contained zlib magic `789c...`.
11. `gcc -### -gz -g -c t.c -o t.o` with a real source file showed GCC invoking `as --compress-debug-sections=zlib`.
12. Omitting the source file from the `gcc -###` probe does not show the assembler invocation and therefore is not a valid equivalent probe.
13. The GNU assembler performs the actual compression operation.
14. Compression was observed to be size-dependent rather than a fixed default.
15. A short directory such as `/tmp/check2` produced an uncompressed section and could make the test appear to pass.
16. A longer realistic distccd compile-working directory reliably triggered compression in the recorded environment.
17. That working directory is formed by `make_temp_dir_and_chdir_for_cpp()` in `src/serve.c` using `dcc_get_new_tmpdir()` plus the client cwd.
18. `dcc_make_tmpnam()` is a different function and names individual files such as the object output rather than this working directory.
19. The `mkdtemp()` suffix is six characters and MUST NOT be assumed to be hexadecimal.
20. After decompression, the expected search path is present as plain text.
21. In the compressed raw bytes, the path is not present byte-for-byte.
22. `update_section()` therefore reports zero occurrences to `replace_string()`.
23. This is logged by the existing `rs_trace()` message stating that the section has no occurrences of the expected path.
24. The failure is non-fatal and the function can still return success.
25. The path rewrite therefore does not happen.
26. The resulting object retains the server-side compilation directory.
27. Client-side gdb can then fail to find the source and report a warning equivalent to `<file>: No such file or directory`.
28. A Debian 13 container with `gcc (Debian 14.2.0-19)` produced uncompressed debug sections at the same tested path lengths and the same test passed.
29. The Debian and Alpine observations used different GCC versions and different distribution configurations. They are not a controlled same-compiler comparison.
30. Debian 13 or trixie and trixie-backports were recorded as not providing GCC 15 at the time.
31. `-gz=none` on the recorded Alpine toolchain removed `SHF_COMPRESSED`.
32. This proves that the assembler compression flag controls whether compression occurs in that test.
33. It does not prove whether the cross-distribution difference is caused by GCC version, distribution GCC build configuration, assembler configuration, or another toolchain factor.
34. Until matched compiler versions are tested, the condition MUST be described as toolchain or distro-configuration dependent rather than attributed to a specific cause.
35. This behavior is unrelated to the repository's network-level zstd compression work in Issue #101 and uses a different code path.
36. The defect was independently isolated by building the `TEST` main in `src/fix_debug_info.c` and calling `dcc_fix_debug_info()` directly on a real object with a known compilation directory.
37. The standalone test reproduced the failure, localizing the problem to the raw-byte rewrite design rather than another `distccd` pipeline stage.
38. The issue was recorded as not yet fixed when the source checklist was written; it has since been fixed. With `HAVE_LIBELF`, `dcc_fix_debug_info()` decompresses the affected section before the rewrite and recompresses after (#487 for `SHF_COMPRESSED`, #526 for GNU-compressed `.zdebug_*` via `elf_compress_gnu()`). Only the raw fallback path built without libelf retains the limitation.

**Verification requirement:** Any test claiming this path works across toolchains MUST include a path length and toolchain capable of exercising the compressed-section case. A short-path smoke test MUST NOT be treated as sufficient.

**References:** Issue #398, Issue #101, PR #487, PR #526.

### **VER-CONTAINER-10** Pump-mode coverage must be proven explicitly

**Applies when:** Pump behavior or a pump-sensitive test is relevant.

**Known behavior:** A local `make check` inside the buildtools container can fail before `pump-maintainer-check` on hosts affected by `VER-CONTAINER-06`.

`Makefile.in`'s `maintainer-check` prerequisites are ordered with plain `distcc-maintainer-check`, `include-server-maintainer-check`, and `pump-maintainer-check`. GNU Make normally stops after a failed prerequisite.

Therefore, a failure in the plain-mode chain can prevent pump mode from running at all.

**Recorded evidence:**

* Issue #275 and PR #440 on 2026-08-07 exposed `NonexistentSourceFile_Case` and `CcacheHitThroughDistcc_Case` as pump-only failures after earlier local runs had been treated as complete.
* Issue #442 established that the host-specific prerequisite failure does not occur on every Docker host.
* On another host using the same buildtools image, `make check` reached `TESTDISTCC_OPTS="--pump "` and completed the suite under pump mode.
* That recorded run produced 174 OK, 26 NOTRUN, 0 FAIL combined across the two modes.

**Requirement:** A specific pump-sensitive case MUST be directly runnable with:

`make TESTNAME=<Case> pump-single-test`

when independent pump evidence is required.

This target is not gated behind the complete prerequisite chain.

**Pass criteria:** The intended case actually runs under pump mode and passes.

**Invalid evidence:** Assuming that a local `make check` covered pump mode without reading its log.

If the local run failed in the trailing `maintainer-check-no-set-path` path, it MUST NOT be described as complete pump coverage.

Actual repository CI remains authoritative for final pump behavior where required.

## Vendored dependency provenance

Relevant changes include the `popt/` fallback tree and any future vendored third-party source.

### **VER-VENDOR-01** Exact source commit pin

**Applies when:** A vendored source is updated or its upstream source changes.

**Requirement:** The vendored source MUST be pinned to an exact commit SHA.

A branch name or moving tag MUST NOT be the only provenance identifier.

For `popt/`, the SHA MUST be recorded in `popt/POPT_VERSION`.

The corresponding CI verification, currently `popt_vendor_check` in `c-build.yml`, MUST use the exact same value.

**Failure condition:** Updating the marker without updating the check can break CI. Loosening the check instead of keeping exact equality can silently stop provenance verification and MUST NOT be used as a workaround.

### **VER-VENDOR-02** File-by-file vendored diff

**Applies when:** The vendored source changes.

**Requirement:** Every changed vendored file MUST be compared against the previous vendored copy.

The review MUST identify actual API changes, removed macros, new warnings, warnings-as-errors effects, and other relevant changes.

**Invalid evidence:** `The new tree builds`.

A large time gap between the previous vendored source and the new source can include substantially more than the motivating fix.

### **VER-VENDOR-03** CVE before and after reproduction

**Applies when:** The new vendored source's history identifies a specific CVE fix.

**Requirement:** `Fixed upstream` alone MUST NOT be treated as proof.

**Procedure:**

1. Obtain the exact pre-fix version of the affected file from the upstream project's history, for example through `git show <parent-sha>:path` or an equivalent hosted API.
2. Replace only that file in an otherwise current test build.
3. Reproduce the vulnerability with the upstream reproducer when one exists.
4. For a memory-safety CVE, use AddressSanitizer, UBSan, or another appropriate runtime detector.
5. Confirm the pre-fix version reproduces the flaw.
6. Restore the current vendored file.
7. Confirm the flaw is absent.

**Pass criteria:** The vulnerability reproduces with the exact pre-fix file and does not reproduce with the current vendored file.

### **VER-VENDOR-04** Actual consumers and complete linkage

**Applies when:** The vendored library or its build integration changes.

**Requirement:** A full `make` MUST verify every binary that actually consumes the vendored library.

The current consumer list MUST be read from `Makefile.in` rather than assumed from memory.

At the time this requirement was recorded, the bundled `popt/` tree was linked by:

* `distccd` through `src/dopt.c`'s `@BUILD_POPT@`;
* `h_dopt`;
* `h_srvrpc`.

At that time the following did not use bundled popt:

* `distcc`;
* `lsdistcc`;
* `distccmon-text`;
* `pump`.

This list is a recorded state, not a permanent assumption. Recertification MUST verify it against current code.

### **VER-VENDOR-05** UID and environment disclosure

**Applies when:** Vendored code is verified.

**Requirement:** The actual UID and environment used by the verification build and test MUST be recorded.

A test run interrupted, skipped, or invalidated by unrelated environment behavior MUST NOT be reported as complete coverage of the vendored update.

**Reference context:** PR #504 changed `popt/` from `rpm-software-management/popt`'s `popt-1.19-release` tag to `wiki-mod/popt-ng`. The update incorporated approximately four years of upstream changes, including CVE-2026-18739 and CVE-2026-18743. Both CVEs received the before and after sanitizer treatment represented by `VER-VENDOR-03`.

## New distribution packaging

This section applies when adding a package recipe or package format not previously shipped by this repository, such as a new `APKBUILD`, RPM recipe, Debian-equivalent recipe, or another package format. It does not automatically apply to a routine version bump of an already-verified recipe.

Issue #398 Thread A and PR #515 established that recipe syntax and similarity to existing packaging are not sufficient evidence.

### **VER-PACKAGE-01** Target-distribution dependency names

**Applies when:** A new distribution package recipe declares build dependencies.

**Requirement:** Every package dependency name MUST be confirmed to exist under that exact name on the target distribution.

**Procedure:** Use the target distribution's package manager in a real target-distribution container or equivalent eligible environment.

For Alpine, this means an actual command such as `apk add <name>`.

**Recorded example:** Debian uses `libelf-dev`; Alpine uses `elfutils-dev`.

**Invalid evidence:** Assuming another distribution uses the same package name.

### **VER-PACKAGE-02** Test dependencies versus build dependencies

**Applies when:** A new distribution package recipe is verified.

**Requirement:** Test-suite dependencies MUST be checked separately from configure and compile dependencies.

**Recorded Alpine base-image state:** A bare `alpine:latest` environment lacked:

* `gdb`;
* `ccache`;
* `ssh`;
* `sshd`;
* `ssh-keygen`.

It also did not provide the repository's IPv6 test configuration through `--enable-rfc2553`.

In that state, `make check` can report the relevant tests as `NOTRUN` rather than failing.

Relevant skipped cases include:

* `Gdb*_Case`;
* `CcacheHitThroughDistcc_Case`;
* `SSHMode_Case`;
* `IPv6Compile_Case`.

**Requirement:** A green suite containing these environment-caused `NOTRUN` results MUST NOT be represented as full coverage.

`gdb` is also a real `checkdepends` requirement if packaging later re-enables `check()` under `abuild`.

### **VER-PACKAGE-03** Vendored versus system dependency selection

**Applies when:** The repository intentionally requires a vendored dependency instead of the target distribution's system package.

**Requirement:** Every packaging recipe MUST set the applicable opt-out or selection flag explicitly.

**Recorded example:** PR #504 added `--without-system-popt` to `docker/release/Dockerfile` so release builds use this fork's CVE-fixed vendored `popt/`.

An Alpine `APKBUILD` draft omitted that option and silently linked Alpine's system `libpopt`.

**Procedure:** Confirm the actual link command.

For the popt case, distinguish:

`-lpopt`

from the intended bundled objects such as:

`popt/popt.o popt/poptconfig.o ...`

The system package SHOULD be removed from the verification container when needed to prove that the intended vendored path is actually used.

**Invalid evidence:** Assuming the intended dependency was selected because configure succeeded.

### **VER-PACKAGE-04** Packaging sandbox versus direct test environment

**Applies when:** The packaging tool executes tests inside its own sandbox, fakeroot layer, or equivalent environment.

**Requirement:** Packaging-tool results and direct correctness verification MUST be kept distinct when privilege semantics differ.

**Recorded Alpine behavior:** `abuild -r` executes `check()` under `fakeroot`.

Inside the recorded fakeroot environment:

* plain `id` reported `uid=0`;
* `id -u` reported the real unprivileged UID.

This inconsistent view can activate `distccd`'s root privilege-drop logic while the underlying filesystem permissions remain those of the real unprivileged user.

The resulting failure is an environment artifact and not automatically a code regression.

**Requirement:** Actual correctness evidence MUST come from a real non-fakeroot, non-root run when this mismatch affects the test.

When gdb tests are involved, the environment MAY additionally require `--cap-add=SYS_PTRACE` and the narrow `docker/verify/seccomp-verify.json` profile defined by `VER-CONTAINER-01`.

**Invalid evidence:** Treating the packaging tool's own test sandbox as behaviorally identical to the direct runtime environment.

### **VER-PACKAGE-05** Automatic split-function ordering

**Applies when:** A packaging format applies automatic subpackage split functions and custom split functions to the same files.

**Requirement:** The actual function ordering MUST be tested through a complete package build.

**Recorded Alpine behavior:** The generic `-pyc` split mechanism expects the original package directory to remain intact.

If a custom split function moves the relevant files first and the `$pkgname-foo-pyc` split is listed afterward, the automatic split can find nothing and fail the build.

**Procedure:** Run the actual complete packaging command, such as `abuild -r`.

**Invalid evidence:** Confirming only that all intended names appear in `subpackages=`.

### **VER-PACKAGE-06** Packaging metadata format validation

**Applies when:** A new packaging format requires metadata fields.

**Requirement:** Required metadata MUST be validated by the packaging tool itself.

**Recorded Alpine behavior:** `abuild` validates the `# Maintainer:` header as an RFC822 address and rejects a bare project or organization name.

**Invalid evidence:** A visually plausible metadata value that has not passed the packaging tool.

### **VER-PACKAGE-07** Source local filename and checksum identity

**Applies when:** The package recipe downloads a source archive and maintains a checksum manifest.

**Requirement:** The source declaration and checksum manifest MUST refer to the same local filename.

**Recorded GitHub tag-archive behavior:** A URL ending in `v$pkgver.tar.gz` does not automatically become a differently named local file such as `distcc-ng-$pkgver.tar.gz`.

For Alpine, an explicit source rename such as `localname::url` can establish the intended name.

**Pass criteria:** The packaging tool's own fetch and checksum phase succeeds using the intended local name.

**Invalid evidence:** Comparing the source and checksum lines visually without running the package tool.

**References:** Issue #398 Thread A, PR #515.

# Release readiness

The release checks below are additional release gates. They do not replace any applicable `VER-*` check.

A release MUST execute the applicable development and behavioral checks for every relevant change since the previous release.

## Release governance and sign-off

### **REL-GOV-01** Candidate SHA identity

**Applies when:** A release is being prepared.

**Requirement:** The Candidate SHA recorded in the release PR MUST still match the actual intended release candidate when the checklist is treated as complete.

**Pass criteria:** The recorded SHA and actual candidate are identical.

### **REL-GOV-02** Release blockers

**Requirement:** No unresolved release blocker may remain open.

**Pass criteria:** Every blocker is resolved or the release is not ready.

### **REL-GOV-03** Final AGENTS.md self-check

**Requirement:** A final `AGENTS.md` self-check required by Rule 78(c) MUST be performed.

At minimum it MUST include:

* tracking metadata under Rule 3;
* PR scope under Rule 58;
* comment style under Rules 38 through 42;
* real validation evidence under Rules 31 through 37;
* support-upstream handling under Rule 57.

**Invalid evidence:** Assuming the release complies because its task-specific checks passed.

### **REL-GOV-04** Independent release PR review

**Requirement:** An independent review of the finished release PR required by Rule 78(a) MUST be performed.

It MUST be distinct from `REL-GOV-03`.

## Before cutting `release/X.Y.Z-NG`

### **REL-PRECUT-01** Changelog coverage of PR history

**Requirement:** `CHANGELOG.md`'s `[Unreleased]` section MUST be reviewed end to end against the actual PR and commit history since the previous tag.

A suitable history source is:

`git log <last-tag>..HEAD --oneline`

The history MUST be used to check the changelog. The changelog MUST NOT be used as the only source for deciding what history exists.

**Pass criteria:** Every user-visible change is represented and no merged user-visible change is silently missing.

### **REL-PRECUT-02** Dated section for every prior tag

**Requirement:** A real dated heading:

`## [X.Y.Z-NG] - YYYY-MM-DD`

MUST exist with real content for every tag since the last point at which this check was completed.

Checking only `[Unreleased]` is insufficient.

**Recorded failure class:** Issue #460 found that v3.6.2-NG, v3.6.3-NG, and v3.6.4-NG had no corresponding dated sections on `current_dev`, leaving their content combined under `[Unreleased]` through later releases.

**References:** Issue #460, PR #465.

### **REL-PRECUT-03** Open security issues

**Requirement:** There MUST be no unresolved `security`-labeled issue that should block the release.

Alternatively, shipping despite such an issue requires an explicit, dated, documented maintainer decision with the reasoning recorded.

The decision MUST identify what is accepted and why.

**Invalid evidence:** Silence or omission.

**Reference:** Issue #266 leak-triage precedent.

### **REL-PRECUT-04** Release-version script

**Requirement:** `scripts/check-release-version.sh` MUST be executed against the intended tag.

**Invalid evidence:** Reading `configure.ac` and concluding that `AC_INIT` looks correct.

### **REL-PRECUT-05** support-upstream completeness

**Requirement:** Every `support-upstream/` entry opened since the previous release MUST have:

1. its own entry file;
2. its `support-upstream/README.md` index row.

**Procedure:** Read the real diff, for example:

`git diff <last-tag>..HEAD -- support-upstream/`

**Invalid evidence:** CI green alone.

**Reference:** `AGENTS.md` Rule 58.

### **REL-PRECUT-06** Default-branch release-event workflow parity

**Requirement:** `master`'s copy of every workflow whose `release:` event is required for publication or post-publication automation MUST match the required `current_dev` behavior before tagging.

This includes `changelog-update-on-release.yml` and any workflow behavior that `package-release.yml` relies on for release publication identity or related release-event processing.

**Recorded behavior:** GitHub evaluates the relevant `release` event workflow from the repository's default branch, which is `master`, rather than taking that workflow definition from the newly created tag.

Issue #460 and PR #467 established that a stale `master` copy can silently prevent automatic changelog processing.

**Procedure:**

1. Diff the relevant workflow files between `master` and `current_dev`.
2. If they differ, either promote the required workflow change to `master` before tagging or use the workflow's explicit dispatch recovery path for this release.
3. A recovery dispatch for the changelog workflow MUST target `current_dev` explicitly.

Example:

`gh workflow run changelog-update-on-release.yml --repo wiki-mod/distcc-ng --ref current_dev -f tag_name=... -f release_notes=...`

An unqualified `gh workflow run` uses the workflow definition selected from the default branch unless another ref is explicitly supplied.

**Invalid evidence:** The current state of the branch diff at some historical date. Whether the diff passes today is transient and is not part of this check's definition.

**References:** Issue #460, PR #467.

### **REL-PRECUT-07** No release-only fixes

**Requirement:** The release branch MUST contain no fix that exists only on the release branch relative to `current_dev`.

**Procedure:** Use an explicit reproducible comparison such as:

`git diff current_dev...release/X.Y.Z-NG`

**Invalid evidence:** Familiarity with the branch or assumption that no one changed it.

### **REL-PRECUT-08** No unreviewed release-branch drift

**Requirement:** The release branch MUST have only its expected relationship to `current_dev` and its intentional cut point.

**Procedure:** Use an explicit ancestry and ahead-content check, for example:

`git merge-base --is-ancestor current_dev release/X.Y.Z-NG`

plus inspection of anything ahead of the relevant merge base.

**Invalid evidence:** Assumption based on branch names or expected workflow.

### **REL-PRECUT-09** Complete change-range verification classification

**Requirement:** Every commit or PR merged since the previous release tag MUST be classified against every applicable `VER-*` category in this document.

Every verification category actually touched by a change MUST have real evidence behind it.

Evidence MAY be:

* a named relevant CI test that actually ran and passed;
* a fresh manual verification satisfying this document.

The sweep MUST be complete and itemized across the entire change range.

Spot-checking a subset MUST NOT be treated as equivalent.

**Historical wording note:** The predecessor release checklist referred to `9 categories` because that was the number present at that time. This combined checklist is intentionally extensible. The normative requirement is every applicable current verification category, not a permanently fixed number.

**Recorded failure class:** Issue #460 Finding 5 on 2026-08-11 established that a release review had worked through the release checklist but had only spot-checked the per-commit verification classification.

**References:** Issue #460 Finding 5.

### **REL-PRECUT-10** master ancestry

**Requirement:** `master`'s tip MUST be an ancestor of the release branch head.

A suitable check is:

`git merge-base --is-ancestor <master-tip> <release-branch-head>`

The number of commits by which `master` is behind is irrelevant.

One independent commit on `master`, including a direct Dependabot merge or one-off CI change, is enough to break the required ancestry relationship.

**Known interpretation:** Issue #460 Finding 4 identified this as the leading but not fully confirmed explanation for a release PR's `pull_request` CI remaining silent through its review window.

That causal explanation MUST NOT be stated as proven unless separately established.

**Requirement:** If `master` is not an ancestor, the relationship MUST be resolved before the release PR's own CI is relied upon as evidence.

**Reference:** PR #463 promotion pattern.

## Release artifact verification

Applicable `VER-*` checks remain mandatory. These `REL-ART-*` items are release-specific additions.

### **REL-ART-01a** Published `distcc-ng` image identity

**Requirement:** The actual published `distcc-ng` image MUST be confirmed to contain the intended image identity.

A Docker build with no explicit `--target` builds the last stage in the Dockerfile, so appending an unrelated stage can silently change the published result.

**Procedure:** Inspect the real live pushed image through the registry API and confirm at minimum:

* `org.opencontainers.image.title`;
* relevant `COPY` history.

**Invalid evidence:** Reading the Dockerfile alone.

**References:** Issue #359.

### **REL-ART-01b** Published `distcc-ng-pump` image identity

**Requirement:** The same verification defined by `REL-ART-01a` MUST be performed for `distcc-ng-pump`.

### **REL-ART-01c** Published `distcc-ng-nightly` image identity

**Requirement:** The same verification defined by `REL-ART-01a` MUST be performed for `distcc-ng-nightly`.

### **REL-ART-02** Seccomp in every released distccd artifact

**Requirement:** Every real released `distccd` artifact, including containers and `.rpm` or `.deb` packages, MUST actually have the seccomp sandbox compiled in and enforcing.

**Procedure:** Apply the real negative syscall test defined by the applicable `VER-SECCOMP-*` checks to every affected artifact class.

**Invalid evidence:**

* dependency present in the build definition;
* configure detection;
* startup log alone.

A startup log proves the corresponding code path executed but does not prove that the denied syscall is actually denied.

**References:** Issue #360.

### **REL-ART-03** Real package dependency metadata

**Requirement:** The actual built `.rpm` and `.deb` artifacts MUST declare the dependencies required by their linked libraries.

**Procedure:** Inspect the real package with:

`rpm -qp --requires`

and:

`dpkg-deb -I`

as applicable.

A real CI-built package SHOULD be used because local and CI builds can differ in build flags and linked library versions.

The real packaging workflow can be dispatched before a tag with:

`gh workflow run package-release.yml --ref <branch> -f publish_container=false`

**Invalid evidence:** `ldd` against only a local development binary.

### **REL-ART-04a** Real distributed compile through plain shipped variant

**Requirement:** A real distributed compile MUST succeed end to end through the plain non-pump shipped image or package variant.

The test MUST use:

* a real client;
* a real server;
* a real network hop;
* server-side independent evidence.

**Invalid evidence:** Only the artifact's own internal self-test.

### **REL-ART-04b** Real distributed compile through pump shipped variant

**Requirement:** The same end-to-end test defined by `REL-ART-04a` MUST independently pass for the pump-mode variant.

This item remains separate because pump mode has previously gone entirely unexecuted in apparently successful local verification.

### **REL-ART-05** SBOM attached to the actual release

**Requirement:** The SBOM generated by `anchore/sbom-action` MUST actually be attached to the real GitHub Release.

**Invalid evidence:** The SBOM generation workflow step succeeding without inspection of the published release.

### **REL-ART-06** Build attestation attached to the actual release

**Requirement:** The build attestation generated by `actions/attest-build-provenance` MUST actually be attached to the real GitHub Release.

**Invalid evidence:** The attestation generation step succeeding without inspection of the published release.

## Conditional release artifact checks

Every item in this subsection MUST be classified as `PASS`, `FAIL`, `BLOCKED`, or `N/A`.

An `N/A` classification MUST state why its trigger does not apply and SHOULD identify the paths reviewed to establish that conclusion.

### **REL-ART-07** Effective seccomp filter after seccomp-related changes

**Applies when:** `src/sandbox-seccomp.c`, `src/sandbox-config.c`, or a Dockerfile stage building `distccd` changed since the previous release.

**Requirement:** The effective seccomp denylist MUST match intent for every affected artifact class.

**Procedure:** Apply the relevant `VER-SECCOMP-*` checks.

### **REL-ART-08** Negative seccomp enforcement after seccomp-related changes

**Applies when:** The same trigger as `REL-ART-07` applies.

**Requirement:** A real denied syscall MUST be proven blocked for every affected artifact class.

### **REL-ART-09** Real second-user permission test after permission changes

**Applies when:** A permission or file-mode affecting file changed, including examples such as `src/lock.c`, `src/state.c`, or `src/daemon.c`.

**Requirement:** The applicable `VER-PERM-*` second-user verification MUST pass on a real Unix-permission filesystem.

### **REL-ART-10** Distribution test after distribution or compiler-identity changes

**Applies when:** Distribution, scheduling, compiler identity, `src/arg.c`, `src/climasq.c`, or protocol-governed wire behavior changed.

**Requirement:** A real two-endpoint distribution test satisfying the applicable `VER-DIST-*` and `VER-COMPILER-*` checks MUST pass.

### **REL-ART-11** Published-stage identity after build-definition changes

**Applies when:** Any `docker/**/Dockerfile` or `package-release.yml` changed.

**Requirement:** Published-stage identity MUST be reconfirmed through the registry API for every affected Dockerfile target.

This is required even when `REL-ART-01a`, `REL-ART-01b`, or `REL-ART-01c` already exists as a general release check, because the publication definition itself changed during this release cycle.

## Compatibility and dependencies

### **REL-COMPAT-01** New hard dependency disclosure

**Applies when:** A new hard dependency was introduced since the previous release.

Examples include a new `apt` dependency, `BuildRequires` entry, or linked library.

**Requirement:** The dependency MUST be explicitly evaluated and documented against `doc/compatibility-policy.md`.

**Invalid evidence:** Treating it as an ordinary dependency bump without evaluating support impact.

### **REL-COMPAT-02** Platform-conditional behavior

**Applies when:** Platform-conditional code changed.

**Requirement:** The supported platform matrix in `doc/compatibility-policy.md`, including applicable FreeBSD, macOS, Cygwin, and current Linux behavior, MUST be reconfirmed for the changed code.

A change protected by `#ifdef` or configure-time detection on one platform MUST have its intended behavior or no-op behavior on the other supported platforms confirmed.

**Invalid evidence:** Assuming the conditional is correct because the source expression looks correct.

## CI and release pipeline sanity

Issue #460 identified two distinct release-pipeline failure classes represented here:

* release PR CI existence;
* release-event changelog automation.

The confirmed mechanism for the changelog automation involved the GitHub token anti-recursion behavior corrected by PR #467.

The exact cause of all observed release-PR CI timing behavior in Finding 4 was not fully proven and MUST NOT be described as fully established.

### **REL-CI-01** Real pull_request CI for the release PR

**Requirement:** A real `pull_request`-triggered CI run MUST exist for the release PR itself.

**Invalid evidence:**

* `pull_request_target`;
* `workflow_dispatch`;
* another branch's CI.

If the release PR CI is `Failed` or `Blocked`, the release branch relationship covered by `REL-PRECUT-07` and `REL-PRECUT-08` SHOULD be checked before the condition is classified as benign.

**Reference:** Issue #460 Finding 4.

### **REL-CI-02** Manual pre-tag artifact verification run record

**Applies when:** A manual `workflow_dispatch` package or artifact verification run was used.

**Requirement:** Its run URL and result MUST be recorded.

### **REL-CI-03** Real tag-triggered package release run

**Requirement:** The actual tag-triggered `package-release.yml` run for the pushed tag MUST exist and MUST succeed.

### **REL-CI-04** Published-release changelog event

**Requirement:** The `release: types: [published]` event MUST actually trigger `changelog-update-on-release.yml` for the real tag.

This item cannot pass while `REL-PRECUT-06` fails because stale default-branch workflow content can prevent the event processing required by the release.

**References:** Issue #460 Finding 2, PR #467.

## Release documentation

### **REL-DOC-01** Quick-start publication references

**Requirement:** `README.md` and `doc/docker.md` quick-start references MUST match the artifacts the release will actually publish.

This includes image tags and package names.

**Procedure:** Compare the documentation to the actual intended release artifact list.

**Invalid evidence:** Carrying values forward from the previous release without reading them.

### **REL-DOC-02** User-visible changes under dated changelog section

**Requirement:** Every user-visible behavior change since the previous release MUST appear under a real dated `CHANGELOG.md` release section by the time the release is announced.

A change belonging to an already shipped release MUST NOT remain stranded under `[Unreleased]`.

## Promotion of `current_dev` to `master`

### **REL-PROMO-01** Fresh maintainer approval

**Requirement:** The promotion MUST have explicit fresh maintainer approval for this specific promotion.

Approval from an earlier promotion or another PR MUST NOT be reused.

**References:** `AGENTS.md` Rule 21 and the current replacement status of Rule 52.

### **REL-PROMO-02** Read actual promotion commit range

**Requirement:** `git log master..current_dev` MUST actually be read before promotion.

**Pass criteria:** The promotion contains no unrelated or unreviewed work that was assumed away because it had already been discussed elsewhere.

### **REL-PROMO-03** Advance current_dev version after tagging

**Requirement:** `current_dev`'s `configure.ac` MUST be bumped to the next planned version immediately after tagging as defined by `doc/release-versioning.md`.

**Reason:** No later build from `current_dev` should continue reporting the version that has already been released.

### **REL-PROMO-04** Account for automated changelog commit

**Requirement:** The automated `changelog-update-on-release.yml` commit defined by `doc/release-versioning.md` MUST actually land on `current_dev`, and its content MUST be explicitly accounted for in the release's real promotion to `master`.

The frozen release branch cannot receive that post-release commit by design.

**Procedure:**

1. Check Actions history for the successful workflow run at the release tag's time.
2. Confirm the automated commit actually exists on `current_dev`.
3. Record how that commit is incorporated into this release's promotion to `master`.

**Invalid evidence:** Looking only at the final visible `CHANGELOG.md` content without accounting for the actual automated commit and branch relationship.

# Checklist maintenance and extension

### **VER-META-01** Add missing verification classes in the same PR

**Applies when:** A non-trivial change exposes behavior that does not fit an existing verification item cleanly.

**Requirement:** A new verification item or family MUST be added as part of the same PR.

An existing item MUST NOT be stretched beyond its real scope merely to avoid adding a new check.

The absence of an existing checklist item MUST NOT be used as a reason to skip real verification.

**Recorded examples:**

* configuration checks were added after Issue #207 introduced the first client-side config file;
* input-validation checks were added after Issue #226;
* container checks were added after Issue #264;
* vendored dependency checks were added after PR #504;
* new distribution packaging checks were added after Issue #398 Thread A and PR #515.

### **VER-META-02** Proactive coverage-gap question

**Applies when:** Any non-trivial change is verified.

**Requirement:** Verification MUST explicitly consider whether the actual changed behavior falls outside the existing checklist.

The question is not only whether existing checks passed. The question is also whether the change introduced a verification class that the current checklist does not describe.

A change that technically satisfies existing wording but clearly exercises a materially different behavior class is itself evidence that this document requires extension.

This is a standing requirement, not a one-time backfill task.

The checklist MUST be treated as a living document and MUST NOT be assumed permanently complete.

### **VER-META-03** Real evidence reporting

**Applies when:** Any checklist item is executed.

**Requirement:** The record MUST state what was actually run and what was actually observed.

Examples include:

* log excerpt;
* `stat` result;
* exit code;
* server-side `COMPILE_OK`;
* package metadata;
* actual release attachment;
* actual filesystem state.

If a required check cannot be performed because of access, environment, artifact availability, or another real limitation, it MUST be marked `BLOCKED` with the reason.

It MUST NOT be silently omitted.

# Last Full Recertification Against current_dev Code

This section MUST remain the final section of this document.

Its purpose is to prove that the checklist itself, not only a particular software change, has been reviewed against the actual current repository state.

A full recertification is not the same as executing every runtime test for a release.

It is a complete review of every checklist item's continued correctness, scope, commands, paths, functions, assumptions, expected results, references, and relationship to the actual `current_dev` implementation.

A historical successful verification MUST NOT by itself satisfy recertification.

Recertification MUST use a recorded `current_dev` commit SHA.

Every checklist item MUST be individually reviewed.

Each item MUST be classified as one of:

* `CURRENT`
* `UPDATED`
* `RETIRED`
* `REPLACED BY <ID>`

`RETIRED` MUST include the reason.

`REPLACED BY <ID>` MUST identify the replacement.

Stable IDs MUST NOT be reused.

The checklist MUST NOT claim full recertification while any applicable recertification item below remains incomplete.

### **RECERT-01** Record exact current_dev baseline

* [ ] Full recertification date recorded.
* [ ] Exact `current_dev` SHA recorded.
* [ ] Reviewer recorded.
* [ ] Independent reviewer recorded.
* [ ] Tracking issue or PR recorded.
* [ ] Result recorded.

### **RECERT-02** Authority and governance

* [ ] Current `AGENTS.md` read in full from the recorded `current_dev` SHA.
* [ ] Rule 0 relationship remains correct.
* [ ] Current verification-evidence environment rules remain correctly represented.
* [ ] Current release governance rules remain correctly represented.
* [ ] No checklist wording conflicts with a newer `AGENTS.md` rule.
* [ ] All AGENTS.md rule references in this document still identify the intended requirements.

### **RECERT-03** Baseline checks

* [ ] Every `VER-BASE-*` item reviewed against current code and current test behavior.
* [ ] Build commands remain current.
* [ ] Test targets remain current.
* [ ] OS-state examples remain technically valid.
* [ ] UID and privilege classifications remain sufficient.

### **RECERT-04** Permission checks

* [ ] Every `VER-PERM-*` item reviewed.
* [ ] Referenced files still exist or were updated.
* [ ] `ModeBits_Case` or its replacement identified.
* [ ] Cross-user deployment assumptions remain current.
* [ ] Files added since the previous recertification were checked for missing permission verification coverage.

### **RECERT-05** Sandbox and seccomp checks

* [ ] Every `VER-SECCOMP-*` item reviewed.
* [ ] Current sandbox source paths confirmed.
* [ ] Current filter action confirmed.
* [ ] Current denylist behavior confirmed.
* [ ] Current marker technique remains capable of exercising the intended filter.
* [ ] Current compiler-name rewrite behavior accounted for.
* [ ] Current package inspection commands remain correct.
* [ ] Current seccomp dependency policy remains correct.

### **RECERT-06** Distribution and scheduling checks

* [ ] Every `VER-DIST-*` item reviewed.
* [ ] Current server-side evidence method confirmed.
* [ ] Current `COMPILE_OK` semantics confirmed.
* [ ] Current fallback behavior confirmed.
* [ ] Current E2E scripts and paths confirmed.
* [ ] New distribution modes since the previous recertification checked for missing coverage.

### **RECERT-07** Compiler identity checks

* [ ] Every `VER-COMPILER-*` item reviewed.
* [ ] Current compiler rewrite functions confirmed.
* [ ] Current whitelist behavior confirmed.
* [ ] Current `dcc_execvp()` behavior confirmed.
* [ ] Current test daemon flags confirmed.
* [ ] Current verification image cross-toolchain availability confirmed.
* [ ] Marker-test assumptions confirmed against current client and server behavior.

### **RECERT-08** External interoperability checks

* [ ] Every `VER-INTEROP-*` item reviewed.
* [ ] Both interoperability directions remain required where applicable.
* [ ] Current independently built client and server test sources identified.
* [ ] Current fallback semantics confirmed.
* [ ] Current non-trivial workload requirement remains sufficient.

### **RECERT-09** External source provenance checks

* [ ] Every `VER-SOURCE-*` item reviewed.
* [ ] Upstream checksum verification requirement remains sufficient.
* [ ] Current artifact acquisition paths checked for new provenance risks.

### **RECERT-10** Configuration checks

* [ ] Every `VER-CONFIG-*` item reviewed.
* [ ] Current config paths confirmed.
* [ ] Current parser functions confirmed.
* [ ] Current environment precedence confirmed.
* [ ] Current missing, empty, and unknown-key behavior confirmed.
* [ ] Current object linkage structure confirmed.

### **RECERT-11** Input validation checks

* [ ] Every `VER-INPUT-*` item reviewed.
* [ ] Current validators and relevant callers identified.
* [ ] Before and after security reproduction requirement remains applicable.
* [ ] Current sanitizer or runtime-detector expectations reviewed.
* [ ] Alternate caller and encoding coverage remains sufficient.

### **RECERT-12** Cleanup checks

* [ ] Every `VER-CLEANUP-*` item reviewed.
* [ ] Current daemon lifecycle behavior confirmed.
* [ ] Current container cleanup requirements confirmed.
* [ ] Current zombie diagnostic remains correct.
* [ ] Current temporary-state restoration requirements remain sufficient.

### **RECERT-13** Container checks

* [ ] Every `VER-CONTAINER-*` item reviewed.
* [ ] Current buildtools image invocation confirmed.
* [ ] Current seccomp verification profile confirmed.
* [ ] Current capability requirements confirmed.
* [ ] Current UID mapping method confirmed.
* [ ] Current HOME handling confirmed.
* [ ] Current passwd and group handling confirmed.
* [ ] Rootless Docker recorded facts checked for continued relevance.
* [ ] Known `maintainer-check-no-set-path` behavior checked to determine whether it still reproduces.
* [ ] `--init` requirement checked against current daemon and harness behavior.
* [ ] Compressed ELF debug-section limitation checked against current implementation and Issue #398 status.
* [ ] Pump-mode direct test target confirmed.
* [ ] Historical test counts are still clearly marked as historical rather than current expectations.

### **RECERT-14** Vendored dependencies

* [ ] Every `VER-VENDOR-*` item reviewed.
* [ ] Current vendored trees identified.
* [ ] Current provenance markers identified.
* [ ] Current CI provenance checks identified.
* [ ] Current binary consumers identified from the build system.
* [ ] Current CVE verification requirements remain sufficient.
* [ ] Any new vendored dependency since the previous recertification has appropriate coverage.

### **RECERT-15** Distribution packaging

* [ ] Every `VER-PACKAGE-*` item reviewed.
* [ ] Current supported package formats identified.
* [ ] Current target-distribution dependency names checked.
* [ ] Current test dependencies checked separately from build dependencies.
* [ ] Current vendored-versus-system dependency policy confirmed.
* [ ] Current packaging sandbox behavior confirmed.
* [ ] Current split-function behavior confirmed where applicable.
* [ ] Current metadata requirements confirmed.
* [ ] Current source and checksum naming behavior confirmed.
* [ ] New package formats since the previous recertification have corresponding verification checks.

### **RECERT-16** Release governance

* [ ] Every `REL-GOV-*` item reviewed.
* [ ] Current release PR process confirmed.
* [ ] Current Candidate SHA requirements confirmed.
* [ ] Current blocker handling confirmed.
* [ ] Current self-review and independent-review gates confirmed.

### **RECERT-17** Pre-cut release checks

* [ ] Every `REL-PRECUT-*` item reviewed.
* [ ] Current changelog structure confirmed.
* [ ] Current release-version script confirmed.
* [ ] Current support-upstream structure confirmed.
* [ ] Current release workflow branch semantics confirmed.
* [ ] Current release branch ancestry model confirmed.
* [ ] Complete change-range classification requirement covers every current `VER-*` family.
* [ ] No obsolete fixed category count remains normative.

### **RECERT-18** Release artifacts

* [ ] Every `REL-ART-*` item reviewed.
* [ ] Current published image set confirmed.
* [ ] Current image identity fields confirmed.
* [ ] Current registry inspection procedure confirmed.
* [ ] Current released package formats confirmed.
* [ ] Current seccomp artifact coverage confirmed.
* [ ] Current distributed plain and pump artifact tests confirmed.
* [ ] Current SBOM mechanism confirmed.
* [ ] Current build-attestation mechanism confirmed.
* [ ] Conditional artifact triggers still match current source and workflow paths.

### **RECERT-19** Compatibility and dependency release checks

* [ ] Every `REL-COMPAT-*` item reviewed.
* [ ] Current compatibility-policy platform matrix confirmed.
* [ ] Current hard-dependency policy confirmed.
* [ ] New platforms or removed platforms since the previous recertification accounted for.

### **RECERT-20** CI and release pipeline

* [ ] Every `REL-CI-*` item reviewed.
* [ ] Current release PR CI trigger confirmed.
* [ ] Current manual pre-tag workflow confirmed.
* [ ] Current tag-triggered package workflow confirmed.
* [ ] Current release-published changelog workflow confirmed.
* [ ] Current token or publication identity behavior confirmed.
* [ ] Issue #460 references still accurately describe unresolved versus confirmed mechanisms.

### **RECERT-21** Release documentation

* [ ] Every `REL-DOC-*` item reviewed.
* [ ] Current README publication references confirmed.
* [ ] Current `doc/docker.md` publication references confirmed.
* [ ] Current changelog publication requirements confirmed.

### **RECERT-22** Promotion to master

* [ ] Every `REL-PROMO-*` item reviewed.
* [ ] Current maintainer approval rule confirmed.
* [ ] Current branch promotion sequence confirmed.
* [ ] Current post-tag version bump sequence confirmed.
* [ ] Current automated changelog commit behavior confirmed.
* [ ] Current release-versioning step references confirmed.

### **RECERT-23** Checklist maintenance model

* [ ] Every `VER-META-*` item reviewed.
* [ ] Stable-ID policy remains compatible with repository governance.
* [ ] New verification gaps since the previous recertification were identified.
* [ ] No relevant implementation area is known to exist without a matching verification family.
* [ ] No item is being stretched beyond its actual technical scope to avoid creating a new ID.

### **RECERT-24** Complete reference audit

* [ ] Every source file path in this document checked against `current_dev`.
* [ ] Every function name checked.
* [ ] Every test case name checked.
* [ ] Every Make target checked.
* [ ] Every workflow filename checked.
* [ ] Every package command checked.
* [ ] Every Docker option and repository-specific invocation checked.
* [ ] Every Issue and PR reference checked for continued relevance.
* [ ] Every internal checklist cross-reference checked.
* [ ] Every reference to another repository document checked.
* [ ] No stale reference remains silently accepted.

### **RECERT-25** Complete semantic audit

* [ ] Every requirement reviewed for continued technical correctness.
* [ ] Every pass criterion reviewed.
* [ ] Every invalid-evidence rule reviewed.
* [ ] Every known constraint reviewed.
* [ ] Every historical fact remains clearly distinguished from a current requirement.
* [ ] Every unresolved hypothesis remains identified as unconfirmed.
* [ ] No historical result is presented as current state without re-verification.
* [ ] No story or chronology is required to understand an actionable check.
* [ ] Removing narrative wording has not removed any technical information.
* [ ] No requirement from the predecessor verification checklist was lost.
* [ ] No requirement from the predecessor release checklist was lost.
* [ ] No requirement has been weakened by wording normalization.

### **RECERT-26** Final full-list completeness decision

* [ ] Every checklist item was reviewed individually.
* [ ] Every item is classified `CURRENT`, `UPDATED`, `RETIRED`, or `REPLACED BY <ID>`.
* [ ] Every `UPDATED` item was checked again after its update.
* [ ] Every `RETIRED` item contains a reason.
* [ ] Every replacement points to the replacement ID.
* [ ] No stable ID was reused.
* [ ] No known new subsystem, external interaction, artifact class, package format, workflow behavior, or failure class lacks an applicable checklist item.
* [ ] Independent reviewer completed the final review.
* [ ] The recorded `current_dev` SHA still matches the code against which this recertification was performed.
* [ ] Full recertification is declared complete only after all checks above are satisfied.

## Last full recertification record

Date:

`current_dev` SHA:

Reviewer:

Independent reviewer:

Tracking issue:

Tracking PR:

Items reviewed:

Items updated:

Items retired:

Items replaced:

New items added:

Unresolved recertification blockers:

Result:

The `Result` field MUST remain empty or state `NOT FULLY RECERTIFIED` until `RECERT-01` through `RECERT-26` are complete against the exact recorded `current_dev` SHA.
