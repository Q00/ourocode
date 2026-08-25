# RFC 0003: Ouroboros routing receipt consumed by Ourocode

- Status: Proposed upstream contract; not fully implemented by Ouroboros 0.51.0
- Date: 2026-08-09
- Parent: [RFC 0001](0001-ourocode-desktop-terminal.md)
- Upstream frugality epic: [Q00/ouroboros#1465](https://github.com/Q00/ouroboros/issues/1465)

Ourocode must not classify prompts or reproduce Ouroboros policy. The desktop
client consumes an Ouroboros-owned, generation-bound decision receipt and
remains ignorant of the closed or evolving policy implementation.

The minimum observable contract contains:

- an investment/complexity assessment with difficulty, stakes, confidence,
  provenance, required capabilities, and stable reason codes;
- capability preflight before selection, including runtime executable or SDK,
  credentials, protocol version, and required tools;
- the requested policy separately from the actual provider, model, effort,
  service tier, and runtime bound;
- a bounded considered/rejected set, override provenance, nullable estimates
  with their source and measurement window, and supersession;
- append-only `routing.snapshot`, `routing.decided`, and override
  accepted/rejected events with generation and monotonic sequence;
- deterministic reconnect/resync and idempotency-conflict behavior.

This follows the decision in
[Q00/ouroboros#1398](https://github.com/Q00/ouroboros/issues/1398): absent or
low-confidence authority cannot authorize cheapening, and raw text length,
tool count, artifact count, or keyword proxies are not acceptable. Historical
token, tool, latency, retry, escalation, and verifier outcomes may become a
calibration input only after Ouroboros approves a versioned proof protocol.
Raw prompts, transcripts, and chain-of-thought are not routing-memory features.

Ourocode displays `suggested` metadata as read-only until the decision is
effect-bound. An optional workspace `routing_required` policy may fail closed
for agent launches initiated through Ourocode when no valid receipt exists. It
does not intercept arbitrary commands typed into the ordinary PTY. Routing
never weakens permission, credential, confirmation, or external-side-effect
gates.

Ouroboros 0.51.0 does not yet satisfy this complete contract. It now owns
bounded model routing, emits `execution.ac.model_routed` and
`execution.ac.effort_routed`, attributes tokens per attempt, and has a
deterministic frugality proof. Those are the correct authority and measurement
layers. The model-routing event is still auxiliary proof telemetry emitted via
a best-effort path whose persistence failure does not block provider dispatch;
there is no signed, cursor-bounded `routing.decided` receipt for an independent
consumer. In one earlier isolated-profile smoke, fallback selected a Claude
alternate harness without the required SDK and exhausted all ACs. That is why
capability preflight still belongs before cost or effort ranking.

An audit of remote `main` at `bef43c1af` (37 commits after the 0.50.8 tag)
found useful but still insufficient progress. `session_signal_target_guards`
and `BEGIN IMMEDIATE` admission reduce the target-active race, but discovery
still issues no opaque lease, queued delivery has no owner-incarnation CAS
claim or status tool, and provider-bound delivery can still become uncertain.
The internal `InvestmentAssessment`, `RouteAdmission`,
`execution.ac.effort_routed`, `execution.ac.model_routed`, and token
attribution events remain policy inputs or observe-only telemetry, not an
effect-authorizing receipt. In particular, persistence failure of
`model_routed` does not prevent provider dispatch.

The required upstream sequence is therefore:

1. persist `routing.decided` atomically with the provider-effect claim after
   executable, SDK, credential, protocol, and tool-capability preflight;
2. bind the receipt to execution, session scope, attempt, AC, generation, and
   request-authority digest with bounded considered/rejected candidates;
3. expose cursor-bounded `routing.snapshot` and `routing.decided` through MCP
   v2, including override and supersession events;
4. make Ourocode consume that receipt without duplicating the private routing
   policy or classifying ordinary PTY text.
