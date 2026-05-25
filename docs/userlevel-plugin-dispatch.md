# UserLevel Plugin Dispatch in Ourocode

Tracks the operational plan for adding `ooo <plugin> <command> ...` dispatch to
the interactive terminal. The product boundary lives in `docs/product-vision.md`
and SSOT issue
[#25](https://github.com/Q00/ourocode/issues/25); this document is one vertical
slice under that SSOT and is intentionally scoped to the UserLevel plugin
dispatch path.

Originating request: [#2](https://github.com/Q00/ourocode/issues/2) (closed as
superseded). Umbrella vision issues #4, #6, #12, #13, and #14 restate the same
direction and are closed in favor of #25.

## Goal

`ourocode` should let users run installed Ouroboros UserLevel plugins from the
terminal UI with direct `ooo <plugin> ...` prompts. A user should not need to
leave `ourocode`, run a shell command, find generated handoff artifacts, and
then manually re-enter `ooo run`.

The motivating example is `Q00/ouroboros-plugins` `superpowers`:

```text
ooo superpowers test-driven-development --goal "Add retry behavior"
```

or, when the user explicitly opts into continuation:

```text
ooo superpowers test-driven-development --goal "..." then run the generated handoff
```

Free-form natural-language dispatch ("Use Superpowers TDD for this change") is
deferred until the exact-match path is stable. Slash-shaped `/superpowers ...`
input continues to flow through the existing
`Ourocode.Command.CapabilityPreflight` slash-command surface; the work in this
document adds a sibling path for `ooo`-prefixed input that the slash surface
does not cover.

## Current boundary (as of `release/bootstrap` v0.1.11)

`ourocode` already has most of the pieces it needs and is missing the
UserLevel-specific bridge.

In place upstream:

- `Ourocode.Runtime.Router` classifies `ooo`/`ouroboros` shortcuts into
  `interview`, `seed`, `run`, `evolve`, `ralph`, and `workflow` adapter routes.
- `Ourocode.Runtime.Dispatcher` enforces shell-injection guards
  (`@forbidden_external_commands`, `@shell_commands`) for any external command
  runner the adapters call.
- `Ourocode.Runtime.OuroborosWorkflowInvocation` already invokes the MCP
  `ouroboros_generate_seed` and `ouroboros_start_execute_seed` tools and is the
  natural continuation target for plugin-generated seeds.
- `Ourocode.Command.Registry` models a `:plugin` source with normalized
  command entries, args, aliases, run_spec, and trust metadata.
- `Ourocode.Command.CapabilityPreflight` resolves slash-shaped (`/foo`)
  command input read-only and projects trust state via
  `CapabilityPreflight.Trust` and `CapabilityPreflight.Projection`.
- `Ourocode.Plugin.*` loads declarative plugin mappings (adapter / action /
  renderer) and the CLI bootstrap now loads `.ourocode/config.json` plugin
  entries during startup.

Still missing for UserLevel plugin dispatch:

- A discovery surface that asks Ouroboros (CLI today, MCP tomorrow) which
  UserLevel plugins are installed, which commands they expose, and which
  artifacts they may produce.
- An execution route for `ooo <plugin> <command> ...` that is distinct from
  the existing Ouroboros workflow shortcuts and from the slash-command surface.
- A dispatch adapter that turns a preflight result into an argv invocation
  through `Dispatcher.guarded_external_command_runner` and streams output into
  a child pane.
- Trust-blocked rendering that surfaces the exact `ouroboros plugin trust ...`
  remediation without granting trust on the user's behalf.
- Detection of plugin-generated artifacts (such as `seed.md`) and an
  intent-gated continuation into `ooo run seed_path=...`.

## Implementation plan

The work is split into five reviewable PRs that build on each other. Each PR
keeps the SSOT primitives in #25 intact and adds exactly one new primitive.

### PR 1 — vision normalization (this PR)

Pure docs and issue hygiene. No code changes.

- Re-anchor this document on #25 and the in-tree `docs/product-vision.md`.
- Close umbrella restatement issues (#4, #6, #12, #13, #14) as
  superseded by #25.
- Inject the PR breakdown into the SSOT issue task list so progress is visible.

Closes none of the implementation-shaped issues by itself; unblocks all later
PRs by giving them a single shared framing.

### PR 2 — UserLevel plugin capability layer

Adds the `Ourocode.Plugin.UserLevel.*` namespace.

- `Capability` and `CommandCapability` structs that record plugin identity
  (id, source, version, install scope, trust scope, manifest digest) and
  per-command metadata (name, aliases, args, risk class, expected artifacts,
  continuation hint).
- `Discovery` behaviour with an `OuroborosCLI` adapter that calls
  `ouroboros plugin list --json` through the existing guarded external command
  runner. Failure surfaces as a `:degraded` registry status rather than a
  startup crash.
- `Registry` Agent that caches the latest capability list with a 60 s TTL,
  invalidates on `Plugin.ConfigWatcher` signals, and exposes a manual
  `/plugins refresh` slash command.
- A wiring step that publishes UserLevel capabilities into the existing
  `Command.Registry` `:plugin` source so the upstream
  `CapabilityPreflight` and `/preflight` surfaces immediately see them.

Closes #5, #8, #9, #18, #27, #29.

### PR 3 — preflight resolver and router glue

Adds the `ooo`-prefixed resolution path that the existing slash-shaped
preflight does not cover.

- `PreflightResult` struct mirroring the upstream slash-shaped projection but
  scoped to `ooo`-shaped input.
- `Resolver` pure function that turns a `TaskRequest` into a `PreflightResult`
  with kind `:unique_match`, `:ambiguous`, or `:unknown`, including trust
  state and remediation text.
- A `:user_level_plugin` execution route in `Router` and `Dispatcher`
  triggered only when the second token exactly matches a known plugin name.
- Tests cover unique match, ambiguous match, unknown plugin, missing trust,
  and shell-injection input.

Closes #16, #23.

### PR 4 — dispatch adapter, trust UX, Superpowers vertical slice

Connects the resolver to actual execution.

- `Ourocode.Runtime.UserLevelPluginInvocation` adapter that implements
  `Ourocode.Runtime.Adapter` and translates a preflight result into an argv
  invocation through `Dispatcher.guarded_external_command_runner`.
- `PreflightPanel` TUI module that renders the preflight (plugin, command,
  args, risk class, trust state, expected artifacts) and surfaces the exact
  `ouroboros plugin trust ...` remediation when trust is missing. No silent
  grants.
- A `superpowers` discovery fixture so `ooo superpowers list` can run end to
  end in tests.

Closes #15, #17 (minimal trust-blocked structured error path), #20, #21.

### PR 5 — artifact capture, continuation policy, decision journal

Closes the loop from dispatch to follow-up workflow.

- `ArtifactWatcher` that scans `Capability.expected_artifacts` after the
  plugin run completes, producing `%Artifact{}` records attached to the
  current session.
- `Continuation` policy module: read-only commands stop, handoff-producing
  commands suggest `ooo run seed_path=...`, and the suggestion runs
  automatically only when the user's prompt explicitly opted in (for example,
  "then run the generated handoff").
- `DecisionJournal` appends one structured event per phase
  (`:preflight`, `:dispatch`, `:artifact`, `:continuation`) into the existing
  `lib/ourocode/journal/` writer.

Closes #7, #10, #11, #26, #28.

## Deferred (no PR yet)

The following vision issues are valuable but premature given current usage
signal. Each is left open with a `defer:awaiting-signal` note that records the
trigger condition under which it should ship.

- #19 — recipes: ships after a recurring user pattern emerges (same plugin
  command invoked five or more times by the same user with the same shape).
- #22 — context packets: ships after a plugin declares an `accepts_context`
  capability so leakage versus underuse is observable.
- #24 — durable sessions and full failure recovery: ships when long-running
  (greater than 10 minute) plugin invocations or plugin-side pause/resume
  hooks appear.

## Continuation policy (PR 5 specifics)

Continuation behavior is intentionally conservative.

- A command whose declared risk class is `:read_only` finishes after rendering
  output. No follow-up is offered.
- A command whose declared risk class is `:handoff_producing` triggers
  artifact watching. If a `seed.md` or other declared artifact is found, the
  continuation card shows the exact `ooo run seed_path=...` command.
- The continuation runs automatically only when the original prompt contains
  an explicit opt-in token such as "then run the generated handoff" or the
  Korean "이어서 실행". Otherwise it waits for user confirmation.
- A command whose declared risk class is `:destructive` requires explicit
  user approval inside the preflight panel before dispatch and never
  auto-continues.

## Acceptance tests carried into PR 4 and PR 5

Carried forward from the original #2 acceptance criteria, rescoped to fit the
plan above.

1. From inside `ourocode`, `ooo superpowers list` invokes the installed
   `superpowers` plugin (or a discovery fixture in tests) and renders output
   in a child pane.
2. From inside `ourocode`, `ooo superpowers test-driven-development --goal "..."`
   surfaces the preflight, dispatches the plugin, and detects the
   declared `seed.md` artifact through `Capability.expected_artifacts`.
3. When a plugin command generates a seed artifact, `ourocode` shows the
   suggested `ooo run seed_path=...` continuation and only auto-runs it when
   the prompt opted in.
4. Missing or untrusted plugin states render the exact
   `ouroboros plugin trust ... --scope ...` remediation string and do not
   grant trust silently.
5. Shell injection attempts in plugin arguments are passed through as argv
   tokens; `Dispatcher.guarded_external_command_runner` guards remain green.

## Non-goals

- Installing or trusting plugins automatically.
- Creating a plugin marketplace or catalog UI.
- Replacing Ouroboros plugin firewall semantics inside `ourocode`.
- Executing destructive plugin actions in the initial bridge.
- Free-form natural-language dispatch beyond exact plugin-name plus
  command-name token matching.
- Inferring plugin-internal storage paths; `ourocode` only trusts the
  `expected_artifacts` glob list a capability declares.
