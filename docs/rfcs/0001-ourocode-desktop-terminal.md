# RFC 0001: Ourocode Desktop — Terminal-First Session Fabric for Ouroboros MCP v2

- Status: Implementing — Ghostty/Metal source default, distribution gates open
- Date: 2026-08-09
- Target: macOS first
- Discussion: [GitHub issue #58](https://github.com/Ouro-labs/ourocode/issues/58)
- Supersedes: the desktop-product boundary in [#25](https://github.com/Ouro-labs/ourocode/issues/25); the existing TUI remains a compatibility client and protocol fixture source
- Completion evidence: [0001-completion-audit.md](0001-completion-audit.md)

## Summary

Ourocode becomes a real desktop terminal emulator with an embedded view of the session forest created by Ouroboros MCP v2. It is not a coding harness with a terminal-shaped panel.

The terminal must remain fully useful when Ouroboros is stopped. When Ouroboros is connected, every server-advertised parent and child session is discoverable in a virtualized session rail, selected sessions can expose their transcript or attached terminal, and authorized steering is sent through Ouroboros rather than injected into a pseudo-terminal. Ouroboros 0.51.1 exposes exact-attempt target data, but the current loopback catalog bridge is not mutation authority, so production steering remains fail-closed until the private authenticated broker path and durable binding acknowledgement are complete.

The first implementation is a thin AppKit and Metal shell over a Rust core. It does not link the existing BEAM TUI runtime into the desktop app. Existing Elixir code remains valuable as a legacy CLI, behavior reference, and source of captured protocol fixtures.

## Why a new runtime

The current repository is an Elixir terminal workbench. It already contains useful lifecycle normalization, journaling, recovery, and parent/child projection semantics, but it has no desktop window, PTY manager, VT emulator, glyph pipeline, or GPU renderer. A desktop wrapper around the current TUI would preserve its per-pane projections and BEAM footprint while adding another UI runtime, which conflicts with the memory goal.

The desktop app therefore shares contracts with the existing client, not its presentation runtime.

## Product boundary

### Ourocode owns

- local shell processes and PTYs;
- terminal emulation, rendering, input, scrollback, selection, search, tabs, and splits;
- a lightweight projection of the Ouroboros session forest;
- focus, pinning, unread state, and the mapping from a session to a visible surface;
- a local append-only audit of user-issued session actions;
- bounded local recovery metadata.

### Ouroboros owns

- agent execution and fanout;
- authoritative session identity, parentage, attempt identity, and lifecycle state;
- delivery and audit of session signals;
- cancellation and execution state;
- replayable execution events and projections.

### Explicit non-goals for the first release

- an Electron, Tauri, or webview desktop shell;
- replacing Ouroboros orchestration inside the client;
- rendering every child session as a live GPU terminal;
- treating an agent transcript as ANSI PTY output;
- cloud sync, accounts, collaborative editing, notebooks, or an AI-first composer;
- Windows or Linux UI before the macOS memory and correctness gates pass;
- a general graph database or client-created session mesh.

## Target architecture

```text
AppKit window and native controls
  |-- SessionRailViewController (virtualized forest)
  |-- SurfaceContainerView
  |     |-- TerminalMetalView        real local or attached PTY
  |     `-- TranscriptView           semantic agent stream
  `-- Command and audit surfaces
             |
       typed C ABI (no JSON FFI)
             |
Rust AppCore
  |-- one mio/kqueue reactor for all PTY and MCP descriptors
  |-- terminal registry and bounded scrollback
  |-- session forest projection and signal audit
  |-- one bounded journal writer
  `-- MCP v2 client: snapshot/query, linked progress, signal, cancel
             |
       Ouroboros MCP v2 server
```

The main AppKit thread owns native views. A single I/O reactor owns PTY and MCP file descriptors. A single bounded writer persists metadata and audit records. The design does not allocate an actor or OS thread per session.

The Metal device, render pipelines, font discovery state, and glyph atlas are shared for the whole application. Only visible terminal surfaces allocate GPU instance buffers. An offscreen session has no layer, swapchain, or vertex buffer.

### Current vertical slice (production candidate, not a release artifact)

```text
AppKit + Metal          one visible Ghostty render projection/input client
AppKit MCP v2 client    Ouroboros catalog/session compatibility projection
          |
    bounded JSON-lines over a mode-0600 Unix socket
          |
Rust ouro-broker        PTYs/process groups, canonical viewport, bounded deltas
```

The current slice proves that a UI restart need not kill the shell and that the
pinned Ghostty renderer can recover a versioned canonical visible viewport
without starting inside UTF-8 or a control sequence. The broker owns bounded
headless Ghostty state for every PTY; AppKit owns one disposable Metal
projection for the selected tab. SwiftTerm is now reachable only through the
explicitly labelled `OUROCODE_SWIFTTERM_COMPATIBILITY_BUILD=1` build and is not
an inferred fallback when Ghostty inputs or the Metal toolchain are missing.
Broker wire protocol v3 added a stable create nonce projected by `list` and
post-`waitpid` termination acknowledgement. Protocol v4 preserves those
lifecycle rules in a separate `broker-v4.sock` and adds manifest-bound 64 KiB
two-phase recovery, ordered PTY/resize state, bounded recovery pins/expiry, an
offscreen Swift import, and input authority only after `attached_ready`. This
lets a client reconcile a timed-out create without duplicating a PTY and keeps
the old renderer intact through corrupt, incomplete, or stale recovery. V2/v3
socket namespaces remain untouched; v3 is now a visibly labelled, explicit
compatibility choice rather than a silent downgrade.
The old Finder bootstrap assumed a shared endpoint at `127.0.0.1:8976`. That
address is no longer a product trust boundary: any same-user process that wins
the port can forge the MCP handshake, session forest, and exact steering target.
Server name and version checks do not close that listener-swap race. An explicit
loopback URL remains a developer/operator override, `--no-ouroboros` disables
the source, and a missing source never disables the terminal. Automatic release
connection requires a launchd-owned, mode-`0600` Unix-domain endpoint with peer
UID validation behind the user-scoped broker. Fixed-port HTTP remains a visibly
labelled development bridge only.
This is not yet a distributable Ghostty production artifact. Source packaging
now fails closed unless the exact renderer archive, Ghostty Metal surface, and
compiled Metal library are available, but this workstation has Command Line
Tools only and cannot run `metal`/`metallib`. The last development DMG therefore
does not prove the current source contract. Developer ID signing, notarization,
the full conformance suite, and close-to-baseline 32-session memory evidence
remain release gates.

## Terminal engine

The preferred engine is a pinned revision of Ghostty's MIT-licensed `libghostty`, behind an Ourocode-owned C/Rust adapter. `libghostty-vt` already provides the difficult VT, Unicode, reflow, selection, input encoding, and render-state machinery without dictating the app UI.

Before committing to it, a bounded spike must prove:

1. the embedding and render-state APIs needed by a Rust static library and AppKit Metal view;
2. IME, Kitty keyboard, resize/reflow, tmux, vim, ssh, and Unicode correctness;
3. acceptable API pinning and upgrade isolation while libghostty has no tagged library version;
4. measured incremental memory within the targets below.

If the spike fails, the fallback is a Rust terminal core using an established VT parser. Writing a new escape-sequence parser and grid from scratch is not an MVP.

The explicit SwiftTerm compatibility adapter has a known content-preservation risk matching [SwiftTerm #494](https://github.com/migueldeicaza/SwiftTerm/issues/494): narrow/widen reflow can duplicate or orphan rows. Disabling `SIGWINCH`, debouncing PTY resize, or changing the Metal buffering mode does not repair lost grid content. It is retained for labelled compatibility and fixture work only; release packaging must use the pinned Ghostty path and may not silently fall back to it.

Warp is a design reference, not a dependency for the core. Its current public
GitHub repository explicitly describes itself as issues-only and says the
client and server remain closed source; an AGPL repository metadata label does
not make absent product source reusable. Any separately published extension or
UI crate must be licensed and audited on its own. We study observable behavior
and open standards only: the useful product idea is semantic command boundaries
through OSC 133/633, not Warp's account, cloud, block-document, or AI-composer
surface.

Warp is ahead today on real terminal maturity: race-safe PTY lifecycle, parser fairness, Alacritty-derived recordings, chunked scrollback, nested panes, native Metal rendering, OSC block semantics, and an existing multi-agent hierarchy and message protocol. Ourocode must not claim that hierarchy or inter-agent messaging is novel.

The credible product wedge is different. Ourocode projects a provider-neutral, local Ouroboros execution forest; exact attempt guards and durable receipts make steering fail closed; semantic agent sessions do not allocate hidden PTYs or GPU surfaces; and one reactor plus global byte, atlas, visible-surface, and thread caps make aggregate resource use measurable. Warp currently uses a PTY reader thread and 256 KiB read buffer per local terminal, materializes child conversations as hidden terminal panes, and grows glyph-cache textures without an eviction policy until configuration reset. These are hypotheses for a controlled benchmark, not proof that Ourocode already uses less memory.

The license boundary is strict: only `crates/warpui` and `crates/warpui_core` are MIT, while the terminal, app, pane, agent, and multi-agent implementation is AGPL-3.0. Even the MIT crates currently participate in Warp's workspace dependency graph, so they are not assumed to be drop-in permissive libraries. Ourocode may study public behavior and independently implement standards, but it does not copy Warp terminal or agent code.

Kaku is also a behavior reference, not an engine candidate. The audited 2026-08-09
`main` revision (`c9d41c2`) and the nearby `V0.18.0` release line are a deeply customized
WezTerm fork, not a Ghostty embedder. Its pane splitting, tab navigator,
detached-window flow, unread state,
and updater staging lock are useful interaction and operations references.
Its strongest visual lesson is restraint: the terminal remains the dominant
surface, split boundaries are quiet, and advanced AI appears in context instead
of becoming permanent dashboard chrome. Ourocode adopts that hierarchy by
keeping MCP sources collapsed by default and presenting session state as a
thin, reversible projection. It does not copy Kaku's low-contrast inactive tab
labels; session titles, focus, unread state, and keyboard focus must remain
legible without relying on color alone.
Kaku also separates direct manipulation from terminal side effects while a
split divider is dragged: presentation geometry follows the pointer, while the
PTY resize is committed on release. Ourocode adopts that interaction contract
with immediate visual feedback, interruptible drag state, keyboard resizing,
and one coalesced final `SIGWINCH` instead of resizing the child on every pixel.
Kaku's `Cmd-Shift-T` keeps only a window-local stack of at most ten working
directories and spawns a new shell; it does not restore the closed PTY. Its
separate session restore recreates a split tree and bounded scrollback before it
also spawns new panes. Ourocode implements the useful navigation behaviors
independently on top of the pinned Ghostty ABI, preserves the live PTY in the
broker, and restores only the window, split, and focus projection in AppKit.
Likewise, Kaku's updater staging lock does not prove post-install health
rollback. Its audited apply path does run
[`codesign --verify --deep --strict` and `spctl --assess --type execute`](https://github.com/tw93/kaku/blob/c9d41c2fdb622dc97f466c604456d7a65459fd62/kaku/src/update.rs#L781-L803)
before replacement, which Ourocode should retain as a useful pre-install gate.
The helper then [deletes its backup after copying](https://github.com/tw93/kaku/blob/c9d41c2fdb622dc97f466c604456d7a65459fd62/scripts/update_helper.sh#L158-L173),
before it [attempts relaunch](https://github.com/tw93/kaku/blob/c9d41c2fdb622dc97f466c604456d7a65459fd62/scripts/update_helper.sh#L196-L223),
and a successful `open` is not an application health acknowledgement.
Ourocode therefore requires signature verification plus a retained backup,
explicit relaunch health confirmation, and atomic rollback as its stricter
release contract.

Kaku's smaller executable and 256 KiB per-pane reader buffer are useful
engineering signals. Its mux currently starts a PTY reader thread and a parser
thread per pane, so those buffers and stacks scale with panes; they are not a
memory baseline until equivalent process-tree measurements exist.
It creates a render state and glyph atlas per window; when the atlas fills it
first recreates the same size and, if that fills again, doubles the side length,
without a global cap or shrink policy. It has no published 1/8/32-pane
`phys_footprint`, lifetime-peak, or close-to-baseline gate. Its optional remote
bridge is likewise not reused: it accepts one bearer token in a path or query,
logs that token, and captures full line snapshots as often as every 16 ms.
Screen broadcasts are bounded by message count rather than bytes, while the AI
event stream is unbounded; neither path provides cursor-based resume or an
explicit resync boundary. Ourocode retains mutual device authentication,
Keychain identity, generation-bound input leases, cursor deltas, and byte
backpressure. Kaku's own
Simple/Deep AI selector is not an Ouroboros complexity router; routing decisions,
token evidence, escalation, and receipts remain provider-side MCP v2 data that
the terminal displays without intercepting ordinary PTY input.

Goose is the strongest open interaction reference for the requested
conversation-like terminal presentation, but not a terminal engine. The audited
AAIF repository is Apache-2.0 and separates its Rust agent/MCP core from an
Electron desktop UI whose `ProgressiveMessageList`, `UserMessage`,
`ToolCallWithResponse`, status indicator, and composer components make one turn
readable without exposing raw protocol JSON. Ourocode adopts the hierarchy, not
the runtime: an OSC 133 command turn gets a quiet prompt boundary, result body,
and explicit running/failed/completed state, while the underlying surface stays
a real `zsh -l -i` PTY with normal selection, alternate-screen applications,
and shell startup files. Tool invocations remain progressive disclosures inside
an Ouroboros session detail; they do not turn every shell command into an agent
card. This keeps Goose's human legibility while preserving Ghostty's terminal
familiarity and the one-render-surface memory model.

### Durable broker and mobile reconnect

Multiple desktop windows and a paired mobile client turn PTY lifetime into a service concern. The production owner is one launchd-managed, user-scoped broker, not an AppKit window and not one `uvx` process per tab. The broker owns PTY masters, child process groups, terminal state, bounded scrollback, Ouroboros MCP connectivity, session lifecycle, cursors, and audit receipts. Desktop windows are restartable thin clients over XPC or a Unix-domain socket.

Herdr is useful evidence for durable server ownership, reconnect, explicit input leases, and keeping the PTY alive while the UI disappears. Paseo is useful evidence for device pairing, mobile snapshots followed by ordered deltas, cursor-based resume, and falling back to a fresh snapshot when a slow consumer exceeds the retained delta window. These ideas are implemented independently: Herdr is Apache-2.0, while Paseo is AGPL-3.0-or-later and its source is not copied.

The broker never sends a PTY file descriptor or raw MCP capability to a mobile device. A paired device receives a bounded `TerminalSnapshot` and monotonic `TerminalDelta` stream and sends high-level commands guarded by a short-lived input lease. The handshake includes protocol version, broker-incarnation UUID, device identity, resume cursor, and advertised capabilities. Every command carries an idempotency key and session generation; stale generation or lease fails closed.

Local discovery and pairing use an explicit one-time code or QR payload. Long-lived device credentials are stored in Keychain, transport is encrypted and mutually authenticated, and revocation is local and immediate. Remote access is disabled by default. Plain streamable HTTP remains a loopback-only development bridge and is never the mobile transport.

Backpressure is global and bounded. Deltas are coalesced by terminal damage region, each client has a byte-limited egress queue, and a client that falls behind receives `resync_required` rather than causing broker memory growth. Only one device holds the input lease for a terminal by default; read-only observers do not affect focus or resize authority. Desktop and mobile tabs are views of stable broker sessions, so closing a view does not implicitly kill a durable PTY, while an explicit terminate command targets the broker-owned foreground process group.

The desktop lifecycle contract exposes those as separate commands.
`Close View` performs `detach(exact lease)`, removes the local projection, and
retains the stable terminal ID. `Reopen Closed View` verifies that ID through an
authoritative broker list and reattaches it. It never approximates restore by
launching a new shell in the previous CWD. `Terminate Session…` detaches the
exact lease, performs a confirmed `terminate(stable terminal ID)`, and removes
the projection. Closing needs no destructive confirmation; termination always does
and explains that the foreground process and shell cannot be recovered. A close
requested during create waits for nonce reconciliation, while a close requested
during recovery cancels the prepare or detaches a late successful commit. An
ambiguous commit failure forces connection recovery before either local removal
or termination, preventing a hidden attachment or unproved destructive target.

The 0.51.1 compatibility bridge currently has to read `ouroboros://sessions`,
which measured about 2.29 MiB on the development machine because it reconstructs
persisted sessions and includes runtime and tool detail. A 2026-08-10 live run
showed the isolated MCP Python service at roughly 290--476 MiB physical footprint
while these snapshots were being rebuilt, with an observed 828 MiB lifetime
peak. Sampling caught SQLAlchemy row materialization and nested JSON decoding;
the old client compounded that cost by polling every 15 seconds and resolving
targets for every running group. This is not an acceptable background path.

The compatibility client therefore observes sessions only while the Sessions
navigator is visible, loads MCP collections on expansion, and resolves exact
signal targets only for the group the user opens. Closing the navigator pauses
polling without affecting terminal PTYs. This bounds client demand but does not
make the upstream resource efficient. The production broker still requires a
bounded session-list projection containing only identity, topology, lifecycle,
short activity, routing receipt references, and monotonic cursors; transcript,
tool-catalog, and runtime-detail payloads are fetched on demand.

The installed base `ouroboros` 0.51.1 console script on the audit machine did
not contain the optional MCP SDK and correctly refused `mcp serve`. Its official
diagnostic recommends an exact-version isolated `ouroboros-ai[mcp]` profile.
That profile may be used by an explicit transitional development service, but
never spawned once per window and never treated as the identity of the installed
base environment. Release setup and updates must be owned by Ouroboros and bind
one verified service descriptor to the broker.

The 2026-08-09 audit of Ouroboros remote `main` at `bef43c1af` confirms that
this projection still does not exist. `ouroboros://sessions` reconstructs all
session starts and then performs per-session reconstruction and activity
queries without limit, pagination, cursor, delta, or response-byte bounds.
The open dashboard projection work in
[Q00/ouroboros#1922](https://github.com/Q00/ouroboros/pull/1922) is useful
transactional/gap-fence evidence, but it is not merged, not an MCP contract,
and currently exposes only a bounded recent dashboard picker. Ourocode's
production dependency remains a `session_projection_v1` state table updated
in the event transaction plus a cursor-bounded MCP tool returning epoch,
watermark, reset, upserts, and removals.

## Core data model

```rust
struct AppCore {
    terminals: SlotMap<TerminalId, TerminalSession>,
    sessions: HashMap<SessionId, SessionRow>,
    children: HashMap<SessionId, SmallVec<[SessionId; 4]>>,
    roots: Vec<SessionId>,
    selected: Option<SessionId>,
}

struct TerminalSession {
    pty: PtyHandle,
    terminal: TerminalState,
    scrollback: ByteBoundedScrollback,
    cwd: PathBuf,
    title: String,
}

struct SessionRow {
    id: SessionId,
    parent_id: Option<SessionId>,
    attempt_id: Option<AttemptId>,
    status: SessionStatus,
    label: String,
    last_seq: u64,
    unread: u32,
    surface: SurfaceKind,
    capabilities: SessionCapabilities,
    routing_decision_id: Option<RoutingDecisionId>,
}

enum SurfaceKind {
    Pty(TerminalId),
    Transcript(StreamId),
    None,
}
```

Ouroboros fanout is projected as a forest because every child has one authoritative parent. Cross-session messages are append-only `MessageRecord` values, not extra tree edges and not payload copies stored on every session row.

## MCP v2 contract

The locally installed Ouroboros 0.51.1 server exposes the primitives needed for the first integration:

- `ouroboros_job_wait` with `stream=linked` for job, execution, lineage, and subagent progress;
- `ouroboros_query_projection` and `ouroboros_query_events` for read-only recovery;
- `ouroboros_session_signal_targets` to resolve an exact active attempt;
- `ouroboros_session_signal` for audited, guarded delivery;
- `ouroboros_cancel_job` and `ouroboros_cancel_execution` for cancellation;
- resources including `ouroboros://sessions/current` and `ouroboros://events`.

`ouroboros_session_signal` is not authenticated agent-to-agent RPC. In 0.51.1 it carries user, main-session, conductor, or worker intent to one exact active AC runtime attempt as a resumed follow-up turn. The caller supplies `source`; there is no authenticated `source_session_id`, reply address, causal chain, hop count, or loop policy. `inform` and `after_turn` are the broadly implemented delivery modes; `redirect` may fall back to `after_turn`, and `replace` is generally unsupported. A queued result proves durable ownership only, not application. The UI must follow applied, completed, rejected, or delivery-uncertain events and must not retry automatically after an uncertain acknowledgement.

A shared-broker smoke on 0.50.8 exposed a remaining authority race: `ouroboros_session_signal_targets` returned an exact live attempt, but both `after_turn` and `inform` requests reached `accepted` and `queued` before ending as `target_lost_before_delivery`. This is a safe failure, not successful steering. Production needs either an expiring target lease minted by discovery or one atomic resolve-and-send operation tied to the execution generation. The client continues to fail closed and refresh targets after rejection; it never retries the message automatically.

The current truthful UI is therefore **Steer exact live attempt**. A future `SessionMessage` contract is required before Ourocode exposes **Send from session A to session B**. That contract needs authenticated sender and recipient scopes, exact attempts, causal correlation, hop/loop policy, delivery and reply receipts, idempotency conflict behavior, expiry, and authorization.

The desktop client negotiates capabilities and records captured fixtures before implementing production actions. It must not guess a child identifier by recursively scanning arbitrary JSON, and it must not claim a queued signal was applied.

Ouroboros 0.51.1 uses the public MCP SDK v2
`MCPServer` boundary and advertises 35 tools plus the session/event resources in
the captured startup smoke. The launcher must use `uvx --isolated --from
'ouroboros-ai[mcp]==0.51.1'` only for the explicit transitional development
profile: without `--isolated`, uv may reuse the installed
standalone `[claude]` tool environment and its MCP 1.x dependency, causing the
v2 server to register its catalog and then fail before accepting a connection.
Ourocode keeps this process boundary explicit rather than combining mutually
incompatible extras in one Python environment. The release path does not search
Finder `PATH`, download packages silently, or accept an unauthenticated fixed
port as service authority.

Normalized client events have a monotonic cursor. Duplicate events are ignored. A gap or stale attempt fails closed and triggers projection recovery. Authoritative lifecycle events are journaled before projection; repaint hints may be coalesced or dropped.

A session signal records at least source, exact target scope and attempt, expected execution, idempotency key, delivery mode, message digest, reason, contract effect, created time, and acknowledgement state. Client-side hop limits may protect UI workflows, but delivery authority and loop policy remain server-side.

### Frugal AI routing is an Ouroboros contract

The standalone consumer boundary and upstream linkage are tracked in
[RFC 0003](0003-routing-consumer-contract.md).

Ourocode does not become a model router. Ouroboros owns route selection because it owns the execution profile, available runtimes, tool capabilities, budget, retry history, and outcome evidence. The terminal requests policy or an override, then renders the authoritative decision and its audit trail.

Ouroboros 0.51.1 projects useful inputs such as `suggested_model_tier`, suggested tools, verifier capability and focus, maximum branching, tool-catalog fingerprint, runtime backend, estimated tokens, and estimated cost. It also records `execution.ac.model_routed`, `execution.ac.effort_routed`, per-attempt token attribution, and deterministic frugality-proof inputs. These are meaningful server-owned routing observations, but not yet the complete effect-bound routing receipt required below. A tier label alone must never be presented as proof of which provider and model actually executed an attempt.

Complexity estimation also belongs to Ouroboros. Before dispatch, it classifies the bounded task shape, required capabilities, external-effect risk, expected context and tool fanout, then combines those features with aggregated historical outcomes from its memory layer: input/output/cache tokens, tool-call count, latency, retry and escalation rate, verifier pass rate, and nullable measured cost. Raw prompts, transcripts, and chain-of-thought are not routing-memory features. A routine repository operation may therefore begin on a Haiku-class candidate when policy allows it, while a failed verifier, capability miss, uncertainty threshold, or token overrun creates an explicit escalation decision.

The authoritative assessment is persisted before the route is bound:

```rust
struct ComplexityAssessmentRecord {
    schema_version: u16,
    assessment_id: ComplexityAssessmentId,
    execution_id: ExecutionId,
    session_scope_id: SessionScopeId,
    task_class: TaskClass,
    score: BoundedScore,
    confidence: BoundedScore,
    feature_schema_version: String,
    history_window_id: Option<RoutingMemoryWindowId>,
    reason_codes: SmallVec<[ComplexityReason; 8]>,
    required_capabilities: SmallVec<[CapabilityId; 8]>,
    external_effect_risk: ExternalEffectRisk,
    created_at: Timestamp,
}
```

The scoring and learning implementation may live in a closed Ouroboros policy module; the protocol, bounded inputs, decision receipt, and audit semantics remain stable. Ourocode does not reproduce the classifier. For agent launches initiated through Ourocode, an optional `routing_required` workspace policy fails closed when Ouroboros does not return a generation-bound `ComplexityAssessmentRecord` and `RoutingDecisionRecord`. This enforcement cannot and does not intercept arbitrary commands typed into the ordinary PTY. Model selection never weakens permission, confirmation, credential, or external-side-effect gates.

Candidate eligibility is capability-gated before cost or complexity ranking. In the shared-broker smoke, failed Codex attempts escalated to a Claude alternate harness even though the isolated MCP profile did not contain `claude-agent-sdk`; all three ACs then exhausted with `alternate_harness_exhausted`. A route whose executable, SDK, credentials, protocol version, or required tools are unavailable must be recorded as rejected and must never be selected. This preflight result belongs in the policy fingerprint and decision receipt so a cheap route cannot become an expensive guaranteed failure.

The existing `execution.ac.model_routed` event is best-effort telemetry after selection, not an effect-boundary decision record. Route-policy candidates contain model, harness, effort, capabilities, stable rejection reasons, and configuration-relative `cost_units`; those units are neither currency nor actual spend. Later route observations can include verifier outcome, failure, escalation, and retry. The missing authoritative event must be persisted before provider dispatch and include a decision ID, policy fingerprint, bounded eligible/rejected set, override provenance, supersession, and nullable estimates.

The proposed bounded record is:

```rust
struct RoutingDecisionRecord {
    schema_version: u16,
    decision_id: RoutingDecisionId,
    execution_id: ExecutionId,
    session_scope_id: SessionScopeId,
    attempt_id: Option<AttemptId>,
    complexity_assessment_id: ComplexityAssessmentId,
    policy_version: String,
    requested: RoutingPolicy,
    selected: SelectedRoute,
    considered: SmallVec<[RouteCandidateSummary; 4]>,
    reason_codes: SmallVec<[RoutingReason; 4]>,
    estimates: RoutingEstimates,
    evidence: RoutingEvidence,
    override_source: Option<RoutingOverrideSource>,
    supersedes: Option<RoutingDecisionId>,
    created_at: Timestamp,
}

struct RoutingPolicy {
    effort: Effort, // auto, low, medium, high, ultra
    max_cost_usd: Option<Decimal>,
    latency_slo_ms: Option<u64>,
    allowed_providers: SmallVec<[ProviderId; 4]>,
    privacy_class: Option<PrivacyClass>,
}
```

Candidate details are bounded summaries, not provider chain-of-thought. Cost, latency, token, and quality estimates remain nullable unless Ouroboros can attach their source and measurement window. The `selected` route records the provider, model, service tier, runtime backend, and capability set actually bound. `reason_codes` explain machine-readable causes such as capability requirement, budget cap, retry escalation, availability fallback, or explicit user override.

Routing events are append-only and generation guarded:

- `routing.snapshot` replaces the full source-keyed routing state after connect or recovery;
- `routing.decided` binds one decision to an exact execution, scope, and attempt;
- `routing.override_requested`, `routing.override_accepted`, and `routing.override_rejected` expose the complete acknowledgement path;
- the same idempotency key and body re-acknowledge, while the same key with a different body fails closed;
- every stream carries generation and monotonic sequence; a gap or generation change triggers a snapshot rather than client inference;
- completed, superseded, and rejected decisions retain bounded receipts or tombstones so reconnect cannot resurrect stale authority.

Until Ouroboros publishes these events and a guarded override tool, Ourocode exposes current profile and tier data as read-only `suggested` metadata. It does not silently switch a model from the client.

### Fanout liveness and fairness

Each producer publishes a complete `ChannelLivenessSnapshot { source, generation, active_count, channels[] }`, not increment/decrement deltas. Each channel includes its stable scope, exact attempt, short description, state, and start time. This makes reconnect and extension reload deterministic and lets the rail show paused work and oldest-active elapsed time without scanning transcript files.

Within one session, event order is FIFO. There is deliberately no global ordering claim across sessions. The MCP client drains complete records fairly across active sessions so one noisy agent cannot starve the rest of the fanout. A durable session ID is never used as ephemeral action authority; signal and cancel operations still require the exact live attempt and execution generation.

### Reference study decisions

- **Senpi:** adopt explicit open/list/close session semantics, per-session FIFO, full liveness snapshots, and typed model/service-tier fields. Reject its duplicated xterm-plus-decoded-buffer memory shape, directory-wide transcript scanning, process-local liveness bus, and unaudited client-side tier toggle.
- **Gajae-Code:** adopt separate durable correlation and ephemeral action authority, explicit resolved/rejected receipts, idempotency conflict rules, revision-bound cursors, generation/sequence resync, and authenticated process incarnation. Reject one WebSocket per session, PID-only liveness, URL bearer tokens, and its Node/Bun/tmux runtime as product architecture.
- **Amp:** use its compact effort dial as interaction evidence only. Provider/model mapping is allowed to vary with workspace, availability, and policy, which reinforces that the dial is a request and the server decision is authoritative. Amp is proprietary service behavior, not a code dependency.

Senpi and Gajae-Code are MIT-licensed but carry upstream NOTICE lineage. These protocol ideas are independently expressed here; no implementation is copied. Amp code is not reused.

## Memory and latency invariants

All gates are measured in an optimized build with the same font, window size, shell workload, and scrollback policy as the Ghostty comparison. macOS `phys_footprint`, private dirty memory, heap, and relevant VM regions are recorded; raw RSS alone is not a release claim.

- provisional app-only idle `phys_footprint`: at most 50 MiB, excluding shell and Ouroboros child processes;
- zero-scrollback 120x40 idle session: at most 0.75 MiB incremental retained memory;
- 32 sessions with 10,000 short lines each: at most 150 MiB app footprint;
- offscreen session GPU allocations: zero;
- visible terminal surfaces with GPU buffers: at most four in the first release;
- one global glyph atlas capped at 32 MiB;
- scrollback capped by bytes: 8 MiB per session and 128 MiB globally by default, with segmented spill and LRU eviction;
- warm launch to usable shell prompt p95 under 250 ms;
- idle CPU under 0.5%;
- key-to-frame p99 under 8 ms while eight PTYs produce output;
- fixed runtime thread count independent of session count, apart from shell child processes and explicitly documented system threads;
- bounded ingress and UI queues with visible overflow counters; no unbounded channel, vector, journal batch, or string clone path.

The provisional absolute targets may be corrected after Gate 0 measurement. The incremental per-session and offscreen-GPU invariants are merge blockers.

### Live 13-session checkpoint (2026-08-11)

A PID-pinned 11-sample run over ten seconds measured the functional Next-8
Ghostty development app after it reattached to 13 broker-owned login zsh PTYs.
The app median and maximum `phys_footprint` were both 77,661,216 bytes
(74.06 MiB), with mean idle CPU of 0.000060%. The broker measured 6.48 MiB;
the 13 separately measured shells totalled 97.02 MiB; the full observed
app+broker+shell sum was 177.57 MiB. Shell memory is reported separately and is
not attributed to the app.

This is conservative debug-build evidence, not the optimized release gate.
The current host has Command Line Tools but not full Xcode's `metal` and
`metallib`, and release builds correctly forbid runtime shader-source
compilation. The checkpoint therefore proves low idle CPU, bounded live
13-session app memory, and honest process accounting; it does not claim the
50 MiB optimized app-only target or the 32-session large-scrollback gate.
Raw records and their PID/hash manifest are in
`apps/macos/OurocodeDesktop/qa-evidence/perf-live-next8-13-tabs-20260811.*`.

## Workspace layout

```text
Cargo.toml
crates/
  ouro-terminal-core/
  ouro-pty/
  ouro-session/
  ouro-mcp-v2/
  ouro-store/
  ouro-ffi/
apps/macos/Ourocode/
bench/
  rss_fanout/
  pty_flood/
  scrollback/
fixtures/mcp-v2/
```

The existing `lib/ourocode/terminal`, `lib/ourocode/dashboard`, and BEAM runtime are not linked into the new application. Reusable behavior is copied only as language-neutral fixtures and documented invariants from lifecycle, relationship recovery, replay, cancel, and steering tests.

## First vertical slice

1. **Gate 0 — truth before code:** measure Ghostty with controlled workloads; capture Ouroboros 0.50.8 tool/resource schemas and linked-stream fixtures; prove or reject the pinned libghostty adapter.
2. **Real terminal:** launch one AppKit window containing one real `/bin/zsh` PTY rendered through Metal. It must run tmux, vim, ssh, Unicode input, copy/paste, scroll, and resize correctly.
3. **Session fabric:** connect to MCP v2, recover a session snapshot/projection, follow linked progress, and show every root/child as grouped native tabs and virtualized rows.
4. **Routing visibility:** display the server-issued effort/profile, actual bound route, reason codes, estimates, and override receipt without implementing client-side routing.
5. **Honest surfaces:** local shells and explicitly attached raw streams use `TerminalMetalView`; agent output uses `TranscriptView` unless Ouroboros advertises a raw PTY attachment capability.
6. **Communication:** entering a child tab resolves its exact live attempt; steering calls `ouroboros_session_signal_targets` followed by one guarded `ouroboros_session_signal`, then displays queued/delivered/rejected audit state. Cancel affects only the selected target.
7. **Recovery:** relaunch and reconstruct topology, selected group/tab, cursor, routing receipt, and audit state without duplicating a signal.

Tabs, splits, themes, searchable semantic command blocks, and other platforms follow only after this slice passes correctness and memory gates.

## Deterministic QA mode

The release build exposes an explicit, visibly labelled QA launch mode such as `--demo fanout-8`. It feeds captured MCP fixtures through the real projection and rendering paths; it is not a separate mock dashboard. Luna's Computer Use suite verifies cold launch, real shell input, incremental fanout, focus preservation, targeted signalling, cancel/error states, replay, 32-session virtualization, memory return after close, accessibility labels, and Retina layouts.

## Initial acceptance criteria

- A runnable `.app` and stable bundle identifier exist.
- With Ouroboros unavailable, the app is still a correct local terminal.
- One parent and at least eight children appear incrementally without raw MCP JSON in the UI.
- Keyboard navigation switches sessions without losing terminal scrollback or input focus.
- Signal and cancellation actions target exact server-authoritative attempts and expose acknowledgement state.
- Relaunch restores the latest topology without duplicate sessions or duplicate signals.
- A 32-session fixture allocates render resources only for visible panes and remains responsive.
- Automated core tests, captured protocol contract tests, terminal conformance smoke tests, and Luna Computer Use smoke tests pass.

## Open questions that block production integration

1. What stable MCP v2 snapshot/resume cursor guarantees does Ouroboros commit to beyond current query and wait tools?
2. Does any child session expose raw PTY bytes or an attachable PTY descriptor, or are child surfaces semantic transcripts only?
3. What is the server-side acknowledgement and loop-prevention contract for inter-session signals?
4. Which libghostty commit and API surface can be pinned with an acceptable upgrade policy?
5. What license will Ourocode use before distributing the new desktop binary and third-party notices?
6. Which Ouroboros event and guarded tool will carry authoritative `RoutingDecisionRecord` and routing overrides, rather than the current `suggested_model_tier` hint alone?

## Decision

Proceed with Gate 0 and the one-real-PTY vertical slice. Reject a first PR that contains only a polished session mockup: the first runnable desktop artifact must be a terminal.
