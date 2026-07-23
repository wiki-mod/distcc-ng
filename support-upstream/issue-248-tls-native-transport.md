# Native TLS transport with mutual identity — this fork's design work traces back to upstream's own original author

**Fork issue:** [wiki-mod/distcc-ng#248](https://github.com/wiki-mod/distcc-ng/issues/248)
**Fixed by:** not yet implemented — design/scoping tracked in #248, this entry documents the design work so far
**Upstream location:** no code location — this documents an upstream *discussion*, not a bug in upstream's current source
**Checked against:** [distcc/distcc discussion #517](https://github.com/distcc/distcc/discussions/517) ("better network security and performance via UNIX socket and SSH"), checked 2026-07-19
**Searched upstream issues/PRs for:** `TLS`, `SSL`, `encrypt`, `mutual` — no open or closed PR implementing this found; [distcc/distcc#155](https://github.com/distcc/distcc/issues/155) (CVE-2004-2687, the origin of `--enable-tcp-insecure`) is the closest related issue, and predates/motivates discussion #517.

## Note on scope: this entry is different from the others in this folder

Every other entry here documents a bug this fork found and fixed that is
still live in upstream's current source. This one is not that — it's a
**feature this fork is designing**, not a defect. It's included here as an
explicit exception (per this folder's broader purpose: leave upstream a
citable, evidence-backed record) because the design direction traces
directly back to upstream's own original author's stated intent, not this
fork's own invention. If this fork ends up building it, that's a concrete
answer to a question upstream's own maintainer raised and never got
resourced to pursue himself.

## What upstream's original author actually said

In discussion #517, a contributor (kolAflash) reported a real, measured
performance problem with distcc's existing SSH-transport option: with a
single SSH connection to a worker, they could not push the worker's total
CPU usage past 50%, even with many idle cores — `ps -wwfLC ssh` confirmed
only one thread in the SSH process. SSH's per-connection encryption runs on
a single thread; distcc's workload (many small, independent, highly
parallel compile jobs funneled through that channel) turns that into a
serialization bottleneck.

**sourcefrog** (Martin Pool, distcc's original author) responded to that
measurement with appropriate scientific caution — *"The fact that the
client is at 50% CPU usage doesn't exactly prove this, maybe it's limited
by remote throughput, but it's indicative"* — not a confirmed diagnosis,
but not dismissed either. Separately, on the underlying security-vs-
performance tradeoff, he stated the direction he considered the actual
long-term answer:

> I think the long term solution would be something like TLS with some
> kind of mutual identity provider, natively in the program.

That sentence is this fork's design starting point.

## This fork's design work so far (see #248 for the live version)

- **Library**: [mbedTLS](https://www.trustedfirmware.org/projects/mbed-tls/) — the only real candidate with an explicit GPLv2 license
  option (matching this project's own license with no compatibility
  question), small footprint, genuine built-in runtime AES-NI detection,
  broad POSIX/Windows portability matching `doc/compatibility-policy.md`'s
  FreeBSD/macOS/Cygwin support. Compared against wolfSSL (GPLv3), GnuTLS
  (heavier dependency chain), OpenSSL (the heavyweight baseline being
  avoided), BearSSL (rarely available as a system package), and s2n-tls
  (Linux/server-oriented, weaker BSD/macOS story).
- **Architecture**: a standalone `src/tls.c`/`src/tls.h` module (own thin
  API, mbedTLS types never leaking into `io.c`/`rpc.c`/`clinet.c`/
  `srvnet.c`), following this codebase's own existing precedent for
  optional/pluggable pieces — `src/compress-zstd.c` (configure-time
  auto-detected, degrades gracefully with no hard dependency when
  unavailable) and `src/sandbox-seccomp.c`.
- **Non-negotiable design constraint**: the transport must never be
  single-threaded/single-connection-serialized for crypto — that would
  just reproduce the exact SSH bottleneck this feature exists to fix.
  Either multiple parallel TLS connections (naturally uses multiple cores,
  closest to distcc's existing one-TCP-connection-per-job model) or a
  smaller number of longer-lived connections using TLS session resumption
  for cheap reconnects (no full asymmetric handshake per job).
- **Explicitly rejected**: a "lighter"/reduced-strength encryption tier for
  trusted/LAN networks. Real crypto shouldn't be weakened based on an
  assumption of network trust — exactly the "isolated network" reasoning
  distcc's own `security.html` and discussion #517 already moved past
  (guest wifi, browser JS reaching local addresses, etc.). Cipher-suite
  selection for efficiency (e.g. preferring ChaCha20-Poly1305 on hardware
  without AES-NI, which mbedTLS/Go's `crypto/tls`/BoringSSL already do
  automatically at runtime) is the legitimate lever instead, not weaker
  crypto.
- **Authentication model**: leaning toward a private CA (self-hosted, no
  public CA needed) signing both client and worker certificates, rather
  than SSH's pairwise `known_hosts`/`authorized_keys`-style pinning —
  a CA scales much better for a build farm where workers are added/rotated
  over time (issue a new cert from the CA, no per-client trust-list update
  needed everywhere). A simpler pinned-certificate mode may still exist for
  small/single-machine setups, mirroring the existing `--allow` IP-list's
  simplicity.
- **Config**: `src/config-parser.c`'s existing `key = value` parser (shared
  by `distcc.conf`/`distccd.conf` since #207) is already generic enough for
  this — new TLS keys are purely additive (new struct fields + the
  parser's existing `dcc_config_parse_bool()`/`dcc_config_parse_list()`
  helpers), no parser changes needed.
- **Protocol**: will need a new protocol version for capability negotiation
  (same shape as the zstd-protover idea in #228) and its own
  `doc/protocol-NNNN.txt` once the wire-level design is final -- per issue
  #304's numbering policy, this must be a 4000+ number, not a low one,
  following this project's existing `doc/protocol-1.txt`–`protocol-3.txt`/
  `protocol-4000.txt` convention.

## Status

Design/scoping only as of this entry — see
[wiki-mod/distcc-ng#248](https://github.com/wiki-mod/distcc-ng/issues/248)
for the live discussion and any follow-up PRs.
