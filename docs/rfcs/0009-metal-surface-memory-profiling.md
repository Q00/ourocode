# RFC 0009 — Metal surface memory profiling gate

Status: **investigation**  
Owner: Ourocode Desktop  
Scope: v5 UI physical footprint, not broker or shell memory

## Finding

The Rams 9 comparison showed 9.75 MB of `IOSurface` in v5 versus 5.24 MB in
v4. A read-only `vmmap -wide -noCoalesce` inspection resolves that difference:
v5 owns two equal `CAMetalLayer Display Drawable` surfaces, each 1136×976 and
4400K, while v4 had one. There is no stale third surface or differently sized
hidden terminal in the snapshot. The current layer policy already uses
`maximumDrawableCount = 2`, `framebufferOnly = true`, and
`presentsWithTransaction = false`; two is the minimum drawable pool supported
by CAMetalLayer. This is therefore a buffering-residency difference, not yet a
proven drawable leak. Reducing the count to one is not an acceptable fix: it
can starve `currentDrawable` and turn a memory experiment into a presentation
failure.

The +3 MB `MALLOC_SMALL` delta is not explained by the layer snapshot. It must
be profiled independently before changing renderer ownership or Swift object
lifetime.

## Reproducible gate

1. Build v4 and v5 with different bundle identifiers but the same window frame,
   screen scale, shell fixture, and number of rendered frames. Capture an
   initial frame, a second frame, and a 30-second quiescent interval.
2. For each phase, record exact-PID `phys_footprint`, `resident_size`, and
   `vmmap -wide -noCoalesce`. Count only rows labelled `CAMetalLayer Display
   Drawable`; exclude QuartzCore/CoreUI surfaces.
3. In a separate run, enable Instruments **Metal System Trace** and
   **Allocations** for five frames. Correlate each `currentDrawable` acquisition
   with `present(drawable)` and command-buffer completion. The invariant is one
   renderer, one active `MTKView`, at most one command buffer in flight, and a
   drawable pool no larger than two.
4. Run `malloc_history <pid>` (or Instruments Allocations call trees) after
   the quiescent phase. Attribute the +3 MB small-allocation delta by stack,
   especially window/session controllers, accessibility projections, and
   renderer preparation. Do not infer a Swift leak from the aggregate zone
   alone.
5. Repeat with a Metal capture around a single typography transaction. If the
   delta is graphics-owned, compare atlas texture creation and staging uploads;
   if it is `MALLOC_SMALL`, compare retain paths and object counts.

## Release criteria

- The two-drawable pool remains the default and passes the static policy
  fixture (`test-terminal-metal-surface-memory.sh`).
- No run may show a third display drawable, a drawable that survives renderer
  teardown, or more than one live terminal `MTKView` in the host hierarchy.
- A change to drawable count, `presentsWithTransaction`, or renderer lifetime
  requires a before/after Metal trace and an interaction smoke test. Memory
  totals without allocation-stack evidence are insufficient.
