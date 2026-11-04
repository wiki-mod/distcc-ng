# Native TLS transport: design v2

Tracking issue: [wiki-mod/distcc-ng#248](https://github.com/wiki-mod/distcc-ng/issues/248).

Status: implemented for the direct `distcc`-to-`distccd` channel (Phases 0 to 7; Phase 8 is future work). Phase 0 audit in [Appendix A](#appendix-a-phase-0-transport-and-protocol-audit) (static source audit at `current_dev` `b5fb3d2`), library check in [Appendix B](#appendix-b-phase-2-tls-library-fit-check), operator guide in [Appendix C](#appendix-c-operating-native-tls), test and measurement results in [Appendix D](#appendix-d-phase-5-to-7-results), status against the §27 acceptance criteria in [Appendix E](#appendix-e-acceptance-status).

This is version 2 of the design document. It deliberately revisits the earlier design from first principles rather than treating previous implementation sketches as requirements. The previous document selected mbedTLS, proposed a dedicated TLS module, and stated that TLS would require a new distcc protocol version. Those were useful investigation results, but they were not sufficiently grounded in a complete audit of the existing transport and I/O boundaries.

The central question of v2 is therefore not "how do we add mbedTLS?" but:

> Can native TLS be introduced as a secure transport below the existing distcc application protocol without changing the compile wire protocol?

That question must be answered from the actual code and protocol behavior before implementation begins.

Answer: yes. The Phase 0 audit answered it from the code (Appendix A.8), and Phase 5 confirmed it by running every supported protocol version through TLS (Appendix D.1).

## 1. Motivation

distcc-ng currently has multiple ways of transporting compile jobs, including plain TCP and SSH-based secure transport. Native TLS is intended to provide strong peer authentication and encryption without reproducing a single serialized encrypted channel that limits distcc's parallel workload.

The relevant performance observation is that distcc commonly runs many independent compile jobs concurrently. A secure transport therefore must preserve that concurrency model. The goal is not merely to encrypt bytes, but to provide secure transport without making the worker's parallel compilation capacity depend on one serialized crypto stream.

The long-term target is mutual identity, not merely encryption. A successful TLS handshake therefore establishes a cryptographic transport, while peer authorization remains a separate application decision.

## 2. Ground-up architectural principle

The existing system must be treated as the source of truth for the first design pass.

Before implementation, audit at least:

- `src/clinet.c`
- `src/netutil.c`
- `src/io.c`
- `src/rpc.c`
- `src/clirpc.c`
- `src/srvnet.c`
- `src/srvrpc.c`
- `src/serve.c`
- `src/daemon.c`
- `src/hosts.c`
- `src/hosts.h`
- `src/auth_common.c`
- `src/auth_distcc.c`
- `src/auth_distccd.c`
- the existing configuration parser
- the existing SSH transport path

The audit must document where the following boundaries actually exist:

```text
network connection
        |
        v
transport I/O
        |
        v
DIST protocol header/version
        |
        v
RPC request/response framing
        |
        v
compile job semantics
```

This document intentionally does not assume that the current `int fd` based I/O layer is already a sufficient transport abstraction. TLS has different state and readiness semantics from a POSIX socket, so the correct abstraction boundary must be derived from the existing implementation.

The audit required by this section is recorded in [Appendix A](#appendix-a-phase-0-transport-and-protocol-audit).

### 2.1 Decision register

This register separates what is fixed from what is proposed and what is still open. Section references point into this document unless stated otherwise.

**Established requirements** (not reopened by this document):

- Mutual identity is the target, not encryption alone (§1, §17).
- No reduced-strength LAN-only crypto mode (§17 item 10).
- One TLS connection per compile job; no application-level multiplexing (§8).
- No implicit TLS-to-plaintext retry and no plaintext capability probe before TLS (§5, §17).
- A valid certificate is not application authorization; `--allow` remains a separate control (§11).
- No project-specific CPU or cipher capability detection (§9).
- GnuTLS `>= 3.6.5` is the TLS library (maintainer decision after the Phase 2 check, Appendix B). The earlier mbedTLS default was a tool-made selection, not a maintainer decision, and was dropped after the Mbed TLS maintenance announcement (§9).
- TLS support is an optional build feature; explicitly required but unavailable TLS fails visibly (§10).
- The classic listener on port 3632 stays classic and never receives TLS or managed-protocol detection traffic ([#237](https://github.com/wiki-mod/distcc-ng/issues/237) §2.3).
- A new feature does not by itself imply a new protocol version (`[AG-PROTO-001]`).

**Evidence-backed decisions** from the Phase 0 audit (proposed; final once this document is reviewed):

- TLS is a transport below the existing distcc application protocol. No `DCC_VER_*` is allocated for TLS (§3, §4, Appendix A.8 questions 9 and 10).
- The TLS handshake runs after the TCP connection and before any GSSAPI exchange and before the `DIST` header, on both client and server (Appendix A.4).
- TLS applies only to connections that are one bidirectional TCP socket. SSH-mode hosts and pipe-based inetd invocations are not TLS candidates (Appendix A.2, A.5).
- `sendfile()` must not be used on a TLS connection, and every raw `read()` on a network fd must go through the transport layer (Appendix A.3).
- `TCP_CORK` and `TCP_DEFER_ACCEPT` remain valid under TLS because they act on the underlying TCP socket (Appendix A.3).

**Phase decisions** (each was open until the named phase):

- Phase 1 (decided): Option 2 of Appendix A.9, a descriptor-keyed transport in `src/io.c` (`struct dcc_transport`). Plain TCP runs through it unchanged.
- Phase 2 (decided): library fit against the Phase 1 interface. Closed in Appendix B: GnuTLS selected; Phase 3 adds pending-data and wait-direction operations to the transport.
- Phase 3 (decided): the server ends a TLS handshake after `tls-handshake-timeout` seconds (default 10). Existing plain server reads still have no I/O timeout unless `--job-lifetime` is set (Appendix A.3).
- Phase 3/5 (decided): TLS and authentication failures need no classification of their own. A failed TLS host is backed off like any failed host (`DISTCC_BACKOFF_PERIOD`, 60 s by default) and the job moves on to other hosts or to a local compile, which is the intended behavior for a host whose TLS setup is broken. A finer classification remains with [#228](https://github.com/wiki-mod/distcc-ng/issues/228) and [#237](https://github.com/wiki-mod/distcc-ng/issues/237) §12.7.
- Phase 4 (decided): host option `,tls` with an explicit port (no default TLS port; 3632 refused on both sides), client credentials from `DISTCC_TLS_CA`/`DISTCC_TLS_CERT`/`DISTCC_TLS_KEY`, daemon options `--tls`, `--tls-ca`, `--tls-cert`, `--tls-key`. A `--tls` daemon is a TLS-only listener; plain and TLS service run as two instances. `--tls` with `--zeroconf` and `--tls-*` without `--tls` are refused. Documented in `distcc(1)` and `distccd(1)`.
- Phase 5 (CRL optional and all settings configurable: maintainer decisions 2026-11-04; role model following the maintainer's suggestion to build on #237 §8): role separation comes from separate CAs (the `tls-ca` a daemon trusts decides which role may connect) plus extended key usage checks (serverAuth/clientAuth). A CRL is optional (`tls-crl`; `tls-require-crl` makes it mandatory, default off). Every TLS setting is configurable through the existing config files, overridden by environment variables or command-line options. Done: config keys, CRL, EKU checks, key-file permission check. Also done: identity white- or blacklist (`--tls-whitelist`/`--tls-blacklist`, `tls-whitelist`/`tls-blacklist`) matching the client certificate CN, sharing the list code with the GSS-API `--whitelist`/`--blacklist` (`dcc_config_load_name_list()` in `src/config-parser.c`); `tls-port`.
- Phase 6 (decided): session resumption is not needed; the full handshake is not measurable against the job time (Appendix D.2). Session tickets are disabled (`GNUTLS_NO_TICKETS`), so there are no ticket keys to manage (§14).
- Phase 7 (decided): there is no reload. Credentials, CRL and lists are read when `distccd` starts and when a client starts a job; a `distccd` restart aborts running jobs (Appendix C.4). Ticket-key lifecycle: not applicable (Phase 6).

## 3. Transport versus compile protocol

The most important unresolved architecture decision is whether TLS belongs to the transport layer only or requires a change to the distcc application protocol.

Two models must be considered. Earlier issue comments used the labels "Model A" and "Model B" for these models in a different order than earlier versions of this document; this document therefore names them only by meaning.

### TLS as transport

```text
TCP socket
    |
    v
TLS handshake / TLS records
    |
    v
byte-stream transport
    |
    v
existing DIST <version>
    |
    v
existing RPC protocol
```

Under this model, TLS changes how the byte stream is protected but does not change the compile protocol carried inside it. A new `DCC_VER_*` is not required merely because TLS is enabled.

### TLS in the application protocol

```text
TCP socket
    |
    v
existing distcc protocol
    |
    v
TLS capability negotiation
    |
    v
TLS / secure application state
    |
    v
compile protocol
```

Under this model, a new protocol version may be justified.

The decision between these models is an output of the transport/protocol audit, not an assumption.

The previous statement that TLS "will need a new protocol version" is explicitly superseded by this document. A new protocol version must only be introduced if the final wire contract actually requires one.

**Phase 0 result:** TLS as transport. The `DIST` header is written only after the connection exists and after any GSSAPI exchange, the protocol version is derived only from compression, preprocessing location and split-DWARF selection, and the existing GSSAPI exchange already runs before `DIST` without any protocol version of its own. See Appendix A.8 questions 1, 3 and 9.

## 4. Protocol-version policy

Issue #304 establishes that upstream protocol versions and fork-specific extensions must remain clearly separated. That policy remains valid.

The fact that a new transport exists is not, by itself, evidence that a new compile protocol exists.

If TLS can remain entirely below the existing RPC byte stream, allocating a `DCC_VER_*` for TLS would mix two concepts:

```text
transport security
```

and

```text
compile wire protocol
```

That should be avoided.

If the audit proves that TLS capability negotiation or other TLS-specific semantics must be represented inside the application protocol, then a new fork protocol version must follow #304's numbering policy and receive its own factual wire-format document.

No protocol number should be reserved speculatively.

**Phase 0 result:** the audit found no application-level state, token, or framing that TLS would add or change (Appendix A.6, A.8 question 10). No fork protocol version is allocated for TLS. This decision is reopened only if Phase 1 or Phase 3 produces concrete contrary evidence.

## 5. Transport selection

TLS negotiation must not depend on an unsafe plaintext probe if TLS is intended to be mandatory for a selected connection.

The design should first establish an explicit transport-selection model. Candidate semantics include:

```text
plain
ssh
tls
```

or an equivalent explicit host specification/configuration mechanism.

The exact syntax is deliberately open until the existing host specification parser and transport selection code have been audited.

The security invariant is fixed:

```text
TLS explicitly selected
        |
        +--> TLS succeeds
        |
        +--> TLS fails
                 |
                 +--> connection fails
                 +--> no implicit plaintext retry
```

Automatic "try TLS, then silently try plaintext" behavior is not acceptable for a secure configuration.

If a future feature intentionally implements capability discovery, that discovery must be designed as a separate security-sensitive protocol decision and must not create a downgrade path.

**Decision (Phase 4):** the host option `,tls` on a TCP host with an explicit port other than 3632 (`distcc(1)`, Appendix C.2). There is no capability probe. A failed TLS host is backed off and the job goes to another host or to a local compile; it is never sent in plaintext (Appendix C.5, D.3).

## 6. Existing compile protocol remains the preferred invariant

If Model A is confirmed, the logical application stream inside TLS should be identical to the stream used over an otherwise equivalent plain connection.

TLS must not alter:

- `DIST`
- protocol version semantics
- token sizes
- token ordering
- compression framing
- file lengths
- request ordering
- result ordering
- Plain mode semantics
- Pump mode semantics
- `DDWO`
- `DOTD`
- `DOTO`
- `SERR`
- `SOUT`
- `STAT`
- request termination
- result termination

The ciphertext will naturally differ. The decrypted application stream should not.

This gives us a strong compatibility invariant and a useful basis for automated tests.

## 7. I/O and transport abstraction

The existing I/O implementation is fd-oriented. TLS cannot safely be treated as a simple replacement for `read()` and `write()` without checking the complete call graph.

TLS introduces state such as:

- handshake progress
- partial encrypted records
- `WANT_READ`
- `WANT_WRITE`
- shutdown state
- handshake timeout
- read timeout
- write timeout
- transport-specific error classification

A TLS read may require an underlying write, and a TLS write may require an underlying read. Therefore polling only according to the direction of the original application operation is not necessarily sufficient.

The first implementation milestone should determine the smallest stable internal abstraction that can represent both plain TCP and TLS while preserving existing behavior.

A conceptual interface might eventually resemble:

```text
transport_open()
transport_handshake()
transport_read()
transport_write()
transport_shutdown()
transport_close()
```

These names are illustrative only. The actual interface must follow the repository's existing conventions and ownership model.

The goal is to keep TLS-specific library types and state out of the RPC protocol implementation.

## 8. Concurrency model

The initial TLS design must preserve distcc's existing ability to execute many independent jobs concurrently.

Preferred initial model:

```text
job 1 -> TLS connection 1
job 2 -> TLS connection 2
job 3 -> TLS connection 3
job 4 -> TLS connection 4
...
```

This avoids introducing application-level multiplexing merely to carry multiple jobs through one encrypted stream.

A future design may investigate longer-lived connections and session resumption if connection establishment becomes a measurable bottleneck. That is an optimization question, not a prerequisite for the initial transport architecture.

The implementation must not recreate SSH's single-connection serialization problem through an accidental global TLS stream or central crypto worker.

## 9. TLS library evaluation

The previous design evaluated mbedTLS against wolfSSL, GnuTLS, OpenSSL, BearSSL, s2n-tls, and Rustls. That research remains useful and does not need to be discarded.

However, the final library decision must be checked against the requirements produced by the transport audit rather than treated as an architectural premise.

The evaluation criteria include:

- project license compatibility
- supported platforms
- supported compiler versions
- POSIX and Windows portability required by the project
- Linux/glibc support
- Alpine/musl support
- FreeBSD support
- macOS support
- Cygwin support where required by the compatibility policy
- configure/build-system integration
- optional dependency behavior
- static and dynamic linking implications
- TLS 1.2 and TLS 1.3 support as required
- mutual certificate authentication
- certificate-chain validation
- identity/SAN handling
- session resumption
- nonblocking I/O behavior
- timeout handling
- error reporting
- thread safety
- cross-compilation
- memory footprint
- vulnerability and maintenance history

**Decision: GnuTLS `>= 3.6.5`** (the first GnuTLS release with TLS 1.3). Reasons, from Appendix B:

- The Mbed TLS team announced on 2026-10-08 that its current maintainers stop work on Mbed TLS from April 2027 and that security fixes and releases for the TLS and X.509 libraries stop then unless new maintainers join ([announcement](https://lists.trustedfirmware.org/archives/list/mbed-tls-announce@lists.trustedfirmware.org/thread/YPIGCB7WN6GCHOGEGKOJXUYAP7OK527W/)). The earlier mbedTLS default ([#248 comment](https://github.com/wiki-mod/distcc-ng/issues/248#issuecomment-5252809516)) was a tool-made selection, not a maintainer decision.
- GnuTLS passed every Phase 2 case and reports the wait direction (`gnutls_record_get_direction()`), which the transport needs and mbedTLS lacks.
- License: LGPL-2.1-or-later, compatible with distcc's GPL-2.0-or-later. OpenSSL 3 (Apache-2.0) would make the combined work GPLv3-only.
- GnuTLS is packaged on every Linux distribution, on Alpine/musl, FreeBSD and macOS (Homebrew).

The implementation is tested against the newest release (3.8.13, 2026-04-29) and the Debian stable package.

## 10. Optional dependency policy

TLS support should follow the project's existing optional-dependency philosophy where practical.

Conceptually:

```text
TLS library available
    -> TLS support can be built

TLS library unavailable
    -> base build remains possible
```

A build without TLS support must never pretend that TLS is available.

If an administrator explicitly requires TLS and the installed binary lacks TLS support, configuration must fail explicitly.

It must never silently substitute plaintext.

The expected states are:

```text
TLS not built + TLS not requested
    -> normal operation

TLS built + TLS not requested
    -> operation according to selected transport

TLS built + TLS required
    -> TLS or explicit failure

TLS not built + TLS required
    -> explicit configuration/build capability error
```

## 11. Authentication, identity, and authorization

TLS authentication and distcc authorization are separate concepts.

The TLS layer establishes cryptographic peer authentication according to the configured trust model.

The application then decides whether that authenticated identity is authorized to submit or accept work.

The initial identity model should continue to investigate a private CA because a build farm is naturally a many-to-many environment. A CA avoids maintaining pairwise peer keys as workers are added, retired, or replaced.

The existing `--allow` network restriction must not automatically be declared obsolete. It answers a different question:

```text
Which network sources may connect?
```

mTLS answers:

```text
Which cryptographic peer is this?
```

Authorization answers:

```text
Is this authenticated peer allowed to perform this role?
```

Those controls may legitimately coexist.

The existing authentication code must be audited before deciding exactly where certificate identity enters the authorization path.

## 12. Certificate identity model

The design must explicitly define how peer identity is extracted and checked.

Candidates include:

- DNS SAN
- URI SAN
- subject identity
- certificate fingerprint/pinning
- private CA plus role-specific policy
- CA trust plus application-level authorization

The choice must follow the project's deployment model rather than copying an HTTPS assumption blindly.

At minimum the final design must answer:

- What identifies a client?
- What identifies a worker?
- What identifies a future scheduler?
- Which CA is trusted?
- Who is authorized to issue certificates?
- How is a compromised identity removed?
- How are identities rotated?

A certificate being cryptographically valid must not automatically mean that the peer is authorized for every distcc role.

**Decision (Phase 5)**, following the role model of [#237](https://github.com/wiki-mod/distcc-ng/issues/237) §8:

- **Client:** a certificate from the CA that the daemon's `tls-ca` names, with extended key usage clientAuth. Its common name (CN) is the identity for the optional white- or blacklist.
- **Worker:** a certificate from the CA that the client's `tls-ca` names, with extended key usage serverAuth and a subject alternative name (DNS or IP) for every name clients use in their host list.
- **Future scheduler:** outside #248 (§23); #237 §8 gives it its own intermediate CA.
- **Trusted CA:** each side trusts exactly the CA certificates in its `tls-ca` file, so role separation comes from which CA each side trusts.
- **Issuer:** the operator's private CA (Appendix C.1).
- **Removing a compromised identity:** a CRL (`tls-crl`) or the blacklist (Appendix C.3).
- **Rotation:** §13 and Appendix C.4.

Certificate pinning is not implemented.

## 13. Certificate rotation

Certificate rotation must be a normal operational workflow.

The design should support an overlap period where old and new credentials can coexist according to the configured trust policy.

At minimum document and test:

```text
old certificate
      |
      v
new certificate issued
      |
      v
overlap period
      |
      v
old certificate removed
```

Questions include:

- Can credentials be reloaded without dropping active jobs?
- What happens to active TLS connections?
- Can CA generations overlap?
- How is a compromised certificate immediately removed?
- What happens when a certificate expires while the daemon remains running?

**Answers from the implementation** (procedure in Appendix C.4, tests in Appendix D.3):

- **Reload without dropping active jobs:** not supported. `distccd` reads its credentials, CRL and lists at start. A restart terminates the daemon's whole process group, so jobs that are running are aborted; their clients back the host off and fall back to a local compile (or fail with `DISTCC_FALLBACK=0`). Rotate in a quiet period.
- **Clients:** every `distcc` run is a new process that reads `distcc.conf` and the `DISTCC_TLS_*` variables again, so client credentials rotate without any restart.
- **Overlapping CA generations:** yes. A `tls-ca` file can hold several CA certificates; certificates from any of them are accepted.
- **Removing a compromised certificate:** add it to the CRL or the blacklist and restart `distccd`.
- **Expiry while running:** validity is checked by the peer at every handshake. Once a server certificate has expired, clients reject new connections to it; jobs already running are not affected. distcc gives no advance warning.

## 14. Session resumption and ticket-key rotation

Session resumption is an optimization and must not become a functional dependency.

The intended behavior is:

```text
resume attempt
      |
      +--> accepted -> resumed session
      |
      +--> rejected -> normal full TLS handshake
```

A failed or expired session ticket must not cause the compile job to fail when a normal authenticated handshake can still succeed.

Session ticket keys are distinct from certificate keys and therefore require their own operational policy.

For a long-running `distccd`, the design must define:

- how session-ticket keys are generated
- their lifetime
- rotation frequency
- how many previous key generations remain accepted
- whether rotation can happen without daemon restart
- what happens to tickets after restart
- what happens if ticket keys are compromised
- whether the selected TLS library performs rotation internally or requires application management

Ticket-key rotation must not require a rebuild. It must also not silently become an availability problem merely because old tickets stop being resumable.

A ticket-key compromise must be treated separately from compromise of the server's certificate/private key because the security consequences and recovery procedures differ.

**Decision (Phase 6):** session resumption is not implemented and session tickets are disabled (`GNUTLS_NO_TICKETS` on both sides; verified in Appendix D.3: `distccd` issues no ticket). Every connection performs a full authenticated handshake, which Appendix D.2 shows is not a measurable cost per job. Without tickets there are no ticket keys, so the lifecycle questions above do not arise. If resumption is added later, this section applies in full.

## 15. Configuration model

Configuration must be designed around transport and role semantics before exact option names are finalized.

Client-side requirements are expected to include:

- transport selection
- CA trust configuration
- client certificate
- client private key
- peer identity policy
- optional session-resumption policy if exposed

Daemon-side requirements are expected to include:

- listener/transport selection
- server certificate
- server private key
- client CA trust
- client identity policy
- authorization policy
- optional TLS policy overrides

The existing configuration parser and precedence model should be reused rather than creating a second configuration mechanism.

Exact names and environment-variable mappings remain open until the parser and documentation conventions have been audited.

**Decision (Phases 4 and 5):** every TLS setting is a `tls-*` key read by the existing parser (`src/config-parser.c`) from `distcc.conf` (client) and `distccd.conf` (daemon). Client environment variables `DISTCC_TLS_CA`, `DISTCC_TLS_CERT`, `DISTCC_TLS_KEY` and `DISTCC_TLS_CRL` override the file; daemon command-line options `--tls` and `--tls-*` override the file. The keys are listed in `distcc(1)` and `distccd(1)`; Appendix C.2 shows a complete setup.

## 16. Port and listener strategy

Port strategy must be decided from migration and deployment requirements rather than assumed.

Possible models include:

- explicit TLS on the existing listener
- separate TLS listener
- TLS-only listener
- dual listeners

The final model must be evaluated against:

```text
old client -> old server
old client -> new server
new client -> old server
new TLS client -> new TLS server
TLS client -> plaintext endpoint
plaintext client -> TLS-only endpoint
```

A stock plaintext distccd must not receive an opaque TLS stream merely because a client guessed incorrectly, and a TLS client must receive a clear failure when the selected transport is unavailable.

Constraint from [#237](https://github.com/wiki-mod/distcc-ng/issues/237) §2.3: the classic endpoint on port 3632 stays classic, and native TLS discovery traffic must not be sent to it. Same-port protocol sniffing on 3632 is therefore excluded; the remaining candidates are a separate TLS listener or a TLS-only listener on a separately configured port.

**Decision (Phase 4):** a `distccd` started with `--tls` (or `tls-enabled = true`) is a TLS-only listener on a separately configured port (`--port` or `tls-port`); port 3632 is refused for TLS on both sides. A host that serves plain and TLS clients runs two `distccd` instances. The behavior for each pair above is in Appendix A.7; the mismatched pairs are tested in Appendix D.3.

## 17. Security invariants

The following are non-negotiable:

1. TLS authentication failures fail closed.
2. TLS is never silently downgraded to plaintext.
3. A valid certificate is not automatically application authorization.
4. Mutual authentication is required for the intended final secure mode.
5. Certificate and private-key handling must use safe file permissions.
6. TLS credentials must not be exposed through normal diagnostic logging.
7. Session resumption is an optimization, not a security bypass.
8. Ticket-key rotation must be operationally supported.
9. Plain TCP remains governed by the existing insecure-transport policy.
10. No reduced-strength LAN-only crypto mode is introduced merely for performance.

## 18. Nonblocking and timeout requirements

The implementation must be tested against the project's actual connection behavior rather than only a blocking localhost example.

At minimum test:

- delayed handshake
- partial reads
- partial writes
- `WANT_READ`
- `WANT_WRITE`
- read requiring an underlying write
- write requiring an underlying read
- handshake timeout
- read timeout
- write timeout
- peer close during handshake
- TCP reset during handshake
- clean TLS shutdown
- abrupt TLS shutdown
- certificate failure during handshake

The transport abstraction must preserve the existing timeout and error semantics as far as possible while exposing TLS-specific failures clearly.

## 19. Protocol and interoperability testing

Once the transport architecture is implemented, test the logical application stream independently of the encryption layer.

The matrix must include, where applicable:

- DCC protocol versions supported by the fork: `DCC_VER_1`, `DCC_VER_2`, `DCC_VER_3`, `DCC_VER_4000`, `DCC_VER_5000`, and `DCC_VER_6000`/`DCC_VER_6001` in builds with `HAVE_SPLIT_DWARF_PUMP`
- Plain mode
- Pump mode
- LZO
- Zstd
- split-DWARF functionality
- `DDWO`
- `DOTD`
- `DOTO`
- malformed requests
- clean protocol rejection
- client/server version mismatch
- TLS client/TLS server
- TLS client/plain server
- plain client/TLS-only server
- SSH coexistence

If TLS remains entirely below the existing protocol, stock distcc interoperability for the TLS path is naturally not expected because stock distcc does not implement the new transport. The existing non-TLS interoperability matrix must nevertheless remain green.

## 20. Security test matrix

### Positive tests

- trusted server certificate
- trusted client certificate
- correct peer identity
- authorized client identity
- authorized worker identity
- multiple concurrent TLS jobs
- reconnect after connection close
- certificate renewal
- session resumption where implemented
- fallback from rejected session ticket to full handshake

### Negative tests

- unknown CA
- expired certificate
- not-yet-valid certificate
- wrong server identity
- wrong client identity
- missing client certificate
- invalid certificate chain
- unauthorized but cryptographically valid identity
- unsupported TLS version
- unsupported cipher policy
- malformed handshake
- TCP reset during handshake
- TLS failure during an active compile
- stale session ticket
- rotated ticket key
- compromised/revoked identity according to the chosen revocation model
- TLS failure followed by verification that no plaintext retry occurred

## 21. Performance validation

Generic TLS benchmarks are insufficient. The benchmark must reproduce distcc's actual workload characteristics.

Measure at minimum:

- plain TCP
- SSH
- native TLS
- many small compile jobs
- medium compile jobs
- large compile jobs
- Plain mode
- Pump mode
- low concurrency
- high concurrency
- connection setup latency
- total build time
- jobs per second
- client CPU
- worker CPU
- network throughput
- memory consumption
- simultaneous connection count

The primary question is:

> Does native TLS preserve distcc's parallel throughput while providing the required authentication and confidentiality?

Session resumption should only be promoted into the initial design if measurements show that full handshakes materially affect real workloads.

## 22. Portability and build matrix

The final implementation must be evaluated against the repository's actual compatibility policy, including where applicable:

- Linux/glibc
- Alpine/musl
- FreeBSD
- macOS
- Cygwin
- supported Windows environments
- supported compiler versions
- cross-compilation environments

A successful Linux build is not sufficient evidence of TLS portability.

## 23. Managed scheduler relationship

Future managed scheduling work may need secure client-to-scheduler and scheduler-to-worker transports.

That does not make scheduler protocol design part of #248.

The desired relationship is:

```text
classic client
      |
      v
secure transport abstraction
      |
      v
distccd
```

and later:

```text
client
   |
   v
secure transport abstraction
   |
   v
scheduler
   |
   v
secure transport abstraction
   |
   v
worker
```

The reusable component is the transport. Scheduler wire semantics remain governed by the scheduler design work.

## 24. Implementation sequence

The recommended sequence is now:

### Phase 0: transport/protocol audit

Document the actual connection lifecycle, I/O behavior, protocol state machine, authentication path, host specification, transport selection, and SSH implementation.

No TLS code.

Recorded in Appendix A. Phase 1 starts only after that appendix has been reviewed.

### Phase 1: transport abstraction proof

Introduce the smallest abstraction necessary to demonstrate that existing plain TCP behavior can run through a generic transport interface without changing RPC semantics.

No cryptographic implementation is required for this proof.

Done: `struct dcc_transport` in `src/io.c` (§2.1).

### Phase 2: TLS library decision

Validate the library against the concrete requirements from Phases 0 and 1. Done: GnuTLS selected (§9, Appendix B).

### Phase 3: TLS transport

Implement the secure transport, including:

- handshake
- certificate validation
- mutual authentication
- nonblocking operation
- timeout handling
- shutdown
- error classification
- explicit transport selection
- no implicit plaintext downgrade

Done: `src/tls.c`.

### Phase 4: identity and authorization

Integrate certificate identity with the existing authorization model and define the private CA/identity workflow.

Done: §12, Appendix C.1 to C.3.

### Phase 5: protocol compatibility

Prove that the logical distcc application stream remains correct above TLS. Only if the audit or implementation proves an application-level protocol change is necessary should a new `DCC_VER_*` be introduced.

Done: Appendix D.1; no new `DCC_VER_*`.

### Phase 6: performance and lifecycle

Measure real workloads. Add session resumption only if justified. Define and test ticket-key rotation if session tickets are enabled.

Done: Appendix D.2; no session resumption, tickets disabled (§14).

### Phase 7: operational hardening

Complete credential rotation, reload behavior, diagnostics, package/build integration, portability, documentation, and failure recovery.

Done except portability beyond Linux and the CI and package builds: rotation and reload in Appendix C.4 and D.3, diagnostics in C.5, CI and release packaging configured for GnuTLS, `distcc(1)` and `distccd(1)`. Portability and build status in Appendix E.

### Phase 8: future managed transport reuse

Reuse the transport layer for scheduler/worker communication when the managed architecture is implemented.

## 25. Decisions explicitly deferred

The following stayed open until the relevant evidence existed. Each is now decided:

- exact transport-selection syntax: `,tls` host option (§5)
- same-port versus separate-port TLS: separate TLS-only port (§16)
- exact TLS configuration key names: `tls-*` keys (§15)
- exact certificate identity encoding: server SAN (DNS or IP), client CN for the lists (§12)
- pinned certificates as an initial feature versus later addition: not in the initial feature (§12)
- exact private-CA operational workflow: Appendix C.1
- whether session resumption is needed in the initial release: no (§14)
- ticket-key management API and rotation interval: not applicable, tickets are disabled (§14)
- whether TLS should interact directly with existing `--allow` or remain orthogonal: orthogonal; `--allow` is checked before the handshake (Appendix A.4, C.2)

Whether a new protocol version is necessary and which TLS library is used are no longer deferred; see §2.1.

Deferring these decisions is intentional. It prevents implementation details from becoming accidental architecture.

## 26. Explicitly rejected shortcuts

The following are not acceptable as substitutes for the proper design:

1. Automatically adding a new `DCC_VER_*` solely because TLS exists.
2. Automatically assuming no new `DCC_VER_*` is necessary without completing the protocol audit.
3. Sending plaintext capability probes to negotiate a required secure transport.
4. Silently retrying a TLS failure over plaintext.
5. Funnel all compile jobs through one serialized TLS stream.
6. Introduce application-level multiplexing merely to compensate for TLS.
7. Make the TLS library a hard dependency before the build/compatibility decision is complete.
8. Treat certificate validity as application authorization.
9. Replace `--allow` without analyzing the distinct security properties first.
10. Make session resumption mandatory for successful connections.
11. Ignore session-ticket key lifecycle when session tickets are enabled.
12. Mix scheduler protocol design into the direct distccd transport implementation.
13. Declare TLS support complete after only a localhost handshake test.

## 27. Acceptance criteria

The feature is ready for production consideration only when all of the following are demonstrated.

Appendix E records for each criterion whether it is met, not applicable, or not yet demonstrated.

### Architecture

- transport and compile protocol boundaries are documented
- the TLS insertion point is justified from the actual code
- the transport abstraction supports both plain TCP and TLS cleanly
- the decision about a new protocol version is evidence-backed
- TLS does not unnecessarily alter compile protocol semantics

### Security

- mutual authentication works
- peer identity is verified
- authorization is explicit
- invalid certificates fail closed
- unauthorized identities fail authorization
- no TLS-to-plaintext downgrade occurs
- certificate rotation works operationally
- ticket-key rotation works if session resumption is enabled
- credentials are protected with safe permissions

### Compatibility

- existing non-TLS functionality remains operational
- Plain mode remains correct
- Pump mode remains correct
- compression modes remain correct
- existing supported protocol versions remain correct
- SSH remains functional
- malformed and incompatible peers fail clearly

### Performance

- multiple TLS connections execute concurrently
- worker CPU utilization is not artificially serialized by the transport
- throughput is measured against plain TCP and SSH
- small-job latency is measured
- Pump workload is measured
- connection setup cost is measured
- session resumption is justified by data if included

### Operational behavior

- TLS can be configured explicitly
- missing TLS support produces an explicit error when TLS is required
- credentials can be rotated according to the documented procedure
- ticket keys can be rotated according to the documented procedure when applicable
- diagnostics distinguish TLS failures from protocol failures
- sensitive credential material is not logged

### Portability

- supported target platforms are tested
- optional dependency behavior is tested
- supported build configurations remain reproducible

## 28. Relationship to the previous design document

This v2 document intentionally supersedes the earlier architectural assumptions in `doc/tls-transport-design.md`.

In particular:

- GnuTLS replaces mbedTLS as the TLS library (§9)
- the TLS code lives in a dedicated `src/tls.c`, as SSH lives in `src/ssh.c`
- a new distcc protocol version is no longer assumed
- transport selection is treated as an independent design problem
- the existing compile protocol is presumed unchanged unless the audit proves otherwise
- session resumption is treated as an optimization
- session-ticket key rotation is explicitly part of the lifecycle design if tickets are enabled

The previous research should not be discarded. It should be reused as evidence during the Phase 0 and Phase 2 work.

The governing principle for implementation is now:

```text
understand the existing system
        |
        v
prove the correct abstraction boundary
        |
        v
decide whether the wire protocol actually changes
        |
        v
select the TLS implementation
        |
        v
implement secure transport
        |
        v
prove compatibility, security, performance, and operations
```

No implementation detail should be promoted to an architectural requirement merely because it appeared in the earlier design.

## Appendix A: Phase 0 transport and protocol audit

Scope: static source audit of `current_dev` at `b5fb3d2`. All `file:line` references refer to that commit. These are static findings: they establish structure and call paths, not runtime behavior. Behavior claims are verified in Phase 1 by execution.

### A.1 Client connection lifecycle

1. `dcc_compile_remote()` calls `dcc_remote_connect()` (`src/remote.c:301`).
2. For a TCP host, `dcc_remote_connect()` (`src/remote.c:73`) calls `dcc_connect_by_name()` and sets `from_net_fd = to_net_fd`. The result is one bidirectional socket.
3. For an SSH host, it calls `dcc_ssh_connect()`, which returns two descriptors to and from the `ssh` child. They are created with `socketpair(AF_UNIX)` or `pipe()` (`src/ssh.c:77-84`).
4. `dcc_connect_by_addr()` (`src/clinet.c:84`) creates the socket, makes it nonblocking (`src/clinet.c:105`), and completes a nonblocking `connect()` with `dcc_select_for_write()` and the 4-second `dcc_connect_timeout` (`src/clinet.c:63`, `src/clinet.c:124`).
5. If GSSAPI is configured for the host, `dcc_gssapi_perform_requested_security()` runs on the connected descriptors before any distcc token (`src/remote.c:304-320`).
6. `dcc_send_header()` (`src/remote.c:142`) corks the socket and writes `DIST <protover>` through `dcc_x_req_header()` (`src/clirpc.c:60`). In pump mode it then writes `CDIR`, followed by `ARGC`/`ARGV`.
7. The input follows:
   - pump mode: `dcc_x_many_files()` (`src/remote.c:330`);
   - otherwise: `dcc_x_file(..., "DOTI", ...)` (`src/remote.c:354`).
8. Results are read from `from_net_fd` by `dcc_retrieve_results()` (`src/remote.c:372`).
9. Both descriptors are closed with `dcc_close()` (`src/remote.c:396-401`).

### A.2 Server connection lifecycle

All three entry modes reach `dcc_service_job(in_fd, out_fd, ...)` (`src/serve.c:163`):

| Mode | Accept / origin | Call |
|---|---|---|
| preforked standalone (default) | `accept()` `src/prefork.c:175` | `dcc_service_job(acc_fd, acc_fd, ...)` `src/prefork.c:194` |
| no-fork standalone | `accept()` `src/dparent.c:259` | `dcc_service_job(acc_fd, acc_fd, ...)` `src/dparent.c:277` |
| inetd / sshd | stdin is the connection | `dcc_service_job(STDIN_FILENO, STDOUT_FILENO, ...)` `src/daemon.c:396` |

In standalone mode, `in_fd == out_fd` is one accepted socket. In inetd mode, stdin and stdout are two descriptors. They may be a socket passed by inetd or systemd, or a pipe when sshd starts the daemon. The code itself records the pipe case: `getpeername()` fails with `ENOTSOCK` (`src/daemon.c:388-391`).

Accepted server sockets are not made nonblocking. On distcc connection descriptors, `dcc_set_nonblocking()` is called only for the client socket (`src/clinet.c:105`) and the SSH descriptor pair (`src/ssh.c:88-89`).

Inside `dcc_service_job()` the steps run in this order:

1. address access control: `dcc_check_client()` (`src/serve.c:175`);
2. optional GSSAPI: `dcc_gssapi_check_client()` (`src/serve.c:183`);
3. `dcc_run_job()` (`src/serve.c:197`), which reads `DIST` with `dcc_r_request_header()` (`src/serve.c:803`).

While the compiler runs, `dcc_collect_child()` (`src/exec.c:518`) watches `in_fd` for a client disconnect, using `select()` (`src/exec.c:579`) and a raw one-byte `read()` (`src/exec.c:582`).

### A.3 Network I/O inventory

**Raw system calls on a distcc network descriptor:**

| Site | Call | Under TLS |
|---|---|---|
| `src/io.c:197` in `dcc_readx()` | `read()` | must go through the transport layer |
| `src/io.c:234` in `dcc_writex()` | `write()` | must go through the transport layer |
| `src/pump.c:116`, `src/pump.c:141` in `dcc_pump_readwrite()` | `read()`/`write()` | must go through the transport layer when either side is a TLS connection |
| `src/sendfile.c` `sys_sendfile()`, reached from `dcc_pump_sendfile()` at `src/bulk.c:235` (uncompressed `dcc_x_file()` when `HAVE_SENDFILE`, `configure.ac:513`) | `sendfile()` | must not be used; kernel-to-socket copies bypass user-space TLS |
| `src/rpc.c:167` in `dcc_explain_mismatch()` | `read()` | must go through the transport layer; a raw read would consume TLS record bytes |
| `src/exec.c:582` in `dcc_collect_child()` | 1-byte `read()` after `select()` | must go through the transport layer; readability can mean a TLS record (for example `close_notify`) rather than EOF, so a raw read would consume TLS data |

**Socket options:**

- `tcp_cork_sock()` (`src/io.c:261-281`; callers `src/remote.c:148`, `:360`, `src/serve.c:801`, `:1069`) acts on the underlying TCP socket. It remains valid under TLS because it only affects how the encrypted records are segmented.
- `dcc_defer_accept()` (`src/netutil.c:135-148`) sets `TCP_DEFER_ACCEPT` on the listening socket. It remains valid under TLS because a TLS client also sends the first bytes (its handshake).

**Readiness helpers:**

- `dcc_select_for_read()` (`src/io.c:93`) and `dcc_select_for_write()` (`src/io.c:139`) are called from:
  - `dcc_readx()`/`dcc_writex()`;
  - `dcc_pump_readwrite()` (`src/pump.c:119`, `:144`);
  - `dcc_pump_sendfile()` (`src/sendfile.c:209`);
  - the connect wait (`src/clinet.c:124`).
- Each waits only in the direction of the operation that returned `EAGAIN`. A TLS operation can need the opposite direction, so under TLS the wait direction must come from the transport.

**Callers of `dcc_readx()` – 14/14 classified:**

- network: `src/auth_common.c:230`, `src/auth_distcc.c:306`, `:351`, `src/auth_distccd.c:255`, `src/compress-lzox1.c:210`, `src/compress-zstd.c:186`, `src/rpc.c:145`, `:206`, `:249`, `:301`, `:344`;
- local:
  - `src/compress-lzox1.c:103`, `src/compress-zstd.c:80` (compressing a local input file);
  - `src/zeroconf.c:678` (host file).

**Callers of `dcc_writex()` – 17/17 classified:**

- network: `src/auth_common.c:193`, `src/auth_distcc.c:281`, `src/auth_distccd.c:268`, `:376`, `src/bulk.c:188`, `src/rpc.c:93`, `:123`, `:368`;
- local or a separate service:
  - `src/compress-lzox1.c:245`, `src/compress-zstd.c:207` (decompressed output to a local file or stdout);
  - `src/state.c:266` (state file);
  - `src/stats.c:117`, `:138` (stats pipe);
  - `src/stats.c:497` (separate plaintext statistics HTTP listener, outside #248);
  - `src/zeroconf.c:173` (host file);
  - `src/h_srvrpc.c:104`, `:112` (test helper).

**Callers of `dcc_pump_readwrite()` – 5/5 classified:**

- network:
  - `src/bulk.c:237` (uncompressed send without `sendfile`);
  - `src/pump.c:69` (uncompressed receive);
  - `src/sendfile.c:226` (fallback);
- local:
  - `src/bulk.c:522` (`dcc_copy_file_to_fd()`; all callers pass `STDERR_FILENO`, `src/compile.c:1203`, `:1228`, `:1254`);
  - `src/emaillog.c:104`.

**Callers of `dcc_pump_sendfile()` – 2/2 classified:**

- network: `src/bulk.c:235`;
- local: `src/bulk.c:520` (`dcc_copy_file_to_fd()`).

**Complete raw-call sweep.**

- **Search:** all of `src/*.c` except `src/h_*.c` and `src/fuzz*`, for `read`, `write`, `recv`, `recvfrom`, `recvmsg`, `send`, `sendto`, `sendmsg`, `readv`, `writev`, `close`, `shutdown`, `fdopen` and `dup2` called as functions.
- **Result:** 123 matches, comment lines included. Each one is classified:
  - **On a per-job distcc connection: 7.**
    - `src/io.c:197`, `:234` (`dcc_readx()`/`dcc_writex()`);
    - `src/io.c:285` (`close()` inside `dcc_close()`);
    - `src/pump.c:116`, `:141`;
    - `src/rpc.c:167`;
    - `src/exec.c:582`.
  - **On a listening socket during setup, before any connection: 2.** `src/srvnet.c:98`, `:108`.
  - **Separate services outside #248.**
    - statistics HTTP listener and stats pipe: `src/stats.c:104`, `:495`, `:502`, `:585`;
    - host-probing tool `lsdistcc`: `src/lsdistcc.c:398`, `:584`, `:622`, `:636`.
  - **Everything else is local:**
    - files, directories and lock files: `arg.c`, `compile.c`, `dotd.c`, `fix_debug_info.c`, `loadfile.c`, `lock.c`, `tempfile.c`, `timefile.c`, `util.c`, `zeroconf.c`, `bulk.c:526`, `serve.c:412`, `:420`, `srvrpc.c:277-496`;
    - pipes to child processes: `arg.c`, `compile.c`, `rslave.c`, `ssh.c:139-149`, `mon-notify.c`;
    - monitor state file: `mon.c:121`;
    - logs and the e-mail log: `trace.c`, `emaillog.c`;
    - pid file and standard-descriptor detach: `dparent.c:306`, `:310`, `:461`, `:469`;
    - comment text only: `io.c:33`, `:176`, `lsdistcc.c:718`, `zeroconf.c:174`, `stats.c:500`.

**Closing a connection.** Per-job connections are closed only through `dcc_close()`:

- client: `src/remote.c:398`, `:401`;
- standalone server: `src/prefork.c:197`, `src/dparent.c:278`;
- inetd: `src/daemon.c:398` closes only `STDIN_FILENO`. `STDOUT_FILENO` is not closed explicitly and is released at process exit.

No `shutdown()` is called on a per-job connection.

**Result:** All compile-protocol, compression, bulk and GSSAPI traffic already passes through `dcc_readx()`, `dcc_writex()`, `dcc_pump_readwrite()` and `dcc_pump_sendfile()`. Outside those helpers and `dcc_close()`, only `src/rpc.c:167` and `src/exec.c:582` touch a per-job network descriptor directly.

**Server-side I/O timeouts.**

- No `SO_RCVTIMEO` or `SO_SNDTIMEO` is set anywhere in `src/`.
- Accepted server sockets are blocking (A.2), and `dcc_readx()`/`dcc_writex()` apply `DISTCC_IO_TIMEOUT` only after `EAGAIN`, which a blocking socket does not return.
- The job-lifetime `alarm()` in `src/prefork.c:183-184` is armed only when `--job-lifetime` is set; the default is 0 (`src/dopt.c:141`, `src/exec.c:81`).
- The only other timer is the whole-daemon `--lifetime` `alarm()` (`src/daemon.c:305-307`), which also defaults to 0 (`src/dopt.c:134`).
- A search of `src/*.c` for `alarm(`, `setitimer`, `SIGALRM` and `SO_KEEPALIVE` finds no further per-connection timeout. The remaining hits are the `SIGALRM` handler (`src/dsignal.c:80-86`) and the separate `lsdistcc` tool (`src/lsdistcc.c:1048-1049`).

Static finding: a server-side read on a connection that stops sending has no I/O timeout unless `--job-lifetime` is configured. For TLS this means a server-side handshake timeout does not come from existing code. It is a new requirement for Phase 3 (§2.1).

### A.4 Access control and authentication order

Current server order:

```text
accept / inetd stdin -> dcc_check_client() (--allow) -> GSSAPI (if enabled) -> DIST ...
```

Current client order:

```text
connect -> GSSAPI (if requested for the host) -> DIST ...
```

`dcc_check_client()` (`src/srvnet.c:231`) allows a connection without a peer address (pipe or SSH case, `src/srvnet.c:247`). It also allows every connection when no `--allow` list is configured (`src/srvnet.c:253`).

GSSAPI is a precedent only for the wire contract: an authentication exchange already runs on the connection before the `DIST` header, without any protocol version announcing it. It is not a precedent for compatibility. A GSSAPI client sends `TLEN` first (`src/auth_common.c:189`), and a server without `--auth` reads it where it expects `DIST` and rejects it (`src/srvrpc.c:63`, `src/rpc.c:213`). GSSAPI has no negotiation either; both sides must be configured to match. Appendix A.11 compares the TLS approach with other implementations.

Proposed order with TLS:

```text
server: accept -> dcc_check_client() -> TLS handshake -> peer identity check
        -> authorization -> GSSAPI (if enabled) -> DIST ...
client: connect -> TLS handshake -> server identity check -> GSSAPI (if requested) -> DIST ...
```

Rejecting by address before the handshake avoids TLS work for connections that `--allow` refuses anyway. Certificate-based authorization can only happen after the handshake.

### A.5 Host specification and transport selection

- **Data model:** `struct dcc_hostdef` (`src/hosts.h`) keeps the transport `mode` (`DCC_MODE_TCP`, `DCC_MODE_SSH`, `DCC_MODE_LOCAL`) separate from `protover`, `compr` and `cpp_where`.
- **Parser:** SSH is selected when a token contains `@` (`src/hosts.c:671-680`). Comma-separated options are read in `dcc_parse_options()`, which supports `lzo`, `zstd`, `down`, `cpp` and `auth[=name]`.
- **Stale grammar comment:** `src/hosts.c:42-52` still lists `OPTION = lzo | cpp`. It is out of date relative to the parser and is recorded here as a separate documentation defect.
- **Fit for TLS:** A TLS selection fits the existing structure without new parser mechanics, either as a host option in `dcc_parse_options()` (valid for TCP hosts only) or as a new mode value. The exact syntax is a Phase 4 decision.
- **SSH hosts are excluded:** TLS does not apply to SSH-mode hosts. `ssh` already encrypts, and its descriptors lead to a local child process, not to a TCP connection with the peer.

### A.6 Protocol matrix

The protocol version is derived as follows:

- `dcc_get_protover_from_features()` (`src/hosts.c:519-552`) uses only compression and preprocessing location.
- Split-DWARF pump upgrades the version to `DCC_VER_6000`/`DCC_VER_6001` through `dcc_split_dwarf_upgrade_protover()` (`src/split_dwarf.c:85`).
- The server accepts exactly `1, 2, 3, 4000, 5000`, plus `6000, 6001` under `HAVE_SPLIT_DWARF_PUMP` (`src/srvrpc.c:57-89`).

| Version | Compression | Preprocessing | Request after `DIST` | Response |
|---|---|---|---|---|
| `DCC_VER_1` | none | client | `ARGC`/`ARGV`, `DOTI` | `DONE`, `STAT`, `SERR`, `SOUT`, `DOTO` |
| `DCC_VER_2` | LZO | client | as 1 | as 1 |
| `DCC_VER_3` | LZO | server (pump) | `CDIR`, `ARGC`/`ARGV`, `NFIL` + `NAME`/`FILE`/`LINK` | as 1, plus `DOTD` |
| `DCC_VER_4000` | Zstd | client | as 1 | as 1, with two-integer length tokens |
| `DCC_VER_5000` | Zstd | server (pump) | as 3 | as 3, with two-integer length tokens |
| `DCC_VER_6000` | LZO | server, split DWARF | as 3 | as 3, plus `DDWO` between `DOTO` and `DOTD` |
| `DCC_VER_6001` | Zstd | server, split DWARF | as 3 | as 5000, plus `DDWO` |

- **Where the tokens are read:** response tokens in `src/clirpc.c:112-270`; two-integer tokens with `dcc_r_token_2int()` (`src/clirpc.c:183`, `:205`, `:215`, `:244`, `:261`).
- **Effect of TLS:** TLS as transport changes none of these rows. Every row must run over the Phase 1 abstraction without TLS and over TLS in Phase 5.
- **Unknown versions** are rejected after `DIST` (`src/srvrpc.c:77-85`). That rejection is part of the protocol and does not depend on the transport.

### A.7 Compatibility matrix (expected behavior)

| Client | Server endpoint | Expected result |
|---|---|---|
| old or new client, plaintext host entry | classic 3632 (old or new `distccd`) | unchanged |
| new client, TLS host entry | TLS listener of a new `distccd` | TLS handshake, then the unchanged protocol |
| new client, TLS host entry | plaintext endpoint (old `distccd`, or 3632 by mistake) | the TLS ClientHello reaches the server. It carries no job data: no source, no arguments, and no client certificate, which is only sent after the server has answered. The stock server reads its first 12 bytes as the `DIST` token (`src/srvrpc.c:63`), logs `protocol derailment: expected token "DIST"` (`src/rpc.c:213`), reads up to 187 further bytes for its error context (`src/rpc.c:155-185`) and closes. The client sees the connection closed before any ServerHello (measured: `GNUTLS_E_PULL_ERROR`, Appendix B.2) and logs `TLS handshake with H:P failed: ...; the endpoint is probably not a distccd TLS listener` (Appendix C.5, D.3). The job fails for that host; no plaintext retry. Today's failure path then marks the host as disliked through `bad_host()` (`src/compile.c:79`, `:1246`), which applies the 60-second backoff (`src/backoff.c:53`), and falls back to a local compile unless `DISTCC_FALLBACK=0` (`src/compile.c:1248`). A local compile is not a plaintext downgrade: no job data is sent over the network unencrypted. |
| plaintext client | TLS-only listener | the TLS server sees bytes that are not a handshake, logs `TLS handshake failed: ...; the client is probably not using TLS` and closes; the client sees a protocol error or EOF (D.3) |
| SSH host entry | any | unchanged; TLS not applicable |
| client built without TLS, TLS host entry | any | explicit configuration error (`tls support not built`); no plaintext fallback |

### A.8 Answers to the twelve Phase 0 questions

Questions from [#248 comment 5239425798](https://github.com/wiki-mod/distcc-ng/issues/248#issuecomment-5239425798) §39.

1. **Where does a connection become a byte stream?**
   - Client: `dcc_connect_by_addr()` for TCP, `dcc_ssh_connect()` for SSH (A.1).
   - Server: `accept()` in `src/prefork.c:175` or `src/dparent.c:259`, or stdin/stdout in inetd mode (A.2).
2. **Which functions assume a raw POSIX descriptor?** The six raw-call sites and the readiness helpers in A.3. Everything else uses `dcc_readx()`, `dcc_writex()`, `dcc_pump_readwrite()` or `dcc_pump_sendfile()`.
3. **Can the RPC layer remain transport-agnostic?** Yes. `rpc.c`, `clirpc.c`, `srvrpc.c`, `bulk.c`, the compression modules and the GSSAPI code exchange bytes only through the helpers in A.3. The two exceptions, `src/rpc.c:167` and the `sendfile()` path, are covered by the abstraction.
4. **Where should handshake state live?** Per connection, owned by the transport layer and bound to the connection descriptor:
   - created right after `connect()` on the client;
   - created right after `dcc_check_client()` on the server (A.4);
   - released at `dcc_close()`.
5. **How should nonblocking readiness be represented?**
   - Client sockets are nonblocking (`src/clinet.c:105`); accepted server sockets are blocking (A.2).
   - The transport must report the direction it is waiting for, so `dcc_select_for_read()`/`dcc_select_for_write()` wait on the right one.
   - Server-side reads have no I/O timeout unless `--job-lifetime` is set (default 0). See the server-side timeout finding in A.3. A server-side TLS handshake timeout is therefore a new Phase 3 requirement.
6. **How do standalone and inetd share the transport layer?**
   - Both enter `dcc_service_job(in_fd, out_fd)`.
   - TLS needs one bidirectional stream. Standalone mode has it (`in_fd == out_fd`); inetd mode has it only when stdin is a socket.
   - The pipe case (sshd) is not a TLS candidate (A.2, A.5).
7. **How is transport selection represented?** Through `struct dcc_hostdef.mode` and host options. A TLS selection fits either form; the syntax is a Phase 4 decision (A.5).
8. **How does TLS identity feed authorization?** As a separate check after the handshake, before GSSAPI and `dcc_run_job()` (A.4).
   - Recommendation for Phase 5, not a decision: reuse the role model of [#237 Phase-0 supplement §8](https://github.com/wiki-mod/distcc-ng/issues/237#issuecomment-5238840686) for the client-to-`distccd` channel. Roles come from the issuing intermediate CA (client CA, worker CA), endpoint identity is carried in the SAN, and one PKI covers both classic and managed mode.
9. **Does TLS change the wire contract?** No.
   - `DIST` is written only after the connection is established and after GSSAPI (A.1).
   - The protocol version is derived only from application features (A.6).
   - The server reads `DIST` only after its access and authentication checks (A.2).
10. **If not, what evidence remains for a `DCC_VER_*`?** None was found. A transport below `DIST` adds or changes no token, framing, ordering or state.
11. **If yes, exactly what bytes and states require a new version?** Not applicable (answer 9).
12. **Which parts of the mbedTLS evaluation remain valid?** The license, footprint, C-integration and portability reasoning is unaffected. The audit adds the following interface requirements for the Phase 2 fit check. Concrete API names are confirmed against the mbedTLS 3.6 documentation in Phase 2.
    - wrapping an already-connected descriptor supplied by the caller, on both client and server;
    - nonblocking handshake and I/O with explicit want-read/want-write results;
    - a way to distinguish buffered plaintext from socket readability (needed for `src/exec.c:582`, A.3);
    - an orderly `close_notify` on close;
    - no dependency on `sendfile()`.

### A.9 Phase 1 interface options

**Option 1 – change signatures.** Network functions take a transport handle instead of `int fd`.

- Advantage: explicit types.
- Cost: every network caller in A.3 changes, and so do the mixed local/network signatures such as `dcc_r_bulk(ofd, ifd, ...)` with a local `ofd` and a network `ifd`.

**Option 2 – descriptor-keyed transport in `io.c`.** The existing `int fd` API stays.

- A connection descriptor can be bound to a transport object; the raw-call sites in A.3 dispatch through it.
- Unbound descriptors keep today's `read()`/`write()` behavior.
- `dcc_pump_sendfile()` falls back to `dcc_pump_readwrite()` for bound descriptors.
- `dcc_close()` releases the binding.
- **inetd:** `in_fd` is 0 and `out_fd` is 1, two descriptors for one socket (A.2). One transport object is bound to both. The first `dcc_close()` of either descriptor ends the session (for TLS: `close_notify`) and unbinds both. This covers `src/daemon.c:398`, which closes only `STDIN_FILENO`.

**Recommendation: Option 2.**

- It extends the existing owner (`io.c`) instead of re-plumbing every caller.
- It leaves every local-file path untouched.
- It matches the process model: a client process handles one job, and a server child handles jobs one after another (`src/prefork.c:165-200`).

Phase 1 implements Option 2 for plain TCP only and must show unchanged behavior through the interop and e2e matrix. The same transport object is the reusable component for the future managed scheduler connections of [#237](https://github.com/wiki-mod/distcc-ng/issues/237).

### A.10 Audit limits

- This is a static source audit. It makes no runtime claims.
- Platform-specific `sendfile()` variants in `src/sendfile.c` were classified by call site, not by platform behavior.
- `src/lsdistcc.c` (host probing) and `src/zeroconf.c` (service advertisement) were classified as outside the per-job transport. Whether TLS endpoints need advertising or probing is open for Phase 4.
- The statistics HTTP listener (`src/stats.c`) is a separate plaintext service and outside #248.

### A.11 Comparison with other implementations

How comparable systems handle a TLS client meeting a plaintext endpoint:

| System | How TLS is selected | TLS client meets plaintext endpoint | Source |
|---|---|---|---|
| upstream distcc | no native TLS; a search of its issues and pull requests for TLS found no implementation; SSH or external tunnels | not applicable | [distcc/distcc#155](https://github.com/distcc/distcc/issues/155) (open: plain TCP mode as a security risk) |
| Redis | separate `tls-port`; plain `port` and `tls-port` can run at the same time; `port 0` disables plain | client configured with `--tls` fails against a plain port | [Redis TLS documentation](https://redis.io/docs/latest/operate/oss_and_stack/management/security/encryption/) |
| PostgreSQL, default | in-band `SSLRequest`; the server answers `S` or `N`; after `N` the client may continue unencrypted | client decides; plaintext continuation is possible | [PostgreSQL protocol flow](https://www.postgresql.org/docs/current/protocol-flow.html) |
| PostgreSQL, direct TLS | client starts the TLS handshake immediately, with ALPN | the server disconnects; no plaintext continuation | same page |
| sccache-dist | HTTPS; build-server certificates are generated at start and distributed through the scheduler; the scheduler's own TLS is left to a reverse proxy | not described | [sccache `docs/Distributed.md`](https://docs.rs/crate/sccache/latest/source/docs/Distributed.md) |

Result:

- The design in this document matches the Redis model (selected by configuration, separate port) and the PostgreSQL direct-TLS model (handshake first, disconnect on mismatch).
- The PostgreSQL default model needs a server that can answer the request. A stock `distccd` cannot answer anything before `DIST`, so an in-band request would fail against it in the same way as a direct handshake. It would also add the plaintext continuation that §17 forbids.
- No design can stop a misconfigured client from sending a ClientHello to a stock `distccd`. What the design controls is that this costs no data and fails with a clear message (A.7).
## Appendix B: Phase 2 TLS library fit check

### B.1 mbedTLS 3.6.6

A probe program tested mbedTLS against the Phase 1 transport shape: a TCP connection that already exists, a nonblocking client socket (as `src/clinet.c:105`), a blocking accepted server socket (as `src/prefork.c:175`), and mutual certificates from one CA. Environment: Debian trixie, `libmbedtls-dev` 3.6.6 (meets the `>= 3.6.3` default), TLS 1.3 and `MBEDTLS_SSL_KEEP_PEER_CERTIFICATE` enabled in the distribution build. The probe is an evaluation program and not part of the repository.

| Case | Result |
|---|---|
| mTLS, 8 MiB client to server, 4 MiB back | TLS 1.3 handshake succeeds; server verify flags 0; the client certificate subject is available on the server. Data arrives complete. |
| Wrapping an existing descriptor | `mbedtls_net_context.fd` set to the connected descriptor plus `mbedtls_ssl_set_bio()`; no socket creation by mbedTLS. |
| Nonblocking client | Handshake and reads return `MBEDTLS_ERR_SSL_WANT_READ` (1 during the handshake, 44 during 4 MiB of reads); `WANT_WRITE` did not occur. |
| Buffered data | After a 100-byte read, `mbedtls_ssl_get_bytes_avail()` reported 16283 bytes and `mbedtls_ssl_check_pending()` 1, while the socket itself had nothing left to read. |
| Orderly close | `mbedtls_ssl_close_notify()` on the client; the server read returns `MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY`. |
| Client without certificate, server requires one | The server fails with `MBEDTLS_ERR_SSL_NO_CLIENT_CERTIFICATE` (-0x7480). The client handshake reports success; the client sees the failure only on its first write (`MBEDTLS_ERR_NET_CONN_RESET`). |
| TLS client against a stock `distccd` | The stock server reads `0x16` as the first `DIST` byte and closes; the client handshake fails with `MBEDTLS_ERR_NET_CONN_RESET` (-0x0050). |
| Plaintext client against a TLS server | The server handshake fails at once with `MBEDTLS_ERR_SSL_INVALID_RECORD` (-0x7200); the client sees a connection reset. |
| Silent peer, blocking server | With `mbedtls_ssl_conf_read_timeout(2000)` and `mbedtls_net_recv_timeout` as receive callback, the server handshake fails after 2.00 s with `MBEDTLS_ERR_SSL_TIMEOUT`. |

Result for mbedTLS: it fits the Phase 1 interface. `WANT_READ`/`WANT_WRITE` map to `EAGAIN`, which `dcc_readx()` and `dcc_writex()` already handle. Phase 3 needs three additions:

1. **Pending data.** `dcc_select_for_read()` and the disconnect probe in `src/exec.c:582` wait on the socket. With TLS, data can sit decrypted in mbedTLS while the socket is idle, so the transport needs a `pending` operation backed by `mbedtls_ssl_get_bytes_avail()`.
2. **Server handshake timeout.** The open Phase 3 requirement (§2.1) is met with mbedTLS's own read timeout on the blocking server socket; no new timer code is needed.
3. **Failure classification.** In TLS 1.3 a rejected client certificate surfaces on the client as an I/O error after a successful handshake, not as a handshake error. The #228 failure classification must not rely on the client seeing authentication failures during the handshake. An immediate connection reset during the handshake is the signal for "probably not a TLS listener" (A.7).

`WANT_WRITE` during a read (possible in TLS 1.3 after a key update) did not occur in the probe. Phase 3 either reports the wanted direction through the transport or runs TLS connections on a blocking socket with the read timeout above. The default TLS 1.3 negotiation selected `TLS1-3-CHACHA20-POLY1305-SHA256`; cipher suite policy stays a Phase 6 question (§9, §21).

### B.2 GnuTLS 3.8.13 and the decision

The same five cases ran against GnuTLS 3.8.13, the newest release (2026-04-29), on Alpine edge. The descriptor is wrapped with `gnutls_transport_set_int()`.

| Case | Result |
|---|---|
| mTLS, 8 MiB client to server, 4 MiB back | TLS 1.3 with AES-256-GCM; the client certificate subject is available on the server; data complete. |
| Nonblocking client | `GNUTLS_E_AGAIN` with `gnutls_record_get_direction()`: 209 waits for reading and 15 for writing during the reads. Waiting for writability inside a read does occur. |
| Buffered data | After a 100-byte read, `gnutls_record_check_pending()` reported 16284 bytes. |
| Orderly close | `gnutls_bye(GNUTLS_SHUT_WR)`; the server read returns 0. |
| Client without certificate | The server fails with `GNUTLS_E_CERTIFICATE_REQUIRED`; as with mbedTLS, the client sees the failure only on its first write (`GNUTLS_E_PREMATURE_TERMINATION`). |
| TLS client against a stock `distccd` | The client handshake fails at once with `GNUTLS_E_PULL_ERROR`. |
| Plaintext client against a TLS server | The server fails at once with `GNUTLS_E_UNEXPECTED_PACKET`. |
| Silent peer, blocking server | `gnutls_handshake_set_timeout(2000)` ends the handshake after 2.00 s with `GNUTLS_E_TIMEDOUT`. |

Decision (maintainer, 2026-11-04): GnuTLS. Besides passing every case, it reports the wait direction, which the measurement shows is needed, and the Mbed TLS maintenance announcement removes mbedTLS as a long-term base (§9). The transport therefore has two operations beyond read, write and close: `pending` (`gnutls_record_check_pending()`) and `wants_write` (`gnutls_record_get_direction()`); `dcc_select_for_read()` and `dcc_select_for_write()` use them.

The disconnect probe in `src/exec.c:582` selects on the raw socket and then reads one byte through the transport. On the blocking server socket such a read could wait for the rest of a partial TLS record. This is acceptable because a client sends nothing after its request until it reads the result; only the peer closing the connection makes the socket readable.

## Appendix C: Operating native TLS

This appendix is the operator guide for the implementation. `distcc(1)` and `distccd(1)` describe each option and config key.

### C.1 Certificates

The role model of [#237](https://github.com/wiki-mod/distcc-ng/issues/237) §8 applies: one offline root CA and one intermediate CA per role. A daemon's `tls-ca` names the CA whose certificates it accepts from clients, and a client's `tls-ca` names the CA that signs the servers. Role separation therefore comes from which CA each side trusts; the extended key usage check (serverAuth for servers, clientAuth for clients) stops a certificate of one role from acting as the other.

Requirements checked by distcc:

| Certificate | Extended key usage | Subject alternative name | Used for lists |
|---|---|---|---|
| server (`distccd`) | serverAuth | every DNS name and IP address clients use in their host list | — |
| client (`distcc`) | clientAuth | not checked | common name (CN) |

Example with OpenSSL, a single CA and one server and one client:

```sh
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -days 3650 -keyout ca.key -out ca.crt -subj "/CN=distcc-ng CA"

openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout server.key -out server.csr -subj "/CN=build1"
printf 'subjectAltName=DNS:build1.example.org\nextendedKeyUsage=serverAuth\n' > server.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 30 -out server.crt -extfile server.ext

openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout client.key -out client.csr -subj "/CN=ci-runner-1"
printf 'extendedKeyUsage=clientAuth\n' > client.ext
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 30 -out client.crt -extfile client.ext

chmod 600 server.key client.key
```

Private keys must not be accessible by group or others; distcc and distccd refuse to start otherwise.

### C.2 Configuration

Server, `/etc/distcc/distccd.conf`:

```text
tls-enabled = true
tls-port = 3633
tls-ca = /etc/distcc/tls/ca.crt
tls-cert = /etc/distcc/tls/server.crt
tls-key = /etc/distcc/tls/server.key
```

Client, `/etc/distcc/distcc.conf` or the `DISTCC_TLS_*` environment variables, plus `,tls` on each host:

```text
tls-ca = /etc/distcc/tls/ca.crt
tls-cert = /etc/distcc/tls/client.crt
tls-key = /etc/distcc/tls/client.key
```

```sh
export DISTCC_HOSTS='build1.example.org:3633,tls,lzo'
```

`--allow` stays in force; a valid certificate does not replace the address filter. A server that should keep serving plain clients runs a second `distccd` on port 3632 without TLS.

### C.3 Removing a compromised peer

- **CRL (standard way):** revoke the certificate at the CA, publish the CRL and point `tls-crl` (server) or `DISTCC_TLS_CRL`/`tls-crl` (client) at it. `tls-require-crl = true` makes a missing CRL a startup error; it is off by default.
- **Blacklist:** add the client's CN to the file named by `tls-blacklist`.
- **Whitelist:** remove the client's CN from the file named by `tls-whitelist`.

### C.4 Rotation and reload

Credentials, CRL and lists are read when `distccd` starts and when a client starts a job. There is no reload signal (`SIGHUP` still terminates `distccd`); restart `distccd` after replacing files.

A restart aborts the jobs `distccd` is running: on `SIGTERM`, `SIGINT` or `SIGHUP` the parent terminates its whole process group (`src/dsignal.c`). The affected clients back the host off and compile locally, or fail with `DISTCC_FALLBACK=0`. Restart in a quiet period. Clients need no restart: each `distcc` run reads its credentials again.

To rotate a CA (tested in Appendix D.3):

1. Put the old and the new CA certificate into the `tls-ca` file on both sides and restart `distccd`. Certificates from either CA are now accepted.
2. Issue new server and client certificates from the new CA and install them; restart `distccd` after replacing its certificate.
3. Remove the old CA certificate from the `tls-ca` files once no old certificate is in use, and restart `distccd`.

### C.5 Diagnostics

| Log message | Meaning |
|---|---|
| `TLS handshake with H:P failed: ...; the endpoint is probably not a distccd TLS listener` | the client reached a plain `distccd` or another service |
| `TLS handshake failed: ...; the client is probably not using TLS` | a plain client connected to the TLS listener |
| `TLS certificate of X rejected: ... The name in the certificate does not match the expected.` | the server certificate lacks the host name or IP from the host list |
| `... The certificate issuer is unknown.` | the certificate is not signed by the configured CA |
| `... does not match the intended purpose.` | wrong extended key usage (role) |
| `... The certificate chain is revoked.` | the certificate is listed in the CRL |
| `... The certificate chain uses expired certificate.` | the certificate has expired |
| `... The certificate chain uses not yet valid certificate.` | the certificate is not valid yet (or the clock is wrong) |
| `TLS handshake failed: No supported cipher suites have been found.` | the peer offered only TLS 1.2 or older |
| `TLS handshake failed: Certificate is required.` | the client has no certificate from a CA the server accepts |
| client: `TLS write failed: The TLS connection was non-properly terminated.` | the server rejected the client certificate after the handshake (TLS 1.3); the reason is in the `distccd` log |
| `TLS access denied - client "CN" ...` | white- or blacklist |
| `TLS handshake failed: The operation timed out` | the client did not finish the handshake within `tls-handshake-timeout` |

A failed TLS host is backed off like any failed host (`DISTCC_BACKOFF_PERIOD`, 60 s by default); the job goes to another host or falls back to a local compile. It is never sent in plaintext.

The logs name files, certificate subjects and GnuTLS error texts, never key material (checked in Appendix D.3 at debug level). GnuTLS itself writes TLS session secrets to the file named by the `SSLKEYLOGFILE` environment variable when that variable is set. This is a GnuTLS debugging aid that lets Wireshark decrypt captured traffic; distcc does not set it, and it must not be set in production.

## Appendix D: Phase 5 to 7 results

Measured in Debian trixie containers (GnuTLS 3.8.9) with the installed binaries, client and server on one machine over loopback. The test scripts are evaluation programs and not part of the repository.

### D.1 Protocol matrix through TLS

Each case compiled the same source with `-MD` once through a TLS host and once through a plain host; the protocol version is the `DIST` token in the client trace.

| Protocol | Host options | Result | TLS output vs. plain output |
|---|---|---|---|
| `DCC_VER_1` | `,tls` | OK | `.o` and `.d` identical |
| `DCC_VER_2` | `,tls,lzo` | OK | identical |
| `DCC_VER_4000` | `,tls,zstd` | OK | identical |
| `DCC_VER_3` (pump) | `,tls,lzo,cpp` | OK | identical |
| `DCC_VER_5000` (pump) | `,tls,zstd,cpp` | OK | identical |
| `DCC_VER_6000` (pump, split DWARF) | `,tls,lzo,cpp`, `-gsplit-dwarf` | OK | `.o`/`.dwo` differ, as they do between two plain runs: the object embeds the server's per-job `.dwo` path (`/tmp/distccd_<random>.dwo`) |
| `DCC_VER_6001` (pump, split DWARF) | `,tls,zstd,cpp`, `-gsplit-dwarf` | OK | same as 6000 |

The decrypted stream is the unchanged protocol: every version and both compression methods and preprocessing locations work through TLS, and wherever the output is deterministic it is byte-identical to plain TCP.

### D.2 Performance

200 source files, each including `<stdio.h>` and `<string.h>`, compiled through one host over loopback on a 12-CPU machine. Plain mode sends the preprocessed file; pump mode (`,cpp,lzo`) sends the sources and headers. Plain TCP and TLS ran interleaved in three rounds; the table gives the mean time per job and, in brackets, the range of the three rounds. SSH ran once, with sshd's `MaxStartups` raised for the parallel case.

| Workload | plain TCP | TLS | SSH |
|---|---|---|---|
| plain mode, 1 job at a time | 35.3 ms (33.7–36.4) | 36.0 ms (34.0–38.9) | 1173 ms |
| pump mode, 1 job at a time | 31.1 ms (30.4–31.5) | 34.6 ms (34.2–34.9) | 1148 ms |
| plain mode, 16 jobs in parallel | 13.7 ms (11.8–16.5) | 13.2 ms (10.4–14.8) | 76.5 ms |
| pump mode, 16 jobs in parallel | 12.5 ms (10.3–14.0) | 12.6 ms (7.8–15.1) | 76.5 ms |

A first, single run of the same workload, not interleaved, measured 61 ms per job for TLS against 39 ms for plain TCP in plain mode one job at a time. That difference did not reproduce in the three interleaved rounds or on Alpine, so the table uses the interleaved rounds; the SSH figures come from that first run.

Connection setup and small-job latency: a minimal job (an empty `main`, no headers), run 5 × 10 times interleaved, took 41 ms for plain TCP and 41 ms for TLS. On Alpine edge with GnuTLS 3.8.13, 2 × 20 interleaved jobs of the `<stdio.h>` source took 33 ms for both. The full TLS 1.3 handshake with mutual ECDSA P-256 authentication is therefore below the 1 ms resolution of these measurements on loopback. On a real network it adds one round trip per job to the TCP connection setup.

Results:

- **One job at a time:** TLS costs about 1 ms per job in plain mode and about 3.5 ms in pump mode, where every job sends all headers through TLS.
- **16 jobs in parallel:** no difference beyond the spread between rounds. The per-job TLS connections run concurrently; the transport does not serialize the worker.
- **SSH** is about 30 times slower one job at a time and about 6 times slower in parallel, because every job starts an `ssh` connection and a `distccd --inetd`.
- **Session resumption and connection reuse** are not needed (§14).

Before `TCP_NODELAY` was set on TLS connections, TLS cost about 35 ms more per job than plain TCP: every small TLS record after the first waited for the peer's delayed ACK.

Not measured: medium and large compile jobs, client and worker CPU time, memory, network throughput on a real network, and many simultaneous clients.

### D.3 Security and lifecycle tests

Debian trixie container, GnuTLS 3.8.9, one CA (`ca`), a second CA for rotation (`newca`) and an unrelated CA (`otherca`). Client-side results are the exit code and the client log; server-side reasons are from the `distccd` log. "Rejected" means the job was not compiled remotely; no case sent job data in plaintext.

| Case | Result | Reason logged |
|---|---|---|
| valid client and server, by IP and by DNS name | compiled | — |
| name not in the server certificate | rejected by the client (exit 103) | `The name in the certificate does not match the expected.` |
| client trusts another CA | rejected by the client (103) | `The certificate issuer is unknown.` |
| server certificate expired | rejected by the client (103) | `The certificate chain uses expired certificate.` |
| server certificate with clientAuth only | rejected by the client (103) | `does not match the intended purpose.` |
| client certificate from another CA | rejected by the server (client 107) | server: `Certificate is required.` (the client offers no certificate from an accepted CA) |
| client certificate with serverAuth only | rejected by the server (107) | server: `does not match the intended purpose.` |
| client certificate not yet valid | rejected by the server (107) | server: `The certificate chain uses not yet valid certificate.` |
| client certificate revoked in the CRL | rejected by the server (107) | server: `The certificate chain is revoked.` |
| client not on the whitelist / on the blacklist | rejected by the server (107) | server: `TLS access denied - client "client-b" ...` |
| client without TLS credentials | refused before connecting (101) | `TLS needs a CA file, a certificate file and a key file` |
| TLS client to a plain `distccd` | rejected by the client (103) | `... the endpoint is probably not a distccd TLS listener`; the plain server logs `protocol derailment: expected token "DIST"` |
| plain client to a TLS `distccd` | connection reset (107) | server: `... the client is probably not using TLS` |
| TLS 1.2 client (`openssl s_client -tls1_2`) | no handshake; the server sends nothing back | server: `No supported cipher suites have been found.` |
| `distcc` to a TLS 1.2-only server (`openssl s_server -tls1_2`) | rejected by the client (103) | `A TLS fatal alert has been received.` |
| client that never finishes the handshake | ended by the server after `tls-handshake-timeout` | server: `The operation timed out` |
| session tickets | `distccd` issued none; `openssl s_server` as a control issued 2 | — |
| `,tls` on port 3632, without a port, or on an SSH host | refused while parsing the host list (116) | `tls host needs an explicit port other than 3632`, `tls cannot be used with an ssh host` |
| `,tls` with a client built without GnuTLS | refused while parsing the host list | `tls support not built: ,tls` |

When the server rejects a client certificate, TLS 1.3 reports this to the client only after the client's handshake has completed. The client therefore logs `TLS write failed: The TLS connection was non-properly terminated.`, and the reason is in the server log.

**Failure during an active compile.** While the compiler was running on the server, the `distccd` children were killed. The client logged `unexpected eof` and backed the host off. With `DISTCC_BACKOFF_PERIOD=60` and `DISTCC_FALLBACK=0` it then failed (exit 116). With `DISTCC_BACKOFF_PERIOD=0` it retried the same host over a new TLS connection (two handshakes, one `COMPILE_OK` on the server).

**Rotation** (procedure in C.4):

| Step | Result |
|---|---|
| daemon `tls-ca` holds old and new CA; client with an old-CA certificate / a new-CA certificate | both compiled |
| server certificate renewed from the new CA; client trusts only the old CA | rejected: `The certificate issuer is unknown.` |
| same, client trusts old and new CA | compiled |
| old CA removed from the daemon; old-CA client / new-CA client | rejected by the server / compiled |
| `distccd` stopped while a job runs (default fallback) | the job was aborted (`unexpected eof`, `server provided no answer`); the client exited 0, which with fallback enabled means it compiled locally (the fallback log line was not captured) |

**Startup refusals:** `--tls-*` without `--tls`, `--tls` on port 3632, `--tls` with `--zeroconf`, a whitelist together with a blacklist, a key file readable by group or others, and `tls-require-crl` without a CRL each stop `distccd` with an error that names the problem.

**Credential material in logs:** a daemon at `--log-level debug` and a client with `DISTCC_VERBOSE=1` ran one successful job and one rejected job (262 log lines). None of the 9 base64 lines of the three private keys and no `PRIVATE KEY` marker appeared in the logs. With `SSLKEYLOGFILE` set, GnuTLS wrote the session secrets to that file (C.5).

**Test suite:** `make check` of a `--with-gnutls` build: 166 OK, 0 failed, 48 not run (tests that need other platforms or tools); `SSHMode_Case` ran and passed. A `--with-gnutls --with-auth` build fails to link `h_srvrpc` in `make check`; this is not caused by TLS, and the fix is on the separate branch `dev/fix_auth-make-check-link`.

## Appendix E: Acceptance status

Status of each §27 criterion. **Met** points to the evidence; **N/A** gives the reason; **Open** has not been demonstrated yet.

| Criterion | Status | Evidence |
|---|---|---|
| **Architecture** | | |
| transport and compile protocol boundaries are documented | Met | A.1 to A.6 |
| the TLS insertion point is justified from the actual code | Met | A.4, A.8 |
| the transport abstraction supports both plain TCP and TLS cleanly | Met | §2.1 Phase 1, A.9; `struct dcc_transport` in `src/io.c` |
| the decision about a new protocol version is evidence-backed | Met | §4, A.8, D.1 |
| TLS does not unnecessarily alter compile protocol semantics | Met | D.1 |
| **Security** | | |
| mutual authentication works | Met | D.3 |
| peer identity is verified | Met | D.3 (name, CA, purpose, validity) |
| authorization is explicit | Met | `--allow` plus the optional white- or blacklist (§12, D.3) |
| invalid certificates fail closed | Met | D.3 |
| unauthorized identities fail authorization | Met | D.3 (whitelist, blacklist, CRL) |
| no TLS-to-plaintext downgrade occurs | Met | §5, D.3: every failed TLS case either fails or compiles locally |
| certificate rotation works operationally | Met | C.4, D.3; a `distccd` restart aborts running jobs |
| ticket-key rotation works if session resumption is enabled | N/A | session tickets are disabled (§14, D.3) |
| credentials are protected with safe permissions | Met | key files readable by group or others are refused (D.3) |
| **Compatibility** | | |
| existing non-TLS functionality remains operational | Met | `make check` (D.3); build without GnuTLS |
| Plain mode remains correct | Met | D.1 |
| Pump mode remains correct | Met | D.1 |
| compression modes remain correct | Met | D.1 (LZO, Zstd) |
| existing supported protocol versions remain correct | Met | D.1 (1, 2, 3, 4000, 5000, 6000, 6001) |
| SSH remains functional | Met | `SSHMode_Case` (D.3), D.2 |
| malformed and incompatible peers fail clearly | Met | D.3 (plain to TLS, TLS to plain, TLS 1.2, silent client) |
| **Performance** | | |
| multiple TLS connections execute concurrently | Met | D.2 |
| worker CPU utilization is not artificially serialized by the transport | Met | D.2: 16 parallel jobs as fast as plain TCP; CPU time itself not measured |
| throughput is measured against plain TCP and SSH | Met | D.2 |
| small-job latency is measured | Met | D.2 |
| Pump workload is measured | Met | D.2 |
| connection setup cost is measured | Met | D.2: below 1 ms on loopback |
| session resumption is justified by data if included | N/A | not included (§14) |
| **Operational behavior** | | |
| TLS can be configured explicitly | Met | §15, C.2 |
| missing TLS support produces an explicit error when TLS is required | Met | D.3; `distccd --tls` without GnuTLS: `--tls: unknown option` |
| credentials can be rotated according to the documented procedure | Met | C.4, D.3 |
| ticket keys can be rotated according to the documented procedure when applicable | N/A | no session tickets |
| diagnostics distinguish TLS failures from protocol failures | Met | C.5, D.3 |
| sensitive credential material is not logged | Met | D.3; `SSLKEYLOGFILE` is a GnuTLS opt-in (C.5) |
| **Portability** | | |
| supported target platforms are tested | Open | Tested: Debian trixie (glibc, GnuTLS 3.8.9, gcc and clang) and Alpine edge (musl, GnuTLS 3.8.13). The macOS CI job installs GnuTLS but has not run on this branch yet. FreeBSD and Cygwin are not tested. |
| optional dependency behavior is tested | Met | builds with and without GnuTLS; D.3 |
| supported build configurations remain reproducible | Open | Built locally: with and without GnuTLS, gcc and clang, Debian trixie and Alpine edge, and the release Docker image (links `libgnutls.so.30`). CI has not run on this branch yet. The RPM and deb builds pass `--with-gnutls` but stop in `%prep` on rpm 4.20, a problem that exists without TLS too. The Alpine APKBUILDs are configured for GnuTLS but were not built. |
