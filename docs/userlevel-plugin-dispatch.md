# UserLevel Plugin Dispatch in Ourocode

Issue: https://github.com/Q00/ourocode/issues/2

## Goal

`ourocode` should let users run installed Ouroboros UserLevel plugins from the
terminal UI with either direct `ooo <plugin> ...` prompts or natural language.
A user should not need to leave `ourocode`, run a shell command, find generated
handoff artifacts, and then manually re-enter `ooo run`.

The motivating example is Q00/ouroboros-plugins `superpowers`:

```text
ooo superpowers test-driven-development --goal "Add retry behavior"
```

or natural language:

```text
Use the Superpowers test-driven-development workflow to add retry behavior, then run the generated handoff.
```

## Current boundary

As of `v0.1.8`, `ourocode` has the pieces needed for the first-class plugin UX,
but they are not connected end-to-end:

- `Ourocode.Runtime.Router` recognizes core `ooo`/`ouroboros` workflow terms.
- `Ourocode.Runtime.OuroborosWorkflowInvocation` invokes seed/run style workflow
  tools through the Ouroboros MCP path.
- `Ourocode.Command.Registry` can model plugin and dynamic-skill entries.
- `Ourocode.Terminal.EventLoop` can display plugin entries in discovery surfaces.
- Ouroboros owns the actual UserLevel plugin firewall, trust store, lockfile, and
  fallback dispatch for `ooo <plugin> <command> ...`.

The missing product boundary is a generic dispatch bridge from the `ourocode`
prompt loop into the installed Ouroboros plugin dispatcher.

## Proposed architecture

Add a `UserLevelPluginInvocation` path that is separate from core workflow
invocations.

```text
Prompt text
  -> TaskRequest / Router
  -> plugin-intent resolution
  -> installed plugin registry lookup
  -> safe Ouroboros plugin dispatch
  -> child pane output + artifact capture
  -> optional continuation into ooo run
```

### 1. Intent detection

Support two entry shapes:

1. **Direct command form**
   - `ooo superpowers list`
   - `ooo superpowers inspect brainstorming`
   - `ooo superpowers test-driven-development --goal "Add retry behavior"`
2. **Natural-language form**
   - “Use superpowers TDD for this task”
   - “Run the Superpowers systematic debugging workflow on this flaky test”

Direct command form should be deterministic. Natural-language form should only
route when an installed plugin name and a known command/skill name can be
resolved confidently; otherwise it should ask for a clarification or fall back to
normal `ooo` workflow routing.

### 2. Registry and trust resolution

`ourocode` should not reimplement plugin trust semantics. It should ask
Ouroboros for the installed plugin state using a stable boundary, in priority
order:

1. an Ouroboros MCP/CLI API dedicated to plugin dispatch and inspection, or
2. the existing Ouroboros CLI plugin dispatcher as a compatibility layer.

Missing trust should render the exact remedial command reported by Ouroboros,
for example:

```bash
ouroboros plugin trust superpowers --scope filesystem:read --scope filesystem:write
```

`ourocode` must not silently grant trust scopes.

### 3. Dispatch

Dispatch must go through the Ouroboros plugin firewall. `ourocode` should not
execute arbitrary shell strings assembled from natural language.

The invocation result should be represented as a normal child session/pane event
stream so the user sees:

- the selected plugin and command,
- trust/permission state,
- stdout/stderr or structured output,
- generated artifact paths,
- blocked or failed status with actionable guidance.

### 4. Artifact capture

Many AgentOS-style plugins prepare handoff artifacts rather than performing the
final implementation directly. `superpowers` writes artifacts under:

```text
.omx/superpowers/runs/<run-id>/
  invocation.json
  provenance.json
  handoff.md
  seed.md
  evidence.json
  audit.jsonl
```

`ourocode` should detect generated `seed.md` or equivalent Seed-compatible
artifacts from the plugin result and surface the continuation:

```text
ooo run seed_path=.omx/superpowers/runs/<run-id>/seed.md
```

### 5. Continuation policy

The first implementation should keep continuation conservative:

- read-only plugin commands stop after rendering output,
- handoff-generating plugin commands show the detected `ooo run` next step,
- automatic continuation into `ooo run` is allowed only when the prompt
  explicitly requests it, such as “then run the generated handoff”,
- destructive plugin actions remain blocked unless a future command declaration
  and trust UX explicitly allow them.

## Example flows

### Direct command, read-only

```text
user: ooo superpowers inspect test-driven-development
ourocode: dispatches installed plugin via Ouroboros firewall
ourocode: renders skill metadata and permissions
```

### Direct command, handoff generation

```text
user: ooo superpowers test-driven-development --goal "Add retry behavior"
ourocode: dispatches plugin
ourocode: renders generated run directory
ourocode: suggests `ooo run seed_path=.../seed.md`
```

### Natural language with continuation

```text
user: Use Superpowers test-driven-development to add retry behavior, then run the generated handoff.
ourocode: resolves plugin=superpowers, command=test-driven-development
ourocode: dispatches plugin and captures seed.md
ourocode: invokes the existing `ooo run` path with the generated seed
```

## Acceptance tests

A first implementation should cover:

1. Router classification for direct `ooo <installed-plugin> ...` prompts.
2. Natural-language resolution when plugin and command names are unambiguous.
3. Trust-blocked plugin output with the exact remedial trust command.
4. Dispatch payload construction without shell-string injection.
5. Artifact detection for `.omx/<plugin>/runs/<run-id>/seed.md`.
6. Continuation policy: suggest vs auto-run.
7. A `superpowers` fixture that proves `test-driven-development` can produce a
   detected handoff path.

## Non-goals

- Installing or trusting plugins automatically.
- Creating a plugin marketplace UI.
- Replacing Ouroboros plugin firewall semantics.
- Executing destructive plugin actions in the initial bridge.
