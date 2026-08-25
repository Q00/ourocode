# RFC 0008 분석: Rust split tree → AppKit pane bridge

- 상태: 기반 구현 진행 중; AppKit multi-pane projection은 아직 없음
- 감사일: 2026-08-16
- 판정: **현재 terminal split/pane UI는 연결되어 있지 않다**

## 2026-08-16 구현 갱신

1단계의 bounded runtime foundation은 구현됐다. `ouro-session::SplitLayout`은
별도 opaque C ABI로 노출되며 create/free, focus, split/close,
revision-guarded leaf geometry, divider preview/commit/cancel, keyboard resize를
지원한다. C11/C++17 conformance, split FFI 5개와 전체 render-FFI test,
warnings-as-errors clippy가 통과했다. Swift에는 pane callback의 exact
tab/pane/broker/attachment identity guard와 4 normal / 8 hard surface admission
정책이 추가됐다.

이 갱신은 terminal multiplexer 완료를 뜻하지 않는다. durable branch-record
snapshot/restore, Swift opaque owner의 archive-link 검증, one-leaf production
parity, AppKit multi-surface projection은 아직 뒤의 gate다. 현재 실행 앱은
계속 한 workspace tab당 한 retained terminal surface만 가진다.

## 현재 연결 상태

현재 창의 `NSSplitViewController`는 Connections rail과 terminal host를
나눌 뿐, terminal pane을 만들지 않는다. `TerminalHostViewController`는
`terminalContainer` 하나와 `surfaceCoordinator` 하나를 유지하고,
`requestMirrorSwitch(to:)`가 선택된 tab의 exact broker terminal을 그 한
surface로 교체한다.

Rust 쪽 `crates/ouro-session/src/split_layout.rs`에는 이미 다음 계약이
완성되어 있다.

- stable broker terminal ID만 가진 bounded tree (`MAX_SPLIT_LEAVES = 32`,
  `MAX_SPLIT_DEPTH = 8`);
- `split_focused`, `close`, 순환·방향 focus;
- pointer divider preview와 mouse-up commit 분리;
- commit당 한 번만 나오는 `ResizeIntent`;
- normalized `LeafGeometry`와 broker terminal 존재를 검증하는 restore.

하지만 이 모듈은 Swift executable에 노출되지 않는다. Broker는
`ouro-session`의 recovery/mobile 모듈만 사용하며 `SplitLayout`은 사용하지
않는다. 따라서 현재 앱에서 `Cmd-D`, `Cmd-Shift-D`, pane focus, divider,
pane zoom을 호출할 경로는 0개다.

## 그대로 재사용할 수 있는 기반

1. `BrokerClient.attachments: [String: ActiveAttachment]`는 이미 한 연결에
   여러 exact terminal attachment를 보유하고 terminal ID별로 event를
   전달한다. pane마다 broker process나 socket을 만들 필요가 없다.
2. `TerminalSurfaceCoordinator`는 한 exact terminal stream, 한 Metal view,
   한 input authority를 독립적으로 소유한다. 여러 인스턴스가
   `OuroTerminalMetalResources`의 device/library/command queue/sampler를
   process-wide로 공유할 수 있다.
3. `TerminalSurfaceCoordinator.prepareCandidate` → `commitCandidate` →
   first-present → `activateInput` 순서는 pane별로 그대로 유지해야 한다.
   Split은 이 authority 계약을 우회하면 안 된다.
4. Rust `PresentationUpdate`와 `ResizeIntent`는 pointer-rate `SIGWINCH`를
   막는 데 필요한 경계를 이미 표현한다.

## 현재 구조에서 끊기는 지점

| 지점 | 현재 심볼 | split에 필요한 변경 |
| --- | --- | --- |
| Rust/Swift 경계 | `crates/ouro-session::split_layout`은 Rust 내부 전용 | opaque C ABI와 Swift owner 필요 |
| tab 모델 | `LocalTerminalTab` 하나가 tab과 PTY 상태를 동시에 표현 | workspace tab과 pane terminal을 분리 |
| view | `terminalContainer`에 한 surface를 edge-to-edge 설치 | stable leaf/divider view tree 필요 |
| runtime | `surfaceCoordinator`, `mirrorTab`, `transitionGeneration`, `inputLocked`가 전역 단일값 | exact terminal ID별 pane runtime으로 이동 |
| recovery | `requestMirrorSwitch`가 이전 attachment를 항상 detach | 같은 active workspace의 visible pane attachments는 함께 유지 |
| resize | `resizeSelectedGhosttyTerminal()`이 전체 container와 selected tab만 계산 | leaf bounds별 계산과 affected-terminal commit 필요 |
| command | `main.swift::installMainMenu`와 `commandSnapshot`에 tab/find만 존재 | split/focus/resize/zoom/close-pane actions 필요 |
| session activation | `activateSessionLeaf`가 terminal ID를 tab index로만 찾음 | workspace를 선택한 뒤 exact pane focus 필요 |

## 최소 구현안

Broker protocol이나 PTY reactor에는 split state를 넣지 않는다. Split은
UI projection이고, PTY authority는 계속 broker의 exact terminal ID와
lease가 소유한다. 하나의 `BrokerClient`와 여러 visible pane surface를
사용한다.

### 1. 기존 Rust tree를 정적 archive에서 직접 노출

수정 파일:

- `crates/ouro-render-ffi/Cargo.toml`
  - `ouro-session` dependency 추가.
- `crates/ouro-render-ffi/include/ouro_split_layout.h` (신규)
  - `OuroSplitLayout` opaque owner와 ABI v1 선언.
- `crates/ouro-render-ffi/src/split_layout_ffi.rs` (신규)
  - `SplitLayout`의 생성/해제, focus, split, close, drag, keyboard resize,
    snapshot/restore를 fail-closed C result로 변환.
- `crates/ouro-render-ffi/src/lib.rs`
  - `split_layout_ffi` export만 추가. Render client lifetime과 섞지 않는다.
- `apps/macos/OurocodeDesktop/Sources/COuroRender/include/COuroRender.h`
  - `ouro_split_layout.h` include.
- `apps/macos/OurocodeDesktop/build-dev-ghostty-app.sh` 및 `build-app.sh`
  - `_ouro_split_layout_new`가 최종 executable에 존재하는지 검사.

필수 C ABI:

- `ouro_split_layout_new/free`
- `ouro_split_layout_focus/focus_direction`
- `ouro_split_layout_can_split_focused`
- `ouro_split_layout_split_focused/close`
- `ouro_split_layout_begin/update/commit/cancel_divider_drag`
- `ouro_split_layout_resize_divider_keyboard`
- `ouro_split_layout_copy_snapshot`
- `ouro_split_layout_restore`

Snapshot은 pointer마다 JSON을 만들지 않는다. Preorder의 bounded node
records `(node_id, kind, axis, ratio, first_id, second_id, terminal offset)`와
`LeafGeometry`를 caller-owned buffers로 복사한다. Commit 결과는
`ResizeIntent.affected_terminals`를 별도 caller buffer로 반환한다.

추가 Swift 파일:

- `Sources/OurocodeDesktop/GhosttySplitLayoutBridge.swift`
  - opaque pointer를 소유하는 `GhosttySplitLayoutBridge`;
  - `SplitLayoutSnapshot`, `SplitLayoutLeafGeometry`, `SplitResizeIntent` DTO;
  - 모든 ID/length/count/revision을 다시 검증하고 main-thread mutation만 허용.

### 2. tab과 pane identity 분리

추가 파일:

- `Sources/OurocodeDesktop/TerminalWorkspaceTab.swift`

새 심볼:

- `TerminalWorkspaceTab`
  - tab UI identity, display sequence, optional custom title;
  - `GhosttySplitLayoutBridge`;
  - `[String: TerminalPane]` keyed by exact broker terminal ID;
  - `focusedTerminalID`, optional `zoomedTerminalID`.
- `TerminalPane`
  - 현재 `LocalTerminalTab`의 broker-facing 상태: create nonce, title/path,
    session binding, attachment, cursor, layout epoch, resize history.

`TerminalHostViewController.tabs`는 `[TerminalWorkspaceTab]`가 된다. 기존
running broker terminals를 복원할 때는 terminal마다 one-leaf workspace를
만들어 지금의 동작을 보존한다. 새 tab도 broker `create` 성공 뒤 returned
terminal ID로 one-leaf layout을 만든다.

Split 생성 순서:

1. `can_split_focused`로 leaf/depth/drag 상태를 먼저 검증한다.
2. focused pane의 authoritative cwd와 예상 half-pane geometry로
   `BrokerClient.create`를 호출한다.
3. 성공 reply의 exact terminal ID를 `split_focused`에 넣는다.
4. 새 pane runtime을 만들어 recovery/first-present를 실행한다.
5. 3번이 예기치 않게 실패하면 새 PTY를 종료하거나 숨기지 않고 새
   one-leaf tab으로 채택한다. 생성된 broker session을 orphan하지 않는다.

### 3. native pane projection 추가

추가 파일:

- `Sources/OurocodeDesktop/TerminalPaneContainerView.swift`
- `Sources/OurocodeDesktop/TerminalPaneDividerView.swift`

`TerminalPaneContainerView`는 Rust snapshot을 source of truth로 삼아 stable
terminal ID별 leaf view와 branch node ID별 divider를 reconcile한다. Nested
`NSSplitView`가 자체 ratio를 별도로 소유하게 하지 않는다. Normalized
`LeafGeometry`를 container bounds로 변환해 subview frame을 정하고,
divider는 native cursor, keyboard focus, AX value를 제공한다.

Interaction:

- pane primary click → Rust `focus` → 해당 Metal view를 first responder로;
- divider mouseDown → `begin_divider_drag`;
- mouseDragged → `update_divider_drag`, AppKit frame만 preview;
- mouseUp → `commit_divider_drag`, returned affected terminal만 한 번 resize;
- Escape/cancel → `cancel_divider_drag`, broker resize 0회.

Focus는 장식용 header 대신 1 px focus keyline과 cursor 상태로만 표시한다.
모든 pane에 별도 title bar를 추가하지 않는다.

### 4. 단일 mirror state machine을 pane runtime으로 추출

추가 파일:

- `Sources/OurocodeDesktop/TerminalPaneRuntime.swift`
- `Sources/OurocodeDesktop/TerminalWorkspaceProjectionCoordinator.swift`

`TerminalPaneRuntime`으로 이동할 현재 host 심볼:

- `surfaceCoordinator`, `transitionGeneration`, `inputLocked`;
- candidate import/commit/first-present/input activation;
- `GhosttyResizeRequest`, `GhosttyResizeTransaction`;
- exact attachment detach와 resync;
- metadata/bell/find callbacks.

각 visible pane는 `TerminalSurfaceCoordinator` 하나를 갖고, 모두 같은
`BrokerClient`를 사용한다. `BrokerClient.onResyncRequired(terminalID:)`는
해당 runtime만 재복구한다. 같은 workspace의 다른 pane을 detach하거나
connection 전체를 재시작하지 않는다. Window first responder만 keyboard
입력의 active pane을 결정하고, focus false/true receipt는 기존 coordinator
계약을 그대로 통과한다.

`TerminalWorkspaceProjectionCoordinator`는 tab 전환 시:

1. outgoing workspace의 모든 pane input을 즉시 닫고 exact detach barrier;
2. surface를 제거해 hidden tab이 renderer/atlas/attachment를 갖지 않게 함;
3. incoming workspace의 leaves를 bounded concurrency로 recovery;
4. Rust focused terminal이 first-present한 뒤에만 first responder 복원.

### 5. resize와 pane zoom

`TerminalHostViewController.resizeSelectedGhosttyTerminal()`은 제거하지 않고
pane runtime의 `resize(to: NSRect, cause:)`로 이동한다.

- Window resize/typography: 80 ms debounce 뒤 visible leaves 각각 마지막
  geometry 한 건으로 coalesce.
- Divider preview: surface frame만 변경, PTY resize 없음.
- Divider commit/keyboard resize: Rust `ResizeIntent`의 terminal IDs만 기존
  pointer barrier와 layout epoch를 거쳐 정확히 한 번 resize.
- Pane zoom: Rust tree를 변형하지 않는 workspace presentation state다.
  focused leaf만 container 전체에 보이고, unzoom에서 committed geometry를
  복원한 뒤 affected panes를 resize한다.

### 6. command와 lifecycle 연결

수정 파일과 심볼:

- `TerminalHostViewController.swift`
  - `splitFocusedLeftRight`, `splitFocusedTopBottom`;
  - `focusPaneLeft/Right/Up/Down`;
  - `resizeFocusedDivider...`, `toggleFocusedPaneZoom`;
  - `closeFocusedPaneOrTab`;
  - `showFind`, typography, session binding/activation을 focused pane runtime에
    route.
- `main.swift::installMainMenu`
  - `Cmd-D`: side-by-side (`LeftRight`);
  - `Cmd-Shift-D`: stacked (`TopBottom`);
  - `Option-Cmd-Arrow`: directional focus;
  - `Shift-Cmd-Return`: pane zoom;
  - `Cmd-W`: leaf가 둘 이상이면 focused pane view, 하나면 tab close.
- `TerminalHostViewController.commandSnapshot/perform`
  - 같은 action을 command palette에 노출하고 limit/attach/drag 상태로
    enablement 결정.
- `activateSessionLeaf`
  - terminal ID로 workspace와 pane을 함께 찾고 tab 선택 → Rust focus →
    first-present/first-responder 순서로 전환.

Pane close는 PTY terminate가 아니다. 먼저 input close + detach가 성공한
뒤 `SplitLayout.close`로 tree를 collapse하고, 기존 closed-view 기록에 exact
terminal ID를 넣는다. `Terminate Session…`만 확인 후 broker terminate를
호출한다.

## 메모리 경계

Visible pane에는 실제로 동시에 보이는 scene이 필요하므로 현재의 “한
retained renderer” 주장은 split 모드에서 유지할 수 없다. 정직한 새
경계는 **hidden tab renderer 0, visible pane renderer 1**이다.

`OuroTerminalMetalResources`는 이미 공유되지만 `OuroTerminalRenderer`마다
2,048×2,048 R8 atlas(약 4 MiB)와 최대 2 MiB metadata, scene buffers를
가진다. 따라서 첫 배포는 AppKit `SplitLimits.max_leaves = 4`로 hard-cap하고
1/2/4-pane coalition 측정 후에만 8/32를 연다. Rust process-wide 상한 32는
그대로 두되 UI가 검증 없이 이를 노출하지 않는다. Shared mutable atlas는
scene reference와 rotation 동기화를 새로 요구하므로 최소 구현에 넣지
않는다.

Broker는 계속 한 poll reactor, 한 UDS connection이며 pane마다 process나
reader thread를 만들지 않는다.

## 완료 테스트

Rust/FFI:

- FFI snapshot이 Rust metadata/geometry와 round-trip;
- invalid ID/count/version/buffer는 fail-closed;
- pointer drag 100 updates가 resize intent 0, commit이 exactly 1;
- missing broker terminal restore 실패.

Swift contract:

- stable node/terminal reconciliation과 gapless pixel frames;
- split create failure가 기존 tree를 보존하고 created terminal을 tab으로
  채택;
- two/four visible attachments가 exact terminal event만 소비;
- pane focus 전환이 한 focus-false/true receipt 순서;
- divider commit이 affected pane당 resize 1회, cancel 0회;
- tab switch 뒤 outgoing renderer/attachment/AX element 0;
- session leaf activation이 exact workspace/pane만 focus.

Acting QA:

- `Cmd-D`, `Cmd-Shift-D`, pointer drag, directional focus, pane close/zoom;
- 각 pane의 real zsh Return/Ctrl-C/IME/copy/paste/find;
- vim/tmux/ssh에서 divider와 window resize reflow;
- 1/2/4 visible pane cold/steady/close-to-baseline memory, GPU allocation,
  app/broker/shell/agent/MCP coalition;
- hidden tabs가 surface/atlas/attachment/thread를 추가하지 않는 증거.

## 구현 순서

1. Rust C ABI + Swift bridge fixture.
2. one-leaf `TerminalWorkspaceTab`로 기존 tab 행동을 무변경 이관.
3. two-pane projection과 exact multi-attachment recovery.
4. divider commit resize, directional focus, close/zoom/menu.
5. restore, acting QA, 1/2/4 memory gate.

1번 뒤 곧바로 split UI를 붙이지 않는다. 먼저 2번의 one-leaf parity가
현재 tab/recovery/input/zoom/find 테스트를 모두 통과해야 한다. 그래야
split 구현이 기존 single-surface correctness를 회귀시켰는지 분리해서
판단할 수 있다.
