#![allow(clippy::missing_safety_doc)]

mod split_layout_ffi;
pub use split_layout_ffi::*;

use ouro_terminal_ghostty::{
    CellSemantic, Config, CursorStyle, Error as EngineError, MemoryInfo, OwnedRenderProjection,
    PageBudget, RenderColor, RenderDirty, RenderFrameInfo, RenderProjectionConfig, RenderRow, Rgb,
    RowSemantic, SelectionAutoscroll as EngineSelectionAutoscroll, SelectionConfig,
    SelectionCopyOutcome, SelectionGeometry, SelectionOutcome as EngineSelectionOutcome,
    SelectionPoint, Terminal, ViewportScroll, GHOSTTY_GRAPHICS_POLICY,
    GHOSTTY_SNAPSHOT_FORMAT_VERSION, GHOSTTY_SNAPSHOT_MAGIC, GHOSTTY_SOURCE_COMMIT,
    GHOSTTY_UNICODE_WIDTH_POLICY, MAX_RENDER_GRAPHEME_BYTES, MAX_TERMINAL_METADATA_BYTES,
    TERMINAL_ENGINE_ABI_VERSION,
};
use std::mem::size_of;
use std::ptr;
use std::slice;
use std::sync::Mutex;

pub const RENDER_CLIENT_ABI_VERSION: u32 = 1;
const TERMINAL_ID_MAX: usize = 128;
const MAX_FEED_BYTES: usize = 1024 * 1024;
const MAX_SNAPSHOT_BYTES: usize = 64 * 1024 * 1024;
const MAX_CACHE_BYTES: usize = 64 * 1024 * 1024;
const MAX_ALLOCATOR_BYTES: usize = 256 * 1024 * 1024;
const MAX_PAGE_BUDGET_BYTES: usize = 1024 * 1024 * 1024;
const MAX_SELECTION_COPY_BYTES: usize = 1024 * 1024;
const MAX_HYPERLINK_URI_BYTES: usize = 4096;
const MAX_FIND_TEXT_BYTES: usize = 8 * 1024 * 1024;

#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ResultCode {
    Ok = 0,
    InvalidArgument = 1,
    OutOfMemory = 2,
    Engine = 3,
    BufferTooSmall = 4,
    StateSeqGap = 5,
    Busy = 6,
    LimitExceeded = 7,
    NoCandidate = 8,
    StaleFrame = 9,
    StaleCandidate = 10,
    StaleStream = 11,
    ManifestMismatch = 12,
    ResyncRequired = 13,
    NoValue = 14,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct StreamIdentity {
    pub size: usize,
    pub abi_version: u32,
    pub broker_generation: u64,
    pub terminal_id_length: usize,
    pub terminal_id: [u8; TERMINAL_ID_MAX],
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Identity {
    broker_generation: u64,
    terminal_id_length: usize,
    terminal_id: [u8; TERMINAL_ID_MAX],
}

impl Identity {
    fn parse(raw: &StreamIdentity) -> Result<Self, ResultCode> {
        if raw.size < size_of::<StreamIdentity>()
            || raw.abi_version != RENDER_CLIENT_ABI_VERSION
            || raw.broker_generation == 0
            || raw.terminal_id_length == 0
            || raw.terminal_id_length > TERMINAL_ID_MAX
        {
            return Err(ResultCode::InvalidArgument);
        }
        let id = &raw.terminal_id[..raw.terminal_id_length];
        if id.contains(&0) || std::str::from_utf8(id).is_err() {
            return Err(ResultCode::InvalidArgument);
        }
        let mut terminal_id = [0; TERMINAL_ID_MAX];
        terminal_id[..id.len()].copy_from_slice(id);
        Ok(Self {
            broker_generation: raw.broker_generation,
            terminal_id_length: id.len(),
            terminal_id,
        })
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ClientManifest {
    pub size: usize,
    pub abi_version: u32,
    pub terminal_engine_abi_version: u32,
    pub snapshot_format_version: u32,
    pub ghostty_source_commit: [u8; 41],
    pub snapshot_magic: [u8; 9],
    pub unicode_width_policy: [u8; 32],
    pub graphics_policy: [u8; 48],
}

fn manifest_value() -> ClientManifest {
    let mut value = ClientManifest {
        size: size_of::<ClientManifest>(),
        abi_version: RENDER_CLIENT_ABI_VERSION,
        terminal_engine_abi_version: TERMINAL_ENGINE_ABI_VERSION,
        snapshot_format_version: GHOSTTY_SNAPSHOT_FORMAT_VERSION,
        ghostty_source_commit: [0; 41],
        snapshot_magic: [0; 9],
        unicode_width_policy: [0; 32],
        graphics_policy: [0; 48],
    };
    value.ghostty_source_commit[..GHOSTTY_SOURCE_COMMIT.len()]
        .copy_from_slice(GHOSTTY_SOURCE_COMMIT.as_bytes());
    value.snapshot_magic[..GHOSTTY_SNAPSHOT_MAGIC.len()]
        .copy_from_slice(GHOSTTY_SNAPSHOT_MAGIC.as_bytes());
    value.unicode_width_policy[..GHOSTTY_UNICODE_WIDTH_POLICY.len()]
        .copy_from_slice(GHOSTTY_UNICODE_WIDTH_POLICY.as_bytes());
    value.graphics_policy[..GHOSTTY_GRAPHICS_POLICY.len()]
        .copy_from_slice(GHOSTTY_GRAPHICS_POLICY.as_bytes());
    value
}

fn manifest_equal(value: &ClientManifest) -> bool {
    value.size >= size_of::<ClientManifest>()
        && value.abi_version == RENDER_CLIENT_ABI_VERSION
        && value.terminal_engine_abi_version == TERMINAL_ENGINE_ABI_VERSION
        && value.snapshot_format_version == GHOSTTY_SNAPSHOT_FORMAT_VERSION
        && value.ghostty_source_commit == manifest_value().ghostty_source_commit
        && value.snapshot_magic == manifest_value().snapshot_magic
        && value.unicode_width_policy == manifest_value().unicode_width_policy
        && value.graphics_policy == manifest_value().graphics_policy
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ClientConfig {
    pub size: usize,
    pub abi_version: u32,
    pub initial_stream: StreamIdentity,
    pub columns: u16,
    pub rows: u16,
    pub cell_width_px: u32,
    pub cell_height_px: u32,
    pub scrollback_max_bytes: usize,
    pub scrollback_max_lines: usize,
    pub snapshot_max_bytes: usize,
    pub engine_memory_max_bytes: usize,
    pub projection_memory_max_bytes: usize,
    pub shared_page_budget_max_bytes: usize,
    pub max_grapheme_bytes: usize,
    pub max_feed_bytes: usize,
    pub cpu_cache_max_bytes: usize,
    pub initial_state_seq: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct ClientRgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct ClientColor {
    pub kind: u32,
    pub palette_index: u8,
    pub rgb: ClientRgb,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct ClientRow {
    pub y: u16,
    pub first_cell_index: usize,
    pub cell_count: usize,
    pub dirty: u8,
    pub selection_has_value: u8,
    pub selection_start_x: u16,
    pub selection_end_x: u16,
    pub wrap: u8,
    pub wrap_continuation: u8,
    pub semantic: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct ClientCell {
    pub x: u16,
    pub width: u8,
    pub grapheme_offset: usize,
    pub grapheme_bytes: usize,
    pub flags: u32,
    pub semantic: u32,
    pub foreground: ClientColor,
    pub background: ClientColor,
    pub underline_color: ClientColor,
    pub underline: ClientUnderline,
}

#[repr(i32)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum ClientUnderline {
    #[default]
    None = 0,
    Single = 1,
    Double = 2,
    Curly = 3,
    Dotted = 4,
    Dashed = 5,
}

impl ClientUnderline {
    fn parse(value: i32) -> Result<Self, ResultCode> {
        match value {
            0 => Ok(Self::None),
            1 => Ok(Self::Single),
            2 => Ok(Self::Double),
            3 => Ok(Self::Curly),
            4 => Ok(Self::Dotted),
            5 => Ok(Self::Dashed),
            _ => Err(ResultCode::Engine),
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct BulkFrame {
    pub size: usize,
    pub abi_version: u32,
    pub state_seq: u64,
    pub generation: u64,
    pub dirty: u32,
    pub columns: u16,
    pub rows: u16,
    pub row_count: usize,
    pub cell_count: usize,
    pub grapheme_bytes: usize,
    pub cursor_has_value: u8,
    pub cursor_x: u16,
    pub cursor_y: u16,
    pub cursor_wide_tail: u8,
    pub cursor_visible: u8,
    pub cursor_blinking: u8,
    pub cursor_password_input: u8,
    pub cursor_style: u32,
    pub background: ClientRgb,
    pub foreground: ClientRgb,
    pub cursor_color_has_value: u8,
    pub cursor_color: ClientRgb,
    pub palette: [ClientRgb; 256],
}

#[repr(C)]
pub struct ClientMemoryInfo {
    pub size: usize,
    pub abi_version: u32,
    pub cpu_cache_live_bytes: usize,
    pub cpu_cache_peak_bytes: usize,
    pub cpu_cache_limit_bytes: usize,
    pub projection_live_bytes: usize,
    pub projection_peak_bytes: usize,
    pub projection_limit_bytes: usize,
    pub projection_allocation_failures: u64,
    pub active_engine_live_bytes: usize,
    pub active_engine_peak_bytes: usize,
    pub active_engine_limit_bytes: usize,
    pub active_engine_allocation_failures: u64,
    pub candidate_present: u8,
    pub candidate_engine_live_bytes: usize,
    pub candidate_engine_peak_bytes: usize,
    pub candidate_engine_limit_bytes: usize,
    pub candidate_engine_allocation_failures: u64,
    pub page_reserved_bytes: usize,
    pub page_peak_reserved_bytes: usize,
    pub page_limit_bytes: usize,
    pub page_denial_count: usize,
    pub page_child_failure_count: usize,
    pub active_terminal_count: u8,
    pub candidate_terminal_count: u8,
    pub projection_count: u8,
}

/// Identifies the visible projection and the minimum canonical terminal state
/// against which a local projection mutation may be applied. The identity is
/// exact; `minimum_state_seq` is a lower bound so delayed local effects cannot
/// run against a projection that has not observed their broker receipt yet.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct ProjectionContext {
    pub size: usize,
    pub abi_version: u32,
    pub stream: StreamIdentity,
    pub minimum_state_seq: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ClientSelectionPoint {
    pub size: usize,
    pub abi_version: u32,
    pub column: u16,
    pub row: u32,
    pub surface_x: f64,
    pub surface_y: f64,
    pub has_time: u8,
    pub time_ns: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ClientSelectionGeometry {
    pub size: usize,
    pub abi_version: u32,
    pub columns: u32,
    pub cell_width: f64,
    pub padding_left: f64,
    pub screen_height: f64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ClientSelectionOutcome {
    pub size: usize,
    pub abi_version: u32,
    pub observed_state_seq: u64,
    pub selection_has_value: u8,
    pub autoscroll_direction: i32,
}

#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ClientViewportScrollKind {
    Top = 0,
    Bottom = 1,
    Delta = 2,
    Row = 3,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ClientViewportScroll {
    pub size: usize,
    pub abi_version: u32,
    pub kind: i32,
    pub delta: i64,
    pub row: u64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ClientScrollbar {
    pub size: usize,
    pub abi_version: u32,
    pub observed_state_seq: u64,
    pub total: u64,
    pub offset: u64,
    pub length: u64,
}

#[derive(Clone)]
struct CachedRow {
    row: RenderRow,
    first_cell: usize,
    cell_count: usize,
}

#[derive(Clone)]
struct CachedCell {
    x: u16,
    width: u8,
    grapheme_offset: usize,
    grapheme_len: usize,
    selected: bool,
    has_styling: bool,
    has_hyperlink: bool,
    semantic: CellSemantic,
    foreground: RenderColor,
    background: RenderColor,
    underline_color: RenderColor,
    bold: bool,
    italic: bool,
    faint: bool,
    blink: bool,
    inverse: bool,
    invisible: bool,
    strikethrough: bool,
    overline: bool,
    underline: ClientUnderline,
}

#[derive(Clone)]
struct CpuCache {
    info: RenderFrameInfo,
    state_seq: u64,
    rows: Vec<CachedRow>,
    cells: Vec<CachedCell>,
    graphemes: Vec<u8>,
}

impl CpuCache {
    fn retained_bytes(&self) -> Option<usize> {
        cache_allocation_bytes(
            self.rows.capacity(),
            self.cells.capacity(),
            self.graphemes.capacity(),
        )
    }
    fn complete(&self) -> bool {
        self.rows.len() == usize::from(self.info.rows)
            && self
                .rows
                .iter()
                .enumerate()
                .all(|(y, row)| usize::from(row.row.y) == y)
    }
}

struct Candidate {
    token: u64,
    stream: Identity,
    phase: CandidatePhase,
}

enum CandidatePhase {
    AwaitingCheckpoint { base_seq: u64 },
    Ready { terminal: Terminal, state_seq: u64 },
    Poisoned,
}

#[derive(Clone, Copy)]
struct Limits {
    terminal: Config,
    max_feed_bytes: usize,
    max_grapheme_bytes: usize,
    cpu_cache_max_bytes: usize,
}

struct State {
    active: OwnedRenderProjection,
    active_stream: Identity,
    active_state_seq: u64,
    active_poisoned: bool,
    candidate: Option<Candidate>,
    next_candidate_token: u64,
    cache: Option<CpuCache>,
    cpu_cache_peak_bytes: usize,
    leased_generation: Option<u64>,
    retry_cache: bool,
    limits: Limits,
    page_budget: PageBudget,
}

#[repr(C)]
pub struct OuroRenderClient {
    state: Mutex<State>,
}

fn map_engine(error: EngineError) -> ResultCode {
    match error {
        EngineError::InvalidArgument => ResultCode::InvalidArgument,
        EngineError::OutOfMemory => ResultCode::OutOfMemory,
        EngineError::BufferTooSmall => ResultCode::BufferTooSmall,
        EngineError::Engine | EngineError::Unknown(_) => ResultCode::Engine,
    }
}

fn copy_metadata(
    projection: &OwnedRenderProjection,
    kind: u8,
    buffer: *mut u8,
    capacity: usize,
    out_length: *mut usize,
) -> ResultCode {
    let value = match kind {
        1 => projection.title(),
        2 => projection.pwd(),
        _ => return ResultCode::InvalidArgument,
    };
    let value = match value {
        Ok(value) => value,
        Err(error) => return map_engine(error),
    };
    if value.len() > MAX_TERMINAL_METADATA_BYTES {
        return ResultCode::LimitExceeded;
    }
    unsafe {
        *out_length = value.len();
    }
    if capacity < value.len() {
        return ResultCode::BufferTooSmall;
    }
    if !value.is_empty() {
        unsafe {
            ptr::copy_nonoverlapping(value.as_ptr(), buffer, value.len());
        }
    }
    ResultCode::Ok
}

fn cache_bytes(rows: usize, cells: usize, graphemes: usize) -> Option<usize> {
    rows.checked_mul(size_of::<CachedRow>())?
        .checked_add(cells.checked_mul(size_of::<CachedCell>())?)?
        .checked_add(graphemes)
}

fn cache_allocation_bytes(
    row_capacity: usize,
    cell_capacity: usize,
    grapheme_capacity: usize,
) -> Option<usize> {
    cache_bytes(row_capacity, cell_capacity, grapheme_capacity)
}

fn vec_allocation_bytes<T>(capacity: usize) -> Option<usize> {
    capacity.checked_mul(size_of::<T>())
}

fn valid_config(config: &ClientConfig) -> bool {
    config.size >= size_of::<ClientConfig>()
        && config.abi_version == RENDER_CLIENT_ABI_VERSION
        && Identity::parse(&config.initial_stream).is_ok()
        && config.columns > 0
        && config.rows > 0
        && config.cell_width_px > 0
        && config.cell_height_px > 0
        && (1..=MAX_SNAPSHOT_BYTES).contains(&config.snapshot_max_bytes)
        && (1..=MAX_ALLOCATOR_BYTES).contains(&config.engine_memory_max_bytes)
        && (1..=MAX_ALLOCATOR_BYTES).contains(&config.projection_memory_max_bytes)
        && (1..=MAX_PAGE_BUDGET_BYTES).contains(&config.shared_page_budget_max_bytes)
        && (1..=MAX_RENDER_GRAPHEME_BYTES).contains(&config.max_grapheme_bytes)
        && (1..=MAX_FEED_BYTES).contains(&config.max_feed_bytes)
        && (1..=MAX_CACHE_BYTES).contains(&config.cpu_cache_max_bytes)
}

fn next_seq(current: u64, incoming: u64) -> bool {
    current.checked_add(1) == Some(incoming)
}

impl ProjectionContext {
    fn parse(&self) -> Result<(Identity, u64), ResultCode> {
        if self.size < size_of::<Self>() || self.abi_version != RENDER_CLIENT_ABI_VERSION {
            return Err(ResultCode::InvalidArgument);
        }
        Ok((Identity::parse(&self.stream)?, self.minimum_state_seq))
    }
}

impl ClientSelectionPoint {
    fn parse(&self) -> Result<SelectionPoint, ResultCode> {
        if self.size < size_of::<Self>()
            || self.abi_version != RENDER_CLIENT_ABI_VERSION
            || self.has_time > 1
            || !self.surface_x.is_finite()
            || !self.surface_y.is_finite()
        {
            return Err(ResultCode::InvalidArgument);
        }
        Ok(SelectionPoint {
            column: self.column,
            row: self.row,
            surface_x: self.surface_x,
            surface_y: self.surface_y,
            time_ns: (self.has_time == 1).then_some(self.time_ns),
        })
    }
}

impl ClientSelectionGeometry {
    fn parse(&self) -> Result<SelectionGeometry, ResultCode> {
        let within_u32 = |value: f64, allow_zero: bool| {
            value.is_finite()
                && if allow_zero {
                    value >= 0.0
                } else {
                    value > 0.0
                }
                && value <= f64::from(u32::MAX)
        };
        if self.size < size_of::<Self>()
            || self.abi_version != RENDER_CLIENT_ABI_VERSION
            || self.columns == 0
            || !within_u32(self.cell_width, false)
            || !within_u32(self.padding_left, true)
            || !within_u32(self.screen_height, false)
        {
            return Err(ResultCode::InvalidArgument);
        }
        Ok(SelectionGeometry {
            columns: self.columns,
            cell_width: self.cell_width,
            padding_left: self.padding_left,
            screen_height: self.screen_height,
        })
    }
}

impl ClientViewportScroll {
    fn parse(&self) -> Result<ViewportScroll, ResultCode> {
        if self.size < size_of::<Self>() || self.abi_version != RENDER_CLIENT_ABI_VERSION {
            return Err(ResultCode::InvalidArgument);
        }
        match self.kind {
            value
                if value == ClientViewportScrollKind::Top as i32
                    && self.delta == 0
                    && self.row == 0 =>
            {
                Ok(ViewportScroll::Top)
            }
            value
                if value == ClientViewportScrollKind::Bottom as i32
                    && self.delta == 0
                    && self.row == 0 =>
            {
                Ok(ViewportScroll::Bottom)
            }
            value if value == ClientViewportScrollKind::Delta as i32 && self.row == 0 => {
                Ok(ViewportScroll::Delta(self.delta))
            }
            value if value == ClientViewportScrollKind::Row as i32 && self.delta == 0 => {
                Ok(ViewportScroll::Row(self.row))
            }
            _ => Err(ResultCode::InvalidArgument),
        }
    }
}

fn selection_config() -> SelectionConfig {
    SelectionConfig {
        copy_max_bytes: MAX_SELECTION_COPY_BYTES,
        ..SelectionConfig::default()
    }
}

fn validate_active_projection(
    state: &State,
    identity: &Identity,
    minimum_state_seq: u64,
) -> Result<(), ResultCode> {
    if identity != &state.active_stream {
        return Err(ResultCode::StaleStream);
    }
    if state.active_poisoned {
        return Err(ResultCode::ResyncRequired);
    }
    if state.active_state_seq < minimum_state_seq {
        return Err(ResultCode::StateSeqGap);
    }
    Ok(())
}

fn validate_mutation_outcome(outcome: &ClientSelectionOutcome) -> Result<(), ResultCode> {
    if outcome.size < size_of::<ClientSelectionOutcome>()
        || outcome.abi_version != RENDER_CLIENT_ABI_VERSION
    {
        return Err(ResultCode::InvalidArgument);
    }
    Ok(())
}

fn validate_scrollbar(scrollbar: &ClientScrollbar) -> Result<(), ResultCode> {
    if scrollbar.size < size_of::<ClientScrollbar>()
        || scrollbar.abi_version != RENDER_CLIENT_ABI_VERSION
    {
        return Err(ResultCode::InvalidArgument);
    }
    Ok(())
}

fn write_selection_outcome(
    outcome: &mut ClientSelectionOutcome,
    observed_state_seq: u64,
    selection: EngineSelectionOutcome,
    autoscroll: EngineSelectionAutoscroll,
) {
    outcome.observed_state_seq = observed_state_seq;
    outcome.selection_has_value = (selection == EngineSelectionOutcome::Selection) as u8;
    outcome.autoscroll_direction = autoscroll as i32;
}

fn finish_selection_mutation(
    state: &mut State,
    outcome: &mut ClientSelectionOutcome,
    selection: EngineSelectionOutcome,
    autoscroll: EngineSelectionAutoscroll,
) -> ResultCode {
    // A NoValue engine outcome can still advance/reset gesture state. Always
    // invalidate the full active projection after every successful mutation.
    if let Err(error) = state.active.force_full() {
        return map_engine(error);
    }
    write_selection_outcome(outcome, state.active_state_seq, selection, autoscroll);
    ResultCode::Ok
}

fn bytes<'a>(pointer: *const u8, length: usize, limit: usize) -> Result<&'a [u8], ResultCode> {
    if length > limit {
        return Err(ResultCode::LimitExceeded);
    }
    if length == 0 {
        return Ok(&[]);
    }
    if pointer.is_null() {
        return Err(ResultCode::InvalidArgument);
    }
    Ok(unsafe { slice::from_raw_parts(pointer, length) })
}

macro_rules! lock_client {
    ($client:expr) => {{
        if $client.is_null() {
            return ResultCode::InvalidArgument;
        }
        // SAFETY: the C contract requires the owned handle to remain alive for
        // this call and forbids racing free. The guard has this lexical scope.
        match unsafe { &(*$client).state }.lock() {
            Ok(guard) => guard,
            Err(_) => return ResultCode::Engine,
        }
    }};
}

fn candidate_mut(state: &mut State, token: u64) -> Result<&mut Candidate, ResultCode> {
    let candidate = state.candidate.as_mut().ok_or(ResultCode::NoCandidate)?;
    if candidate.token != token {
        return Err(ResultCode::StaleCandidate);
    }
    Ok(candidate)
}

fn ready_candidate_mut(
    state: &mut State,
    token: u64,
) -> Result<(&mut Terminal, &mut u64), ResultCode> {
    let candidate = candidate_mut(state, token)?;
    match &mut candidate.phase {
        CandidatePhase::Ready {
            terminal,
            state_seq,
        } => Ok((terminal, state_seq)),
        CandidatePhase::AwaitingCheckpoint { .. } => Err(ResultCode::Busy),
        CandidatePhase::Poisoned => Err(ResultCode::ResyncRequired),
    }
}

fn build_allocation_bytes(
    rows: &Vec<CachedRow>,
    cells: &Vec<CachedCell>,
    graphemes: &Vec<u8>,
    scratch_capacity: usize,
) -> Option<usize> {
    cache_allocation_bytes(rows.capacity(), cells.capacity(), graphemes.capacity())?
        .checked_add(vec_allocation_bytes::<u8>(scratch_capacity)?)
}

fn reserve_bounded<T>(
    values: &mut Vec<T>,
    additional: usize,
    live_before: usize,
    limit: usize,
    peak: &mut usize,
) -> Result<(), ResultCode> {
    let required = values
        .len()
        .checked_add(additional)
        .ok_or(ResultCode::LimitExceeded)?;
    if required <= values.capacity() {
        return Ok(());
    }
    // reserve_exact requests precisely this capacity. Count the old backing
    // allocation (already in live_before) and the replacement together: both
    // can be resident until realloc completes.
    let requested = vec_allocation_bytes::<T>(required).ok_or(ResultCode::LimitExceeded)?;
    let requested_transient = live_before
        .checked_add(requested)
        .ok_or(ResultCode::LimitExceeded)?;
    if requested_transient > limit {
        return Err(ResultCode::LimitExceeded);
    }
    values
        .try_reserve_exact(additional)
        .map_err(|_| ResultCode::OutOfMemory)?;
    let actual = vec_allocation_bytes::<T>(values.capacity()).ok_or(ResultCode::LimitExceeded)?;
    let actual_transient = live_before
        .checked_add(actual)
        .ok_or(ResultCode::LimitExceeded)?;
    *peak = (*peak).max(actual_transient);
    if actual_transient > limit {
        return Err(ResultCode::LimitExceeded);
    }
    Ok(())
}

fn build_delta(state: &mut State) -> Result<CpuCache, ResultCode> {
    state.active.begin_frame().map_err(map_engine)?;
    let info = match state.active.frame_info() {
        Ok(value) => value,
        Err(error) => {
            let _ = state.active.drop_uncommitted_frame();
            return Err(map_engine(error));
        }
    };
    let mut rows = Vec::new();
    let mut cells = Vec::new();
    let mut graphemes = Vec::new();
    let mut scratch = Vec::new();
    let old_bytes = match state.cache.as_ref() {
        Some(cache) => cache.retained_bytes().ok_or(ResultCode::LimitExceeded)?,
        None => 0,
    };
    if let Err(code) = reserve_bounded(
        &mut scratch,
        state.limits.max_grapheme_bytes,
        old_bytes,
        state.limits.cpu_cache_max_bytes,
        &mut state.cpu_cache_peak_bytes,
    ) {
        let _ = state.active.drop_uncommitted_frame();
        return Err(code);
    }
    let scratch_capacity = scratch.capacity();
    let result = (|| {
        while let Some(row) = state.active.next_row().map_err(map_engine)? {
            if rows
                .last()
                .is_some_and(|prior: &CachedRow| prior.row.y >= row.y)
                || row.y >= info.rows
            {
                return Err(ResultCode::Engine);
            }
            let live = old_bytes
                .checked_add(
                    build_allocation_bytes(&rows, &cells, &graphemes, scratch_capacity)
                        .ok_or(ResultCode::LimitExceeded)?,
                )
                .ok_or(ResultCode::LimitExceeded)?;
            reserve_bounded(
                &mut rows,
                1,
                live,
                state.limits.cpu_cache_max_bytes,
                &mut state.cpu_cache_peak_bytes,
            )?;
            let first_cell = cells.len();
            while let Some(cell) = state
                .active
                .next_cell_into(&mut scratch)
                .map_err(map_engine)?
            {
                let live = old_bytes
                    .checked_add(
                        build_allocation_bytes(&rows, &cells, &graphemes, scratch_capacity)
                            .ok_or(ResultCode::LimitExceeded)?,
                    )
                    .ok_or(ResultCode::LimitExceeded)?;
                reserve_bounded(
                    &mut cells,
                    1,
                    live,
                    state.limits.cpu_cache_max_bytes,
                    &mut state.cpu_cache_peak_bytes,
                )?;
                let live = old_bytes
                    .checked_add(
                        build_allocation_bytes(&rows, &cells, &graphemes, scratch_capacity)
                            .ok_or(ResultCode::LimitExceeded)?,
                    )
                    .ok_or(ResultCode::LimitExceeded)?;
                reserve_bounded(
                    &mut graphemes,
                    cell.grapheme.len(),
                    live,
                    state.limits.cpu_cache_max_bytes,
                    &mut state.cpu_cache_peak_bytes,
                )?;
                let grapheme_offset = graphemes.len();
                graphemes.extend_from_slice(cell.grapheme);
                cells.push(CachedCell {
                    x: cell.x,
                    width: cell.width,
                    grapheme_offset,
                    grapheme_len: cell.grapheme.len(),
                    selected: cell.selected,
                    has_styling: cell.has_styling,
                    has_hyperlink: cell.has_hyperlink,
                    semantic: cell.semantic,
                    foreground: cell.foreground,
                    background: cell.background,
                    underline_color: cell.underline_color,
                    bold: cell.bold,
                    italic: cell.italic,
                    faint: cell.faint,
                    blink: cell.blink,
                    inverse: cell.inverse,
                    invisible: cell.invisible,
                    strikethrough: cell.strikethrough,
                    overline: cell.overline,
                    underline: ClientUnderline::parse(cell.underline)?,
                });
            }
            let cell_count = cells
                .len()
                .checked_sub(first_cell)
                .ok_or(ResultCode::Engine)?;
            rows.push(CachedRow {
                row,
                first_cell,
                cell_count,
            });
            let live = old_bytes
                .checked_add(
                    build_allocation_bytes(&rows, &cells, &graphemes, scratch_capacity)
                        .ok_or(ResultCode::LimitExceeded)?,
                )
                .ok_or(ResultCode::LimitExceeded)?;
            state.cpu_cache_peak_bytes = state.cpu_cache_peak_bytes.max(live);
        }
        Ok(CpuCache {
            info,
            state_seq: state.active_state_seq,
            rows,
            cells,
            graphemes,
        })
    })();
    if result.is_err() {
        let _ = state.active.drop_uncommitted_frame();
    }
    result
}

fn append_row(
    target: &mut CpuCache,
    source: &CpuCache,
    row: &CachedRow,
    dirty: bool,
) -> Result<(), ResultCode> {
    if target.rows.len() == target.rows.capacity()
        || target.cells.capacity().saturating_sub(target.cells.len()) < row.cell_count
    {
        return Err(ResultCode::Engine);
    }
    let first_cell = target.cells.len();
    let end = row
        .first_cell
        .checked_add(row.cell_count)
        .ok_or(ResultCode::LimitExceeded)?;
    for cell in source
        .cells
        .get(row.first_cell..end)
        .ok_or(ResultCode::Engine)?
    {
        let grapheme_end = cell
            .grapheme_offset
            .checked_add(cell.grapheme_len)
            .ok_or(ResultCode::LimitExceeded)?;
        let value = source
            .graphemes
            .get(cell.grapheme_offset..grapheme_end)
            .ok_or(ResultCode::Engine)?;
        if target
            .graphemes
            .capacity()
            .saturating_sub(target.graphemes.len())
            < value.len()
        {
            return Err(ResultCode::Engine);
        }
        let mut copied = cell.clone();
        copied.grapheme_offset = target.graphemes.len();
        target.graphemes.extend_from_slice(value);
        target.cells.push(copied);
    }
    let mut copied_row = row.row;
    copied_row.dirty = dirty;
    target.rows.push(CachedRow {
        row: copied_row,
        first_cell,
        cell_count: row.cell_count,
    });
    Ok(())
}

fn row_grapheme_bytes(source: &CpuCache, row: &CachedRow) -> Result<usize, ResultCode> {
    let end = row
        .first_cell
        .checked_add(row.cell_count)
        .ok_or(ResultCode::LimitExceeded)?;
    source
        .cells
        .get(row.first_cell..end)
        .ok_or(ResultCode::Engine)?
        .iter()
        .try_fold(0usize, |total, cell| {
            total
                .checked_add(cell.grapheme_len)
                .ok_or(ResultCode::LimitExceeded)
        })
}

fn merge_cache(state: &mut State, mut delta: CpuCache) -> Result<CpuCache, ResultCode> {
    if delta.info.dirty == RenderDirty::Full || state.cache.is_none() {
        if delta.info.dirty != RenderDirty::Full || !delta.complete() {
            return Err(ResultCode::Engine);
        }
        // FULL means every row is damage, independent of engine-internal row
        // iterator details. The retained cache remains a complete framebuffer.
        for row in &mut delta.rows {
            row.row.dirty = true;
        }
        let delta_bytes = delta.retained_bytes().ok_or(ResultCode::LimitExceeded)?;
        let old_bytes = match state.cache.as_ref() {
            Some(cache) => cache.retained_bytes().ok_or(ResultCode::LimitExceeded)?,
            None => 0,
        };
        let transient = old_bytes
            .checked_add(delta_bytes)
            .ok_or(ResultCode::LimitExceeded)?;
        state.cpu_cache_peak_bytes = state.cpu_cache_peak_bytes.max(transient);
        if transient > state.limits.cpu_cache_max_bytes {
            return Err(ResultCode::LimitExceeded);
        }
        return Ok(delta);
    }
    let mut observed_peak = state.cpu_cache_peak_bytes;
    let result = (|| {
        let old = state.cache.as_ref().ok_or(ResultCode::Engine)?;
        if !old.complete()
            || old.info.columns != delta.info.columns
            || old.info.rows != delta.info.rows
        {
            return Err(ResultCode::Engine);
        }
        let mut merged_cells = 0usize;
        let mut merged_graphemes = 0usize;
        for y in 0..delta.info.rows {
            let (source, row) = match delta.rows.binary_search_by_key(&y, |row| row.row.y) {
                Ok(index) => {
                    let row = delta.rows.get(index).ok_or(ResultCode::Engine)?;
                    if row.row.dirty {
                        (&delta, row)
                    } else {
                        (old, old.rows.get(usize::from(y)).ok_or(ResultCode::Engine)?)
                    }
                }
                Err(_) => (old, old.rows.get(usize::from(y)).ok_or(ResultCode::Engine)?),
            };
            merged_cells = merged_cells
                .checked_add(row.cell_count)
                .ok_or(ResultCode::LimitExceeded)?;
            merged_graphemes = merged_graphemes
                .checked_add(row_grapheme_bytes(source, row)?)
                .ok_or(ResultCode::LimitExceeded)?;
        }
        let requested_merged_bytes =
            cache_allocation_bytes(usize::from(delta.info.rows), merged_cells, merged_graphemes)
                .ok_or(ResultCode::LimitExceeded)?;
        let base = old
            .retained_bytes()
            .and_then(|value| value.checked_add(delta.retained_bytes()?))
            .ok_or(ResultCode::LimitExceeded)?;
        let combined = base
            .checked_add(requested_merged_bytes)
            .ok_or(ResultCode::LimitExceeded)?;
        if combined > state.limits.cpu_cache_max_bytes {
            return Err(ResultCode::LimitExceeded);
        }

        let mut merged = CpuCache {
            info: delta.info.clone(),
            state_seq: delta.state_seq,
            rows: Vec::new(),
            cells: Vec::new(),
            graphemes: Vec::new(),
        };
        reserve_bounded(
            &mut merged.rows,
            usize::from(delta.info.rows),
            base,
            state.limits.cpu_cache_max_bytes,
            &mut observed_peak,
        )?;
        let live = base
            .checked_add(merged.retained_bytes().ok_or(ResultCode::LimitExceeded)?)
            .ok_or(ResultCode::LimitExceeded)?;
        reserve_bounded(
            &mut merged.cells,
            merged_cells,
            live,
            state.limits.cpu_cache_max_bytes,
            &mut observed_peak,
        )?;
        let live = base
            .checked_add(merged.retained_bytes().ok_or(ResultCode::LimitExceeded)?)
            .ok_or(ResultCode::LimitExceeded)?;
        reserve_bounded(
            &mut merged.graphemes,
            merged_graphemes,
            live,
            state.limits.cpu_cache_max_bytes,
            &mut observed_peak,
        )?;
        let actual_combined = base
            .checked_add(merged.retained_bytes().ok_or(ResultCode::LimitExceeded)?)
            .ok_or(ResultCode::LimitExceeded)?;
        observed_peak = observed_peak.max(actual_combined);
        if actual_combined > state.limits.cpu_cache_max_bytes {
            return Err(ResultCode::LimitExceeded);
        }
        for y in 0..delta.info.rows {
            match delta.rows.binary_search_by_key(&y, |row| row.row.y) {
                Ok(index) if delta.rows.get(index).ok_or(ResultCode::Engine)?.row.dirty => {
                    append_row(
                        &mut merged,
                        &delta,
                        delta.rows.get(index).ok_or(ResultCode::Engine)?,
                        true,
                    )?
                }
                Err(_) => append_row(
                    &mut merged,
                    old,
                    old.rows.get(usize::from(y)).ok_or(ResultCode::Engine)?,
                    false,
                )?,
                Ok(_) => append_row(
                    &mut merged,
                    old,
                    old.rows.get(usize::from(y)).ok_or(ResultCode::Engine)?,
                    false,
                )?,
            }
        }
        Ok(merged)
    })();
    state.cpu_cache_peak_bytes = observed_peak;
    result
}

fn rgb(value: Rgb) -> ClientRgb {
    ClientRgb {
        r: value.r,
        g: value.g,
        b: value.b,
    }
}

fn color(value: RenderColor) -> ClientColor {
    match value {
        RenderColor::Default => ClientColor::default(),
        RenderColor::Palette(index) => ClientColor {
            kind: 1,
            palette_index: index,
            rgb: ClientRgb::default(),
        },
        RenderColor::Rgb(value) => ClientColor {
            kind: 2,
            palette_index: 0,
            rgb: rgb(value),
        },
    }
}

fn fill_frame(out: &mut BulkFrame, cache: &CpuCache) {
    let info = &cache.info;
    out.state_seq = cache.state_seq;
    out.generation = info.generation;
    out.dirty = match info.dirty {
        RenderDirty::None => 0,
        RenderDirty::Partial => 1,
        RenderDirty::Full => 2,
    };
    out.columns = info.columns;
    out.rows = info.rows;
    out.row_count = cache.rows.len();
    out.cell_count = cache.cells.len();
    out.grapheme_bytes = cache.graphemes.len();
    out.cursor_has_value = info.cursor.is_some() as u8;
    (out.cursor_x, out.cursor_y) = info.cursor.map_or((0, 0), |cursor| cursor);
    out.cursor_wide_tail = info.cursor_wide_tail as u8;
    out.cursor_visible = info.cursor_visible as u8;
    out.cursor_blinking = info.cursor_blinking as u8;
    out.cursor_password_input = info.cursor_password_input as u8;
    out.cursor_style = match info.cursor_style {
        CursorStyle::Bar => 0,
        CursorStyle::Block => 1,
        CursorStyle::Underline => 2,
        CursorStyle::HollowBlock => 3,
    };
    out.background = rgb(info.background);
    out.foreground = rgb(info.foreground);
    out.cursor_color_has_value = info.cursor_color.is_some() as u8;
    out.cursor_color = info.cursor_color.map_or_else(ClientRgb::default, rgb);
    out.palette = info.palette.map(rgb);
}

fn valid_sized<T>(pointer: *const T, size: usize, abi: u32) -> bool {
    !pointer.is_null() && size >= size_of::<T>() && abi == RENDER_CLIENT_ABI_VERSION
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_manifest(out: *mut ClientManifest) -> ResultCode {
    if out.is_null() || !valid_sized(out, (*out).size, (*out).abi_version) {
        return ResultCode::InvalidArgument;
    }
    *out = manifest_value();
    ResultCode::Ok
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_manifest_matches(
    value: *const ClientManifest,
) -> ResultCode {
    if value.is_null() || !manifest_equal(&*value) {
        ResultCode::ManifestMismatch
    } else {
        ResultCode::Ok
    }
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_new(
    config: *const ClientConfig,
    out: *mut *mut OuroRenderClient,
) -> ResultCode {
    if config.is_null() || out.is_null() {
        return ResultCode::InvalidArgument;
    }
    *out = ptr::null_mut();
    let config = &*config;
    if !valid_config(config) {
        return ResultCode::InvalidArgument;
    }
    let active_stream = match Identity::parse(&config.initial_stream) {
        Ok(value) => value,
        Err(code) => return code,
    };
    let terminal_config = Config {
        columns: config.columns,
        rows: config.rows,
        cell_width_px: config.cell_width_px,
        cell_height_px: config.cell_height_px,
        scrollback_max_bytes: config.scrollback_max_bytes,
        scrollback_max_lines: config.scrollback_max_lines,
        kitty_image_max_bytes: 0,
        apc_max_bytes: 1024 * 1024,
        continuation_max_bytes: 64 * 1024,
        snapshot_max_bytes: config.snapshot_max_bytes,
        engine_memory_max_bytes: config.engine_memory_max_bytes,
    };
    let page_budget = match PageBudget::new(config.shared_page_budget_max_bytes) {
        Ok(value) => value,
        Err(error) => return map_engine(error),
    };
    let terminal = match Terminal::new_with_page_budget(terminal_config, &page_budget) {
        Ok(value) => value,
        Err(error) => return map_engine(error),
    };
    let projection_config = RenderProjectionConfig {
        memory_max_bytes: config.projection_memory_max_bytes,
        max_grapheme_bytes: config.max_grapheme_bytes,
    };
    let active = match terminal.try_into_owned_render_with_config(projection_config) {
        Ok(value) => value,
        Err((error, _)) => return map_engine(error),
    };
    *out = Box::into_raw(Box::new(OuroRenderClient {
        state: Mutex::new(State {
            active,
            active_stream,
            active_state_seq: config.initial_state_seq,
            active_poisoned: false,
            candidate: None,
            next_candidate_token: 1,
            cache: None,
            cpu_cache_peak_bytes: 0,
            leased_generation: None,
            retry_cache: false,
            limits: Limits {
                terminal: terminal_config,
                max_feed_bytes: config.max_feed_bytes,
                max_grapheme_bytes: config.max_grapheme_bytes,
                cpu_cache_max_bytes: config.cpu_cache_max_bytes,
            },
            page_budget,
        }),
    }));
    ResultCode::Ok
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_free(client: *mut OuroRenderClient) {
    if !client.is_null() {
        drop(Box::from_raw(client));
    }
}

fn write_engine(
    out_live: &mut usize,
    out_peak: &mut usize,
    out_limit: &mut usize,
    out_failures: &mut u64,
    info: MemoryInfo,
) {
    *out_live = info.live_bytes;
    *out_peak = info.peak_bytes;
    *out_limit = info.limit_bytes;
    *out_failures = info.allocation_failures;
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_memory_info(
    client: *mut OuroRenderClient,
    out: *mut ClientMemoryInfo,
) -> ResultCode {
    if out.is_null() || !valid_sized(out, (*out).size, (*out).abi_version) {
        return ResultCode::InvalidArgument;
    }
    let state = lock_client!(client);
    let projection = match state.active.memory_info() {
        Ok(value) => value,
        Err(error) => return map_engine(error),
    };
    let active = match state.active.try_terminal().and_then(Terminal::memory_info) {
        Ok(value) => value,
        Err(error) => return map_engine(error),
    };
    let pages = match state.page_budget.stats() {
        Ok(value) => value,
        Err(error) => return map_engine(error),
    };
    (*out).cpu_cache_live_bytes = match state.cache.as_ref() {
        Some(cache) => match cache.retained_bytes() {
            Some(value) => value,
            None => return ResultCode::Engine,
        },
        None => 0,
    };
    (*out).cpu_cache_peak_bytes = state.cpu_cache_peak_bytes;
    (*out).cpu_cache_limit_bytes = state.limits.cpu_cache_max_bytes;
    (*out).projection_live_bytes = projection.live_bytes;
    (*out).projection_peak_bytes = projection.peak_bytes;
    (*out).projection_limit_bytes = projection.limit_bytes;
    (*out).projection_allocation_failures = projection.allocation_failures;
    write_engine(
        &mut (*out).active_engine_live_bytes,
        &mut (*out).active_engine_peak_bytes,
        &mut (*out).active_engine_limit_bytes,
        &mut (*out).active_engine_allocation_failures,
        active,
    );
    (*out).candidate_present = state.candidate.is_some() as u8;
    if let Some(Candidate {
        phase: CandidatePhase::Ready { terminal, .. },
        ..
    }) = state.candidate.as_ref()
    {
        let info = match terminal.memory_info() {
            Ok(value) => value,
            Err(error) => return map_engine(error),
        };
        write_engine(
            &mut (*out).candidate_engine_live_bytes,
            &mut (*out).candidate_engine_peak_bytes,
            &mut (*out).candidate_engine_limit_bytes,
            &mut (*out).candidate_engine_allocation_failures,
            info,
        );
    } else {
        (*out).candidate_engine_live_bytes = 0;
        (*out).candidate_engine_peak_bytes = 0;
        (*out).candidate_engine_limit_bytes = 0;
        (*out).candidate_engine_allocation_failures = 0;
    }
    (*out).page_reserved_bytes = pages.reserved_bytes;
    (*out).page_peak_reserved_bytes = pages.peak_reserved_bytes;
    (*out).page_limit_bytes = pages.limit_bytes;
    (*out).page_denial_count = pages.denial_count;
    (*out).page_child_failure_count = pages.child_failure_count;
    (*out).active_terminal_count = 1;
    (*out).candidate_terminal_count = state
        .candidate
        .as_ref()
        .is_some_and(|candidate| matches!(candidate.phase, CandidatePhase::Ready { .. }))
        as u8;
    (*out).projection_count = 1;
    ResultCode::Ok
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_active_feed(
    client: *mut OuroRenderClient,
    stream: *const StreamIdentity,
    seq: u64,
    data: *const u8,
    length: usize,
) -> ResultCode {
    if stream.is_null() {
        return ResultCode::InvalidArgument;
    }
    let identity = match Identity::parse(&*stream) {
        Ok(v) => v,
        Err(c) => return c,
    };
    let mut state = lock_client!(client);
    if identity != state.active_stream {
        return ResultCode::StaleStream;
    }
    if state.active_poisoned {
        return ResultCode::ResyncRequired;
    }
    if !next_seq(state.active_state_seq, seq) {
        return ResultCode::StateSeqGap;
    }
    let data = match bytes(data, length, state.limits.max_feed_bytes) {
        Ok(v) => v,
        Err(c) => return c,
    };
    match state.active.feed(data) {
        Ok(()) => {
            state.active_state_seq = seq;
            ResultCode::Ok
        }
        Err(e) => {
            // Ghostty feed can consume a prefix before an allocator failure.
            // Never present that partially mutated terminal as state `seq - 1`.
            state.active_poisoned = true;
            map_engine(e)
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_active_resize(
    client: *mut OuroRenderClient,
    stream: *const StreamIdentity,
    seq: u64,
    columns: u16,
    rows: u16,
    cw: u32,
    ch: u32,
) -> ResultCode {
    if stream.is_null() || columns == 0 || rows == 0 || cw == 0 || ch == 0 {
        return ResultCode::InvalidArgument;
    }
    let identity = match Identity::parse(&*stream) {
        Ok(v) => v,
        Err(c) => return c,
    };
    let mut state = lock_client!(client);
    if identity != state.active_stream {
        return ResultCode::StaleStream;
    }
    if state.active_poisoned {
        return ResultCode::ResyncRequired;
    }
    if !next_seq(state.active_state_seq, seq) {
        return ResultCode::StateSeqGap;
    }
    match state.active.resize(columns, rows, cw, ch) {
        Ok(()) => {
            // A terminal resize is also a renderer geometry transaction. The
            // cell contents may be byte-for-byte unchanged, but the desktop
            // surface must rebuild every glyph against the new pixel cell and
            // font atlas. Without an explicit full damage mark, a typography
            // change can update the PTY dimensions while Metal keeps showing
            // the retained scene at the previous size.
            if let Err(error) = state.active.force_full() {
                state.active_poisoned = true;
                return map_engine(error);
            }
            state.active_state_seq = seq;
            ResultCode::Ok
        }
        Err(e) => map_engine(e),
    }
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_candidate_begin(
    client: *mut OuroRenderClient,
    stream: *const StreamIdentity,
    base_seq: u64,
    out_token: *mut u64,
) -> ResultCode {
    if stream.is_null() || out_token.is_null() {
        return ResultCode::InvalidArgument;
    }
    let identity = match Identity::parse(&*stream) {
        Ok(v) => v,
        Err(c) => return c,
    };
    let mut state = lock_client!(client);
    if state.candidate.is_some() {
        return ResultCode::Busy;
    }
    let token = state.next_candidate_token;
    state.next_candidate_token = match token.checked_add(1) {
        Some(v) => v,
        None => return ResultCode::LimitExceeded,
    };
    state.candidate = Some(Candidate {
        token,
        stream: identity,
        phase: CandidatePhase::AwaitingCheckpoint { base_seq },
    });
    *out_token = token;
    ResultCode::Ok
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_candidate_import_checkpoint(
    client: *mut OuroRenderClient,
    token: u64,
    manifest: *const ClientManifest,
    seq: u64,
    data: *const u8,
    length: usize,
) -> ResultCode {
    if manifest.is_null() || !manifest_equal(&*manifest) {
        return ResultCode::ManifestMismatch;
    }
    let mut state = lock_client!(client);
    let base_seq = match state.candidate.as_ref() {
        Some(Candidate {
            token: current,
            phase: CandidatePhase::AwaitingCheckpoint { base_seq },
            ..
        }) if *current == token => *base_seq,
        Some(Candidate { token: current, .. }) if *current != token => {
            return ResultCode::StaleCandidate
        }
        Some(_) => return ResultCode::Busy,
        None => return ResultCode::NoCandidate,
    };
    if seq != base_seq {
        return ResultCode::StateSeqGap;
    }
    let data = match bytes(data, length, state.limits.terminal.snapshot_max_bytes) {
        Ok(v) => v,
        Err(c) => return c,
    };
    let terminal =
        match Terminal::restore_with_page_budget(state.limits.terminal, &state.page_budget, data) {
            Ok(v) => v,
            Err(e) => return map_engine(e),
        };
    let Some(candidate) = state.candidate.as_mut() else {
        return ResultCode::NoCandidate;
    };
    candidate.phase = CandidatePhase::Ready {
        terminal,
        state_seq: seq,
    };
    ResultCode::Ok
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_candidate_feed(
    client: *mut OuroRenderClient,
    token: u64,
    seq: u64,
    data: *const u8,
    length: usize,
) -> ResultCode {
    let mut state = lock_client!(client);
    let limit = state.limits.max_feed_bytes;
    let data = match bytes(data, length, limit) {
        Ok(v) => v,
        Err(c) => return c,
    };
    let candidate = match state.candidate.take() {
        Some(candidate) if candidate.token == token => candidate,
        Some(candidate) => {
            state.candidate = Some(candidate);
            return ResultCode::StaleCandidate;
        }
        None => return ResultCode::NoCandidate,
    };
    let Candidate {
        token,
        stream,
        phase,
    } = candidate;
    let (mut terminal, state_seq) = match phase {
        CandidatePhase::Ready {
            terminal,
            state_seq,
        } => (terminal, state_seq),
        phase @ CandidatePhase::AwaitingCheckpoint { .. } => {
            state.candidate = Some(Candidate {
                token,
                stream,
                phase,
            });
            return ResultCode::Busy;
        }
        CandidatePhase::Poisoned => {
            state.candidate = Some(Candidate {
                token,
                stream,
                phase: CandidatePhase::Poisoned,
            });
            return ResultCode::ResyncRequired;
        }
    };
    if !next_seq(state_seq, seq) {
        state.candidate = Some(Candidate {
            token,
            stream,
            phase: CandidatePhase::Ready {
                terminal,
                state_seq,
            },
        });
        return ResultCode::StateSeqGap;
    }
    match terminal.feed(data) {
        Ok(()) => {
            state.candidate = Some(Candidate {
                token,
                stream,
                phase: CandidatePhase::Ready {
                    terminal,
                    state_seq: seq,
                },
            });
            ResultCode::Ok
        }
        Err(error) => {
            // Drop the prefix-mutated terminal. The token remains only so the
            // caller gets an explicit resync result until it aborts recovery.
            drop(terminal);
            state.candidate = Some(Candidate {
                token,
                stream,
                phase: CandidatePhase::Poisoned,
            });
            map_engine(error)
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_candidate_resize(
    client: *mut OuroRenderClient,
    token: u64,
    seq: u64,
    columns: u16,
    rows: u16,
    cw: u32,
    ch: u32,
) -> ResultCode {
    if columns == 0 || rows == 0 || cw == 0 || ch == 0 {
        return ResultCode::InvalidArgument;
    }
    let mut state = lock_client!(client);
    let (terminal, state_seq) = match ready_candidate_mut(&mut state, token) {
        Ok(v) => v,
        Err(c) => return c,
    };
    if !next_seq(*state_seq, seq) {
        return ResultCode::StateSeqGap;
    }
    match terminal.resize(columns, rows, cw, ch) {
        Ok(()) => {
            *state_seq = seq;
            ResultCode::Ok
        }
        Err(e) => map_engine(e),
    }
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_candidate_commit(
    client: *mut OuroRenderClient,
    token: u64,
    attached_ready_seq: u64,
) -> ResultCode {
    let mut state = lock_client!(client);
    if state.leased_generation.is_some() || state.retry_cache {
        return ResultCode::Busy;
    }
    let candidate = match state.candidate.take() {
        Some(v) if v.token == token => v,
        Some(v) => {
            state.candidate = Some(v);
            return ResultCode::StaleCandidate;
        }
        None => return ResultCode::NoCandidate,
    };
    let Candidate {
        token,
        stream,
        phase,
    } = candidate;
    let (terminal, state_seq) = match phase {
        CandidatePhase::Ready {
            terminal,
            state_seq,
        } if state_seq == attached_ready_seq => (terminal, state_seq),
        phase @ CandidatePhase::Ready { .. } => {
            state.candidate = Some(Candidate {
                token,
                stream,
                phase,
            });
            return ResultCode::StateSeqGap;
        }
        phase @ CandidatePhase::AwaitingCheckpoint { .. } => {
            state.candidate = Some(Candidate {
                token,
                stream,
                phase,
            });
            return ResultCode::Busy;
        }
        CandidatePhase::Poisoned => {
            state.candidate = Some(Candidate {
                token,
                stream,
                phase: CandidatePhase::Poisoned,
            });
            return ResultCode::ResyncRequired;
        }
    };
    let mut terminal = terminal;
    // Candidate recovery replays historical bytes. BEL effects from replay are
    // not live user notifications and must never leak across the cutover.
    if let Err(error) = terminal.take_bells() {
        state.candidate = Some(Candidate {
            token,
            stream,
            phase: CandidatePhase::Ready {
                terminal,
                state_seq,
            },
        });
        return map_engine(error);
    }
    match state.active.replace_terminal(terminal) {
        Ok(old) => {
            drop(old);
            state.active_stream = stream;
            state.active_state_seq = state_seq;
            state.active_poisoned = false;
            state.cache = None;
            state.retry_cache = false;
            ResultCode::Ok
        }
        Err((e, terminal)) => {
            state.candidate = Some(Candidate {
                token,
                stream,
                phase: CandidatePhase::Ready {
                    terminal,
                    state_seq,
                },
            });
            map_engine(e)
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_candidate_abort(
    client: *mut OuroRenderClient,
    token: u64,
) -> ResultCode {
    let mut state = lock_client!(client);
    match state.candidate.as_ref() {
        Some(v) if v.token == token => {
            state.candidate = None;
            ResultCode::Ok
        }
        Some(_) => ResultCode::StaleCandidate,
        None => ResultCode::NoCandidate,
    }
}

fn acquire(state: &mut State) -> Result<u64, ResultCode> {
    if state.leased_generation.is_some() {
        return Err(ResultCode::Busy);
    }
    if state.retry_cache {
        let generation = state
            .cache
            .as_ref()
            .ok_or(ResultCode::Engine)?
            .info
            .generation;
        state.leased_generation = Some(generation);
        return Ok(generation);
    }
    if state.active_poisoned {
        return Err(ResultCode::ResyncRequired);
    }
    let delta = build_delta(state)?;
    let merged = match merge_cache(state, delta) {
        Ok(v) => v,
        Err(c) => {
            let _ = state.active.drop_uncommitted_frame();
            return Err(c);
        }
    };
    state.active.commit_cpu_cache().map_err(map_engine)?;
    let live = merged.retained_bytes().ok_or(ResultCode::LimitExceeded)?;
    state.cpu_cache_peak_bytes = state.cpu_cache_peak_bytes.max(live);
    let generation = merged.info.generation;
    state.cache = Some(merged);
    state.leased_generation = Some(generation);
    Ok(generation)
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_acquire_frame(
    client: *mut OuroRenderClient,
    out: *mut BulkFrame,
) -> ResultCode {
    if out.is_null() || !valid_sized(out, (*out).size, (*out).abi_version) {
        return ResultCode::InvalidArgument;
    }
    let mut state = lock_client!(client);
    if let Err(c) = acquire(&mut state) {
        return c;
    }
    let Some(cache) = state.cache.as_ref() else {
        return ResultCode::Engine;
    };
    fill_frame(&mut *out, cache);
    if state.retry_cache {
        (*out).dirty = 2;
    }
    ResultCode::Ok
}

fn row_wire(row: &CachedRow, full_damage: bool) -> ClientRow {
    ClientRow {
        y: row.row.y,
        first_cell_index: row.first_cell,
        cell_count: row.cell_count,
        dirty: (full_damage || row.row.dirty) as u8,
        selection_has_value: row.row.selection.is_some() as u8,
        selection_start_x: row.row.selection.map_or(0, |v| v.0),
        selection_end_x: row.row.selection.map_or(0, |v| v.1),
        wrap: row.row.wrap as u8,
        wrap_continuation: row.row.wrap_continuation as u8,
        semantic: match row.row.semantic {
            RowSemantic::None => 0,
            RowSemantic::Prompt => 1,
            RowSemantic::PromptContinuation => 2,
        },
    }
}
fn cell_wire(cell: &CachedCell) -> ClientCell {
    ClientCell {
        x: cell.x,
        width: cell.width,
        grapheme_offset: cell.grapheme_offset,
        grapheme_bytes: cell.grapheme_len,
        flags: (cell.selected as u32)
            | ((cell.has_styling as u32) << 1)
            | ((cell.has_hyperlink as u32) << 2)
            | ((cell.bold as u32) << 3)
            | ((cell.italic as u32) << 4)
            | ((cell.faint as u32) << 5)
            | ((cell.blink as u32) << 6)
            | ((cell.inverse as u32) << 7)
            | ((cell.invisible as u32) << 8)
            | ((cell.strikethrough as u32) << 9)
            | ((cell.overline as u32) << 10),
        semantic: match cell.semantic {
            CellSemantic::Output => 0,
            CellSemantic::Input => 1,
            CellSemantic::Prompt => 2,
        },
        foreground: color(cell.foreground),
        background: color(cell.background),
        underline_color: color(cell.underline_color),
        underline: cell.underline,
    }
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_copy_frame_bulk(
    client: *mut OuroRenderClient,
    generation: u64,
    rows: *mut ClientRow,
    row_capacity: usize,
    cells: *mut ClientCell,
    cell_capacity: usize,
    graphemes: *mut u8,
    grapheme_capacity: usize,
    out: *mut BulkFrame,
) -> ResultCode {
    if out.is_null() || !valid_sized(out, (*out).size, (*out).abi_version) {
        return ResultCode::InvalidArgument;
    }
    let state = lock_client!(client);
    if state.leased_generation != Some(generation) {
        return ResultCode::StaleFrame;
    }
    let cache = match state.cache.as_ref() {
        Some(v) => v,
        None => return ResultCode::Engine,
    };
    fill_frame(&mut *out, cache);
    let full_damage = cache.info.dirty == RenderDirty::Full || state.retry_cache;
    if state.retry_cache {
        (*out).dirty = 2;
    }
    if row_capacity < cache.rows.len()
        || cell_capacity < cache.cells.len()
        || grapheme_capacity < cache.graphemes.len()
    {
        return ResultCode::BufferTooSmall;
    }
    if (!cache.rows.is_empty() && rows.is_null())
        || (!cache.cells.is_empty() && cells.is_null())
        || (!cache.graphemes.is_empty() && graphemes.is_null())
    {
        return ResultCode::InvalidArgument;
    }
    for (i, value) in cache
        .rows
        .iter()
        .map(|row| row_wire(row, full_damage))
        .enumerate()
    {
        *rows.add(i) = value;
    }
    for (i, value) in cache.cells.iter().map(cell_wire).enumerate() {
        *cells.add(i) = value;
    }
    if !cache.graphemes.is_empty() {
        ptr::copy_nonoverlapping(cache.graphemes.as_ptr(), graphemes, cache.graphemes.len());
    }
    ResultCode::Ok
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_finish_frame_lease(
    client: *mut OuroRenderClient,
    generation: u64,
    disposition: u32,
) -> ResultCode {
    if disposition > 1 {
        return ResultCode::InvalidArgument;
    }
    let mut state = lock_client!(client);
    if state.leased_generation != Some(generation) {
        return ResultCode::StaleFrame;
    }
    state.leased_generation = None;
    state.retry_cache = disposition == 1;
    ResultCode::Ok
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_cancel_frame_retry(
    client: *mut OuroRenderClient,
) -> ResultCode {
    let mut state = lock_client!(client);
    if state.leased_generation.is_some() {
        return ResultCode::Busy;
    }
    state.retry_cache = false;
    ResultCode::Ok
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_active_selection_begin(
    client: *mut OuroRenderClient,
    context: *const ProjectionContext,
    point: *const ClientSelectionPoint,
    outcome: *mut ClientSelectionOutcome,
) -> ResultCode {
    if context.is_null() || point.is_null() || outcome.is_null() {
        return ResultCode::InvalidArgument;
    }
    let (identity, minimum_state_seq) = match (*context).parse() {
        Ok(value) => value,
        Err(code) => return code,
    };
    let point = match (*point).parse() {
        Ok(value) => value,
        Err(code) => return code,
    };
    if let Err(code) = validate_mutation_outcome(&*outcome) {
        return code;
    }
    let mut state = lock_client!(client);
    if let Err(code) = validate_active_projection(&state, &identity, minimum_state_seq) {
        return code;
    }
    if state.leased_generation.is_some() {
        return ResultCode::Busy;
    }
    let selection = match state.active.try_terminal_mut() {
        Ok(terminal) => match terminal.selection(selection_config()) {
            Ok(mut selection) => selection.begin(point),
            Err(error) => return map_engine(error),
        },
        Err(error) => return map_engine(error),
    };
    match selection {
        Ok(value) => finish_selection_mutation(
            &mut state,
            &mut *outcome,
            value,
            EngineSelectionAutoscroll::None,
        ),
        Err(error) => map_engine(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_active_selection_update(
    client: *mut OuroRenderClient,
    context: *const ProjectionContext,
    point: *const ClientSelectionPoint,
    geometry: *const ClientSelectionGeometry,
    rectangle: u8,
    outcome: *mut ClientSelectionOutcome,
) -> ResultCode {
    if context.is_null()
        || point.is_null()
        || geometry.is_null()
        || outcome.is_null()
        || rectangle > 1
    {
        return ResultCode::InvalidArgument;
    }
    let (identity, minimum_state_seq) = match (*context).parse() {
        Ok(value) => value,
        Err(code) => return code,
    };
    let point = match (*point).parse() {
        Ok(value) => value,
        Err(code) => return code,
    };
    let geometry = match (*geometry).parse() {
        Ok(value) => value,
        Err(code) => return code,
    };
    if let Err(code) = validate_mutation_outcome(&*outcome) {
        return code;
    }
    let mut state = lock_client!(client);
    if let Err(code) = validate_active_projection(&state, &identity, minimum_state_seq) {
        return code;
    }
    if state.leased_generation.is_some() {
        return ResultCode::Busy;
    }
    let selection = match state.active.try_terminal_mut() {
        Ok(terminal) => match terminal.selection(selection_config()) {
            Ok(mut selection) => selection.update(point, geometry, rectangle == 1),
            Err(error) => return map_engine(error),
        },
        Err(error) => return map_engine(error),
    };
    match selection {
        Ok(value) => finish_selection_mutation(
            &mut state,
            &mut *outcome,
            value,
            EngineSelectionAutoscroll::None,
        ),
        Err(error) => map_engine(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_active_selection_autoscroll(
    client: *mut OuroRenderClient,
    context: *const ProjectionContext,
    viewport_column: u16,
    viewport_row: u32,
    surface_x: f64,
    surface_y: f64,
    geometry: *const ClientSelectionGeometry,
    rectangle: u8,
    outcome: *mut ClientSelectionOutcome,
) -> ResultCode {
    if context.is_null()
        || geometry.is_null()
        || outcome.is_null()
        || rectangle > 1
        || !surface_x.is_finite()
        || !surface_y.is_finite()
    {
        return ResultCode::InvalidArgument;
    }
    let (identity, minimum_state_seq) = match (*context).parse() {
        Ok(value) => value,
        Err(code) => return code,
    };
    let geometry = match (*geometry).parse() {
        Ok(value) => value,
        Err(code) => return code,
    };
    if let Err(code) = validate_mutation_outcome(&*outcome) {
        return code;
    }
    let mut state = lock_client!(client);
    if let Err(code) = validate_active_projection(&state, &identity, minimum_state_seq) {
        return code;
    }
    if state.leased_generation.is_some() {
        return ResultCode::Busy;
    }
    let selection = match state.active.try_terminal_mut() {
        Ok(terminal) => match terminal.selection(selection_config()) {
            Ok(mut selection) => selection.autoscroll(
                (viewport_column, viewport_row),
                (surface_x, surface_y),
                geometry,
                rectangle == 1,
            ),
            Err(error) => return map_engine(error),
        },
        Err(error) => return map_engine(error),
    };
    match selection {
        Ok((value, direction)) => {
            finish_selection_mutation(&mut state, &mut *outcome, value, direction)
        }
        Err(error) => map_engine(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_active_selection_end(
    client: *mut OuroRenderClient,
    context: *const ProjectionContext,
    point: *const ClientSelectionPoint,
    outcome: *mut ClientSelectionOutcome,
) -> ResultCode {
    if context.is_null() || outcome.is_null() {
        return ResultCode::InvalidArgument;
    }
    let (identity, minimum_state_seq) = match (*context).parse() {
        Ok(value) => value,
        Err(code) => return code,
    };
    let point = if point.is_null() {
        None
    } else {
        match (*point).parse() {
            Ok(value) => Some(value),
            Err(code) => return code,
        }
    };
    if let Err(code) = validate_mutation_outcome(&*outcome) {
        return code;
    }
    let mut state = lock_client!(client);
    if let Err(code) = validate_active_projection(&state, &identity, minimum_state_seq) {
        return code;
    }
    if state.leased_generation.is_some() {
        return ResultCode::Busy;
    }
    let selection = match state.active.try_terminal_mut() {
        Ok(terminal) => match terminal.selection(selection_config()) {
            Ok(mut selection) => selection.end(point),
            Err(error) => return map_engine(error),
        },
        Err(error) => return map_engine(error),
    };
    match selection {
        Ok(value) => finish_selection_mutation(
            &mut state,
            &mut *outcome,
            value,
            EngineSelectionAutoscroll::None,
        ),
        Err(error) => map_engine(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_active_selection_cancel(
    client: *mut OuroRenderClient,
    context: *const ProjectionContext,
    outcome: *mut ClientSelectionOutcome,
) -> ResultCode {
    if context.is_null() || outcome.is_null() {
        return ResultCode::InvalidArgument;
    }
    let (identity, minimum_state_seq) = match (*context).parse() {
        Ok(value) => value,
        Err(code) => return code,
    };
    if let Err(code) = validate_mutation_outcome(&*outcome) {
        return code;
    }
    let mut state = lock_client!(client);
    if let Err(code) = validate_active_projection(&state, &identity, minimum_state_seq) {
        return code;
    }
    if state.leased_generation.is_some() {
        return ResultCode::Busy;
    }
    let result = match state.active.try_terminal_mut() {
        Ok(terminal) => match terminal.selection(selection_config()) {
            Ok(mut selection) => selection.cancel(),
            Err(error) => return map_engine(error),
        },
        Err(error) => return map_engine(error),
    };
    match result {
        Ok(()) => finish_selection_mutation(
            &mut state,
            &mut *outcome,
            EngineSelectionOutcome::NoValue,
            EngineSelectionAutoscroll::None,
        ),
        Err(error) => map_engine(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_active_selection_copy(
    client: *mut OuroRenderClient,
    context: *const ProjectionContext,
    buffer: *mut u8,
    capacity: usize,
    out_length: *mut usize,
) -> ResultCode {
    if context.is_null() || out_length.is_null() || (capacity != 0 && buffer.is_null()) {
        return ResultCode::InvalidArgument;
    }
    let (identity, minimum_state_seq) = match (*context).parse() {
        Ok(value) => value,
        Err(code) => return code,
    };
    *out_length = 0;
    let mut state = lock_client!(client);
    if let Err(code) = validate_active_projection(&state, &identity, minimum_state_seq) {
        return code;
    }
    // Never construct an attacker-sized Rust slice. The engine selection is
    // configured with the same hard cap, so additional caller capacity is
    // intentionally invisible to it.
    let output: &mut [u8] = if capacity == 0 {
        &mut []
    } else {
        slice::from_raw_parts_mut(buffer, capacity.min(MAX_SELECTION_COPY_BYTES))
    };
    let copy = match state.active.try_terminal_mut() {
        Ok(terminal) => match terminal.selection(selection_config()) {
            Ok(mut selection) => selection.copy(output),
            Err(error) => return map_engine(error),
        },
        Err(error) => return map_engine(error),
    };
    match copy {
        Ok(SelectionCopyOutcome::Written(length)) => {
            if length > MAX_SELECTION_COPY_BYTES || length > output.len() {
                return ResultCode::Engine;
            }
            *out_length = length;
            ResultCode::Ok
        }
        Ok(SelectionCopyOutcome::BufferTooSmall { required }) => {
            *out_length = required;
            if required > MAX_SELECTION_COPY_BYTES {
                ResultCode::LimitExceeded
            } else {
                ResultCode::BufferTooSmall
            }
        }
        Ok(SelectionCopyOutcome::NoSelection) => ResultCode::NoValue,
        Err(error) => map_engine(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_active_copy_plain_text(
    client: *mut OuroRenderClient,
    context: *const ProjectionContext,
    buffer: *mut u8,
    capacity: usize,
    out_length: *mut usize,
) -> ResultCode {
    if context.is_null() || out_length.is_null() || (capacity != 0 && buffer.is_null()) {
        return ResultCode::InvalidArgument;
    }
    let (identity, minimum_state_seq) = match (*context).parse() {
        Ok(value) => value,
        Err(code) => return code,
    };
    *out_length = 0;
    let mut state = lock_client!(client);
    if let Err(code) = validate_active_projection(&state, &identity, minimum_state_seq) {
        return code;
    }
    if state.leased_generation.is_some() {
        return ResultCode::Busy;
    }
    let text = match state.active.try_terminal_mut() {
        Ok(terminal) => match terminal.plain_text() {
            Ok(value) => value,
            Err(error) => return map_engine(error),
        },
        Err(error) => return map_engine(error),
    };
    if text.len() > MAX_FIND_TEXT_BYTES {
        return ResultCode::LimitExceeded;
    }
    *out_length = text.len();
    if capacity < text.len() {
        return ResultCode::BufferTooSmall;
    }
    if !text.is_empty() {
        ptr::copy_nonoverlapping(text.as_ptr(), buffer, text.len());
    }
    ResultCode::Ok
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_active_copy_metadata(
    client: *mut OuroRenderClient,
    context: *const ProjectionContext,
    kind: u8,
    buffer: *mut u8,
    capacity: usize,
    out_length: *mut usize,
) -> ResultCode {
    if context.is_null() || out_length.is_null() || (capacity != 0 && buffer.is_null()) {
        return ResultCode::InvalidArgument;
    }
    let (identity, minimum_state_seq) = match (*context).parse() {
        Ok(value) => value,
        Err(code) => return code,
    };
    *out_length = 0;
    let state = lock_client!(client);
    if let Err(code) = validate_active_projection(&state, &identity, minimum_state_seq) {
        return code;
    }
    copy_metadata(&state.active, kind, buffer, capacity, out_length)
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_active_metadata_epoch(
    client: *mut OuroRenderClient,
    context: *const ProjectionContext,
    out_epoch: *mut u64,
) -> ResultCode {
    if context.is_null() || out_epoch.is_null() {
        return ResultCode::InvalidArgument;
    }
    let (identity, minimum_state_seq) = match (*context).parse() {
        Ok(value) => value,
        Err(code) => return code,
    };
    let state = lock_client!(client);
    if let Err(code) = validate_active_projection(&state, &identity, minimum_state_seq) {
        return code;
    }
    match state.active.metadata_epoch() {
        Ok(epoch) => {
            *out_epoch = epoch;
            ResultCode::Ok
        }
        Err(error) => map_engine(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_active_hyperlink_uri(
    client: *mut OuroRenderClient,
    context: *const ProjectionContext,
    column: u16,
    row: u32,
    buffer: *mut u8,
    capacity: usize,
    out_length: *mut usize,
) -> ResultCode {
    if context.is_null() || out_length.is_null() || (capacity != 0 && buffer.is_null()) {
        return ResultCode::InvalidArgument;
    }
    let (identity, minimum_state_seq) = match (*context).parse() {
        Ok(value) => value,
        Err(code) => return code,
    };
    *out_length = 0;
    let mut state = lock_client!(client);
    if let Err(code) = validate_active_projection(&state, &identity, minimum_state_seq) {
        return code;
    }
    if state.leased_generation.is_some() {
        return ResultCode::Busy;
    }
    let uri = match state.active.try_terminal_mut() {
        Ok(terminal) => {
            match terminal.hyperlink_uri_at_viewport(column, row, MAX_HYPERLINK_URI_BYTES) {
                Ok(value) => value,
                Err(EngineError::BufferTooSmall) => return ResultCode::LimitExceeded,
                Err(error) => return map_engine(error),
            }
        }
        Err(error) => return map_engine(error),
    };
    let Some(uri) = uri else {
        return ResultCode::NoValue;
    };
    *out_length = uri.len();
    if capacity < uri.len() {
        return ResultCode::BufferTooSmall;
    }
    if !uri.is_empty() {
        ptr::copy_nonoverlapping(uri.as_ptr(), buffer, uri.len());
    }
    ResultCode::Ok
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_active_take_bells(
    client: *mut OuroRenderClient,
    context: *const ProjectionContext,
    out_count: *mut u32,
) -> ResultCode {
    if context.is_null() || out_count.is_null() {
        return ResultCode::InvalidArgument;
    }
    let (identity, minimum_state_seq) = match (*context).parse() {
        Ok(value) => value,
        Err(code) => return code,
    };
    *out_count = 0;
    let mut state = lock_client!(client);
    if let Err(code) = validate_active_projection(&state, &identity, minimum_state_seq) {
        return code;
    }
    // Bells are terminal metadata, not a retained CPU frame. `begin_frame`
    // commits the CPU cache before exposing the lease, so draining here is
    // safe while the renderer holds the generation and keeps PTY delivery
    // from turning a normal bell into a spurious BUSY/resync.
    match state.active.try_terminal_mut() {
        Ok(terminal) => match terminal.take_bells() {
            Ok(value) => {
                *out_count = value;
                ResultCode::Ok
            }
            Err(error) => map_engine(error),
        },
        Err(error) => map_engine(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_active_viewport_scroll(
    client: *mut OuroRenderClient,
    context: *const ProjectionContext,
    request: *const ClientViewportScroll,
) -> ResultCode {
    if context.is_null() || request.is_null() {
        return ResultCode::InvalidArgument;
    }
    let (identity, minimum_state_seq) = match (*context).parse() {
        Ok(value) => value,
        Err(code) => return code,
    };
    let request = match (*request).parse() {
        Ok(value) => value,
        Err(code) => return code,
    };
    let mut state = lock_client!(client);
    if let Err(code) = validate_active_projection(&state, &identity, minimum_state_seq) {
        return code;
    }
    if state.leased_generation.is_some() {
        return ResultCode::Busy;
    }
    let result = match state.active.try_terminal_mut() {
        Ok(terminal) => terminal.scroll_viewport(request),
        Err(error) => return map_engine(error),
    };
    if let Err(error) = result {
        return map_engine(error);
    }
    // Even a clamped/no-op request is a successfully applied local viewport
    // mutation and must produce a fresh, complete projection frame.
    match state.active.force_full() {
        Ok(()) => ResultCode::Ok,
        Err(error) => map_engine(error),
    }
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_active_scrollbar(
    client: *mut OuroRenderClient,
    context: *const ProjectionContext,
    out_scrollbar: *mut ClientScrollbar,
) -> ResultCode {
    if context.is_null() || out_scrollbar.is_null() {
        return ResultCode::InvalidArgument;
    }
    let (identity, minimum_state_seq) = match (*context).parse() {
        Ok(value) => value,
        Err(code) => return code,
    };
    if let Err(code) = validate_scrollbar(&*out_scrollbar) {
        return code;
    }
    let state = lock_client!(client);
    if let Err(code) = validate_active_projection(&state, &identity, minimum_state_seq) {
        return code;
    }
    let scrollbar = match state.active.try_terminal() {
        Ok(terminal) => match terminal.scrollbar() {
            Ok(value) => value,
            Err(error) => return map_engine(error),
        },
        Err(error) => return map_engine(error),
    };
    (*out_scrollbar).observed_state_seq = state.active_state_seq;
    (*out_scrollbar).total = scrollbar.total;
    (*out_scrollbar).offset = scrollbar.offset;
    (*out_scrollbar).length = scrollbar.length;
    ResultCode::Ok
}

#[no_mangle]
pub unsafe extern "C" fn ouro_render_client_force_full_frame(
    client: *mut OuroRenderClient,
) -> ResultCode {
    let mut state = lock_client!(client);
    if state.active_poisoned {
        return ResultCode::ResyncRequired;
    }
    match state.active.force_full() {
        Ok(()) => ResultCode::Ok,
        Err(e) => map_engine(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn identity(generation: u64, id: &str) -> StreamIdentity {
        let mut value = StreamIdentity {
            size: size_of::<StreamIdentity>(),
            abi_version: RENDER_CLIENT_ABI_VERSION,
            broker_generation: generation,
            terminal_id_length: id.len(),
            terminal_id: [0; TERMINAL_ID_MAX],
        };
        value.terminal_id[..id.len()].copy_from_slice(id.as_bytes());
        value
    }
    fn config() -> ClientConfig {
        ClientConfig {
            size: size_of::<ClientConfig>(),
            abi_version: RENDER_CLIENT_ABI_VERSION,
            initial_stream: identity(1, "one"),
            columns: 16,
            rows: 4,
            cell_width_px: 8,
            cell_height_px: 16,
            scrollback_max_bytes: 1024 * 1024,
            scrollback_max_lines: 1000,
            snapshot_max_bytes: 4 * 1024 * 1024,
            engine_memory_max_bytes: 16 * 1024 * 1024,
            projection_memory_max_bytes: 4 * 1024 * 1024,
            shared_page_budget_max_bytes: 128 * 1024 * 1024,
            max_grapheme_bytes: 256,
            max_feed_bytes: 64 * 1024,
            cpu_cache_max_bytes: 4 * 1024 * 1024,
            initial_state_seq: 10,
        }
    }
    unsafe fn client() -> *mut OuroRenderClient {
        let cfg = config();
        let mut out = ptr::null_mut();
        assert_eq!(ouro_render_client_new(&cfg, &mut out), ResultCode::Ok);
        out
    }
    fn checkpoint(content: &[u8]) -> Vec<u8> {
        let cfg = config();
        let mut terminal = Terminal::new(Config {
            columns: cfg.columns,
            rows: cfg.rows,
            cell_width_px: cfg.cell_width_px,
            cell_height_px: cfg.cell_height_px,
            scrollback_max_bytes: cfg.scrollback_max_bytes,
            scrollback_max_lines: cfg.scrollback_max_lines,
            kitty_image_max_bytes: 0,
            apc_max_bytes: 1024 * 1024,
            continuation_max_bytes: 64 * 1024,
            snapshot_max_bytes: cfg.snapshot_max_bytes,
            engine_memory_max_bytes: cfg.engine_memory_max_bytes,
        })
        .unwrap();
        terminal.feed(content).unwrap();
        terminal.snapshot().unwrap()
    }
    fn terminal_config(cfg: &ClientConfig, engine_memory_max_bytes: usize) -> Config {
        Config {
            columns: cfg.columns,
            rows: cfg.rows,
            cell_width_px: cfg.cell_width_px,
            cell_height_px: cfg.cell_height_px,
            scrollback_max_bytes: cfg.scrollback_max_bytes,
            scrollback_max_lines: cfg.scrollback_max_lines,
            kitty_image_max_bytes: 0,
            apc_max_bytes: 1024 * 1024,
            continuation_max_bytes: 64 * 1024,
            snapshot_max_bytes: cfg.snapshot_max_bytes,
            engine_memory_max_bytes,
        }
    }
    fn feed_oom_config() -> ClientConfig {
        let mut cfg = config();
        let mut low = 1usize;
        let mut high = cfg.engine_memory_max_bytes;
        while low < high {
            let middle = low + (high - low) / 2;
            let page_budget = PageBudget::new(cfg.shared_page_budget_max_bytes).unwrap();
            if Terminal::new_with_page_budget(terminal_config(&cfg, middle), &page_budget).is_ok() {
                high = middle;
            } else {
                low = middle + 1;
            }
        }
        cfg.engine_memory_max_bytes = low;
        cfg
    }
    fn allocation_requiring_feed() -> &'static [u8] {
        b"\x1b]8;id=feed-oom;https://example.com/feed-oom\x1b\\linked-\xed\x95\x9c\xea\xb5\xad-\xf0\x9f\x8c\x8a\x1b]8;;\x1b\\\r\n"
    }
    unsafe fn frame(client: *mut OuroRenderClient) -> BulkFrame {
        let mut out: BulkFrame = std::mem::zeroed();
        out.size = size_of::<BulkFrame>();
        out.abi_version = RENDER_CLIENT_ABI_VERSION;
        assert_eq!(
            ouro_render_client_acquire_frame(client, &mut out),
            ResultCode::Ok
        );
        out
    }
    unsafe fn memory(client: *mut OuroRenderClient) -> ClientMemoryInfo {
        let mut out: ClientMemoryInfo = std::mem::zeroed();
        out.size = size_of::<ClientMemoryInfo>();
        out.abi_version = RENDER_CLIENT_ABI_VERSION;
        assert_eq!(
            ouro_render_client_memory_info(client, &mut out),
            ResultCode::Ok
        );
        out
    }
    fn projection_context(stream: StreamIdentity, minimum_state_seq: u64) -> ProjectionContext {
        ProjectionContext {
            size: size_of::<ProjectionContext>(),
            abi_version: RENDER_CLIENT_ABI_VERSION,
            stream,
            minimum_state_seq,
        }
    }
    fn selection_point(column: u16, row: u32, x: f64, y: f64) -> ClientSelectionPoint {
        ClientSelectionPoint {
            size: size_of::<ClientSelectionPoint>(),
            abi_version: RENDER_CLIENT_ABI_VERSION,
            column,
            row,
            surface_x: x,
            surface_y: y,
            has_time: 0,
            time_ns: 0,
        }
    }
    fn selection_geometry(columns: u32) -> ClientSelectionGeometry {
        ClientSelectionGeometry {
            size: size_of::<ClientSelectionGeometry>(),
            abi_version: RENDER_CLIENT_ABI_VERSION,
            columns,
            cell_width: 8.0,
            padding_left: 0.0,
            screen_height: 64.0,
        }
    }
    fn selection_outcome() -> ClientSelectionOutcome {
        ClientSelectionOutcome {
            size: size_of::<ClientSelectionOutcome>(),
            abi_version: RENDER_CLIENT_ABI_VERSION,
            observed_state_seq: 0,
            selection_has_value: 0,
            autoscroll_direction: -1,
        }
    }
    fn viewport_scroll(
        kind: ClientViewportScrollKind,
        delta: i64,
        row: u64,
    ) -> ClientViewportScroll {
        ClientViewportScroll {
            size: size_of::<ClientViewportScroll>(),
            abi_version: RENDER_CLIENT_ABI_VERSION,
            kind: kind as i32,
            delta,
            row,
        }
    }
    fn scrollbar_out() -> ClientScrollbar {
        ClientScrollbar {
            size: size_of::<ClientScrollbar>(),
            abi_version: RENDER_CLIENT_ABI_VERSION,
            observed_state_seq: 0,
            total: 0,
            offset: 0,
            length: 0,
        }
    }
    fn projection_rebind_failure_budget() -> usize {
        let cfg = config();
        let terminal_config = Config {
            columns: cfg.columns,
            rows: cfg.rows,
            cell_width_px: cfg.cell_width_px,
            cell_height_px: cfg.cell_height_px,
            scrollback_max_bytes: cfg.scrollback_max_bytes,
            scrollback_max_lines: cfg.scrollback_max_lines,
            kitty_image_max_bytes: 0,
            apc_max_bytes: 1024 * 1024,
            continuation_max_bytes: 64 * 1024,
            snapshot_max_bytes: cfg.snapshot_max_bytes,
            engine_memory_max_bytes: cfg.engine_memory_max_bytes,
        };
        let mut terminal = Terminal::new(terminal_config).unwrap();
        terminal.feed(b"old").unwrap();
        let mut projection = match terminal.try_into_owned_render() {
            Ok(value) => value,
            Err((error, _)) => panic!("probe projection: {error:?}"),
        };
        let floor = projection.memory_info().unwrap().live_bytes;
        projection.begin_frame().unwrap();
        let mut scratch = Vec::new();
        while projection.next_row().unwrap().is_some() {
            while projection.next_cell_into(&mut scratch).unwrap().is_some() {}
        }
        projection.commit_cpu_cache().unwrap();
        projection.memory_info().unwrap().live_bytes + floor - 1
    }

    #[test]
    fn manifest_and_c_header_contract() {
        let value = manifest_value();
        assert!(manifest_equal(&value));
        assert_eq!(value.terminal_engine_abi_version, 6);
        assert_eq!(
            &value.ghostty_source_commit[..40],
            GHOSTTY_SOURCE_COMMIT.as_bytes()
        );
        assert_eq!(size_of::<StreamIdentity>(), 160);
        assert_eq!(std::mem::offset_of!(StreamIdentity, terminal_id), 32);
        assert_eq!(size_of::<ClientManifest>(), 152);
        assert_eq!(size_of::<ClientConfig>(), 272);
        assert_eq!(std::mem::offset_of!(ClientConfig, initial_stream), 16);
        assert_eq!(std::mem::offset_of!(ClientConfig, initial_state_seq), 264);
        assert_eq!(size_of::<ClientRow>(), 40);
        assert_eq!(size_of::<ClientCell>(), 64);
        assert_eq!(std::mem::offset_of!(ClientCell, grapheme_offset), 8);
        assert_eq!(std::mem::offset_of!(ClientCell, underline), 56);
        assert_eq!(size_of::<ClientUnderline>(), 4);
        assert_eq!(ClientUnderline::None as i32, 0);
        assert_eq!(ClientUnderline::Single as i32, 1);
        assert_eq!(ClientUnderline::Double as i32, 2);
        assert_eq!(ClientUnderline::Curly as i32, 3);
        assert_eq!(ClientUnderline::Dotted as i32, 4);
        assert_eq!(ClientUnderline::Dashed as i32, 5);
        assert_eq!(ClientUnderline::parse(-1), Err(ResultCode::Engine));
        assert_eq!(ClientUnderline::parse(6), Err(ResultCode::Engine));
        assert_eq!(size_of::<BulkFrame>(), 864);
        assert_eq!(std::mem::offset_of!(BulkFrame, palette), 90);
        assert_eq!(size_of::<ClientMemoryInfo>(), 192);
        assert_eq!(size_of::<ProjectionContext>(), 184);
        assert_eq!(std::mem::offset_of!(ProjectionContext, stream), 16);
        assert_eq!(
            std::mem::offset_of!(ProjectionContext, minimum_state_seq),
            176
        );
        assert_eq!(size_of::<ClientSelectionPoint>(), 56);
        assert_eq!(std::mem::offset_of!(ClientSelectionPoint, row), 16);
        assert_eq!(std::mem::offset_of!(ClientSelectionPoint, time_ns), 48);
        assert_eq!(size_of::<ClientSelectionGeometry>(), 40);
        assert_eq!(
            std::mem::offset_of!(ClientSelectionGeometry, cell_width),
            16
        );
        assert_eq!(size_of::<ClientSelectionOutcome>(), 32);
        assert_eq!(
            std::mem::offset_of!(ClientSelectionOutcome, observed_state_seq),
            16
        );
        assert_eq!(
            std::mem::offset_of!(ClientSelectionOutcome, autoscroll_direction),
            28
        );
        assert_eq!(selection_config().copy_max_bytes, 1024 * 1024);
        assert_eq!(size_of::<ClientViewportScrollKind>(), 4);
        assert_eq!(ClientViewportScrollKind::Top as i32, 0);
        assert_eq!(ClientViewportScrollKind::Bottom as i32, 1);
        assert_eq!(ClientViewportScrollKind::Delta as i32, 2);
        assert_eq!(ClientViewportScrollKind::Row as i32, 3);
        assert_eq!(size_of::<ClientViewportScroll>(), 32);
        assert_eq!(std::mem::offset_of!(ClientViewportScroll, delta), 16);
        assert_eq!(size_of::<ClientScrollbar>(), 48);
        assert_eq!(
            std::mem::offset_of!(ClientScrollbar, observed_state_seq),
            16
        );
        assert_eq!(std::mem::offset_of!(ClientScrollbar, length), 40);
    }

    #[test]
    fn active_hyperlinks_and_bells_are_identity_scoped_lease_safe_and_drained() {
        unsafe {
            let c = client();
            let one = identity(1, "one");
            let payload = b"\x07\x07\x1b]8;;https://example.com/turn\x1b\\linked\x1b]8;;\x1b\\";
            assert_eq!(
                ouro_render_client_active_feed(c, &one, 11, payload.as_ptr(), payload.len()),
                ResultCode::Ok
            );
            let context = projection_context(one, 11);

            let mut required = usize::MAX;
            assert_eq!(
                ouro_render_client_active_hyperlink_uri(
                    c,
                    &context,
                    0,
                    0,
                    ptr::null_mut(),
                    0,
                    &mut required,
                ),
                ResultCode::BufferTooSmall
            );
            assert_eq!(required, b"https://example.com/turn".len());
            let mut uri = vec![0; required];
            assert_eq!(
                ouro_render_client_active_hyperlink_uri(
                    c,
                    &context,
                    0,
                    0,
                    uri.as_mut_ptr(),
                    uri.len(),
                    &mut required,
                ),
                ResultCode::Ok
            );
            assert_eq!(uri, b"https://example.com/turn");
            assert_eq!(
                ouro_render_client_active_hyperlink_uri(
                    c,
                    &context,
                    u16::MAX,
                    u32::MAX,
                    ptr::null_mut(),
                    0,
                    &mut required,
                ),
                ResultCode::InvalidArgument
            );

            let stale = projection_context(identity(1, "other"), 11);
            assert_eq!(
                ouro_render_client_active_hyperlink_uri(
                    c,
                    &stale,
                    0,
                    0,
                    ptr::null_mut(),
                    0,
                    &mut required,
                ),
                ResultCode::StaleStream
            );
            let future = projection_context(one, 12);
            let mut bell_count = u32::MAX;
            assert_eq!(
                ouro_render_client_active_take_bells(c, &future, &mut bell_count),
                ResultCode::StateSeqGap
            );
            assert_eq!(bell_count, 0);

            let leased = frame(c);
            assert_eq!(
                ouro_render_client_active_hyperlink_uri(
                    c,
                    &context,
                    0,
                    0,
                    ptr::null_mut(),
                    0,
                    &mut required,
                ),
                ResultCode::Busy
            );
            assert_eq!(
                ouro_render_client_active_take_bells(c, &context, &mut bell_count),
                ResultCode::Ok
            );
            assert_eq!(bell_count, 2);
            assert_eq!(
                ouro_render_client_finish_frame_lease(c, leased.generation, 0),
                ResultCode::Ok
            );

            assert_eq!(
                ouro_render_client_active_take_bells(c, &context, &mut bell_count),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_active_take_bells(c, &context, &mut bell_count),
                ResultCode::Ok
            );
            assert_eq!(bell_count, 0);

            // Candidate feeds replay historical terminal bytes. Their BELs
            // must be cleared at cutover instead of notifying as live events.
            let target = identity(2, "two");
            let snapshot = checkpoint(b"");
            let manifest = manifest_value();
            let mut token = 0;
            assert_eq!(
                ouro_render_client_candidate_begin(c, &target, 20, &mut token),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_candidate_import_checkpoint(
                    c,
                    token,
                    &manifest,
                    20,
                    snapshot.as_ptr(),
                    snapshot.len(),
                ),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_candidate_feed(c, token, 21, b"\x07\x07".as_ptr(), 2),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_candidate_commit(c, token, 21),
                ResultCode::Ok
            );
            let target_context = projection_context(target, 21);
            bell_count = u32::MAX;
            assert_eq!(
                ouro_render_client_active_take_bells(c, &target_context, &mut bell_count),
                ResultCode::Ok
            );
            assert_eq!(bell_count, 0);
            ouro_render_client_free(c);
        }
    }

    #[test]
    fn active_metadata_is_epoch_scoped_bounded_and_lease_safe() {
        unsafe {
            let c = client();
            let one = identity(1, "one");
            let payload = b"\x1b]0;Build Agent\x07\x1b]7;file://localhost/private/tmp\x07";
            assert_eq!(
                ouro_render_client_active_feed(c, &one, 11, payload.as_ptr(), payload.len()),
                ResultCode::Ok
            );
            let context = projection_context(one, 11);
            let mut epoch = 0;
            assert_eq!(
                ouro_render_client_active_metadata_epoch(c, &context, &mut epoch),
                ResultCode::Ok
            );
            assert!(epoch > 0);

            let mut required = 0;
            assert_eq!(
                ouro_render_client_active_copy_metadata(
                    c,
                    &context,
                    1,
                    ptr::null_mut(),
                    0,
                    &mut required
                ),
                ResultCode::BufferTooSmall
            );
            let mut title = vec![0; required];
            assert_eq!(
                ouro_render_client_active_copy_metadata(
                    c,
                    &context,
                    1,
                    title.as_mut_ptr(),
                    title.len(),
                    &mut required
                ),
                ResultCode::Ok
            );
            assert_eq!(title, b"Build Agent");

            required = 0;
            assert_eq!(
                ouro_render_client_active_copy_metadata(
                    c,
                    &context,
                    2,
                    ptr::null_mut(),
                    0,
                    &mut required
                ),
                ResultCode::BufferTooSmall
            );
            let mut pwd = vec![0; required];
            assert_eq!(
                ouro_render_client_active_copy_metadata(
                    c,
                    &context,
                    2,
                    pwd.as_mut_ptr(),
                    pwd.len(),
                    &mut required
                ),
                ResultCode::Ok
            );
            assert_eq!(pwd, b"file://localhost/private/tmp");

            let leased = frame(c);
            let mut leased_epoch = 0;
            assert_eq!(
                ouro_render_client_active_metadata_epoch(c, &context, &mut leased_epoch),
                ResultCode::Ok
            );
            assert_eq!(leased_epoch, epoch);
            required = 0;
            assert_eq!(
                ouro_render_client_active_copy_metadata(
                    c,
                    &context,
                    1,
                    ptr::null_mut(),
                    0,
                    &mut required
                ),
                ResultCode::BufferTooSmall
            );
            assert_eq!(required, b"Build Agent".len());
            assert_eq!(
                ouro_render_client_finish_frame_lease(c, leased.generation, 0),
                ResultCode::Ok
            );

            let stale = projection_context(identity(1, "stale"), 11);
            assert_eq!(
                ouro_render_client_active_metadata_epoch(c, &stale, &mut epoch),
                ResultCode::StaleStream
            );
            ouro_render_client_free(c);
        }
    }

    #[test]
    fn active_selection_is_identity_scoped_forces_full_and_copies_two_pass() {
        unsafe {
            let c = client();
            let one = identity(1, "one");
            assert_eq!(
                ouro_render_client_active_feed(
                    c,
                    &one,
                    11,
                    b"hello world\r\nsecond".as_ptr(),
                    b"hello world\r\nsecond".len(),
                ),
                ResultCode::Ok
            );
            let initial = frame(c);
            assert_eq!(
                ouro_render_client_finish_frame_lease(c, initial.generation, 0),
                ResultCode::Ok
            );

            let context = projection_context(one, 11);
            let start = selection_point(0, 0, 2.0, 8.0);
            let end = selection_point(4, 0, 38.0, 8.0);
            let geometry = selection_geometry(16);
            let mut outcome = selection_outcome();
            assert_eq!(
                ouro_render_client_active_selection_begin(c, &context, &start, &mut outcome),
                ResultCode::Ok
            );
            assert_eq!(outcome.observed_state_seq, 11);
            assert_eq!(outcome.selection_has_value, 0);
            assert_eq!(outcome.autoscroll_direction, 0);
            assert_eq!(
                ouro_render_client_active_selection_update(
                    c,
                    &context,
                    &end,
                    &geometry,
                    0,
                    &mut outcome,
                ),
                ResultCode::Ok
            );
            assert_eq!(outcome.selection_has_value, 1);
            assert_eq!(
                ouro_render_client_active_selection_autoscroll(
                    c,
                    &context,
                    4,
                    0,
                    38.0,
                    8.0,
                    &geometry,
                    0,
                    &mut outcome,
                ),
                ResultCode::Ok
            );
            assert_eq!(outcome.autoscroll_direction, 0);

            let selected = frame(c);
            assert_eq!(selected.dirty, 2, "selection mutation must force FULL");
            let mut query = selected;
            assert_eq!(
                ouro_render_client_copy_frame_bulk(
                    c,
                    selected.generation,
                    ptr::null_mut(),
                    0,
                    ptr::null_mut(),
                    0,
                    ptr::null_mut(),
                    0,
                    &mut query,
                ),
                ResultCode::BufferTooSmall
            );
            let mut rows = vec![ClientRow::default(); query.row_count];
            let mut cells = vec![ClientCell::default(); query.cell_count];
            let mut graphemes = vec![0; query.grapheme_bytes];
            assert_eq!(
                ouro_render_client_copy_frame_bulk(
                    c,
                    selected.generation,
                    rows.as_mut_ptr(),
                    rows.len(),
                    cells.as_mut_ptr(),
                    cells.len(),
                    graphemes.as_mut_ptr(),
                    graphemes.len(),
                    &mut query,
                ),
                ResultCode::Ok
            );
            assert!(cells.iter().any(|cell| { cell.flags & (1 << 0) != 0 }));

            // Mutating while the exact CPU frame is leased would invalidate
            // its selection payload. Read-only copy remains allowed.
            assert_eq!(
                ouro_render_client_active_selection_end(c, &context, &end, &mut outcome),
                ResultCode::Busy
            );
            let mut required = usize::MAX;
            assert_eq!(
                ouro_render_client_active_selection_copy(
                    c,
                    &context,
                    ptr::null_mut(),
                    0,
                    &mut required,
                ),
                ResultCode::BufferTooSmall
            );
            assert_eq!(required, 5);
            let mut short = [0u8; 4];
            assert_eq!(
                ouro_render_client_active_selection_copy(
                    c,
                    &context,
                    short.as_mut_ptr(),
                    short.len(),
                    &mut required,
                ),
                ResultCode::BufferTooSmall
            );
            assert_eq!(required, 5);
            let mut copied = [0u8; 5];
            assert_eq!(
                ouro_render_client_active_selection_copy(
                    c,
                    &context,
                    copied.as_mut_ptr(),
                    copied.len(),
                    &mut required,
                ),
                ResultCode::Ok
            );
            assert_eq!(required, 5);
            assert_eq!(&copied, b"hello");
            assert_eq!(
                ouro_render_client_finish_frame_lease(c, selected.generation, 0),
                ResultCode::Ok
            );

            assert_eq!(
                ouro_render_client_active_selection_end(c, &context, ptr::null(), &mut outcome,),
                ResultCode::Ok
            );
            assert_eq!(outcome.selection_has_value, 0);
            assert_eq!(
                ouro_render_client_active_selection_cancel(c, &context, &mut outcome),
                ResultCode::Ok
            );
            required = usize::MAX;
            assert_eq!(
                ouro_render_client_active_selection_copy(
                    c,
                    &context,
                    ptr::null_mut(),
                    0,
                    &mut required,
                ),
                ResultCode::NoValue
            );
            assert_eq!(required, 0);
            ouro_render_client_free(c);
        }
    }

    #[test]
    fn selection_rejects_stale_or_not_ready_projection_without_candidate_mutation() {
        unsafe {
            let c = client();
            let one = identity(1, "one");
            assert_eq!(
                ouro_render_client_active_feed(c, &one, 11, b"active".as_ptr(), 6),
                ResultCode::Ok
            );
            let target = identity(2, "two");
            let snapshot = checkpoint(b"candidate-only");
            let manifest = manifest_value();
            let mut token = 0;
            assert_eq!(
                ouro_render_client_candidate_begin(c, &target, 20, &mut token),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_candidate_import_checkpoint(
                    c,
                    token,
                    &manifest,
                    20,
                    snapshot.as_ptr(),
                    snapshot.len(),
                ),
                ResultCode::Ok
            );
            let candidate_before = {
                let mut state = (*c).state.lock().unwrap();
                match &mut state.candidate.as_mut().unwrap().phase {
                    CandidatePhase::Ready {
                        terminal,
                        state_seq,
                    } => {
                        assert_eq!(*state_seq, 20);
                        terminal.snapshot().unwrap()
                    }
                    _ => panic!("candidate not ready"),
                }
            };

            let point = selection_point(0, 0, 0.0, 0.0);
            let mut outcome = selection_outcome();
            let stale = projection_context(identity(1, "other"), 11);
            assert_eq!(
                ouro_render_client_active_selection_begin(c, &stale, &point, &mut outcome),
                ResultCode::StaleStream
            );
            let not_ready = projection_context(one, 12);
            assert_eq!(
                ouro_render_client_active_selection_begin(c, &not_ready, &point, &mut outcome),
                ResultCode::StateSeqGap
            );
            let mut bad_context = projection_context(one, 11);
            bad_context.size -= 1;
            assert_eq!(
                ouro_render_client_active_selection_begin(c, &bad_context, &point, &mut outcome,),
                ResultCode::InvalidArgument
            );
            let context = projection_context(one, 11);
            let mut bad_point = point;
            bad_point.has_time = 2;
            assert_eq!(
                ouro_render_client_active_selection_begin(c, &context, &bad_point, &mut outcome,),
                ResultCode::InvalidArgument
            );
            let mut bad_outcome = selection_outcome();
            bad_outcome.size -= 1;
            assert_eq!(
                ouro_render_client_active_selection_begin(c, &context, &point, &mut bad_outcome,),
                ResultCode::InvalidArgument
            );
            assert_eq!(
                ouro_render_client_active_selection_begin(c, &context, &point, &mut outcome),
                ResultCode::Ok
            );

            let candidate_after = {
                let mut state = (*c).state.lock().unwrap();
                match &mut state.candidate.as_mut().unwrap().phase {
                    CandidatePhase::Ready {
                        terminal,
                        state_seq,
                    } => {
                        assert_eq!(*state_seq, 20);
                        terminal.snapshot().unwrap()
                    }
                    _ => panic!("candidate not ready"),
                }
            };
            assert_eq!(candidate_after, candidate_before);
            assert_eq!(ouro_render_client_candidate_abort(c, token), ResultCode::Ok);
            ouro_render_client_free(c);
        }
    }

    #[test]
    fn active_viewport_scroll_is_bounded_identity_scoped_and_forces_full() {
        unsafe {
            let c = client();
            let one = identity(1, "one");
            let history = (0..24)
                .map(|line| format!("history-{line:02}\r\n"))
                .collect::<String>();
            assert_eq!(
                ouro_render_client_active_feed(c, &one, 11, history.as_ptr(), history.len()),
                ResultCode::Ok
            );
            let initial = frame(c);
            assert_eq!(
                ouro_render_client_finish_frame_lease(c, initial.generation, 0),
                ResultCode::Ok
            );
            let context = projection_context(one, 11);
            let mut scrollbar = scrollbar_out();
            assert_eq!(
                ouro_render_client_active_scrollbar(c, &context, &mut scrollbar),
                ResultCode::Ok
            );
            assert_eq!(scrollbar.observed_state_seq, 11);
            assert_eq!(scrollbar.length, 4);
            assert!(scrollbar.total > scrollbar.length);
            assert_eq!(scrollbar.offset, scrollbar.total - scrollbar.length);

            let top = viewport_scroll(ClientViewportScrollKind::Top, 0, 0);
            assert_eq!(
                ouro_render_client_active_viewport_scroll(c, &context, &top),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_active_scrollbar(c, &context, &mut scrollbar),
                ResultCode::Ok
            );
            assert_eq!(scrollbar.offset, 0);
            let top_frame = frame(c);
            assert_eq!(top_frame.dirty, 2, "viewport mutation must force FULL");

            let bottom = viewport_scroll(ClientViewportScrollKind::Bottom, 0, 0);
            assert_eq!(
                ouro_render_client_active_viewport_scroll(c, &context, &bottom),
                ResultCode::Busy
            );
            assert_eq!(
                ouro_render_client_active_scrollbar(c, &context, &mut scrollbar),
                ResultCode::Ok
            );
            assert_eq!(scrollbar.offset, 0, "BUSY scroll must not mutate viewport");
            assert_eq!(
                ouro_render_client_finish_frame_lease(c, top_frame.generation, 0),
                ResultCode::Ok
            );

            let delta = viewport_scroll(ClientViewportScrollKind::Delta, 2, 0);
            assert_eq!(
                ouro_render_client_active_viewport_scroll(c, &context, &delta),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_active_scrollbar(c, &context, &mut scrollbar),
                ResultCode::Ok
            );
            assert_eq!(scrollbar.offset, 2);
            let row = viewport_scroll(ClientViewportScrollKind::Row, 0, u64::MAX);
            assert_eq!(
                ouro_render_client_active_viewport_scroll(c, &context, &row),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_active_scrollbar(c, &context, &mut scrollbar),
                ResultCode::Ok
            );
            assert_eq!(scrollbar.offset, scrollbar.total - scrollbar.length);

            let stale_context = projection_context(identity(1, "stale"), 11);
            assert_eq!(
                ouro_render_client_active_viewport_scroll(c, &stale_context, &top),
                ResultCode::StaleStream
            );
            let not_ready_context = projection_context(one, 12);
            assert_eq!(
                ouro_render_client_active_scrollbar(c, &not_ready_context, &mut scrollbar),
                ResultCode::StateSeqGap
            );
            let invalid = viewport_scroll(ClientViewportScrollKind::Top, 1, 0);
            assert_eq!(
                ouro_render_client_active_viewport_scroll(c, &context, &invalid),
                ResultCode::InvalidArgument
            );
            let mut bad_out = scrollbar_out();
            bad_out.size -= 1;
            assert_eq!(
                ouro_render_client_active_scrollbar(c, &context, &mut bad_out),
                ResultCode::InvalidArgument
            );
            ouro_render_client_free(c);
        }
    }
    #[test]
    fn stale_stream_seq_gap_and_stale_candidate_token() {
        unsafe {
            let c = client();
            let one = identity(1, "one");
            let stale = identity(1, "old");
            assert_eq!(
                ouro_render_client_active_feed(c, &stale, 11, b"x".as_ptr(), 1),
                ResultCode::StaleStream
            );
            assert_eq!(
                ouro_render_client_active_feed(c, &one, 12, b"x".as_ptr(), 1),
                ResultCode::StateSeqGap
            );
            let target = identity(2, "two");
            let mut token = 0;
            assert_eq!(
                ouro_render_client_candidate_begin(c, &target, 3, &mut token),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_candidate_feed(c, token + 1, 4, b"x".as_ptr(), 1),
                ResultCode::StaleCandidate
            );
            assert_eq!(
                ouro_render_client_candidate_feed(c, token, 4, b"x".as_ptr(), 1),
                ResultCode::Busy
            );
            assert_eq!(
                ouro_render_client_candidate_commit(c, token, 4),
                ResultCode::Busy
            );
            assert_eq!(ouro_render_client_candidate_abort(c, token), ResultCode::Ok);
            ouro_render_client_free(c);
        }
    }
    #[test]
    fn candidate_is_headless_counted_and_expected_seq_commit_switches_identity() {
        unsafe {
            let c = client();
            let target = identity(2, "two");
            let mut token = 0;
            assert_eq!(
                ouro_render_client_candidate_begin(c, &target, 3, &mut token),
                ResultCode::Ok
            );
            let mut m: ClientMemoryInfo = std::mem::zeroed();
            m.size = size_of::<ClientMemoryInfo>();
            m.abi_version = 1;
            assert_eq!(ouro_render_client_memory_info(c, &mut m), ResultCode::Ok);
            assert_eq!(
                (
                    m.active_terminal_count,
                    m.candidate_terminal_count,
                    m.projection_count
                ),
                (1, 0, 1)
            );
            let snapshot = checkpoint(b"checkpoint");
            let manifest = manifest_value();
            assert_eq!(
                ouro_render_client_candidate_import_checkpoint(
                    c,
                    token,
                    &manifest,
                    3,
                    snapshot.as_ptr(),
                    snapshot.len()
                ),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_candidate_import_checkpoint(
                    c,
                    token,
                    &manifest,
                    3,
                    snapshot.as_ptr(),
                    snapshot.len()
                ),
                ResultCode::Busy
            );
            assert_eq!(
                ouro_render_client_candidate_feed(c, token, 4, b"new".as_ptr(), 3),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_candidate_import_checkpoint(
                    c,
                    token,
                    &manifest,
                    3,
                    snapshot.as_ptr(),
                    snapshot.len()
                ),
                ResultCode::Busy
            );
            (*c).state.lock().unwrap().active_poisoned = true;
            assert_eq!(
                ouro_render_client_candidate_commit(c, token, 4),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_active_feed(c, &identity(1, "one"), 11, b"late".as_ptr(), 4),
                ResultCode::StaleStream
            );
            assert_eq!(
                ouro_render_client_active_feed(c, &target, 5, b"ok".as_ptr(), 2),
                ResultCode::Ok
            );
            ouro_render_client_free(c);
        }
    }
    #[test]
    fn lease_allows_mutation_retry_bulk_and_blocks_commit() {
        unsafe {
            let c = client();
            let one = identity(1, "one");
            assert_eq!(
                ouro_render_client_active_feed(
                    c,
                    &one,
                    11,
                    "hello 界".as_bytes().as_ptr(),
                    "hello 界".len()
                ),
                ResultCode::Ok
            );
            let first = frame(c);
            assert_eq!(
                ouro_render_client_active_feed(c, &one, 12, b" later".as_ptr(), 6),
                ResultCode::Ok
            );
            let target = identity(2, "two");
            let mut token = 0;
            assert_eq!(
                ouro_render_client_candidate_begin(c, &target, 1, &mut token),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_candidate_commit(c, token, 1),
                ResultCode::Busy
            );
            let mut query: BulkFrame = std::mem::zeroed();
            query.size = size_of::<BulkFrame>();
            query.abi_version = 1;
            assert_eq!(
                ouro_render_client_copy_frame_bulk(
                    c,
                    first.generation,
                    ptr::null_mut(),
                    0,
                    ptr::null_mut(),
                    0,
                    ptr::null_mut(),
                    0,
                    &mut query
                ),
                ResultCode::BufferTooSmall
            );
            let mut rows = vec![ClientRow::default(); query.row_count];
            let mut cells = vec![ClientCell::default(); query.cell_count];
            let mut graphemes = vec![0; query.grapheme_bytes];
            assert_eq!(
                ouro_render_client_copy_frame_bulk(
                    c,
                    first.generation,
                    rows.as_mut_ptr(),
                    rows.len(),
                    cells.as_mut_ptr(),
                    cells.len(),
                    graphemes.as_mut_ptr(),
                    graphemes.len(),
                    &mut query
                ),
                ResultCode::Ok
            );
            assert!(cells.iter().all(|v| v
                .grapheme_offset
                .checked_add(v.grapheme_bytes)
                .is_some_and(|end| end <= graphemes.len())));
            assert_eq!(
                ouro_render_client_finish_frame_lease(c, first.generation, 1),
                ResultCode::Ok
            );
            let retry = frame(c);
            assert_eq!(retry.generation, first.generation);
            assert_eq!(retry.dirty, 2);
            let mut retry_rows = vec![ClientRow::default(); retry.row_count];
            let mut retry_cells = vec![ClientCell::default(); retry.cell_count];
            let mut retry_graphemes = vec![0; retry.grapheme_bytes];
            let mut retry_bulk = retry;
            assert_eq!(
                ouro_render_client_copy_frame_bulk(
                    c,
                    retry.generation,
                    retry_rows.as_mut_ptr(),
                    retry_rows.len(),
                    retry_cells.as_mut_ptr(),
                    retry_cells.len(),
                    retry_graphemes.as_mut_ptr(),
                    retry_graphemes.len(),
                    &mut retry_bulk
                ),
                ResultCode::Ok
            );
            assert_eq!(retry_bulk.dirty, 2);
            assert_eq!(retry_rows, rows);
            assert_eq!(retry_cells, cells);
            assert_eq!(retry_graphemes, graphemes);
            assert_eq!(
                ouro_render_client_finish_frame_lease(c, retry.generation, 0),
                ResultCode::Ok
            );
            assert_eq!(ouro_render_client_force_full_frame(c), ResultCode::Ok);
            let forced = frame(c);
            assert_eq!(forced.dirty, 2);
            assert_eq!(
                ouro_render_client_finish_frame_lease(c, forced.generation, 0),
                ResultCode::Ok
            );
            assert_eq!(ouro_render_client_candidate_abort(c, token), ResultCode::Ok);
            ouro_render_client_free(c);
        }
    }
    #[test]
    fn partial_merge_marks_only_the_changed_row_and_keeps_a_lossless_full_cache() {
        unsafe {
            let c = client();
            let one = identity(1, "one");
            let initial = b"\x1b[3;1Hbase";
            assert_eq!(
                ouro_render_client_active_feed(c, &one, 11, initial.as_ptr(), initial.len()),
                ResultCode::Ok
            );
            let full = frame(c);
            assert_eq!(full.dirty, 2);
            let mut full_rows = vec![ClientRow::default(); full.row_count];
            let mut full_cells = vec![ClientCell::default(); full.cell_count];
            let mut full_graphemes = vec![0; full.grapheme_bytes];
            let mut full_bulk = full;
            assert_eq!(
                ouro_render_client_copy_frame_bulk(
                    c,
                    full.generation,
                    full_rows.as_mut_ptr(),
                    full_rows.len(),
                    full_cells.as_mut_ptr(),
                    full_cells.len(),
                    full_graphemes.as_mut_ptr(),
                    full_graphemes.len(),
                    &mut full_bulk
                ),
                ResultCode::Ok
            );
            assert_eq!(full_rows.len(), 4);
            assert!(full_rows.iter().all(|row| row.dirty == 1));
            assert_eq!(
                ouro_render_client_finish_frame_lease(c, full.generation, 0),
                ResultCode::Ok
            );

            assert_eq!(
                ouro_render_client_active_feed(c, &one, 12, b"X".as_ptr(), 1),
                ResultCode::Ok
            );
            let partial = frame(c);
            assert_eq!(partial.dirty, 1);
            let mut rows = vec![ClientRow::default(); partial.row_count];
            let mut cells = vec![ClientCell::default(); partial.cell_count];
            let mut graphemes = vec![0; partial.grapheme_bytes];
            let mut bulk = partial;
            assert_eq!(
                ouro_render_client_copy_frame_bulk(
                    c,
                    partial.generation,
                    rows.as_mut_ptr(),
                    rows.len(),
                    cells.as_mut_ptr(),
                    cells.len(),
                    graphemes.as_mut_ptr(),
                    graphemes.len(),
                    &mut bulk
                ),
                ResultCode::Ok
            );
            assert_eq!(rows.len(), 4);
            assert_eq!(
                rows.iter()
                    .filter(|row| row.dirty == 1)
                    .map(|row| row.y)
                    .collect::<Vec<_>>(),
                vec![2]
            );
            assert!(String::from_utf8_lossy(&graphemes).contains("baseX"));
            assert!(cells.iter().all(|cell| matches!(
                cell.underline,
                ClientUnderline::None
                    | ClientUnderline::Single
                    | ClientUnderline::Double
                    | ClientUnderline::Curly
                    | ClientUnderline::Dotted
                    | ClientUnderline::Dashed
            )));
            assert_eq!(
                ouro_render_client_finish_frame_lease(c, partial.generation, 0),
                ResultCode::Ok
            );
            ouro_render_client_free(c);
        }
    }
    #[test]
    fn explicit_retry_cancel_unblocks_superseding_candidate_commit() {
        unsafe {
            let c = client();
            let one = identity(1, "one");
            assert_eq!(
                ouro_render_client_active_feed(c, &one, 11, b"old-frame".as_ptr(), 9),
                ResultCode::Ok
            );
            let old_frame = frame(c);
            assert_eq!(
                ouro_render_client_cancel_frame_retry(c),
                ResultCode::Busy,
                "an outstanding lease cannot be abandoned"
            );
            assert_eq!(
                ouro_render_client_finish_frame_lease(c, old_frame.generation, 1),
                ResultCode::Ok
            );

            let target = identity(2, "two");
            let snapshot = checkpoint(b"candidate");
            let manifest = manifest_value();
            let mut token = 0;
            assert_eq!(
                ouro_render_client_candidate_begin(c, &target, 20, &mut token),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_candidate_import_checkpoint(
                    c,
                    token,
                    &manifest,
                    20,
                    snapshot.as_ptr(),
                    snapshot.len()
                ),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_candidate_commit(c, token, 20),
                ResultCode::Busy
            );
            assert_eq!(ouro_render_client_cancel_frame_retry(c), ResultCode::Ok);
            assert_eq!(
                ouro_render_client_candidate_commit(c, token, 20),
                ResultCode::Ok
            );
            ouro_render_client_free(c);
        }
    }
    #[test]
    fn retry_survives_candidate_prepare_abort_and_commit_interleaving_byte_exactly() {
        unsafe {
            let c = client();
            let one = identity(1, "one");
            assert_eq!(
                ouro_render_client_active_feed(c, &one, 11, b"retry-source".as_ptr(), 12),
                ResultCode::Ok
            );
            let first = frame(c);
            let mut first_rows = vec![ClientRow::default(); first.row_count];
            let mut first_cells = vec![ClientCell::default(); first.cell_count];
            let mut first_graphemes = vec![0; first.grapheme_bytes];
            let mut first_bulk = first;
            assert_eq!(
                ouro_render_client_copy_frame_bulk(
                    c,
                    first.generation,
                    first_rows.as_mut_ptr(),
                    first_rows.len(),
                    first_cells.as_mut_ptr(),
                    first_cells.len(),
                    first_graphemes.as_mut_ptr(),
                    first_graphemes.len(),
                    &mut first_bulk
                ),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_finish_frame_lease(c, first.generation, 1),
                ResultCode::Ok
            );

            let target = identity(2, "two");
            let snapshot = checkpoint(b"candidate");
            let manifest = manifest_value();
            let mut aborted_token = 0;
            assert_eq!(
                ouro_render_client_candidate_begin(c, &target, 20, &mut aborted_token),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_candidate_import_checkpoint(
                    c,
                    aborted_token,
                    &manifest,
                    20,
                    snapshot.as_ptr(),
                    snapshot.len()
                ),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_candidate_commit(c, aborted_token, 20),
                ResultCode::Busy
            );
            assert_eq!(
                ouro_render_client_candidate_abort(c, aborted_token),
                ResultCode::Ok
            );

            let mut committed_token = 0;
            assert_eq!(
                ouro_render_client_candidate_begin(c, &target, 20, &mut committed_token),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_candidate_import_checkpoint(
                    c,
                    committed_token,
                    &manifest,
                    20,
                    snapshot.as_ptr(),
                    snapshot.len()
                ),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_active_feed(c, &one, 12, b"-later".as_ptr(), 6),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_candidate_commit(c, committed_token, 20),
                ResultCode::Busy
            );

            let retry = frame(c);
            let mut retry_rows = vec![ClientRow::default(); retry.row_count];
            let mut retry_cells = vec![ClientCell::default(); retry.cell_count];
            let mut retry_graphemes = vec![0; retry.grapheme_bytes];
            let mut retry_bulk = retry;
            assert_eq!(
                ouro_render_client_copy_frame_bulk(
                    c,
                    retry.generation,
                    retry_rows.as_mut_ptr(),
                    retry_rows.len(),
                    retry_cells.as_mut_ptr(),
                    retry_cells.len(),
                    retry_graphemes.as_mut_ptr(),
                    retry_graphemes.len(),
                    &mut retry_bulk
                ),
                ResultCode::Ok
            );
            assert_eq!(retry.generation, first.generation);
            assert_eq!(retry_bulk.dirty, 2);
            assert_eq!(retry_rows, first_rows);
            assert_eq!(retry_cells, first_cells);
            assert_eq!(retry_graphemes, first_graphemes);
            assert_eq!(
                ouro_render_client_finish_frame_lease(c, retry.generation, 0),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_candidate_commit(c, committed_token, 20),
                ResultCode::Ok
            );
            ouro_render_client_free(c);
        }
    }
    #[test]
    fn active_feed_oom_requires_checkpoint_resync_and_never_accepts_failed_seq() {
        unsafe {
            let cfg = feed_oom_config();
            let mut c = ptr::null_mut();
            assert_eq!(ouro_render_client_new(&cfg, &mut c), ResultCode::Ok);
            let one = identity(1, "one");
            let input = allocation_requiring_feed();
            assert_eq!(
                ouro_render_client_active_feed(c, &one, 11, input.as_ptr(), input.len()),
                ResultCode::OutOfMemory
            );
            assert_eq!(
                ouro_render_client_active_feed(c, &one, 11, ptr::null(), 0),
                ResultCode::ResyncRequired
            );
            assert_eq!(
                ouro_render_client_active_resize(c, &one, 11, 16, 4, 8, 16),
                ResultCode::ResyncRequired
            );
            let mut out: BulkFrame = std::mem::zeroed();
            out.size = size_of::<BulkFrame>();
            out.abi_version = RENDER_CLIENT_ABI_VERSION;
            assert_eq!(
                ouro_render_client_acquire_frame(c, &mut out),
                ResultCode::ResyncRequired
            );

            ouro_render_client_free(c);
        }
    }
    #[test]
    fn active_resize_marks_a_full_frame_for_new_cell_geometry() {
        unsafe {
            let c = client();
            let one = identity(1, "one");
            let initial = frame(c);
            assert_eq!(initial.dirty, 2);
            assert_eq!(
                ouro_render_client_finish_frame_lease(c, initial.generation, 0),
                ResultCode::Ok
            );

            // The terminal contents are unchanged, but a new cell size must
            // invalidate the retained renderer projection so the desktop can
            // rebuild its glyph atlas at the requested typography.
            assert_eq!(
                ouro_render_client_active_resize(c, &one, 11, 16, 4, 11, 22),
                ResultCode::Ok
            );
            let resized = frame(c);
            assert_eq!(resized.dirty, 2);
            assert_eq!(
                ouro_render_client_finish_frame_lease(c, resized.generation, 0),
                ResultCode::Ok
            );
            ouro_render_client_free(c);
        }
    }
    #[test]
    fn candidate_feed_oom_discards_terminal_and_cannot_retry_or_commit_prefix() {
        unsafe {
            let cfg = feed_oom_config();
            let mut c = ptr::null_mut();
            assert_eq!(ouro_render_client_new(&cfg, &mut c), ResultCode::Ok);
            let target = identity(2, "two");
            let mut token = 0;
            assert_eq!(
                ouro_render_client_candidate_begin(c, &target, 20, &mut token),
                ResultCode::Ok
            );
            {
                let mut state = (*c).state.lock().unwrap();
                let terminal =
                    Terminal::new_with_page_budget(state.limits.terminal, &state.page_budget)
                        .unwrap();
                let candidate = state.candidate.as_mut().unwrap();
                candidate.phase = CandidatePhase::Ready {
                    terminal,
                    state_seq: 20,
                };
            }
            let input = allocation_requiring_feed();
            assert_eq!(
                ouro_render_client_candidate_feed(c, token, 21, input.as_ptr(), input.len()),
                ResultCode::OutOfMemory
            );
            assert_eq!(memory(c).candidate_terminal_count, 0);
            assert_eq!(
                ouro_render_client_candidate_feed(c, token, 21, ptr::null(), 0),
                ResultCode::ResyncRequired
            );
            assert_eq!(
                ouro_render_client_candidate_resize(c, token, 21, 16, 4, 8, 16),
                ResultCode::ResyncRequired
            );
            assert_eq!(
                ouro_render_client_candidate_commit(c, token, 20),
                ResultCode::ResyncRequired
            );
            assert_eq!(ouro_render_client_candidate_abort(c, token), ResultCode::Ok);
            let one = identity(1, "one");
            assert_eq!(
                ouro_render_client_active_feed(c, &one, 11, ptr::null(), 0),
                ResultCode::Ok
            );
            ouro_render_client_free(c);
        }
    }
    #[test]
    fn cache_bound_force_full_failed_restore_and_rebind_preserve_cache() {
        unsafe {
            let mut cfg = config();
            cfg.cpu_cache_max_bytes = size_of::<RenderFrameInfo>() + 1;
            let mut c = ptr::null_mut();
            assert_eq!(ouro_render_client_new(&cfg, &mut c), ResultCode::Ok);
            let mut out: BulkFrame = std::mem::zeroed();
            out.size = size_of::<BulkFrame>();
            out.abi_version = 1;
            assert_eq!(
                ouro_render_client_acquire_frame(c, &mut out),
                ResultCode::LimitExceeded
            );
            assert_eq!(ouro_render_client_force_full_frame(c), ResultCode::Ok);
            ouro_render_client_free(c);
            let c = client();
            let first = frame(c);
            assert_eq!(
                ouro_render_client_finish_frame_lease(c, first.generation, 0),
                ResultCode::Ok
            );
            let target = identity(2, "two");
            let mut token = 0;
            assert_eq!(
                ouro_render_client_candidate_begin(c, &target, 1, &mut token),
                ResultCode::Ok
            );
            let manifest = manifest_value();
            assert_ne!(
                ouro_render_client_candidate_import_checkpoint(
                    c,
                    token,
                    &manifest,
                    1,
                    b"corrupt".as_ptr(),
                    7
                ),
                ResultCode::Ok
            );
            let retry = frame(c);
            assert!(retry.generation > first.generation);
            assert_eq!(
                ouro_render_client_finish_frame_lease(c, retry.generation, 0),
                ResultCode::Ok
            );
            assert_eq!(ouro_render_client_candidate_abort(c, token), ResultCode::Ok);
            ouro_render_client_free(c);
        }
    }
    #[test]
    fn shared_page_budget_denies_second_terminal_and_counts_denial() {
        let terminal_cfg = Config {
            columns: 16,
            rows: 4,
            ..Config::default()
        };
        let probe = PageBudget::new(128 * 1024 * 1024).unwrap();
        let source = Terminal::new_with_page_budget(terminal_cfg, &probe).unwrap();
        let one = probe.stats().unwrap().reserved_bytes;
        drop(source);
        let budget = PageBudget::new(one).unwrap();
        let _active = Terminal::new_with_page_budget(terminal_cfg, &budget).unwrap();
        assert!(matches!(
            Terminal::new_with_page_budget(terminal_cfg, &budget),
            Err(EngineError::OutOfMemory)
        ));
        assert!(budget.stats().unwrap().denial_count > 0);
    }
    #[test]
    fn ffi_shared_page_budget_denial_is_telemetry_visible() {
        unsafe {
            let cfg = config();
            let terminal_cfg = Config {
                columns: cfg.columns,
                rows: cfg.rows,
                ..Config::default()
            };
            let probe = PageBudget::new(128 * 1024 * 1024).unwrap();
            let source = Terminal::new_with_page_budget(terminal_cfg, &probe).unwrap();
            let one = probe.stats().unwrap().reserved_bytes;
            drop(source);
            let mut constrained = cfg;
            constrained.shared_page_budget_max_bytes = one;
            let mut c = ptr::null_mut();
            assert_eq!(ouro_render_client_new(&constrained, &mut c), ResultCode::Ok);
            let target = identity(2, "two");
            let mut token = 0;
            assert_eq!(
                ouro_render_client_candidate_begin(c, &target, 1, &mut token),
                ResultCode::Ok
            );
            let snapshot = checkpoint(b"candidate");
            let manifest = manifest_value();
            assert_eq!(
                ouro_render_client_candidate_import_checkpoint(
                    c,
                    token,
                    &manifest,
                    1,
                    snapshot.as_ptr(),
                    snapshot.len()
                ),
                ResultCode::OutOfMemory
            );
            let info = memory(c);
            assert_eq!(info.candidate_terminal_count, 0);
            assert!(info.page_denial_count > 0);
            assert_eq!(info.active_terminal_count, 1);
            assert_eq!(info.projection_count, 1);
            ouro_render_client_free(c);
        }
    }
    #[test]
    fn transactional_rebind_failure_preserves_active_stream_candidate_and_cache() {
        unsafe {
            let mut cfg = config();
            cfg.projection_memory_max_bytes = projection_rebind_failure_budget();
            let mut c = ptr::null_mut();
            assert_eq!(ouro_render_client_new(&cfg, &mut c), ResultCode::Ok);
            let one = identity(1, "one");
            assert_eq!(
                ouro_render_client_active_feed(c, &one, 11, b"old".as_ptr(), 3),
                ResultCode::Ok
            );
            let visible = frame(c);
            assert_eq!(
                ouro_render_client_finish_frame_lease(c, visible.generation, 0),
                ResultCode::Ok
            );
            let before = memory(c);
            let target = identity(2, "two");
            let mut token = 0;
            assert_eq!(
                ouro_render_client_candidate_begin(c, &target, 1, &mut token),
                ResultCode::Ok
            );
            let snapshot = checkpoint(b"candidate");
            let manifest = manifest_value();
            assert_eq!(
                ouro_render_client_candidate_import_checkpoint(
                    c,
                    token,
                    &manifest,
                    1,
                    snapshot.as_ptr(),
                    snapshot.len()
                ),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_candidate_commit(c, token, 1),
                ResultCode::OutOfMemory
            );
            let after = memory(c);
            assert_eq!(after.cpu_cache_live_bytes, before.cpu_cache_live_bytes);
            assert_eq!(after.candidate_terminal_count, 1);
            assert_eq!(after.projection_count, 1);
            assert_eq!(
                ouro_render_client_active_feed(c, &target, 2, b"late".as_ptr(), 4),
                ResultCode::StaleStream
            );
            assert_eq!(
                ouro_render_client_active_feed(c, &one, 12, b"still-old".as_ptr(), 9),
                ResultCode::Ok
            );
            assert_eq!(ouro_render_client_candidate_abort(c, token), ResultCode::Ok);
            ouro_render_client_free(c);
        }
    }
    #[test]
    fn partial_merge_cap_failure_preserves_live_cache_and_respects_peak_limit() {
        unsafe {
            let one = identity(1, "one");
            let probe = client();
            assert_eq!(
                ouro_render_client_active_feed(probe, &one, 11, b"base".as_ptr(), 4),
                ResultCode::Ok
            );
            let first = frame(probe);
            assert_eq!(
                ouro_render_client_finish_frame_lease(probe, first.generation, 0),
                ResultCode::Ok
            );
            assert_eq!(
                ouro_render_client_active_feed(probe, &one, 12, b" delta".as_ptr(), 6),
                ResultCode::Ok
            );
            let second = frame(probe);
            assert_eq!(
                ouro_render_client_finish_frame_lease(probe, second.generation, 0),
                ResultCode::Ok
            );
            let required_peak = memory(probe).cpu_cache_peak_bytes;
            ouro_render_client_free(probe);
            let mut cfg = config();
            cfg.cpu_cache_max_bytes = required_peak - 1;
            let mut c = ptr::null_mut();
            assert_eq!(ouro_render_client_new(&cfg, &mut c), ResultCode::Ok);
            assert_eq!(
                ouro_render_client_active_feed(c, &one, 11, b"base".as_ptr(), 4),
                ResultCode::Ok
            );
            let first = frame(c);
            assert_eq!(
                ouro_render_client_finish_frame_lease(c, first.generation, 0),
                ResultCode::Ok
            );
            let before = memory(c);
            assert_eq!(
                ouro_render_client_active_feed(c, &one, 12, b" delta".as_ptr(), 6),
                ResultCode::Ok
            );
            let mut out: BulkFrame = std::mem::zeroed();
            out.size = size_of::<BulkFrame>();
            out.abi_version = 1;
            assert_eq!(
                ouro_render_client_acquire_frame(c, &mut out),
                ResultCode::LimitExceeded
            );
            let after = memory(c);
            assert_eq!(after.cpu_cache_live_bytes, before.cpu_cache_live_bytes);
            assert!(after.cpu_cache_peak_bytes <= after.cpu_cache_limit_bytes);
            ouro_render_client_free(c);
        }
    }
    #[test]
    fn cache_telemetry_uses_retained_capacity_and_growth_preflights_old_plus_new() {
        unsafe {
            let c = client();
            let visible = frame(c);
            assert_eq!(
                ouro_render_client_finish_frame_lease(c, visible.generation, 0),
                ResultCode::Ok
            );
            let (retained, logical) = {
                let mut state = (*c).state.lock().unwrap();
                let cache = state.cache.as_mut().unwrap();
                cache.rows.reserve_exact(7);
                cache.cells.reserve_exact(11);
                cache.graphemes.reserve_exact(13);
                let retained = cache.retained_bytes().unwrap();
                let logical =
                    cache_bytes(cache.rows.len(), cache.cells.len(), cache.graphemes.len())
                        .unwrap();
                state.cpu_cache_peak_bytes = state.cpu_cache_peak_bytes.max(retained);
                (retained, logical)
            };
            assert!(retained > logical);
            let info = memory(c);
            assert_eq!(info.cpu_cache_live_bytes, retained);
            assert!(info.cpu_cache_peak_bytes >= info.cpu_cache_live_bytes);
            ouro_render_client_free(c);
        }

        let mut values = Vec::<u64>::new();
        values.try_reserve_exact(4).unwrap();
        let old_capacity = values.capacity();
        let live = vec_allocation_bytes::<u64>(old_capacity).unwrap();
        let requested = vec_allocation_bytes::<u64>(old_capacity + 1).unwrap();
        let mut peak = live;
        assert_eq!(
            reserve_bounded(
                &mut values,
                old_capacity + 1,
                live,
                live + requested - 1,
                &mut peak,
            ),
            Err(ResultCode::LimitExceeded)
        );
        assert_eq!(values.capacity(), old_capacity);
        assert_eq!(peak, live);
    }
    #[test]
    fn checked_arithmetic_rejects_overflow() {
        assert_eq!(cache_bytes(usize::MAX, 1, 1), None);
        assert_eq!(cache_bytes(1, usize::MAX, 1), None);
    }
}
