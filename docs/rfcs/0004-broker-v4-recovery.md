# RFC 0004: Broker protocol v4 canonical recovery

- Status: Broker-owned exact-pin Ghostty engine and immutable replay recovery implemented behind an experimental binary; renderer and page-budget promotion gates pending
- Date: 2026-08-09
- Parent: [RFC 0001](0001-ourocode-desktop-terminal.md)
- Engine gate: [RFC 0002](0002-libghostty-gate0.md)

## Decision

Protocol v4 uses the exact-pin Ghostty complete snapshot as an
incarnation-bound canonical checkpoint and an Ourocode-owned ordered state log.
It does not widen protocol v3's ANSI viewport replay and never treats an opaque
engine memory dump as a durable file format.

The capability manifest binds all of the following:

- broker protocol `4` and a separate `broker-v4.sock` namespace;
- Ourocode terminal ABI version;
- Ghostty source commit;
- Ghostty snapshot magic and format version;
- Unicode width-policy identifier;
- disabled or bounded graphics capabilities;
- snapshot, terminal-history, global-history, delta, and recovery-pinning
  byte limits.

A manifest mismatch requires a new snapshot from a compatible broker. No
snapshot is restored across a different engine pin or format version.

## Ordered terminal state

Every mutation belongs to one monotonic `state_seq`:

```text
pty_bytes { bytes }
resize { columns, rows, cell_width_px, cell_height_px, layout_epoch }
history_trim { history_epoch, first_retained_line }
canonical_checkpoint { checkpoint_id, state_seq }
```

Duplicate events may be ignored only when their digest matches. A gap,
cursor-ahead value, generation mismatch, layout mismatch, or conflicting
duplicate fails closed with `resync_required`. Resize is never an out-of-band
side effect: observers and resume clients see it in the same order as PTY
bytes.

The broker retains an immutable exact-pin snapshot at checkpoint `C` plus the
ordered events after `C`. This is also the recovery rule for an unfinished VT
continuation. The public decoder restores that continuation with tracking
disabled, so a restored state is not immediately re-snapshotted. The original
checkpoint and subsequent events remain authoritative until input reaches
ground and a new canonical snapshot succeeds; checkpoint replacement is then
atomic. A continuation that exceeds its bound is aborted and produces an
explicit canonical-resync event.

## Two-phase attach

Input authority is unavailable until recovery commits:

```text
attach_prepare(terminal_id, broker_generation, after_state_seq?)
  -> recovery_begin(recovery_id, cutover=C, manifest, total_bytes,
                    chunk_count, digest)
  -> recovery_chunk(recovery_id, index, bytes) ...
  -> recovery_end(recovery_id, digest)

client validates/imports into an offscreen terminal state

recovery_commit(recovery_id, cutover=C, digest)
  -> broker validates client incarnation and retained C+1..D
  -> recovery_delta(C+1..D)
  -> attached_ready(D, input_epoch, lease_id)
  -> live events D+1...
```

`attach_prepare` first revokes any existing input lease and suspends that
client's live subscription for the terminal. The old input epoch can never
mutate state during recovery, and live events cannot interleave with the
checkpoint/chunk stream. A client that rejects a manifest, digest, chunk,
offscreen import, or commit sends incarnation-bound `recovery_abort`; the
broker releases the pin and per-client/global slot immediately. Bounded abort
tombstones make an exact retry idempotent while foreign client, terminal, or
generation values fail closed.

Decoded chunks are at most 64 KiB. The client validates manifest totals before
allocation, accepts only exact chunk order, and hashes the complete stream.
Initial v4 uses no compression. The engine snapshot retains its record-level
CRC32C checks; the transport digest protects chunk assembly and manifest
binding.

The broker permits one recovery per client, four globally, with CSPRNG recovery
IDs bound to the client incarnation, a short TTL, and a global pinned-byte
budget. Disconnect, timeout, failed import, or failed commit releases every
pinned reference and grants no lease. If cutover `C` leaves the delta window
before commit, the broker rejects commit and starts a fresh recovery rather
than mixing states.

## Memory contract

- Ghostty allocations routed through `GhosttyAllocator` use the Ourocode
  accounting allocator from terminal creation through decoder, render-state,
  formatter, and destruction. Exact-pin terminal page backing uses direct
  tagged `mmap` and is accounted separately.
- Every terminal reports requested-byte live/peak/failures plus direct page
  virtual, resident, dirty, and compressed bytes. The allocator-mediated cap
  rejects heap growth before its allocator is called; a production page cap
  requires a page-mapping observer/budget and a decoded-page byte limit from a
  newly gated exact pin.
- Logical history is limited by 8 MiB and 10,000 lines per terminal, whichever
  is reached first. Ghostty page granularity is included in measured engine
  allocation rather than hidden behind the configured estimate.
- The broker accounts allocator-mediated engine state, direct page mappings,
  compressed cold pages, immutable checkpoints, delta windows, serialization
  scratch, and recovery-pinned pages separately.
- Global history defaults to 128 MiB. LRU trimming never removes a viewport;
  it advances `history_epoch` and emits `history_trim` before older references
  become invalid.
- Offscreen desktop and mobile clients keep no GPU surface. A client imports
  into one bounded headless state and swaps it into the selected surface only
  after digest and sequence validation.
- Selected/hot sessions receive the larger history allowance. Offscreen
  sessions use the minimum practical page policy and schedule Ghostty's
  activity-token-driven incremental compression only during reactor idle
  slices. Full synchronous compression is reserved for tests and explicit
  cold transitions, never PTY input or frame delivery.

## Security boundary

Mode-0600 UDS and same-UID peer credentials remain necessary but are not
sufficient for terminal confidentiality. Production launchd/XPC admission must
bind an audit token or signed client credential to each client incarnation.
Recovery IDs, input leases, and state cursors are terminal-, generation-, and
incarnation-bound. A foreign process cannot turn a read attach into input
authority.

## Merge gates

1. Snapshot import/export produces an identical canonical digest for styled
   Unicode, combining graphemes, double-width cells, hyperlinks, cursor/modes,
   main/alternate grids, scrollback, and narrow/wide/narrow reflow.
2. Corrupt, truncated, trailing, over-limit, wrong-pin, and wrong-format input
   fails before state is exposed.
3. Formatter allocator usage stays inside its hard budget; restore rejects
   allocator or decoded-page budget overflow before exposing state, and every
   failure path returns allocator and page accounting to its prior baseline.
4. Concurrent output and resize during recovery converges to the broker digest
   at the same `state_seq`.
5. Missing, duplicate-conflicting, or reordered chunks/events and delta-window
   overflow produce `resync_required`, never partial presentation.
6. Disconnect during every recovery phase releases pinned state and never
   leaves an input lease.
7. Global eviction gives connected and reconnecting clients the same
   `history_epoch` and first retained logical line.
8. Thirty-two noisy terminals remain inside allocator, direct-page, compressed,
   and global budgets with one reactor thread, idle CPU below 0.5%, and no
   offscreen GPU allocation. Physical gates use `phys_footprint` and private
   dirty evidence rather than raw RSS alone.
9. Eight noisy PTYs during an 8 MiB recovery meet the key-to-frame and reactor
   fairness gates from RFC 0001.

## Non-goals

Protocol v4 does not make the experimental Ghostty snapshot a cross-release
persistence format, expose raw PTY descriptors, provide mobile pairing, or
replace the renderer promotion gates. Those remain separate release gates.

## Implementation evidence

The checked-in Rust server keeps the default `ouro-broker-v4` binary as an
explicit `OUROCODE-ANSI-REPLAY` fixture for the current SwiftTerm bootstrap.
The feature-gated `ouro-broker-v4-ghostty` binary instead creates one exact-pin
Ghostty engine per PTY before spawning the child, feeds it every original PTY
byte exactly once, applies ordered resize, exports its checkpoint directly,
and schedules bounded activity-token compression during reactor idle slices.
Production Ghostty mode allocates neither the ANSI shadow parser nor the v3
delta window.

Each live engine now starts with immutable checkpoint `C=0`. PTY and resize
events are journaled before engine mutation; a failed feed, resize, or
compression discards the possibly partial handle, restores `C`, and replays
the raw `C+1..D` tail into a new handle. The active tail cannot evict an event
after `C`. Rotation begins with reserved room for one bounded parser
continuation plus one PTY chunk; at the hard boundary output stays in the
bounded pending buffer and PTY reads pause rather than mutating unrecoverable
state. Resize capacity is secured before `TIOCSWINSZ`. Persistent checkpoints
have a broker-global admission budget, and the same `Arc<[u8]>` backs the
internal checkpoint and a recovery pin without a second payload copy.

This is still an experimental promotion lane. Restore plus tail replay is
synchronous on the single reactor today; a bounded background restore/commit
handoff is required before a worst-case 16 MiB checkpoint can be enabled in
the default broker. The exact pin also still needs the reviewed shared page
budget wired through the Ourocode adapter before aggregate-memory claims are
allowed.

Rust verification currently covers:

- 18 `ouro-session` ordered-state tests for typed PTY/resize events, exact
  duplicate handling, gap/conflict rejection, byte-window eviction, and
  no-eviction active checkpoint tails;
- 18 protocol-v4 PTY integration tests for the cross-language digest vector,
  manifest-bound 64 KiB assembly, no authority before commit, wrong-digest
  cleanup, output-during-recovery catch-up, typed live resize order, one
  recovery per client, four globally, pinned-byte rejection, expiry, and
  disconnect release, plus old-lease fencing, live-subscription suspension,
  abort ownership, idempotency, immediate retry, 1,000 rapid connect-close
  admissions, broker-owned live state, exact-pin raw-tail recovery,
  partial-prefix failure restore/replay, idle compression gating, and global
  immutable-checkpoint admission;
- all 12 protocol-v3 lifecycle tests and 9 canonical terminal-state tests
  unchanged and passing.

The Swift client validates the same fixed binary digest preimage, manifest
limits, exact chunk order, and event sequence. It imports the bootstrap ANSI
checkpoint into an offscreen terminal, applies commit catch-up, and swaps the
selected view only after `attached_ready`. Wrong manifests, reordered chunks,
early commit, and live sequence gaps preserve the old renderer and request a
fresh recovery. Broker v3 is an explicit, visibly labelled compatibility mode;
there is no silent downgrade.

Standalone Swift adversarial smoke tests and a cross-language smoke against
the bundled `ouro-broker-v4` helper pass hello, create, digest, prepare,
abort, same-connection re-prepare, commit, `attached_ready`, input, ordered
output, and exit. The release app
bundle contains separately signed v3 and v4 helpers and passes deep/strict
code-sign verification.

On macOS a peer that disconnected between `getpeereid` and `SO_NOSIGPIPE`
configuration exposed an `EINVAL` admission race. V4 now discards that accepted
stream only when a non-consuming `MSG_PEEK | MSG_DONTWAIT` also proves EOF;
live-peer option failures and probe errors still terminate with context rather
than being masked. The complete broker/session suite passed 20 consecutive
serial repetitions after this fix, independently repeated by the root QA run.
