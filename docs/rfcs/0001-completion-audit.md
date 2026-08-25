# RFC 0001 completion audit

- Audit date: 2026-08-16
- Rule: a requirement is complete only when the current artifact proves the user-visible outcome. A fixture or interface contract does not prove a production integration.

| Requirement | Current evidence | Verdict | Missing proof |
| --- | --- | --- | --- |
| Terminal-first native desktop app | AppKit application, broker-owned real PTYs, exact-pin Ghostty ABI v6 development surface, normalized keyboard/text/paste/focus receipts, local IME preedit, one Metal surface, 32 tabs, DMG | Proven development candidate | Long-run conformance, physical-trackpad scroll gate, compiled-metallib release build, Developer ID and notarization |
| General MCP v2 source browser | Typed 16-source registry, negotiated protocol/capabilities, bounded paginated tools/resources/prompts, reconnect generation isolation, production-one/demo-two registry, and a deterministic Local Notes MCP v2 provider fixture | Proven provider-neutral core and UI registry | Production add/remove/configuration UI and a second installed external provider remain |
| Show every Ouroboros fanout session | Exact Ouroboros 0.51.5 MCP v2 (`2025-06-18`) shared launchd service; live initialize returned `serverInfo.version=0.51.5`; compact hierarchy; exact Final2 Computer Use expanded `Sessions 2`, selected `Gen 10` on the first click, and showed Started/Completed/Run finished; two-line identifier rows and compact read-only state | Partial | Upstream still needs a compact cursor/delta projection instead of the approximately 2.29 MiB full resource; live running-child steering remains fail-closed until authority is wired |
| Direct steering between sessions | Exact attempt discovery, strict Swift request/status/receipt model, same-nonce uncertain recovery, Rust authenticated gateway, principal registration ACK ABI, bounded stop-and-wait coordinator, and authority-gated compact UI. Timeout contract: 1 s socket / 5 s attempt / 64 KiB receipt; see below. | Scaffolded and fail-closed | Signed installer trust root, reciprocal verified Ouroboros peer, real inherited-FD service handlers, broker lifecycle wiring, and live A-to-B Claude/Codex delivery |
| Terminal multiplexing with low memory | One disposable app projection and one Metal surface; one-thread Rust PTY broker; five keyed/reused AppKit tab buttons. Current hash `e9fcd298…` completed an exact 70 ms-paced 32→1→32 Close Tab/Reopen cycle without terminating or replacing any of the 32 zsh PIDs. The sum of per-PID median physical footprints was 319.326 MiB at one view and 318.967 MiB after all 32 views returned: app 63.907→63.548 MiB, broker 10.563 MiB, shells 244.856 MiB (`/tmp/ourocode-{close-one,close-return}-e9fcd298.*`). | Current warm 32-session projection and close-return proven | AppKit split surfaces, lifetime peak, syscall profiling/kqueue, and equivalent live Claude/Codex/Warp workloads remain. The measured process-set sum is not unique host memory, and the 32 zsh processes account for most of it; agent-process and MCP-host deduplication remain separate release gates. |
| Sessions survive UI restart and support mobile views | Broker-owned PTY survives AppKit exit; mode-0600 UDS; v3 lifecycle compatibility; v4 manifest-bound 64 KiB two-phase recovery, ordered raw PTY/resize state, immutable `C+tail` engine replay, partial-prefix failure replacement, expiry/pin/global checkpoint bounds, atomic Swift import, post-commit lease, and exact-lease detach that preserves PTY/canonical state while suppressing every post-reply live event; real bundled-helper plus exact-pin Ghostty E2E | Exact-pin broker ownership, recovery, and detach contract proven; Ghostty/Metal is the source-level default and SwiftTerm is explicit compatibility only | Build the current source with compiled `metallib`, move worst-case restore off the reactor, add launchd supervision, pairing, and encrypted mobile transport |
| Ghostty-quality terminal correctness | Exact `libghostty-vt` pin, static C/Rust adapter, bounded state, one app-side Metal projection, normalized input, actual Korean 2-Set preedit and exact final commit, real CGEvent tab-picker activation, tab overflow cues, and 32-tab V7 app run ([RFC 0002](0002-libghostty-gate0.md)) | Development gates substantially passed; product promotion remains incomplete | Scroll promotion requires a real HID trackpad on the exact app hash, with IOHID event observation proving the hardware gesture reached AppKit and a visible scrollback displacement; CGEvent/SMB injection alone is insufficient. vim/tmux/ssh/Kitty suite, lifetime-peak reduction, and packaged compiled Metal library remain. |
| Warp-informed semantic terminal | Real `zsh -l -i`; startup files sourced once; OSC 133 prompt/input boundaries carried in existing GPU cell flags; edge-to-edge terminal; bounded five-tab projection with searchable full index; engine-native bounded full-scrollback Find; identity-safe top-origin row reveal; secure on-demand OSC 8; bounded visual/audible/VoiceOver bell; quoted non-executing Finder path drop; immediate bounded text-size HUD for `⌘+`, `⌘−`, and `⌘0`, including min/max/default state and reduced-motion behavior | Partial, live development UI proven | Semantic session identities/groups and alternate-screen/Increase-Contrast release evidence remain; Find currently navigates rows without an inline match highlight. |
| Frugal smart model routing | Ouroboros explicit `smart_routing=true`, runtime capability preflight, durable `routing.decided`, one-use CAS effect claim immediately before direct/parallel provider entry, signed bounded Ed25519 snapshot, real MCP read-only tool and initialize capability; routing/MCP/runner/parallel tests pass. Ourocode now pins, launches, and negotiates the exact 0.51.5 isolated MCP v2 shared-service contract. Timeout contract: 1 s socket / 5 s attempt / 64 KiB receipt; see below. | Implemented upstream and deployed shared-service contract; live provider proof pending | Run one low-complexity Claude task and one high-complexity Codex task with real credentials; provider effect, signed receipt, and MCP readback must agree, while omitted opt-in remains dormant. |
| Beautiful and safe installer | Dedicated icon, accessible `Install Ourocode` Finder title, deterministic 660×420 window with 1320×840/144dpi Retina background, one-way app→Applications mapping, verify-before-replace atomic output, checksum validation, and fail-closed production codesign/notary gates including an explicit `Developer ID Application:` identity-class check. Canonical `Ourocode-0.1.0-dev.dmg` was remounted, checksum/deep-signature verified, matched app hash `e9fcd298…`, and passed Luna Finder review. | Exact local development installer proven | Public release still requires Developer ID credentials, notarization, stapling, stable macOS TCC identity, and final Rams review of the signed payload. |
| Accessibility and keyboard control | Native outline, radio-tab AX, full labels/help, focus commands, reduced motion, 16 KiB UTF-8-bounded retained viewport projection; partial damage preserves semantic command rows; Korean IME and all-tabs pointer paths are repaired; tab-slot reuse now carries stable UUID identity, posts AX layout changes, and rejects stale focus restoration by projection generation. Exact 2026-08-16 Computer Use selected Shell 32 from the full picker and re-opened Find and Settings; OSC 8 failed opens are consumed with feedback and coalesced Bell announcements interpolate the real count. | Proven on the current Ghostty development artifact | Physical-trackpad scrolling and final signed-artifact accessibility audit remain |

## Current critical path

1. Complete the trusted session-mutation composition. The next auditable milestone is an inherited-FD handler accepting one synthetic broker-owned socket and returning an authenticated steering receipt without live Ouroboros; only after that gate add the verified service peer, broker/app wiring, and live signed A-to-B delivery.
2. Prove live terminal scroll with physical hardware, integrate the split core into AppKit, run vim/tmux/ssh/Kitty, and reduce cold-start/lifetime peak memory; the warm 32-to-1 Close View return gate now passes.
3. Exercise the wired Shared MCP Preview/phrase-gated Apply UI on an explicitly supported registration, then prove the host reconnects to the shared service without terminating unrelated live processes. Missing Claude registration remains a non-actionable fail-closed state.
4. Replace the heavy all-session Ouroboros resource with a compact cursor/delta contract before claiming complete fanout under load.
5. Run current upstream Ouroboros smart routing with real Claude/Codex credentials and match provider effect to the signed MCP receipt.
6. Build with full Xcode compiled `metallib`, Developer ID sign, notarize, staple, and obtain exact-hash Luna/Rams approval before public distribution.

Evidence attribution rule: every row above that names “current” or “canonical”
refers to the 2026-08-16 app hash `e9fcd298…` and its broker-compatible source
tree. Rows that cite `86bf51e8…`, `227369e2…`, Final2, the historical development DMG, or earlier perf
artifacts are explicitly historical and do not transfer a verdict to the
canonical hash.

Steering timeout contract: the future inherited-FD handler and stop-and-wait
coordinator must enforce a 1-second socket read/write deadline, a 5-second
whole-attempt deadline, and a bounded receipt body of 64 KiB. Timeout, peer
loss, malformed receipt, or lifecycle generation mismatch must return a typed
delivery-uncertain/fail-closed result and must never retry the user message.
If recovery is cancelled during candidate import, the partial candidate is
discarded before post-commit lease and the prior committed checkpoint remains
authoritative; the next attempt must recover again from that checkpoint.

## Ouroboros QA result

> **NOTE: This score evaluates audit-document quality and honesty only. It is
> not a product-release pass verdict.**

- Tool/version: `ouroboros qa` from `ouroboros-ai[mcp]==0.51.5`
- Session: `qa-2fcbfb1c`
- Iteration 1: `0.87 / 1.00`, PASS at threshold `0.80`
- Same-session refinement checks: `0.85` PASS, then `0.84` PASS after evidence-attribution and timeout-contract clarifications
- Current fallback judge: session `qa-65527af3`, iteration 1, `0.93 / 1.00` PASS at threshold `0.80`, using the canonical Ouroboros 0.51.5 `qa-judge.md` after acting verification. The isolated provider subprocess was stopped after returning no verdict for 60 seconds, so this is explicitly a local fallback judgment rather than a remote-model result.
- Scope: development-stage completion-audit quality and honesty. This is not a claim that the product-release blockers above are complete.

## 2026-08-16 canonical development evidence

- Exact app: `apps/macos/OurocodeDesktop/.build/Ourocode.app`
- App executable SHA-256: `e9fcd298ac3a324b8266f1f17c02f106f55e9cb1ef6100e7f1dc4dd6a4ceaba1`
- Exact local installer: `apps/macos/OurocodeDesktop/dist/Ourocode-0.1.0-dev.dmg`, SHA-256 `b7b74167fe2a073f3b544722d66f1bf39c5d34a4a1d3fc135a1feac498a66d11`, 7,642,574 bytes. A read-only remount passed HFS checksum and deep/strict signature verification; the contained executable SHA-256 is the canonical `e9fcd298…` value. Luna approved the 660×420 `Install Ourocode` Finder layout with the Ourocode → Applications mapping; evidence: `/var/folders/60/x3f084654915g9v4ht0g454c0000gn/T/com.openai.sky.CUAService/Finder Screenshot 2026-08-16 at 3.49.25 AM.jpeg`. This remains explicitly ad-hoc `-dev.dmg`, not a notarized release.
- The UI-only process was replaced with PID `9804` while broker PID `99420` and all 32 broker-owned `/bin/zsh -l -i` sessions remained alive; the rebuilt app restored every session. That preserved-session run used the long-lived compatibility broker at `.build/dev-ghostty/Ourocode-Ghostty-Dev.app/...`, SHA-256 `450de81f368c754738002bda5c2891c0b432e8b26a96bdd89a725a10e6e911d5`, not the freshly packaged helper.
- Computer Use opened the searchable 32-session picker and activated its Shell 32 cell; the visible five-tab window moved to tabs 28–32 and exposed Shell 32 as selected.
- Computer Use on fresh Shell 19 observed `2 command rows are available`, invoked `Read next command row` and `Read previous command row`, enlarged the terminal with `⌘+` without wrapping the right prompt, and restored the baseline with `⌘0`.
- The identity/generation-safe tab focus, interaction-safety, bounded tab-window, Find/accessibility/hyperlink/command-AX fixes passed Apple interaction review on preceding hash `86bf51e8…`; those sources are unchanged in the current build. The full picker exposed Shell 32 and a direct cell click selected it.
- Current-hash Computer Use showed rapid `⌘+` converging on `19 pt`; the HUD is one reused pointer-pass-through, layer-backed view with a separate VoiceOver announcement, stale-fade generation guard, and reduced-motion path. Clicking through the visible HUD retained terminal focus.
- Current-hash Computer Use switched directly from Shell 1 to Shell 2, restored its existing `zsh -l -i` screen, selected terminal text by dragging, and displaced live scrollback. A focus transition no longer invalidates unchanged pointer geometry; the transient `Pointer paused · syncing` status clears through a level-triggered readiness handshake.
- Independent Luna Computer Use on the exact `e9fcd298…` artifact re-ran rapid zoom → `⌘0` → HUD-center-click; after 1.6 seconds there was no lingering pointer-sync status, and drag selection, scroll, Shell 2 tab selection, terminal focus, and direct `qa-steer` input remained valid. Evidence screenshots are in `/var/folders/60/x3f084654915g9v4ht0g454c0000gn/T/com.openai.sky.CUAService/` (`Ourocode Screenshot 2026-08-16 at 3.40.47 AM.jpeg`, `3.40.58 AM.jpeg`, `3.41.07 AM.jpeg`, `3.41.18 AM.jpeg`, `3.41.33 AM.jpeg`, `3.41.43 AM.jpeg`).
- `test-terminal-accessibility-projection.sh` proves partial-frame row/selection/OSC 133 retention and hard 16 KiB UTF-8 budgets for value, selection, and command navigation.
- Computer Use proved `⌘F`, `⌘G`, and `⇧⌘G` moved through five live matches; `⌘,` exposed synchronized 12–48 pt text and visual/audible bell controls; `⌘+` changed Settings from 16 to 17 pt and `⌘0` returned it to 16 pt.
- Current exact-hash close-return: 11 successful samples at one visible view and 11 after all 32 views were reopened. App median physical footprint moved from 63.907 MiB to 63.548 MiB; broker stayed 10.563 MiB and the 32 shells stayed 244.856 MiB. The sum of per-PID medians moved from 319.326 MiB to 318.967 MiB; it is a measured process-set sum, not unique host memory or the median of a per-sample aggregate. All 34 executable/start identities matched, file descriptors stayed at 11, and app threads ranged 6–14 and 5–14. Evidence: `/tmp/ourocode-{close-one,close-return}-e9fcd298.*`.
- An earlier unpaced 31-close stress run exposed a real `OURO_RENDER_CLIENT_BUSY` cutover failure: a superseded Metal presentation had settled as RETRY and kept candidate commit blocked. The final explicit retry-cancel ABI preserves BUSY for an outstanding lease, abandons only the superseded retry after lease settlement, and is covered by a Rust regression test. On exact hash `e9fcd298…`, Luna then completed exact 70 ms-paced 31-close and 31-reopen passes (`32→1→32`) with focus intact and no ABI 6/render-bridge error; the broker and every zsh identity remained unchanged. Evidence: `Ourocode Screenshot 2026-08-16 at 3.43.15 AM.jpeg` and `3.43.28 AM.jpeg` in the CUAService screenshot directory.
- Historical preceding-hash close-return (`227369e2…`): app physical footprint 60.923 MiB at 32 views and after closing 31 views; broker 10.766 MiB in both phases; all 34 sampled target identities matched, and no PTY was terminated.
- The latest `ooo qa` command was attempted through the exact 0.51.5 isolated package. Its default 0.51.1 CLI failed on a deprecated Claude model, while the 0.51.5 QA subprocess selected the current Claude model but stalled without returning a verdict; no new automated score is attributed to this run. The earlier same-session QA PASS remains an audit-document score, not a product-release claim.
- The exact Ouroboros 0.51.5 launchd service negotiated MCP `2025-06-18`. Its Python process settled from a roughly 230 MiB database-startup RSS to roughly 29 MiB RSS after initialization; this service memory is measured separately from the terminal host tree.

## 2026-08-13 Final2 development evidence

- Exact app: `apps/macos/OurocodeDesktop/.build/dev-human-tabs-final2-20260813/Ourocode-Ghostty-Human-Tabs-Final2.app`
- App executable SHA-256: `443ff3e8afd922a50c66517a3341bf951ffed0395c5efe2113a95fe9131ea481`
- Broker executable SHA-256: `de893d1004ae990bfce83a43153ddef204e15f0e8cd4c8e2ff73d9a238a50be1`
- Computer Use: [connected/collapsed](../../apps/macos/OurocodeDesktop/qa-evidence/luna-final2-connected-collapsed-20260813.png), [sessions expanded](../../apps/macos/OurocodeDesktop/qa-evidence/luna-final2-sessions-expanded-20260813.png), and [first-click activity detail](../../apps/macos/OurocodeDesktop/qa-evidence/luna-final2-session-detail-20260813.png).
- The exact app restored all 15 broker-owned zsh PTYs after two UI-only restarts. A real tab click selected tab 2; the retained shell displayed `v2-shell:5.9:on:on:on:/bin/zsh`, proving login, interactive, and RCS state with the user's `.zshrc` prompt visible.
- Exact five-second 15-tab sample: app 70,124,552 bytes, broker 7,766,424 bytes, shells 121,034,632 bytes, full measured tree 198,925,608 bytes (189.71 MiB). Evidence: `perf-human-tabs-final2-exact-15-tabs-20260813.*`.
- This is a development artifact. It does not replace the signed/notarized production gate or prove physical-trackpad scroll, split surfaces, live session mutation, or equivalent Claude/Codex/Warp memory.

## Ouroboros layer fanout audit

A read-only 2026-08-16 re-audit of the live shared endpoint negotiated MCP
`2025-06-18` and returned `serverInfo = ouroboros-mcp 0.51.5`. `tools/list`
returned 36 tools and included `ouroboros_session_signal_targets`,
`ouroboros_session_signal`, and `ouroboros_query_projection`; it did not expose
an `ouroboros_query_sessions` tool. Tool presence is not local mutation
authority. The 0.51.5 compact lifecycle index still creates groups with
`tabs: []`; active targets are a lazy authority overlay, completed fanout
children are absent, and logical projection rows lack the exact scope/attempt
identity required for a retry-safe join.

The 2026-08-10 v0.51.1 transport audit also proved that a fixed loopback port
is not service identity: another same-user process can win `127.0.0.1:8976`,
forge MCP `serverInfo`, sessions, and steering targets, and receive steering
text. Automatic release connection therefore remains gated on a launchd-owned,
mode-`0600` UDS with peer UID verification behind the broker. An explicit
fixed-port endpoint is development/operator trust only.

The installed base v0.51.1 environment did not include the optional MCP SDK;
its exact console script correctly exited with the official isolated `[mcp]`
profile guidance. A live exact-version `uvx --isolated` HTTP profile negotiated
MCP `2025-06-18` and exposed the expected resources, but repeated full-session
reconstruction drove roughly 290--476 MiB physical footprint and an observed
828 MiB lifetime peak. The client must not create that runtime in the background
or per window. Sessions observation, catalog enumeration, and exact target
resolution are now demand-driven by visible/expanded UI; this reduces demand
but does not replace the missing upstream compact session cursor/delta contract.

A live process-tree audit on 2026-08-09 found 184 `ouroboros mcp serve`
processes with approximately 2.3 GiB aggregate RSS; 101 had already been
reparented to PID 1. Only one process listened on the shared Ourocode endpoint
at `127.0.0.1:8976`. The active Codex configuration launches Ouroboros through
an stdio `uvx --from ouroboros-ai[mcp]` command, and Claude configurations also
contain stdio Ouroboros commands. This means opening many Codex/Claude sessions
can multiply complete Python MCP runtimes even though Ourocode itself connects
to one shared HTTP service.

A PID-pinned six-sample `phys_footprint` run on 2026-08-10 measured the then-current
13-tab development window with one idle Claude Code tab. The Ourocode host tree
(AppKit app, one-thread Ghostty broker, and thirteen zsh processes) was
241,949,272 bytes with approximately 0.009% aggregate idle CPU. The one Claude
process and its eleven configured MCP descendants were another 936,613,912
bytes. This is not a same-workload Ghostty comparison and does not prove an
Ourocode memory win. It does prove that rendering micro-optimizations alone
cannot satisfy the aggregate goal: supported Claude and Codex installations
must migrate Ouroboros from per-session `uvx` stdio servers to one supervised
shared MCP v2 service. The raw observation remains local at
`/tmp/ourocode-mixed-one-claude-20260810.ndjson` and names exact PIDs rather than
discovering or terminating processes by name.

The processes were not bulk-terminated during the audit because ownership by
active tool clients was not proven. The production gate is therefore broader
than Ourocode app RSS: supported hosts must connect to one supervised
user-scoped service when their MCP transport permits it, stdio children must be
reaped with their owning client, and a reconciliation tool must distinguish
active children from recoverable orphans before cleanup. The live shared
endpoint also returned a SQLAlchemy `QueuePool limit of size 5 overflow 10`
timeout while reading `ouroboros://sessions`; Ourocode now exposes that exact
bounded error and keeps steering disabled instead of showing an empty-but-ready
session tree.

The host migration boundary and its explicit Settings UI are now specified and
implemented in RFC 0006. It recognizes the supported Codex and Claude
user/local Ouroboros stdio shapes, including one immediately adjacent Codex
`[mcp_servers.ouroboros.env]` table, produces a secret-free reviewed diff for
the one verified loopback service, and retains the complete original only in
executor-owned rollback state. The current acting check called Preview against
the explicit user Codex config and proved the file bytes were unchanged; it did
not call Apply. Environment values, headers, tokens, and unrelated host
configuration are not part of the preview model. This is not proof that any
host was migrated or reconnected. A missing Claude entry and Claude
plugin-namespaced MCP servers remain fail-closed until an explicit registration
or authoritative per-server disable/override contract exists.

## macOS local-signing boundary

The local artifact is ad-hoc signed because this machine has no valid Developer
ID identity. Rebuilding changes the code identity while System Settings can
still display a stale Files and Folders grant for the bundle identifier. A
controlled probe showed an app-responsible child blocking exactly while opening
`~/Downloads/google-cloud-sdk/bin`; the same child launched under a terminal
responsibility chain completed immediately. This is not counted as a Return or
PTY failure. Deterministic input QA uses `--shell /bin/sh` to separate the
terminal path from account-specific startup and TCC. Release proof still
requires a stable Developer ID signature, refreshed folder consent, and
notarization; the app must not silently toggle macOS privacy settings.

## Latest packaged artifact

- Development DMG: `apps/macos/OurocodeDesktop/dist/Ourocode-0.1.0-dev.dmg` (the unsigned path cannot create the canonical release filename)
- SHA-256: `b7b74167fe2a073f3b544722d66f1bf39c5d34a4a1d3fc135a1feac498a66d11`
- Packaged: 2026-08-16
- Local verification: HFS image checksum valid; bundled app passes `codesign --verify --deep --strict`; contained executable hash matches the canonical artifact
- App executable SHA-256: `e9fcd298ac3a324b8266f1f17c02f106f55e9cb1ef6100e7f1dc4dd6a4ceaba1`
- No signed release DMG exists; this exact-hash image is ad-hoc signed and explicitly named `-dev.dmg`.
- Packaged broker executable SHA-256: `25368e30851f2a9a0d872178fcb85c633337e317af352fb0871febddcc5bf092`. Its signature and hash were verified inside the remounted DMG, but the preserved 32-session acting run used the separate compatible long-lived broker hash `450de81f…` named above.
- Finder layout and final Luna evidence: exact-payload PASS at `/var/folders/60/x3f084654915g9v4ht0g454c0000gn/T/com.openai.sky.CUAService/Finder Screenshot 2026-08-16 at 3.49.25 AM.jpeg`; signed-payload Rams review remains a production release gate
- MCP/terminal/session evidence: [`final-62a938-mcp-connected.jpeg`](../../apps/macos/OurocodeDesktop/qa-evidence/final-62a938-mcp-connected.jpeg), [`final-62a938-return.jpeg`](../../apps/macos/OurocodeDesktop/qa-evidence/final-62a938-return.jpeg), [`final-62a938-sessions.jpeg`](../../apps/macos/OurocodeDesktop/qa-evidence/final-62a938-sessions.jpeg)
- Historical destructive-close evidence (superseded by the Close View / Terminate Session split): [`final-62a938-create-close-confirm.jpeg`](../../apps/macos/OurocodeDesktop/qa-evidence/final-62a938-create-close-confirm.jpeg), [`final-62a938-create-close-after-ack.jpeg`](../../apps/macos/OurocodeDesktop/qa-evidence/final-62a938-create-close-after-ack.jpeg), [`final-62a938-last-tab-close-confirm.jpeg`](../../apps/macos/OurocodeDesktop/qa-evidence/final-62a938-last-tab-close-confirm.jpeg). Fresh exact-ID close/reopen and explicit-terminate Computer Use evidence is required.
- Current Computer Use evidence: [Luna broker-v4 bootstrap QA](../../apps/macos/OurocodeDesktop/qa-evidence/luna-v4-qa.md)

The package script remounted and verified the current development image before
the atomic rename. Its HFS checksum is valid and the mounted app passes
deep/strict code-signature verification. Exact-payload Computer Use confirmed
the Finder geometry, labels, and accessible image names. Dark Mode, Increase
Contrast/Reduced Transparency, VoiceOver navigation, and the signed-payload
Rams gate remain release work. This does not relax the Developer ID/notarization
boundary.

The 2026-08-16 canonical acting QA did not revoke and re-grant Files and
Folders access after the ad-hoc rebuild. TCC carry-over may therefore have been
in effect; no protected-folder success from that run is accepted as fresh
permission evidence. Before accepting any protected-folder result, revoke and
re-grant Files and Folders consent for the current code identity and rerun the
probe; evidence from a session that skips this sequence is invalid.

## Historical exact-pin app memory and wire verification

The 2026-08-09 development app statically linked the Ghostty ABI v6 adapter and
uses the bundled pin-namespaced v4 broker. A PID-scoped ten-second idle sample
recorded 48,333,760 bytes for the AppKit process, 1,868,112 bytes for the
broker, and 1,622,376 bytes for `/bin/sh`, about 51.8 MB combined. The app had
seven threads, the broker one, the shell one, and idle CPU was effectively
zero. Evidence: `qa-evidence/perf-full-app-one-tab-20260809.ndjson` plus its
manifest. This is a historical one-tab baseline and is superseded for current
artifact attribution by the exact `e9fcd298…` evidence above.

A separate 2026-08-10 exact development build using the account `/bin/zsh -l
-i` measured 95,008 KiB (92.78 MiB) for the app, broker, and one live shell.
With eight live shells it measured 148,464 KiB (144.98 MiB) across the ten
processes in that explicit descendant tree. This is a point-in-time RSS sample,
not a lifetime peak. It excludes unrelated or reparented gitstatus helpers and
therefore does not prove total host memory or superiority over Ghostty or Warp.
Those runs left the 32-live-session and close-to-baseline gates open; the
current exact-hash 32→1→32 evidence above closes only the warm projection and
close-return gate, not lifetime peak or equivalent-workload comparison.

The separate steady 32×10k Ghostty state probe measured 50.1 MiB and zero idle
CPU with one broker thread. It also observed a 279.5 MiB lifetime peak. The
steady number is therefore not evidence that peak memory is below 150 MiB, and
no superiority claim over Ghostty or Warp is made yet.

## Latest Ghostty ABI v6 verification

ABI v6 keeps headless state broker-owned and creates a projection only for the
selected app-side mirror. The app constructs exactly one `MTKView`. A normalized
input capability covers key press/repeat/release, committed text, bounded paste,
and focus, with exact `(generation, terminal, epoch, sequence, lease, digest)`
receipts. Korean IME marked text stays local; a single commit enters the broker.
The Metal scene also preserves Ghostty's width-zero spacer tail, so a width-two
Korean/CJK head is no longer half-covered by a later empty-cell background.
The selected view becomes interactive only after the matching generation's
first Metal presentation and focus receipt. Detach waits for `focus=false`, and
ambiguous receipt ordering fails closed into reconnect without resending.

The account shell now enters through libc `forkpty`, with a child-side
fail-closed check for session leadership, foreground process-group ownership,
and one shared tty across stdin/stdout/stderr before exec. Fresh-socket Luna QA
showed the Powerlevel10k prompt and `zsh 5.9` under `/bin/zsh`. The durable
development namespace still binds only the Ghostty source commit; production
must bind broker build/ABI identity and define coexistence or migration before
reusing an existing listener.

C11/C++17 layout gates, static-link checks, Rust conformance, broker default and
Ghostty feature suites, Clippy `-D warnings`, Swift feature-on/off
warnings-as-errors builds, and deep/strict app signature verification pass.
Pointer selection and scrollback now use identity- and geometry-sequenced broker
receipts; exact-hash Luna drag/scroll acting QA passed without a lingering sync
status. A physical HID trackpad run with observable scrollback displacement
remains a release gate.
