# Native TLS transport: design v2

Tracking issue: [wiki-mod/distcc-ng#248](https://github.com/wiki-mod/distcc-ng/issues/248).

Status: architecture re-evaluation, not yet implemented.

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

## 3. Transport versus compile protocol

The most important unresolved architecture decision is whether TLS belongs to the transport layer only or requires a change to the distcc application protocol.

Two models must be considered.

### Model A: TLS as transport

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

### Model B: TLS as an application-level protocol feature

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

Version 2 deliberately does not choose between these models by assumption. The decision is an output of the transport/protocol audit.

The previous statement that TLS "will need a new protocol version" is therefore explicitly superseded by this document. A new protocol version must only be introduced if the final wire contract actually requires one.

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

mbedTLS remains a strong candidate based on the previous evaluation, but v2 does not make it a requirement before the transport abstraction is proven.

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

- DCC protocol versions supported by the fork
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

### Phase 1: transport abstraction proof

Introduce the smallest abstraction necessary to demonstrate that existing plain TCP behavior can run through a generic transport interface without changing RPC semantics.

No cryptographic implementation is required for this proof.

### Phase 2: TLS library decision

Re-evaluate the previously investigated TLS libraries against the concrete requirements from Phases 0 and 1.

mbedTLS may remain the selected library, but selection becomes evidence-backed rather than assumed.

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

- whether a new distcc protocol version is necessary
- exact transport-selection syntax
- same-port versus separate-port TLS
- exact TLS configuration key names
- exact certificate identity encoding
- pinned certificates as an initial feature versus later addition
- exact private-CA operational workflow
- whether session resumption is needed in the initial release
- ticket-key management API and rotation interval
- whether TLS should interact directly with existing `--allow` or remain orthogonal
- final TLS library choice

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

- mbedTLS remains a candidate, not a prerequisite
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