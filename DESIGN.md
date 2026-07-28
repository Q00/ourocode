# Ourocode Design System

## 1. Atmosphere & Identity

Ourocode feels like a quiet terminal command center: dense enough for real work, but deliberate about hierarchy so the next action is visible. The signature is a productized terminal surface with mono typography, restrained mint accents, and verification evidence treated as first-class UI.

## 2. Color

### Palette

| Role | Token | Light | Dark | Usage |
| --- | --- | --- | --- | --- |
| Surface/primary | `--bg` | `#fafaf7` | `#0a0a0b` | Page background |
| Surface/panel | `--panel` | `#ffffff` | `#111111` | Main panels and terminal shells |
| Surface/secondary | `--panel-2` | `#f1f2ed` | `#1a1a1d` | Secondary panels, selected surfaces |
| Text/primary | `--ink` | `#111513` | `#e2e2e5` | Headlines and terminal text |
| Text/secondary | `--muted` | `#61655f` | `#a8a8a8` | Captions, hints, inactive rows |
| Border/default | `--line` | `rgba(17, 21, 19, 0.14)` | `rgba(226, 226, 229, 0.18)` | Dividers and panel outlines |
| Accent/primary | `--mint` | `#087c58` | `#66d9c2` | Primary action, selected state, healthy checks |
| Accent/warning | `--amber` | `#a96c00` | `#e8a45c` | Workflow/interview emphasis |
| Status/error | `--rose` | `#b84646` | `#f87171` | Failed checks or destructive actions |
| Shadow | `--shadow` | `rgba(17, 21, 19, 0.16)` | `rgba(0, 0, 0, 0.42)` | Elevated browser/tool surfaces |

### Rules

- Use mint for active verification and primary affordances only.
- Use amber for interview/workflow context, never as a general accent.
- Raw terminal text may remain monochrome; color is reserved for state and action.

## 3. Typography

### Scale

| Level | Size | Weight | Line Height | Tracking | Usage |
| --- | --- | --- | --- | --- | --- |
| Display | `clamp(3rem, 10vw, 8rem)` | 700 | 0.9 | 0 | Product hero only |
| H1 | `40px` | 700 | 1.1 | 0 | Tool/page title |
| H2 | `28px` | 700 | 1.2 | 0 | Section heading |
| H3 | `18px` | 700 | 1.35 | 0 | Panel heading |
| Body | `15px` | 400 | 1.6 | 0 | Default copy |
| Body/sm | `13px` | 400 | 1.5 | 0 | Metadata, helper text |
| Caption | `12px` | 700 | 1.4 | 0 | Labels and status chips |
| Terminal | `14px` | 400 | 1.45 | 0 | Rendered TUI frame text |

### Font Stack

- Primary and mono: `"JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace`.

### Rules

- Letter spacing is 0 unless a pre-existing terminal label requires uppercase density.
- Body text must not drop below 13px in web QA tools.

## 4. Spacing & Layout

### Base Unit

All spacing derives from 4px.

| Token | Value | Usage |
| --- | --- | --- |
| `--space-1` | `4px` | Tight inline gaps |
| `--space-2` | `8px` | Compact row gaps |
| `--space-3` | `12px` | Control padding |
| `--space-4` | `16px` | Panel inner spacing |
| `--space-5` | `20px` | Dense section spacing |
| `--space-6` | `24px` | Tool shell spacing |
| `--space-8` | `32px` | Major group spacing |
| `--space-10` | `40px` | Page bands |

### Grid

- Max content width: `1440px`.
- Breakpoints: mobile `< 760px`, tablet `760px`, desktop `1100px`.
- QA tool layout: control rail plus terminal preview on desktop; stacked controls on mobile.

### Rules

- Terminal preview dimensions are stable and must not resize when frame content changes.
- Toolbars wrap before text overflows.

## 5. Components

### Terminal Shell

- **Structure**: title bar, status dots, fixed-height preformatted frame area.
- **Variants**: dark, light, compact.
- **Spacing**: `--space-4` and `--space-6`.
- **States**: default, playing, paused, empty, error.
- **Accessibility**: labelled region; text remains selectable; no color-only status.
- **Motion**: frame changes use opacity only.

### Scenario Rail

- **Structure**: list of frame buttons with title, duration, and check count.
- **Variants**: selected, failed, warning.
- **Spacing**: `--space-2` and `--space-3`.
- **States**: default, hover, active, focus, disabled.
- **Accessibility**: native buttons with `aria-current` on the selected scenario.
- **Motion**: hover color transition under 160ms.

### Evidence Panel

- **Structure**: key-value checks, viewport controls, export/copy actions.
- **Variants**: pass, warning, blocked.
- **Spacing**: `--space-3` and `--space-4`.
- **States**: default, loading, error.
- **Accessibility**: status text is explicit, not icon-only.
- **Motion**: none beyond control feedback.

## 6. Motion & Interaction

| Type | Duration | Easing | Usage |
| --- | --- | --- | --- |
| Micro | `120ms` | `ease` | Button and row hover |
| Standard | `180ms` | `ease-out` | Frame opacity change |

Rules:

- Animate only opacity and transform.
- Respect `prefers-reduced-motion` by disabling auto-play transitions.
- Keyboard QA must support play/pause, previous/next, and direct scenario selection.

## 7. Depth & Surface

### Strategy

Mixed: web documentation uses subtle shadows for elevated browser-like surfaces; terminal tool surfaces use borders plus tonal shifts.

| Level | Value | Usage |
| --- | --- | --- |
| Subtle border | `1px solid var(--line)` | Panels, controls |
| Elevated shadow | `0 1.2rem 3rem var(--shadow)` | Main terminal shell |
| Tonal shift | `var(--panel-2)` | Selected rows and secondary controls |

