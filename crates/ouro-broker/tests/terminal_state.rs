#[path = "../src/terminal_state.rs"]
mod terminal_state;

use terminal_state::{
    CanonicalTerminalState, RecoveryFrame, SNAPSHOT_FORMAT, SNAPSHOT_SCOPE, SNAPSHOT_VERSION,
};

fn state(rows: u16, columns: u16) -> CanonicalTerminalState {
    CanonicalTerminalState::new(rows, columns, 64, 512 * 1024, 64 * 1024).unwrap()
}

fn replay(snapshot: &terminal_state::CanonicalSnapshot) -> vt100::Parser {
    let mut parser = vt100::Parser::new(snapshot.rows, snapshot.columns, 64);
    parser.process(&snapshot.replay);
    parser
}

fn raw(frames: Vec<RecoveryFrame>) -> Vec<u8> {
    frames
        .into_iter()
        .flat_map(|frame| match frame {
            RecoveryFrame::Raw(bytes) => bytes,
            RecoveryFrame::Resync(snapshot) => snapshot.replay,
        })
        .collect()
}

fn assert_same_visible(expected: &vt100::Screen, actual: &vt100::Screen) {
    assert_eq!(actual.contents(), expected.contents());
    assert_eq!(actual.cursor_position(), expected.cursor_position());
    assert_eq!(actual.alternate_screen(), expected.alternate_screen());
    assert_eq!(actual.application_cursor(), expected.application_cursor());
    assert_eq!(actual.bracketed_paste(), expected.bracketed_paste());
    assert_eq!(actual.hide_cursor(), expected.hide_cursor());
    let (rows, columns) = expected.size();
    for row in 0..rows {
        for column in 0..columns {
            let expected_cell = expected.cell(row, column).unwrap();
            let actual_cell = actual.cell(row, column).unwrap();
            assert_eq!(actual_cell.contents(), expected_cell.contents());
            assert_eq!(actual_cell.fgcolor(), expected_cell.fgcolor());
            assert_eq!(actual_cell.bgcolor(), expected_cell.bgcolor());
            assert_eq!(actual_cell.bold(), expected_cell.bold());
            assert_eq!(actual_cell.italic(), expected_cell.italic());
            assert_eq!(actual_cell.underline(), expected_cell.underline());
            assert_eq!(actual_cell.inverse(), expected_cell.inverse());
        }
    }
}

#[test]
fn utf8_continuation_is_never_emitted_without_its_prefix() {
    let mut terminal = state(4, 20);
    let korean = "한".as_bytes();
    assert!(terminal.process(&korean[..2]).unwrap().is_empty());
    assert_eq!(terminal.pending_raw_bytes(), 2);

    let snapshot = terminal.snapshot().unwrap();
    let mut restored = replay(&snapshot);
    let completion = raw(terminal.process(&korean[2..]).unwrap());
    assert_eq!(completion, korean);
    restored.process(&completion);
    assert_same_visible(terminal.screen(), restored.screen());
}

#[test]
fn csi_and_osc_boundaries_survive_arbitrary_chunking() {
    let mut terminal = state(4, 30);
    assert_eq!(raw(terminal.process(b"base\x1b[3").unwrap()), b"base");
    let snapshot = terminal.snapshot().unwrap();
    let mut restored = replay(&snapshot);

    let csi = raw(terminal.process(b"1;1mRED\x1b]0;hel").unwrap());
    assert_eq!(csi, b"\x1b[31;1mRED");
    restored.process(&csi);
    assert_eq!(terminal.screen().title(), "");

    let osc = raw(terminal.process(b"lo\x07").unwrap());
    assert_eq!(osc, b"\x1b]0;hello\x07");
    restored.process(&osc);
    assert_same_visible(terminal.screen(), restored.screen());
    assert_eq!(restored.screen().title(), "hello");
}

#[test]
fn snapshot_restores_cursor_styles_and_input_modes() {
    let mut terminal = state(6, 24);
    terminal
        .process(b"plain \x1b[38;5;196;1;4mstyled\x1b[3;7H\x1b[?1h\x1b[?2004h\x1b[?25l")
        .unwrap();
    let snapshot = terminal.snapshot().unwrap();
    assert_eq!(snapshot.format, SNAPSHOT_FORMAT);
    assert_eq!(snapshot.scope, SNAPSHOT_SCOPE);
    assert_eq!(snapshot.snapshot_version, SNAPSHOT_VERSION);
    assert_eq!((snapshot.cursor_row, snapshot.cursor_column), (2, 6));
    assert!(!snapshot.replay.is_empty());

    let restored = replay(&snapshot);
    assert_same_visible(terminal.screen(), restored.screen());
}

#[test]
fn alternate_snapshot_preserves_inactive_main_screen() {
    let mut terminal = state(5, 24);
    terminal.process(b"main-screen\x1b[4;5H").unwrap();
    terminal.process(b"\x1b[?1049").unwrap();
    terminal.process(b"hALT\x1b[2;3H").unwrap();
    assert!(terminal.screen().alternate_screen());

    let snapshot = terminal.snapshot().unwrap();
    assert!(snapshot.alternate_screen);
    let mut restored = replay(&snapshot);
    assert_same_visible(terminal.screen(), restored.screen());

    let exit = raw(terminal.process(b"\x1b[?1049l").unwrap());
    restored.process(&exit);
    assert!(!terminal.screen().alternate_screen());
    assert_same_visible(terminal.screen(), restored.screen());
    assert!(restored.screen().contents().contains("main-screen"));
}

#[test]
fn canonical_viewport_recovers_after_far_more_output_than_raw_history() {
    let mut terminal = CanonicalTerminalState::new(4, 20, 2, 32 * 1024, 32).unwrap();
    for index in 0..200 {
        let line = format!("line-{index:03}\r\n");
        let _ = terminal.process(line.as_bytes()).unwrap();
    }
    let snapshot = terminal.snapshot().unwrap();
    assert!(snapshot.replay.len() < 32 * 1024);
    let restored = replay(&snapshot);
    assert_same_visible(terminal.screen(), restored.screen());
    assert!(restored.screen().contents().contains("line-199"));
    assert!(!restored.screen().contents().contains("line-000"));
}

#[test]
fn resize_while_alternate_is_active_preserves_both_grids() {
    let mut terminal = state(5, 24);
    terminal
        .process(b"main-before-resize\x1b[?1049hALT")
        .unwrap();
    terminal.resize(4, 18).unwrap();
    let snapshot = terminal.snapshot().unwrap();
    let mut restored = replay(&snapshot);
    assert_same_visible(terminal.screen(), restored.screen());

    let exit = raw(terminal.process(b"\x1b[?1049l").unwrap());
    restored.process(&exit);
    assert_same_visible(terminal.screen(), restored.screen());
}

#[test]
fn create_and_resize_reject_unrecoverable_snapshot_capacity_before_mutation() {
    assert!(CanonicalTerminalState::new(120, 40, 0, 64 * 1024, 32 * 1024).is_err());

    let mut terminal = state(5, 24);
    let original_size = terminal.screen().size();
    assert!(terminal.resize(1_000, 1_000).is_err());
    assert_eq!(terminal.screen().size(), original_size);
}

#[test]
fn styled_near_limit_viewport_stays_within_prevalidated_snapshot_bound() {
    let mut terminal = CanonicalTerminalState::new(4, 20, 0, 32 * 1024, 32).unwrap();
    for index in 0..80 {
        let style = format!("\x1b[38;2;{};{};{}mX", index, 255 - index, index / 2);
        terminal.process(style.as_bytes()).unwrap();
    }
    let snapshot = terminal.snapshot().unwrap();
    assert!(snapshot.replay.len() < 32 * 1024);
}

#[test]
fn unterminated_control_string_is_bounded_and_resyncs_at_terminator() {
    let mut terminal = CanonicalTerminalState::new(4, 20, 0, 32 * 1024, 32).unwrap();
    let mut hostile = b"\x1b]52;c;".to_vec();
    hostile.extend(std::iter::repeat_n(b'A', 4 * 1024));
    assert!(terminal.process(&hostile).unwrap().is_empty());
    assert!(terminal.pending_raw_bytes() <= 32);

    let frames = terminal.process(b"\x07safe").unwrap();
    assert!(matches!(frames.first(), Some(RecoveryFrame::Resync(_))));
    assert!(matches!(frames.last(), Some(RecoveryFrame::Raw(bytes)) if bytes == b"safe"));
}
