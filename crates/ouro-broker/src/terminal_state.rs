//! Bootstrap canonical terminal recovery.
//!
//! The PTY byte stream is parsed once in the broker with the established
//! `vt100`/`vte` parser. Recovery snapshots are generated from terminal state,
//! never from a truncated byte tail. Live bytes remain byte-for-byte exact,
//! but are framed only at parser-neutral UTF-8/ECMA-48 boundaries so a newly
//! attached renderer never receives a continuation without its prefix.
//!
//! This is intentionally a bootstrap lane. `vt100` does not model Kitty
//! graphics, sixel, or every Ghostty extension. Production promotion requires
//! the public libghostty-vt conformance gate described in RFC 0002.

use std::fmt;

pub const SNAPSHOT_FORMAT: &str = "ansi_replay";
pub const SNAPSHOT_SCOPE: &str = "viewport";
pub const SNAPSHOT_VERSION: u16 = 1;
const MAX_CANONICAL_CELLS: usize = 1_000_000;
const WORST_REPLAY_BYTES_PER_CELL: usize = 64;
const SNAPSHOT_FIXED_OVERHEAD: usize = 8 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CanonicalSnapshot {
    pub format: &'static str,
    /// Version 1 restores the visible grids only; it does not claim canonical
    /// scrollback recovery.
    pub scope: &'static str,
    pub snapshot_version: u16,
    pub rows: u16,
    pub columns: u16,
    pub cursor_row: u16,
    pub cursor_column: u16,
    pub alternate_screen: bool,
    pub parser_errors: usize,
    pub replay: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RecoveryFrame {
    /// Exact PTY bytes ending at a parser-neutral boundary.
    Raw(Vec<u8>),
    /// An oversized unterminated control string was dropped. Consumers must
    /// reset and replay this canonical state before accepting another frame.
    Resync(CanonicalSnapshot),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CanonicalStateError {
    InvalidDimensions,
    DimensionsTooLarge { cells: usize, limit: usize },
    SnapshotTooLarge { bytes: usize, limit: usize },
}

impl fmt::Display for CanonicalStateError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidDimensions => formatter.write_str("terminal dimensions must be non-zero"),
            Self::DimensionsTooLarge { cells, limit } => {
                write!(
                    formatter,
                    "terminal has {cells} cells; canonical limit is {limit}"
                )
            }
            Self::SnapshotTooLarge { bytes, limit } => {
                write!(
                    formatter,
                    "canonical snapshot is {bytes} bytes; limit is {limit}"
                )
            }
        }
    }
}

impl std::error::Error for CanonicalStateError {}

/// Broker-owned terminal parser plus a bounded lossless raw-frame fence.
pub struct CanonicalTerminalState {
    parser: vt100::Parser,
    saved_main_screen: Option<vt100::Screen>,
    boundary: StreamBoundary,
    pending_raw: Vec<u8>,
    pending_was_dropped: bool,
    parser_sequence_aborted: bool,
    max_pending_raw_bytes: usize,
    max_snapshot_bytes: usize,
    rows: u16,
    columns: u16,
    scrollback_lines: usize,
}

impl CanonicalTerminalState {
    pub fn new(
        rows: u16,
        columns: u16,
        scrollback_lines: usize,
        max_snapshot_bytes: usize,
        max_pending_raw_bytes: usize,
    ) -> Result<Self, CanonicalStateError> {
        Self::validate_snapshot_capacity(rows, columns, max_snapshot_bytes, max_pending_raw_bytes)?;
        Ok(Self {
            parser: vt100::Parser::new(rows, columns, scrollback_lines),
            saved_main_screen: None,
            boundary: StreamBoundary::default(),
            pending_raw: Vec::new(),
            pending_was_dropped: false,
            parser_sequence_aborted: false,
            max_pending_raw_bytes,
            max_snapshot_bytes,
            rows,
            columns,
            scrollback_lines,
        })
    }

    /// Parse PTY bytes and return only frames safe for a fresh terminal parser.
    /// Partial UTF-8 and escape/control strings stay broker-owned until their
    /// terminator arrives. Memory remains bounded even for a hostile OSC/DCS.
    pub fn process(&mut self, bytes: &[u8]) -> Result<Vec<RecoveryFrame>, CanonicalStateError> {
        let mut frames = Vec::new();
        let mut last_safe_len = 0;

        for &byte in bytes {
            if !self.pending_was_dropped {
                if self.pending_raw.len() < self.max_pending_raw_bytes {
                    self.pending_raw.push(byte);
                } else {
                    self.pending_raw.clear();
                    self.pending_was_dropped = true;
                    self.parser.process(&[0x18]);
                    self.parser_sequence_aborted = true;
                    last_safe_len = 0;
                }
            }

            if !self.parser_sequence_aborted {
                let was_alternate = self.parser.screen().alternate_screen();
                let main_before_enter =
                    if !was_alternate && self.boundary.is_private_mode_set_final(byte) {
                        Some(self.parser.screen().clone())
                    } else {
                        None
                    };
                self.parser.process(std::slice::from_ref(&byte));
                let is_alternate = self.parser.screen().alternate_screen();
                if !was_alternate && is_alternate {
                    self.saved_main_screen = main_before_enter;
                } else if was_alternate && !is_alternate {
                    self.saved_main_screen = None;
                }
            }

            self.boundary.advance(byte);
            if self.boundary.is_safe() {
                if self.pending_was_dropped {
                    self.parser_sequence_aborted = false;
                    frames.push(RecoveryFrame::Resync(self.snapshot()?));
                    self.pending_was_dropped = false;
                    self.pending_raw.clear();
                    last_safe_len = 0;
                } else {
                    last_safe_len = self.pending_raw.len();
                }
            }
        }

        if last_safe_len > 0 {
            let unsafe_suffix = self.pending_raw.split_off(last_safe_len);
            let safe_prefix = std::mem::replace(&mut self.pending_raw, unsafe_suffix);
            frames.push(RecoveryFrame::Raw(safe_prefix));
        }
        Ok(frames)
    }

    /// Produce an ANSI replay of the visible viewport, modes, title,
    /// attributes, and cursor state. In alternate-screen mode both the
    /// inactive main viewport and the active alternate grid are reconstructed
    /// so a later `1049l` restores the correct main screen. Scrollback is not
    /// part of snapshot version 1.
    pub fn snapshot(&self) -> Result<CanonicalSnapshot, CanonicalStateError> {
        let screen = self.parser.screen();
        let mut replay = Vec::new();
        if screen.alternate_screen() {
            if let Some(main) = &self.saved_main_screen {
                replay.extend(main.state_formatted());
            }
            replay.extend_from_slice(b"\x1b[?1049h");
        }
        replay.extend(screen.state_formatted());
        if replay.len() > self.max_snapshot_bytes {
            return Err(CanonicalStateError::SnapshotTooLarge {
                bytes: replay.len(),
                limit: self.max_snapshot_bytes,
            });
        }
        let (cursor_row, cursor_column) = screen.cursor_position();
        Ok(CanonicalSnapshot {
            format: SNAPSHOT_FORMAT,
            scope: SNAPSHOT_SCOPE,
            snapshot_version: SNAPSHOT_VERSION,
            rows: self.rows,
            columns: self.columns,
            cursor_row,
            cursor_column,
            alternate_screen: screen.alternate_screen(),
            parser_errors: screen.errors(),
            replay,
        })
    }

    pub fn resize(&mut self, rows: u16, columns: u16) -> Result<(), CanonicalStateError> {
        Self::validate_snapshot_capacity(
            rows,
            columns,
            self.max_snapshot_bytes,
            self.max_pending_raw_bytes,
        )?;
        self.parser.set_size(rows, columns);
        if let Some(main) = self.saved_main_screen.take() {
            // `vt100::Screen::set_size` is private. Replaying into a temporary
            // parser gives the inactive main grid the same deterministic resize
            // semantics a newly attached renderer will use.
            let mut resized = vt100::Parser::new(rows, columns, self.scrollback_lines);
            resized.process(&main.state_formatted());
            self.saved_main_screen = Some(resized.screen().clone());
        }
        self.rows = rows;
        self.columns = columns;
        Ok(())
    }

    pub fn screen(&self) -> &vt100::Screen {
        self.parser.screen()
    }

    pub fn pending_raw_bytes(&self) -> usize {
        self.pending_raw.len()
    }

    pub fn validate_dimensions(rows: u16, columns: u16) -> Result<(), CanonicalStateError> {
        if rows == 0 || columns == 0 {
            return Err(CanonicalStateError::InvalidDimensions);
        }
        let cells = usize::from(rows).saturating_mul(usize::from(columns));
        if cells > MAX_CANONICAL_CELLS {
            return Err(CanonicalStateError::DimensionsTooLarge {
                cells,
                limit: MAX_CANONICAL_CELLS,
            });
        }
        Ok(())
    }

    pub fn validate_snapshot_capacity(
        rows: u16,
        columns: u16,
        max_snapshot_bytes: usize,
        max_pending_raw_bytes: usize,
    ) -> Result<(), CanonicalStateError> {
        Self::validate_dimensions(rows, columns)?;
        // Alternate recovery contains both visible grids. The per-cell bound
        // covers a four-byte scalar plus a conservative SGR/cursor diff.
        let cells = usize::from(rows).saturating_mul(usize::from(columns));
        let required = cells
            .saturating_mul(2)
            .saturating_mul(WORST_REPLAY_BYTES_PER_CELL)
            .saturating_add(max_pending_raw_bytes)
            .saturating_add(SNAPSHOT_FIXED_OVERHEAD);
        if required > max_snapshot_bytes {
            return Err(CanonicalStateError::SnapshotTooLarge {
                bytes: required,
                limit: max_snapshot_bytes,
            });
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
enum EscapeState {
    #[default]
    Ground,
    Escape,
    Csi {
        private: bool,
    },
    Osc,
    OscEscape,
    String,
    StringEscape,
}

/// A lexical fence, not a second terminal emulator. Canonical semantics come
/// solely from `vt100`; this tracks when raw bytes can safely start in a fresh
/// renderer without depending on parser state from an earlier frame.
#[derive(Clone, Copy, Debug, Default)]
struct StreamBoundary {
    escape: EscapeState,
    utf8_continuations: u8,
}

impl StreamBoundary {
    fn is_safe(self) -> bool {
        self.escape == EscapeState::Ground && self.utf8_continuations == 0
    }

    fn is_private_mode_set_final(self, byte: u8) -> bool {
        matches!(self.escape, EscapeState::Csi { private: true }) && byte == b'h'
    }

    fn advance(&mut self, byte: u8) {
        if self.utf8_continuations > 0 {
            if byte & 0b1100_0000 == 0b1000_0000 {
                self.utf8_continuations -= 1;
                return;
            }
            // Invalid UTF-8 ends the old scalar. Re-evaluate this byte as a
            // fresh control/printable byte, matching vte's fail-closed parser.
            self.utf8_continuations = 0;
        }

        match self.escape {
            EscapeState::Ground => match byte {
                0x1b => self.escape = EscapeState::Escape,
                0xc2..=0xdf => self.utf8_continuations = 1,
                0xe0..=0xef => self.utf8_continuations = 2,
                0xf0..=0xf4 => self.utf8_continuations = 3,
                _ => {}
            },
            EscapeState::Escape => match byte {
                b'[' => self.escape = EscapeState::Csi { private: false },
                b']' => self.escape = EscapeState::Osc,
                b'P' | b'X' | b'^' | b'_' => self.escape = EscapeState::String,
                0x1b => {}
                0x20..=0x2f => {}
                _ => self.escape = EscapeState::Ground,
            },
            EscapeState::Csi { private } => match byte {
                0x18 | 0x1a => self.escape = EscapeState::Ground,
                0x1b => self.escape = EscapeState::Escape,
                b'?' if !private => self.escape = EscapeState::Csi { private: true },
                0x40..=0x7e => self.escape = EscapeState::Ground,
                _ => {}
            },
            EscapeState::Osc => match byte {
                0x07 | 0x18 | 0x1a => self.escape = EscapeState::Ground,
                0x1b => self.escape = EscapeState::OscEscape,
                _ => {}
            },
            EscapeState::OscEscape => match byte {
                b'\\' | 0x18 | 0x1a => self.escape = EscapeState::Ground,
                0x1b => {}
                _ => self.escape = EscapeState::Osc,
            },
            EscapeState::String => match byte {
                0x18 | 0x1a => self.escape = EscapeState::Ground,
                0x1b => self.escape = EscapeState::StringEscape,
                _ => {}
            },
            EscapeState::StringEscape => match byte {
                b'\\' | 0x18 | 0x1a => self.escape = EscapeState::Ground,
                0x1b => {}
                _ => self.escape = EscapeState::String,
            },
        }
    }
}
