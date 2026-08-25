# RFC 0006: Session-to-terminal identity bridge

Status: control-session entry and optional PTY attach are separate; exact-attempt surface projection and broker declaration seams exist locally, while the provider PTY producer remains incomplete

Upstream tracking: [Q00/ouroboros#2152](https://github.com/Q00/ouroboros/issues/2152)

## Decision

An Ouroboros session is not inherently a terminal. The shipped Codex and
Claude fanout runtimes are headless worker sessions driven through subprocess
pipes, MCP, or an SDK. Ourocode therefore models session entry as a sum type:

```text
session_entry = mcp_control(execution, scope, attempt, capabilities)
              | broker_pty(terminal_id, broker_generation)
```

Every validated session may open a read-only control/activity surface. A row
without a PTY must never be presented as a broken terminal or a terminal picker
that can never succeed. The richer `broker_pty` branch exists only when the
process was actually launched under the Ourocode broker and the server can
truthfully advertise the binding. Direct steering additionally requires an
authenticated mutation channel; read-only MCP discovery does not grant it.

Ourocode joins an Ouroboros fanout leaf to a broker PTY only with a
server-owned exact identity tuple:

```text
(source_id, session_id, execution_id, session_scope_id, session_attempt_id)
```

Names, display paths, logical `ac_id` values, process IDs, tab positions and
terminal titles are presentation data. They are never join keys. Retries can
reuse a logical AC while creating a different attempt, and users can rename a
terminal tab at any time.

An optional terminal surface is carried beside the exact attempt:

```json
{
  "surface": {
    "kind": "pty",
    "terminal_id": "term-7",
    "broker_generation": 42
  }
}
```

`terminal_id` is the durable broker PTY identifier, not the process-local
Swift tab UUID. `broker_generation` is mandatory so a terminal identifier from
an earlier broker incarnation cannot activate a current surface. Missing,
malformed, unsupported, or generation-less surface metadata stays explicitly
unbound. It never falls back to title or path matching.

Surface metadata is read-only correlation. It is not steering authority and
does not grant a terminal input lease.

## Proven upstream gap in Ouroboros 0.51.6

The shipped `ouroboros_session_signal_targets` schema in Ouroboros 0.51.6
returns exact execution, scope, attempt, runtime, logical hierarchy and
steering capabilities. It does **not** return `surface`, `terminal_id`, or
`broker_generation`. Therefore no production Ourocode build can currently
enter a fanout attempt as a PTY from this tool alone. The Swift decoder and
broker attach path are ready for the extension above, but an upstream-owned
binding producer is still required. The UI must not imply otherwise.

The current development branches now cover both sides of the metadata seam
without claiming that missing producer:

- Ouroboros can decode a bounded `SessionSignalTargetSurface` from an exact
  lifecycle event and expose it through
  `ouroboros_session_signal_targets.meta.targets[].surface`. Invalid surfaces
  are omitted while the logical target remains available.
- Ourocode broker v4 `Create` accepts an optional exact five-part
  `session_binding` declaration and returns it atomically with `terminal.id`;
  `List` preserves the same correlation and duplicate live bindings fail.

The broker declaration is discovery-only and client-supplied. It is not proof
that an Ouroboros service owns the attempt and grants no attach, input, or
steering authority. Production activation still requires the authenticated
principal binding, current broker generation, and normal input lease. No stock
0.51.6 worker emits this metadata.

This is not only a missing JSON field. `codex_cli_runtime` launches `codex
exec` with asyncio pipes, `claude_worker_runtime` launches `claude -p` with
pipes, and the Claude SDK runtime has no broker PTY either. Inventing a surface
from the parent environment, cwd, provider session ID, label, PID, or AC ID
would bind sibling attempts to the wrong terminal. A real raw-terminal mode
requires the Ourocode broker to allocate the PTY before the attempt is spawned
and Ouroboros to persist the resulting exact binding.

Ouroboros 0.51.6's compact index is reconstructed from
`orchestrator.session.started` and `execution.terminal`. That projection has
only parent session/execution metadata, so `OuroborosMCPClient` correctly
creates every group with `tabs: []`.

The current child-population path calls `ouroboros_session_signal_targets`
after a group is selected. That tool is an ephemeral action-authority query,
not a durable fanout projection:

- it returns active attempts only;
- completed fanout children are absent;
- terminal executions intentionally return no targets;
- the default auto-installed loopback endpoint is catalog trust only, so target
  results are admitted solely as bounded read-only identity/surface metadata;
  advertised delivery modes are stripped on that trust class.

Read-only discovery does not grant mutation authority and still does not recover
completed children. A surfaced PTY is cross-checked against the current broker
generation and `broker.list`; steering remains on the separate authenticated
gateway contract. The target tool remains a live metadata overlay.

`ouroboros_query_projection` supplies useful read-only logical steps, but its
0.51.6 response lacks scope/attempt identity. A logical `ac_id` cannot safely
be merged with a runtime target because retries can reuse it. Ouroboros needs a
bounded structured fanout projection containing at least session, execution,
scope, attempt, node/display hierarchy and lifecycle state. An optional PTY
surface may be attached only by the server/broker-owned binding path.

## Boundaries

This contract belongs to the optional Ouroboros Sessions extension. It does
not alter standard MCP source registration or the standard Tools, Resources
and Prompts catalog. A general MCP source without the extension remains fully
browsable and has no session-to-PTY assumptions.

Three identities remain separate:

1. `LocalTerminalTab.id` is a process-local UI identity.
2. `BrokerTerminalSummary.id` is the stable broker `terminal_id`.
3. `OuroborosSessionAttemptIdentityV1` is the exact semantic fanout attempt.

The bridge maps (3) to (2). It never persists or transmits (1).

## Activation and steering gates

Outline selection is inspection-only. A pointer primary click or an unmodified
Return/Enter on a projected live fanout row may request a terminal switch only
after:

1. the exact tuple decodes and matches the parent projection;
2. the surface is a supported `pty` with a nonzero broker generation;
3. the current broker hello generation equals the advertised generation;
4. `broker.list` contains the exact terminal ID;
5. normal recovery/attach and first-present gates complete.

Those checks grant only the normal terminal-view attachment. They do not mint
session messaging authority.

Space opens session detail without attaching a terminal. A live group with one
verified surface opens that terminal directly; a group with multiple verified
surfaces reveals its attempt rows. A stock headless Ouroboros worker has no
`terminal_id`; its primary action opens the session detail/control surface and
explicitly says that no terminal is attached. Completed groups open read-only
history. Expanding a group may refresh target metadata, but the row's primary
action never promises terminal discovery from an unbound session. Arrow-key or
VoiceOver selection remains inspection-only.

Target discovery completion is correlated by execution and request generation.
Empty, malformed, failed, cancelled, or stale outcomes cannot replay a terminal
activation; generic session-index refreshes never consume terminal-entry intent.

Authenticated A-to-B steering remains a separate RFC 0005 flow. The Rust
broker already models a principal containing session/execution/scope/attempt,
and its internal authority registry can associate an optional terminal ID.
Production still needs installer-owned workspace authority, reciprocal
Ouroboros service verification, durable principal-binding acknowledgement and
desktop lifecycle wiring. Until all gates succeed, Swift exposes read-only
state and `SessionMessageCapabilityStateV1.unavailable`.

## Current implementation

`OuroborosSessionTerminalIdentityDecoderV1` implements the fail-closed tuple
and optional surface decoder. `OuroborosMCPClient` applies it only to lazy live
target discovery and preserves the resulting identity/surface on its tab
descriptor. A mismatched execution or session is rejected before becoming a
leaf. A missing or malformed surface leaves the target usable for read-only
inspection but unbound from every PTY.

The rail now exports only exact bindings to the terminal host and may activate
a selected leaf when the current broker generation and exact `terminal_id` are
both present in broker-owned state. An absent local view is adopted only after
an exact `broker.list` match, then enters the normal recovery/first-present
gates. This is a terminal view attachment, not session-message authority. The
implementation does not claim end-to-end PTY entry against stock Ouroboros
0.51.6, because that server emits no PTY surface binding. It also does not
claim to list completed fanout children until Ouroboros exposes their exact
attempt identities; compact groups still begin with `tabs: []`, and the lazy
overlay contains active targets only.

For stock headless sessions, primary click opens the session activity/control
surface instead of arming a misleading terminal chooser. Verified PTY rows
retain the separate `Terminal` action. Group rows retain the bounded
session-level read-only snapshot. Fanout leaf activation now carries the full
five-part identity and requests an exact attempt snapshot with
`execution_id`, `session_scope_id`, and `session_attempt_id`; the response must
echo all three before any event is shown.
Stock 0.51.6 does not implement that filter/echo contract, so a leaf fails
closed instead of displaying the parent session under Agent 1–4. Its
session/execution-only run projection is likewise group-only.

A future chat-like transcript still needs a server-issued monotonic `next_cursor`
paired with a service epoch, filtered by the exact attempt tuple. Ourocode does
not derive a fake cursor from identity or accept an un-echoed session-wide
fallback.

The desktop compatibility index treats a missing `execution.terminal` event as
`checking`, not as proof of liveness. Ourocode performs at most twelve recent,
two-at-a-time `ouroboros_session_status` checks and promotes a row to `Live`
only after the returned `(session_id, execution_id, status)` tuple agrees. A
terminal, target, or steering composer is revoked when that authoritative
status becomes terminal. The MCP catalog cross-link opens the sole live
session directly and otherwise lands on the session browser; headless rows use
`Open session` and the workspace keeps activity and verified next-turn
steering together.

The RFC 0005 broker messaging implementation is scaffolding in the current
production build: the Ghostty broker does not advertise the gateway and the
upstream Ouroboros service does not implement its bridge protocol. A smaller
MVP may use Ouroboros HTTP bearer authentication for an app-managed local MCP
service and call `ouroboros_session_signal` with exact attempt identity. That
path must remain disabled for unauthenticated or user-supplied endpoints and
must not treat bearer possession as a PTY input lease.

The remaining producer is intentionally provider-specific. Existing `codex
exec --json`, `claude -p --output-format json`, OpenCode, and SDK transports are
one-shot machine protocols over pipes. Moving them under a PTY would merge
stdout/stderr, change TTY detection, and still would not make subsequent bytes
into a provider turn. Ourocode therefore distinguishes:

1. `activity`: headless history plus exact-attempt Synapse steering;
2. `operator_shell`: a separate zsh in the same working directory, never
   represented as the agent process;
3. `provider_pty`: a genuinely duplex interactive provider runtime, the only
   surface eligible for terminal attach.

The first provider implementation must allocate its PTY through the broker
before runtime registration, persist the returned surface in the exact
lifecycle event, and revoke the surface in the same owner/finally boundary that
unregisters the Synapse target. Until then, entering a stock session means
opening its Activity workspace, not attaching to its worker process.

## Multiplexer interaction state (2026-08-17)

The desktop multiplexer no longer exposes the ambiguous card action `Focus`.
Its primary action is derived from the typed destination:

- a live exact attempt with a verified broker PTY binding exposes
  `Enter Terminal` and routes through the existing exact
  `activateSessionLeaf` gate;
- a live headless attempt with authenticated after-turn authority exposes
  `Message Agent`, which focuses only that card's isolated draft; and
- a completed, stale, untrusted, or otherwise unavailable attempt exposes no
  primary action.

Terminal entry and MCP steering are independent capabilities. A verified PTY
can remain enterable while MCP messaging is unavailable, and a headless worker
can remain steerable without creating a renderer or pretending to own a PTY.
Only the explicit `Queue` control submits a draft. Card focus changes never
submit.

An exact PTY card activation captures the group, child, attempt identity and
request generation. The terminal host revalidates the current binding and
broker generation before selecting or adopting the PTY. A successful switch is
accepted only when the host projects the same exact attempt back as the focused
session pane; a failed switch is rendered only if the original group workspace
is still current. This keeps delayed callbacks from dismissing or annotating a
replacement session.

The UI seam is implemented and fixture-tested, but the upstream producer gap
above remains real. Acting QA against the isolated `fanout-8` projection proves
headless `Message Agent`, draft isolation, explicit Queue, and A-only receipt
routing. It does not prove real delivery or `Enter Terminal`: stock 0.51.6
fanout cards are headless and advertise no PTY surface. The evidence is kept in
`.qa-evidence/luna-exact-terminal-entry-335731ad-20260817/REPORT.md`.

## Exact producer implementation boundary

The first eligible provider runtime must create one PTY per exact attempt at
Ouroboros's provider-entry boundary, immediately before
`parallel_executor.py:_stream_provider_call` dispatches the leaf. The exact
identity comes from `ACRuntimeIdentity.session_scope_id/attempt_id`; it must not
be reconstructed from a provider session ID, PID, cwd, label, or environment.

`Create(session_binding=...)` remains a declaration, not proof. Before
publishing `execution.session.started.surface`, Ouroboros must obtain a
broker-authenticated identification receipt for the canonical terminal ID,
broker generation, create nonce, and full session binding. A proposed closed
wire operation is:

```text
IdentifySurface(terminal_id, broker_generation, create_nonce, session_binding)
  -> SurfaceIdentified(terminal_id, broker_generation, session_binding, producer_receipt)
```

The broker admits this only when the stored create signature matches, exec
startup succeeded, the child owns its kernel session, and the PTY foreground
process group belongs to that session. The opaque producer receipt is scoped to
the creating connection and is never exposed through `List`. Environment
variables are hints and cannot satisfy this check.

Only after this receipt may Ouroboros attach `surface` to the exact live
Synapse target and lifecycle event. The same owner must perform
`Terminate -> exited observation -> Forget` in its `finally` block before
unregistering the target and runtime handle. `Terminate` alone leaves a
tombstone and must not release the binding. Retry with the same attempt and
create nonce reconciles the existing lease; it never creates a sibling PTY.

Existing Codex CLI, Claude pipe/SDK, and external worker adapters remain
headless. They become PTY-backed only through an explicit duplex provider
transport that reads and writes broker PTY state events. Blanket wrapping or
copying the parent terminal would violate the one-attempt/one-PTY invariant.
