# Native TLS transport — design notes

Tracking issue: [wiki-mod/distcc-ng#248](https://github.com/wiki-mod/distcc-ng/issues/248).
Status: design/scoping, not yet implemented. This document records the
design decisions made so far and the questions still open, so a future
implementation PR has a single source of truth to work from rather than
reconstructing context from issue comments.

## Motivation

distcc-ng currently offers two transports:

- **Plain TCP** with an IP allowlist (`--allow`) — no encryption, no real
  identity. Explicitly gated behind `--enable-tcp-insecure` since
  [distcc/distcc#155](https://github.com/distcc/distcc/issues/155)
  (CVE-2004-2687) made the risk of unauthenticated TCP mode concrete
  (arbitrary remote code execution via a crafted client, automated in
  public exploit tooling).
- **SSH tunneling** — encrypted and authenticated, but has a real,
  measured parallelism problem for distcc's actual workload shape. See
  [distcc/distcc discussion #517](https://github.com/distcc/distcc/discussions/517):
  a contributor measured that a single SSH connection to a worker could
  not push that worker's total CPU usage past 50%, even with many idle
  cores, because SSH's per-connection encryption runs on a single thread
  (`ps -wwfLC ssh` confirmed only one thread) and distcc's workload is many
  small, independent, highly parallel jobs funneled through that one
  channel. distcc's original author, **sourcefrog** (Martin Pool),
  responded to that measurement with appropriate caution (*"doesn't
  exactly prove this... but it's indicative"*), and separately stated
  what he considered the actual long-term answer:

  > I think the long term solution would be something like TLS with some
  > kind of mutual identity provider, natively in the program.

This document is this fork's attempt at that. See
`support-upstream/issue-248-tls-native-transport.md` for the full
upstream-discussion citation and quotes.

## Non-negotiable design constraint

**The transport must never be single-threaded/single-connection-serialized
for crypto.** This is the entire point of the feature — reproducing SSH's
bottleneck with a different cipher would fix nothing. Concretely, this
rules out any design that funnels every parallel compile job through one
serialized encrypted channel.

Two designs satisfy this, and they're not mutually exclusive:

1. **Multiple parallel TLS connections** to a given worker — naturally
   uses multiple CPU cores for crypto, and is the closest fit to distcc's
   existing "one TCP connection per job" model, just with each connection
   TLS-wrapped.
2. **A smaller number of longer-lived connections with TLS session
   resumption** (session tickets) — a reconnect doesn't need a full
   asymmetric handshake, only a cheap resumed-session negotiation. Useful
   if connection count itself becomes a resource concern at very high
   worker-core-counts.

The initial implementation should likely default to (1), since it requires
no new stream-multiplexing logic and mirrors distcc's existing connection
model most directly; (2) can layer on top later as an optimization once
real performance data exists (see "Validation" below).

## Library: mbedTLS

Evaluated against wolfSSL, GnuTLS, OpenSSL, BearSSL, s2n-tls, and Rustls
(comparison table and sourcing in the issue's own comments and the
support-upstream entry). Chosen because it's the only candidate with:

- an explicit **GPLv2 license option** (dual Apache-2.0/GPLv2) — matches
  this project's own license with zero compatibility question, unlike
  wolfSSL's GPLv3-only open-source option;
- a genuinely **small footprint**, written for embedded/resource-
  constrained targets, unlike OpenSSL/GnuTLS;
- **written in C** (C99, kept ANSI-C/C89-compatible for portability),
  fitting this codebase directly with no FFI/binding layer;
- broad **POSIX/Windows portability** matching
  `doc/compatibility-policy.md`'s FreeBSD/macOS/Cygwin support — unlike
  BearSSL (rarely packaged as a system library, would need vendoring) or
  s2n-tls (Linux/server-oriented);
- **genuine runtime hardware-capability detection already built in**:
  `mbedtls_aesni_has_support()` (`aesni.c`) does a real CPUID-based check
  and caches the result. This fork will *not* write its own hardware-
  capability-detection code — that would duplicate what the library
  already does correctly, for no benefit. Cipher-suite preference
  (e.g. favoring ChaCha20-Poly1305 when AES-NI isn't available, which
  Go's `crypto/tls` and BoringSSL both already do automatically) is a
  configuration/priority-list concern layered on top of the library's own
  detection, not a reason to reimplement CPUID probing.

Per `doc/compatibility-policy.md`, mbedTLS must be configure-time
auto-detected and optional, degrading gracefully (no hard new dependency)
when unavailable — the same pattern as the existing zstd integration
(`PKG_CHECK_MODULES([ZSTD], ...)` in `configure.ac`).

## Module architecture

TLS support lands as its own self-contained module, `src/tls.c`/
`src/tls.h`, exposing a thin internal API — sketch, not final:

```c
int dcc_tls_wrap_socket(int fd, struct dcc_tls_ctx *ctx, /* ... */);
ssize_t dcc_tls_read(struct dcc_tls_conn *conn, void *buf, size_t len);
ssize_t dcc_tls_write(struct dcc_tls_conn *conn, const void *buf, size_t len);
int dcc_tls_handshake(struct dcc_tls_conn *conn);
```

mbedTLS-specific types and error codes stay inside `tls.c`; callers in
`io.c`/`rpc.c`/`clinet.c`/`srvnet.c` only see this fork's own API. This
mirrors the existing precedent of `src/compress-zstd.c` (optional,
auto-detected, own thin API) and `src/sandbox-seccomp.c` (own module for
an optional OS-level feature). A `--without-tls` build must degrade the
same way `--without-zstd` already does today: never a hard dependency by
default.

## Authentication model

Leaning toward a **private CA** (self-hosted; no public CA needed) that
signs both client and worker certificates, rather than an SSH-style
pairwise trust model (`known_hosts`/`authorized_keys`-equivalent, where
each peer individually pins every other peer's key/fingerprint).

Rationale: distcc's actual deployment shape is a build farm — a set of
worker machines that changes over time (added, retired, rotated) — and
pairwise pinning scales badly there. Every new worker means updating every
client's trust list (or vice versa for a new client). A CA-based model
means issuing a new worker a CA-signed certificate is a one-time action
that doesn't require touching every existing client's configuration; every
peer just verifies "is this cert signed by our CA," not "do I have this
exact peer pinned."

A simpler pinned-certificate mode may still be worth supporting for small/
single-machine setups where standing up a CA is disproportionate overhead
— mirroring how the existing `--allow` IP-allowlist stays simple for
small deployments. Not yet decided whether this is in scope for an initial
implementation or a later addition.

**Explicitly rejected**: a reduced-strength/"lighter" encryption tier for
trusted or LAN-only networks. This was considered and dropped (maintainer
decision, 2026-07-19) — the "the network is trusted" assumption is exactly
what CVE-2004-2687 and discussion #517 both argue against (guest wifi,
browser JavaScript reaching local addresses, unknown devices on office
networks). If resource efficiency matters, the correct lever is cipher
suite *selection among equally strong options* (see above), not weakening
the crypto itself.

## Configuration

`src/config-parser.c`'s existing `key = value` parser (shared by
`distcc.conf`/`distccd.conf` since issue #207) is already suited to this
without any parser changes: it's callback-driven
(`dcc_config_load(path, log_prefix, apply_kv_fn, cfg)`), the caller owns
its own config struct, and unrecognized keys are the callback's own
responsibility rather than a hard parse error. Adding TLS support is
purely additive:

- **Client side** (`distcc.conf`, `struct dcc_client_config`): certificate
  and key paths for mutual auth, CA trust-store path(s) (a comma-separated
  list works directly with the parser's existing
  `dcc_config_parse_list()`), an enable/require policy flag (using
  `dcc_config_parse_bool()`).
- **Daemon side** (`distccd.conf`): listen certificate/key paths,
  client-certificate verification policy (require / optional / disabled),
  possibly a cipher-suite priority override.

The existing precedence chain (compiled-in default < config file <
environment variable) extends naturally — e.g. `DISTCC_TLS_CERT`
overriding `distcc.conf`'s `tls_cert = ...`, matching how every other
`DISTCC_*` environment variable already layers over this same config
system.

## Protocol

Will need a new protocol version for capability negotiation, following the
same shape as #228's proposed zstd-capability-negotiation protocol
version: an incompatible/older peer must fail closed or fall back per an
explicit, configured policy — never silently misbehave. Once the wire-
level design is final, it gets its own `doc/protocol-NNNN.txt` (whatever
the next free fork-extension number is by then, per issue #304's
numbering policy — 4000+, not a low number), following the existing
`doc/protocol-1.txt`–`protocol-3.txt`/`protocol-4000.txt` convention
(short, factual, wire-format-only — design rationale belongs in this
document, not there).

## Validation plan (once implemented)

Before considering this feature complete, per this project's own
verification-checklist discipline:

- Reproduce discussion #517's own methodology — measure worker CPU
  utilization under sustained parallel load — for plain TCP, SSH (with and
  without `ControlMaster` multiplexing), and the new TLS transport, on
  real hardware (not just a container). Don't assume the theoretical
  single-thread-crypto argument holds without measuring it on this fork's
  actual implementation.
- Real interop/compatibility testing matching
  `doc/verification-checklist.md` section 4 (external-host/network
  compatibility): both directions (this fork's client against a stock
  peer, and vice versa) wherever the new transport doesn't make that
  moot (e.g. if TLS is entirely this fork's own addition with no upstream
  equivalent, the "stock peer" side of that matrix may not apply — assess
  this once the protocol version behavior is final).
- A real `--without-tls` build must still work exactly as today, with the
  existing plain-TCP/SSH transports unaffected.

## Open questions

- Whether an encryption-only milestone (TLS without mutual identity)
  should land first as an intermediate step, or whether mutual identity is
  required from the first implementation — the "long term solution" quote
  this feature is built on specifically wants mutual identity, not just
  encryption, so shipping encryption-only first would be a deliberately
  incomplete first step, not the end state.
- Exact TLS config key names on each side.
- Whether/how this integrates with or replaces the existing `--allow`
  IP-allowlist and masquerade-whitelist mechanisms, and whether
  `src/auth_common.c`/`src/auth_distcc.c`/`src/auth_distccd.c` (existing
  auth infrastructure in this codebase) has anything reusable — needs a
  real read of that code before assuming either way.
- Certificate provisioning/rotation workflow for the private-CA model.
