# Security Policy

## Security Contact

If you discover a security vulnerability in distcc-ng, please report it privately to the maintainer:

- **GitHub**: Please open a private security advisory via [GitHub Security Advisories](https://github.com/wiki-mod/distcc-ng/security/advisories)

Do **not** open a public GitHub issue for security vulnerabilities. Private disclosure helps address issues before they are publicly known.

## Supported Versions

| Version | Status | Support Until |
|---------|--------|----------------|
| `3.6.x-NG` (current `master`) | Current | Ongoing |
| `current_dev` (unreleased) | Active development | N/A |
| Earlier `-NG` releases | Not maintained | None |

distcc-ng continues distcc's own version numbering with a `-NG` suffix marking this fork's own releases (see `doc/release-versioning.md`). We aim to provide security fixes for the current `master` release line; older releases are not actively maintained.

## Reporting a Vulnerability

1. **Contact**: Use GitHub's private security advisory feature (link above).
2. **Information to include**:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if you have one)
3. **Response**: We will acknowledge receipt within 14 days and work to address the issue.
4. **Disclosure**: Once a fix is released, the vulnerability will be disclosed responsibly, with credit to the reporter unless they request otherwise.

For non-security bugs, see `doc/reporting-bugs.txt` and open a normal public issue instead.

## Known Security Tradeoffs and Design Decisions

This section documents intentional security design decisions and known tradeoffs, so reports about these specific behaviors can be triaged correctly.

### 1. distccd trusts its configured network

**Design**: `distccd` is a compile-farm daemon intended for a trusted LAN or otherwise access-controlled network (see `--allow`/`hosts.allow`-style access control in `doc/example/`). It is not designed to be exposed directly to the untrusted internet.

**Mitigation**:
- Use `--allow`/`--listen` to restrict which clients may connect
- Prefer running behind a firewall or VPN rather than exposing `distccd`'s port publicly
- The daemon drops privileges to an unprivileged user at startup (`dcc_discard_root()`); running it as `root` without `--user` is discouraged

### 2. seccomp sandboxing is opt-in and configurable, not a hard guarantee

**Design**: `distccd` can sandbox compiler execution via seccomp (see `doc/seccomp-sandbox.md`), with a configurable fail-open/fail-closed policy for unrecognized syscalls. This is defense-in-depth against a compromised/malicious compiler invocation, not a substitute for network-level access control.

**Mitigation**: review `doc/seccomp-sandbox.md` and `/etc/distcc/seccomp.conf` before relying on the sandbox as a primary control.

### 3. TLS transport is not yet implemented

**Design**: distcc-ng's wire protocol is not encrypted by default (see `doc/tls-transport-design.md` for the in-progress design). Traffic between `distcc` and `distccd` should be treated as plaintext on the network.

**Mitigation**: run distcc-ng only on networks you trust (LAN, VPN, or otherwise isolated), same as upstream distcc's own long-standing deployment model.

### 4. Continuous static and supply-chain analysis

This project runs CodeQL and OSSF Scorecard continuously against the codebase; open findings are tracked as GitHub issues rather than dismissed silently.
