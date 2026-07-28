//! ourocode terminal driver helper.
//!
//! The Elixir runtime stays the single source of truth; this is the seed's
//! replaceable native frontend piece. An escript cannot raw-mode its own
//! terminal (no `tcsetattr` in Elixir; `stty` via :os.cmd has no ctty), and
//! a Port-spawned child has no controlling terminal so `/dev/tty` is not an
//! option either.
//!
//! On Unix, we use the terminal fds the BEAM already holds. Erlang's
//! `:nouse_stdio` port option leaves fds 0/1/2 inherited from the BEAM
//! (the real terminal) and moves the Erlang<->port protocol to fds 3 and 4.
//! termios works on any tty fd whether or not it is the ctty, so the Unix
//! helper sets raw mode directly on fd 0.
//!
//!   * fd 0  terminal input   (keystrokes; raw termios set here)
//!   * fd 1  terminal output  (frames written verbatim)
//!   * fd 3  protocol in      (frames from Elixir)
//!   * fd 4  protocol out     (size header then key byte stream to Elixir)
//!
//! On Windows, Port stdio remains the protocol pipe on fd 0/1. Console input
//! and output are acquired separately through CONIN$/CONOUT$ or real console
//! std handles.
//!
//! Protocol: first thing written to fd 4 is "<cols> <rows>\n"; everything
//! after is the raw key stream. Restores the original termios on exit.

#[cfg(unix)]
mod unix {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::{mem, process, ptr, thread};

    const TTY_IN: libc::c_int = 0;
    const TTY_OUT: libc::c_int = 1;
    const PROTO_IN: libc::c_int = 3;
    const PROTO_OUT: libc::c_int = 4;

    static mut SAVED: Option<libc::termios> = None;
    static RESTORED: AtomicBool = AtomicBool::new(false);

    unsafe fn restore() {
        if RESTORED.swap(true, Ordering::SeqCst) {
            return;
        }
        if let Some(saved) = SAVED {
            libc::tcsetattr(TTY_IN, libc::TCSANOW, &saved);
        }
        let seq = b"\x1b[?25h\x1b[?1049l";
        libc::write(TTY_OUT, seq.as_ptr() as *const libc::c_void, seq.len());
    }

    extern "C" fn on_signal(_sig: libc::c_int) {
        unsafe { restore() };
        process::exit(0);
    }

    fn install_signal(sig: libc::c_int) {
        unsafe {
            let mut sa: libc::sigaction = mem::zeroed();
            sa.sa_sigaction = on_signal as *const () as usize;
            libc::sigemptyset(&mut sa.sa_mask);
            libc::sigaction(sig, &sa, ptr::null_mut());
        }
    }

    fn write_all(fd: libc::c_int, buf: &[u8]) -> bool {
        let mut off = 0usize;
        while off < buf.len() {
            let w = unsafe {
                libc::write(
                    fd,
                    buf.as_ptr().add(off) as *const libc::c_void,
                    buf.len() - off,
                )
            };
            if w <= 0 {
                return false;
            }
            off += w as usize;
        }
        true
    }

    pub fn run() {
        // fd 0 must be a terminal. If not (piped / no tty), bail so Elixir falls
        // back to the plain renderer.
        if unsafe { libc::isatty(TTY_IN) } != 1 {
            process::exit(1);
        }

        unsafe {
            let mut term: libc::termios = mem::zeroed();
            if libc::tcgetattr(TTY_IN, &mut term) != 0 {
                process::exit(1);
            }
            SAVED = Some(term);

            let mut raw = term;
            libc::cfmakeraw(&mut raw);
            libc::tcsetattr(TTY_IN, libc::TCSANOW, &raw);
        }

        for sig in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP, libc::SIGPIPE] {
            install_signal(sig);
        }

        let (cols, rows) = unsafe {
            let mut ws: libc::winsize = mem::zeroed();
            if libc::ioctl(TTY_OUT, libc::TIOCGWINSZ, &mut ws) == 0
                && ws.ws_col > 0
                && ws.ws_row > 0
            {
                (ws.ws_col, ws.ws_row)
            } else {
                (120u16, 40u16)
            }
        };
        write_all(PROTO_OUT, format!("{} {}\n", cols, rows).as_bytes());

        // terminal input -> Elixir
        thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                let n =
                    unsafe { libc::read(TTY_IN, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
                if n <= 0 || !write_all(PROTO_OUT, &buf[..n as usize]) {
                    process::exit(0);
                }
            }
        });

        // Elixir frames -> terminal. EOF means Elixir is done.
        let mut buf = [0u8; 16384];
        loop {
            let n =
                unsafe { libc::read(PROTO_IN, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
            if n <= 0 || !write_all(TTY_OUT, &buf[..n as usize]) {
                break;
            }
        }

        unsafe { restore() };
        process::exit(0);
    }
}

#[cfg(unix)]
fn main() {
    unix::run();
}

#[cfg(windows)]
fn main() {
    windows::run();
}

#[cfg(not(any(unix, windows)))]
fn main() {
    eprintln!("ourocode_tty: unsupported platform; falling back");
    std::process::exit(1);
}

#[cfg(windows)]
mod windows {
    use std::ffi::c_void;
    use std::mem::MaybeUninit;
    use std::process;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::thread;

    use windows_sys::Win32::Foundation::{
        CloseHandle, GENERIC_READ, GENERIC_WRITE, HANDLE, INVALID_HANDLE_VALUE,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        CreateFileW, WriteFile, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
    };
    use windows_sys::Win32::System::Console::{
        AttachConsole, GetConsoleMode, GetConsoleScreenBufferInfo, GetStdHandle, ReadConsoleInputW,
        SetConsoleCtrlHandler, SetConsoleMode, ATTACH_PARENT_PROCESS, CONSOLE_SCREEN_BUFFER_INFO,
        ENABLE_ECHO_INPUT, ENABLE_LINE_INPUT, ENABLE_MOUSE_INPUT, ENABLE_PROCESSED_INPUT,
        ENABLE_VIRTUAL_TERMINAL_INPUT, ENABLE_VIRTUAL_TERMINAL_PROCESSING, ENABLE_WINDOW_INPUT,
        FROM_LEFT_1ST_BUTTON_PRESSED, INPUT_RECORD, KEY_EVENT, MOUSE_EVENT, STD_INPUT_HANDLE,
        STD_OUTPUT_HANDLE, WINDOW_BUFFER_SIZE_EVENT,
    };

    const PROTO_IN: libc::c_int = 0;
    const PROTO_OUT: libc::c_int = 1;
    const CONSOLE_READ_WRITE: u32 = GENERIC_READ | GENERIC_WRITE;

    static RESTORED: AtomicBool = AtomicBool::new(false);
    static mut INPUT_HANDLE: HANDLE = std::ptr::null_mut();
    static mut OUTPUT_HANDLE: HANDLE = std::ptr::null_mut();
    static mut INPUT_MODE: u32 = 0;
    static mut OUTPUT_MODE: u32 = 0;
    static mut CLOSE_INPUT_HANDLE: bool = false;
    static mut CLOSE_OUTPUT_HANDLE: bool = false;

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    enum ConsoleDevice {
        Input,
        Output,
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    enum ConsoleHandleCandidate {
        NamedConsole { name: &'static str, access: u32 },
        StdHandle(u32),
    }

    struct AcquiredConsoleHandle {
        handle: HANDLE,
        close_on_restore: bool,
    }

    enum WindowsConsoleEvent {
        Key(WindowsKeyEvent),
        Resize(WindowsResizeEvent),
        Mouse(WindowsMouseEvent),
    }

    struct WindowsKeyEvent {
        key_down: bool,
        unicode_char: Option<char>,
    }

    struct WindowsResizeEvent {
        columns: i16,
        rows: i16,
    }

    struct WindowsMouseEvent {
        column: i16,
        row: i16,
        button: MouseButton,
        state: MouseButtonState,
    }

    enum MouseButton {
        Left,
    }

    enum MouseButtonState {
        Pressed,
    }

    struct ConsoleGuard;

    impl Drop for ConsoleGuard {
        fn drop(&mut self) {
            restore();
        }
    }

    fn translate_windows_console_event(event: WindowsConsoleEvent) -> Option<Vec<u8>> {
        match event {
            WindowsConsoleEvent::Key(event) => translate_key_event(event),
            WindowsConsoleEvent::Resize(event) => translate_resize_event(event),
            WindowsConsoleEvent::Mouse(event) => translate_mouse_event(event),
        }
    }

    fn input_record_to_windows_console_event(record: &INPUT_RECORD) -> Option<WindowsConsoleEvent> {
        match u32::from(record.EventType) {
            KEY_EVENT => {
                // SAFETY: Category 8 - FFI boundary union access. Win32 sets
                // EventType to KEY_EVENT only when Event.KeyEvent is the active
                // INPUT_RECORD union field; tests construct the same invariant.
                let event = unsafe { record.Event.KeyEvent };
                // SAFETY: Category 8 - FFI boundary union access. The `W`
                // console APIs document UnicodeChar as the active key char
                // representation for KEY_EVENT_RECORD.
                let unicode = unsafe { event.uChar.UnicodeChar };
                let unicode_char = if unicode == 0 {
                    None
                } else {
                    char::from_u32(u32::from(unicode))
                };

                Some(WindowsConsoleEvent::Key(WindowsKeyEvent {
                    key_down: event.bKeyDown != 0,
                    unicode_char,
                }))
            }
            WINDOW_BUFFER_SIZE_EVENT => {
                // SAFETY: Category 8 - FFI boundary union access. Win32 sets
                // EventType to WINDOW_BUFFER_SIZE_EVENT only when
                // Event.WindowBufferSizeEvent is the active union field.
                let event = unsafe { record.Event.WindowBufferSizeEvent };

                Some(WindowsConsoleEvent::Resize(WindowsResizeEvent {
                    columns: event.dwSize.X,
                    rows: event.dwSize.Y,
                }))
            }
            MOUSE_EVENT => {
                // SAFETY: Category 8 - FFI boundary union access. Win32 sets
                // EventType to MOUSE_EVENT only when Event.MouseEvent is the
                // active INPUT_RECORD union field.
                let event = unsafe { record.Event.MouseEvent };
                if event.dwButtonState & FROM_LEFT_1ST_BUTTON_PRESSED == 0 {
                    return None;
                }

                Some(WindowsConsoleEvent::Mouse(WindowsMouseEvent {
                    column: event.dwMousePosition.X,
                    row: event.dwMousePosition.Y,
                    button: MouseButton::Left,
                    state: MouseButtonState::Pressed,
                }))
            }
            _ => None,
        }
    }

    fn translate_key_event(event: WindowsKeyEvent) -> Option<Vec<u8>> {
        if !event.key_down {
            return None;
        }

        event.unicode_char.map(|ch| {
            let mut encoded = [0u8; 4];
            ch.encode_utf8(&mut encoded).as_bytes().to_vec()
        })
    }

    fn translate_resize_event(event: WindowsResizeEvent) -> Option<Vec<u8>> {
        if event.columns <= 0 || event.rows <= 0 {
            return None;
        }

        Some(
            format!(
                "\x1b]777;ourocode-resize={}x{}\x07",
                event.columns, event.rows
            )
            .into_bytes(),
        )
    }

    fn translate_mouse_event(event: WindowsMouseEvent) -> Option<Vec<u8>> {
        if event.column < 0 || event.row < 0 {
            return None;
        }

        let button_code = match event.button {
            MouseButton::Left => 0,
        };
        let suffix = match event.state {
            MouseButtonState::Pressed => 'M',
        };
        let column = i32::from(event.column) + 1;
        let row = i32::from(event.row) + 1;

        Some(format!("\x1b[<{button_code};{column};{row}{suffix}").into_bytes())
    }

    fn restore() {
        if RESTORED.swap(true, Ordering::SeqCst) {
            return;
        }

        // SAFETY: Category 8 - FFI boundary. The handles and modes are copied
        // from successful GetStdHandle/GetConsoleMode calls during setup and
        // never mutated after the control handler is installed.
        unsafe {
            if !INPUT_HANDLE.is_null() && INPUT_HANDLE != INVALID_HANDLE_VALUE {
                SetConsoleMode(INPUT_HANDLE, INPUT_MODE);
            }
            if !OUTPUT_HANDLE.is_null() && OUTPUT_HANDLE != INVALID_HANDLE_VALUE {
                SetConsoleMode(OUTPUT_HANDLE, OUTPUT_MODE);
            }

            let _ = write_console(b"\x1b[?25h\x1b[?1049l");

            if CLOSE_INPUT_HANDLE && !INPUT_HANDLE.is_null() && INPUT_HANDLE != INVALID_HANDLE_VALUE
            {
                CloseHandle(INPUT_HANDLE);
                CLOSE_INPUT_HANDLE = false;
            }
            if CLOSE_OUTPUT_HANDLE
                && !OUTPUT_HANDLE.is_null()
                && OUTPUT_HANDLE != INVALID_HANDLE_VALUE
            {
                CloseHandle(OUTPUT_HANDLE);
                CLOSE_OUTPUT_HANDLE = false;
            }
        }
    }

    unsafe extern "system" fn on_console_ctrl(_ctrl_type: u32) -> i32 {
        restore();
        0
    }

    fn exit_after_restore(code: i32) -> ! {
        restore();
        process::exit(code);
    }

    fn write_proto(buf: &[u8]) -> bool {
        let mut off = 0usize;
        while off < buf.len() {
            let remaining = buf.len() - off;
            let chunk = remaining.min(i32::MAX as usize);
            let written = unsafe {
                libc::write(
                    PROTO_OUT,
                    buf.as_ptr().add(off) as *const c_void,
                    chunk as libc::c_uint,
                )
            };
            if written <= 0 {
                return false;
            }
            off += written as usize;
        }
        true
    }

    fn read_proto(buf: &mut [u8]) -> isize {
        (unsafe {
            libc::read(
                PROTO_IN,
                buf.as_mut_ptr() as *mut c_void,
                buf.len() as libc::c_uint,
            )
        }) as isize
    }

    fn write_console(buf: &[u8]) -> bool {
        let handle = unsafe { OUTPUT_HANDLE };
        if handle.is_null() || handle == INVALID_HANDLE_VALUE {
            return false;
        }

        let mut off = 0usize;
        while off < buf.len() {
            let chunk = (buf.len() - off).min(u32::MAX as usize);
            let mut written = 0u32;
            let ok = unsafe {
                WriteFile(
                    handle,
                    buf.as_ptr().add(off),
                    chunk as u32,
                    &mut written,
                    std::ptr::null_mut(),
                )
            };
            if ok == 0 || written == 0 {
                return false;
            }
            off += written as usize;
        }
        true
    }

    fn read_console_event() -> Result<Option<WindowsConsoleEvent>, ()> {
        let mut record = MaybeUninit::<INPUT_RECORD>::uninit();
        // SAFETY: Category 8 - FFI boundary. INPUT_HANDLE is written once from
        // GetStdHandle during setup before the input thread starts, then only
        // read by this function and restore/control-handler code.
        let handle = unsafe { INPUT_HANDLE };
        if handle.is_null() || handle == INVALID_HANDLE_VALUE {
            return Err(());
        }

        let mut read = 0u32;
        // SAFETY: Category 8 - FFI boundary. `record` points to writable
        // storage for one INPUT_RECORD, `read` points to writable u32 storage,
        // and `handle` was validated against null/INVALID_HANDLE_VALUE above.
        let ok = unsafe { ReadConsoleInputW(handle, record.as_mut_ptr(), 1, &mut read) };
        if ok == 0 {
            Err(())
        } else if read == 0 {
            Ok(None)
        } else {
            // SAFETY: Category 4 - uninitialized memory. ReadConsoleInputW
            // returned success and reported one record read, so it initialized
            // the INPUT_RECORD storage before this assume_init.
            let record = unsafe { record.assume_init() };
            Ok(input_record_to_windows_console_event(&record))
        }
    }

    fn terminal_size() -> (i16, i16) {
        unsafe {
            let mut info: CONSOLE_SCREEN_BUFFER_INFO = std::mem::zeroed();
            if GetConsoleScreenBufferInfo(OUTPUT_HANDLE, &mut info) != 0 {
                let cols = info.srWindow.Right - info.srWindow.Left + 1;
                let rows = info.srWindow.Bottom - info.srWindow.Top + 1;
                if cols > 0 && rows > 0 {
                    return (cols, rows);
                }
            }
        }

        (120, 40)
    }

    fn wide_null(value: &str) -> Vec<u16> {
        value.encode_utf16().chain(std::iter::once(0)).collect()
    }

    const fn console_handle_candidates(device: ConsoleDevice) -> [ConsoleHandleCandidate; 2] {
        match device {
            ConsoleDevice::Input => [
                ConsoleHandleCandidate::NamedConsole {
                    name: "CONIN$",
                    access: CONSOLE_READ_WRITE,
                },
                ConsoleHandleCandidate::StdHandle(STD_INPUT_HANDLE),
            ],
            ConsoleDevice::Output => [
                ConsoleHandleCandidate::NamedConsole {
                    name: "CONOUT$",
                    access: CONSOLE_READ_WRITE,
                },
                ConsoleHandleCandidate::StdHandle(STD_OUTPUT_HANDLE),
            ],
        }
    }

    fn acquire_console_handle(device: ConsoleDevice) -> Option<AcquiredConsoleHandle> {
        for candidate in console_handle_candidates(device) {
            if let Some(handle) = acquire_console_handle_candidate(candidate) {
                return Some(handle);
            }
        }

        None
    }

    fn acquire_console_handle_candidate(
        candidate: ConsoleHandleCandidate,
    ) -> Option<AcquiredConsoleHandle> {
        let (handle, close_on_restore) = match candidate {
            ConsoleHandleCandidate::NamedConsole { name, access } => {
                let name = wide_null(name);
                // SAFETY: Category 8 - FFI boundary. The UTF-16 name buffer is
                // null-terminated and lives for the duration of CreateFileW;
                // remaining pointers are null because no security attributes,
                // template file, or overlapped I/O are requested.
                let handle = unsafe {
                    CreateFileW(
                        name.as_ptr(),
                        access,
                        FILE_SHARE_READ | FILE_SHARE_WRITE,
                        std::ptr::null_mut(),
                        OPEN_EXISTING,
                        0,
                        std::ptr::null_mut(),
                    )
                };
                (handle, true)
            }
            ConsoleHandleCandidate::StdHandle(kind) => {
                // SAFETY: Category 8 - FFI boundary. `kind` is one of the
                // Win32 STD_* constants produced by console_handle_candidates.
                let handle = unsafe { GetStdHandle(kind) };
                (handle, false)
            }
        };

        if handle.is_null() || handle == INVALID_HANDLE_VALUE {
            return None;
        }

        let mut mode = 0u32;
        // SAFETY: Category 8 - FFI boundary. `handle` was checked against null
        // and INVALID_HANDLE_VALUE, and `mode` points to writable stack storage.
        if unsafe { GetConsoleMode(handle, &mut mode) } == 0 {
            if close_on_restore {
                // SAFETY: Category 8 - FFI boundary. This closes only handles
                // opened by CreateFileW in this function and not shared std handles.
                unsafe {
                    CloseHandle(handle);
                }
            }
            return None;
        }

        Some(AcquiredConsoleHandle {
            handle,
            close_on_restore,
        })
    }

    fn setup_console() -> Option<ConsoleGuard> {
        // SAFETY: Category 8 - FFI boundary. Each Win32 call receives either
        // valid output pointers to stack locals or acquired console handles
        // checked before mode calls; saved modes are restored on every failure
        // path after mutation.
        unsafe {
            // SAFETY: Category 8 - FFI boundary. Attaching to the parent console
            // is best-effort; it fails harmlessly when the process is already
            // attached, and the subsequent CONIN$/CONOUT$ probes decide support.
            let _ = AttachConsole(ATTACH_PARENT_PROCESS);

            let input_handle = acquire_console_handle(ConsoleDevice::Input)?;
            let output_handle = acquire_console_handle(ConsoleDevice::Output)?;
            INPUT_HANDLE = input_handle.handle;
            OUTPUT_HANDLE = output_handle.handle;
            CLOSE_INPUT_HANDLE = input_handle.close_on_restore;
            CLOSE_OUTPUT_HANDLE = output_handle.close_on_restore;

            if INPUT_HANDLE.is_null() || OUTPUT_HANDLE.is_null() {
                return None;
            }

            let mut input_mode = 0u32;
            let mut output_mode = 0u32;
            if GetConsoleMode(INPUT_HANDLE, &mut input_mode) == 0 {
                return None;
            }
            if GetConsoleMode(OUTPUT_HANDLE, &mut output_mode) == 0 {
                return None;
            }

            INPUT_MODE = input_mode;
            OUTPUT_MODE = output_mode;

            let raw_input = (input_mode
                & !(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT))
                | ENABLE_MOUSE_INPUT
                | ENABLE_WINDOW_INPUT
                | ENABLE_VIRTUAL_TERMINAL_INPUT;
            let vt_output = output_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING;

            if SetConsoleMode(INPUT_HANDLE, raw_input) == 0 {
                return None;
            }
            if SetConsoleMode(OUTPUT_HANDLE, vt_output) == 0 {
                SetConsoleMode(INPUT_HANDLE, INPUT_MODE);
                return None;
            }
            // SAFETY: Category 8 - FFI boundary. `on_console_ctrl` has the
            // PHANDLER_ROUTINE ABI/signature required by SetConsoleCtrlHandler
            // and remains valid for the process lifetime.
            if SetConsoleCtrlHandler(Some(on_console_ctrl), 1) == 0 {
                SetConsoleMode(OUTPUT_HANDLE, OUTPUT_MODE);
                SetConsoleMode(INPUT_HANDLE, INPUT_MODE);
                return None;
            }
        }

        Some(ConsoleGuard)
    }

    pub fn run() {
        let _guard = match setup_console() {
            Some(guard) => guard,
            None => process::exit(1),
        };

        let (cols, rows) = terminal_size();
        if !write_proto(format!("{} {}\n", cols, rows).as_bytes()) {
            exit_after_restore(1);
        }

        thread::spawn(move || loop {
            match read_console_event() {
                Ok(Some(event)) => {
                    if let Some(buf) = translate_windows_console_event(event) {
                        if !write_proto(&buf) {
                            exit_after_restore(0);
                        }
                    }
                }
                Ok(None) => {}
                Err(()) => exit_after_restore(0),
            }
        });

        let mut buf = [0u8; 16384];
        loop {
            let n = read_proto(&mut buf);
            if n <= 0 || !write_console(&buf[..n as usize]) {
                break;
            }
        }

        exit_after_restore(0);
    }

    #[cfg(test)]
    mod windows_tty_tests {
        use super::{
            console_handle_candidates, input_record_to_windows_console_event,
            translate_windows_console_event, ConsoleDevice, ConsoleHandleCandidate, MouseButton,
            MouseButtonState, WindowsConsoleEvent, WindowsKeyEvent, WindowsMouseEvent,
            WindowsResizeEvent, PROTO_IN, PROTO_OUT,
        };
        use windows_sys::Win32::Foundation::BOOL;
        use windows_sys::Win32::System::Console::{
            COORD, FOCUS_EVENT, FOCUS_EVENT_RECORD, FROM_LEFT_1ST_BUTTON_PRESSED, INPUT_RECORD,
            INPUT_RECORD_0, KEY_EVENT, KEY_EVENT_RECORD, KEY_EVENT_RECORD_0, MOUSE_EVENT,
            MOUSE_EVENT_RECORD, WINDOW_BUFFER_SIZE_EVENT, WINDOW_BUFFER_SIZE_RECORD,
        };
        use windows_sys::Win32::System::Console::{STD_INPUT_HANDLE, STD_OUTPUT_HANDLE};

        #[test]
        fn windows_tty_uses_port_stdio_for_protocol() {
            // Given: Elixir opens the Windows helper without :nouse_stdio.
            // When: the helper chooses protocol file descriptors.
            // Then: fd 0/1 remain the Port protocol pipe instead of fd 3/4.
            assert_eq!(PROTO_IN, 0);
            assert_eq!(PROTO_OUT, 1);
        }

        #[test]
        fn windows_tty_prefers_named_console_handles_before_std_handles() {
            // Given: Port stdio is reserved for the BEAM protocol pipe.
            let input_candidates = console_handle_candidates(ConsoleDevice::Input);
            let output_candidates = console_handle_candidates(ConsoleDevice::Output);

            // When: the helper looks for real console I/O handles.
            // Then: CONIN$/CONOUT$ are tried first, with std handles only as fallbacks.
            assert_eq!(
                input_candidates,
                [
                    ConsoleHandleCandidate::NamedConsole {
                        name: "CONIN$",
                        access: super::CONSOLE_READ_WRITE
                    },
                    ConsoleHandleCandidate::StdHandle(STD_INPUT_HANDLE)
                ]
            );
            assert_eq!(
                output_candidates,
                [
                    ConsoleHandleCandidate::NamedConsole {
                        name: "CONOUT$",
                        access: super::CONSOLE_READ_WRITE
                    },
                    ConsoleHandleCandidate::StdHandle(STD_OUTPUT_HANDLE)
                ]
            );
        }

        #[test]
        fn windows_tty_translates_printable_key_when_key_down() {
            // Given: a Windows key-down event carrying a printable Unicode scalar.
            let event = WindowsConsoleEvent::Key(WindowsKeyEvent {
                key_down: true,
                unicode_char: Some('A'),
            });

            // When: the pure Windows console event translator handles the event.
            let translated = translate_windows_console_event(event);

            // Then: the helper emits the UTF-8 key byte stream expected by Elixir.
            assert_eq!(translated.as_deref(), Some(&b"A"[..]));
        }

        #[test]
        fn windows_tty_translates_control_key_when_key_down() {
            // Given: a Windows key-down event carrying a control character.
            let event = WindowsConsoleEvent::Key(WindowsKeyEvent {
                key_down: true,
                unicode_char: Some('\u{3}'),
            });

            // When: the pure Windows console event translator handles the event.
            let translated = translate_windows_console_event(event);

            // Then: the helper preserves the control byte rather than dropping it.
            assert_eq!(translated.as_deref(), Some(&[0x03][..]));
        }

        #[test]
        fn windows_tty_ignores_key_up_and_malformed_empty_key_events() {
            // Given: key events that should not produce terminal input.
            let key_up = WindowsConsoleEvent::Key(WindowsKeyEvent {
                key_down: false,
                unicode_char: Some('A'),
            });
            let empty_key = WindowsConsoleEvent::Key(WindowsKeyEvent {
                key_down: true,
                unicode_char: None,
            });

            // When: the pure Windows console event translator handles the events.
            let translated_key_up = translate_windows_console_event(key_up);
            let translated_empty_key = translate_windows_console_event(empty_key);

            // Then: no raw bytes are emitted for malformed or non-down key events.
            assert_eq!(translated_key_up, None);
            assert_eq!(translated_empty_key, None);
        }

        #[test]
        fn windows_tty_translates_resize_to_helper_control_frame() {
            // Given: a valid Windows buffer resize event.
            let event = WindowsConsoleEvent::Resize(WindowsResizeEvent {
                columns: 132,
                rows: 41,
            });

            // When: the pure Windows console event translator handles the event.
            let translated = translate_windows_console_event(event);

            // Then: the helper emits a structured resize control frame for Elixir.
            assert_eq!(
                translated.as_deref(),
                Some(&b"\x1b]777;ourocode-resize=132x41\x07"[..])
            );
        }

        #[test]
        fn windows_tty_rejects_malformed_resize_events() {
            // Given: malformed resize events from an invalid console state.
            let zero_columns = WindowsConsoleEvent::Resize(WindowsResizeEvent {
                columns: 0,
                rows: 41,
            });
            let zero_rows = WindowsConsoleEvent::Resize(WindowsResizeEvent {
                columns: 132,
                rows: 0,
            });

            // When: the pure Windows console event translator handles the events.
            let translated_zero_columns = translate_windows_console_event(zero_columns);
            let translated_zero_rows = translate_windows_console_event(zero_rows);

            // Then: invalid dimensions do not produce helper control data.
            assert_eq!(translated_zero_columns, None);
            assert_eq!(translated_zero_rows, None);
        }

        #[test]
        fn windows_tty_translates_mouse_press_to_sgr_mouse_sequence() {
            // Given: a left-button press at Windows 0-based console coordinates.
            let event = WindowsConsoleEvent::Mouse(WindowsMouseEvent {
                column: 4,
                row: 9,
                button: MouseButton::Left,
                state: MouseButtonState::Pressed,
            });

            // When: the pure Windows console event translator handles the event.
            let translated = translate_windows_console_event(event);

            // Then: the helper emits an SGR mouse sequence with 1-based coordinates.
            assert_eq!(translated.as_deref(), Some(&b"\x1b[<0;5;10M"[..]));
        }

        #[test]
        fn windows_tty_rejects_malformed_mouse_events() {
            // Given: a mouse event with coordinates outside the SGR encoding range.
            let event = WindowsConsoleEvent::Mouse(WindowsMouseEvent {
                column: -1,
                row: 9,
                button: MouseButton::Left,
                state: MouseButtonState::Pressed,
            });

            // When: the pure Windows console event translator handles the event.
            let translated = translate_windows_console_event(event);

            // Then: invalid coordinates do not produce raw terminal bytes.
            assert_eq!(translated, None);
        }

        #[test]
        fn windows_tty_converts_raw_key_input_record() {
            // Given: a raw Win32 key-down input record carrying a printable Unicode scalar.
            let record = INPUT_RECORD {
                EventType: KEY_EVENT as u16,
                Event: INPUT_RECORD_0 {
                    KeyEvent: KEY_EVENT_RECORD {
                        bKeyDown: 1 as BOOL,
                        wRepeatCount: 1,
                        wVirtualKeyCode: 0,
                        wVirtualScanCode: 0,
                        uChar: KEY_EVENT_RECORD_0 {
                            UnicodeChar: 'Z' as u16,
                        },
                        dwControlKeyState: 0,
                    },
                },
            };

            // When: the helper converts the raw Win32 record through the pure seam.
            let translated = input_record_to_windows_console_event(&record)
                .and_then(translate_windows_console_event);

            // Then: the same UTF-8 key stream reaches Elixir as with the synthetic event.
            assert_eq!(translated.as_deref(), Some(&b"Z"[..]));
        }

        #[test]
        fn windows_tty_converts_raw_resize_input_record() {
            // Given: a raw Win32 window-buffer-size event.
            let record = INPUT_RECORD {
                EventType: WINDOW_BUFFER_SIZE_EVENT as u16,
                Event: INPUT_RECORD_0 {
                    WindowBufferSizeEvent: WINDOW_BUFFER_SIZE_RECORD {
                        dwSize: COORD { X: 144, Y: 36 },
                    },
                },
            };

            // When: the helper converts the raw Win32 record through the pure seam.
            let translated = input_record_to_windows_console_event(&record)
                .and_then(translate_windows_console_event);

            // Then: the existing resize helper protocol is preserved exactly.
            assert_eq!(
                translated.as_deref(),
                Some(&b"\x1b]777;ourocode-resize=144x36\x07"[..])
            );
        }

        #[test]
        fn windows_tty_converts_raw_mouse_input_record() {
            // Given: a raw Win32 left-button mouse press at 0-based console coordinates.
            let record = INPUT_RECORD {
                EventType: MOUSE_EVENT as u16,
                Event: INPUT_RECORD_0 {
                    MouseEvent: MOUSE_EVENT_RECORD {
                        dwMousePosition: COORD { X: 2, Y: 6 },
                        dwButtonState: FROM_LEFT_1ST_BUTTON_PRESSED,
                        dwControlKeyState: 0,
                        dwEventFlags: 0,
                    },
                },
            };

            // When: the helper converts the raw Win32 record through the pure seam.
            let translated = input_record_to_windows_console_event(&record)
                .and_then(translate_windows_console_event);

            // Then: SGR mouse translation remains intact.
            assert_eq!(translated.as_deref(), Some(&b"\x1b[<0;3;7M"[..]));
        }

        #[test]
        fn windows_tty_ignores_raw_non_input_record() {
            // Given: a raw Win32 focus event that carries no terminal input for Elixir.
            let record = INPUT_RECORD {
                EventType: FOCUS_EVENT as u16,
                Event: INPUT_RECORD_0 {
                    FocusEvent: FOCUS_EVENT_RECORD { bSetFocus: 1 },
                },
            };

            // When: the helper converts the raw Win32 record through the pure seam.
            let converted = input_record_to_windows_console_event(&record);

            // Then: unsupported records are ignored instead of becoming raw bytes.
            assert!(converted.is_none());
        }
    }
}
