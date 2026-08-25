use super::{result, Error, Terminal, TERMINAL_ENGINE_ABI_VERSION};
use std::ffi::c_void;

const SCROLL_VIEWPORT_TOP: i32 = 0;
const SCROLL_VIEWPORT_BOTTOM: i32 = 1;
const SCROLL_VIEWPORT_DELTA: i32 = 2;
const SCROLL_VIEWPORT_ROW: i32 = 3;

#[repr(C)]
struct RawScrollViewport {
    size: usize,
    abi_version: u32,
    kind: i32,
    delta: i64,
    row: u64,
}

#[repr(C)]
struct RawScrollbar {
    size: usize,
    abi_version: u32,
    total: u64,
    offset: u64,
    length: u64,
}

extern "C" {
    fn ouro_terminal_scroll_viewport(
        terminal: *mut c_void,
        viewport: *const RawScrollViewport,
    ) -> i32;
    fn ouro_terminal_scrollbar(terminal: *mut c_void, out: *mut RawScrollbar) -> i32;
}

/// A viewport movement over retained terminal rows.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ViewportScroll {
    Top,
    Bottom,
    /// Relative rows; negative moves toward older history.
    Delta(i64),
    /// Absolute top-origin row offset in the scrollbar's row space.
    Row(u64),
}

impl ViewportScroll {
    fn raw(self) -> Result<RawScrollViewport, Error> {
        let (kind, delta, row) = match self {
            Self::Top => (SCROLL_VIEWPORT_TOP, 0, 0),
            Self::Bottom => (SCROLL_VIEWPORT_BOTTOM, 0, 0),
            Self::Delta(delta) => {
                if isize::try_from(delta).is_err() {
                    return Err(Error::InvalidArgument);
                }
                (SCROLL_VIEWPORT_DELTA, delta, 0)
            }
            Self::Row(row) => {
                if usize::try_from(row).is_err() {
                    return Err(Error::InvalidArgument);
                }
                (SCROLL_VIEWPORT_ROW, 0, row)
            }
        };
        Ok(RawScrollViewport {
            size: std::mem::size_of::<RawScrollViewport>(),
            abi_version: TERMINAL_ENGINE_ABI_VERSION,
            kind,
            delta,
            row,
        })
    }
}

/// Current dimensions and absolute position of the visible viewport.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Scrollbar {
    /// Total retained rows, including the visible area.
    pub total: u64,
    /// Top-origin row offset of the first visible row.
    pub offset: u64,
    /// Number of visible rows.
    pub length: u64,
}

impl Scrollbar {
    /// Largest valid absolute viewport offset.
    pub fn max_offset(self) -> u64 {
        self.total.saturating_sub(self.length)
    }
}

impl Terminal {
    /// Moves the viewport. Absolute and relative requests are clamped by the
    /// engine so the visible range remains within retained rows.
    pub fn scroll_viewport(&mut self, viewport: ViewportScroll) -> Result<(), Error> {
        let raw = viewport.raw()?;
        // SAFETY: raw has the exact versioned C layout and &mut self serializes
        // this synchronous viewport mutation with every other terminal call.
        result(unsafe { ouro_terminal_scroll_viewport(self.raw.as_ptr(), &raw) })
    }

    /// Polls the viewport state. This allocates nothing and retains no callback.
    pub fn scrollbar(&self) -> Result<Scrollbar, Error> {
        let mut raw = RawScrollbar {
            size: std::mem::size_of::<RawScrollbar>(),
            abi_version: TERMINAL_ENGINE_ABI_VERSION,
            total: 0,
            offset: 0,
            length: 0,
        };
        // SAFETY: raw is a correctly sized writable output value and this call
        // only observes serialized terminal viewport state.
        result(unsafe { ouro_terminal_scrollbar(self.raw.as_ptr(), &mut raw) })?;
        if raw.length > raw.total || raw.offset > raw.total - raw.length {
            return Err(Error::Engine);
        }
        Ok(Scrollbar {
            total: raw.total,
            offset: raw.offset,
            length: raw.length,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Config, RenderProjection};

    fn visible_text(projection: &mut RenderProjection<'_>) -> String {
        projection.force_full().unwrap();
        let mut frame = projection.begin().unwrap();
        let mut bytes = Vec::new();
        let mut scratch = Vec::new();
        while frame.next_row().unwrap().is_some() {
            while let Some(cell) = frame.next_cell_into(&mut scratch).unwrap() {
                bytes.extend_from_slice(cell.grapheme);
            }
            bytes.push(b'\n');
        }
        frame.commit_cpu_cache().unwrap();
        String::from_utf8(bytes).unwrap()
    }

    #[test]
    fn raw_viewport_and_scrollbar_layouts_match_lp64_c_abi() {
        #[cfg(target_pointer_width = "64")]
        {
            assert_eq!(std::mem::size_of::<RawScrollViewport>(), 32);
            assert_eq!(std::mem::size_of::<RawScrollbar>(), 40);
        }
    }

    #[test]
    fn viewport_round_trips_absolute_rows_and_clamps() {
        let mut terminal = Terminal::new(Config {
            columns: 12,
            rows: 4,
            ..Config::default()
        })
        .unwrap();
        for line in 0..24 {
            terminal
                .feed(format!("history-{line:02}\r\n").as_bytes())
                .unwrap();
        }

        let bottom = terminal.scrollbar().unwrap();
        assert_eq!(bottom.length, 4);
        assert!(bottom.total > bottom.length);
        assert_eq!(bottom.offset, bottom.max_offset());
        let snapshot_at_bottom = terminal.snapshot().unwrap();

        terminal.scroll_viewport(ViewportScroll::Top).unwrap();
        assert_eq!(terminal.scrollbar().unwrap().offset, 0);
        assert_eq!(terminal.snapshot().unwrap(), snapshot_at_bottom);

        terminal.scroll_viewport(ViewportScroll::Delta(2)).unwrap();
        assert_eq!(terminal.scrollbar().unwrap().offset, 2);
        terminal.scroll_viewport(ViewportScroll::Delta(-1)).unwrap();
        assert_eq!(terminal.scrollbar().unwrap().offset, 1);

        terminal
            .scroll_viewport(ViewportScroll::Row(u64::MAX))
            .unwrap();
        assert_eq!(terminal.scrollbar().unwrap().offset, bottom.max_offset());
        terminal.scroll_viewport(ViewportScroll::Row(3)).unwrap();
        assert_eq!(terminal.scrollbar().unwrap().offset, 3);

        terminal.scroll_viewport(ViewportScroll::Bottom).unwrap();
        assert_eq!(terminal.scrollbar().unwrap().offset, bottom.max_offset());
    }

    #[test]
    fn alternate_screen_has_no_scrollback_viewport() {
        let mut terminal = Terminal::new(Config {
            columns: 12,
            rows: 4,
            ..Config::default()
        })
        .unwrap();
        for line in 0..12 {
            terminal
                .feed(format!("history-{line:02}\r\n").as_bytes())
                .unwrap();
        }
        terminal.feed(b"\x1b[?1049halternate").unwrap();
        terminal.scroll_viewport(ViewportScroll::Top).unwrap();
        let alternate = terminal.scrollbar().unwrap();
        assert_eq!(alternate.total, alternate.length);
        assert_eq!(alternate.offset, 0);
        assert_eq!(alternate.max_offset(), 0);
    }

    #[test]
    fn render_projection_reads_the_selected_viewport() {
        let mut terminal = Terminal::new(Config {
            columns: 16,
            rows: 4,
            ..Config::default()
        })
        .unwrap();
        for line in 0..12 {
            terminal
                .feed(format!("history-{line:02}\r\n").as_bytes())
                .unwrap();
        }

        let mut projection = terminal.render_projection().unwrap();
        let bottom = visible_text(&mut projection);
        assert!(bottom.contains("history-11"));
        assert!(!bottom.contains("history-00"));

        projection
            .terminal_mut()
            .scroll_viewport(ViewportScroll::Top)
            .unwrap();
        let top = visible_text(&mut projection);
        assert!(top.contains("history-00"));
        assert!(!top.contains("history-11"));
    }
}
