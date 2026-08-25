use ouro_session::split_layout::{
    FocusDirection, LeafGeometry, PresentationUpdate, ResizeCause, ResizeIntent, SplitAxis,
    SplitLayout, SplitLayoutError, SplitLimits, SplitNodeId, SplitPlacement, TerminalId,
    MAX_SPLIT_DEPTH, MAX_SPLIT_LEAVES, MAX_TERMINAL_ID_BYTES,
};
use std::mem::size_of;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::sync::{Mutex, MutexGuard};

pub const SPLIT_LAYOUT_ABI_VERSION: u32 = 1;

#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SplitLayoutResult {
    Ok = 0,
    InvalidArgument = 1,
    BufferTooSmall = 2,
    NotFound = 3,
    LimitExceeded = 4,
    Busy = 5,
    CannotCloseLastLeaf = 6,
    StaleSnapshot = 7,
    InternalError = 8,
}

#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SplitAxisValue {
    LeftRight = 0,
    TopBottom = 1,
}

#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SplitPlacementValue {
    Before = 0,
    After = 1,
}

#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SplitFocusDirectionValue {
    Left = 0,
    Right = 1,
    Up = 2,
    Down = 3,
}

#[repr(i32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SplitResizeCauseValue {
    DividerCommit = 0,
    Keyboard = 1,
    Equalize = 2,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SplitTerminalId {
    pub size: usize,
    pub abi_version: u32,
    pub length: usize,
    pub bytes: [u8; MAX_TERMINAL_ID_BYTES],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SplitLayoutConfig {
    pub size: usize,
    pub abi_version: u32,
    pub max_leaves: u32,
    pub max_depth: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SplitLayoutSnapshot {
    pub size: usize,
    pub abi_version: u32,
    pub revision: u64,
    pub leaf_count: usize,
    pub focused_terminal: SplitTerminalId,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SplitLeafGeometry {
    pub size: usize,
    pub abi_version: u32,
    pub node_id: u64,
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
    pub terminal_id: SplitTerminalId,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SplitFocusResult {
    pub size: usize,
    pub abi_version: u32,
    pub moved: u8,
    pub focused_terminal: SplitTerminalId,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SplitPresentationUpdate {
    pub size: usize,
    pub abi_version: u32,
    pub divider_node_id: u64,
    pub ratio_basis_points: u16,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SplitResizeIntent {
    pub size: usize,
    pub abi_version: u32,
    pub has_value: u8,
    pub cause: i32,
    pub layout_revision: u64,
    pub affected_count: usize,
}

/// UI-only split state. It owns no PTY, renderer, broker connection, or
/// scrollback. The mutex makes independent C calls serializable; callers must
/// still ensure `free` does not race another call.
pub struct OuroSplitLayout {
    state: Mutex<SplitLayout>,
}

fn ffi_guard(operation: impl FnOnce() -> Result<(), SplitLayoutResult>) -> SplitLayoutResult {
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(())) => SplitLayoutResult::Ok,
        Ok(Err(code)) => code,
        Err(_) => SplitLayoutResult::InternalError,
    }
}

fn map_layout_error(error: SplitLayoutError) -> SplitLayoutResult {
    match error {
        SplitLayoutError::MissingTerminal(_)
        | SplitLayoutError::MissingDivider(_)
        | SplitLayoutError::MissingBrokerTerminal(_)
        | SplitLayoutError::MissingFocusedTerminal(_) => SplitLayoutResult::NotFound,
        SplitLayoutError::LeafLimit { .. }
        | SplitLayoutError::DepthLimit { .. }
        | SplitLayoutError::NodeIdExhausted => SplitLayoutResult::LimitExceeded,
        SplitLayoutError::DragAlreadyActive
        | SplitLayoutError::DragNotActive
        | SplitLayoutError::StructureMutationDuringDrag => SplitLayoutResult::Busy,
        SplitLayoutError::CannotCloseLastLeaf => SplitLayoutResult::CannotCloseLastLeaf,
        SplitLayoutError::EmptyTerminalId
        | SplitLayoutError::TerminalIdTooLong { .. }
        | SplitLayoutError::ControlCharacterInTerminalId
        | SplitLayoutError::InvalidLimits
        | SplitLayoutError::DuplicateTerminal(_)
        | SplitLayoutError::InvalidNodeId
        | SplitLayoutError::DuplicateNodeId(_)
        | SplitLayoutError::RatioOutOfRange { .. }
        | SplitLayoutError::ZeroDragSpan
        | SplitLayoutError::UnsupportedMetadataVersion { .. } => SplitLayoutResult::InvalidArgument,
    }
}

unsafe fn input_terminal(raw: *const SplitTerminalId) -> Result<TerminalId, SplitLayoutResult> {
    let raw = raw.as_ref().ok_or(SplitLayoutResult::InvalidArgument)?;
    if raw.size < size_of::<SplitTerminalId>()
        || raw.abi_version != SPLIT_LAYOUT_ABI_VERSION
        || raw.length == 0
        || raw.length > MAX_TERMINAL_ID_BYTES
    {
        return Err(SplitLayoutResult::InvalidArgument);
    }
    let value = std::str::from_utf8(&raw.bytes[..raw.length])
        .map_err(|_| SplitLayoutResult::InvalidArgument)?;
    TerminalId::new(value.to_owned()).map_err(map_layout_error)
}

fn terminal_record(terminal: &TerminalId) -> SplitTerminalId {
    let value = terminal.as_str().as_bytes();
    let mut record = SplitTerminalId {
        size: size_of::<SplitTerminalId>(),
        abi_version: SPLIT_LAYOUT_ABI_VERSION,
        length: value.len(),
        bytes: [0; MAX_TERMINAL_ID_BYTES],
    };
    record.bytes[..value.len()].copy_from_slice(value);
    record
}

unsafe fn checked_output<'a, T>(
    output: *mut T,
    size: usize,
    abi_version: u32,
) -> Result<&'a mut T, SplitLayoutResult> {
    if output.is_null() || size < size_of::<T>() || abi_version != SPLIT_LAYOUT_ABI_VERSION {
        Err(SplitLayoutResult::InvalidArgument)
    } else {
        Ok(&mut *output)
    }
}

unsafe fn snapshot_output<'a>(
    output: *mut SplitLayoutSnapshot,
) -> Result<&'a mut SplitLayoutSnapshot, SplitLayoutResult> {
    if output.is_null() {
        return Err(SplitLayoutResult::InvalidArgument);
    }
    checked_output(output, (*output).size, (*output).abi_version)
}

unsafe fn focus_output<'a>(
    output: *mut SplitFocusResult,
) -> Result<&'a mut SplitFocusResult, SplitLayoutResult> {
    if output.is_null() {
        return Err(SplitLayoutResult::InvalidArgument);
    }
    checked_output(output, (*output).size, (*output).abi_version)
}

unsafe fn presentation_output<'a>(
    output: *mut SplitPresentationUpdate,
) -> Result<&'a mut SplitPresentationUpdate, SplitLayoutResult> {
    if output.is_null() {
        return Err(SplitLayoutResult::InvalidArgument);
    }
    checked_output(output, (*output).size, (*output).abi_version)
}

unsafe fn intent_output<'a>(
    output: *mut SplitResizeIntent,
) -> Result<&'a mut SplitResizeIntent, SplitLayoutResult> {
    if output.is_null() {
        return Err(SplitLayoutResult::InvalidArgument);
    }
    checked_output(output, (*output).size, (*output).abi_version)
}

unsafe fn layout_state<'a>(
    layout: *mut OuroSplitLayout,
) -> Result<MutexGuard<'a, SplitLayout>, SplitLayoutResult> {
    let layout = layout.as_ref().ok_or(SplitLayoutResult::InvalidArgument)?;
    layout
        .state
        .lock()
        .map_err(|_| SplitLayoutResult::InternalError)
}

fn axis(value: i32) -> Result<SplitAxis, SplitLayoutResult> {
    match value {
        value if value == SplitAxisValue::LeftRight as i32 => Ok(SplitAxis::LeftRight),
        value if value == SplitAxisValue::TopBottom as i32 => Ok(SplitAxis::TopBottom),
        _ => Err(SplitLayoutResult::InvalidArgument),
    }
}

fn placement(value: i32) -> Result<SplitPlacement, SplitLayoutResult> {
    match value {
        value if value == SplitPlacementValue::Before as i32 => Ok(SplitPlacement::Before),
        value if value == SplitPlacementValue::After as i32 => Ok(SplitPlacement::After),
        _ => Err(SplitLayoutResult::InvalidArgument),
    }
}

fn direction(value: i32) -> Result<FocusDirection, SplitLayoutResult> {
    match value {
        value if value == SplitFocusDirectionValue::Left as i32 => Ok(FocusDirection::Left),
        value if value == SplitFocusDirectionValue::Right as i32 => Ok(FocusDirection::Right),
        value if value == SplitFocusDirectionValue::Up as i32 => Ok(FocusDirection::Up),
        value if value == SplitFocusDirectionValue::Down as i32 => Ok(FocusDirection::Down),
        _ => Err(SplitLayoutResult::InvalidArgument),
    }
}

fn update_record(update: PresentationUpdate) -> SplitPresentationUpdate {
    SplitPresentationUpdate {
        size: size_of::<SplitPresentationUpdate>(),
        abi_version: SPLIT_LAYOUT_ABI_VERSION,
        divider_node_id: update.divider.get(),
        ratio_basis_points: update.ratio.basis_points(),
    }
}

fn geometry_record(geometry: LeafGeometry) -> SplitLeafGeometry {
    SplitLeafGeometry {
        size: size_of::<SplitLeafGeometry>(),
        abi_version: SPLIT_LAYOUT_ABI_VERSION,
        node_id: geometry.node_id.get(),
        x: geometry.x,
        y: geometry.y,
        width: geometry.width,
        height: geometry.height,
        terminal_id: terminal_record(&geometry.terminal_id),
    }
}

unsafe fn preflight_affected_buffer(
    leaf_count: usize,
    affected_terminals: *mut SplitTerminalId,
    affected_capacity: usize,
    output: &mut SplitResizeIntent,
    revision: u64,
) -> Result<(), SplitLayoutResult> {
    *output = SplitResizeIntent {
        size: size_of::<SplitResizeIntent>(),
        abi_version: SPLIT_LAYOUT_ABI_VERSION,
        has_value: 0,
        cause: SplitResizeCauseValue::DividerCommit as i32,
        layout_revision: revision,
        affected_count: leaf_count,
    };
    if affected_capacity < leaf_count {
        return Err(SplitLayoutResult::BufferTooSmall);
    }
    if leaf_count != 0 && affected_terminals.is_null() {
        return Err(SplitLayoutResult::InvalidArgument);
    }
    Ok(())
}

unsafe fn write_resize_intent(
    intent: Option<ResizeIntent>,
    affected_terminals: *mut SplitTerminalId,
    output: &mut SplitResizeIntent,
    unchanged_revision: u64,
) {
    let Some(intent) = intent else {
        *output = SplitResizeIntent {
            size: size_of::<SplitResizeIntent>(),
            abi_version: SPLIT_LAYOUT_ABI_VERSION,
            has_value: 0,
            cause: SplitResizeCauseValue::DividerCommit as i32,
            layout_revision: unchanged_revision,
            affected_count: 0,
        };
        return;
    };
    for (index, terminal) in intent.affected_terminals.iter().enumerate() {
        ptr::write(affected_terminals.add(index), terminal_record(terminal));
    }
    *output = SplitResizeIntent {
        size: size_of::<SplitResizeIntent>(),
        abi_version: SPLIT_LAYOUT_ABI_VERSION,
        has_value: 1,
        cause: match intent.cause {
            ResizeCause::DividerCommit => SplitResizeCauseValue::DividerCommit as i32,
            ResizeCause::Keyboard => SplitResizeCauseValue::Keyboard as i32,
            ResizeCause::Equalize => SplitResizeCauseValue::Equalize as i32,
        },
        layout_revision: intent.layout_revision,
        affected_count: intent.affected_terminals.len(),
    };
}

#[no_mangle]
pub unsafe extern "C" fn ouro_split_layout_new(
    config: *const SplitLayoutConfig,
    initial_terminal: *const SplitTerminalId,
    out_layout: *mut *mut OuroSplitLayout,
) -> SplitLayoutResult {
    ffi_guard(|| {
        let out_layout = out_layout
            .as_mut()
            .ok_or(SplitLayoutResult::InvalidArgument)?;
        *out_layout = ptr::null_mut();
        let config = config.as_ref().ok_or(SplitLayoutResult::InvalidArgument)?;
        if config.size < size_of::<SplitLayoutConfig>()
            || config.abi_version != SPLIT_LAYOUT_ABI_VERSION
            || config.max_leaves == 0
            || config.max_depth == 0
            || config.max_leaves as usize > MAX_SPLIT_LEAVES
            || config.max_depth as usize > MAX_SPLIT_DEPTH
        {
            return Err(SplitLayoutResult::InvalidArgument);
        }
        let initial = input_terminal(initial_terminal)?;
        let state = SplitLayout::new(
            initial,
            SplitLimits {
                max_leaves: config.max_leaves as usize,
                max_depth: config.max_depth as usize,
            },
        )
        .map_err(map_layout_error)?;
        *out_layout = Box::into_raw(Box::new(OuroSplitLayout {
            state: Mutex::new(state),
        }));
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn ouro_split_layout_free(layout: *mut OuroSplitLayout) {
    if layout.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(layout))));
}

#[no_mangle]
pub unsafe extern "C" fn ouro_split_layout_snapshot(
    layout: *mut OuroSplitLayout,
    out_snapshot: *mut SplitLayoutSnapshot,
) -> SplitLayoutResult {
    ffi_guard(|| {
        let output = snapshot_output(out_snapshot)?;
        let state = layout_state(layout)?;
        *output = SplitLayoutSnapshot {
            size: size_of::<SplitLayoutSnapshot>(),
            abi_version: SPLIT_LAYOUT_ABI_VERSION,
            revision: state.revision(),
            leaf_count: state.leaf_count(),
            focused_terminal: terminal_record(state.focused()),
        };
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn ouro_split_layout_copy_leaf_geometries(
    layout: *mut OuroSplitLayout,
    expected_revision: u64,
    geometries: *mut SplitLeafGeometry,
    geometry_capacity: usize,
    out_geometry_count: *mut usize,
) -> SplitLayoutResult {
    ffi_guard(|| {
        let count = out_geometry_count
            .as_mut()
            .ok_or(SplitLayoutResult::InvalidArgument)?;
        *count = 0;
        if geometry_capacity != 0 && geometries.is_null() {
            return Err(SplitLayoutResult::InvalidArgument);
        }
        let state = layout_state(layout)?;
        if state.revision() != expected_revision {
            return Err(SplitLayoutResult::StaleSnapshot);
        }
        let geometry = state.geometry();
        *count = geometry.len();
        if geometry_capacity < geometry.len() {
            return Err(SplitLayoutResult::BufferTooSmall);
        }
        if !geometry.is_empty() && geometries.is_null() {
            return Err(SplitLayoutResult::InvalidArgument);
        }
        for (index, leaf) in geometry.into_iter().enumerate() {
            ptr::write(geometries.add(index), geometry_record(leaf));
        }
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn ouro_split_layout_focus(
    layout: *mut OuroSplitLayout,
    terminal: *const SplitTerminalId,
) -> SplitLayoutResult {
    ffi_guard(|| {
        let terminal = input_terminal(terminal)?;
        layout_state(layout)?
            .focus(&terminal)
            .map_err(map_layout_error)
    })
}

#[no_mangle]
pub unsafe extern "C" fn ouro_split_layout_focus_direction(
    layout: *mut OuroSplitLayout,
    requested_direction: i32,
    out_result: *mut SplitFocusResult,
) -> SplitLayoutResult {
    ffi_guard(|| {
        let output = focus_output(out_result)?;
        let mut state = layout_state(layout)?;
        let moved = state
            .focus_direction(direction(requested_direction)?)
            .is_some();
        *output = SplitFocusResult {
            size: size_of::<SplitFocusResult>(),
            abi_version: SPLIT_LAYOUT_ABI_VERSION,
            moved: u8::from(moved),
            focused_terminal: terminal_record(state.focused()),
        };
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn ouro_split_layout_can_split_focused(
    layout: *mut OuroSplitLayout,
    out_can_split: *mut u8,
) -> SplitLayoutResult {
    ffi_guard(|| {
        let output = out_can_split
            .as_mut()
            .ok_or(SplitLayoutResult::InvalidArgument)?;
        *output = 0;
        let state = layout_state(layout)?;
        let existing = state.terminal_ids();
        let candidate = (0..=MAX_SPLIT_LEAVES)
            .map(|index| TerminalId::new(format!("ourocode-split-probe-{index}")))
            .collect::<Result<Vec<_>, _>>()
            .map_err(map_layout_error)?
            .into_iter()
            .find(|candidate| !existing.contains(candidate))
            .ok_or(SplitLayoutResult::InternalError)?;
        let mut probe = state.clone();
        match probe.split_focused(SplitAxis::LeftRight, candidate, SplitPlacement::After) {
            Ok(_) => *output = 1,
            Err(
                SplitLayoutError::LeafLimit { .. }
                | SplitLayoutError::DepthLimit { .. }
                | SplitLayoutError::StructureMutationDuringDrag,
            ) => {}
            Err(error) => return Err(map_layout_error(error)),
        }
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn ouro_split_layout_split_focused(
    layout: *mut OuroSplitLayout,
    requested_axis: i32,
    new_terminal: *const SplitTerminalId,
    requested_placement: i32,
    out_divider_node_id: *mut u64,
) -> SplitLayoutResult {
    ffi_guard(|| {
        let output = out_divider_node_id
            .as_mut()
            .ok_or(SplitLayoutResult::InvalidArgument)?;
        *output = 0;
        let terminal = input_terminal(new_terminal)?;
        let divider = layout_state(layout)?
            .split_focused(
                axis(requested_axis)?,
                terminal,
                placement(requested_placement)?,
            )
            .map_err(map_layout_error)?;
        *output = divider.get();
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn ouro_split_layout_close(
    layout: *mut OuroSplitLayout,
    terminal: *const SplitTerminalId,
) -> SplitLayoutResult {
    ffi_guard(|| {
        let terminal = input_terminal(terminal)?;
        layout_state(layout)?
            .close(&terminal)
            .map_err(map_layout_error)
    })
}

#[no_mangle]
pub unsafe extern "C" fn ouro_split_layout_begin_divider_drag(
    layout: *mut OuroSplitLayout,
    divider_node_id: u64,
    out_update: *mut SplitPresentationUpdate,
) -> SplitLayoutResult {
    ffi_guard(|| {
        let output = presentation_output(out_update)?;
        let divider = SplitNodeId::from_metadata(divider_node_id).map_err(map_layout_error)?;
        let update = layout_state(layout)?
            .begin_divider_drag(divider)
            .map_err(map_layout_error)?;
        *output = update_record(update);
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn ouro_split_layout_update_divider_drag(
    layout: *mut OuroSplitLayout,
    position_from_start: u32,
    available_span: u32,
    out_update: *mut SplitPresentationUpdate,
) -> SplitLayoutResult {
    ffi_guard(|| {
        let output = presentation_output(out_update)?;
        let update = layout_state(layout)?
            .update_divider_drag(position_from_start, available_span)
            .map_err(map_layout_error)?;
        *output = update_record(update);
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn ouro_split_layout_commit_divider_drag(
    layout: *mut OuroSplitLayout,
    affected_terminals: *mut SplitTerminalId,
    affected_capacity: usize,
    out_intent: *mut SplitResizeIntent,
) -> SplitLayoutResult {
    ffi_guard(|| {
        let output = intent_output(out_intent)?;
        let mut state = layout_state(layout)?;
        preflight_affected_buffer(
            state.leaf_count(),
            affected_terminals,
            affected_capacity,
            output,
            state.revision(),
        )?;
        let intent = state.commit_divider_drag().map_err(map_layout_error)?;
        write_resize_intent(intent, affected_terminals, output, state.revision());
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn ouro_split_layout_cancel_divider_drag(
    layout: *mut OuroSplitLayout,
    out_update: *mut SplitPresentationUpdate,
) -> SplitLayoutResult {
    ffi_guard(|| {
        let output = presentation_output(out_update)?;
        let update = layout_state(layout)?
            .cancel_divider_drag()
            .map_err(map_layout_error)?;
        *output = update_record(update);
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn ouro_split_layout_resize_divider_keyboard(
    layout: *mut OuroSplitLayout,
    divider_node_id: u64,
    delta_basis_points: i16,
    affected_terminals: *mut SplitTerminalId,
    affected_capacity: usize,
    out_intent: *mut SplitResizeIntent,
) -> SplitLayoutResult {
    ffi_guard(|| {
        let output = intent_output(out_intent)?;
        let divider = SplitNodeId::from_metadata(divider_node_id).map_err(map_layout_error)?;
        let mut state = layout_state(layout)?;
        preflight_affected_buffer(
            state.leaf_count(),
            affected_terminals,
            affected_capacity,
            output,
            state.revision(),
        )?;
        let intent = state
            .resize_divider_from_keyboard(divider, delta_basis_points)
            .map_err(map_layout_error)?;
        write_resize_intent(intent, affected_terminals, output, state.revision());
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn ouro_split_layout_equalize(
    layout: *mut OuroSplitLayout,
    affected_terminals: *mut SplitTerminalId,
    affected_capacity: usize,
    out_intent: *mut SplitResizeIntent,
) -> SplitLayoutResult {
    ffi_guard(|| {
        let output = intent_output(out_intent)?;
        let mut state = layout_state(layout)?;
        preflight_affected_buffer(
            state.leaf_count(),
            affected_terminals,
            affected_capacity,
            output,
            state.revision(),
        )?;
        let intent = state.equalize().map_err(map_layout_error)?;
        write_resize_intent(intent, affected_terminals, output, state.revision());
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn terminal(value: &str) -> SplitTerminalId {
        let mut terminal = SplitTerminalId {
            size: size_of::<SplitTerminalId>(),
            abi_version: SPLIT_LAYOUT_ABI_VERSION,
            length: value.len(),
            bytes: [0; MAX_TERMINAL_ID_BYTES],
        };
        terminal.bytes[..value.len()].copy_from_slice(value.as_bytes());
        terminal
    }

    fn config(max_leaves: u32) -> SplitLayoutConfig {
        SplitLayoutConfig {
            size: size_of::<SplitLayoutConfig>(),
            abi_version: SPLIT_LAYOUT_ABI_VERSION,
            max_leaves,
            max_depth: 8,
        }
    }

    unsafe fn new_layout(max_leaves: u32) -> *mut OuroSplitLayout {
        let mut layout = ptr::null_mut();
        assert_eq!(
            ouro_split_layout_new(&config(max_leaves), &terminal("terminal-a"), &mut layout),
            SplitLayoutResult::Ok
        );
        assert!(!layout.is_null());
        layout
    }

    fn blank_snapshot() -> SplitLayoutSnapshot {
        SplitLayoutSnapshot {
            size: size_of::<SplitLayoutSnapshot>(),
            abi_version: SPLIT_LAYOUT_ABI_VERSION,
            revision: 0,
            leaf_count: 0,
            focused_terminal: terminal("unused"),
        }
    }

    fn blank_update() -> SplitPresentationUpdate {
        SplitPresentationUpdate {
            size: size_of::<SplitPresentationUpdate>(),
            abi_version: SPLIT_LAYOUT_ABI_VERSION,
            divider_node_id: 0,
            ratio_basis_points: 0,
        }
    }

    fn blank_intent() -> SplitResizeIntent {
        SplitResizeIntent {
            size: size_of::<SplitResizeIntent>(),
            abi_version: SPLIT_LAYOUT_ABI_VERSION,
            has_value: 0,
            cause: SplitResizeCauseValue::DividerCommit as i32,
            layout_revision: 0,
            affected_count: 0,
        }
    }

    #[test]
    fn one_leaf_snapshot_and_geometry_preserve_terminal_identity() {
        unsafe {
            let layout = new_layout(4);
            let mut snapshot = blank_snapshot();
            assert_eq!(
                ouro_split_layout_snapshot(layout, &mut snapshot),
                SplitLayoutResult::Ok
            );
            assert_eq!(snapshot.revision, 0);
            assert_eq!(snapshot.leaf_count, 1);
            assert_eq!(
                &snapshot.focused_terminal.bytes[..snapshot.focused_terminal.length],
                b"terminal-a"
            );
            let mut required = 0;
            assert_eq!(
                ouro_split_layout_copy_leaf_geometries(
                    layout,
                    snapshot.revision,
                    ptr::null_mut(),
                    0,
                    &mut required,
                ),
                SplitLayoutResult::BufferTooSmall
            );
            assert_eq!(required, 1);
            let mut geometry = std::mem::MaybeUninit::<SplitLeafGeometry>::uninit();
            assert_eq!(
                ouro_split_layout_copy_leaf_geometries(
                    layout,
                    snapshot.revision,
                    geometry.as_mut_ptr(),
                    1,
                    &mut required,
                ),
                SplitLayoutResult::Ok
            );
            let geometry = geometry.assume_init();
            assert_eq!((geometry.x, geometry.y), (0, 0));
            assert_eq!((geometry.width, geometry.height), (1_000_000, 1_000_000));
            ouro_split_layout_free(layout);
        }
    }

    #[test]
    fn two_leaf_mutation_focus_close_and_stale_copy_are_bounded() {
        unsafe {
            let layout = new_layout(2);
            let mut divider = 0;
            assert_eq!(
                ouro_split_layout_split_focused(
                    layout,
                    SplitAxisValue::LeftRight as i32,
                    &terminal("terminal-b"),
                    SplitPlacementValue::After as i32,
                    &mut divider,
                ),
                SplitLayoutResult::Ok
            );
            assert_ne!(divider, 0);
            let mut can_split = 1;
            assert_eq!(
                ouro_split_layout_can_split_focused(layout, &mut can_split),
                SplitLayoutResult::Ok
            );
            assert_eq!(can_split, 0);
            let mut snapshot = blank_snapshot();
            assert_eq!(
                ouro_split_layout_snapshot(layout, &mut snapshot),
                SplitLayoutResult::Ok
            );
            assert_eq!(snapshot.revision, 1);
            assert_eq!(snapshot.leaf_count, 2);
            let mut focus = SplitFocusResult {
                size: size_of::<SplitFocusResult>(),
                abi_version: SPLIT_LAYOUT_ABI_VERSION,
                moved: 0,
                focused_terminal: terminal("unused"),
            };
            assert_eq!(
                ouro_split_layout_focus_direction(
                    layout,
                    SplitFocusDirectionValue::Left as i32,
                    &mut focus,
                ),
                SplitLayoutResult::Ok
            );
            assert_eq!(focus.moved, 1);
            assert_eq!(
                &focus.focused_terminal.bytes[..focus.focused_terminal.length],
                b"terminal-a"
            );
            assert_eq!(
                ouro_split_layout_focus(layout, &terminal("terminal-b")),
                SplitLayoutResult::Ok
            );
            assert_eq!(
                ouro_split_layout_close(layout, &terminal("terminal-b")),
                SplitLayoutResult::Ok
            );
            let mut count = 0;
            let mut geometry = std::mem::MaybeUninit::<SplitLeafGeometry>::uninit();
            assert_eq!(
                ouro_split_layout_copy_leaf_geometries(
                    layout,
                    snapshot.revision,
                    geometry.as_mut_ptr(),
                    1,
                    &mut count,
                ),
                SplitLayoutResult::StaleSnapshot
            );
            assert_eq!(count, 0);
            assert_eq!(
                ouro_split_layout_close(layout, &terminal("terminal-a")),
                SplitLayoutResult::CannotCloseLastLeaf
            );
            ouro_split_layout_free(layout);
        }
    }

    #[test]
    fn pointer_updates_emit_no_intent_and_short_commit_buffer_is_atomic() {
        unsafe {
            let layout = new_layout(4);
            let mut divider = 0;
            assert_eq!(
                ouro_split_layout_split_focused(
                    layout,
                    SplitAxisValue::TopBottom as i32,
                    &terminal("terminal-b"),
                    SplitPlacementValue::After as i32,
                    &mut divider,
                ),
                SplitLayoutResult::Ok
            );
            let mut update = blank_update();
            assert_eq!(
                ouro_split_layout_begin_divider_drag(layout, divider, &mut update),
                SplitLayoutResult::Ok
            );
            for position in 0..100 {
                assert_eq!(
                    ouro_split_layout_update_divider_drag(layout, position, 100, &mut update),
                    SplitLayoutResult::Ok
                );
            }
            let mut before = blank_snapshot();
            assert_eq!(
                ouro_split_layout_snapshot(layout, &mut before),
                SplitLayoutResult::Ok
            );
            let mut intent = blank_intent();
            assert_eq!(
                ouro_split_layout_commit_divider_drag(layout, ptr::null_mut(), 0, &mut intent,),
                SplitLayoutResult::BufferTooSmall
            );
            assert_eq!(intent.affected_count, 2);
            let mut after_failed = blank_snapshot();
            assert_eq!(
                ouro_split_layout_snapshot(layout, &mut after_failed),
                SplitLayoutResult::Ok
            );
            assert_eq!(after_failed.revision, before.revision);
            let mut affected = [terminal("unused"); 2];
            assert_eq!(
                ouro_split_layout_commit_divider_drag(
                    layout,
                    affected.as_mut_ptr(),
                    affected.len(),
                    &mut intent,
                ),
                SplitLayoutResult::Ok
            );
            assert_eq!(intent.has_value, 1);
            assert_eq!(intent.cause, SplitResizeCauseValue::DividerCommit as i32);
            assert_eq!(intent.layout_revision, before.revision + 1);
            assert_eq!(intent.affected_count, 2);
            assert_eq!(&affected[0].bytes[..affected[0].length], b"terminal-a");
            assert_eq!(&affected[1].bytes[..affected[1].length], b"terminal-b");
            ouro_split_layout_free(layout);
        }
    }

    #[test]
    fn invalid_sizes_lengths_nulls_and_zero_span_fail_closed() {
        unsafe {
            let mut layout = ptr::null_mut();
            let mut bad_config = config(4);
            bad_config.abi_version = 99;
            assert_eq!(
                ouro_split_layout_new(&bad_config, &terminal("a"), &mut layout),
                SplitLayoutResult::InvalidArgument
            );
            assert!(layout.is_null());

            let layout = new_layout(4);
            let mut invalid_id = terminal("a");
            invalid_id.length = MAX_TERMINAL_ID_BYTES + 1;
            assert_eq!(
                ouro_split_layout_focus(layout, &invalid_id),
                SplitLayoutResult::InvalidArgument
            );
            let mut divider = 0;
            assert_eq!(
                ouro_split_layout_split_focused(
                    layout,
                    SplitAxisValue::LeftRight as i32,
                    &terminal("b"),
                    SplitPlacementValue::After as i32,
                    &mut divider,
                ),
                SplitLayoutResult::Ok
            );
            let mut update = blank_update();
            assert_eq!(
                ouro_split_layout_begin_divider_drag(layout, divider, &mut update),
                SplitLayoutResult::Ok
            );
            assert_eq!(
                ouro_split_layout_update_divider_drag(layout, 1, 0, &mut update),
                SplitLayoutResult::InvalidArgument
            );
            assert_eq!(
                ouro_split_layout_cancel_divider_drag(layout, &mut update),
                SplitLayoutResult::Ok
            );
            assert_eq!(
                ouro_split_layout_split_focused(
                    layout,
                    99,
                    &terminal("c"),
                    SplitPlacementValue::After as i32,
                    &mut divider,
                ),
                SplitLayoutResult::InvalidArgument
            );
            assert_eq!(
                ouro_split_layout_snapshot(ptr::null_mut(), &mut blank_snapshot()),
                SplitLayoutResult::InvalidArgument
            );
            ouro_split_layout_free(layout);
            ouro_split_layout_free(ptr::null_mut());
        }
    }

    #[test]
    fn keyboard_resize_emits_one_bounded_intent_and_clamped_no_change() {
        unsafe {
            let layout = new_layout(4);
            let mut divider = 0;
            assert_eq!(
                ouro_split_layout_split_focused(
                    layout,
                    SplitAxisValue::LeftRight as i32,
                    &terminal("terminal-b"),
                    SplitPlacementValue::After as i32,
                    &mut divider,
                ),
                SplitLayoutResult::Ok
            );
            let mut affected = [terminal("unused"); 2];
            let mut intent = blank_intent();
            assert_eq!(
                ouro_split_layout_resize_divider_keyboard(
                    layout,
                    divider,
                    -10_000,
                    affected.as_mut_ptr(),
                    affected.len(),
                    &mut intent,
                ),
                SplitLayoutResult::Ok
            );
            assert_eq!(intent.has_value, 1);
            assert_eq!(intent.cause, SplitResizeCauseValue::Keyboard as i32);
            assert_eq!(intent.affected_count, 2);
            assert_eq!(
                ouro_split_layout_resize_divider_keyboard(
                    layout,
                    divider,
                    -1,
                    affected.as_mut_ptr(),
                    affected.len(),
                    &mut intent,
                ),
                SplitLayoutResult::Ok
            );
            assert_eq!(intent.has_value, 0);
            assert_eq!(intent.affected_count, 0);
            ouro_split_layout_free(layout);
        }
    }

    #[test]
    fn equalize_emits_one_bounded_recursive_intent() {
        unsafe {
            let layout = new_layout(4);
            let mut divider = 0;
            assert_eq!(
                ouro_split_layout_split_focused(
                    layout,
                    SplitAxisValue::LeftRight as i32,
                    &terminal("terminal-b"),
                    SplitPlacementValue::After as i32,
                    &mut divider,
                ),
                SplitLayoutResult::Ok
            );
            let mut affected = [terminal("unused"); 4];
            let mut intent = blank_intent();
            assert_eq!(
                ouro_split_layout_resize_divider_keyboard(
                    layout,
                    divider,
                    2_000,
                    affected.as_mut_ptr(),
                    affected.len(),
                    &mut intent,
                ),
                SplitLayoutResult::Ok
            );
            assert_eq!(
                ouro_split_layout_equalize(
                    layout,
                    affected.as_mut_ptr(),
                    affected.len(),
                    &mut intent,
                ),
                SplitLayoutResult::Ok
            );
            assert_eq!(intent.has_value, 1);
            assert_eq!(intent.cause, SplitResizeCauseValue::Equalize as i32);
            assert_eq!(intent.affected_count, 2);
            assert_eq!(
                ouro_split_layout_equalize(
                    layout,
                    affected.as_mut_ptr(),
                    affected.len(),
                    &mut intent,
                ),
                SplitLayoutResult::Ok
            );
            assert_eq!(intent.has_value, 0);
            ouro_split_layout_free(layout);
        }
    }
}
