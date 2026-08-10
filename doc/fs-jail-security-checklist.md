# Filesystem Jail Security Verification Checklist

This is the living verification checklist for Issue #289, the filesystem jail for remote compilation. It is intended to be used by implementation PRs and security reviews as an executable checklist, not as a prose design document.

The original detailed implementation plan remains in Issue #289 for historical context. This document is the maintained verification record and release gate.

This checklist follows the repository's `doc/verification-checklist.md` convention: `make check` is necessary but does not prove new behavior. Tests must exercise the claimed behavior directly and record the actual result. See `AGENTS.md` rules 27 and 31 through 32.

## Status vocabulary

Use one of the following for every applicable item:

- [ ] NOT TESTED
- [ ] PASS
- [ ] FAIL
- [ ] BLOCKED
- [ ] NOT APPLICABLE

For completed verification, record the command, environment, observed result, and evidence where practical.

## 0. Scope and security guarantees

- [ ] Define the exact security guarantee provided by the filesystem jail.
- [ ] Define what is explicitly outside the scope of Issue #289, including unrelated distribution or packaging work.
- [ ] Define whether the jail is optional or required by configuration.
- [ ] Define fail-open versus fail-closed behavior. If jail mode is required, jail setup failure must not silently fall back to an unsafe unrestricted remote compile.
- [ ] Define supported platforms and the behavior on unsupported platforms.
- [ ] Define the expected relationship between the filesystem jail and the existing Seccomp sandbox.
- [ ] Define whether network isolation is in scope. Do not imply that filesystem isolation is a complete network sandbox.
- [ ] Define whether resource limits such as CPU, memory, process count, and disk usage are in scope. If not, document the boundary.

## 1. Prototype regression tests

These are named regression tests for concrete defects already found during development of the prototype. They must remain explicit so that a reimplementation cannot silently reproduce them.

### 1.1 Original UID/GID must be captured before `CLONE_NEWUSER`

Background: the prototype initially read `getuid()` and `getgid()` after `unshare(CLONE_NEWUSER)`. The kernel then returned the namespace overflow sentinel, 65534 (`nobody`), instead of the original host identity.

Required invariant:

- [ ] Capture the original UID before `unshare(CLONE_NEWUSER)`.
- [ ] Capture the original GID before `unshare(CLONE_NEWUSER)`.
- [ ] Establish UID/GID mappings using those original identities.
- [ ] Verify that 65534 is never accidentally treated as the original host UID or GID.
- [ ] Run this test with a real non-root identity as well as the root-started path where applicable.

Expected result: namespace mappings represent the actual original identity, not 65534/`nobody`.

### 1.2 Original working directory must be preserved before `pivot_root`

Background: the prototype initially called `getcwd()` only after `pivot_root()` followed by `chdir("/")`. At that point the original working directory could no longer be recovered correctly.

Required invariant:

- [ ] Capture all state needed to restore the original working directory before `pivot_root()` changes the filesystem context.
- [ ] Enter the jail and perform `pivot_root()`.
- [ ] Change to the jail root as required for the compiler.
- [ ] Complete the job and leave the jail.
- [ ] Verify that the parent process retains the original working directory.
- [ ] Test a normal directory, a nested directory, and a directory reached through a symlink where applicable.

Expected result: the caller's original working directory is preserved and is not reconstructed from post-`pivot_root()` state.

## 2. Existing CI namespace capability spike

Do this before adding new CI plumbing. The existing `verify-image-build.yml` `make_check` container already uses `--security-opt seccomp=unconfined` and `--cap-add=SYS_PTRACE`. The prototype demonstrated that Docker's default Seccomp profile blocks `unshare --user --mount` unless that restriction is removed or the required capability is added.

The existing `seccomp=unconfined` setting must therefore be verified first rather than assuming new Docker configuration is required.

- [ ] Confirm the current `verify-image-build.yml` `make_check` container still contains `--security-opt seccomp=unconfined`.
- [ ] Confirm `unshare --user` works inside the existing verification container.
- [ ] Confirm `unshare --mount` works where required.
- [ ] Confirm `unshare --user --mount` works.
- [ ] Confirm UID/GID mapping works inside the existing container.
- [ ] Confirm a controlled mount operation works inside the namespace.
- [ ] Confirm `pivot_root()` works in the actual test environment.
- [ ] Confirm the old root can be detached after `pivot_root()`.
- [ ] Confirm the host or outer container mount namespace is unchanged afterwards.
- [ ] Confirm cleanup works on both success and failure paths.
- [ ] Determine empirically whether `CAP_SYS_ADMIN` is actually required. Do not add it preemptively.
- [ ] Keep `SYS_PTRACE` and `SYS_ADMIN` conceptually separate. Existing `SYS_PTRACE` does not by itself prove that `CAP_SYS_ADMIN` is available.
- [ ] If the existing CI environment is sufficient, reuse it rather than introducing redundant Docker capability or security-option changes.
- [ ] If it is insufficient, document the exact failed operation and the minimum additional permission required before changing CI.

## 3. Job root and filesystem lifecycle

- [ ] Every remote compile receives one dedicated job root.
- [ ] Job root creation is atomic and resistant to name collisions and symlink races.
- [ ] Job root ownership and permissions are verified immediately after creation.
- [ ] Temporary compiler files are inside the job's controlled filesystem view.
- [ ] `temp_o` is either created inside the jail or exposed through an explicitly controlled mount.
- [ ] `deps_fname` is handled inside the jail without depending on an unrelated host `/tmp` path.
- [ ] Pump files are inside the correct job filesystem view.
- [ ] Output files have one clearly defined ownership and lifecycle model.
- [ ] Cleanup removes the job root on success.
- [ ] Cleanup removes the job root on compiler failure.
- [ ] Cleanup removes the job root on timeout.
- [ ] Cleanup removes the job root on client disconnect.
- [ ] Cleanup removes the job root after signals and abnormal child termination.

## 4. User namespace and identity

- [ ] `CLONE_NEWUSER` is established at the correct point in the lifecycle.
- [ ] Original UID/GID are captured before entering the user namespace.
- [ ] UID mapping is correct.
- [ ] GID mapping is correct.
- [ ] Namespace root is not host root.
- [ ] Root-started `distccd` path is tested.
- [ ] `distccd --user` or equivalent privilege-drop path is tested.
- [ ] Already non-root `distccd` path is tested.
- [ ] Effective UID and GID inside the compiler process are recorded.
- [ ] Capabilities inside the compiler process are audited.
- [ ] The compiler does not acquire host-level privileges through namespace setup.

## 5. Mount namespace and propagation

- [ ] `CLONE_NEWNS` is established before jail-specific mounts are changed.
- [ ] Mount propagation is made private as required.
- [ ] Host mount propagation into or out of the job is impossible through normal job activity.
- [ ] Mount state is captured before the job.
- [ ] Mount state is inspected after the job.
- [ ] Mount state is unchanged after successful cleanup.
- [ ] Mount state is unchanged after each failure path.
- [ ] Parallel jobs do not affect one another's mount namespaces.

## 6. Jail root and `pivot_root`

- [ ] A dedicated jail root is created.
- [ ] Required directories are created before entering the compiler.
- [ ] Required mounts are installed before `pivot_root()`.
- [ ] `pivot_root()` changes the compiler's root to the job jail.
- [ ] The old root is moved to a controlled temporary mountpoint.
- [ ] The old root is detached after the pivot.
- [ ] `/proc/self/root` shows the jail root from the compiler's perspective.
- [ ] `/proc/self/cwd` is correct inside the jail.
- [ ] The original working directory is preserved for the parent process.
- [ ] `findmnt` and `/proc/self/mountinfo` show no unintended old-root access.
- [ ] Failure of any pivot step aborts jail creation safely.

## 7. Mount policy and trust model

For every exposed path, record whether it is readable, writable, executable, and why it is needed.

- [ ] Define a server-controlled allowlist of filesystem roots.
- [ ] Do not derive trusted host mount targets from client-controlled symlink destinations.
- [ ] Validate canonical paths against real path-component boundaries.
- [ ] Avoid simple string-prefix checks that accept paths such as `/usr/lib-evil` as children of `/usr/lib`.
- [ ] Treat `realpath()` as path information, not as a complete security policy.
- [ ] Avoid time-of-check/time-of-use races between client-controlled path validation and later access.
- [ ] Prefer stable, server-controlled mount sources.
- [ ] Record every read-only mount explicitly.
- [ ] Record every writable mount explicitly.
- [ ] Record every executable mount explicitly.
- [ ] Minimize the exposed host filesystem rather than mounting broad host trees without justification.

## 8. Symlink security

- [ ] Absolute symlink into a forbidden host path.
- [ ] Relative symlink using `..` to leave the allowed tree.
- [ ] Multi-level symlink chain.
- [ ] Symlink chain ending in a forbidden file.
- [ ] Symlink chain ending in a forbidden directory.
- [ ] Symlink loop.
- [ ] Symlink replacement race during setup.
- [ ] Symlink in a compiler include path.
- [ ] Symlink in a Pump include tree.
- [ ] Symlink used in an output path.
- [ ] Symlink used to target a host canary.

Expected result: no client-controlled symlink can cause an unauthorized host filesystem exposure or write.

## 9. Hardlinks and filesystem operations

- [ ] Evaluate hardlink behavior explicitly.
- [ ] Attempt a hardlink from client-controlled data to an existing protected file where filesystem semantics permit the attempt.
- [ ] Verify that cross-mount boundaries prevent unintended hardlink escapes where relied upon.
- [ ] Test `link()`.
- [ ] Test `linkat()`.
- [ ] Test `rename()`.
- [ ] Test `renameat()`.
- [ ] Test `renameat2()` where available.
- [ ] Test `unlink()` and `unlinkat()`.
- [ ] Test `mkdir()` and `rmdir()`.
- [ ] Test that write operations remain confined to the permitted job area.

## 10. File descriptor isolation

- [ ] Audit all descriptors inherited by the compiler.
- [ ] Confirm stdin, stdout, stderr and explicitly required descriptors are the only expected inherited descriptors.
- [ ] Open a host secret file before jail creation and verify that the compiler cannot use the inherited descriptor to read it.
- [ ] Open a host directory before jail creation and verify that it cannot provide an escape to the old root.
- [ ] Inspect `/proc/self/fd` from the compiler process.
- [ ] Verify that mount-control descriptors do not leak into the compiler.
- [ ] Verify that unexpected host sockets do not leak into the compiler.
- [ ] Verify that all descriptors with filesystem access have the intended `CLOEXEC` behavior.

## 11. `/dev`

- [ ] Define the minimum device set required by supported compilers.
- [ ] Provide `/dev/null` if required.
- [ ] Provide `/dev/zero` if required.
- [ ] Provide `/dev/random` or `/dev/urandom` if required.
- [ ] Define `/dev/fd` behavior if required.
- [ ] Do not expose the host `/dev` wholesale without an explicit security justification.
- [ ] Verify `/dev/mem` is inaccessible.
- [ ] Verify `/dev/kmem` is inaccessible where relevant.
- [ ] Verify `/dev/kmsg` is inaccessible where relevant.
- [ ] Verify block devices such as `/dev/sda` and `/dev/nvme*` are inaccessible.

## 12. `/proc`, `/sys`, and shared memory

- [ ] Decide whether `/proc` is needed.
- [ ] If `/proc` is needed, provide a controlled procfs view.
- [ ] Test `/proc/self/root`.
- [ ] Test `/proc/self/cwd`.
- [ ] Test `/proc/self/mountinfo`.
- [ ] Test `/proc/1` and process visibility.
- [ ] Verify that host process information is not unnecessarily exposed.
- [ ] Decide whether `/sys` is needed.
- [ ] Do not expose host `/sys` unless explicitly justified.
- [ ] If `/dev/shm` is needed, use an isolated mount rather than the host shared-memory mount.

## 13. `/etc`, secrets, and host information disclosure

- [ ] Determine which `/etc` files are actually required by the compiler runtime.
- [ ] Do not blindly expose the complete host `/etc`.
- [ ] Verify host `/etc/shadow` is inaccessible.
- [ ] Verify SSH keys are inaccessible.
- [ ] Verify `/root/.ssh` is inaccessible.
- [ ] Verify users' SSH keys are inaccessible.
- [ ] Verify service credentials and environment files are inaccessible.
- [ ] Verify cloud credentials are inaccessible.
- [ ] Verify arbitrary host files are inaccessible.
- [ ] Check compiler diagnostics for accidental disclosure of sensitive host paths.
- [ ] Check jail and security logs for unnecessary disclosure of sensitive paths.

## 14. Environment isolation

Review at least:

`HOME`, `PATH`, `TMPDIR`, `PWD`, `LD_LIBRARY_PATH`, `LD_PRELOAD`, `CPATH`, `C_INCLUDE_PATH`, `CPLUS_INCLUDE_PATH`, `LIBRARY_PATH`, `GCC_EXEC_PREFIX`, and `COMPILER_PATH`.

- [ ] Define a safe environment for the compiler.
- [ ] Verify `TMPDIR` points into the controlled filesystem.
- [ ] Verify `PATH` cannot cause a client-controlled executable to replace a trusted toolchain executable.
- [ ] Verify `LD_PRELOAD` cannot inject a client library into an unintended privileged process.
- [ ] Verify `LD_LIBRARY_PATH` cannot redirect trusted host processes to client libraries.
- [ ] Verify `SSH_AUTH_SOCK` is not unintentionally inherited.
- [ ] Review credential-like environment variables and remove or constrain them as appropriate.

## 15. Toolchain discovery

- [ ] GCC executable.
- [ ] G++ executable.
- [ ] `cc1`.
- [ ] `cc1plus`.
- [ ] assembler.
- [ ] linker.
- [ ] `collect2` where applicable.
- [ ] GCC runtime files.
- [ ] GCC specs.
- [ ] startup objects such as `crt1.o`, `crti.o`, and `crtn.o` where applicable.
- [ ] `libgcc`.
- [ ] `libstdc++` where applicable.
- [ ] GCC libexec paths.
- [ ] Clang executable if supported.
- [ ] Clang++ executable if supported.
- [ ] Clang resource directory if supported.
- [ ] LLVM libraries and helper executables required by supported configurations.
- [ ] `ld.bfd`, `ld.gold`, and `ld.lld` where supported.
- [ ] Non-standard toolchain locations such as `/usr/local` and `/opt` where supported.
- [ ] Compiler wrappers such as `ccache` and `sccache` where supported.
- [ ] Cross compilers where supported.

## 16. Compiler argument security

Explicitly evaluate and test arguments that can alter executable, library, sysroot, or toolchain selection.

- [ ] `-B` cannot cause an unauthorized client executable to be selected.
- [ ] `--sysroot` cannot expose the host root outside the jail policy.
- [ ] `-L` cannot create an unauthorized host library path.
- [ ] `-I` cannot escape the permitted filesystem view.
- [ ] `-isystem` cannot escape the permitted filesystem view.
- [ ] `-specs` and related GCC configuration options are evaluated.
- [ ] `-wrapper` is evaluated.
- [ ] `-plugin` and `-fplugin` are evaluated.
- [ ] LTO-related tool selection is evaluated.
- [ ] Client-controlled executable files cannot become trusted compiler helper programs merely by manipulating compiler arguments.

## 17. Plain compilation

For each supported compiler family, test both jail disabled and jail enabled.

- [ ] GCC C compile.
- [ ] GCC C++ compile.
- [ ] Clang C compile if supported.
- [ ] Clang C++ compile if supported.
- [ ] Relative input path.
- [ ] Absolute input path where protocol semantics permit it.
- [ ] Relative output path.
- [ ] Absolute output path where protocol semantics permit it.
- [ ] Output directory.
- [ ] Missing header.
- [ ] Syntax error.
- [ ] Invalid compiler option.
- [ ] Assembler error.
- [ ] Linker error where linking is supported by the test path.

## 18. Pump compilation

- [ ] GCC plus Pump.
- [ ] G++ plus Pump.
- [ ] Clang plus Pump where supported.
- [ ] Clang++ plus Pump where supported.
- [ ] Include server startup.
- [ ] Include server files are visible inside the jail as intended.
- [ ] Symlink mirror behavior is correct.
- [ ] Dependency generation remains correct.
- [ ] Output handling remains correct.
- [ ] Include server cleanup is complete.
- [ ] No include-server process remains after the job.
- [ ] No Pump pipe or descriptor remains unexpectedly open.

## 19. Output and dependency files

- [ ] Normal `.o` output.
- [ ] `.d` dependency output.
- [ ] `-MD`.
- [ ] `-MMD`.
- [ ] `-MF`.
- [ ] `-MT`.
- [ ] `-MQ`.
- [ ] Compiler temporary files.
- [ ] Debug-related temporary files where applicable.
- [ ] LTO temporary files.
- [ ] `-o ../../outside` style traversal attempt is rejected or safely contained.
- [ ] Absolute output targeting a protected host path is rejected or safely contained.
- [ ] Generated dependency content is correct, not merely the command exit code.

## 20. Debug information and path rewriting

- [ ] `-g`.
- [ ] `-g1`.
- [ ] `-g2`.
- [ ] `-g3`.
- [ ] `-fdebug-prefix-map`.
- [ ] `-fmacro-prefix-map`.
- [ ] Verify that jail paths do not cause unintended reproducibility or diagnostic regressions.

## 21. LTO, multilib, and cross compilation

- [ ] `-flto` with GCC where supported.
- [ ] LTO helper processes are visible and functional inside the jail.
- [ ] 32-bit toolchain where supported.
- [ ] 64-bit toolchain where supported.
- [ ] Multilib directories are correctly exposed where needed.
- [ ] Cross compiler where supported.
- [ ] Cross compiler helper tools are correctly exposed.
- [ ] Cross compiler cannot select arbitrary client executables as trusted helpers.

## 22. ccache and sccache integration

- [ ] ccache with jail enabled where supported.
- [ ] sccache with jail enabled where supported.
- [ ] Wrapper to compiler to toolchain resolution remains correct.
- [ ] Cache directories are not accidentally exposed as host write targets.
- [ ] Cache credentials or sockets are not leaked.

## 23. Security escape tests

Use explicit host canary files and directories. Do not rely only on the compiler returning an error.

- [ ] Read a host canary file from inside the jail.
- [ ] Write a host canary file from inside the jail.
- [ ] Enumerate a protected host directory.
- [ ] Execute a protected host executable where meaningful.
- [ ] Follow an absolute symlink to a host canary.
- [ ] Follow a relative symlink escaping the job tree.
- [ ] Attempt a hardlink escape where applicable.
- [ ] Attempt an `openat()` escape using a directory descriptor.
- [ ] Attempt `openat2()` path-resolution escape where available.
- [ ] Attempt `renameat()` or `unlinkat()` against a protected path.
- [ ] Attempt to use an inherited host file descriptor.
- [ ] Attempt `mount` after jail setup.
- [ ] Attempt `umount` after jail setup.
- [ ] Attempt `pivot_root` after jail setup.
- [ ] Attempt `chroot` after jail setup.
- [ ] Attempt `unshare` after jail setup.
- [ ] Attempt `setns` after jail setup.
- [ ] Attempt to create additional namespaces after jail setup.
- [ ] Attempt `ptrace` against a host process.
- [ ] Attempt to signal a host process.
- [ ] Attempt access to protected `/proc` information.

Expected result: every unauthorized access is denied or otherwise prevented by the combined isolation policy.

## 24. Existing security regressions

- [ ] Re-run all existing Issue #95 filesystem or sandbox escape regressions relevant to the jail.
- [ ] Re-run all existing Issue #292 filesystem or sandbox escape regressions relevant to the jail.
- [ ] Add each newly discovered escape technique as a permanent named regression test rather than leaving it only in an issue comment.
- [ ] Apply the repository Rule 27 principle: when a finding is discovered, test the whole failure class across build, test, CI, documentation, and release paths where applicable, not only the original line.

## 25. Seccomp interaction

Required order must be explicit and tested:

`fork -> file descriptor setup -> user namespace -> mount namespace -> mounts -> pivot_root -> old-root cleanup -> jail validation -> Seccomp -> compiler exec`

- [ ] Jail setup succeeds before Seccomp blocks required setup syscalls.
- [ ] Compiler starts only after the jail is established.
- [ ] Compiler cannot undo the jail after Seccomp is installed.
- [ ] `mount` is denied after setup.
- [ ] `umount` is denied after setup.
- [ ] `pivot_root` is denied after setup.
- [ ] `chroot` is denied after setup where required by policy.
- [ ] `unshare` is denied after setup where required by policy.
- [ ] `setns` is denied after setup where required by policy.
- [ ] `clone` or related namespace creation is denied where required by policy.
- [ ] A legitimate compile still succeeds under the final Seccomp policy.
- [ ] A deliberately denied syscall is actually blocked, not merely absent from the normal compile path.
- [ ] `fail-open` and `fail-closed` behavior are separately tested where supported.
- [ ] `require-seccomp` behavior is separately tested where supported.
- [ ] A build without libseccomp and a non-Linux host retain the documented behavior.

## 26. Failure handling

- [ ] User namespace creation failure.
- [ ] UID mapping failure.
- [ ] GID mapping failure.
- [ ] Mount namespace creation failure.
- [ ] Mount failure.
- [ ] `pivot_root()` failure.
- [ ] Old-root unmount failure.
- [ ] Seccomp installation failure.
- [ ] Compiler syntax error.
- [ ] Compiler crash.
- [ ] Compiler `SIGTERM`.
- [ ] Compiler `SIGKILL`.
- [ ] Compiler hang.
- [ ] Client disconnect.
- [ ] Timeout.
- [ ] Include server failure.
- [ ] Pump failure.
- [ ] Parent process interruption.
- [ ] Cleanup failure is observable and diagnosable.

For every failure path verify that no unsafe fallback, process leak, mount leak, or job-root leak occurs.

## 27. Cleanup and leak verification

- [ ] No unexpected compiler process remains.
- [ ] No `cc1` or `cc1plus` remains.
- [ ] No assembler or linker helper remains.
- [ ] No Pump include server remains.
- [ ] No unexpected child process remains.
- [ ] No zombie remains.
- [ ] No job root remains.
- [ ] No jail mount remains.
- [ ] No old-root mount remains.
- [ ] No unexpected file descriptor remains.
- [ ] Outer or host mount namespace is identical after cleanup.
- [ ] Cleanup is verified after success.
- [ ] Cleanup is verified after every relevant failure mode.

## 28. Parallelism and race conditions

- [ ] One simultaneous job.
- [ ] Two simultaneous jobs.
- [ ] Four simultaneous jobs.
- [ ] Eight simultaneous jobs.
- [ ] Higher parallelism appropriate to the test host.
- [ ] Every job has a separate mount namespace.
- [ ] Every job has a separate job root.
- [ ] Temporary files cannot collide.
- [ ] Output files cannot collide unexpectedly.
- [ ] One job cannot see another job's private files.
- [ ] Parallel mount setup is safe.
- [ ] Parallel cleanup is safe.
- [ ] Simultaneous symlink creation and cleanup is safe.
- [ ] Repeated stress runs do not produce intermittent mount or process leaks.

## 29. Filesystem edge cases

- [ ] Spaces in filenames.
- [ ] Unicode filenames.
- [ ] Newline in filename.
- [ ] Very long filename.
- [ ] Very deep directory tree.
- [ ] Empty file.
- [ ] Empty directory.
- [ ] Zero-byte source.
- [ ] Large source.
- [ ] Large header.
- [ ] Large dependency file.
- [ ] Large object file.
- [ ] Many files.
- [ ] Many include directories.
- [ ] Mount count remains bounded under realistic workloads.

## 30. Resource and exposure limits

These are scope-adjacent but must be consciously evaluated.

- [ ] Maximum expected mounts per job is documented.
- [ ] Maximum expected job file count is documented.
- [ ] Maximum path length assumptions are documented.
- [ ] Disk exhaustion behavior is understood.
- [ ] Process exhaustion behavior is understood.
- [ ] Memory exhaustion behavior is understood.
- [ ] CPU exhaustion behavior is understood.
- [ ] If resource limits are not implemented by Issue #289, the limitation is documented explicitly.

## 31. Logging and diagnostics

- [ ] User namespace failure is distinguishable.
- [ ] UID mapping failure is distinguishable.
- [ ] GID mapping failure is distinguishable.
- [ ] Mount namespace failure is distinguishable.
- [ ] Mount failure identifies the relevant controlled operation without leaking unnecessary sensitive host paths.
- [ ] `pivot_root()` failure is distinguishable.
- [ ] Seccomp failure is distinguishable.
- [ ] Cleanup failure is distinguishable.
- [ ] Security policy rejection is distinguishable from an ordinary compiler error.
- [ ] Logs do not unnecessarily expose secrets or sensitive host paths.

## 32. Configuration and compatibility

- [ ] Jail configuration has a clear documented default.
- [ ] Configuration file behavior is tested with a real daemon.
- [ ] Environment variable behavior is tested where applicable.
- [ ] Configuration precedence is tested where both mechanisms exist.
- [ ] Missing configuration file is tested.
- [ ] Empty configuration file is tested.
- [ ] Unknown configuration key is tested.
- [ ] Jail disabled retains the documented legacy behavior.
- [ ] Unsupported platform behavior is explicit and predictable.
- [ ] Linux kernel requirements are documented.
- [ ] Container requirements are documented.
- [ ] systemd deployment is tested where supported.
- [ ] Root-started daemon deployment is tested.
- [ ] Non-root daemon deployment is tested.

## 33. Platform matrix

For each supported environment record:

`distribution | kernel | libc | compiler | container | root/non-root | Seccomp | plain/pump | result`

- [ ] Representative Debian environment.
- [ ] Representative Ubuntu environment.
- [ ] Representative Fedora environment.
- [ ] Representative openSUSE environment.
- [ ] Alpine or another materially different userland if supported.
- [ ] Container execution.
- [ ] Native host execution.
- [ ] Different supported compiler versions as required by the compatibility policy.

Do not turn Issue #289 into unrelated Alpine packaging work. Separate packaging or BusyBox-specific issues remain separate unless explicitly brought into scope.

## 34. CI integration

- [ ] Existing `verify-image-build.yml` namespace capability spike passes.
- [ ] No redundant Docker security flags are added if the existing configuration is sufficient.
- [ ] If additional capability is genuinely required, document the exact syscall and reason.
- [ ] Unit tests run in CI.
- [ ] Namespace integration tests run in CI where the runner permits them.
- [ ] Security regression tests run in CI where the runner permits them.
- [ ] Plain E2E runs in CI.
- [ ] Pump E2E runs in CI.
- [ ] Full E2E runs in CI.
- [ ] CI failure is fail-closed for required security tests.
- [ ] Workflow changes are validated with `actionlint`.
- [ ] Workflow triggers, permissions, matrix behavior, and cache keys are reviewed.
- [ ] No CI test is weakened merely to make the branch green.

## 35. Unit, integration, security, E2E, and performance test separation

### Unit

- [ ] Path containment.
- [ ] Path normalization.
- [ ] Allowlist logic.
- [ ] Symlink policy.
- [ ] Configuration parsing.
- [ ] Error mapping.
- [ ] Mount policy representation.

### Integration

- [ ] Real user namespace.
- [ ] Real mount namespace.
- [ ] Real UID/GID mapping.
- [ ] Real mounts.
- [ ] Real `pivot_root()`.
- [ ] Real cleanup.
- [ ] Real Seccomp integration.

### Security

- [ ] Host read canary.
- [ ] Host write canary.
- [ ] Symlink escape.
- [ ] Hardlink evaluation.
- [ ] FD escape.
- [ ] Mount escape.
- [ ] Namespace escape.
- [ ] Process visibility.
- [ ] `ptrace` attempt.
- [ ] Host signal attempt.
- [ ] Existing Issue #95 regressions.
- [ ] Existing Issue #292 regressions.
- [ ] Both named prototype regressions from Section 1.

### E2E

- [ ] Real `distcc` client.
- [ ] Real `distccd` server.
- [ ] GCC.
- [ ] Clang where supported.
- [ ] Plain compile.
- [ ] Pump compile.
- [ ] Real network path.
- [ ] Expected output verified independently.

### Performance

- [ ] Plain compile without jail baseline.
- [ ] Plain compile with jail.
- [ ] Pump compile without jail baseline.
- [ ] Pump compile with jail.
- [ ] Parallel jobs.
- [ ] Large include tree.
- [ ] Many files.
- [ ] Measure rather than assuming the overhead is acceptable.

## 36. Verification evidence

For every security-critical test, record:

- [ ] Test name.
- [ ] Exact command.
- [ ] Expected result.
- [ ] Actual result.
- [ ] Exit code.
- [ ] Distribution and version.
- [ ] Kernel version.
- [ ] libc version where relevant.
- [ ] Compiler version.
- [ ] `distcc`/`distccd` configuration.
- [ ] Root/non-root identity.
- [ ] Container/native environment.
- [ ] Relevant logs.
- [ ] `mountinfo` evidence for namespace tests.
- [ ] Process tree evidence for cleanup tests.
- [ ] File descriptor evidence for FD isolation tests.

Never replace actual evidence with a statement that the code appears correct.

## 37. Release and merge gate

The following gate must be green before Issue #289 is considered complete:

- [ ] Architecture and scope are documented.
- [ ] Existing CI namespace capability is verified.
- [ ] No unnecessary CI security changes were introduced.
- [ ] Job root lifecycle is complete.
- [ ] `temp_o` handling is correct.
- [ ] `deps_fname` handling is correct.
- [ ] Original UID/GID regression test passes.
- [ ] Original working-directory regression test passes.
- [ ] User namespace is verified.
- [ ] Mount namespace is verified.
- [ ] Mount propagation is verified.
- [ ] `pivot_root()` is verified.
- [ ] Old-root cleanup is verified.
- [ ] Mount trust model is documented and tested.
- [ ] Symlink regression suite passes.
- [ ] Hardlink behavior is explicitly tested or documented as not applicable.
- [ ] File descriptor isolation passes.
- [ ] `/dev` policy passes.
- [ ] `/proc` policy passes.
- [ ] `/sys` policy passes.
- [ ] Shared-memory policy passes where applicable.
- [ ] `/etc` and host-secret isolation passes.
- [ ] Environment isolation is reviewed.
- [ ] `PATH` and dynamic library lookup are reviewed.
- [ ] GCC works.
- [ ] G++ works.
- [ ] Clang works if supported.
- [ ] Clang++ works if supported.
- [ ] Toolchain discovery is complete.
- [ ] Cross compilation is evaluated where supported.
- [ ] LTO is tested where supported.
- [ ] Multilib is tested where supported.
- [ ] ccache and sccache are evaluated where supported.
- [ ] Plain compilation passes.
- [ ] Pump compilation passes.
- [ ] Output file tests pass.
- [ ] Dependency file tests pass.
- [ ] Compiler argument security tests pass.
- [ ] Issue #95 regressions pass.
- [ ] Issue #292 regressions pass.
- [ ] Seccomp integration passes.
- [ ] Privilege-drop tests pass.
- [ ] Root and non-root paths pass.
- [ ] Failure-path tests pass.
- [ ] Cleanup tests pass.
- [ ] Parallelism tests pass.
- [ ] Race-condition tests pass.
- [ ] Security canary tests pass.
- [ ] Host mount namespace remains unchanged.
- [ ] No process, mount, descriptor, or job-root leaks remain.
- [ ] CI unit tests pass.
- [ ] CI integration tests pass.
- [ ] CI security tests pass.
- [ ] CI E2E tests pass.
- [ ] Performance impact is measured and documented.
- [ ] Compatibility matrix is recorded.
- [ ] Documentation is complete.
- [ ] Code review is complete.
- [ ] Security review is complete.
- [ ] Final verification is performed against the current `current_dev` base before claiming completion.

## 38. Scope boundary: Issue #398

Issue #398 is intentionally not incorporated into this checklist as an implementation dependency. It remains a separate concern.

The filesystem jail may be tested in Alpine or other container environments where useful, but Alpine packaging, BusyBox-specific behavior, image migration, and other Issue #398-specific work must not be silently folded into Issue #289.

If a test discovers a cross-cutting problem that genuinely belongs to #398, record the finding in the appropriate issue and keep the acceptance criteria of #289 separate.

## 39. Final verification record

When the implementation is ready, complete this section with the actual evidence rather than leaving it as an unqualified checklist claim.

```text
Issue: #289
Implementation branch/PR:
Base commit:
Verification date:
Verifier:

Host:
Distribution:
Kernel:
libc:
Compiler(s):
Container runtime:
Container image:

Server identity:
Client identity:
Seccomp:
Filesystem jail:
Plain compile:
Pump compile:

Known prototype regression 1:
Result:
Evidence:

Known prototype regression 2:
Result:
Evidence:

Existing Issue #95 regressions:
Result:
Evidence:

Existing Issue #292 regressions:
Result:
Evidence:

Security escape suite:
Result:
Evidence:

Cleanup verification:
Result:
Evidence:

Parallelism:
Result:
Evidence:

CI namespace capability:
Result:
Evidence:

Final release gate:
PASS / FAIL / BLOCKED
```
