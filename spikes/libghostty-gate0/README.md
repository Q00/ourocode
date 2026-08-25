# libghostty Gate 0 spike

This directory proves only the public `libghostty-vt` C boundary. It does not
replace SwiftTerm in the application and it does not use Ghostty's internal
`include/ghostty.h` GUI embedding API.

Pins:

- Ghostty commit: `136f436a3bbb14fd48d18e927a83fc6585d5a63c`
- libghostty advertised version: `0.1.0-dev`
- Zig: `0.16.0`
- Zig macOS archive SHA-256 used for the recorded run:
  `b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489`
- Ourocode shared page-budget patch:
  `patches/0001-shared-page-budget.patch`, SHA-256
  `58596254d225ae5cccd6abc402b494c4648ce58e9dc42c8d23e055f1381aabd3`
- Patched public header SHA-256:
  `f78301213dcb68a692562dce7a6b0c33f398700a19569c7e14958aa258c111a0`
- Canonical release archive SHA-256:
  `c2c507b9355627e0ee2535e8328e47715212ea9075d50a96997fd3db2b8c34b6`
- Canonical eleven-member manifest SHA-256:
  `0425918640f8ab640ad9fb88699e3396c4c0dc4ee53a47343f642c64ded07055`

`build-upstream.sh` requires a clean exact-pin checkout and the absolute path
to the official Zig distribution archive in `OUROCODE_ZIG_ARCHIVE`. It verifies
the archive digest and compares the active Zig directory byte-for-byte with a
fresh extraction, rejects staged, unstaged, and non-ignored untracked source
dirt, verifies the patch digest, applies the patch only for the
build, and removes it on every normal or signal exit. The patch adds a
Ghostty-owned shared page-mapping budget with atomic
pre-allocation admission, rollback on child-allocation failure, checked hostile
snapshot page layout, and shared terminal/decoder accounting. Decommitted pages
remain charged until their mapping is actually freed; this is a mapping cap,
not a claim about physical RSS.

The raw Zig static archive is intentionally not used as the supply-chain
identity. At this pin, release objects still contain DWARF compilation
directories and Zig cache paths, and Apple archive headers contain build time,
UID, and GID metadata. Two clean builds from different working directories
therefore produced raw SHA-256 values `789e267dcceb46c8efdb9ea2f25afdd474cea69b7c8c9bffa1e10b72b8bf2aab`
and `b9c6116b9c5c2ecb770321e6613f0b383d2a955fb7b5dbec9179b637a1bfd5aa`.
After `strip -S`, all eleven linkable member payloads matched the checked-in
[`canonical-members.sha256`](./canonical-members.sha256). Rebuilding them in
the audited order with Apple `libtool -static -D`, fixed mode `0644`, zero
timestamps, and zero UID/GID produced byte-identical archives with SHA-256
`c2c507b9355627e0ee2535e8328e47715212ea9075d50a96997fd3db2b8c34b6`.
The canonicalization audit used Command Line Tools package
`26.5.0.0.1777544298` and `cctools_ld-1267`; output and member digests remain
fail-closed if a later toolchain emits different bytes.

Build and run from a clean Ghostty checkout:

```sh
export PATH=/absolute/path/to/zig-aarch64-macos-0.16.0:$PATH
export OUROCODE_ZIG_ARCHIVE=/absolute/path/to/zig-aarch64-macos-0.16.0.tar.xz
./spikes/libghostty-gate0/build-upstream.sh \
  /absolute/path/to/ghostty \
  /absolute/path/to/libghostty-prefix

./spikes/libghostty-gate0/tests/test-canonical-archive.sh

./spikes/libghostty-gate0/run-conformance.sh \
  /absolute/path/to/libghostty-prefix

GHOSTTY_VT_PREFIX=/absolute/path/to/libghostty-prefix \
  cargo test --manifest-path crates/ouro-terminal-ghostty/Cargo.toml
```

The C header is the application-owned ABI. The C implementation is the only
file that includes `<ghostty/vt.h>`. The Rust crate wraps the application ABI,
not the unstable upstream ABI, and links the exact static archive by path.

The Ourocode-owned boundary is ABI v4. It preserves the complete ABI-v3 public
config, frame-info, and memory-info struct layouts and adds idle compression
as functions plus a typed result. An ABI-v3 client still rejects the v4 adapter
instead of guessing layouts. ABI v3 added a mandatory
`engine_memory_max_bytes` hard budget for allocations
routed through `GhosttyAllocator`. A single Ourocode-owned allocator is passed
to the terminal, detached render state, temporary formatter/output, and
snapshot decoder/decoded terminal. Its context remains alive until every
Ghostty object using it has been freed.

This is not a complete terminal-memory budget at the exact pin. Native
terminal page backing bypasses `GhosttyAllocator` and uses tagged `mmap`
regions directly; see the physical fanout result below.

The allocator is backed by `malloc`/`realloc`/`free` and accounts exact sizes
requested through the upstream allocator contract:

- `live_bytes` decreases only after a successful physical remap shrink or
  free; `resize` never claims an in-place size change that libc did not make;
- `peak_bytes` is monotonic and never exceeds `limit_bytes`;
- alloc, remap, and growth requests check the cap with subtraction-based,
  overflow-safe arithmetic before touching the heap;
- remap growth conservatively requires room for the complete replacement
  allocation in addition to current live requests, covering the old+new
  overlap a moving `realloc` or Zig's copy fallback may require;
- `allocation_failures` is a saturating count of rejected or failed allocator
  callbacks;
- allocator-mediated formatter and decoder allocations are charged to the
  same budget and released before the synchronous Ourocode call returns.

`OuroTerminalMemoryInfo` and `ouro_terminal_memory_info` expose those values.
They measure exact requested engine bytes, not allocator metadata, retained
malloc size-class slack, the Ourocode wrapper itself, a libc-internal transient
during `realloc`, or process RSS. On macOS the adapter separately tracks
`malloc_size` only as a private diagnostic; it is not evidence that the
requested-byte cap bounds physical footprint or native page mappings. The
conformance default budget is 32 MiB.

ABI v4 exposes the exact pin's idle-compression scheduler primitives without
changing logical terminal state:

- `ouro_terminal_compression_activity` returns an opaque token. Only equality
  comparisons are meaningful; any change restarts the caller-owned idle delay;
- `ouro_terminal_compress_incremental` performs one bounded step and returns a
  typed `UNSUPPORTED`, `PENDING`, or `COMPLETE` result;
- `ouro_terminal_compress_full_for_testing` is deliberately named and
  documented as test/benchmark-only. It is forbidden on the product hot path
  because its synchronous work grows with retained history. The Rust wrapper
  does not compile its FULL method unless the explicit
  `benchmark-full-compression` feature is enabled.

Callers serialize compression with PTY writes, resize, rendering, search,
snapshots, and every other operation on the same terminal. A `PENDING` result
is continued only while the session remains idle and its captured activity
token is unchanged. `COMPLETE` means the pass has no continuation; it does not
promise that every page was profitable or successfully reclaimed.

ABI v2 added the mandatory `snapshot_max_bytes` bound and two synchronous APIs,
which remain unchanged in v4:

- `ouro_terminal_copy_snapshot` queries or copies a complete snapshot without
  allocating an adapter-owned snapshot buffer;
- `ouro_terminal_restore` borrows snapshot bytes for the duration of the call,
  validates through `FINISH`, rejects trailing bytes, and creates a detached
  render state for the restored terminal.

The probe currently covers:

- exact C compilation and static linking;
- hard requested-byte accounting across allocator-mediated terminal, render
  state, formatter, formatter output, and snapshot-decoder work;
- fail-closed terminal creation at a literal tiny cap and fail-closed restore
  immediately below its dynamically measured minimum successful cap;
- observable allocation failure accounting and rollback to the prior live-byte
  baseline after a deliberately oversized resize;
- formatter/decoder temporary-allocation release, monotonic peak accounting,
  and AddressSanitizer/UndefinedBehaviorSanitizer-friendly free paths;
- a macOS `malloc_size` regression that remaps 4 KiB to 8 MiB and back to
  4 KiB, and requires the final usable allocation to fall below one sixteenth
  of the grown allocation;
- bounded scrollback, APC, continuation, and Kitty image settings;
- VT input and Unicode text;
- render-state creation and dirty metadata;
- narrow/widen content preservation for the SwiftTerm #494 failure shape;
- sized/versioned ABI rejection;
- preservation of the exact ABI-v3 config/frame/memory struct sizes on 64-bit
  targets while the version is explicitly raised to 4;
- activity-token mutation, typed incremental convergence, benchmark-only full
  behavior, and byte-identical plain text plus canonical snapshots before and
  after compression;
- complete snapshot persistence for styled Unicode (CJK, emoji, combining),
  OSC 8 hyperlinks, both main and alternate screens, resize/reflow, and
  scrollback;
- byte-for-byte canonical re-encoding of grounded snapshots at the pinned
  commit;
- unfinished VT continuation restoration and equivalent behavior after the
  sequence reaches ground;
- total snapshot export/import caps and a separate decoder continuation cap;
- fail-closed rejection of truncated, CRC-corrupt, oversized, empty, and
  adapter-ABI-incompatible inputs.

On restore, the adapter reapplies the caller's scrollback byte/line, Kitty
image, APC, and continuation bounds; snapshot data never chooses runtime
policy. The `snapshot_max_bytes` default used by the conformance probe is
16 MiB.

## Physical fanout result

The exact release-pin benchmark creates 32 terminals, feeds 10,000 styled CJK
lines to each, materializes a plain-text history projection, and holds every
terminal live for `ps`, `footprint`, and `vmmap` inspection. Its third argument
is the per-terminal scrollback-byte setting:

```sh
OURO_BENCH_HOLD_SECONDS=8 \
  target/release/examples/fanout_memory 32 10000 8388608
```

Compression is opt-in for this benchmark; the default remains the
uncompressed baseline. Incremental and full comparison runs are explicit:

```sh
GHOSTTY_VT_PREFIX=/absolute/path/to/libghostty-prefix \
  cargo build -p ouro-terminal-ghostty --release --example fanout_memory \
  --features benchmark-full-compression

OURO_BENCH_COMPRESSION=incremental OURO_BENCH_HOLD_SECONDS=8 \
  target/release/examples/fanout_memory 32 10000 8388608

OURO_BENCH_COMPRESSION=full OURO_BENCH_HOLD_SECONDS=8 \
  target/release/examples/fanout_memory 32 10000 8388608
```

The allocator shrink fix did not reduce the 8 MiB-scrollback footprint:
RSS moved only from 262,800 KiB to 262,848 KiB in comparable runs, and
`phys_footprint` remained approximately 256 MiB. `vmmap` identified 128 live
`Memory Tag 240` regions, four per terminal. The exact pin declares tag 240
for its Darwin page allocator and `src/terminal/page.zig` always allocates page
backing through direct `mmap`, outside the public custom allocator.

The same workload produced this scrollback matrix after the shrink fix:

| Per-terminal setting | Retained markers | RSS | `phys_footprint` | Tag 240 resident |
|---:|---:|---:|---:|---:|
| 256 KiB | 15,872 | 31,360 KiB | 31,015,272 B | 27.0 MiB |
| 512 KiB | 15,872 | 31,344 KiB | 30,998,888 B | 27.0 MiB |
| 1 MiB | 15,872 | 31,328 KiB | 30,982,504 B | 27.0 MiB |
| 2 MiB | 53,888 | 69,408 KiB | 70,042,056 B | 64.0 MiB |
| 4 MiB | 117,248 | 133,952 KiB | 136,135,112 B | 126.5 MiB |
| 8 MiB | 243,968 | 263,328 KiB | 268,698,176 B | 252.0 MiB |

The lower three settings all hit the same physical floor: roughly 864 KiB of
tag-240 resident memory per terminal and 496 retained markers per terminal.
Above that floor, resident page memory tracks scrollback policy closely. This
proves that a process/global budget, lower history for offscreen sessions,
lazy restore, or an upstream page-allocator API is required for a true fanout
memory cap; ABI v4's requested-byte allocator cannot provide one alone.

The ABI-v4 release benchmark compares the same 32 × 10,000 × 8 MiB state after
population. All modes retained 243,968 line markers and reported zero allocator
failures:

| Mode | Steps | Compression time | Requested live | `ps` RSS | `phys_footprint` |
|---|---:|---:|---:|---:|---:|
| none | 0 | 0 ms | 893,504 B | 262,912 KiB | 268,239,424 B |
| incremental | 704 | 52 ms | 8,762,186 B | 284,768 KiB | 28,475,968 B |
| full (benchmark only) | 32 | 52 ms | 8,762,186 B | 284,816 KiB | 28,525,120 B |

Incremental compression reduced `phys_footprint` by 89.38% and converged to
the same reclaimed state as FULL while dividing work into 704 bounded steps.
Requested live bytes rose because compressed payloads are allocator-mediated.
`ps` RSS also rose because the retained but clean direct mappings remain in the
resident address set; it is not evidence that those pages remain physically
charged. `footprint` showed the same 128 direct page regions moving from
264,241,152 B dirty in the baseline to 15,204,352 B dirty plus 262,144,000 B
reclaimable after either compression mode. The corresponding
`phys_footprint_peak` remained approximately 269 MiB because this benchmark
deliberately populates every session before it compresses them. FULL remains
unsuitable for the product hot path. ABI v4 lets the terminal owner schedule
the bounded steps only after an activity-token-based idle delay.

Pinned-upstream limits discovered by this gate:

- snapshot format version 1 explicitly has no binary-compatibility guarantee;
- `allocator.h` describes `alignment` as a raw power of two from 1 through 16,
  but this pin's `src/lib/allocator.zig` actually passes the numeric value of
  Zig's `std.mem.Alignment` enum: log2 encodings 0 through 4. ABI v4 follows
  the linked implementation, validates that range on every allocator callback,
  and validates returned pointers against `1 << alignment` bytes;
- native page storage is deliberately allocated by direct OS mappings rather
  than `GhosttyAllocator`. This excludes the dominant scrollback footprint
  and decoded page expansion from ABI v4 accounting; restore is source-size
  bounded but not hard physical-memory bounded at this pin;
- a decoder restores an unfinished parser with continuation tracking disabled.
  Re-enabling the runtime cap after restore cannot reconstruct the already-read
  continuation prefix, so an immediate second snapshot is rejected by upstream.
  Feeding the sequence to ground repairs tracking, after which re-encoding is
  byte-for-byte identical at this pin;
- the decoder intentionally permits bytes after `FINISH`; ABI v2 rejects them
  by requiring the reported source offset to equal the borrowed input length.

It intentionally does not claim Metal rendering, CoreText shaping, IME,
selection, mouse/key encoding, PTY ownership, shell-integration prompt redraw,
or production RSS superiority. Snapshot/accounting/compression ABI v4 is still
a promotion gate, not production renderer adoption. Direct `mmap` page backing
remains outside `engine_memory_max_bytes`; neither compression nor requested-
byte accounting is a process/global physical-memory hard cap.
