# RFC 0010: Terminal baseline and zoom discoverability gate

- Status: v12 zoom runtime-verified; terminal baseline gate remains open
- Date: 2026-08-16
- Scope: native macOS terminal behavior, independent of Ouroboros availability
- Rule: source code and fixtures are not proof that the currently opened app works

## Why this gate exists

Ourocode must first be a familiar, complete terminal. MCP sessions, semantic
command presentation, and agent routing do not compensate for a missing or
undiscoverable terminal convention.

The source originally contained text-size actions, but the user's opened app
did not execute them. That report correctly invalidated the earlier
`implemented` verdict. The replacement v12 portable artifact now passes the
core exact-hash acting checks and makes text size discoverable from terminal
chrome. Untested focus/boundary cases remain explicit below.

This follows the Apple interaction requirement of familiarity and clear
mapping: a common action must be reachable by the standard shortcut, a native
menu item, and a visible or searchable control. Feedback shown only *after* a
shortcut succeeds is confirmation, not discoverability.

## Reference boundary

We copy behavior and conventions, not UI source.

- [Ghostty pinned source](https://github.com/ghostty-org/ghostty/tree/02436fd4eb0fca179f6d58717e9bc7a0ce106272)
  is the terminal action baseline. Its default bindings include `Cmd-=`,
  `Cmd-+`, `Cmd--`, `Cmd-0`, `Cmd-K`, `Cmd-A`, `Cmd-Home`, `Cmd-End`, tab
  creation/navigation, split actions, and font actions.
- [Warp pinned source](https://github.com/warpdotdev/Warp/tree/e72fd7aacbbb2236d9b3be2aad7e7178fe94b4bc)
  informs pane groups, terminal Find, links, notifications, and semantic
  command readability. Its block treatment is not permission to replace PTY
  output with a chat transcript.
- [Kaku pinned keybindings](https://github.com/tw93/kaku/blob/8b370e5fadfd7721097928567f5b0180d71f3a7d/docs/keybindings.md)
  are the clearest macOS convention list: `Cmd-=/-/0`, `Cmd-K`, tabs,
  splits, directional focus/resize, pane zoom, and a searchable command
  palette.
- Grok CLI is an agent/CLI reference, not an independent terminal-emulator
  engine. Its command discovery and progressive task feedback may inform the
  MCP/session layer, but cannot prove selection, scrollback, reflow, IME, or
  PTY correctness.

## Baseline requirements matrix

`Source-backed` means the present worktree has a plausible path. It does not
mean the current binary passed.

| User behavior | Expected convention | Current source evidence | Current verdict | Release proof |
| --- | --- | --- | --- | --- |
| Increase/decrease/reset terminal text | `Cmd-=`, `Cmd-+`, `Cmd--`, `Cmd-0`; native View menu; Settings control | App-wide event routing, View menu, command palette entries, 12–48 pt Settings slider, bounded HUD, compact terminal-chrome menu | **Implemented and v12 runtime-verified** for terminal, palette, and Settings focus | Complete the unchecked boundary rows in the exact-hash matrix |
| New/close/reopen terminal tab | `Cmd-T`, `Cmd-W`, `Shift-Cmd-T`; explicit terminate separate from close view | Source-backed | P0 acting proof required | PTY identity survives close/reopen; terminate requires explicit action |
| Select and navigate tabs | `Cmd-1…9`, `Shift-Cmd-[` / `]`, searchable all-tabs control | Source-backed | P0 acting proof required | Keyboard, pointer, overflow, and stable identity on 32 tabs |
| Copy, paste, select all | `Cmd-C`, `Cmd-V`, `Cmd-A`; multiline/control paste confirmation | Copy/paste and `Cmd-A` are wired through native menu and app command routing | Implemented by contract; extended acting proof remains | Selection and clipboard acting checks with Unicode, ANSI, and alternate screen |
| Find scrollback | `Cmd-F`, `Cmd-G`, `Shift-Cmd-G`, native find surface | Source-backed | Partial; inline match highlight is missing | Exact visible match navigation across retained scrollback |
| Clear screen and scrollback | `Cmd-K`, menu and palette command | Native menu/palette path sends canonical Ctrl-L; v12 visibly cleared the shell | Partial: screen clear implemented, true scrollback deletion missing | Canonical render FFI clears current pane scrollback without shell-text injection |
| Scroll to top/bottom | `Cmd-Home` / `Cmd-End` and accessible actions | Native menu, palette, accessibility, and Metal serialization paths exist | Implemented by contract; large-scrollback acting proof remains | Large real scrollback, keyboard and VoiceOver proof |
| Split terminal and manage panes | `Cmd-D`, `Shift-Cmd-D`; `Cmd-Option-Arrows` focus; `Cmd-Control-Arrows` resize; `Shift-Cmd-Return` pane zoom | Rust split tree exists; AppKit bridge does not | **P0 missing** | 1/2/4 visible panes, exact PTY/focus/input authority, divider commit once |
| Shell fidelity | Account login shell, `.zprofile`/`.zshrc`, TERM/locale, OSC 7 and OSC 133 without fake readiness | Source-backed | Artifact-sensitive | Clean Powerlevel10k startup and zsh/bash/fish fixtures plus acting proof |
| Resize/reflow/fullscreen | Live window resize, Retina move, fullscreen, vim/tmux/ssh reflow | Resize contract source-backed; no complete conformance run | Partial | Physical display/fullscreen and narrow-wide conformance run |
| Links and files | URL hover/open/copy; safe Finder path drop | OSC 8 open and path drop source-backed | Partial; implicit URL, hover, and copy URL missing | Acting proof with safe schemes and credential rejection |
| Themes, fonts, keymap | User font/palette/theme and reload; editable conflict-checked keymap | Fixed theme/font candidates; text-size preference only | **Missing parity** | Persistent settings, contrast, live reload, conflict handling |
| Restore | Window geometry, selected tab, tab order, panes, cwd, scroll/focus | PTY/tab reattachment source-backed | Partial | Relaunch exact state without extra PTY or renderer |
| Performance | Low input latency; bounded hidden state; shared GPU resources; no thread/runtime per tab | One selected Metal projection and broker bounds are source-backed | Broad superiority unproven | Same-workload Ghostty/Warp coalition benchmark and 1/4/8/32 pane close-to-baseline |

## Zoom discoverability contract

All of these paths must invoke one shared semantic action. They must not each
install a competing key handler.

1. The **View** menu exposes “Make Text Bigger”, “Make Text Smaller”, and
   “Actual Size”, each with its rendered shortcut.
2. The command palette finds the same actions by “text”, “font”, “bigger”,
   “smaller”, “zoom”, and “actual size”.
3. Settings exposes a live text-size value and reset control.
4. Terminal chrome exposes one compact text-size entry point (`textformat.size`)
   with a menu for Bigger, Smaller, Actual Size, and Settings. It is one control,
   not permanent `+` and `-` clutter. Its tooltip states `Cmd-+ / Cmd--`.
5. A successful change immediately shows the resulting point size; minimum,
   maximum, and default are explicit. VoiceOver receives one announcement.
6. The main-window accessibility help mentions text resizing. Reduced motion
   removes the HUD fade animation without removing feedback.

The current source satisfies all six items. In the exact v12 artifact, Computer
Use opened the terminal-chrome menu, executed terminal zoom, found all three
zoom commands from the palette, and observed Settings stay synchronized.

## Exact-hash zoom acting matrix

Run this on a fresh isolated app build and record the app executable hash. The
starting size is 16 pt unless the test explicitly verifies restored preference.

Exact artifact: `/private/tmp/Ourocode-Ghostty-v12-portable.app`, bundle ID
`works.ourocode.desktop.qa.v12`, executable SHA-256
`12b6bdaac2606a03e147760d635f202939e0f6c13c756701dbdaa78c9609dd00`.

| Focus/state | Action | Required observation | v12 observation |
| --- | --- | --- | --- |
| Terminal first responder | `Cmd-=` | 16 → 17 pt exactly once; HUD, atlas, cell and PTY pixel geometry agree | Pass: 16 → 17 |
| Terminal first responder | `Shift-Cmd-+` | 17 → 18 pt exactly once | Pass: 17 → 18 |
| Terminal first responder | `Cmd--` | 18 → 17 pt exactly once | Pass: 18 → 17 |
| Terminal first responder | `Cmd-0` | 17 → 16 pt exactly once and “Default” appears | Pass: 17 → 16 |
| Connections rail focused | `Cmd-+`, `Cmd--` | Same one-step changes; focus is not stolen | Not yet recorded |
| Command palette open | Search/menu zoom action | Commands are discoverable; invocation dismisses intentionally and changes once | Search `zoom` exposed all three commands; menu invocation not separately recorded |
| Settings key window | `Cmd-+`, `Cmd-0` | Terminal preference and visible slider/value remain synchronized | Pass |
| Shell starting / input locked | `Cmd-+` | Typography changes without unlocking or sending bytes to the PTY | Not yet recorded |
| Min/max bounds | one extra `Cmd--` / `Cmd-+` | “Minimum” / “Maximum”; no duplicate atlas or resize transaction | Not yet recorded |
| Rapid repeat | ten increases then reset | Coalesced resize settles at the expected value; no stuck pointer/input gate | Not yet recorded in v12 |

Also click every View-menu item. A keyboard fixture alone cannot satisfy this
gate because it does not prove that `installApplicationKeyMonitor`, the current
window, and the shipped executable are the code being exercised.

## Performance invariants for terminal parity

Adding familiar behavior must preserve the architecture rather than attach a
new runtime to each tab.

- Font actions reuse one HUD and replace the active glyph atlas; prior point
  sizes do not accumulate textures.
- Repeated font/window resize is coalesced; a committed geometry produces at
  most one ordered PTY resize per affected visible pane.
- Hidden tabs own no Metal view, drawable, glyph atlas, render thread, or
  additional MCP runtime.
- Multiple visible panes share Metal device, pipelines, samplers, font
  discovery, glyph cache where safe, broker connection, and I/O reactor.
- Memory claims include app, broker, shells, agents, and MCP descendants. Report
  `phys_footprint`, lifetime peak, idle CPU, threads, FDs, and close-to-baseline;
  do not substitute app RSS or a headless engine microbenchmark.
- Compare Ourocode, Ghostty, and Warp using the same shell startup files,
  geometry, scrollback payload, pane count, agent process set, warmup, and
  sampling window. Until then, “faster” or “lower memory” remains unproven.

## Exit criteria

This baseline is complete only when:

1. every P0 row above has exact-hash acting evidence;
2. true clear-scrollback and AppKit split/pane paths are implemented and
   menu/palette discoverable; `Cmd-A` and top/bottom scrolling remain protected
   by their command/accessibility contracts;
3. the zoom acting matrix passes from all listed focus states;
4. Ghostty/Warp same-workload performance evidence meets explicit numeric
   budgets without losing shell, accessibility, or terminal correctness; and
5. the signed/notarized installer contains the same verified executable.
