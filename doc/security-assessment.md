# Security Assessment

This is an index, not a restatement — each topic is covered in full in the
referenced document. Satisfies OpenSSF Best Practices Baseline criteria
`OSPS-SA-01.01` (design/actors) and `OSPS-SA-03.01` (security assessment),
raised during issue #267's review.

## Trust model and actors

- **Client (`distcc`) / server (`distccd`) / include-server (`pump` mode)**
  and their trust boundaries: `SECURITY.md`'s "Known Security Tradeoffs and
  Design Decisions" section (LAN-oriented deployment model, no TLS yet,
  seccomp as defense-in-depth rather than a hard guarantee).
- **Wire protocol and external interfaces**: `doc/protocol-1.txt` through
  `doc/protocol-5000.txt` document every protocol version's actors, message
  flow, and format in full.
- **Planned transport hardening**: `doc/tls-transport-design.md`.
- **Sandboxing**: `doc/seccomp-sandbox.md`.

## Known risk history

Real, previously-fixed vulnerability classes in this codebase (path
traversal, TOCTOU, heap overflow) are documented in `CHANGELOG.md`'s dated
release sections and in their originating GitHub issues/PRs — not
duplicated here; search the changelog or issue tracker for specifics.

## Upstream context

This fork inherits decades of upstream `distcc/distcc` design and
production use; upstream's own documentation and issue history (read-only
reference, see `AGENTS.md` rule 50) are relevant prior art for anyone
assessing this project's security posture beyond this fork's own changes.
