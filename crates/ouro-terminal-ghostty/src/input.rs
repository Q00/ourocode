use super::{result, Error, Terminal, TERMINAL_ENGINE_ABI_VERSION};
use std::ffi::c_void;
use std::ptr::NonNull;

pub const MAX_KEY_TEXT_BYTES: usize = 4096;
pub const MAX_PASTE_SOURCE_BYTES: usize = 65_536 - 12;

#[repr(C)]
#[derive(Clone, Copy)]
struct RawInputConfig {
    size: usize,
    abi_version: u32,
    option_as_alt: i32,
}

#[repr(C)]
struct RawKeyEvent {
    size: usize,
    abi_version: u32,
    hid_usage: u32,
    action: i32,
    modifiers: u16,
    consumed_modifiers: u16,
    composing: bool,
    unshifted_codepoint: u32,
    utf8: *const u8,
    utf8_length: usize,
}

#[repr(C)]
struct RawMouseGeometry {
    size: usize,
    abi_version: u32,
    screen_width: f64,
    screen_height: f64,
    cell_width: f64,
    cell_height: f64,
    padding_top: f64,
    padding_bottom: f64,
    padding_right: f64,
    padding_left: f64,
}

#[repr(C)]
struct RawMouseEvent {
    size: usize,
    abi_version: u32,
    action: i32,
    button: i32,
    modifiers: u16,
    x: f64,
    y: f64,
}

#[repr(C)]
struct RawScrollEvent {
    size: usize,
    abi_version: u32,
    direction: i32,
    modifiers: u16,
    x: f64,
    y: f64,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct RawSelectionConfig {
    size: usize,
    abi_version: u32,
    copy_max_bytes: usize,
    repeat_distance_px: f64,
    repeat_interval_ns: u64,
}

#[repr(C)]
struct RawSelectionPoint {
    size: usize,
    abi_version: u32,
    column: u16,
    row: u32,
    surface_x: f64,
    surface_y: f64,
    has_time: bool,
    time_ns: u64,
}

#[repr(C)]
struct RawSelectionGeometry {
    size: usize,
    abi_version: u32,
    columns: u32,
    cell_width: f64,
    padding_left: f64,
    screen_height: f64,
}

extern "C" {
    fn ouro_terminal_input_new(
        terminal: *mut c_void,
        config: *const RawInputConfig,
        out: *mut *mut c_void,
    ) -> i32;
    fn ouro_terminal_input_free(input: *mut c_void);
    fn ouro_terminal_input_encode_key(
        input: *mut c_void,
        event: *const RawKeyEvent,
        buffer: *mut u8,
        capacity: usize,
        out_length: *mut usize,
    ) -> i32;
    fn ouro_terminal_input_encode_committed_text(
        input: *mut c_void,
        utf8: *const u8,
        length: usize,
        buffer: *mut u8,
        capacity: usize,
        out_length: *mut usize,
    ) -> i32;
    fn ouro_terminal_input_set_mouse_geometry(
        input: *mut c_void,
        geometry: *const RawMouseGeometry,
    ) -> i32;
    fn ouro_terminal_input_mouse_reporting(input: *mut c_void, out_enabled: *mut bool) -> i32;
    fn ouro_terminal_input_encode_mouse(
        input: *mut c_void,
        event: *const RawMouseEvent,
        buffer: *mut u8,
        capacity: usize,
        out_length: *mut usize,
    ) -> i32;
    fn ouro_terminal_input_encode_scroll(
        input: *mut c_void,
        event: *const RawScrollEvent,
        buffer: *mut u8,
        capacity: usize,
        out_length: *mut usize,
    ) -> i32;
    fn ouro_terminal_input_reset_mouse(input: *mut c_void) -> i32;
    fn ouro_terminal_input_paste_is_safe(
        input: *mut c_void,
        source: *const u8,
        source_length: usize,
        out_safe: *mut bool,
    ) -> i32;
    fn ouro_terminal_input_encode_paste(
        input: *mut c_void,
        source: *const u8,
        source_length: usize,
        buffer: *mut u8,
        capacity: usize,
        out_length: *mut usize,
    ) -> i32;
    fn ouro_terminal_input_encode_focus(
        input: *mut c_void,
        focused: bool,
        buffer: *mut u8,
        capacity: usize,
        out_length: *mut usize,
    ) -> i32;
    fn ouro_terminal_selection_new(
        terminal: *mut c_void,
        config: *const RawSelectionConfig,
        out: *mut *mut c_void,
    ) -> i32;
    fn ouro_terminal_selection_free(selection: *mut c_void);
    fn ouro_terminal_selection_begin(
        selection: *mut c_void,
        point: *const RawSelectionPoint,
    ) -> i32;
    fn ouro_terminal_selection_update(
        selection: *mut c_void,
        point: *const RawSelectionPoint,
        geometry: *const RawSelectionGeometry,
        rectangle: bool,
    ) -> i32;
    fn ouro_terminal_selection_autoscroll(
        selection: *mut c_void,
        viewport_column: u16,
        viewport_row: u32,
        surface_x: f64,
        surface_y: f64,
        geometry: *const RawSelectionGeometry,
        rectangle: bool,
        out_direction: *mut i32,
    ) -> i32;
    fn ouro_terminal_selection_end(selection: *mut c_void, point: *const RawSelectionPoint) -> i32;
    fn ouro_terminal_selection_cancel(selection: *mut c_void) -> i32;
    fn ouro_terminal_selection_copy(
        selection: *mut c_void,
        buffer: *mut u8,
        capacity: usize,
        out_length: *mut usize,
    ) -> i32;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(i32)]
pub enum OptionAsAlt {
    False = 0,
    True = 1,
    Left = 2,
    Right = 3,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InputConfig {
    pub option_as_alt: OptionAsAlt,
}

impl Default for InputConfig {
    fn default() -> Self {
        Self {
            option_as_alt: OptionAsAlt::False,
        }
    }
}

impl InputConfig {
    fn raw(self) -> RawInputConfig {
        RawInputConfig {
            size: std::mem::size_of::<RawInputConfig>(),
            abi_version: TERMINAL_ENGINE_ABI_VERSION,
            option_as_alt: self.option_as_alt as i32,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(i32)]
pub enum KeyAction {
    Release = 0,
    Press = 1,
    Repeat = 2,
}

pub type Modifiers = u16;
pub const MOD_SHIFT: Modifiers = 1 << 0;
pub const MOD_CTRL: Modifiers = 1 << 1;
pub const MOD_ALT: Modifiers = 1 << 2;
pub const MOD_SUPER: Modifiers = 1 << 3;
pub const MOD_CAPS_LOCK: Modifiers = 1 << 4;
pub const MOD_NUM_LOCK: Modifiers = 1 << 5;
pub const MOD_SHIFT_RIGHT: Modifiers = 1 << 6;
pub const MOD_CTRL_RIGHT: Modifiers = 1 << 7;
pub const MOD_ALT_RIGHT: Modifiers = 1 << 8;
pub const MOD_SUPER_RIGHT: Modifiers = 1 << 9;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct KeyEvent<'text> {
    pub hid_usage: u32,
    pub action: KeyAction,
    pub modifiers: Modifiers,
    pub consumed_modifiers: Modifiers,
    pub composing: bool,
    pub unshifted_codepoint: u32,
    pub utf8: &'text [u8],
}

impl<'text> KeyEvent<'text> {
    fn raw(self) -> RawKeyEvent {
        RawKeyEvent {
            size: std::mem::size_of::<RawKeyEvent>(),
            abi_version: TERMINAL_ENGINE_ABI_VERSION,
            hid_usage: self.hid_usage,
            action: self.action as i32,
            modifiers: self.modifiers,
            consumed_modifiers: self.consumed_modifiers,
            composing: self.composing,
            unshifted_codepoint: self.unshifted_codepoint,
            utf8: self.utf8.as_ptr(),
            utf8_length: self.utf8.len(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MouseGeometry {
    pub screen_width: f64,
    pub screen_height: f64,
    pub cell_width: f64,
    pub cell_height: f64,
    pub padding_top: f64,
    pub padding_bottom: f64,
    pub padding_right: f64,
    pub padding_left: f64,
}

impl MouseGeometry {
    fn raw(self) -> RawMouseGeometry {
        RawMouseGeometry {
            size: std::mem::size_of::<RawMouseGeometry>(),
            abi_version: TERMINAL_ENGINE_ABI_VERSION,
            screen_width: self.screen_width,
            screen_height: self.screen_height,
            cell_width: self.cell_width,
            cell_height: self.cell_height,
            padding_top: self.padding_top,
            padding_bottom: self.padding_bottom,
            padding_right: self.padding_right,
            padding_left: self.padding_left,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(i32)]
pub enum MouseAction {
    Press = 0,
    Release = 1,
    Motion = 2,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(i32)]
pub enum MouseButton {
    None = 0,
    Left = 1,
    Right = 2,
    Middle = 3,
    Four = 4,
    Five = 5,
    Six = 6,
    Seven = 7,
    Eight = 8,
    Nine = 9,
    Ten = 10,
    Eleven = 11,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MouseEvent {
    pub action: MouseAction,
    pub button: MouseButton,
    pub modifiers: Modifiers,
    pub x: f64,
    pub y: f64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(i32)]
pub enum ScrollDirection {
    Up = 0,
    Down = 1,
    Left = 2,
    Right = 3,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ScrollEvent {
    pub direction: ScrollDirection,
    pub modifiers: Modifiers,
    pub x: f64,
    pub y: f64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EncodeOutcome {
    Written(usize),
    BufferTooSmall { required: usize },
}

fn encode_outcome(code: i32, length: usize) -> Result<EncodeOutcome, Error> {
    if code == 0 {
        Ok(EncodeOutcome::Written(length))
    } else if code == 4 {
        Ok(EncodeOutcome::BufferTooSmall { required: length })
    } else {
        result(code)?;
        Err(Error::Engine)
    }
}

pub(crate) struct RawInputOwner {
    raw: NonNull<c_void>,
    config: InputConfig,
}

impl RawInputOwner {
    pub(crate) fn free(self) {
        // SAFETY: the terminal owner releases this unique child before itself.
        unsafe { ouro_terminal_input_free(self.raw.as_ptr()) };
    }
}

pub struct TerminalInput<'terminal> {
    terminal: &'terminal mut Terminal,
}

impl Terminal {
    pub fn input(&mut self, config: InputConfig) -> Result<TerminalInput<'_>, Error> {
        let replace = self
            .input
            .as_ref()
            .is_none_or(|owner| owner.config != config);
        if replace {
            if let Some(old) = self.input.take() {
                old.free();
            }
            let raw_config = config.raw();
            let mut raw = std::ptr::null_mut();
            // SAFETY: terminal and config live through this synchronous call.
            result(unsafe { ouro_terminal_input_new(self.raw.as_ptr(), &raw_config, &mut raw) })?;
            self.input = Some(RawInputOwner {
                raw: NonNull::new(raw).ok_or(Error::Engine)?,
                config,
            });
        }
        Ok(TerminalInput { terminal: self })
    }
}

impl TerminalInput<'_> {
    fn raw(&self) -> Result<NonNull<c_void>, Error> {
        self.terminal
            .input
            .as_ref()
            .map(|owner| owner.raw)
            .ok_or(Error::Engine)
    }

    pub fn feed(&mut self, bytes: &[u8]) -> Result<(), Error> {
        self.terminal.feed(bytes)
    }

    pub fn encode_key(
        &mut self,
        event: KeyEvent<'_>,
        output: &mut [u8],
    ) -> Result<EncodeOutcome, Error> {
        let raw = event.raw();
        let mut length = 0;
        // SAFETY: all borrowed buffers remain valid for this synchronous call.
        let code = unsafe {
            ouro_terminal_input_encode_key(
                self.raw()?.as_ptr(),
                &raw,
                output.as_mut_ptr(),
                output.len(),
                &mut length,
            )
        };
        encode_outcome(code, length)
    }

    pub fn encode_committed_text(
        &mut self,
        text: &[u8],
        output: &mut [u8],
    ) -> Result<EncodeOutcome, Error> {
        let mut length = 0;
        // SAFETY: borrowed text and output are valid for the call.
        let code = unsafe {
            ouro_terminal_input_encode_committed_text(
                self.raw()?.as_ptr(),
                text.as_ptr(),
                text.len(),
                output.as_mut_ptr(),
                output.len(),
                &mut length,
            )
        };
        encode_outcome(code, length)
    }

    pub fn set_mouse_geometry(&mut self, geometry: MouseGeometry) -> Result<(), Error> {
        let raw = geometry.raw();
        // SAFETY: raw geometry is valid for the synchronous call.
        result(unsafe { ouro_terminal_input_set_mouse_geometry(self.raw()?.as_ptr(), &raw) })
    }

    /// Returns whether the terminal's current modes route pointer events to
    /// the PTY. UI modifier overrides (for example Shift-to-select) remain an
    /// app policy layered above this non-mutating probe.
    pub fn mouse_reporting(&self) -> Result<bool, Error> {
        let mut enabled = false;
        // SAFETY: the output bool is writable for this synchronous read.
        result(unsafe { ouro_terminal_input_mouse_reporting(self.raw()?.as_ptr(), &mut enabled) })?;
        Ok(enabled)
    }

    pub fn encode_mouse(
        &mut self,
        event: MouseEvent,
        output: &mut [u8],
    ) -> Result<EncodeOutcome, Error> {
        let raw = RawMouseEvent {
            size: std::mem::size_of::<RawMouseEvent>(),
            abi_version: TERMINAL_ENGINE_ABI_VERSION,
            action: event.action as i32,
            button: event.button as i32,
            modifiers: event.modifiers,
            x: event.x,
            y: event.y,
        };
        let mut length = 0;
        // SAFETY: raw event and output are valid for this synchronous call.
        let code = unsafe {
            ouro_terminal_input_encode_mouse(
                self.raw()?.as_ptr(),
                &raw,
                output.as_mut_ptr(),
                output.len(),
                &mut length,
            )
        };
        encode_outcome(code, length)
    }

    pub fn encode_scroll(
        &mut self,
        event: ScrollEvent,
        output: &mut [u8],
    ) -> Result<EncodeOutcome, Error> {
        let raw = RawScrollEvent {
            size: std::mem::size_of::<RawScrollEvent>(),
            abi_version: TERMINAL_ENGINE_ABI_VERSION,
            direction: event.direction as i32,
            modifiers: event.modifiers,
            x: event.x,
            y: event.y,
        };
        let mut length = 0;
        // SAFETY: raw event and output are valid for this synchronous call.
        let code = unsafe {
            ouro_terminal_input_encode_scroll(
                self.raw()?.as_ptr(),
                &raw,
                output.as_mut_ptr(),
                output.len(),
                &mut length,
            )
        };
        encode_outcome(code, length)
    }

    pub fn reset_mouse(&mut self) -> Result<(), Error> {
        // SAFETY: this is the unique serialized input child.
        result(unsafe { ouro_terminal_input_reset_mouse(self.raw()?.as_ptr()) })
    }

    pub fn paste_is_safe(&mut self, source: &[u8]) -> Result<bool, Error> {
        let mut safe = false;
        // SAFETY: source and output bool remain valid through the call.
        result(unsafe {
            ouro_terminal_input_paste_is_safe(
                self.raw()?.as_ptr(),
                source.as_ptr(),
                source.len(),
                &mut safe,
            )
        })?;
        Ok(safe)
    }

    pub fn encode_paste(
        &mut self,
        source: &[u8],
        output: &mut [u8],
    ) -> Result<EncodeOutcome, Error> {
        let mut length = 0;
        // SAFETY: source remains borrowed/immutable and output is writable.
        let code = unsafe {
            ouro_terminal_input_encode_paste(
                self.raw()?.as_ptr(),
                source.as_ptr(),
                source.len(),
                output.as_mut_ptr(),
                output.len(),
                &mut length,
            )
        };
        encode_outcome(code, length)
    }

    pub fn encode_focus(
        &mut self,
        focused: bool,
        output: &mut [u8],
    ) -> Result<EncodeOutcome, Error> {
        let mut length = 0;
        // SAFETY: output remains valid for the synchronous call.
        let code = unsafe {
            ouro_terminal_input_encode_focus(
                self.raw()?.as_ptr(),
                focused,
                output.as_mut_ptr(),
                output.len(),
                &mut length,
            )
        };
        encode_outcome(code, length)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SelectionConfig {
    pub copy_max_bytes: usize,
    pub repeat_distance_px: f64,
    pub repeat_interval_ns: u64,
}

impl Default for SelectionConfig {
    fn default() -> Self {
        Self {
            copy_max_bytes: 1024 * 1024,
            repeat_distance_px: 5.0,
            repeat_interval_ns: 500_000_000,
        }
    }
}

impl SelectionConfig {
    fn raw(self) -> RawSelectionConfig {
        RawSelectionConfig {
            size: std::mem::size_of::<RawSelectionConfig>(),
            abi_version: TERMINAL_ENGINE_ABI_VERSION,
            copy_max_bytes: self.copy_max_bytes,
            repeat_distance_px: self.repeat_distance_px,
            repeat_interval_ns: self.repeat_interval_ns,
        }
    }
}

impl PartialEq for RawSelectionConfig {
    fn eq(&self, other: &Self) -> bool {
        self.copy_max_bytes == other.copy_max_bytes
            && self.repeat_distance_px.to_bits() == other.repeat_distance_px.to_bits()
            && self.repeat_interval_ns == other.repeat_interval_ns
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SelectionPoint {
    pub column: u16,
    pub row: u32,
    pub surface_x: f64,
    pub surface_y: f64,
    pub time_ns: Option<u64>,
}

impl SelectionPoint {
    fn raw(self) -> RawSelectionPoint {
        RawSelectionPoint {
            size: std::mem::size_of::<RawSelectionPoint>(),
            abi_version: TERMINAL_ENGINE_ABI_VERSION,
            column: self.column,
            row: self.row,
            surface_x: self.surface_x,
            surface_y: self.surface_y,
            has_time: self.time_ns.is_some(),
            time_ns: self.time_ns.unwrap_or(0),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SelectionGeometry {
    pub columns: u32,
    pub cell_width: f64,
    pub padding_left: f64,
    pub screen_height: f64,
}

impl SelectionGeometry {
    fn raw(self) -> RawSelectionGeometry {
        RawSelectionGeometry {
            size: std::mem::size_of::<RawSelectionGeometry>(),
            abi_version: TERMINAL_ENGINE_ABI_VERSION,
            columns: self.columns,
            cell_width: self.cell_width,
            padding_left: self.padding_left,
            screen_height: self.screen_height,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SelectionOutcome {
    Selection,
    NoValue,
}

fn selection_outcome(code: i32) -> Result<SelectionOutcome, Error> {
    match code {
        0 => Ok(SelectionOutcome::Selection),
        5 => Ok(SelectionOutcome::NoValue),
        _ => {
            result(code)?;
            Err(Error::Engine)
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(i32)]
pub enum SelectionAutoscroll {
    None = 0,
    Up = 1,
    Down = 2,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SelectionCopyOutcome {
    Written(usize),
    BufferTooSmall { required: usize },
    NoSelection,
}

pub(crate) struct RawSelectionOwner {
    raw: NonNull<c_void>,
    config: RawSelectionConfig,
}

impl RawSelectionOwner {
    pub(crate) fn free(self) {
        // SAFETY: the unique child is released before its terminal.
        unsafe { ouro_terminal_selection_free(self.raw.as_ptr()) };
    }
}

pub struct TerminalSelection<'terminal> {
    terminal: &'terminal mut Terminal,
}

impl Terminal {
    pub fn selection(&mut self, config: SelectionConfig) -> Result<TerminalSelection<'_>, Error> {
        let raw_config = config.raw();
        let replace = self
            .selection
            .as_ref()
            .is_none_or(|owner| owner.config != raw_config);
        if replace {
            if let Some(old) = self.selection.take() {
                old.free();
            }
            let mut raw = std::ptr::null_mut();
            // SAFETY: terminal/config/out remain valid for this synchronous call.
            result(unsafe {
                ouro_terminal_selection_new(self.raw.as_ptr(), &raw_config, &mut raw)
            })?;
            self.selection = Some(RawSelectionOwner {
                raw: NonNull::new(raw).ok_or(Error::Engine)?,
                config: raw_config,
            });
        }
        Ok(TerminalSelection { terminal: self })
    }
}

impl TerminalSelection<'_> {
    fn raw(&self) -> Result<NonNull<c_void>, Error> {
        self.terminal
            .selection
            .as_ref()
            .map(|owner| owner.raw)
            .ok_or(Error::Engine)
    }

    pub fn begin(&mut self, point: SelectionPoint) -> Result<SelectionOutcome, Error> {
        let raw = point.raw();
        // SAFETY: raw point is valid for this synchronous call.
        selection_outcome(unsafe { ouro_terminal_selection_begin(self.raw()?.as_ptr(), &raw) })
    }

    pub fn update(
        &mut self,
        point: SelectionPoint,
        geometry: SelectionGeometry,
        rectangle: bool,
    ) -> Result<SelectionOutcome, Error> {
        let point = point.raw();
        let geometry = geometry.raw();
        // SAFETY: raw values are valid for this synchronous call.
        selection_outcome(unsafe {
            ouro_terminal_selection_update(self.raw()?.as_ptr(), &point, &geometry, rectangle)
        })
    }

    pub fn autoscroll(
        &mut self,
        viewport: (u16, u32),
        surface: (f64, f64),
        geometry: SelectionGeometry,
        rectangle: bool,
    ) -> Result<(SelectionOutcome, SelectionAutoscroll), Error> {
        let geometry = geometry.raw();
        let mut direction = 0;
        // SAFETY: raw geometry and direction output remain valid for the call.
        let outcome = selection_outcome(unsafe {
            ouro_terminal_selection_autoscroll(
                self.raw()?.as_ptr(),
                viewport.0,
                viewport.1,
                surface.0,
                surface.1,
                &geometry,
                rectangle,
                &mut direction,
            )
        })?;
        let direction = match direction {
            0 => SelectionAutoscroll::None,
            1 => SelectionAutoscroll::Up,
            2 => SelectionAutoscroll::Down,
            _ => return Err(Error::Engine),
        };
        Ok((outcome, direction))
    }

    pub fn end(&mut self, point: Option<SelectionPoint>) -> Result<SelectionOutcome, Error> {
        let raw = point.map(SelectionPoint::raw);
        // SAFETY: optional point remains valid for the synchronous call.
        selection_outcome(unsafe {
            ouro_terminal_selection_end(
                self.raw()?.as_ptr(),
                raw.as_ref().map_or(std::ptr::null(), |value| value),
            )
        })
    }

    pub fn cancel(&mut self) -> Result<(), Error> {
        // SAFETY: this is the unique serialized selection child.
        result(unsafe { ouro_terminal_selection_cancel(self.raw()?.as_ptr()) })
    }

    pub fn copy(&mut self, output: &mut [u8]) -> Result<SelectionCopyOutcome, Error> {
        let mut length = 0;
        // SAFETY: output remains writable for the synchronous call.
        match unsafe {
            ouro_terminal_selection_copy(
                self.raw()?.as_ptr(),
                output.as_mut_ptr(),
                output.len(),
                &mut length,
            )
        } {
            0 => Ok(SelectionCopyOutcome::Written(length)),
            4 => Ok(SelectionCopyOutcome::BufferTooSmall { required: length }),
            5 => Ok(SelectionCopyOutcome::NoSelection),
            code => {
                result(code)?;
                Err(Error::Engine)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Config;

    fn key<'a>(hid_usage: u32, utf8: &'a [u8]) -> KeyEvent<'a> {
        KeyEvent {
            hid_usage,
            action: KeyAction::Press,
            modifiers: 0,
            consumed_modifiers: 0,
            composing: false,
            unshifted_codepoint: 0,
            utf8,
        }
    }

    fn written(outcome: EncodeOutcome, buffer: &[u8]) -> &[u8] {
        match outcome {
            EncodeOutcome::Written(length) => &buffer[..length],
            EncodeOutcome::BufferTooSmall { required } => {
                panic!("unexpected required capacity {required}")
            }
        }
    }

    #[test]
    fn key_encoder_tracks_dec_modes_modify_other_keys_kitty_and_kam() {
        let mut terminal = Terminal::new(Config::default()).unwrap();
        let mut input = terminal.input(InputConfig::default()).unwrap();
        let mut buffer = [0u8; 128];

        let normal = input.encode_key(key(0x52, &[]), &mut buffer).unwrap();
        assert_eq!(written(normal, &buffer), b"\x1b[A");
        input.feed(b"\x1b[?1h").unwrap();
        let application = input.encode_key(key(0x52, &[]), &mut buffer).unwrap();
        assert_eq!(written(application, &buffer), b"\x1bOA");

        let backspace = input.encode_key(key(0x2a, &[]), &mut buffer).unwrap();
        assert_eq!(written(backspace, &buffer), b"\x7f");
        input.feed(b"\x1b[?67h").unwrap();
        let backspace = input.encode_key(key(0x2a, &[]), &mut buffer).unwrap();
        assert_eq!(written(backspace, &buffer), b"\x08");

        let keypad = input.encode_key(key(0x59, b"1"), &mut buffer).unwrap();
        assert_eq!(written(keypad, &buffer), b"1");
        input.feed(b"\x1b=\x1b[?1035l").unwrap();
        let keypad_event = key(0x59, b"1");
        let keypad = input.encode_key(keypad_event, &mut buffer).unwrap();
        assert_eq!(written(keypad, &buffer), b"\x1bOq");

        input.feed(b"\x1b[>4;2m").unwrap();
        let mut modified = key(0x0b, b"H");
        modified.modifiers = MOD_CTRL | MOD_SHIFT;
        let mok = input.encode_key(modified, &mut buffer).unwrap();
        assert_eq!(written(mok, &buffer), b"\x1b[27;6;72~");

        input.feed(b"\x1b[>3u").unwrap();
        let mut f1_release = key(0x3a, &[]);
        f1_release.action = KeyAction::Release;
        let kitty = input.encode_key(f1_release, &mut buffer).unwrap();
        let kitty = written(kitty, &buffer);
        assert_eq!(kitty, b"\x1b[1;1:3P");

        input.feed(b"\x1b[2h").unwrap();
        let locked = input.encode_key(key(0x04, b"a"), &mut buffer).unwrap();
        assert_eq!(locked, EncodeOutcome::Written(0));
        let committed = input
            .encode_committed_text("한글".as_bytes(), &mut buffer)
            .unwrap();
        assert_eq!(committed, EncodeOutcome::Written(0));
    }

    #[test]
    fn enter_key_encodes_carriage_return_for_canonical_ptys() {
        let mut terminal = Terminal::new(Config::default()).unwrap();
        let mut input = terminal.input(InputConfig::default()).unwrap();
        let mut buffer = [0u8; 16];
        let enter = input.encode_key(key(0x28, &[]), &mut buffer).unwrap();
        assert_eq!(written(enter, &buffer), b"\r");
    }

    #[test]
    fn enter_key_zero_capacity_preflight_is_retry_safe() {
        let mut terminal = Terminal::new(Config::default()).unwrap();
        let mut input = terminal.input(InputConfig::default()).unwrap();
        let enter = key(0x28, &[]);
        let mut empty = [];
        assert_eq!(
            input.encode_key(enter, &mut empty).unwrap(),
            EncodeOutcome::BufferTooSmall { required: 1 }
        );

        let mut buffer = [0u8; 1];
        let retry = input.encode_key(enter, &mut buffer).unwrap();
        assert_eq!(written(retry, &buffer), b"\r");
    }

    #[test]
    fn option_as_alt_is_reapplied_after_terminal_mode_sync() {
        let mut terminal = Terminal::new(Config::default()).unwrap();
        let mut input = terminal
            .input(InputConfig {
                option_as_alt: OptionAsAlt::True,
            })
            .unwrap();
        input.feed(b"\x1b[?1h").unwrap();
        let mut event = key(0x04, b"a");
        event.modifiers = MOD_ALT;
        let mut buffer = [0u8; 32];
        let outcome = input.encode_key(event, &mut buffer).unwrap();
        assert_eq!(written(outcome, &buffer), b"\x1ba");
    }

    #[test]
    fn paste_is_bounded_safe_and_source_immutable() {
        let mut terminal = Terminal::new(Config::default()).unwrap();
        let mut input = terminal.input(InputConfig::default()).unwrap();
        assert!(input.paste_is_safe(b"hello").unwrap());
        assert!(!input.paste_is_safe(b"hello\rworld").unwrap());
        assert!(!input.paste_is_safe(b"hello\nworld").unwrap());
        assert!(!input.paste_is_safe(b"x\x1b[201~y").unwrap());

        input.feed(b"\x1b[?2004h").unwrap();
        let source = b"hello\x1bworld".to_vec();
        let before = source.clone();
        let mut small = [0u8; 1];
        let query = input.encode_paste(&source, &mut small).unwrap();
        let required = match query {
            EncodeOutcome::BufferTooSmall { required } => required,
            other => panic!("unexpected outcome {other:?}"),
        };
        assert_eq!(source, before);
        let mut output = vec![0; required];
        let encoded = input.encode_paste(&source, &mut output).unwrap();
        assert_eq!(source, before);
        assert_eq!(written(encoded, &output), b"\x1b[200~hello world\x1b[201~");

        assert_eq!(
            input.paste_is_safe(&vec![b'x'; MAX_PASTE_SOURCE_BYTES + 1]),
            Err(Error::InvalidArgument)
        );
    }

    #[test]
    fn mouse_retry_is_identical_motion_dedupes_and_scroll_uses_public_buttons() {
        let mut terminal = Terminal::new(Config::default()).unwrap();
        let mut input = terminal.input(InputConfig::default()).unwrap();
        assert!(!input.mouse_reporting().unwrap());
        input.feed(b"\x1b[?1003h\x1b[?1006h").unwrap();
        assert!(input.mouse_reporting().unwrap());
        input
            .set_mouse_geometry(MouseGeometry {
                screen_width: 800.0,
                screen_height: 600.0,
                cell_width: 8.0,
                cell_height: 16.0,
                padding_top: 0.0,
                padding_bottom: 0.0,
                padding_right: 0.0,
                padding_left: 0.0,
            })
            .unwrap();
        let motion = MouseEvent {
            action: MouseAction::Motion,
            button: MouseButton::None,
            modifiers: 0,
            x: 17.0,
            y: 17.0,
        };
        let mut empty = [];
        let required = match input.encode_mouse(motion, &mut empty).unwrap() {
            EncodeOutcome::BufferTooSmall { required } => required,
            other => panic!("unexpected outcome {other:?}"),
        };
        let mut output = vec![0; required];
        let retry = input.encode_mouse(motion, &mut output).unwrap();
        let retry_bytes = written(retry, &output).to_vec();
        assert!(!retry_bytes.is_empty());
        assert_eq!(
            input.encode_mouse(motion, &mut output).unwrap(),
            EncodeOutcome::Written(0)
        );

        let scroll = input
            .encode_scroll(
                ScrollEvent {
                    direction: ScrollDirection::Up,
                    modifiers: 0,
                    x: 17.0,
                    y: 17.0,
                },
                &mut output,
            )
            .unwrap();
        assert!(written(scroll, &output).starts_with(b"\x1b[<64;"));
        assert_eq!(
            input.set_mouse_geometry(MouseGeometry {
                screen_width: f64::NAN,
                screen_height: 600.0,
                cell_width: 8.0,
                cell_height: 16.0,
                padding_top: 0.0,
                padding_bottom: 0.0,
                padding_right: 0.0,
                padding_left: 0.0,
            }),
            Err(Error::InvalidArgument)
        );
    }

    #[test]
    fn mouse_release_keeps_the_press_time_tracking_format() {
        let mut terminal = Terminal::new(Config::default()).unwrap();
        let mut input = terminal.input(InputConfig::default()).unwrap();
        input.feed(b"\x1b[?1000h\x1b[?1006h").unwrap();
        input
            .set_mouse_geometry(MouseGeometry {
                screen_width: 800.0,
                screen_height: 600.0,
                cell_width: 8.0,
                cell_height: 16.0,
                padding_top: 0.0,
                padding_bottom: 0.0,
                padding_right: 0.0,
                padding_left: 0.0,
            })
            .unwrap();
        let press = MouseEvent {
            action: MouseAction::Press,
            button: MouseButton::Left,
            modifiers: 0,
            x: 17.0,
            y: 17.0,
        };
        let mut empty = [];
        let required = match input.encode_mouse(press, &mut empty).unwrap() {
            EncodeOutcome::BufferTooSmall { required } => required,
            other => panic!("unexpected press preflight {other:?}"),
        };
        let mut output = vec![0; required.max(32)];
        let press = input.encode_mouse(press, &mut output).unwrap();
        assert!(written(press, &output).starts_with(b"\x1b[<0;"));

        // The child can change both tracking and output format while the
        // physical button remains down. A matching release still belongs to
        // the protocol that consumed the press.
        input.feed(b"\x1b[?1006l\x1b[?1000l").unwrap();
        assert!(!input.mouse_reporting().unwrap());
        let release = input
            .encode_mouse(
                MouseEvent {
                    action: MouseAction::Release,
                    button: MouseButton::Left,
                    modifiers: 0,
                    x: 25.0,
                    y: 33.0,
                },
                &mut output,
            )
            .unwrap();
        let release = written(release, &output);
        assert!(release.starts_with(b"\x1b[<0;"));
        assert!(release.ends_with(b"m"));
    }

    #[test]
    fn focus_and_committed_text_are_mode_aware() {
        let mut terminal = Terminal::new(Config::default()).unwrap();
        let mut input = terminal.input(InputConfig::default()).unwrap();
        let mut output = [0u8; 32];
        assert_eq!(
            input.encode_focus(true, &mut output).unwrap(),
            EncodeOutcome::Written(0)
        );
        input.feed(b"\x1b[?1004h").unwrap();
        let focus = input.encode_focus(true, &mut output).unwrap();
        assert_eq!(written(focus, &output), b"\x1b[I");
        let text = input
            .encode_committed_text("한글".as_bytes(), &mut output)
            .unwrap();
        assert_eq!(written(text, &output), "한글".as_bytes());
        assert_eq!(
            input.encode_committed_text(b"bad\x1b", &mut output),
            Err(Error::InvalidArgument)
        );
    }

    #[test]
    fn selection_gesture_installs_copies_cancels_and_enforces_cap() {
        let mut terminal = Terminal::new(Config {
            columns: 20,
            rows: 4,
            ..Config::default()
        })
        .unwrap();
        terminal.feed(b"hello world\r\nsecond line").unwrap();
        let mut selection = terminal.selection(SelectionConfig::default()).unwrap();
        let start = SelectionPoint {
            column: 0,
            row: 0,
            surface_x: 2.0,
            surface_y: 8.0,
            time_ns: Some(1),
        };
        assert_eq!(selection.begin(start).unwrap(), SelectionOutcome::NoValue);
        let geometry = SelectionGeometry {
            columns: 20,
            cell_width: 10.0,
            padding_left: 0.0,
            screen_height: 40.0,
        };
        let end = SelectionPoint {
            column: 4,
            row: 0,
            surface_x: 46.0,
            surface_y: 8.0,
            time_ns: None,
        };
        assert_eq!(
            selection.update(end, geometry, false).unwrap(),
            SelectionOutcome::Selection
        );
        let mut output = [0u8; 64];
        assert_eq!(
            selection.copy(&mut output).unwrap(),
            SelectionCopyOutcome::Written(5)
        );
        assert_eq!(&output[..5], b"hello");
        assert_eq!(selection.end(Some(end)).unwrap(), SelectionOutcome::NoValue);
        selection.cancel().unwrap();
        assert_eq!(
            selection.copy(&mut output).unwrap(),
            SelectionCopyOutcome::NoSelection
        );
        let mut capped = terminal
            .selection(SelectionConfig {
                copy_max_bytes: 2,
                ..SelectionConfig::default()
            })
            .unwrap();
        capped.begin(start).unwrap();
        capped.update(end, geometry, false).unwrap();
        assert_eq!(
            capped.copy(&mut output).unwrap(),
            SelectionCopyOutcome::BufferTooSmall { required: 5 }
        );
    }

    #[test]
    fn input_context_creation_oom_is_reported_without_leaking() {
        let base = Config::default();
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
        assert!(matches!(
            terminal.input(InputConfig::default()),
            Err(Error::OutOfMemory)
        ));
        assert!(terminal.memory_info().unwrap().allocation_failures > 0);
    }

    #[test]
    fn terminal_rebind_uses_a_fresh_mouse_dedupe_owner() {
        let geometry = MouseGeometry {
            screen_width: 800.0,
            screen_height: 600.0,
            cell_width: 8.0,
            cell_height: 16.0,
            padding_top: 0.0,
            padding_bottom: 0.0,
            padding_right: 0.0,
            padding_left: 0.0,
        };
        let motion = MouseEvent {
            action: MouseAction::Motion,
            button: MouseButton::None,
            modifiers: 0,
            x: 17.0,
            y: 17.0,
        };
        let mut old = Terminal::new(Config::default()).unwrap();
        {
            let mut input = old.input(InputConfig::default()).unwrap();
            input.feed(b"\x1b[?1003h\x1b[?1006h").unwrap();
            input.set_mouse_geometry(geometry).unwrap();
            let mut output = [0u8; 32];
            assert!(matches!(
                input.encode_mouse(motion, &mut output).unwrap(),
                EncodeOutcome::Written(length) if length > 0
            ));
            assert_eq!(
                input.encode_mouse(motion, &mut output).unwrap(),
                EncodeOutcome::Written(0)
            );
        }
        let mut projection = old
            .try_into_owned_render()
            .unwrap_or_else(|_| unreachable!());
        let mut candidate = Terminal::new(Config::default()).unwrap();
        candidate.feed(b"\x1b[?1003h\x1b[?1006h").unwrap();
        let returned_old = projection
            .replace_terminal(candidate)
            .unwrap_or_else(|_| unreachable!());
        drop(returned_old);
        let mut input = projection
            .try_terminal_mut()
            .unwrap()
            .input(InputConfig::default())
            .unwrap();
        input.set_mouse_geometry(geometry).unwrap();
        let mut output = [0u8; 32];
        assert!(matches!(
            input.encode_mouse(motion, &mut output).unwrap(),
            EncodeOutcome::Written(length) if length > 0
        ));
    }
}
