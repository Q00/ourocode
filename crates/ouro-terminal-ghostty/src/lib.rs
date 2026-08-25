use std::ffi::c_void;
use std::ptr::NonNull;
use std::sync::Arc;

/// Version of the Ourocode-owned C terminal engine ABI used by this wrapper.
pub const TERMINAL_ENGINE_ABI_VERSION: u32 = 6;
pub const GHOSTTY_SOURCE_COMMIT: &str = "136f436a3bbb14fd48d18e927a83fc6585d5a63c";
pub const GHOSTTY_SNAPSHOT_MAGIC: &str = "GHOSTSNP";
pub const GHOSTTY_SNAPSHOT_FORMAT_VERSION: u32 = 1;
pub const GHOSTTY_UNICODE_WIDTH_POLICY: &str = "ghostty-exact-pin";
pub const GHOSTTY_GRAPHICS_POLICY: &str = "disabled-until-global-byte-budget";
pub const MAX_TERMINAL_METADATA_BYTES: usize = 4 * 1024;

mod render;
pub use render::*;
mod input;
pub use input::*;
mod viewport;
use input::{RawInputOwner, RawSelectionOwner};
pub use viewport::*;

#[repr(C)]
struct RawConfig {
    size: usize,
    abi_version: u32,
    columns: u16,
    rows: u16,
    cell_width_px: u32,
    cell_height_px: u32,
    scrollback_max_bytes: usize,
    scrollback_max_lines: usize,
    kitty_image_max_bytes: u64,
    apc_max_bytes: usize,
    continuation_max_bytes: usize,
    snapshot_max_bytes: usize,
    engine_memory_max_bytes: usize,
}

#[repr(C)]
struct RawFrameInfo {
    size: usize,
    abi_version: u32,
    columns: u16,
    rows: u16,
    cursor_x: u16,
    cursor_y: u16,
    dirty: i32,
}

#[repr(C)]
struct RawMemoryInfo {
    size: usize,
    abi_version: u32,
    live_bytes: usize,
    peak_bytes: usize,
    limit_bytes: usize,
    allocation_failures: u64,
}

#[repr(C)]
struct RawPageBudgetStats {
    size: usize,
    abi_version: u32,
    limit_bytes: usize,
    reserved_bytes: usize,
    peak_reserved_bytes: usize,
    denial_count: usize,
    child_failure_count: usize,
}

extern "C" {
    fn ouro_terminal_new(config: *const RawConfig, out: *mut *mut c_void) -> i32;
    fn ouro_terminal_new_with_page_budget(
        config: *const RawConfig,
        page_budget: *mut c_void,
        out: *mut *mut c_void,
    ) -> i32;
    fn ouro_terminal_page_budget_new(limit_bytes: usize, out: *mut *mut c_void) -> i32;
    fn ouro_terminal_page_budget_free(page_budget: *mut c_void);
    fn ouro_terminal_page_budget_stats(
        page_budget: *mut c_void,
        out: *mut RawPageBudgetStats,
    ) -> i32;
    fn ouro_terminal_free(terminal: *mut c_void);
    fn ouro_terminal_feed(terminal: *mut c_void, bytes: *const u8, length: usize) -> i32;
    fn ouro_terminal_take_pty_responses(
        terminal: *mut c_void,
        buffer: *mut u8,
        capacity: usize,
        out_length: *mut usize,
    ) -> i32;
    fn ouro_terminal_take_bells(terminal: *mut c_void, out_count: *mut u32) -> i32;
    fn ouro_terminal_hyperlink_uri_at_viewport(
        terminal: *mut c_void,
        column: u16,
        row: u32,
        buffer: *mut u8,
        capacity: usize,
        out_length: *mut usize,
    ) -> i32;
    fn ouro_terminal_copy_title(
        terminal: *mut c_void,
        buffer: *mut u8,
        capacity: usize,
        out_length: *mut usize,
    ) -> i32;
    fn ouro_terminal_copy_pwd(
        terminal: *mut c_void,
        buffer: *mut u8,
        capacity: usize,
        out_length: *mut usize,
    ) -> i32;
    fn ouro_terminal_metadata_epoch(terminal: *mut c_void, out_epoch: *mut u64) -> i32;
    fn ouro_terminal_resize(
        terminal: *mut c_void,
        columns: u16,
        rows: u16,
        cell_width_px: u32,
        cell_height_px: u32,
    ) -> i32;
    fn ouro_terminal_frame_info(terminal: *mut c_void, out: *mut RawFrameInfo) -> i32;
    fn ouro_terminal_memory_info(terminal: *mut c_void, out: *mut RawMemoryInfo) -> i32;
    fn ouro_terminal_compression_activity(terminal: *mut c_void, out_activity: *mut u64) -> i32;
    fn ouro_terminal_compress_incremental(terminal: *mut c_void, out_result: *mut i32) -> i32;
    #[cfg(feature = "benchmark-full-compression")]
    fn ouro_terminal_compress_full_for_testing(terminal: *mut c_void, out_result: *mut i32) -> i32;
    fn ouro_terminal_copy_plain_text(
        terminal: *mut c_void,
        buffer: *mut u8,
        capacity: usize,
        out_length: *mut usize,
    ) -> i32;
    fn ouro_terminal_copy_snapshot(
        terminal: *mut c_void,
        buffer: *mut u8,
        capacity: usize,
        out_length: *mut usize,
    ) -> i32;
    fn ouro_terminal_restore(
        config: *const RawConfig,
        snapshot: *const u8,
        length: usize,
        out: *mut *mut c_void,
    ) -> i32;
    fn ouro_terminal_restore_with_page_budget(
        config: *const RawConfig,
        page_budget: *mut c_void,
        snapshot: *const u8,
        length: usize,
        out: *mut *mut c_void,
    ) -> i32;
}

#[derive(Clone, Copy, Debug)]
pub struct Config {
    pub columns: u16,
    pub rows: u16,
    pub cell_width_px: u32,
    pub cell_height_px: u32,
    pub scrollback_max_bytes: usize,
    pub scrollback_max_lines: usize,
    pub kitty_image_max_bytes: u64,
    pub apc_max_bytes: usize,
    pub continuation_max_bytes: usize,
    /// Hard limit for both exported and restored engine snapshots.
    pub snapshot_max_bytes: usize,
    /// Hard limit for allocations routed through GhosttyAllocator.
    /// Native terminal-page mmap regions are outside this budget.
    pub engine_memory_max_bytes: usize,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            columns: 120,
            rows: 40,
            cell_width_px: 8,
            cell_height_px: 16,
            scrollback_max_bytes: 8 * 1024 * 1024,
            scrollback_max_lines: 10_000,
            // Images remain disabled until the app has a global byte budget.
            kitty_image_max_bytes: 0,
            apc_max_bytes: 1024 * 1024,
            continuation_max_bytes: 64 * 1024,
            snapshot_max_bytes: 16 * 1024 * 1024,
            engine_memory_max_bytes: 32 * 1024 * 1024,
        }
    }
}

impl Config {
    fn raw(self) -> RawConfig {
        RawConfig {
            size: std::mem::size_of::<RawConfig>(),
            abi_version: TERMINAL_ENGINE_ABI_VERSION,
            columns: self.columns,
            rows: self.rows,
            cell_width_px: self.cell_width_px,
            cell_height_px: self.cell_height_px,
            scrollback_max_bytes: self.scrollback_max_bytes,
            scrollback_max_lines: self.scrollback_max_lines,
            kitty_image_max_bytes: self.kitty_image_max_bytes,
            apc_max_bytes: self.apc_max_bytes,
            continuation_max_bytes: self.continuation_max_bytes,
            snapshot_max_bytes: self.snapshot_max_bytes,
            engine_memory_max_bytes: self.engine_memory_max_bytes,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Dirty {
    None,
    Partial,
    Full,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FrameInfo {
    pub columns: u16,
    pub rows: u16,
    pub cursor_x: u16,
    pub cursor_y: u16,
    pub dirty: Dirty,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MemoryInfo {
    pub live_bytes: usize,
    pub peak_bytes: usize,
    pub limit_bytes: usize,
    pub allocation_failures: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PageBudgetStats {
    pub limit_bytes: usize,
    pub reserved_bytes: usize,
    pub peak_reserved_bytes: usize,
    pub denial_count: usize,
    pub child_failure_count: usize,
}

#[derive(Clone, Debug)]
pub struct PageBudget {
    inner: Arc<PageBudgetInner>,
}

#[derive(Debug)]
struct PageBudgetInner {
    raw: NonNull<c_void>,
}

// The opaque upstream budget uses atomic accounting and its adapter-owned
// references outlive synchronous calls. Rust shares only this stable handle.
unsafe impl Send for PageBudgetInner {}
unsafe impl Sync for PageBudgetInner {}

/// Scheduling result from a bounded idle-compression step.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CompressionStep {
    Unsupported,
    Pending,
    Complete,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    InvalidArgument,
    OutOfMemory,
    Engine,
    BufferTooSmall,
    Unknown(i32),
}

fn result(code: i32) -> Result<(), Error> {
    match code {
        0 => Ok(()),
        1 => Err(Error::InvalidArgument),
        2 => Err(Error::OutOfMemory),
        3 => Err(Error::Engine),
        4 => Err(Error::BufferTooSmall),
        other => Err(Error::Unknown(other)),
    }
}

fn compression_step(raw: i32) -> Result<CompressionStep, Error> {
    match raw {
        0 => Ok(CompressionStep::Unsupported),
        1 => Ok(CompressionStep::Pending),
        2 => Ok(CompressionStep::Complete),
        _ => Err(Error::Engine),
    }
}

impl PageBudget {
    pub fn new(limit_bytes: usize) -> Result<Self, Error> {
        let mut raw = std::ptr::null_mut();
        // SAFETY: `raw` is a valid writable out pointer for this synchronous call.
        result(unsafe { ouro_terminal_page_budget_new(limit_bytes, &mut raw) })?;
        Ok(Self {
            inner: Arc::new(PageBudgetInner {
                raw: NonNull::new(raw).ok_or(Error::Engine)?,
            }),
        })
    }

    pub fn stats(&self) -> Result<PageBudgetStats, Error> {
        let mut raw = RawPageBudgetStats {
            size: std::mem::size_of::<RawPageBudgetStats>(),
            abi_version: TERMINAL_ENGINE_ABI_VERSION,
            limit_bytes: 0,
            reserved_bytes: 0,
            peak_reserved_bytes: 0,
            denial_count: 0,
            child_failure_count: 0,
        };
        // SAFETY: the Arc keeps the opaque handle alive and `raw` is writable.
        result(unsafe { ouro_terminal_page_budget_stats(self.inner.raw.as_ptr(), &mut raw) })?;
        Ok(PageBudgetStats {
            limit_bytes: raw.limit_bytes,
            reserved_bytes: raw.reserved_bytes,
            peak_reserved_bytes: raw.peak_reserved_bytes,
            denial_count: raw.denial_count,
            child_failure_count: raw.child_failure_count,
        })
    }
}

impl Drop for PageBudgetInner {
    fn drop(&mut self) {
        // SAFETY: this Arc-owned caller reference is released exactly once.
        unsafe { ouro_terminal_page_budget_free(self.raw.as_ptr()) };
    }
}

pub struct Terminal {
    raw: NonNull<c_void>,
    snapshot_max_bytes: usize,
    page_budget: Option<PageBudget>,
    input: Option<RawInputOwner>,
    selection: Option<RawSelectionOwner>,
}

// The C handle has unique ownership, all mutation requires `&mut self`, and
// the exact-pin libghostty terminal has no thread affinity. Moving the owner
// between threads is safe; concurrent access is intentionally not exposed.
unsafe impl Send for Terminal {}

impl Terminal {
    pub fn new(config: Config) -> Result<Self, Error> {
        let raw_config = config.raw();
        let mut raw = std::ptr::null_mut();
        // SAFETY: raw_config and out pointer are valid for the duration of the call.
        result(unsafe { ouro_terminal_new(&raw_config, &mut raw) })?;
        let raw = NonNull::new(raw).ok_or(Error::Engine)?;
        Ok(Self {
            raw,
            snapshot_max_bytes: config.snapshot_max_bytes,
            page_budget: None,
            input: None,
            selection: None,
        })
    }

    /// Creates a terminal whose native page mappings share `page_budget`.
    pub fn new_with_page_budget(config: Config, page_budget: &PageBudget) -> Result<Self, Error> {
        let raw_config = config.raw();
        let mut raw = std::ptr::null_mut();
        // SAFETY: all borrowed inputs and the out pointer remain valid for the call.
        result(unsafe {
            ouro_terminal_new_with_page_budget(
                &raw_config,
                page_budget.inner.raw.as_ptr(),
                &mut raw,
            )
        })?;
        let raw = NonNull::new(raw).ok_or(Error::Engine)?;
        Ok(Self {
            raw,
            snapshot_max_bytes: config.snapshot_max_bytes,
            page_budget: Some(page_budget.clone()),
            input: None,
            selection: None,
        })
    }

    /// Restores an engine-owned snapshot under the resource bounds in `config`.
    ///
    /// Snapshots are opaque and must only be passed back to this ABI. Malformed,
    /// truncated, version-mismatched, and over-limit inputs fail closed.
    pub fn restore(config: Config, snapshot: &[u8]) -> Result<Self, Error> {
        if snapshot.len() > config.snapshot_max_bytes {
            return Err(Error::InvalidArgument);
        }

        let raw_config = config.raw();
        let mut raw = std::ptr::null_mut();
        // SAFETY: config, snapshot, and out remain valid for this synchronous call.
        result(unsafe {
            ouro_terminal_restore(&raw_config, snapshot.as_ptr(), snapshot.len(), &mut raw)
        })?;
        let raw = NonNull::new(raw).ok_or(Error::Engine)?;
        Ok(Self {
            raw,
            snapshot_max_bytes: config.snapshot_max_bytes,
            page_budget: None,
            input: None,
            selection: None,
        })
    }

    /// Restores a snapshot while charging native page mappings to a shared budget.
    pub fn restore_with_page_budget(
        config: Config,
        page_budget: &PageBudget,
        snapshot: &[u8],
    ) -> Result<Self, Error> {
        if snapshot.len() > config.snapshot_max_bytes {
            return Err(Error::InvalidArgument);
        }

        let raw_config = config.raw();
        let mut raw = std::ptr::null_mut();
        // SAFETY: all borrowed inputs and the out pointer remain valid for the call.
        result(unsafe {
            ouro_terminal_restore_with_page_budget(
                &raw_config,
                page_budget.inner.raw.as_ptr(),
                snapshot.as_ptr(),
                snapshot.len(),
                &mut raw,
            )
        })?;
        let raw = NonNull::new(raw).ok_or(Error::Engine)?;
        Ok(Self {
            raw,
            snapshot_max_bytes: config.snapshot_max_bytes,
            page_budget: Some(page_budget.clone()),
            input: None,
            selection: None,
        })
    }

    pub fn page_budget(&self) -> Option<&PageBudget> {
        self.page_budget.as_ref()
    }

    /// Feeds PTY bytes into the terminal.
    ///
    /// `OutOfMemory` means the exact-pin upstream engine may already have
    /// applied an arbitrary prefix because its write API returns no status.
    /// The owner must discard this terminal and resynchronize from its last
    /// checkpoint plus ordered event tail. Retrying `bytes` on this handle can
    /// duplicate a prefix. Empty input is always a successful no-op.
    pub fn feed(&mut self, bytes: &[u8]) -> Result<(), Error> {
        // SAFETY: the adapter copies/processes bytes synchronously and the handle is owned.
        result(unsafe { ouro_terminal_feed(self.raw.as_ptr(), bytes.as_ptr(), bytes.len()) })
    }

    /// Drains bounded device-query responses generated by the latest feed.
    pub fn take_pty_responses(&mut self) -> Result<Vec<u8>, Error> {
        let mut output = vec![0u8; 65_536];
        let mut length = 0;
        // SAFETY: output is writable for its capacity and mutation is serialized.
        result(unsafe {
            ouro_terminal_take_pty_responses(
                self.raw.as_ptr(),
                output.as_mut_ptr(),
                output.len(),
                &mut length,
            )
        })?;
        if length > output.len() {
            return Err(Error::Engine);
        }
        output.truncate(length);
        Ok(output)
    }

    pub fn take_bells(&mut self) -> Result<u32, Error> {
        let mut count = 0;
        // SAFETY: count is a valid writable output and mutation is serialized.
        result(unsafe { ouro_terminal_take_bells(self.raw.as_ptr(), &mut count) })?;
        Ok(count)
    }

    pub fn hyperlink_uri_at_viewport(
        &mut self,
        column: u16,
        row: u32,
        maximum_bytes: usize,
    ) -> Result<Option<Vec<u8>>, Error> {
        if maximum_bytes == 0 {
            return Err(Error::InvalidArgument);
        }
        let mut required = 0;
        // SAFETY: a null buffer with zero capacity is the documented query.
        let query = unsafe {
            ouro_terminal_hyperlink_uri_at_viewport(
                self.raw.as_ptr(),
                column,
                row,
                std::ptr::null_mut(),
                0,
                &mut required,
            )
        };
        if query == 5 {
            return Ok(None);
        }
        if query != 4 {
            result(query)?;
        }
        // `NO_VALUE` is the only absence result in the adapter contract.
        // Never let an invalid coordinate or engine failure with a cleared
        // output length masquerade as a cell without a hyperlink.
        if required == 0 {
            return Err(Error::Engine);
        }
        if required > maximum_bytes {
            return Err(Error::BufferTooSmall);
        }
        let mut bytes = vec![0; required];
        // SAFETY: bytes owns the exact queried writable capacity.
        result(unsafe {
            ouro_terminal_hyperlink_uri_at_viewport(
                self.raw.as_ptr(),
                column,
                row,
                bytes.as_mut_ptr(),
                bytes.len(),
                &mut required,
            )
        })?;
        if required > bytes.len() {
            return Err(Error::Engine);
        }
        bytes.truncate(required);
        Ok(Some(bytes))
    }

    pub fn resize(
        &mut self,
        columns: u16,
        rows: u16,
        cell_width_px: u32,
        cell_height_px: u32,
    ) -> Result<(), Error> {
        // SAFETY: the handle is owned and mutation is serialized through &mut self.
        result(unsafe {
            ouro_terminal_resize(
                self.raw.as_ptr(),
                columns,
                rows,
                cell_width_px,
                cell_height_px,
            )
        })
    }

    pub fn frame_info(&mut self) -> Result<FrameInfo, Error> {
        let mut raw = RawFrameInfo {
            size: std::mem::size_of::<RawFrameInfo>(),
            abi_version: TERMINAL_ENGINE_ABI_VERSION,
            columns: 0,
            rows: 0,
            cursor_x: 0,
            cursor_y: 0,
            dirty: 0,
        };
        // SAFETY: raw is a correctly sized writable output value and handle is owned.
        result(unsafe { ouro_terminal_frame_info(self.raw.as_ptr(), &mut raw) })?;
        let dirty = match raw.dirty {
            0 => Dirty::None,
            1 => Dirty::Partial,
            2 => Dirty::Full,
            _ => return Err(Error::Engine),
        };
        Ok(FrameInfo {
            columns: raw.columns,
            rows: raw.rows,
            cursor_x: raw.cursor_x,
            cursor_y: raw.cursor_y,
            dirty,
        })
    }

    /// Reports exact requested-byte accounting for GhosttyAllocator-mediated
    /// allocations. It does not include native terminal-page mmap regions or
    /// represent a process RSS/physical-footprint hard cap.
    pub fn memory_info(&self) -> Result<MemoryInfo, Error> {
        let mut raw = RawMemoryInfo {
            size: std::mem::size_of::<RawMemoryInfo>(),
            abi_version: TERMINAL_ENGINE_ABI_VERSION,
            live_bytes: 0,
            peak_bytes: 0,
            limit_bytes: 0,
            allocation_failures: 0,
        };
        // SAFETY: raw is a correctly sized writable output value and this call
        // only reads the engine's serialized allocation counters.
        result(unsafe { ouro_terminal_memory_info(self.raw.as_ptr(), &mut raw) })?;
        Ok(MemoryInfo {
            live_bytes: raw.live_bytes,
            peak_bytes: raw.peak_bytes,
            limit_bytes: raw.limit_bytes,
            allocation_failures: raw.allocation_failures,
        })
    }

    /// Returns the opaque token used to postpone idle compression after
    /// compression-relevant terminal activity. Only equality is meaningful.
    pub fn compression_activity(&self) -> Result<u64, Error> {
        let mut activity = 0;
        // SAFETY: activity is a valid writable output and the call only reads
        // serialized engine state.
        result(unsafe { ouro_terminal_compression_activity(self.raw.as_ptr(), &mut activity) })?;
        Ok(activity)
    }

    /// Performs one bounded compression step suitable for an idle callback.
    ///
    /// The owner should call this again for `Pending` only while the terminal
    /// remains idle and the activity token is unchanged. The mutable borrow
    /// serializes compression with every other terminal operation.
    pub fn compress_incremental_step(&mut self) -> Result<CompressionStep, Error> {
        let mut raw = -1;
        // SAFETY: raw is a valid writable output and &mut self provides unique,
        // serialized access to the terminal during this synchronous step.
        result(unsafe { ouro_terminal_compress_incremental(self.raw.as_ptr(), &mut raw) })?;
        compression_step(raw)
    }

    /// Performs a synchronous full scan for conformance tests and benchmarks.
    ///
    /// This must not be used on the product hot path: work grows with retained
    /// history and can stall the terminal owner.
    #[doc(hidden)]
    #[cfg(feature = "benchmark-full-compression")]
    pub fn compress_full_for_benchmark(&mut self) -> Result<CompressionStep, Error> {
        let mut raw = -1;
        // SAFETY: raw is a valid writable output and &mut self serializes the
        // synchronous benchmark-only scan with all terminal operations.
        result(unsafe { ouro_terminal_compress_full_for_testing(self.raw.as_ptr(), &mut raw) })?;
        compression_step(raw)
    }

    pub fn plain_text(&mut self) -> Result<Vec<u8>, Error> {
        let mut length = 0;
        // SAFETY: a null buffer with zero capacity is the documented size query.
        let query = unsafe {
            ouro_terminal_copy_plain_text(self.raw.as_ptr(), std::ptr::null_mut(), 0, &mut length)
        };
        if query != 0 && query != 4 {
            result(query)?;
        }

        let mut bytes = vec![0; length];
        // SAFETY: bytes owns at least length writable bytes for the synchronous copy.
        result(unsafe {
            ouro_terminal_copy_plain_text(
                self.raw.as_ptr(),
                bytes.as_mut_ptr(),
                bytes.len(),
                &mut length,
            )
        })?;
        bytes.truncate(length);
        Ok(bytes)
    }

    fn copy_metadata(
        &self,
        copy: unsafe extern "C" fn(*mut c_void, *mut u8, usize, *mut usize) -> i32,
    ) -> Result<Vec<u8>, Error> {
        let mut length = 0;
        let query = unsafe { copy(self.raw.as_ptr(), std::ptr::null_mut(), 0, &mut length) };
        if query != 0 && query != 4 {
            result(query)?;
        }
        if length > MAX_TERMINAL_METADATA_BYTES {
            return Err(Error::BufferTooSmall);
        }
        let mut bytes = vec![0; length];
        result(unsafe {
            copy(
                self.raw.as_ptr(),
                bytes.as_mut_ptr(),
                bytes.len(),
                &mut length,
            )
        })?;
        bytes.truncate(length);
        Ok(bytes)
    }

    pub fn title(&self) -> Result<Vec<u8>, Error> {
        self.copy_metadata(ouro_terminal_copy_title)
    }

    pub fn pwd(&self) -> Result<Vec<u8>, Error> {
        self.copy_metadata(ouro_terminal_copy_pwd)
    }

    pub fn metadata_epoch(&self) -> Result<u64, Error> {
        let mut epoch = 0;
        result(unsafe { ouro_terminal_metadata_epoch(self.raw.as_ptr(), &mut epoch) })?;
        Ok(epoch)
    }

    /// Copies the terminal's opaque, bounded persistence snapshot.
    pub fn snapshot(&mut self) -> Result<Vec<u8>, Error> {
        let mut length = 0;
        // SAFETY: a null buffer with zero capacity is the documented size query.
        let query = unsafe {
            ouro_terminal_copy_snapshot(self.raw.as_ptr(), std::ptr::null_mut(), 0, &mut length)
        };
        if query != 0 && query != 4 {
            result(query)?;
        }
        if length > self.snapshot_max_bytes {
            return Err(Error::BufferTooSmall);
        }

        let mut bytes = vec![0; length];
        // SAFETY: bytes owns `length` writable bytes for the synchronous copy.
        result(unsafe {
            ouro_terminal_copy_snapshot(
                self.raw.as_ptr(),
                bytes.as_mut_ptr(),
                bytes.len(),
                &mut length,
            )
        })?;
        if length > bytes.len() {
            return Err(Error::BufferTooSmall);
        }
        bytes.truncate(length);
        Ok(bytes)
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        if let Some(selection) = self.selection.take() {
            selection.free();
        }
        if let Some(input) = self.input.take() {
            input.free();
        }
        // SAFETY: this is the unique owned handle and Drop runs once.
        unsafe { ouro_terminal_free(self.raw.as_ptr()) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_page_budget_accounts_new_restore_and_release() {
        let config = Config {
            columns: 12,
            rows: 5,
            ..Config::default()
        };
        let budget = PageBudget::new(128 * 1024 * 1024).unwrap();
        assert_eq!(budget.stats().unwrap().reserved_bytes, 0);

        let mut source = Terminal::new_with_page_budget(config, &budget).unwrap();
        source.feed(b"shared-budget\r\n").unwrap();
        let source_reserved = budget.stats().unwrap().reserved_bytes;
        assert!(source_reserved > 0);
        let snapshot = source.snapshot().unwrap();

        let restored = Terminal::restore_with_page_budget(config, &budget, &snapshot).unwrap();
        assert!(budget.stats().unwrap().reserved_bytes > source_reserved);
        drop(restored);
        assert_eq!(budget.stats().unwrap().reserved_bytes, source_reserved);
        drop(source);
        assert_eq!(budget.stats().unwrap().reserved_bytes, 0);
    }

    #[test]
    fn shared_page_budget_allows_normal_pagelist_growth_fallback() {
        let budget = PageBudget::new(512 * 1024 * 1024).unwrap();
        let mut terminal = Terminal::new_with_page_budget(
            Config {
                columns: 120,
                rows: 40,
                scrollback_max_bytes: 8 * 1024 * 1024,
                scrollback_max_lines: 10_000,
                engine_memory_max_bytes: 16 * 1024 * 1024,
                ..Config::default()
            },
            &budget,
        )
        .unwrap();

        for line in 0..10_000 {
            terminal
                .feed(
                    format!(
                        "\x1b[3{}mS00 L{line:05} 한글 e\u{301} 🌊 abcdefghijklmnopqrstuvwxyz\x1b[0m\r\n",
                        line % 8
                    )
                    .as_bytes(),
                )
                .unwrap();
        }

        let populated = budget.stats().unwrap();
        assert!(populated.reserved_bytes > 0);
        assert!(populated.reserved_bytes <= populated.limit_bytes);
        assert_eq!(populated.denial_count, 0);
        assert_eq!(populated.child_failure_count, 0);
        drop(terminal);
        assert_eq!(budget.stats().unwrap().reserved_bytes, 0);
    }

    #[test]
    fn tiny_shared_page_budget_rejects_terminal_creation() {
        let budget = PageBudget::new(1).unwrap();
        assert!(matches!(
            Terminal::new_with_page_budget(Config::default(), &budget),
            Err(Error::OutOfMemory)
        ));
        let stats = budget.stats().unwrap();
        assert!(stats.denial_count > 0);
        assert_eq!(stats.reserved_bytes, 0);
    }

    #[test]
    fn public_adapter_preserves_content_across_resize_round_trip() {
        let mut terminal = Terminal::new(Config {
            columns: 12,
            rows: 6,
            ..Config::default()
        })
        .unwrap();
        terminal
            .feed(b"ABCDEFGHIJ\r\n\x1b[1;32mstyled\x1b[0m \xed\x95\x9c\xea\xb8\x80\r\n")
            .unwrap();

        let frame = terminal.frame_info().unwrap();
        assert_eq!((frame.columns, frame.rows), (12, 6));
        assert_ne!(frame.dirty, Dirty::None);

        terminal.resize(5, 10, 8, 16).unwrap();
        terminal.resize(12, 6, 8, 16).unwrap();
        let text = String::from_utf8(terminal.plain_text().unwrap()).unwrap();
        assert!(text.contains("ABCDEFGHIJ"));
        assert!(text.contains("styled"));
        assert!(text.contains("한글"));
    }

    #[test]
    fn bell_and_osc8_lookup_are_bounded_and_on_demand() {
        let mut terminal = Terminal::new(Config {
            columns: 24,
            rows: 6,
            ..Config::default()
        })
        .unwrap();
        terminal.feed(b"\x07\x07").unwrap();
        assert_eq!(terminal.take_bells().unwrap(), 2);
        assert_eq!(terminal.take_bells().unwrap(), 0);

        terminal
            .feed(b"\x1b]0;Build Agent\x07\x1b]7;file://localhost/private/tmp\x07")
            .unwrap();
        assert_eq!(terminal.title().unwrap(), b"Build Agent");
        assert_eq!(terminal.pwd().unwrap(), b"file://localhost/private/tmp");

        terminal
            .feed(b"\x1b]8;;https://example.com/path?q=1\x1b\\linked\x1b]8;;\x1b\\")
            .unwrap();
        assert_eq!(
            terminal
                .hyperlink_uri_at_viewport(0, 0, 4096)
                .unwrap()
                .as_deref(),
            Some(b"https://example.com/path?q=1".as_slice())
        );
        assert_eq!(
            terminal.hyperlink_uri_at_viewport(12, 0, 4096).unwrap(),
            None
        );
        assert!(matches!(
            terminal.hyperlink_uri_at_viewport(u16::MAX, u32::MAX, 4096),
            Err(Error::InvalidArgument)
        ));
        assert!(matches!(
            terminal.hyperlink_uri_at_viewport(0, 0, 4),
            Err(Error::BufferTooSmall)
        ));

        let mut invalid_utf8 = Terminal::new(Config {
            columns: 24,
            rows: 6,
            ..Config::default()
        })
        .unwrap();
        invalid_utf8
            .feed(b"\x1b]8;;https://example.com/\xff\x1b\\linked\x1b]8;;\x1b\\")
            .unwrap();
        assert_eq!(
            invalid_utf8
                .hyperlink_uri_at_viewport(0, 0, 4096)
                .unwrap()
                .as_deref(),
            Some(b"https://example.com/\xff".as_slice())
        );
    }

    #[test]
    fn snapshot_round_trips_styled_unicode_scrollback_and_resize() {
        let config = Config {
            columns: 10,
            rows: 4,
            ..Config::default()
        };
        let mut terminal = Terminal::new(config).unwrap();
        for line in 0..12 {
            terminal
                .feed(format!("\x1b[1;3{}mline-{line:02} 한글 🌊\x1b[0m\r\n", line % 8).as_bytes())
                .unwrap();
        }
        terminal.resize(7, 7, 9, 18).unwrap();
        terminal.feed(b"after-narrow\r\n").unwrap();
        terminal.resize(14, 5, 8, 16).unwrap();

        let before_text = terminal.plain_text().unwrap();
        let before_text_string = String::from_utf8(before_text.clone()).unwrap();
        assert!(before_text_string.contains("line-00"));
        assert!(before_text_string.contains("line-11"));
        assert!(before_text_string.contains("한글"));
        assert!(before_text_string.contains("🌊"));
        assert!(before_text_string.contains("after-narrow"));
        let before_frame = terminal.frame_info().unwrap();
        let snapshot = terminal.snapshot().unwrap();
        assert!(!snapshot.is_empty());

        let mut restored = Terminal::restore(config, &snapshot).unwrap();
        assert_eq!(restored.plain_text().unwrap(), before_text);
        let restored_frame = restored.frame_info().unwrap();
        assert_eq!(
            (restored_frame.columns, restored_frame.rows),
            (before_frame.columns, before_frame.rows)
        );
        assert_eq!((restored_frame.columns, restored_frame.rows), (14, 5));
        assert_eq!(restored.snapshot().unwrap(), snapshot);
    }

    #[test]
    fn restore_rejects_corrupt_truncated_and_oversized_snapshots() {
        let config = Config {
            columns: 10,
            rows: 4,
            ..Config::default()
        };
        let mut terminal = Terminal::new(config).unwrap();
        terminal.feed(b"snapshot-integrity\r\n").unwrap();
        let snapshot = terminal.snapshot().unwrap();
        assert!(snapshot.len() > 1);

        let mut corrupt = snapshot.clone();
        let middle = corrupt.len() / 2;
        corrupt[middle] ^= 0x5a;
        assert!(matches!(
            Terminal::restore(config, &corrupt),
            Err(Error::Engine)
        ));
        assert!(matches!(
            Terminal::restore(config, &snapshot[..snapshot.len() - 1]),
            Err(Error::Engine)
        ));

        let bounded = Config {
            snapshot_max_bytes: snapshot.len() - 1,
            ..config
        };
        assert!(matches!(
            Terminal::restore(bounded, &snapshot),
            Err(Error::InvalidArgument)
        ));

        let mut export_bounded = Terminal::new(Config {
            snapshot_max_bytes: 32,
            ..config
        })
        .unwrap();
        export_bounded
            .feed(b"this terminal snapshot cannot fit within thirty-two bytes")
            .unwrap();
        assert!(matches!(
            export_bounded.snapshot(),
            Err(Error::BufferTooSmall)
        ));
    }

    #[test]
    fn engine_memory_accounting_is_bounded_and_releases_temporary_work() {
        let config = Config {
            columns: 16,
            rows: 5,
            ..Config::default()
        };
        let mut terminal = Terminal::new(config).unwrap();
        let created = terminal.memory_info().unwrap();
        assert_eq!(created.limit_bytes, config.engine_memory_max_bytes);
        assert!(created.live_bytes <= created.limit_bytes);
        assert!(created.peak_bytes >= created.live_bytes);

        for line in 0..64 {
            terminal
                .feed(format!("history-{line:02}-abcdefghij\r\n").as_bytes())
                .unwrap();
        }
        let populated = terminal.memory_info().unwrap();
        assert!(populated.live_bytes <= populated.limit_bytes);
        assert!(populated.peak_bytes >= created.peak_bytes);

        let formatter_baseline = populated.live_bytes;
        let _text = terminal.plain_text().unwrap();
        let after_formatter = terminal.memory_info().unwrap();
        assert_eq!(after_formatter.live_bytes, formatter_baseline);
        assert!(after_formatter.peak_bytes >= populated.peak_bytes);
        assert!(after_formatter.live_bytes <= after_formatter.limit_bytes);

        let snapshot_baseline = after_formatter.live_bytes;
        let snapshot = terminal.snapshot().unwrap();
        let after_snapshot = terminal.memory_info().unwrap();
        assert_eq!(after_snapshot.live_bytes, snapshot_baseline);
        assert!(after_snapshot.peak_bytes >= after_formatter.peak_bytes);
        assert!(after_snapshot.live_bytes <= after_snapshot.limit_bytes);

        let mut restored = Terminal::restore(config, &snapshot).unwrap();
        let restored_baseline = restored.memory_info().unwrap();
        assert_eq!(
            restored_baseline.limit_bytes,
            config.engine_memory_max_bytes
        );
        assert!(restored_baseline.live_bytes <= restored_baseline.limit_bytes);
        let _restored_text = restored.plain_text().unwrap();
        assert_eq!(
            restored.memory_info().unwrap().live_bytes,
            restored_baseline.live_bytes
        );
    }

    #[test]
    fn incremental_idle_compression_is_typed_and_content_preserving() {
        let config = Config {
            columns: 24,
            rows: 6,
            scrollback_max_bytes: 8 * 1024 * 1024,
            scrollback_max_lines: 10_000,
            ..Config::default()
        };
        let mut terminal = Terminal::new(config).unwrap();
        let initial_activity = terminal.compression_activity().unwrap();
        for line in 0..512 {
            terminal
                .feed(
                    format!(
                        "\x1b[3{}mline-{line:04} 한글 e\u{301} 🌊\x1b[0m\r\n",
                        line % 8
                    )
                    .as_bytes(),
                )
                .unwrap();
        }
        let populated_activity = terminal.compression_activity().unwrap();
        assert_ne!(populated_activity, initial_activity);
        let before = terminal.plain_text().unwrap();
        let before_snapshot = terminal.snapshot().unwrap();

        let mut steps = 0usize;
        let final_step = loop {
            steps += 1;
            assert!(steps <= 2_048, "incremental compression did not converge");
            match terminal.compress_incremental_step().unwrap() {
                CompressionStep::Pending => continue,
                terminal_step => break terminal_step,
            }
        };
        assert!(matches!(
            final_step,
            CompressionStep::Complete | CompressionStep::Unsupported
        ));
        assert_eq!(terminal.compression_activity().unwrap(), populated_activity);
        assert_eq!(terminal.plain_text().unwrap(), before);
        assert_eq!(terminal.snapshot().unwrap(), before_snapshot);
    }

    #[test]
    #[cfg(feature = "benchmark-full-compression")]
    fn benchmark_only_full_compression_has_no_pending_continuation() {
        let mut terminal = Terminal::new(Config {
            columns: 16,
            rows: 5,
            ..Config::default()
        })
        .unwrap();
        for line in 0..64 {
            terminal
                .feed(format!("full-{line:02}-abcdefghij\r\n").as_bytes())
                .unwrap();
        }
        assert!(matches!(
            terminal.compress_full_for_benchmark().unwrap(),
            CompressionStep::Complete | CompressionStep::Unsupported
        ));
    }

    #[test]
    fn tiny_engine_memory_budget_rejects_new_and_restore() {
        let tiny = Config {
            engine_memory_max_bytes: 1,
            ..Config::default()
        };
        assert!(matches!(Terminal::new(tiny), Err(Error::OutOfMemory)));

        let source_config = Config {
            columns: 10,
            rows: 4,
            ..Config::default()
        };
        let mut source = Terminal::new(source_config).unwrap();
        source.feed(b"restore-needs-engine-memory\r\n").unwrap();
        let snapshot = source.snapshot().unwrap();
        assert!(matches!(
            Terminal::restore(
                Config {
                    engine_memory_max_bytes: 1,
                    ..source_config
                },
                &snapshot
            ),
            Err(Error::OutOfMemory)
        ));
    }

    #[test]
    fn feed_surfaces_allocator_failure_and_empty_input_remains_a_noop() {
        let base = Config {
            columns: 16,
            rows: 5,
            ..Config::default()
        };
        let mut low = 1usize;
        let mut high = base.engine_memory_max_bytes;
        while low < high {
            let middle = low + (high - low) / 2;
            if Terminal::new(Config {
                engine_memory_max_bytes: middle,
                ..base
            })
            .is_ok()
            {
                high = middle;
            } else {
                low = middle + 1;
            }
        }

        let mut terminal = Terminal::new(Config {
            engine_memory_max_bytes: low,
            ..base
        })
        .unwrap();
        let before_empty = terminal.memory_info().unwrap();
        terminal.feed(&[]).unwrap();
        assert_eq!(terminal.memory_info().unwrap(), before_empty);

        let allocation_requiring_input =
            "\x1b]8;id=feed-oom;https://example.com/feed-oom\x1b\\linked-한국-🌊\x1b]8;;\x1b\\\r\n";
        assert_eq!(
            terminal.feed(allocation_requiring_input.as_bytes()),
            Err(Error::OutOfMemory)
        );
        assert!(terminal.memory_info().unwrap().allocation_failures > 0);
        // Do not inspect or retry the partially mutated terminal after OOM.
    }

    #[test]
    fn device_query_responses_are_bounded_and_drained_once() {
        let mut terminal = Terminal::new(Config::default()).unwrap();
        terminal.feed(b"\x1b[6n").unwrap();
        assert_eq!(terminal.take_pty_responses().unwrap(), b"\x1b[1;1R");
        assert!(terminal.take_pty_responses().unwrap().is_empty());
    }
}
