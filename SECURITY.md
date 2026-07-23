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

**Remediation threshold**: this project's policy is zero-tolerance for open CodeQL security alerts on the default branch. This is enforced, not aspirational — the `distcc-ng-default` repository ruleset carries a `code_scanning` rule with `alerts_threshold: "all"`, which technically blocks merging any pull request while any CodeQL security alert is open, not merely a recommendation to fix them.

**Dismissed-alert transparency**: a CodeQL alert dismissed as a false positive or accepted design tradeoff is not simply closed and forgotten — see `doc/distcc-ng.openvex.json`, an [OpenVEX](https://github.com/openvex/spec) document recording every currently-dismissed alert's real disposition (`not_affected` with a machine-readable justification, or `under_investigation` for the handful not yet finally triaged under issue #143) plus the actual reasoning behind it. This is the honest, auditable trail this project's own dismissal comments already contained, made consumable by external VEX tooling rather than left only in GitHub's UI.

### 5. Dependency vulnerability (SCA) policy

This project distinguishes two dependency ecosystems, consistent with `doc/compatibility-policy.md`'s "Dependency management policy" section (added in #311):

- **GitHub Actions** (`.github/workflows/**`): the one ecosystem with both a manifest (each workflow's `uses:` lines) and real automated tooling. **OSV-Scanner** (`.github/workflows/osv-scanner.yml`) gates every pull request and push to `current_dev`/`master` against OSV.dev's advisory database, in addition to Dependabot's periodic update PRs (`.github/dependabot.yml`).
- **C library dependencies** (`libzstd`, `libpopt`, `libavahi-client`, `libseccomp`): detected at `./configure` time from whatever the build host provides — there is no package-manager-native manifest format for autoconf/C dependencies of this kind, so no automated SCA tool (OSV-Scanner included) has anything to scan here. This is a real, honestly-stated coverage gap, not a claimed capability; version floors for these are reviewed manually as part of normal `configure.ac` changes.

**Threshold**: a known **critical** or **high**-severity vulnerability in a scanned (GitHub Actions) dependency blocks a release — it must be remediated (an update, a pin change, or a documented, maintainer-approved risk acceptance) before a tagged release is cut. **Medium**/**low**-severity findings are tracked (an issue is opened) but do not block a release by themselves. This mirrors the zero-tolerance CodeQL threshold above in spirit — a real gate, not a recommendation — scoped to what OSV-Scanner can actually see.

## Secrets and Credentials Policy

distcc-ng does not commit or otherwise store long-lived credentials in the repository. In practice:

- **GitHub Actions secrets are the only secret material this project uses** (e.g. registry/publish tokens consumed by `.github/workflows/*.yml`). No API keys, passwords, or private keys are checked into source, workflows, or docs (see `AGENTS.md` rules 46-49).
- **Least-privilege workflow permissions**: workflow files default to `contents: read` at the top level, with each job declaring only the specific additional write scope it actually needs (e.g. `attestations: write` only on the job that mints a build-provenance attestation, `packages: write` only on the job that pushes to GHCR) — see `.github/workflows/package-release.yml` for the current example, tightened repo-wide in #308.
- **Secret scanning is enabled as an enforcement backstop**, not just a suggestion: both `secret_scanning` and `secret_scanning_push_protection` are enabled on this repository (verified live via `gh api repos/wiki-mod/distcc-ng --jq '.security_and_analysis'`), so a credential accidentally staged for commit is blocked at push time, in addition to being flagged if one is ever found in history.

## Verifying Release Artifacts

Every tagged release built by `.github/workflows/package-release.yml` is accompanied by a real [Sigstore](https://www.sigstore.dev/) build-provenance attestation, generated via [`actions/attest-build-provenance`](https://github.com/actions/attest-build-provenance) for each release asset. This lets a downstream user verify both that an artifact was not tampered with after being built (integrity) and that it was actually built by this repository's own GitHub Actions workflow rather than by some other party claiming to be this project (authenticity/author identity).

To verify a downloaded release asset (requires the [GitHub CLI](https://cli.github.com/), `gh`, version with the `attestation` subcommand):

```bash
gh attestation verify <path-to-downloaded-artifact> --repo wiki-mod/distcc-ng
```

(`--owner wiki-mod` also works if you want to trust any repository under the `wiki-mod` organization rather than this specific one.) A successful verification cryptographically confirms the artifact's checksum matches an attestation signed by this repository's own `package-release.yml` workflow run — i.e. it was built here, by this project's CI, and not modified since. See `gh attestation verify --help` for additional flags (e.g. pinning a specific signer workflow path).
