# Ourocode Desktop for macOS

This is the first runnable slice from RFC 0001: a native AppKit window with broker-owned local PTYs, VT emulation, Unicode/IME support, and an on-demand Metal renderer. It remains a useful terminal when Ouroboros is unavailable.

The signed app bundles `Contents/Helpers/ouro-broker-v4` plus the explicitly
labelled v3 compatibility helper. The broker is an independent,
single-`poll(2)`-loop process listening on a mode-`0600` Unix socket under the
user's Application Support directory. Closing or restarting the UI only drops a
client connection: shells remain broker-owned and are restored from a bounded
snapshot or monotonic cursor resume. Only the separately confirmed
`Terminate Session…` command sends `terminate`, which signals and reaps its
foreground process group.

The UI now names those operations by their actual lifetime semantics.
`Close View` (`Command-W`) crosses the exact detach barrier and removes only
the local projection; it never sends `terminate`. `Reopen Closed View`
(`Command-Shift-T`) lists the broker, verifies that the same stable terminal ID
is still running, and reattaches that identity rather than starting a new shell.
`Terminate Session…` is a separate destructive command with explicit warning
copy and confirmation. Create/recovery races use the same pure lifecycle policy:
unknown create outcomes are reconciled, late attachment commits are detached,
and ambiguous commit failures reconnect before any UI is discarded. The
standalone policy fixture is `test-terminal-view-lifecycle.sh`.

The default wire protocol is v4 and uses `broker-v4.sock`. The app leaves the
v2/v3 namespaces untouched so older brokers and their live sessions can coexist
during upgrade. V4 validates a capability manifest, imports a digest-bound
checkpoint through exact-order 64 KiB chunks into an offscreen terminal, applies
ordered PTY/resize catch-up, and swaps the selected view only after recovery
commit returns `attached_ready`. No input lease exists before that point. Missing,
conflicting, expired, over-budget, or reordered recovery state fails closed and
preserves the old renderer. Preparing a recovery revokes the previous lease and
live subscription; any rejected import sends `recovery_abort` so broker pins and
slots are released immediately. Rapid tab switching can cancel a prepare before
`recovery_id` is known: the client retains the request ID, bounded-ignores a late
`recovery_begin`, and immediately sends `recovery_abort` once its identity arrives.

V4 also requires `terminal.detach.lease.v4`. `detach` carries the exact
`broker_generation`, `terminal_id`, `input_epoch`, and per-connection attachment
lease. It flushes and queues prior state events, removes only that subscription,
conditionally revokes matching input authority, and then returns `detached` with
the final `state_seq`. FIFO framing therefore places all prior events before the
reply and permits no event for that attachment after it. The PTY, child process,
canonical state, and ordered headless journal remain broker-owned; `detach` is
not `terminate`. A displaced input owner can still detach its own subscription
without revoking the newer owner's lease. V3 has no equivalent ordering barrier,
so the Swift API rejects detach instead of claiming local-only compatibility.

V3 is never a silent downgrade: the user must choose
the visibly labelled compatibility path after seeing the v4 failure reason. A
create nonce remains projected by list so timeout outcomes can be reconciled
without duplicating a PTY.

The session rail can connect to an existing Ouroboros MCP v2 streamable-HTTP
endpoint and group persisted executions. Every session row enters a central
workspace first, even when one or several verified PTYs exist. The workspace
refreshes changed activity snapshots every two seconds, follows the live tail
only while the reader remains at the bottom, preserves historical scroll
position, and exposes one independently scoped message composer per exact
agent attempt. A queued receipt is shown as queued; the app does not claim that
the running agent applied it.

## Build and run

Command Line Tools and Swift 5.9 or newer are sufficient:

```bash
./apps/macos/OurocodeDesktop/build-app.sh
./apps/macos/OurocodeDesktop/run-canonical-app.sh -- --project-dir "$PWD"
```

For deterministic terminal/input QA, or to bypass account-specific login
startup while diagnosing it, select an executable shell explicitly. This path
is interactive but intentionally does not add `-l`:

```bash
./apps/macos/OurocodeDesktop/run-canonical-app.sh -- \
  --project-dir "$PWD" --shell /bin/sh
```

The ordinary launch uses the account shell from `getpwuid(3)` with `-l -i`, so
zsh reads `.zprofile` and `.zshrc` in a real controlling PTY. `OUROCODE_SHELL`
is the environment equivalent of `--shell` and remains an explicit,
non-login override. Finder launches receive a UTF-8 locale fallback plus
`TERM_PROGRAM_VERSION`; an existing user locale is never overwritten.

Terminal text starts at 16pt with a process-scoped bundled MesloLGS Nerd Font
Mono so Powerlevel10k and other `.zshrc` prompt glyphs render without changing
the user's system font library. JetBrains Mono and Menlo remain fixed-pitch
fallbacks. Use Command-Plus,
Command-Minus, and Command-0 to resize or reset it. The chosen size is
remembered, and the font, cell grid, Metal frame, and PTY pixel geometry change
as one operation.

The account's real `zsh -l -i`, `.zprofile`, and `.zshrc` remain authoritative.
Ourocode's generated ZDOTDIR proxy sources every user startup file exactly once,
then appends OSC 133 command-boundary hooks. A verified broker lease and first
presented frame own input authority; delayed or absent OSC 133 never hides or
locks a usable PTY. The Ghostty projection uses available
existing row semantics to give prompt/input rows one restrained 3% sRGB turn
background while leaving command output and explicit ANSI backgrounds exact.
This is a renderer-only presentation: it does not create a parallel transcript,
another terminal model, or a per-tab view.

The pinned Ghostty/Metal surface has a separate, explicitly development-only
bundle path for Luna QA and screen recording:

```bash
GHOSTTY_VT_PREFIX=/absolute/path/to/audited/ghostty-v6-prefix \
  ./apps/macos/OurocodeDesktop/build-dev-ghostty-app.sh
OUROCODE_CANONICAL_APP="$PWD/apps/macos/OurocodeDesktop/.build/dev-ghostty/Ourocode-Ghostty-Dev.app" \
  ./apps/macos/OurocodeDesktop/run-canonical-app.sh
```

This command verifies the exact source/header/canonical-archive digests, statically links
the render ABI, bundles the pin-namespaced broker, and compiles only the tracked
shader resource at runtime under a debug flag. It is ad-hoc signed and is not a
release artifact. `build-app.sh` keeps the packaged surface gate: a feature-on
release fails closed unless full Xcode can produce `OuroTerminal.metallib`; it
never falls back to shipping runtime Metal source.

An ad-hoc development rebuild has a new macOS code identity. System Settings
may still show an older Files and Folders grant as enabled even though a child
shell from the rebuilt app cannot open a protected Desktop, Documents, or
Downloads path. Do not work around that by weakening the broker or silently
changing privacy settings. Refresh consent for the final signed artifact, or
use `--shell /bin/sh` only to isolate terminal-input QA from account startup.
Release artifacts require a stable Developer ID signature and notarization.

On an ordinary Finder launch, Ourocode connects automatically to the shared,
user-scoped Ouroboros endpoint at `http://127.0.0.1:8976/mcp`. Ouroboros setup
owns that service; Ourocode does not create one Python runtime per window or
download packages behind the user's back. The terminal remains available when
the endpoint is missing, and `--no-ouroboros` disables the connection.

The managed Ouroboros bridge also exposes pinned `cua-rs` 0.9.1 tools through
the `cua_` namespace. `cua-rs` drives native macOS accessibility elements
without moving the user's pointer, stealing keyboard focus, or switching
Spaces. The bridge sets `CUA_YIELD_TO_HUMAN=1`, so it stands down when the user
is actively using the target app. Settings → Computer Use verifies the native
binary, the Ourocode compatibility bridge, Accessibility, and Screen Recording;
it never downloads or runs an installer. The repository installer performs a
checksum-pinned best-effort CUA install on Apple silicon unless
`OUROCODE_SKIP_CUA=1` is set.

The compatibility helper answers only Ouroboros 0.51.6's initial modern
`server/discover` probe with JSON-RPC method-not-found, then forwards every
legacy MCP frame byte-for-byte to cua-rs. This is required because cua-rs 0.9.1
otherwise closes stdio before Ouroboros can fall back to `initialize`.

For development with one independently supervised, loopback-only Ouroboros
process, start the endpoint explicitly:

```bash
OUROBOROS_MCP_CONFIG="$PWD/apps/macos/OurocodeDesktop/Resources/ouroboros-mcp-bridge-cua.yaml" \
  uvx --isolated --from 'ouroboros-ai[mcp]==0.51.6' ouroboros mcp serve \
  --transport streamable-http --host 127.0.0.1 --port 8976 --runtime codex

./apps/macos/OurocodeDesktop/run-canonical-app.sh -- \
  --project-dir "$PWD" --mcp-url http://127.0.0.1:8976/mcp
```

The fixed bridge config exposes only the pinned CUA server; unrelated user MCP
servers are never copied into an explicitly launched development child. That
mode may use the pinned `uvx` package and is not the product default. Production
packaging will replace the current shared HTTP bootstrap with one
launchd-managed user broker over XPC or a Unix-domain socket. Both HTTP and
HTTPS endpoints are accepted only on loopback; remote and mobile clients
require authenticated pairing and a separate encrypted snapshot/delta
transport.

## Mobile boundary

Paseo is a product and protocol reference, not a code dependency. A paired mobile app is another thin view of broker-owned sessions: it receives a bounded terminal snapshot followed by ordered deltas, resumes from a monotonic cursor, and is forced to resync if its byte-limited queue falls behind. It never receives the PTY master file descriptor or an Ouroboros MCP capability. Input requires a short-lived, generation-guarded lease, so desktop and mobile cannot accidentally type into the same terminal concurrently. Paseo is AGPL-3.0-or-later; no source is copied into Ourocode.

The release bundle identifier is `com.ourolabs.ourocode`. Development and QA
bundles are assigned separate identities and may not claim the release ID.

## Distribution image

Build the drag-to-Applications DMG with the same native type and material system as the app:

```bash
./apps/macos/OurocodeDesktop/package-dmg.sh
```

The default ad-hoc artifact is explicitly named `Ourocode-<version>-dev.dmg` so it cannot be mistaken for a distributable release. A production package must set `RELEASE_BUILD=1`, `CODESIGN_IDENTITY`, and `NOTARY_PROFILE`; only that path may create `Ourocode-<version>.dmg`, and it fails closed unless Developer ID signing, notarization, stapling, image verification, and the mounted-app signature check all succeed. The verified temporary image replaces the previous DMG only as the final atomic step.

Use the standard launch command path for deterministic smoke runs without depending on the current macOS input source:

```bash
./apps/macos/OurocodeDesktop/run-canonical-app.sh -- \
  --project-dir "$PWD" --command "printf 'ourocode-smoke\\n'"
```

Run the visibly labelled captured-fixture mode for session-tree and steering UI QA:

```bash
./apps/macos/OurocodeDesktop/run-canonical-app.sh -- \
  --project-dir "$PWD" --demo fanout-8
```

The same real UI path has deterministic `offline`, `limited`, `ended`, and
`rejected` modes for state and recovery QA. In `rejected`, sending the fixture
message returns `target_lost_before_delivery` so draft preservation and the
immediate read-only transition can be inspected.

## Current engine boundary

The current production-candidate development path is the exact Ghostty source
pin recorded by `GhosttyRenderDeployment.sourceCommit`, exposed only through
Ourocode's static ABI v6 boundary. The broker owns one bounded headless Ghostty
state per PTY. The AppKit process owns one disposable projection and one
`MTKView`, regardless of whether one or 32 terminal tabs exist. A tab switch
revokes input through a FIFO receipt, restores the selected state offscreen,
and opens keyboard input only after the exact generation's first frame and
focus receipt. Korean IME preedit remains local and only committed text enters
the normalized input lane.

The ordinary production-candidate build now requires the exact Ghostty render
archive and Metal surface. A missing archive or full Xcode Metal toolchain
fails closed instead of producing another engine. The pinned MIT-licensed
SwiftTerm adapter is available only when
`OUROCODE_SWIFTTERM_COMPATIBILITY_BUILD=1` is set; that labelled fixture build
uses `OUROCODE-ANSI-REPLAY` from `fixture:vt100-0.15.2`, never a Ghostty
checkpoint. Both paths support up to 32 local PTY tabs and attach only the
selected terminal to the view hierarchy.

The Ghostty app is still development-only until a packaged build supplies a
compiled Metal library, the terminal selection/pointer contract passes its
gate, and Developer ID signing and notarization succeed. The build never
silently falls back from that release gate to runtime shader compilation.

## Verification

```bash
cargo test --manifest-path crates/ouro-session/Cargo.toml
cargo test --manifest-path crates/ouro-broker/Cargo.toml --all-targets
swiftc -O apps/macos/OurocodeDesktop/Sources/OurocodeDesktop/NormalizedTerminalInput.swift \
  apps/macos/OurocodeDesktop/Sources/OurocodeDesktop/BrokerClient.swift \
  apps/macos/OurocodeDesktop/Tests/BrokerClientV4Smoke.swift \
  -o /tmp/ourocode-broker-v4-smoke
/tmp/ourocode-broker-v4-smoke
codesign --verify --deep --strict apps/macos/OurocodeDesktop/.build/Ourocode.app
```

For memory measurements, use the PID-scoped sampler in `scripts/perf` and
record `phys_footprint` for the app, broker, and every shell separately; raw RSS
is not a release claim. The current exact-pin Ghostty development app measured
48,333,760 bytes for the AppKit process, 1,868,112 bytes for the broker, and
1,622,376 bytes for one idle shell (about 51.8 MB combined), with seven app
threads, one broker thread, one shell thread, and effectively zero idle CPU.
The evidence is in `qa-evidence/perf-full-app-one-tab-20260809.ndjson` and its
manifest. A steady 32-state headless Ghostty workload measured 50.1 MiB and
zero idle CPU, but its 279.5 MiB lifetime peak remains unresolved. Do not infer
a sub-150 MiB peak or a Ghostty/Warp superiority claim from the steady result.
