use super::{result, Error, Terminal, TERMINAL_ENGINE_ABI_VERSION};
use std::ffi::c_void;
use std::marker::PhantomData;
use std::ptr::NonNull;

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct RawRgb {
    r: u8,
    g: u8,
    b: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct RawColor {
    kind: i32,
    palette_index: u8,
    rgb: RawRgb,
}

#[repr(C)]
struct RawRenderFrameInfo {
    size: usize,
    abi_version: u32,
    generation: u64,
    dirty: i32,
    columns: u16,
    rows: u16,
    cursor_has_value: bool,
    cursor_x: u16,
    cursor_y: u16,
    cursor_wide_tail: bool,
    cursor_visible: bool,
    cursor_blinking: bool,
    cursor_password_input: bool,
    cursor_style: i32,
    background: RawRgb,
    foreground: RawRgb,
    cursor_color_has_value: bool,
    cursor_color: RawRgb,
    palette: [RawRgb; 256],
}

#[repr(C)]
struct RawRenderRowInfo {
    size: usize,
    abi_version: u32,
    y: u16,
    dirty: bool,
    selection_has_value: bool,
    selection_start_x: u16,
    selection_end_x: u16,
    wrap: bool,
    wrap_continuation: bool,
    semantic: i32,
}

#[repr(C)]
struct RawRenderCellInfo {
    size: usize,
    abi_version: u32,
    x: u16,
    width: u8,
    grapheme_bytes: usize,
    selected: bool,
    has_styling: bool,
    has_hyperlink: bool,
    semantic: i32,
    foreground_has_value: bool,
    foreground: RawColor,
    background_has_value: bool,
    background: RawColor,
    underline_color_has_value: bool,
    underline_color: RawColor,
    bold: bool,
    italic: bool,
    faint: bool,
    blink: bool,
    inverse: bool,
    invisible: bool,
    strikethrough: bool,
    overline: bool,
    underline: i32,
}

#[repr(C)]
struct RawRenderProjectionConfig {
    size: usize,
    abi_version: u32,
    memory_max_bytes: usize,
    max_grapheme_bytes: usize,
}

#[repr(C)]
struct RawRenderProjectionMemoryInfo {
    size: usize,
    abi_version: u32,
    live_bytes: usize,
    peak_bytes: usize,
    limit_bytes: usize,
    allocation_failures: u64,
}

extern "C" {
    fn ouro_terminal_set_selection(
        terminal: *mut c_void,
        start_x: u16,
        start_y: u16,
        end_x: u16,
        end_y: u16,
        rectangle: bool,
    ) -> i32;
    fn ouro_terminal_clear_selection(terminal: *mut c_void) -> i32;
    fn ouro_render_projection_new(
        terminal: *mut c_void,
        config: *const RawRenderProjectionConfig,
        out: *mut *mut c_void,
    ) -> i32;
    fn ouro_render_projection_rebind(projection: *mut c_void, terminal: *mut c_void) -> i32;
    fn ouro_render_projection_memory_info(
        projection: *mut c_void,
        out: *mut RawRenderProjectionMemoryInfo,
    ) -> i32;
    fn ouro_render_projection_free(projection: *mut c_void);
    fn ouro_render_projection_begin(projection: *mut c_void, out: *mut *mut c_void) -> i32;
    fn ouro_render_projection_force_full(projection: *mut c_void) -> i32;
    fn ouro_render_frame_info(frame: *mut c_void, out: *mut RawRenderFrameInfo) -> i32;
    fn ouro_render_frame_next_row(
        frame: *mut c_void,
        out: *mut RawRenderRowInfo,
        has_row: *mut bool,
    ) -> i32;
    fn ouro_render_frame_next_cell(
        frame: *mut c_void,
        grapheme: *mut u8,
        capacity: usize,
        out: *mut RawRenderCellInfo,
        has_cell: *mut bool,
    ) -> i32;
    fn ouro_render_frame_end(frame: *mut c_void, disposition: i32) -> i32;
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Rgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RenderColor {
    Default,
    Palette(u8),
    Rgb(Rgb),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RenderDirty {
    None,
    Partial,
    Full,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CursorStyle {
    Bar,
    Block,
    Underline,
    HollowBlock,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RowSemantic {
    None,
    Prompt,
    PromptContinuation,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CellSemantic {
    Output,
    Input,
    Prompt,
}

pub const MAX_RENDER_GRAPHEME_BYTES: usize = 256;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RenderProjectionConfig {
    pub memory_max_bytes: usize,
    pub max_grapheme_bytes: usize,
}

impl Default for RenderProjectionConfig {
    fn default() -> Self {
        Self {
            memory_max_bytes: 8 * 1024 * 1024,
            max_grapheme_bytes: MAX_RENDER_GRAPHEME_BYTES,
        }
    }
}

impl RenderProjectionConfig {
    fn raw(self) -> RawRenderProjectionConfig {
        RawRenderProjectionConfig {
            size: std::mem::size_of::<RawRenderProjectionConfig>(),
            abi_version: TERMINAL_ENGINE_ABI_VERSION,
            memory_max_bytes: self.memory_max_bytes,
            max_grapheme_bytes: self.max_grapheme_bytes,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RenderProjectionMemoryInfo {
    pub live_bytes: usize,
    pub peak_bytes: usize,
    pub limit_bytes: usize,
    pub allocation_failures: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RenderFrameInfo {
    pub generation: u64,
    pub dirty: RenderDirty,
    pub columns: u16,
    pub rows: u16,
    pub cursor: Option<(u16, u16)>,
    pub cursor_wide_tail: bool,
    pub cursor_visible: bool,
    pub cursor_blinking: bool,
    pub cursor_password_input: bool,
    pub cursor_style: CursorStyle,
    pub background: Rgb,
    pub foreground: Rgb,
    pub cursor_color: Option<Rgb>,
    pub palette: [Rgb; 256],
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RenderRow {
    pub y: u16,
    pub dirty: bool,
    pub selection: Option<(u16, u16)>,
    pub wrap: bool,
    pub wrap_continuation: bool,
    pub semantic: RowSemantic,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RenderCell<'grapheme> {
    pub x: u16,
    pub width: u8,
    pub grapheme: &'grapheme [u8],
    pub selected: bool,
    pub has_styling: bool,
    pub has_hyperlink: bool,
    pub semantic: CellSemantic,
    pub foreground: RenderColor,
    pub background: RenderColor,
    pub underline_color: RenderColor,
    pub bold: bool,
    pub italic: bool,
    pub faint: bool,
    pub blink: bool,
    pub inverse: bool,
    pub invisible: bool,
    pub strikethrough: bool,
    pub overline: bool,
    pub underline: i32,
}

pub struct RenderProjection<'terminal> {
    raw: NonNull<c_void>,
    terminal: &'terminal mut Terminal,
    config: RenderProjectionConfig,
    // The C projection is serialized through this !Sync owner.
    _not_sync: PhantomData<*mut ()>,
}

pub struct RenderFrame<'projection, 'terminal> {
    raw: NonNull<c_void>,
    projection: &'projection mut RenderProjection<'terminal>,
    ended: bool,
}

/// Owns one terminal together with its single persistent render projection.
///
/// This is the app-side counterpart to the borrowing [`RenderProjection`]. It
/// exists so an FFI owner can keep both opaque C handles alive without a
/// self-referential Rust borrow. The C projection owns an independent bounded
/// allocator, so replacing and dropping the old terminal cannot invalidate it.
pub struct OwnedRenderProjection {
    terminal: Terminal,
    projection: NonNull<c_void>,
    frame: Option<NonNull<c_void>>,
    config: RenderProjectionConfig,
    // All mutation is serialized through `&mut self`; the C handles are not
    // exposed and this marker prevents accidental shared cross-thread use.
    _not_sync: PhantomData<*mut ()>,
}

// Terminal is Send and the exact-pin C projection has no thread affinity.
// Every operation requires `&mut self`; PhantomData<*mut ()> keeps it !Sync.
unsafe impl Send for OwnedRenderProjection {}

impl Terminal {
    pub fn render_projection(&mut self) -> Result<RenderProjection<'_>, Error> {
        self.render_projection_with_config(RenderProjectionConfig::default())
    }

    pub fn render_projection_with_config(
        &mut self,
        config: RenderProjectionConfig,
    ) -> Result<RenderProjection<'_>, Error> {
        let raw_config = config.raw();
        let mut raw = std::ptr::null_mut();
        result(unsafe { ouro_render_projection_new(self.raw.as_ptr(), &raw_config, &mut raw) })?;
        Ok(RenderProjection {
            raw: NonNull::new(raw).ok_or(Error::Engine)?,
            terminal: self,
            config,
            _not_sync: PhantomData,
        })
    }

    pub fn set_selection(
        &mut self,
        start: (u16, u16),
        end: (u16, u16),
        rectangle: bool,
    ) -> Result<(), Error> {
        result(unsafe {
            ouro_terminal_set_selection(
                self.raw.as_ptr(),
                start.0,
                start.1,
                end.0,
                end.1,
                rectangle,
            )
        })
    }

    pub fn clear_selection(&mut self) -> Result<(), Error> {
        result(unsafe { ouro_terminal_clear_selection(self.raw.as_ptr()) })
    }

    /// Converts this terminal into an owner with exactly one persistent
    /// render projection. On failure the terminal is returned unchanged so a
    /// caller can preserve its previous visible state or retry deliberately.
    pub fn try_into_owned_render(self) -> Result<OwnedRenderProjection, (Error, Terminal)> {
        self.try_into_owned_render_with_config(RenderProjectionConfig::default())
    }

    pub fn try_into_owned_render_with_config(
        self,
        config: RenderProjectionConfig,
    ) -> Result<OwnedRenderProjection, (Error, Terminal)> {
        let raw_config = config.raw();
        let mut raw = std::ptr::null_mut();
        if let Err(error) =
            result(unsafe { ouro_render_projection_new(self.raw.as_ptr(), &raw_config, &mut raw) })
        {
            return Err((error, self));
        }
        let Some(projection) = NonNull::new(raw) else {
            return Err((Error::Engine, self));
        };
        Ok(OwnedRenderProjection {
            terminal: self,
            projection,
            frame: None,
            config,
            _not_sync: PhantomData,
        })
    }
}

impl OwnedRenderProjection {
    /// Terminal metadata is independent of the retained render-frame cursor.
    /// These read-only snapshots are safe while a CPU frame lease is open and
    /// let embedders observe OSC-only title/PWD changes without dropping them.
    pub fn metadata_epoch(&self) -> Result<u64, Error> {
        self.terminal.metadata_epoch()
    }

    pub fn title(&self) -> Result<Vec<u8>, Error> {
        self.terminal.title()
    }

    pub fn pwd(&self) -> Result<Vec<u8>, Error> {
        self.terminal.pwd()
    }

    pub fn try_terminal(&self) -> Result<&Terminal, Error> {
        if self.frame.is_some() {
            return Err(Error::InvalidArgument);
        }
        Ok(&self.terminal)
    }

    pub fn try_terminal_mut(&mut self) -> Result<&mut Terminal, Error> {
        if self.frame.is_some() {
            return Err(Error::InvalidArgument);
        }
        Ok(&mut self.terminal)
    }

    pub fn feed(&mut self, bytes: &[u8]) -> Result<(), Error> {
        if self.frame.is_some() {
            return Err(Error::InvalidArgument);
        }
        self.terminal.feed(bytes)
    }

    pub fn resize(
        &mut self,
        columns: u16,
        rows: u16,
        cell_width_px: u32,
        cell_height_px: u32,
    ) -> Result<(), Error> {
        if self.frame.is_some() {
            return Err(Error::InvalidArgument);
        }
        self.terminal
            .resize(columns, rows, cell_width_px, cell_height_px)
    }

    /// Begins the sole outstanding frame for this projection.
    pub fn begin_frame(&mut self) -> Result<(), Error> {
        if self.frame.is_some() {
            return Err(Error::InvalidArgument);
        }
        let mut raw = std::ptr::null_mut();
        result(unsafe { ouro_render_projection_begin(self.projection.as_ptr(), &mut raw) })?;
        self.frame = Some(NonNull::new(raw).ok_or(Error::Engine)?);
        Ok(())
    }

    pub fn frame_info(&self) -> Result<RenderFrameInfo, Error> {
        frame_info(self.frame.ok_or(Error::InvalidArgument)?)
    }

    pub fn next_row(&mut self) -> Result<Option<RenderRow>, Error> {
        frame_next_row(self.frame.ok_or(Error::InvalidArgument)?)
    }

    pub fn next_cell_into<'scratch>(
        &mut self,
        scratch: &'scratch mut Vec<u8>,
    ) -> Result<Option<RenderCell<'scratch>>, Error> {
        frame_next_cell_into(
            self.frame.ok_or(Error::InvalidArgument)?,
            scratch,
            self.config.max_grapheme_bytes,
        )
    }

    /// Clears engine dirty state after the complete frame has been merged into
    /// the renderer's lossless full CPU row cache. GPU presentation is later.
    pub fn commit_cpu_cache(&mut self) -> Result<(), Error> {
        let frame = self.frame.take().ok_or(Error::InvalidArgument)?;
        result(unsafe { ouro_render_frame_end(frame.as_ptr(), 0) })
    }

    pub fn drop_uncommitted_frame(&mut self) -> Result<(), Error> {
        let frame = self.frame.take().ok_or(Error::InvalidArgument)?;
        result(unsafe { ouro_render_frame_end(frame.as_ptr(), 1) })
    }

    pub fn force_full(&mut self) -> Result<(), Error> {
        if self.frame.is_some() {
            return Err(Error::InvalidArgument);
        }
        result(unsafe { ouro_render_projection_force_full(self.projection.as_ptr()) })
    }

    pub fn memory_info(&self) -> Result<RenderProjectionMemoryInfo, Error> {
        projection_memory_info(self.projection)
    }

    /// Transactionally rebinds this one projection to `candidate`.
    ///
    /// Success returns the old terminal after the C projection has stopped
    /// borrowing it. Failure returns the untouched candidate and preserves the
    /// current terminal/projection state.
    pub fn replace_terminal(&mut self, candidate: Terminal) -> Result<Terminal, (Error, Terminal)> {
        if self.frame.is_some() {
            return Err((Error::InvalidArgument, candidate));
        }
        if let Err(error) = result(unsafe {
            ouro_render_projection_rebind(self.projection.as_ptr(), candidate.raw.as_ptr())
        }) {
            return Err((error, candidate));
        }
        Ok(std::mem::replace(&mut self.terminal, candidate))
    }
}

impl Drop for OwnedRenderProjection {
    fn drop(&mut self) {
        if let Some(frame) = self.frame.take() {
            let _ = unsafe { ouro_render_frame_end(frame.as_ptr(), 1) };
        }
        // End the C borrow before the automatically owned terminal is dropped.
        unsafe { ouro_render_projection_free(self.projection.as_ptr()) };
    }
}

impl<'terminal> RenderProjection<'terminal> {
    pub fn terminal_mut(&mut self) -> &mut Terminal {
        self.terminal
    }

    pub fn begin<'projection>(
        &'projection mut self,
    ) -> Result<RenderFrame<'projection, 'terminal>, Error> {
        let mut raw = std::ptr::null_mut();
        result(unsafe { ouro_render_projection_begin(self.raw.as_ptr(), &mut raw) })?;
        Ok(RenderFrame {
            raw: NonNull::new(raw).ok_or(Error::Engine)?,
            projection: self,
            ended: false,
        })
    }

    pub fn force_full(&mut self) -> Result<(), Error> {
        result(unsafe { ouro_render_projection_force_full(self.raw.as_ptr()) })
    }

    pub fn memory_info(&self) -> Result<RenderProjectionMemoryInfo, Error> {
        projection_memory_info(self.raw)
    }
}

impl Drop for RenderProjection<'_> {
    fn drop(&mut self) {
        unsafe { ouro_render_projection_free(self.raw.as_ptr()) };
    }
}

fn rgb(raw: RawRgb) -> Rgb {
    Rgb {
        r: raw.r,
        g: raw.g,
        b: raw.b,
    }
}

fn color(raw: RawColor) -> Result<RenderColor, Error> {
    match raw.kind {
        0 => Ok(RenderColor::Default),
        1 => Ok(RenderColor::Palette(raw.palette_index)),
        2 => Ok(RenderColor::Rgb(rgb(raw.rgb))),
        _ => Err(Error::Engine),
    }
}

fn projection_memory_info(
    projection: NonNull<c_void>,
) -> Result<RenderProjectionMemoryInfo, Error> {
    let mut raw = RawRenderProjectionMemoryInfo {
        size: std::mem::size_of::<RawRenderProjectionMemoryInfo>(),
        abi_version: TERMINAL_ENGINE_ABI_VERSION,
        live_bytes: 0,
        peak_bytes: 0,
        limit_bytes: 0,
        allocation_failures: 0,
    };
    result(unsafe { ouro_render_projection_memory_info(projection.as_ptr(), &mut raw) })?;
    Ok(RenderProjectionMemoryInfo {
        live_bytes: raw.live_bytes,
        peak_bytes: raw.peak_bytes,
        limit_bytes: raw.limit_bytes,
        allocation_failures: raw.allocation_failures,
    })
}

fn frame_info(frame: NonNull<c_void>) -> Result<RenderFrameInfo, Error> {
    let mut raw = RawRenderFrameInfo {
        size: std::mem::size_of::<RawRenderFrameInfo>(),
        abi_version: TERMINAL_ENGINE_ABI_VERSION,
        generation: 0,
        dirty: 0,
        columns: 0,
        rows: 0,
        cursor_has_value: false,
        cursor_x: 0,
        cursor_y: 0,
        cursor_wide_tail: false,
        cursor_visible: false,
        cursor_blinking: false,
        cursor_password_input: false,
        cursor_style: 0,
        background: RawRgb::default(),
        foreground: RawRgb::default(),
        cursor_color_has_value: false,
        cursor_color: RawRgb::default(),
        palette: [RawRgb::default(); 256],
    };
    result(unsafe { ouro_render_frame_info(frame.as_ptr(), &mut raw) })?;
    Ok(RenderFrameInfo {
        generation: raw.generation,
        dirty: match raw.dirty {
            0 => RenderDirty::None,
            1 => RenderDirty::Partial,
            2 => RenderDirty::Full,
            _ => return Err(Error::Engine),
        },
        columns: raw.columns,
        rows: raw.rows,
        cursor: raw.cursor_has_value.then_some((raw.cursor_x, raw.cursor_y)),
        cursor_wide_tail: raw.cursor_wide_tail,
        cursor_visible: raw.cursor_visible,
        cursor_blinking: raw.cursor_blinking,
        cursor_password_input: raw.cursor_password_input,
        cursor_style: match raw.cursor_style {
            0 => CursorStyle::Bar,
            1 => CursorStyle::Block,
            2 => CursorStyle::Underline,
            3 => CursorStyle::HollowBlock,
            _ => return Err(Error::Engine),
        },
        background: rgb(raw.background),
        foreground: rgb(raw.foreground),
        cursor_color: raw.cursor_color_has_value.then_some(rgb(raw.cursor_color)),
        palette: raw.palette.map(rgb),
    })
}

fn frame_next_row(frame: NonNull<c_void>) -> Result<Option<RenderRow>, Error> {
    let mut raw = RawRenderRowInfo {
        size: std::mem::size_of::<RawRenderRowInfo>(),
        abi_version: TERMINAL_ENGINE_ABI_VERSION,
        y: 0,
        dirty: false,
        selection_has_value: false,
        selection_start_x: 0,
        selection_end_x: 0,
        wrap: false,
        wrap_continuation: false,
        semantic: 0,
    };
    let mut has_row = false;
    result(unsafe { ouro_render_frame_next_row(frame.as_ptr(), &mut raw, &mut has_row) })?;
    if !has_row {
        return Ok(None);
    }
    Ok(Some(RenderRow {
        y: raw.y,
        dirty: raw.dirty,
        selection: raw
            .selection_has_value
            .then_some((raw.selection_start_x, raw.selection_end_x)),
        wrap: raw.wrap,
        wrap_continuation: raw.wrap_continuation,
        semantic: match raw.semantic {
            0 => RowSemantic::None,
            1 => RowSemantic::Prompt,
            2 => RowSemantic::PromptContinuation,
            _ => return Err(Error::Engine),
        },
    }))
}

fn frame_next_cell_into<'scratch>(
    frame: NonNull<c_void>,
    scratch: &'scratch mut Vec<u8>,
    max_grapheme_bytes: usize,
) -> Result<Option<RenderCell<'scratch>>, Error> {
    if max_grapheme_bytes == 0 || max_grapheme_bytes > MAX_RENDER_GRAPHEME_BYTES {
        return Err(Error::InvalidArgument);
    }
    if scratch.is_empty() {
        let initial = 16.min(max_grapheme_bytes);
        scratch
            .try_reserve_exact(initial)
            .map_err(|_| Error::OutOfMemory)?;
        scratch.resize(initial, 0);
    }
    let mut writable = scratch.len().min(max_grapheme_bytes);
    loop {
        let mut raw = RawRenderCellInfo {
            size: std::mem::size_of::<RawRenderCellInfo>(),
            abi_version: TERMINAL_ENGINE_ABI_VERSION,
            x: 0,
            width: 0,
            grapheme_bytes: 0,
            selected: false,
            has_styling: false,
            has_hyperlink: false,
            semantic: 0,
            foreground_has_value: false,
            foreground: RawColor::default(),
            background_has_value: false,
            background: RawColor::default(),
            underline_color_has_value: false,
            underline_color: RawColor::default(),
            bold: false,
            italic: false,
            faint: false,
            blink: false,
            inverse: false,
            invisible: false,
            strikethrough: false,
            overline: false,
            underline: 0,
        };
        let mut has_cell = false;
        let code = unsafe {
            ouro_render_frame_next_cell(
                frame.as_ptr(),
                scratch.as_mut_ptr(),
                writable,
                &mut raw,
                &mut has_cell,
            )
        };
        if code == 4 {
            if !has_cell {
                return Err(Error::Engine);
            }
            let required = raw.grapheme_bytes;
            if required <= writable {
                return Err(Error::Engine);
            }
            if required > max_grapheme_bytes {
                return Err(Error::BufferTooSmall);
            }
            scratch
                .try_reserve_exact(required.saturating_sub(scratch.len()))
                .map_err(|_| Error::OutOfMemory)?;
            scratch.resize(required, 0);
            writable = required;
            continue;
        }
        result(code)?;
        if !has_cell {
            return Ok(None);
        }
        if raw.grapheme_bytes > writable {
            return Err(Error::Engine);
        }
        return Ok(Some(RenderCell {
            x: raw.x,
            width: raw.width,
            grapheme: &scratch[..raw.grapheme_bytes],
            selected: raw.selected,
            has_styling: raw.has_styling,
            has_hyperlink: raw.has_hyperlink,
            semantic: match raw.semantic {
                0 => CellSemantic::Output,
                1 => CellSemantic::Input,
                2 => CellSemantic::Prompt,
                _ => return Err(Error::Engine),
            },
            foreground: color(raw.foreground)?,
            background: color(raw.background)?,
            underline_color: color(raw.underline_color)?,
            bold: raw.bold,
            italic: raw.italic,
            faint: raw.faint,
            blink: raw.blink,
            inverse: raw.inverse,
            invisible: raw.invisible,
            strikethrough: raw.strikethrough,
            overline: raw.overline,
            underline: raw.underline,
        }));
    }
}

impl RenderFrame<'_, '_> {
    pub fn info(&self) -> Result<RenderFrameInfo, Error> {
        frame_info(self.raw)
    }

    pub fn next_row(&mut self) -> Result<Option<RenderRow>, Error> {
        frame_next_row(self.raw)
    }

    pub fn next_cell_into<'scratch>(
        &mut self,
        scratch: &'scratch mut Vec<u8>,
    ) -> Result<Option<RenderCell<'scratch>>, Error> {
        frame_next_cell_into(self.raw, scratch, self.projection.config.max_grapheme_bytes)
    }

    /// Acknowledges that every row/cell was merged into a lossless full CPU
    /// row cache. A later GPU submission failure is retried from that cache.
    pub fn commit_cpu_cache(mut self) -> Result<(), Error> {
        let code = unsafe { ouro_render_frame_end(self.raw.as_ptr(), 0) };
        self.ended = true;
        result(code)
    }

    pub fn drop_uncommitted(mut self) -> Result<(), Error> {
        let code = unsafe { ouro_render_frame_end(self.raw.as_ptr(), 1) };
        self.ended = true;
        result(code)
    }
}

impl Drop for RenderFrame<'_, '_> {
    fn drop(&mut self) {
        if !self.ended {
            let _ = unsafe { ouro_render_frame_end(self.raw.as_ptr(), 1) };
            self.ended = true;
        }
        let _ = &self.projection;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Config;

    #[derive(Default)]
    struct Evidence {
        cjk: bool,
        wide_tail: bool,
        combining_grapheme: bool,
        styled: bool,
        selected: bool,
        hyperlink: bool,
        semantic_prompt: bool,
        long_grapheme: bool,
    }

    fn drain(frame: &mut RenderFrame<'_, '_>) -> Evidence {
        let mut evidence = Evidence::default();
        let mut scratch = Vec::new();
        while let Some(row) = frame.next_row().unwrap() {
            evidence.selected |= row.selection.is_some();
            while let Some(cell) = frame.next_cell_into(&mut scratch).unwrap() {
                evidence.cjk |= cell.grapheme == "界".as_bytes() && cell.width == 2;
                evidence.wide_tail |= cell.grapheme.is_empty() && cell.width == 0;
                evidence.combining_grapheme |= cell.grapheme == "e\u{301}".as_bytes();
                evidence.long_grapheme |= cell.grapheme
                    == "q\u{301}\u{302}\u{303}\u{304}\u{305}\u{306}\u{307}\u{308}\u{309}"
                        .as_bytes();
                evidence.selected |= cell.selected;
                evidence.hyperlink |= cell.has_hyperlink;
                evidence.semantic_prompt |= cell.semantic == CellSemantic::Prompt;
                evidence.styled |= cell.bold
                    && cell.italic
                    && cell.underline != 0
                    && cell.foreground == RenderColor::Palette(42)
                    && cell.background == RenderColor::Rgb(Rgb { r: 1, g: 2, b: 3 })
                    && cell.underline_color == RenderColor::Rgb(Rgb { r: 4, g: 5, b: 6 });
            }
        }
        evidence
    }

    #[test]
    fn detached_projection_preserves_render_identity_and_invalidation() {
        let config = Config {
            columns: 16,
            rows: 4,
            ..Config::default()
        };
        let mut terminal = Terminal::new(config).unwrap();
        terminal
            .feed(
                b"\x1b[1;3;4;38;5;42;48;2;1;2;3;58;2;4;5;6m\
                  \xe7\x95\x8ce\xcc\x81q\xcc\x81\xcc\x82\xcc\x83\xcc\x84\xcc\x85\xcc\x86\xcc\x87\xcc\x88\xcc\x89\x1b[0m \
                  \x1b]8;;https://example.com/render\x1b\\link\x1b]8;;\x1b\\\
                  \r\n\x1b]133;A\x07PROMPT",
            )
            .unwrap();
        terminal.set_selection((0, 0), (2, 0), false).unwrap();
        let headless_live_bytes = terminal.memory_info().unwrap().live_bytes;

        {
            let mut projection = terminal.render_projection().unwrap();
            assert_eq!(
                projection.terminal_mut().memory_info().unwrap().live_bytes,
                headless_live_bytes
            );
            assert!(projection.memory_info().unwrap().live_bytes > 0);

            let mut first = projection.begin().unwrap();
            let first_info = first.info().unwrap();
            assert_eq!(first_info.generation, 1);
            assert_eq!(first_info.dirty, RenderDirty::Full);
            assert_eq!((first_info.columns, first_info.rows), (16, 4));
            assert!(first_info.cursor.is_some() && first_info.cursor_visible);
            let evidence = drain(&mut first);
            assert!(evidence.cjk && evidence.wide_tail && evidence.combining_grapheme);
            assert!(evidence.long_grapheme);
            assert!(evidence.styled && evidence.selected && evidence.hyperlink);
            assert!(evidence.semantic_prompt);
            first.commit_cpu_cache().unwrap();

            let mut clean = projection.begin().unwrap();
            let clean_info = clean.info().unwrap();
            assert_eq!(clean_info.generation, 2);
            assert_eq!(clean_info.dirty, RenderDirty::None);
            let _ = drain(&mut clean);
            clean.commit_cpu_cache().unwrap();

            projection.terminal_mut().feed(b"X").unwrap();
            let partial = projection.begin().unwrap();
            assert_eq!(partial.info().unwrap().dirty, RenderDirty::Partial);
            drop(partial);

            let mut retained = projection.begin().unwrap();
            assert_eq!(retained.info().unwrap().dirty, RenderDirty::Full);
            let _ = drain(&mut retained);
            retained.commit_cpu_cache().unwrap();

            projection.force_full().unwrap();
            let mut incomplete = projection.begin().unwrap();
            assert_eq!(incomplete.info().unwrap().dirty, RenderDirty::Full);
            assert!(incomplete.next_row().unwrap().is_some());
            assert_eq!(incomplete.commit_cpu_cache(), Err(Error::InvalidArgument));

            let mut final_frame = projection.begin().unwrap();
            assert_eq!(final_frame.info().unwrap().dirty, RenderDirty::Full);
            let _ = drain(&mut final_frame);
            final_frame.commit_cpu_cache().unwrap();
        }

        assert_eq!(
            terminal.memory_info().unwrap().live_bytes,
            headless_live_bytes
        );
    }

    #[test]
    fn projection_preserves_osc_defaults_cursor_and_sgr58() {
        let mut terminal = Terminal::new(Config {
            columns: 8,
            rows: 2,
            ..Config::default()
        })
        .unwrap();
        terminal
            .feed(
                b"\x1b]10;#123456\x1b\\\x1b]11;#234567\x1b\\\
                  \x1b]12;#345678\x1b\\\x1b[4;58;2;4;5;6mU\x1b[0m",
            )
            .unwrap();

        let mut projection = terminal.render_projection().unwrap();
        let mut frame = projection.begin().unwrap();
        let info = frame.info().unwrap();
        assert_eq!(
            info.foreground,
            Rgb {
                r: 0x12,
                g: 0x34,
                b: 0x56
            }
        );
        assert_eq!(
            info.background,
            Rgb {
                r: 0x23,
                g: 0x45,
                b: 0x67
            }
        );
        assert_eq!(
            info.cursor_color,
            Some(Rgb {
                r: 0x34,
                g: 0x56,
                b: 0x78
            })
        );

        let mut scratch = Vec::new();
        let mut underline = None;
        while frame.next_row().unwrap().is_some() {
            while let Some(cell) = frame.next_cell_into(&mut scratch).unwrap() {
                if cell.grapheme == b"U" {
                    underline = Some((cell.underline, cell.underline_color));
                }
            }
        }
        assert_eq!(
            underline,
            Some((1, RenderColor::Rgb(Rgb { r: 4, g: 5, b: 6 })))
        );
        frame.commit_cpu_cache().unwrap();
    }

    fn drain_owned(projection: &mut OwnedRenderProjection) -> Vec<u8> {
        let mut text = Vec::new();
        let mut scratch = Vec::new();
        while projection.next_row().unwrap().is_some() {
            while let Some(cell) = projection.next_cell_into(&mut scratch).unwrap() {
                text.extend_from_slice(cell.grapheme);
            }
        }
        text
    }

    #[test]
    fn owned_projection_rebinds_without_allocator_or_terminal_lifetime_aliasing() {
        fn assert_send<T: Send>() {}
        assert_send::<OwnedRenderProjection>();

        let config = Config {
            columns: 24,
            rows: 4,
            ..Config::default()
        };
        let mut old = Terminal::new(config).unwrap();
        old.feed(b"OLD").unwrap();
        let mut projection = match old.try_into_owned_render() {
            Ok(projection) => projection,
            Err((error, _)) => panic!("owned projection creation failed: {error:?}"),
        };
        projection.begin_frame().unwrap();
        assert!(drain_owned(&mut projection).windows(3).any(|w| w == b"OLD"));
        projection.commit_cpu_cache().unwrap();

        let mut candidate = Terminal::new(config).unwrap();
        candidate.feed(b"CANDIDATE").unwrap();
        let old = match projection.replace_terminal(candidate) {
            Ok(old) => old,
            Err((error, _)) => panic!("projection rebind failed: {error:?}"),
        };
        drop(old);
        projection.feed(b"-AFTER-OLD-DROP").unwrap();
        projection.begin_frame().unwrap();
        let rebound_info = projection.frame_info().unwrap();
        assert_eq!(rebound_info.generation, 2);
        assert_eq!(rebound_info.dirty, RenderDirty::Full);
        let text = drain_owned(&mut projection);
        assert!(text.windows(9).any(|w| w == b"CANDIDATE"));
        projection.commit_cpu_cache().unwrap();

        // A GPU submission failure after this point is retried from the CPU
        // cache. It must not turn back into an engine DROPPED disposition.
        projection.begin_frame().unwrap();
        assert_eq!(projection.frame_info().unwrap().dirty, RenderDirty::None);
        let _ = drain_owned(&mut projection);
        projection.commit_cpu_cache().unwrap();
    }

    #[test]
    fn projection_budget_and_grapheme_bound_fail_closed() {
        let terminal = Terminal::new(Config::default()).unwrap();
        let tiny = RenderProjectionConfig {
            memory_max_bytes: 1,
            ..RenderProjectionConfig::default()
        };
        let (error, _terminal) = match terminal.try_into_owned_render_with_config(tiny) {
            Ok(_) => panic!("tiny render budget unexpectedly succeeded"),
            Err(failure) => failure,
        };
        assert_eq!(error, Error::OutOfMemory);

        let terminal_config = Config {
            columns: 24,
            rows: 4,
            ..Config::default()
        };
        let mut probe_terminal = Terminal::new(terminal_config).unwrap();
        probe_terminal.feed(b"PRESERVED-OLD").unwrap();
        let mut probe = match probe_terminal.try_into_owned_render() {
            Ok(projection) => projection,
            Err((error, _)) => panic!("probe projection failed: {error:?}"),
        };
        let resource_floor = probe.memory_info().unwrap().live_bytes;
        probe.begin_frame().unwrap();
        let _ = drain_owned(&mut probe);
        probe.commit_cpu_cache().unwrap();
        let rendered_live = probe.memory_info().unwrap().live_bytes;
        drop(probe);

        let constrained = RenderProjectionConfig {
            memory_max_bytes: rendered_live + resource_floor - 1,
            ..RenderProjectionConfig::default()
        };
        let mut old_terminal = Terminal::new(terminal_config).unwrap();
        old_terminal.feed(b"PRESERVED-OLD").unwrap();
        let mut old_projection = match old_terminal.try_into_owned_render_with_config(constrained) {
            Ok(projection) => projection,
            Err((error, _)) => panic!("constrained projection failed: {error:?}"),
        };
        old_projection.begin_frame().unwrap();
        let _ = drain_owned(&mut old_projection);
        old_projection.commit_cpu_cache().unwrap();
        let mut candidate = Terminal::new(terminal_config).unwrap();
        candidate.feed(b"REJECTED-CANDIDATE").unwrap();
        let (error, mut candidate) = match old_projection.replace_terminal(candidate) {
            Ok(_) => panic!("constrained rebind unexpectedly succeeded"),
            Err(failure) => failure,
        };
        assert_eq!(error, Error::OutOfMemory);
        assert!(candidate
            .plain_text()
            .unwrap()
            .windows(18)
            .any(|window| window == b"REJECTED-CANDIDATE"));
        old_projection.force_full().unwrap();
        old_projection.begin_frame().unwrap();
        assert!(drain_owned(&mut old_projection)
            .windows(13)
            .any(|window| window == b"PRESERVED-OLD"));
        old_projection.commit_cpu_cache().unwrap();

        let mut terminal = Terminal::new(Config {
            columns: 24,
            rows: 4,
            ..Config::default()
        })
        .unwrap();
        let mut long = vec![b'q'];
        for combining in 0x0301..=0x0309 {
            let mut encoded = [0; 4];
            long.extend_from_slice(
                char::from_u32(combining)
                    .unwrap()
                    .encode_utf8(&mut encoded)
                    .as_bytes(),
            );
        }
        assert!(long.len() > 16);
        terminal.feed(&long).unwrap();
        let mut projection = terminal
            .render_projection_with_config(RenderProjectionConfig {
                max_grapheme_bytes: 16,
                ..RenderProjectionConfig::default()
            })
            .unwrap();
        let mut frame = projection.begin().unwrap();
        assert!(frame.next_row().unwrap().is_some());
        let mut scratch = Vec::new();
        assert_eq!(
            frame.next_cell_into(&mut scratch),
            Err(Error::BufferTooSmall)
        );
        drop(frame);
    }
}
