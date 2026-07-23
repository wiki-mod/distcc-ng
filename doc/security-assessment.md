# Security Assessment

This is an index, not a restatement — each topic is covered in full in the
referenced document. Satisfies OpenSSF Best Practices Baseline criteria
`OSPS-SA-01.01` (design/actors) and `OSPS-SA-03.01` (security assessment),
raised during issue #267's review.

## Threat model and attack surface analysis

`doc/threat-model.md`: the real threat model and attack-surface enumeration
required by `OSPS-SA-03.02` — actors, trust boundaries, the wire-protocol
parsers' concrete fixed-vulnerability history (#95/#292/#293), the seccomp
sandbox's fail-open/fail-closed boundary, and what changes if `distccd` is
ever exposed beyond a trusted LAN. Not duplicated here.

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

## Vulnerability exploitability exchange (VEX)

`doc/distcc-ng.openvex.json`: an [OpenVEX](https://github.com/openvex/spec)
document declaring the real, current disposition of every dismissed CodeQL
alert on this repository (`not_affected` with a justification, or
`under_investigation` where triage under issue #143 isn't finished yet) —
see `SECURITY.md`'s "Continuous static and supply-chain analysis" section
for the policy this implements.

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
