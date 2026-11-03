# Native TLS transport: design v2

Tracking issue: [wiki-mod/distcc-ng#248](https://github.com/wiki-mod/distcc-ng/issues/248).

Status: Phase 0 transport and protocol audit recorded in [Appendix A](#appendix-a-phase-0-transport-and-protocol-audit) (static source audit at `current_dev` `b5fb3d2`); not yet implemented.

This is version 2 of the design document. It deliberately revisits the earlier design from first principles rather than treating previous implementation sketches as requirements. The previous document selected mbedTLS, proposed a dedicated TLS module, and stated that TLS would require a new distcc protocol version. Those were useful investigation results, but they were not sufficiently grounded in a complete audit of the existing transport and I/O boundaries.

The central question of v2 is therefore not "how do we add mbedTLS?" but:

> Can native TLS be introduced as a secure transport below the existing distcc application protocol without changing the compile wire protocol?

That question must be answered from the actual code and protocol behavior before implementation begins.

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
- mbedTLS `>= 3.6.3` is the project's standing TLS library default ([#248 comment](https://github.com/wiki-mod/distcc-ng/issues/248#issuecomment-5252809516), [#237 Phase-0 supplement §8](https://github.com/wiki-mod/distcc-ng/issues/237#issuecomment-5238840686)); its technical fit is validated in Phase 2 (§9).
- TLS support is an optional build feature; explicitly required but unavailable TLS fails visibly (§10).
- The classic listener on port 3632 stays classic and never receives TLS or managed-protocol detection traffic ([#237](https://github.com/wiki-mod/distcc-ng/issues/237) §2.3).
- A new feature does not by itself imply a new protocol version (`[AG-PROTO-001]`).

**Evidence-backed decisions** from the Phase 0 audit (proposed; final once this document is reviewed):

- TLS is a transport below the existing distcc application protocol. No `DCC_VER_*` is allocated for TLS (§3, §4, Appendix A.8 questions 9 and 10).
- The TLS handshake runs after the TCP connection and before any GSSAPI exchange and before the `DIST` header, on both client and server (Appendix A.4).
- TLS applies only to connections that are one bidirectional TCP socket. SSH-mode hosts and pipe-based inetd invocations are not TLS candidates (Appendix A.2, A.5).
- `sendfile()` must not be used on a TLS connection, and every raw `read()` on a network fd must go through the transport layer (Appendix A.3).
- `TCP_CORK` and `TCP_DEFER_ACCEPT` remain valid under TLS because they act on the underlying TCP socket (Appendix A.3).

**Open questions** (decided in the named phase):

- Phase 1: transport interface shape (Appendix A.9 lists two options with a recommendation).
- Phase 2: mbedTLS fit against the Phase 1 interface, including the API calls named in Appendix A.8 question 12.
- Phase 4: exact transport-selection syntax and TLS listener port.
- Phase 5: certificate identity model; Appendix A.8 question 8 recommends reusing the #237 role model.
- Phase 6: whether session resumption is needed.
- Phase 7: credential reload and ticket-key lifecycle.
- Phase 3: a server-side TLS handshake timeout. Existing server reads have no I/O timeout unless `--job-lifetime` is set (Appendix A.3).
- Phase 3/5: how TLS and authentication failures are classified against the host backoff. Today every failure backs off the whole `host:port` for 60 s ([#228](https://github.com/wiki-mod/distcc-ng/issues/228); [#237](https://github.com/wiki-mod/distcc-ng/issues/237) §12.7 classifies TLS/auth failures as security failures).

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

mbedTLS `>= 3.6.3` is the project's standing TLS library default ([#248 comment](https://github.com/wiki-mod/distcc-ng/issues/248#issuecomment-5252809516), [amendment](https://github.com/wiki-mod/distcc-ng/issues/248#issuecomment-5252950732)). The general library comparison is closed. What remains open is the technical fit check in Phase 2 against the transport interface proven in Phase 1; only a concrete technical blocker found there reopens the choice. Appendix A.8 question 12 lists the interface requirements that check must cover.

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

### Phase 2: TLS library decision

Validate the standing default, mbedTLS `>= 3.6.3`, against the concrete requirements from Phases 0 and 1. The general library comparison is not repeated; only a concrete technical blocker reopens the choice (§9).

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

### Phase 4: identity and authorization

Integrate certificate identity with the existing authorization model and define the private CA/identity workflow.

### Phase 5: protocol compatibility

Prove that the logical distcc application stream remains correct above TLS. Only if the audit or implementation proves an application-level protocol change is necessary should a new `DCC_VER_*` be introduced.

### Phase 6: performance and lifecycle

Measure real workloads. Add session resumption only if justified. Define and test ticket-key rotation if session tickets are enabled.

### Phase 7: operational hardening

Complete credential rotation, reload behavior, diagnostics, package/build integration, portability, documentation, and failure recovery.

### Phase 8: future managed transport reuse

Reuse the transport layer for scheduler/worker communication when the managed architecture is implemented.

## 25. Decisions explicitly deferred

The following must remain open until the relevant evidence exists:

- exact transport-selection syntax
- same-port versus separate-port TLS
- exact TLS configuration key names
- exact certificate identity encoding
- pinned certificates as an initial feature versus later addition
- exact private-CA operational workflow
- whether session resumption is needed in the initial release
- ticket-key management API and rotation interval
- whether TLS should interact directly with existing `--allow` or remain orthogonal

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
7. Make mbedTLS a hard dependency before the build/compatibility decision is complete.
8. Treat certificate validity as application authorization.
9. Replace `--allow` without analyzing the distinct security properties first.
10. Make session resumption mandatory for successful connections.
11. Ignore session-ticket key lifecycle when session tickets are enabled.
12. Mix scheduler protocol design into the direct distccd transport implementation.
13. Declare TLS support complete after only a localhost handshake test.

## 27. Acceptance criteria

The feature is ready for production consideration only when all of the following are demonstrated.

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

- mbedTLS `>= 3.6.3` is the standing project default; its technical fit is validated in Phase 2 (§9)
- a dedicated `src/tls.c` module remains a possible implementation detail, not a fixed architecture
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

GSSAPI is an existing precedent: an authentication exchange already runs on the connection before the `DIST` header, without any protocol version announcing it.

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
| new client, TLS host entry | plaintext endpoint (old `distccd`, or 3632 by mistake) | server reads handshake bytes where it expects `DIST` and rejects the token; client sees a handshake failure; the job fails for that host; no plaintext retry. Today's failure path then marks the host as disliked through `bad_host()` (`src/compile.c:79`, `:1246`), which applies the 60-second backoff (`src/backoff.c:53`), and falls back to a local compile unless `DISTCC_FALLBACK=0` (`src/compile.c:1248`). A local compile is not a plaintext downgrade: no job data is sent over the network unencrypted. |
| plaintext client | TLS-only listener | the TLS server sees bytes that are not a handshake and closes; the client sees a protocol error or EOF |
| SSH host entry | any | unchanged; TLS not applicable |
| client built without TLS, TLS host entry | any | explicit configuration error; no plaintext fallback |

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