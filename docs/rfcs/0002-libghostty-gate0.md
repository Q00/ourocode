# RFC 0002: libghostty Gate 0 — Public API, Pin, and Replacement Gate

- Status: Ghostty/Metal is the source-level default; signed production artifact **not approved**
- Date: 2026-08-09
- Parent: [RFC 0001](./0001-ourocode-desktop-terminal.md)
- Upstream audit point: Ghostty `136f436a3bbb14fd48d18e927a83fc6585d5a63c`

## Decision

Promote the pinned `libghostty-vt` path to the source-level default while
retaining SwiftTerm only as an explicitly labelled compatibility build. The
exact-pin static-link gate, Ourocode-owned snapshot/accounting/idle-compression
ABI v4, ABI v5 detached render projection, shared page-admission adapter, and
broker integration pass. Distribution is still not approved: the current
machine cannot compile a packaged Metal library, and signing, notarization,
current-hash IME, conformance, and memory gates remain.

The preferred production candidate is Ghostty's public `libghostty-vt`, not
Ghostty's internal macOS surface API. The public library now exposes terminal
state, input encoders, selection, bounded scrollback, incremental render state,
and snapshots. It does **not** supply a Metal renderer, CoreText shaping, PTY
ownership, IME/AppKit view, or tab/session UI. Ourocode must provide those
layers and retain its one-reactor/global-budget architecture.

The checked-in adapter and Rust crate prove that the current public C API can
be compiled, statically linked, bounded, and isolated behind an Ourocode-owned
ABI. They do not prove visual parity or aggregate memory superiority.

## Pin and license ledger

| Artifact | Exact revision/version | License/status | Gate use |
| --- | --- | --- | --- |
| Ghostty application latest tag | [`v1.3.1` / `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`](https://github.com/ghostty-org/ghostty/tree/332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28) | MIT; released app tag | Controlled Ghostty.app comparison only. Its released `libghostty-vt` API predates much of the current terminal/render surface. |
| Gate 0 `libghostty-vt` | [`136f436a3bbb14fd48d18e927a83fc6585d5a63c`](https://github.com/ghostty-org/ghostty/tree/136f436a3bbb14fd48d18e927a83fc6585d5a63c) | [MIT](https://github.com/ghostty-org/ghostty/blob/136f436a3bbb14fd48d18e927a83fc6585d5a63c/LICENSE); library version `0.1.0-dev`; untagged API | Exact source pin for the experiment. No floating `main`, `tip`, or semver range. |
| Gate 0 Zig toolchain | `0.16.0`, macOS arm64 archive SHA-256 `b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489` | Zig distribution license bundle | Build input; the gate verifies the archive and the active extracted distribution. |
| Gate 0 canonical archive | `libghostty-vt.a` SHA-256 `c2c507b9355627e0ee2535e8328e47715212ea9075d50a96997fd3db2b8c34b6`; [`canonical-members.sha256`](../../spikes/libghostty-gate0/canonical-members.sha256) SHA-256 `0425918640f8ab640ad9fb88699e3396c4c0dc4ee53a47343f642c64ded07055` | Ghostty/Zig object licenses above | Release input after debug-only metadata removal and deterministic archive reconstruction. |
| Ghostling reference | [`f9034e43a50a2f3a8101e35497f486090c1ddd6e`](https://github.com/ghostty-org/ghostling/tree/f9034e43a50a2f3a8101e35497f486090c1ddd6e) pinning Ghostty `ae52f97dcac558735cfa916ea3965f247e5c6e9e` | Demo, not production terminal | Evidence that the public render-state API is consumable; no source is copied. |
| SwiftTerm compatibility adapter | [`e4f31b091b2efd81b33945ef7609141f827f2753`](https://github.com/migueldeicaza/SwiftTerm/commit/e4f31b091b2efd81b33945ef7609141f827f2753) | MIT; notice already bundled | Explicit compatibility/fixture build only; never an inferred production fallback. |

Before distribution, the build must retain Ghostty's copyright and MIT text,
inventory every object linked into the combined archive, generate an SBOM, and
record the canonical archive digest produced by CI. The gate retains all four
independent checks: exact source commit, exact Ourocode patch, exact official
Zig distribution, and exact patched public header. The canonical object-member
manifest and final archive digest add link-input verification; neither is a
substitute for those source and toolchain pins.

### Reproducible archive contract

The pinned Zig build emits a semantically stable but byte-unstable raw Darwin
archive. Release objects contain DWARF `comp_dir` and cache paths even under
`ReleaseFast`, while the archive table of contents and some member headers carry
wall-clock time and local UID/GID. This is why a rebuild can preserve `vt.h`
yet miss a raw whole-archive digest.

The release gate extracts only the exact ordered member set in
`canonical-members.sha256`, removes debug sections with Apple `strip -S`,
verifies every resulting member payload, fixes member mode to `0644`, and
rebuilds with Apple `libtool -static -D`. The audit ran with Command Line Tools
package `26.5.0.0.1777544298` / `cctools_ld-1267`. Two isolated exact-input
builds had different raw archive SHA-256 values
`789e267dcceb46c8efdb9ea2f25afdd474cea69b7c8c9bffa1e10b72b8bf2aab`
and `b9c6116b9c5c2ecb770321e6613f0b383d2a955fb7b5dbec9179b637a1bfd5aa`,
but canonicalized to the same final archive SHA-256
`c2c507b9355627e0ee2535e8328e47715212ea9075d50a96997fd3db2b8c34b6`.
Unexpected, reordered, duplicated, or changed members fail closed. A changed
canonicalizer/toolchain output also fails the final digest rather than silently
refreshing the pin.

Ourocode's own repository/distribution license is still unspecified. That is a
release-policy blocker independent of Ghostty's permissive license.

## Upstream API truth

The upstream distinction is mandatory:

| Surface | Public support at the pin | Ourocode policy |
| --- | --- | --- |
| [`include/ghostty/vt.h`](https://github.com/ghostty-org/ghostty/blob/136f436a3bbb14fd48d18e927a83fc6585d5a63c/include/ghostty/vt.h#L1-L42) | Public C API for VT state and related modules, but explicitly incomplete and unstable | Allowed only behind the Ourocode ABI and exact pin. |
| [`include/ghostty/vt/terminal.h`](https://github.com/ghostty-org/ghostty/blob/136f436a3bbb14fd48d18e927a83fc6585d5a63c/include/ghostty/vt/terminal.h#L1480-L1550) | Terminal create/feed/resize plus bounded options and effects | Used by the spike. |
| [`include/ghostty/vt/render.h`](https://github.com/ghostty-org/ghostty/blob/136f436a3bbb14fd48d18e927a83fc6585d5a63c/include/ghostty/vt/render.h#L22-L91) | Detached incremental render state with global and row dirty tracking | Suitable input to an Ourocode renderer; it does not draw pixels. |
| [`include/ghostty/vt/snapshot.h`](https://github.com/ghostty-org/ghostty/blob/136f436a3bbb14fd48d18e927a83fc6585d5a63c/include/ghostty/vt/snapshot.h#L22-L115) | CRC-protected progressive terminal snapshot; format v1 is work in progress | Wrapped behind Ourocode ABI v4 for exact-pin, incarnation-bound recovery only; never treated as a durable cross-version file contract. |
| [`include/ghostty.h`](https://github.com/ghostty-org/ghostty/blob/136f436a3bbb14fd48d18e927a83fc6585d5a63c/include/ghostty.h#L1-L7) | Internal macOS GUI glue; upstream says it is not a general embedding API and has one consumer | Forbidden dependency. It would couple Ourocode to Ghostty's GUI runtime and per-surface concurrency. |

The upstream README confirms both sides of the contract: the underlying
functionality is proven, but API signatures remain in flux and libghostty has
no tagged library version yet
([source](https://github.com/ghostty-org/ghostty/blob/136f436a3bbb14fd48d18e927a83fc6585d5a63c/README.md#L145-L170)).
The official Swift XCFramework example is a state/formatter example, not a
terminal view or Metal renderer
([source](https://github.com/ghostty-org/ghostty/tree/136f436a3bbb14fd48d18e927a83fc6585d5a63c/example/swift-vt-xcframework)).

## Why Zig matters, and what does not transfer

Ghostty did not choose Zig as a cosmetic performance claim. The transferable
architecture is:

- a portable core selected through compile-time interfaces, with native
  application runtimes at the edge;
- a C ABI static-library boundary so Swift can own the macOS lifecycle;
- explicit allocators and fallible operations;
- generated tables/types at compile time rather than runtime dispatch and
  duplicated platform data;
- build-time specialization without putting platform conditionals throughout
  the terminal core;
- measurement and conformance before claims of being “fastest.”

This is described in Hashimoto's
[Ghostty and Useful Zig Patterns](https://mitchellh.com/writing/ghostty-and-useful-zig-patterns)
and the native-product goal is explicit in
[Ghostty 1.0 Is Coming](https://mitchellh.com/writing/ghostty-is-coming).

What must not transfer is Ghostty.app's dedicated read, write, and render
threads per terminal. Upstream documents that model
([source](https://github.com/ghostty-org/ghostty/blob/136f436a3bbb14fd48d18e927a83fc6585d5a63c/README.md#L112-L117)).
Ourocode's fanout goal instead requires one broker reactor, headless offscreen
terminal state, and a fixed number of visible render surfaces.

The Superlogical direction reinforces the product boundary: a durable session
around work, reconnect from another device, native macOS/iOS and web clients,
composable structured actions, and production operability
([announcement](https://www.superlogical.com/),
[Hashimoto's note](https://mitchellh.com/writing/superlogical)). Ourocode can
apply those principles to its broker and MCP projections without claiming
Superlogical's unreleased implementation or turning Ouroboros semantic agent
sessions into fake PTYs.

## Audit of the current implementation

The current application is a useful bootstrap but does not yet implement the
architecture claimed by RFC 0001:

1. `OurocodeDesktop` still links SwiftTerm directly for terminal state and
   rendering. The experimental `ouro-broker-v4-ghostty` binary now owns the
   exact-pin Ghostty engine before PTY spawn, applies original PTY bytes and
   resize events to that same engine, and recovers from an immutable checkpoint
   plus raw ordered tail. The Swift app has not yet adopted Ghostty render state,
   so this is broker integration rather than a production engine replacement.
2. Only the selected tab enables SwiftTerm Metal, which is directionally
   correct. However, each enabled `MetalTerminalRenderer` creates its own
   command queue, pipelines, grayscale/color atlases, shaper cache, and glyph
   caches. The RFC's one global glyph atlas and four-surface global budget do
   not exist yet.
3. `AccessibleTerminalView` now keeps 500 scrollback lines, disables advertised
   Sixel support, and caps the Kitty image cache at 4 MiB per visible adapter.
   This removes the immediate 320 MiB-per-tab default, but it is not the target
   process-global atlas/image budget.
4. SwiftTerm's narrow/widen defect remains open as
   [issue #494](https://github.com/migueldeicaza/SwiftTerm/issues/494). The
   pinned `Buffer.swift` still skips the cursor line and performs in-place
   reflow plus post-reflow truncation. A successful shell/zombie smoke does
   not prove content preservation.
5. The recorded 49.9 MiB one-tab and 50.9 MiB eight-tab footprint is useful,
   but it is one machine/sample, does not exercise scrollback or graphics, and
   has no same-workload Ghostty comparison. Gate 0 is therefore not complete.

Regardless of the final engine, cap SwiftTerm's image storage immediately in
the bootstrap and never treat a protocol's documented maximum as a global
application budget.

## Bootstrap canonical recovery lane

The runnable broker now embeds exact Cargo pin `vt100 = 0.15.2`, which uses
`vte`, for one narrow responsibility: reconnect recovery must never replay an
arbitrarily truncated PTY byte tail. Every PTY read is parsed in the broker.
Live output and delta resume remain byte-for-byte raw, but the broker emits
those bytes only at a parser-neutral UTF-8/CSI/OSC/DCS boundary. A partial
Unicode scalar or escape string remains broker-owned until its suffix arrives.
An oversized unterminated control string is bounded; at its eventual
terminator the broker emits a hard reset plus canonical resync instead of a
suffix detached from its prefix.

Reset recovery is an explicit wire contract:

- `format = "ansi_replay"`;
- `scope = "viewport"`;
- `snapshot_version = 1`.

The Swift client rejects unknown format, scope, or version and therefore
cannot mistake legacy raw history for a reset snapshot. Version 1 reconstructs
the visible main viewport, active alternate grid, cursor, supported cell
styles, title, and supported input modes. While alternate screen is active it
also reconstructs the inactive main viewport so a later `1049l` returns to the
correct visible main state.

This contract does **not** include scrollback. `vt100::state_formatted()` only
projects the visible viewport, and version 1 deliberately says so. It also
does not claim Kitty graphics, sixel, every DEC mode, or Ghostty extension
parity. The broker therefore retains zero hidden `vt100` scrollback rows by
default instead of paying memory for state the wire cannot recover. The lane
is bootstrap-only; production canonical scrollback and full
terminal semantics remain part of the exact-pin `libghostty-vt` promotion
gate. Tests cover split UTF-8, CSI and OSC, alternate screen, cursor/styles,
resize, bounded hostile control strings, and viewport recovery after output
far exceeds the former raw-history budget.

## Implemented Gate 0 artifact

The following experiment code is checked in:

- `spikes/libghostty-gate0/include/ouro_terminal_engine.h`: sized and
  versioned Ourocode ABI with opaque engine state, bounded complete snapshot
  export, and fail-closed restore;
- `spikes/libghostty-gate0/src/ouro_ghostty_adapter.c`: the sole source file
  that includes unstable Ghostty headers;
- `crates/ouro-terminal-ghostty`: safe Rust ownership wrapper linked to the
  exact static archive path;
- C and Rust conformance tests for bounds, VT/Unicode, render-state metadata,
  ABI rejection, a narrow/widen regression shape, full scrollback/main/alternate
  snapshot round trips, CRC/truncation rejection, and grounded byte-for-byte
  canonical re-encoding.

The adapter explicitly configures scrollback bytes/lines, Kitty image bytes,
APC bytes, and continuation bytes. Kitty images are disabled in the default
Rust config until the application has a process-global budget. The diagnostic
plain-text projection is not a renderer or persistence format.

ABI v5 removes persistent `GhosttyRenderState` ownership from `OuroTerminal`.
A headless broker terminal therefore pays no retained render-state, row
iterator, or cell-iterator allocation. A caller explicitly creates one opaque
`OuroRenderProjection` only for the terminal mirror it intends to draw. The
projection owns a local monotonic generation, one stable render allocator and
hard cap, and allows one outstanding frame. A checked transactional rebind
builds replacement render resources under that same combined cap, preserves
the old binding on failure, and forces a full frame on success. The safe Rust
`OwnedRenderProjection` consumes its terminal and can replace it without a
self-referential borrow or lifetime transmute.
Its sized C records copy the following public Ghostty data without exposing an
upstream pointer or internal `ghostty.h` type:

- global/full/partial dirty state, dimensions, palette, default colors, and
  complete cursor metadata;
- row dirty, selection, wrapping, and prompt semantic metadata;
- cell position and width, caller-owned UTF-8 grapheme bytes, selection,
  hyperlink presence, prompt/input/output semantics, style flags, underline
  kind, and tagged default/palette/RGB foreground, background, and underline
  colors.

Frame acknowledgment is transactional. `COMMITTED` clears dirty state only
after every row and cell has been drained and losslessly merged into the
renderer-owned full CPU row cache; it never means GPU submission or on-screen
presentation. An early commit attempt is rejected and forces a full redraw.
`DROPPED`, allocation failure, and RAII drop preserve invalidation. A later
Metal failure retries from the CPU cache. `BUFFER_TOO_SMALL` reports the
required grapheme length and retries the same cell rather than advancing the
iterator. Rust uses caller-reused scratch with fallible growth, rejects a
non-growing retry, and enforces a configurable bound up to 256 bytes per cell.
The C contract requires the borrowed terminal to outlive the projection and
serializes terminal mutation with projection use; the Rust wrapper enforces
that lifetime and exclusive access. The legacy `frame_info` helper now creates
only an ephemeral diagnostic render state and is explicitly forbidden as the
product render loop.

This is the input boundary for a renderer, not a renderer. The app still needs
one disposable active mirror, at most one recovery candidate, one retained
projection, and one shared Metal surface. The default bundled broker and DMG
remain the honest SwiftTerm bootstrap until that lane passes.

The repository now also carries the exact-pin upstream candidate patch
`spikes/libghostty-gate0/patches/0001-shared-page-budget.patch`. It adds a
Ghostty-owned atomic shared `PageBudget`, charges the actual OS-page-rounded
mapping size before allocation, rolls reservations back on child failure,
retains the mapping charge across decommit, exposes terminal-local failure
epochs, and performs hostile snapshot page layout with checked component and
alignment arithmetic before allocation. Live terminals and snapshot decoders
can retain the same explicit budget handle; no process-global static counter
or allocation-hot-path callback is used.

Focused verification passed 6/6 direct PageBudget cases, 57/57 lazy-alternate
exact-cap cases, 55/55 OS-page-rounded C cases, and 39/39 static-build cases,
plus strict C conformance and diff checks. The Ourocode adapter and safe Rust
wrapper now create and retain an opaque shared budget, use it for both new and
restore, and compare terminal-local failure epochs around feed, resize, and
compression. `GhosttyEngineFactory` shares one budget across broker create and
restore paths. This is reproducible page-mapping admission evidence, not a
production promotion or a process RSS hard cap.

## Recorded build spike

Host: Apple Silicon macOS 26, Command Line Tools active, Swift 6.3.2. Full
Xcode is not selected.

| Check | Result |
| --- | --- |
| Ghostty source HEAD | `136f436a3bbb14fd48d18e927a83fc6585d5a63c` |
| Zig | downloaded 0.16.0 archive; digest matches the ledger |
| `zig build -Demit-lib-vt=true -Demit-xcframework=false -Doptimize=ReleaseFast` | PASS |
| Produced static archive | PASS; about 10 MiB before final app dead stripping |
| Produced shared library | PASS; about 1.8 MiB |
| Standalone C compile/static link | PASS; no `libghostty-vt.dylib` load command |
| C conformance | PASS |
| Rust debug and release tests | PASS, 1 test each |
| Ourocode snapshot/accounting/compression ABI v4 C conformance | PASS; ABI v3 struct layouts preserved, styled CJK/emoji/combining, OSC 8, main/alternate, scrollback, reflow, unfinished continuation, corrupt/truncated/oversized rejection, allocator-mediated failure/reclamation, typed incremental compression and content/snapshot identity |
| Ourocode snapshot/accounting/compression ABI v4 Rust tests | PASS, 6 default tests; 7 with the benchmark-only full-compression Cargo feature |
| Ourocode shared PageBudget Rust adapter | PASS, 9 tests |
| Ourocode detached render projection ABI v5 | PASS; C11/C++17 layout gates, C conformance, safe owned/rebind projection, CPU-cache commit semantics, bounded Rust scratch/invalidation/grapheme retry; terminal crate 12/12 |
| Broker Ghostty shared factory | PASS, 1 focused test; create and restore use one budget |
| Broker manifest ABI source | PASS; imports the terminal crate's public ABI constant rather than duplicating `5` |
| ABI v3 accounting probe, 24×6 and 96 history lines | create minimum 12,332 B; source live 18,604 B / peak 23,139 B; restore minimum and peak 293,917 B; restored live 18,604 B; failed oversized resize returned to baseline with two denied callbacks |
| ABI v4 ASan + UBSan conformance | PASS (`detect_leaks` is unavailable in Apple's ASan runtime; all adapter release paths additionally assert zero requested live bytes before destroying allocator context) |
| Rust test binary linkage | PASS; only `/usr/lib/libSystem.B.dylib` is dynamic |
| Minimal C probe peak footprint | 1,933,624 bytes; max RSS 3,162,112 bytes |
| Default XCFramework build | BLOCKED: `xcodebuild -create-xcframework` exits 1 because only Command Line Tools are selected |

The 1.9 MiB probe number is evidence that a single tiny headless test is
possible. It is not an incremental-session measurement and must not be used to
claim that the app beats Ghostty or SwiftTerm.

Snapshot ABI v2 added a 16 MiB default source/export ceiling and reapplies the
caller's scrollback, image, APC, and continuation policies after restore. The
pinned public decoder validates CRC records through `FINISH`, supports a
renderable `READY` prefix followed by progressive history pages, and restores
complete terminal state. The adapter additionally rejects trailing bytes.
ABI v3 added one allocator for terminal, render state, formatter, and snapshot
decoder. It rejects allocation growth before the underlying allocator when the
32 MiB default hard ceiling would be exceeded and reports exact requested-byte
live/peak/failure accounting for allocations routed through that allocator.
ABI v4 allocator accounting by itself is not a complete engine-memory ceiling:
the exact pin backs terminal pages with direct tagged `mmap` regions outside
`GhosttyAllocator`. The checked-in candidate patch and adapter integration now
supply pre-allocation shared page admission for live and decoded Ghostty pages.
The cap covers Ghostty-owned page mappings, not renderer atlases, ordered tails,
client queues, allocator-mediated payloads, or total process RSS. Those remain
separate budgets. Snapshot format v1 also has no compatibility guarantee.

The physical fanout probe makes that boundary concrete. With 32 terminals,
120×40 grids, 10,000 styled Unicode lines each, and an 8 MiB scrollback limit,
requested allocator live bytes totaled 893,504 while `phys_footprint` reached
268,698,176 bytes. `vmmap` attributed about 252 MiB to Ghostty's direct terminal
page mappings. Limits of 256 KiB, 512 KiB, and 1 MiB all reached the same page
granularity floor of about 31 MiB process footprint, or roughly 864 KiB of
direct page mapping per terminal. The result is bounded policy cost, not a
leak, but it disproves using allocator requested-byte counters as an RSS claim.

ABI v4 preserves the v3 config/frame/memory layouts and exposes the exact pin's
opaque compression-activity token plus one typed, bounded incremental step.
Callers serialize each step with terminal mutation and continue only while the
reactor is idle. Full synchronous compression is named test-only in C and is
absent from normal Rust builds unless the explicit benchmark Cargo feature is
enabled.

ABI v5 preserves those terminal/config/snapshot/accounting responsibilities
and adds only the separated render ownership above. The v5 C/Rust suite and
the Ghostty-feature broker suites pass (terminal 12, broker unit 6, v3
integration 12, v4 integration 18, terminal-state 9). The experimental broker
binary links `libiconv` and `libSystem` only; it has no dynamic Ghostty load
command.

In the 32×10,000-line, 8 MiB-per-terminal workload, 704 incremental steps took
52 ms total and preserved the logical projection and canonical snapshot. They
reduced `phys_footprint` from 268,239,424 to 28,475,968 bytes (89.38%) and
converted 262,144,000 bytes of direct page backing to reclaimable mappings.
Allocator live bytes rose from 893,504 to 8,762,186 because compressed payloads
are allocator-mediated. Raw RSS rose because it includes clean retained virtual
mappings; it is not the physical-memory release gate. Selected sessions should
receive a larger history policy than offscreen sessions, and incremental work
must remain an idle-slice policy rather than a PTY or frame hot-path action.

The pin's VT write API returns `void`. The Ourocode v4 adapter therefore samples
the allocator failure counter before and after every non-empty feed. An
increase returns `OUT_OF_MEMORY`; because an arbitrary prefix may already have
mutated the engine, the caller must discard that state and recover from the
last immutable checkpoint plus ordered event tail rather than retrying the same
bytes. Literal tiny-budget C and Rust tests force an OSC 8/Unicode allocation
failure and verify this contract. Empty input remains a successful no-op. If
the saturating failure counter has already reached its maximum, mutation is
rejected before the write because success could no longer be proven.

The pin also revealed an upstream ABI documentation defect: `allocator.h`
describes alignment as byte values 1..16, while `allocator.zig` passes the
`std.mem.Alignment` log2 enum encoding 0..4. The adapter is intentionally bound
to the observed exact-pin encoding and validates returned pointers. A future
pin must re-run this gate rather than assuming source compatibility.
Protocol v4 therefore still needs the bounded two-phase chunk stream, pin and
format manifest, and atomic client commit specified in
[RFC 0004](0004-broker-v4-recovery.md) before an input lease is issued.

The installed `/Applications/Ghostty.app` is 1.2.3, while upstream's current
application tag is 1.3.1. No comparison against that installed binary is a
“latest Ghostty” result.

## Gate 0 experiment and thresholds

All candidates consume the same timestamped PTY byte recordings, use a 120×40
grid, the same font/size, and identical scrollback and image limits. Debug
builds are excluded.

### Engine-only lane

Run SwiftTerm headless and the pinned libghostty adapter at 1, 8, and 32
terminal states for:

- empty shell and zero scrollback;
- 10,000 short lines;
- a bounded `yes` flood with UI/reactor backpressure;
- tmux, vim alternate screen, OSC 133 prompt, Kitty keyboard/mouse, true color,
  combining marks, CJK, emoji grapheme clusters, BiDi, and Kitty image rejects;
- 100 cycles of 120→20→120 resize with logical-content hash comparison;
- allocation-failure injection at every adapter allocation point.

Record custom-allocator live/high-water bytes, direct page-mapping statistics,
`phys_footprint`, private dirty, `vmmap -summary`, CPU time, parser throughput,
resize p99, compression latency, and thread count. Raw RSS is diagnostic only:
on macOS it includes clean decommitted mappings that do not contribute to the
same physical-footprint charge.

Engine promotion requires:

- zero content mismatches and no stale render-state access;
- no crash or unbounded queue under malformed/oversized escape input;
- zero-scrollback incremental retained memory ≤ 0.75 MiB per headless state;
- 32×10,000-line app-core footprint ≤ 150 MiB;
- fixed runtime thread count independent of terminal count;
- parser throughput no worse than SwiftTerm by more than 10%, unless a measured
  end-to-end latency win justifies it.

### One-surface native lane

Build exactly one `NSView`/`MTKView` backed by the public render-state API. The
view owns CoreText shaping/rasterization, IME marked text, selection, paste,
mouse/key encoding, accessibility, and damage-to-frame scheduling. It reuses a
process-global Metal device, pipelines, and bounded atlas.

Promotion requires tmux/vim/ssh and Korean IME correctness, Retina pixel
tests, `keyDown` to presented-frame p99 < 8 ms during eight headless PTY
producers, idle CPU < 0.5%, and zero Metal buffers/atlas ownership for an
offscreen terminal.

### Full-app lane

Only after the first two lanes pass, put one terminal tab behind an explicit
engine flag and compare:

- SwiftTerm bootstrap;
- pinned libghostty adapter plus Ourocode renderer;
- Ghostty.app v1.3.1 with an equivalent config.

Measure cold/warm launch, one/eight/32 sessions, close-to-baseline memory
return, GPU VM regions, app/broker/shell processes separately, and codesigned
release size. Three cold runs plus ten warm runs are the minimum; report the
raw samples, median, p95, and device/OS/build identifiers.

## Smallest next real spike

1. Add the one-surface native lane, not more tab chrome or MCP decoration. Use
   only public render-state iterators and input encoders.
2. Inject/recognize OSC 133 prompt redraw before judging interactive resize;
   libghostty intentionally does not assume the embedder installed Ghostty's
   shell integration.
3. Measure the experimental broker with the same timestamped PTY recordings at
   1, 8, and 32 sessions, including recovery and idle compression, while
   reporting Ghostty page admission separately from physical footprint.
4. If the thresholds pass, replace one tab behind a launch flag. Keep the
   SwiftTerm fallback until selection, IME, accessibility, graphics, and PTY
   lifecycle parity pass.

## Current blockers

- Full Xcode is required to produce and validate the upstream XCFramework.
- Public libghostty API signatures and snapshot format are unversioned and
  unstable; the Ourocode ABI and exact source/toolchain pin are mandatory.
- No Ourocode Metal/CoreText renderer exists for the public render state.
- Renderer atlas, global logical-history/client-queue budgets, and production
  app adoption do not exist yet. The experimental Ghostty broker has bounded
  page admission and complete checkpoint-plus-raw-tail recovery, while the
  default SwiftTerm bootstrap retains its narrower viewport recovery contract.
- The current machine lacks latest Ghostty.app for an honest full-app baseline.
- Ourocode's distribution license and complete third-party SBOM are undecided.

These are work items, not reasons to adopt the internal `ghostty.h` API or to
declare SwiftTerm production-ready.
