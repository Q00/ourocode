# RFC 0005: Authenticated session messaging and atomic admission

- Status: Proposed P0 contract; no production write path may ship before every
  merge gate passes
- Date: 2026-08-10
- Parent: [RFC 0001](0001-ourocode-desktop-terminal.md)
- Broker recovery contract: [RFC 0004](0004-broker-v4-recovery.md)

## Decision

Ourocode will expose next-turn session messaging only through a Rust
broker-owned authority boundary. The Swift session rail remains a presentation
and intent surface. It never chooses an exact runtime attempt, asserts a source
session, mints delivery authority, or calls the public
`ouroboros_session_signal` tool directly.

The first production operation is one authenticated, idempotent
**resolve-and-admit** request. It maps a stable target session selector to one
exact live attempt and durably admits an `after_turn` message in one Ouroboros
database transaction. A returned queued receipt proves durable admission, not
application. Runtime delivery, application, completion, rejection, and
uncertainty remain distinct states.

The authority split is normative:

- the Rust broker owns local peer admission, immutable caller principals,
  connection and authority epochs, request bounds, non-blocking transport,
  backpressure, and receipt forwarding;
- Ouroboros owns semantic session identity, source/target lifecycle, target
  resolution, authorization policy, exact-attempt guards, durable
  idempotency, the delivery outbox, owner claims, application receipts, and
  loop policy;
- Swift owns selection of a stable visible session, the user's bounded draft,
  display of receipts, and preservation of the request nonce while an outcome
  is ambiguous;
- an agent-facing MCP v2 bridge translates the standard MCP tool into the
  broker wire operation, but owns no authority itself.

The broker cannot manufacture semantic atomicity by serializing the existing
`ouroboros_session_signal_targets` and `ouroboros_session_signal` calls. The
target guard and durable outbox are in the Ouroboros database, so target
resolution and admission must be one upstream transaction.

## Current implementation and incompatibility

The checked-in source now provides bounded pieces of this contract, but not a
production authority path:

- `broker-v4.sock` is mode `0600`, accepted peers are checked for the broker's
  effective UID, and every broker incarnation uses a CSPRNG generation;
- terminal input is protected by a connection-bound input epoch and lease;
- normalized input has a bounded duplicate-receipt window and digest conflict
  detection;
- all terminal client and PTY work shares one bounded non-blocking reactor;
- the separate Rust session-message gateway, authority registry, closed bridge
  codec, and stop-and-wait principal-binding ACK coordinator exist as tested
  library components;
- register/revoke APIs consume an exact non-clone durable ACK whose operation,
  broker generation, binding ID and authority epoch match before mutation;
- `main_v4_ghostty` accepts only a complete pair of distinct, connected
  inherited `AF_UNIX/SOCK_STREAM` descriptors, protects both originals and
  owned copies with `CLOEXEC`, and otherwise keeps terminal-only launch valid;
- the Swift client implements bounded length framing, same-UID/same-broker-PID
  verification, generation checks, one pending effect, and same-nonce uncertain
  recovery for an optional broker hello descriptor.

Those pieces are necessary but insufficient. The production broker main only
validates and retains the inherited descriptors: it does not drive the gateway
or ACK coordinator, construct a verified installation authority, reciprocally
verify the Ouroboros service, supervise per-session bridge sockets, or compose
their lifecycle with `Broker::run`. It therefore advertises no session-message
gateway descriptor or mutation capability. A same-UID client can still use the
separate terminal compatibility lane, but same UID cannot become
session-message authority.

The Sessions extension can discover exact active targets, and its legacy Swift
adapter still contains a signal method. The rail does not enable that method
from catalog data or the default shared HTTP endpoint. Its message capability
now comes only from the optional kernel-authenticated terminal-broker gateway
descriptor; because production emits no descriptor, the composer remains
read-only. An explicit/public streamable-HTTP endpoint is not a substitute for
the production authenticated local transport.

Pane-specific selection is intentionally not added to this version-1 stable
session selector. The additive, non-advertised exact-attempt backend contract
and its socket evidence are specified in
[RFC 0011](0011-exact-pane-authenticated-steering.md).

## Concrete production activation boundary (2026-08-16)

The current process boundary does **not** carry enough authority to activate
steering. The following are file/symbol-level blockers, not optional polish:

| Boundary | Current symbol | Missing production proof |
| --- | --- | --- |
| Shared Ouroboros launch | `SharedOuroborosServiceSupervisor.makePlistData` in `SharedOuroborosService.swift` | The plist has HTTP `ProgramArguments`, `EnvironmentVariables`, and readiness only. It has no launchd `Sockets`/`MachServices`, private registration endpoint, audit-token handoff, or inherited broker descriptors. HTTP `serverInfo` 0.51.5 proves compatibility, not service identity for mutation. |
| Desktop broker launch | `BrokerClient.launchBundledBroker` in `BrokerClient.swift` | The app starts the helper with `Process` and one pathname argument. There is no launchd/XPC broker owner, socket activation, reciprocal code requirement, or FD handoff. |
| Inherited descriptor validation | `GhosttyBrokerRuntimeArgs` / `InheritedGatewayFds` in `gateway_runtime_contract.rs` | The two connected UNIX streams are validated and protected with `CLOEXEC`, but deliberately classify as `PrivateTransportsValidatedButUnauthenticated`. Descriptor presence must never enable hello advertisement. |
| Installation scope | `VerifiedInstallationAuthorityV1::from_verified_installation` in `principal_binding_registration.rs` | Only crate-private/test scaffolding can mint workspace/forest authority. A production installer-owned verifier and immutable policy artifact are absent. No environment/CLI constructor may replace it. |
| Ouroboros service peer | `VerifiedOuroborosServicePeer` in `authority_registry.rs` | Production has no reciprocal peer verifier or constructor. A loopback HTTP endpoint, launchd label string, PID, executable path, or MCP catalog response is insufficient. |
| Durable desktop activation | `DesktopAuthorityActivator` and `DurablyActivatedDesktopAuthority` in `session_message_gateway.rs` | No production activator drives a prepared registration through `PrincipalBindingAckCoordinator`, consumes its exact durable ACK, and publishes/revokes a cached authority. |
| Composite reactor/lifecycle | `Broker::run`, `SessionMessageGateway::tick`, and `PrincipalBindingAckCoordinator` | They are not composed under one supervised runtime. Service disconnect, broker generation rollover, session bridge creation, ACK ambiguity, and shutdown must revoke exact bindings before any descriptor is advertised. |
| Broker hello | `ServerBodyV4::Hello` in `lib.rs` and `BrokerHello` in `BrokerClient.swift` | Rust emits no `session_message_gateway` descriptor today. Swift can decode and verify an optional descriptor, but absence correctly remains read-only. The descriptor may be emitted only after every preceding row is live for the same broker generation. |

The next safe implementation unit is therefore a launchd/XPC-owned composite
runtime, not a boolean capability toggle:

1. define an installer-owned, owner-only policy artifact and verifier that is
   the sole production constructor for `VerifiedInstallationAuthorityV1`;
2. give the Ouroboros service and broker reciprocal private endpoints with
   kernel/audit-token verification, then mint `VerifiedOuroborosServicePeer`
   only from that evidence;
3. drive principal registration/revocation stop-and-wait on the dedicated FD,
   and activate only the exact durable ACK token already required by the
   gateway APIs;
4. supervise gateway, ACK coordinator, terminal broker, service disconnect,
   and generation rollover as one lifecycle;
5. only after the gateway listener is bound and desktop authority is durably
   active, include its private path/generation/capabilities/authority in hello.

Regression contracts keep the interim boundary fail-closed:

- `gateway_runtime_contract` tests prove terminal-only and descriptor-pair
  launches both return `may_advertise_authenticated_session_messaging == false`;
- `SharedOuroborosServiceFixture` proves the current launch plist has no
  `Sockets`, `MachServices`, or session-message FD flags;
- `SessionMessageGatewayClientFixture` proves an absent descriptor and public
  MCP capability strings cannot produce Swift authority.

Ouroboros 0.51.1 has a transactional active-target admission fence. It checks
`session_signal_target_guards.active` and records accepted/queued events under
`BEGIN IMMEDIATE`. However, the requested event, semantic target resolution,
capability check, and contract-version check occur before that transaction,
and process-local queue handoff occurs after commit. The caller also supplies
the source enum. This RFC therefore defines a new contract rather than
silently reinterpreting the legacy tool.

## Security and trust boundary

### Same UID is admission, not authority

Mode `0600`, a mode `0700` parent directory, `getpeereid` on macOS, and
`SO_PEERCRED` on Linux are mandatory. They exclude other login users. They do
not distinguish Ourocode from arbitrary code already running as the same
login user and do not authenticate session A.

Every accepted transport is assigned exactly one immutable principal:

```rust
enum ClientPrincipal {
    ReadOnlyUid {
        uid: u32,
    },
    SignedDesktop {
        uid: u32,
        binding_id: BoundedId,
        audit_identity_digest: [u8; 32],
        desktop_incarnation: [u8; 24],
        authority_epoch: u64,
    },
    OuroborosSession {
        uid: u32,
        binding_id: BoundedId,
        session_id: BoundedId,
        execution_id: BoundedId,
        scope_id: BoundedId,
        attempt_id: BoundedId,
        authority_epoch: u64,
        cause: Option<SessionCause>,
    },
}

struct SessionCause {
    signal_id: BoundedId,
    hop_count: u8,
}
```

Source identity is never accepted from JSON or MCP tool arguments. A request
field named `source`, `source_session_id`, `source_attempt_id`, `hop_count`, or
`authority_role` is a protocol error rather than an ignored compatibility
field.

`ReadOnlyUid` may list bounded public projections negotiated for that endpoint.
It may not attach, input, resize, terminate, register a session, or send a
message. Existing terminal-control mutation remains an explicit compatibility
lane until signed desktop admission is complete; it must not be reused for
session messaging.

### Desktop authority

On macOS, production desktop mutation uses a launchd-owned XPC connection or
an equivalent transport that supplies an audit token. The broker binds the
audit token and reviewed signing requirement to the client incarnation. A raw
pathname UDS with only `getpeereid` remains a development/read-only transport.

On Linux, production mutation uses a broker-supervised inherited Unix socket
or a launch mechanism that binds `SO_PEERCRED` PID plus a non-reusable process
identity such as a pidfd to the expected executable. PID or parent-PID checks
alone are insufficient because PID reuse and same-user sibling processes do
not prove application identity.

The desktop performs reciprocal verification before trusting `hello`:

- the kernel-reported peer UID must equal the effective UID;
- the kernel-reported peer PID or audit identity must match the launchd/XPC or
  broker-launch contract;
- `hello.pid` must match the kernel peer PID when a PID is available;
- the broker generation must be nonzero and changes invalidate every local
  authority object;
- a path-based development socket must be a socket owned by the effective UID
  under a non-symlink mode-`0700` directory.

None of those checks independently upgrades a read-only path transport to
production write authority.

### Session authority

Only broker-supervised Ouroboros sessions receive a session principal. The
trusted Ouroboros service registers an exact live session binding over its
authenticated private connection:

```rust
struct RegisterSessionAuthorityV1 {
    binding_id: BoundedId,
    session_id: BoundedId,
    execution_id: BoundedId,
    scope_id: BoundedId,
    attempt_id: BoundedId,
    authority_epoch: u64,
    owner_incarnation: BoundedId,
    terminal_id: Option<BoundedId>,
    expires_at: Timestamp,
    cause: Option<SessionCause>,
}
```

Registration is accepted only from the authenticated Ouroboros service and is
validated against its durable active-attempt guard. The broker then creates a
connected `AF_UNIX/SOCK_STREAM` socketpair for the session MCP bridge and binds
the server end to that registration. The bridge receives the other end as an
inherited capability descriptor. The descriptor is never serialized into an
argument, environment variable, pathname, log, or world-readable file.

The broker clears `CLOEXEC` only for the one intended bridge descriptor and
closes every unintended duplicate in parent and child. Disconnect, expiry,
the bound source session's terminal lifecycle, owner-incarnation replacement,
or broker restart revokes the binding. A generic Codex or Claude process
started outside this supervised launch is not an authenticated Ouroboros
session merely because it runs inside an Ourocode PTY.

Principal persistence registration uses a second broker-supervised inherited
socketpair that is never shared with resolve/status traffic. The Rust broker
may construct a registration frame only from an opaque verified desktop peer
or authenticated Ouroboros service capability plus an installation-owned
workspace/forest policy capability. There is no public constructor or JSON
decoder for that policy. The broker obtains a durable registration
acknowledgement before exposing the corresponding desktop/session binding to a
client connection. If local activation then fails, it sends the exact durable
revoke before reusing either binding ID or authority epoch.

The privileged session registration frame carries exact semantic IDs and the
verified owner incarnation, but deliberately omits source generation.
Ouroboros selects the matching active-attempt guard and derives its generation
while checking owner, workspace, and forest under the same `BEGIN IMMEDIATE`
transaction that inserts the binding. A field named `source_generation` is an
unknown-field protocol error. Registration request IDs are allocated by the
broker upstream connection and are not copied from client-local request IDs.

### Service-to-service authority

The broker's Ouroboros connection is a launchd-owned, mode-`0600` private UDS
or XPC service with reciprocal peer validation. The public MCP endpoint never
accepts a broker authority assertion. The private service binds one broker
incarnation to the connection and accepts `principal_binding_id` only from
that connection.

The broker calls the private upstream MCP tool
`ouroboros_session_message_resolve_and_admit` with this exact closed argument
object:

```rust
struct PrivateResolveAndAdmitV1 {
    schema_version: u16,             // exactly 1
    broker_generation: u64,
    principal_binding_id: BoundedId,
    authority_epoch: u64,
    request_nonce: Nonce,
    target_session_id: BoundedId,
    expected_execution_id: Option<BoundedId>,
    expected_target_generation: Option<u64>,
    mode: SessionMessageMode,
    message: BoundedMessage,
    reason: BoundedReason,
    expires_at: Timestamp,
    correlation_id: Option<BoundedId>,
}
```

The private handler looks up `principal_binding_id` under the authenticated
broker incarnation and recomputes the request digest from the authoritative
binding. It does not accept source identity, authority role, causal parent, or
hop count from the broker payload. The status tool accepts only
`schema_version`, `broker_generation`, `principal_binding_id`,
`authority_epoch`, and `request_nonce`.

A request nonce is an idempotency identity, not an authentication secret. A
challenge echoed over an unauthenticated same-UID connection also does not
authenticate the peer.

## Protocol negotiation

The local session bridge implements MCP protocol `2025-06-18` and exposes the
tool below only after its inherited broker connection has been authenticated:

```text
ouroboros_session_message
```

The broker advertises all of the following exact capabilities:

```text
mcp.session_message.authenticated.v1
session.message.resolve_admit.v1
session.message.status.v1
session.message.receipt_cursor.v1
```

Ouroboros advertises the latter three capabilities on the private broker
connection. Missing or unknown required contract versions disable the write
tool. There is no fallback from this tool to `ouroboros_session_signal`, no
fallback to loopback HTTP, and no conversion of a read-only peer into a user
principal.

The existing general MCP Sources browser remains provider-neutral. Tools,
resources, prompts, and bounded session projections continue to work for
read-only sources even when authenticated messaging is unavailable.

## Agent-facing MCP v2 tool

The MCP tool arguments are exact and closed; additional properties are
rejected:

```json
{
  "request_nonce": "base64url-no-padding-128-to-256-bit",
  "target_session_id": "stable-session-b",
  "expected_execution_id": "optional-execution-guard",
  "expected_target_generation": 7,
  "mode": "after_turn",
  "message": "bounded additive intent",
  "reason": "bounded user-visible rationale",
  "expires_at": "2026-08-10T15:04:05.000Z",
  "correlation_id": "optional-caller-correlation"
}
```

`expected_execution_id`, `expected_target_generation`, and `correlation_id`
are optional. Every other field is required. P0 accepts only `after_turn` and
additive intent. Redirect, replacement, specification changes, arbitrary
provider-native IDs, and caller-controlled exact attempt IDs are rejected.
`expires_at` must be later than the transaction clock and no more than ten
minutes after it; clients should normally use two minutes.

The bridge forwards the request without adding a caller-provided source. The
broker derives source identity, authority role, causal parent, and hop count
from `ClientPrincipal`.

The MCP result `_meta` contains the exact receipt defined below. Human-readable
text must say either `durably queued; application is not yet proven`, the
terminal failure state, or the completed reply summary. It must never call a
queued receipt delivered or applied.

## Broker wire protocol

The internal broker operation uses bounded newline-delimited JSON version 1.
The privileged session path normally runs over an inherited socketpair; signed
desktop/XPC code maps the same value types without acquiring a session
principal. Every wire struct uses `deny_unknown_fields`. `Timestamp` is a
timezone-aware RFC 3339 UTC instant and all integers use their full unsigned
range unless a smaller bound is stated.

```rust
struct SessionMessageRequestV1 {
    version: u16,                    // exactly 1
    id: u64,                         // nonzero connection-local request id
    op: ResolveAndAdmitV1,           // exact string below
    broker_generation: u64,
    authority_epoch: u64,
    request_nonce: Nonce,
    target_session_id: BoundedId,
    expected_execution_id: Option<BoundedId>,
    expected_target_generation: Option<u64>,
    mode: SessionMessageMode,        // exactly AfterTurn in v1
    message: BoundedMessage,
    reason: BoundedReason,
    expires_at: Timestamp,
    correlation_id: Option<BoundedId>,
}

enum ResolveAndAdmitV1 {
    #[serde(rename = "session_message_resolve_and_admit")]
    ResolveAndAdmit,
}

enum SessionMessageMode {
    #[serde(rename = "after_turn")]
    AfterTurn,
}
```

Its canonical JSON shape is:

```json
{
  "version": 1,
  "id": 42,
  "op": "session_message_resolve_and_admit",
  "broker_generation": 873421,
  "authority_epoch": 3,
  "request_nonce": "EiQ2SFpscYKTpLXNZ2mr7A",
  "target_session_id": "session-b",
  "expected_execution_id": "execution-1",
  "expected_target_generation": 7,
  "mode": "after_turn",
  "message": "Re-check the reconnect boundary.",
  "reason": "Session A found a stale-owner race.",
  "expires_at": "2026-08-10T15:04:05.000Z",
  "correlation_id": "review-17"
}
```

The local status request is:

```rust
struct SessionMessageStatusRequestV1 {
    version: u16,                    // exactly 1
    id: u64,
    op: StatusV1,                    // "session_message_status"
    broker_generation: u64,
    authority_epoch: u64,
    request_nonce: Nonce,
}

enum StatusV1 {
    #[serde(rename = "session_message_status")]
    Status,
}
```

It returns the same `SessionMessageReceiptV1` with the current durable state
and never changes delivery state.

`authority_epoch` must equal the connection principal. It is a stale-binding
guard, not a bearer token. The source fields, causal parent, hop count, and
authority role do not appear on the wire because the broker already owns them.

### Privileged principal-binding wire

Principal registration/revocation is a distinct length-prefixed inherited-FD
protocol. It is not an operation in the resolve/status union. Frames are flat,
closed, bounded to 32 KiB, reject duplicate keys, and use broker-upstream
nonzero request IDs. The canonical language-neutral vectors are frozen in
[`fixtures/principal-binding-registration-v1-known-vector.json`](fixtures/principal-binding-registration-v1-known-vector.json).

The three exact operations are:

```text
principal_binding_register_desktop
principal_binding_register_session
principal_binding_revoke
```

Desktop registration contains only broker generation, binding ID, verified
UID, authority epoch, installation workspace/forest, canonical base64url audit
identity digest and desktop incarnation, and expiry. Session registration
contains only broker generation, binding ID, verified service UID, authority
epoch, installation workspace/forest, exact source session/execution/scope/
attempt IDs, verified owner incarnation, expiry, and registry-derived optional
cause signal/hop. Principal kind and durable principal ID are derived from the
operation and binding ID. Neither registration operation accepts a nested
binding object, bearer, source generation, role, terminal connection ID, or
caller-supplied policy object.

The bounded success result is `principal_binding_registered` or
`principal_binding_revoked` with the exact binding ID, authority epoch, and a
`changed` boolean. A successful/idempotent durable registration acknowledgement
is a prerequisite for local activation. Revoke is durably acknowledged before
the local registry removes the binding. Only the exact service admission epoch
that registered a session may prepare or apply its revoke; another verified
service cannot revoke it by learning the binding ID and epoch.

The exact closed principal-binding ACK is:

```rust
struct PrincipalBindingAckV1 {
    version: u16,                    // exactly 1
    broker_generation: NonZeroU64,  // exact prepared generation
    id: NonZeroU64,                 // exact prepared request ID
    result: PrincipalBindingResult, // registered | revoked
    binding_id: BoundedId,          // exact prepared binding
    authority_epoch: u64,           // exact prepared epoch
    changed: bool,                  // false is a valid idempotent success
}
```

The broker uses bounded stop-and-wait on this descriptor. Unknown fields,
identity/result mismatches, and malformed ACKs never mint an activation token.
After any tracked request byte is written, descriptor failure makes the durable
outcome ambiguous and forbids automatic retry for that broker generation. An
abandoned but possibly visible request is completed and its exact ACK drained;
if it registered durably, the same binding ID/epoch cannot be reused until an
exact revoke is durably acknowledged.

The separate session-message success reply is:

```rust
struct SessionMessageReceiptV1 {
    version: u16,                    // exactly 1
    broker_generation: u64,
    id: u64,
    result: ReceiptResult,           // "session_message_receipt"
    request_nonce: Nonce,
    request_digest: Sha256Digest,
    signal_id: BoundedId,
    source: ExactSourceIdentity,
    target: ExactSessionIdentity,
    mode: SessionMessageMode,
    state: SessionMessageState,
    durable_cursor: u64,
    application_proven: bool,
    replayed: bool,
    hop_count: u8,
    expires_at: Timestamp,
    reply_summary: Option<BoundedReply>,
}

struct ExactSessionIdentity {
    session_id: BoundedId,
    execution_id: BoundedId,
    scope_id: BoundedId,
    attempt_id: BoundedId,
    generation: u64,
}

#[serde(tag = "kind", rename_all = "snake_case")]
enum ExactSourceIdentity {
    User {
        principal_id: BoundedId,
        authority_epoch: u64,
    },
    Session {
        #[serde(flatten)]
        identity: ExactSessionIdentity,
    },
}

enum ReceiptResult {
    #[serde(rename = "session_message_receipt")]
    SessionMessageReceipt,
}

#[serde(rename_all = "snake_case")]
enum SessionMessageState {
    Queued,
    Delivering,
    Applied,
    Completed,
    Rejected,
    DeliveryUncertain,
}
```

A signed desktop principal is encoded in the upstream durable event and local
receipt as the tagged user identity. It must not fabricate scope or attempt
IDs.

Receipts do not echo the message or reason. `request_digest` is SHA-256 over a
versioned, length-prefixed encoding of the derived source principal,
authority epoch, request nonce, target selector, expected guards, mode,
message digest, reason digest, expiry, derived causal parent/hop, and optional
correlation ID. JSON serialization order is never the digest preimage.

The broker returns only these stable error codes:

```text
bad_version
bad_request
unauthenticated
unauthorized
stale_generation
stale_authority
nonce_conflict
source_not_active
target_not_found
target_ambiguous
target_not_active
target_generation_mismatch
receipt_not_found
cross_forest_denied
self_message_denied
hop_limit_exceeded
capability_unsupported
expired
queue_full
upstream_unavailable
outcome_unknown
internal
```

The bounded error reply is exact:

```rust
struct SessionMessageErrorV1 {
    version: u16,                    // exactly 1
    broker_generation: u64,
    id: u64,
    error: ErrorResult,              // "session_message_error"
    code: SessionMessageErrorCode,
    message: BoundedErrorMessage,    // at most 1,000 UTF-8 bytes
}

enum ErrorResult {
    #[serde(rename = "session_message_error")]
    SessionMessageError,
}
```

Errors are bounded and contain no message body, credential, provider-native ID,
or unbounded database detail. `outcome_unknown` instructs the caller to repeat
the identical request nonce or call status; it never authorizes a new nonce.

## Idempotency and replay

`request_nonce` decodes to 16 through 32 bytes and uses canonical unpadded
base64url. The caller creates it before the first attempt and retains it while
the outcome can be ambiguous. A UUID may be used only if its full 122 bits of
randomness are preserved and its canonical byte representation is used.

The durable idempotency key is:

```text
(source_principal_id, source_authority_epoch, request_nonce)
```

The first request stores `request_digest` and the resolved exact target. A
later request with the same key and digest returns the latest receipt for the
original exact target with `replayed=true`; it never resolves a newer attempt.
A later request with the same key and a different digest fails with
`nonce_conflict` and causes no event or provider effect.

Broker request IDs, JSON-RPC IDs, connection file descriptors, PIDs, input
lease IDs, and broker generations are not substitutes for the request nonce.
The in-memory broker replay cache is an optimization only. Correctness comes
from the Ouroboros durable unique key.

The status operation accepts exactly the authenticated principal,
`authority_epoch`, and `request_nonce`. It returns one bounded receipt or
`receipt_not_found`; it does not replay an execution, scan arbitrary events, or
return the message body. A signed user principal may query only receipts it
created. A session principal may query only its exact source identity and
authority epoch.

## Authorization and loop policy

P0 session-to-session messages are allowed only when source A and target B are
active members of the same Ouroboros execution forest and workspace authority.
Cross-execution or cross-workspace delivery is denied even when both processes
share a UID. A signed user principal may target any session visible under its
authenticated workspace authority, subject to the same exact-target checks.

A session may not target its own exact identity in P0. This avoids accidental
self-resume loops while the broader loop policy is still intentionally small.

The authoritative causal context is derived from the source binding:

- a normal active source session sends at hop 1;
- a source turn resumed because of signal `S` carries `cause=(S, 1)`;
- any outbound message from that resumed turn would be hop 2 and is rejected;
- a caller-supplied correlation ID never changes this count.

Thus P0 permits one direct A-to-B edge and no automatic forwarding. Raising the
hop limit requires a later RFC with cycle detection and explicit policy. The
message cannot weaken permissions, confirmation, credential, tool, routing, or
external-effect gates in B.

## Durable database contract

Ouroboros is the sole durable authority. The implementation may use the
existing append-only event store and projection tables, but it must provide the
equivalent of these indexed records:

```text
session_message_idempotency
  source_principal_id
  source_authority_epoch
  request_nonce
  request_digest
  signal_id
  resolved_target_execution_id
  resolved_target_scope_id
  resolved_target_attempt_id
  resolved_target_generation
  state
  durable_cursor
  created_at
  expires_at
  UNIQUE(source_principal_id, source_authority_epoch, request_nonce)

session_message_outbox
  signal_id PRIMARY KEY
  target_execution_id
  target_scope_id
  target_attempt_id
  target_generation
  target_owner_incarnation
  state
  claim_epoch
  message_ciphertext_or_bounded_payload
  message_digest
  expires_at
  updated_at
```

The exact-attempt guard must expose active state, session ID, execution/scope/
attempt identity, session generation, contract version, capability fingerprint,
workspace/forest authority, and current owner incarnation through indexed
columns or an equally atomic projection. Target selection uses an indexed query
with `LIMIT 2`: zero rows is not found/inactive, two rows is ambiguous, and
exactly one row may be admitted. It never calls an unbounded event replay or
`query_execution_related_events(limit=None)` inside admission.

### Resolve-and-admit transaction

SQLite uses `BEGIN IMMEDIATE`; other databases use an equivalent serializable
transaction or explicit row locks. The transaction performs these steps in
order without yielding to a process-local queue:

1. Read the idempotency row by exact source principal, authority epoch, and
   nonce.
2. If present, compare the request digest and return the existing receipt or
   `nonce_conflict`.
3. Validate source authority and active source lifecycle at the registered
   source generation.
4. Resolve `target_session_id` plus optional guards to zero, one, or multiple
   exact active attempts using bounded indexed reads.
5. Enforce workspace/forest authorization, self-message denial, causal hop,
   expiry, contract generation, target owner incarnation, and `after_turn`
   capability.
6. Insert the immutable requested, accepted, and queued lifecycle events.
7. Insert the idempotency row and durable outbox payload.
8. Advance and store the durable receipt cursor.
9. Commit.

If validation rejects a well-formed request, the transaction inserts one
immutable rejected receipt under the idempotency key, without an outbox row, so
an identical retry returns the same decision. Authentication failures and
malformed requests are not persisted.

The transaction commits all requested/accepted/queued/outbox/idempotency state
or none of it. A process-local `enqueue()` after commit is not delivery
ownership and cannot be required for the queued receipt to be true.

### Delivery claim

The runtime owner loads at most a bounded batch of queued rows and claims one
with a compare-and-swap equivalent to:

```sql
UPDATE session_message_outbox
SET state = 'delivering',
    claim_epoch = claim_epoch + 1,
    updated_at = :now
WHERE signal_id = :signal_id
  AND state = 'queued'
  AND target_owner_incarnation = :current_owner
  AND expires_at > :now
RETURNING claim_epoch;
```

The provider acknowledgement is accepted only for the same signal, exact
target, owner incarnation, and claim epoch. A stale worker cannot acknowledge a
replacement attempt. The next-turn prompt is built only after a successful
claim and contains bounded additive intent, source display metadata, signal ID,
and no credential.

Target terminal lifecycle updates its guard and pending outbox rows in the
same lifecycle transaction:

- queued rows become rejected with `target_ended_before_boundary`;
- delivering rows become `delivery_uncertain` unless the provider proves no
  effect occurred;
- applied rows retain application proof and may complete with a bounded reply.

## State machine

Externally observable states are:

```text
                    +--> rejected
                    |
none --atomic tx--> queued --> delivering --> applied --> completed
                      |            |
                      +--> rejected +--> delivery_uncertain
```

`requested` and `accepted` remain audit events inside the initial atomic
transaction and are never externally stable receipt states.

Allowed transitions are:

| From | To | Required proof |
| --- | --- | --- |
| none | queued | resolve-and-admit transaction committed with outbox row |
| none | rejected | immutable rejection committed under idempotency key |
| queued | delivering | exact owner-incarnation CAS claim |
| queued | rejected | expiry, terminal target, or explicit pre-claim policy decision |
| delivering | applied | provider acknowledgement bound to claim epoch |
| delivering | delivery_uncertain | owner loss or crash after effect may have begun |
| applied | completed | bounded completion/reply receipt |

`rejected`, `delivery_uncertain`, and `completed` are terminal. `applied` is
application proof but may still await a completion reply. No terminal state can
transition back to queued. A duplicate event with the same immutable digest is
ignored; a conflicting duplicate fails the projection closed.

`application_proven` is true only for applied or completed. It is false for
queued, delivering, rejected, and delivery uncertain.

## Crash and ambiguous-ack semantics

The P0 broker does not own an offline durable message queue. Ouroboros is the
only durable store, which keeps the smallest correct crash boundary:

| Failure point | Required result |
| --- | --- |
| broker dies before upstream commit | no durable receipt; identical nonce may be retried |
| broker dies after commit before local reply | retry/status returns the committed receipt without re-resolution |
| Swift or MCP bridge loses the reply | preserve nonce; repeat identical request or status |
| upstream is unavailable before commit | `upstream_unavailable`; no durable-queue claim and no retained broker payload |
| worker dies before claim | row remains queued for the current owner/recovery policy |
| worker dies after claim before provider effect | recover only if no-effect proof exists; otherwise delivery uncertain |
| worker dies after provider effect before ack | delivery uncertain; never automatically resend |
| target ends before admission lock | rejected, no outbox |
| target ends after admission commit | queued receipt followed by durable rejection or uncertainty according to claim state |
| broker restarts | new broker generation; every local authority binding is stale |
| source owner is replaced | old authority epoch cannot send or acknowledge; status remains read-only for authorized recovery |

The broker reserves enough response-queue capacity for the maximum bounded
receipt before starting the upstream operation. Failure to reserve returns
`queue_full` before commit. A transport error after upstream commit is still an
ambiguous acknowledgement and relies on durable nonce replay; it never causes
an automatic request with a new nonce.

Offline authoring or broker-owned durable drafts are future features. Adding
them requires a separately checksummed, fsync-defined WAL contract and is not
implicit in this RFC.

## Memory and fairness contract

All limits are UTF-8 byte limits after normalization, not Swift character
counts:

| Item | P0 maximum |
| --- | ---: |
| message | 8,192 bytes |
| reason | 1,000 bytes |
| reply summary | 1,000 bytes |
| each identity/correlation field | 256 bytes |
| decoded nonce | 32 bytes |
| broker session-message wire frame | 32 KiB |
| encoded receipt | 16 KiB |
| in-flight requests per client | 2 |
| in-flight requests globally | 64 |
| broker upstream pending payload | 1 MiB globally |
| per-client session-message output queue | 64 KiB |
| in-memory replay receipts | 256 globally, 10-minute TTL |
| runtime outbox fetch batch | 16 rows / 128 KiB payload |

The broker validates fixed-size fields and total frame length before allocating
message storage. Secret-shaped content is rejected using the Ouroboros bounded
signal policy. Audit events retain message and reason digests rather than body
copies. The outbox retains the one delivery payload until terminal state and
then scrubs or encrypts it according to Ouroboros retention policy.

After a durable receipt is decoded, the broker releases its message payload.
The replay cache stores receipt metadata and digests only. Cache eviction never
changes correctness because status and duplicate admission use the durable
unique row.

The gateway is integrated into the existing descriptor-driven reactor. It
does not create one thread, process, URLSession, or Python MCP server per
message or terminal. Each tick enforces separate accept/read/request/write
budgets for terminal and gateway descriptors. A slow upstream connection stops
accepting new signal payloads at the global byte cap; it cannot stop PTY reads,
PTY writes, recovery expiry, or termination reaping.

An oversized or slow client is disconnected or receives bounded backpressure.
It never causes broker-wide buffer growth. Target resolution, status, and
receipt projection are indexed and bounded; none materializes an execution's
complete event history.

## Swift and UI contract

The Sources rail may display session B and collect a draft. On send it passes
only the stable target session ID, optional generation guard, request nonce,
mode, message, reason, expiry, and correlation ID to a broker adapter.

Swift does not:

- call target discovery to acquire write authority;
- send exact scope or attempt IDs as authority;
- set `source=user` or any session source field;
- infer capability from arbitrary MCP JSON;
- automatically retry with a new nonce;
- call the legacy signal tool after an authenticated-tool failure;
- label queued or delivery-uncertain state as applied.

The adapter preserves the draft and nonce for `upstream_unavailable`,
`outcome_unknown`, disconnect, or timeout. It clears the payload after a
durable receipt while retaining bounded receipt metadata. Session row rebuild,
selection changes, and Rail collapse do not change authority or cause a second
send.

For agent A, the same semantics are presented through MCP v2. The bridge's
human-readable result and `_meta` receipt agree exactly. Generic MCP sources
remain unaffected and never receive the privileged tool.

## Migration and compatibility

This contract is additive and fail closed.

1. Ouroboros adds the idempotency/outbox schema and indexed active-session
   projection. Schema migration is transactional and safe to run repeatedly.
2. Existing `session_signal` events remain readable legacy audit history. They
   are not backfilled with authenticated source principals and cannot authorize
   a `SessionMessageReceiptV1`.
3. Ouroboros ships the private resolve-and-admit and status capabilities behind
   a disabled-by-default feature flag. The public MCP server does not advertise
   them.
4. The Rust broker adds principal admission, the private Ouroboros connection,
   bounded gateway state, and the session MCP bridge. This uses a new
   `session-message-v1` namespace or inherited socketpair and does not widen
   an old socket silently.
5. The desktop adds reciprocal broker verification and a broker-backed message
   adapter. Direct Swift steering remains compiled out in production.
6. The authenticated UI is enabled only when every required capability and
   schema version is negotiated. Otherwise the Rail remains read-only with an
   explicit explanation.
7. The old loopback HTTP and `ouroboros_session_signal` path remains a visibly
   labelled developer compatibility mode. It cannot display session-to-session
   authentication or production delivery claims.

There is no migration that grants authority to existing path-based clients,
cached exact targets, UUIDs whose payload is lost, or legacy queued signals.

## Phased implementation

### Phase 0 — upstream contract and fixtures

- publish the Ouroboros schema/tool issue linked from this RFC;
- freeze cross-language digest vectors, error codes, receipt JSON, bounds, and
  state transitions;
- treat
  [`fixtures/session-message-v1-known-vector.json`](fixtures/session-message-v1-known-vector.json)
  as the language-neutral digest fixture; Rust, Swift, and Ouroboros must
  reproduce it byte-for-byte before enabling the capability;
- add captured fixtures for queued, rejected, duplicate, conflict, applied,
  completed, and uncertain receipts.

### Phase 1 — peer and principal admission

- implement reciprocal desktop peer verification;
- add signed desktop/XPC admission on macOS;
- add broker-supervised inherited socketpair admission for session bridges;
- keep all same-UID pathname peers read-only;
- add registration, expiry, disconnect, and authority-epoch revocation.
- keep privileged register/revoke on a dedicated inherited descriptor, and
  require its durable acknowledgement before exposing the local binding;

No message tool is exposed in this phase.

### Phase 2 — Ouroboros atomic authority

- add indexed target projection, idempotency and outbox storage;
- implement one resolve-and-admit transaction and bounded status lookup;
- implement owner-incarnation claim and terminal-lifecycle draining;
- bound or remove process-lifetime signal-lock maps;
- prove crash behavior at every transaction/claim boundary.

### Phase 3 — Rust gateway and MCP bridge

- add the non-blocking private Ouroboros connection to the broker reactor;
- implement exact wire structs, digest, queue reservation, replay cache, and
  memory counters;
- expose `ouroboros_session_message` only on an authenticated session bridge;
- launch Codex/Claude test sessions through broker-owned bindings.

### Phase 4 — Swift cutover

- add the broker-backed adapter and receipt timeline;
- persist one nonce with each ambiguous draft;
- remove production direct target-discovery/send authority from Swift;
- retain generic MCP catalog/session browsing as read-only functionality.

### Phase 5 — performance and promotion

- run 32-terminal plus multi-session fairness and physical-memory gates;
- run live Codex/Claude A-to-B next-turn tests under Luna/computer use;
- verify app, broker, bridge, Ouroboros service, and descendants as one process
  manifest;
- enable production UI only after the security, crash, and memory merge gates
  pass.

## Required tests and merge gates

### Peer and principal security

1. Socket and parent-directory mode, owner, symlink, stale-socket, and
   listener-substitution tests fail closed.
2. Foreign UID and same-UID unsigned clients cannot acquire any mutation or
   session-message capability.
3. macOS audit-token/signing mismatch and Linux inherited-capability/PID
   identity mismatch fail before request parsing.
4. The desktop rejects a broker whose kernel peer identity disagrees with
   `hello.pid` or the launch contract.
5. A JSON/MCP request containing source, exact source attempt, hop count, or
   authority role is rejected.
6. Copying an authority epoch or nonce to another connection, session,
   terminal, UID, broker generation, or owner incarnation grants no authority.
7. Disconnect, expiry, source completion, target owner replacement, and broker
   restart revoke the intended binding and no other binding.

### Nonce and replay

8. Same principal/epoch/nonce/digest returns the identical signal and exact
   target with `replayed=true` and creates one outbox row.
9. Same nonce with any message, reason, target, expiry, mode, generation,
   correlation, or causal change returns `nonce_conflict` with no new event.
10. Two concurrent identical requests commit once; two concurrent conflicting
    requests produce one winner and one deterministic conflict.
11. Dropping the reply after upstream commit and reconnecting returns the same
    receipt through both duplicate admission and status.
12. Replay-cache eviction and broker restart do not affect durable idempotency.

### Atomic target and delivery ownership

13. Target termination racing admission yields either an atomic rejection or a
    durable queued receipt followed by the correct terminal transition; it
    never leaves accepted without idempotency and outbox state.
14. Target attempt replacement racing admission never redirects a duplicate
    nonce to the replacement attempt.
15. Zero and multiple active matches return not-found/ambiguous without
    guessing; optional generation and execution mismatches fail closed.
16. Source termination, forest/workspace mismatch, self-message, and hop 2 all
    reject inside admission.
17. Capability, contract, guard, and owner-incarnation changes are read from one
    consistent transaction snapshot.
18. Only one current owner claim succeeds. Stale owner and stale claim-epoch
    acknowledgements cannot apply or complete a signal.
19. Target terminal lifecycle atomically rejects queued rows and marks claimed
    rows uncertain according to the state machine.

### Crash recovery

20. Kill the broker before upstream send, during send, after commit, while
    decoding, and before local reply; identical nonce recovery matches the
    crash table.
21. Kill the Ouroboros handler before transaction, during transaction, after
    commit, and before response; no partial initial state is observable.
22. Kill the runtime before claim, after claim, before provider effect, after
    provider effect, and before acknowledgement; no automatic uncertain resend
    occurs.
23. Restart broker and runtime with new incarnations; old authority and claims
    fail while read-only durable status remains reconcilable.

### Bounds and reactor fairness

24. Boundary fixtures cover 0/1/max/max+1 bytes for every field, invalid UTF-8,
    noncanonical nonce, secret-shaped content, malformed JSON, and unknown
    fields.
25. Sixty-four clients filling input/output/in-flight limits remain inside the
    declared broker byte budget; the sixty-fifth global request receives
    bounded backpressure.
26. One hundred thousand unique nonces do not grow broker replay memory past
    256 receipts; upstream status remains indexed and bounded.
27. A stopped or slow Ouroboros service fills at most 1 MiB of pending broker
    payload and does not starve PTY input/output, recovery expiry, compression
    slices, termination escalation, or client fairness.
28. Runtime outbox reads never exceed 16 rows or 128 KiB and target resolution
    never materializes complete execution history.
29. Receipt queue reservation failure occurs before upstream commit. Ambiguous
    post-commit transport failure is reconciled only by the original nonce.
30. Thirty-two terminals plus eight active session-message clients meet RFC
    0001 key-to-frame and idle-CPU gates with measured physical footprint and
    private-dirty evidence.

### End-to-end product truthfulness

31. A broker-supervised Codex session A calls the MCP v2 tool and exactly one
    next turn reaches selected session B; the receipt remains queued until
    application proof arrives.
32. The same test passes for Claude Code, concurrent A-to-B requests, target
    completion, app restart, and Rail selection changes.
33. A message-triggered B turn cannot forward to C under P0 hop policy.
34. Generic MCP source fixtures, tools/resources/prompts browsing, and ordinary
    zsh terminal use remain functional without authenticated messaging.
35. Production binary/string inspection and request capture show zero Swift
    calls to `ouroboros_session_signal_targets` or
    `ouroboros_session_signal` for write authority and zero release use of the
    unauthenticated loopback bridge.

## Non-goals

This RFC does not add redirect/replace, specification-changing intent,
cross-workspace messaging, arbitrary provider-native addressing, automatic
multi-hop forwarding, mobile pairing, offline broker-owned signal queues,
general terminal command authorization redesign, or proof that a provider
effect itself is exactly once. It establishes the smallest authenticated,
durably idempotent next-turn admission contract on which those features may
later build.
