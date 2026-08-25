use crate::{
    BrokerConfig, CapabilityManifestV4, LiveTerminalCompression, LiveTerminalEngine,
    LiveTerminalEngineConfig, LiveTerminalEngineFactory, LiveTerminalInputEncode,
    NormalizedInputEvent, NormalizedKeyAction, NormalizedMouseAction, NormalizedMouseButton,
    NormalizedScrollDirection, PointerDisposition, PROTOCOL_VERSION_V4, RECOVERY_CHUNK_BYTES,
};
use ouro_terminal_ghostty::{
    CompressionStep, Config, EncodeOutcome, Error as GhosttyError, InputConfig, KeyAction,
    KeyEvent, MouseAction, MouseButton, MouseEvent, MouseGeometry, PageBudget, PageBudgetStats,
    ScrollDirection, ScrollEvent, Terminal, GHOSTTY_GRAPHICS_POLICY, GHOSTTY_UNICODE_WIDTH_POLICY,
    TERMINAL_ENGINE_ABI_VERSION,
};
use std::io;

pub use ouro_terminal_ghostty::{
    GHOSTTY_SNAPSHOT_FORMAT_VERSION, GHOSTTY_SNAPSHOT_MAGIC, GHOSTTY_SOURCE_COMMIT,
};

/// Exact-pin Ghostty factory for the Rust-only product integration gate.
///
/// This factory establishes live state ownership, canonical snapshot
/// provenance, and one shared native-page budget across create and restore.
#[derive(Clone, Debug)]
pub struct GhosttyEngineFactory {
    config: Config,
    page_budget: PageBudget,
}

impl GhosttyEngineFactory {
    pub fn new(config: Config, shared_page_budget_bytes: usize) -> io::Result<Self> {
        let page_budget = PageBudget::new(shared_page_budget_bytes)
            .map_err(|error| map_error("create shared page budget", error))?;
        Ok(Self {
            config,
            page_budget,
        })
    }

    pub fn page_budget_stats(&self) -> io::Result<PageBudgetStats> {
        self.page_budget
            .stats()
            .map_err(|error| map_error("read shared page budget", error))
    }

    pub fn manifest(&self, broker: &BrokerConfig) -> io::Result<CapabilityManifestV4> {
        if self.config.scrollback_max_bytes != broker.max_terminal_history_bytes {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Ghostty and broker per-terminal history budgets differ",
            ));
        }
        if self.config.snapshot_max_bytes != broker.max_snapshot_bytes {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Ghostty and broker snapshot budgets differ",
            ));
        }
        Ok(CapabilityManifestV4 {
            protocol_version: PROTOCOL_VERSION_V4,
            terminal_abi_version: TERMINAL_ENGINE_ABI_VERSION,
            engine_source_commit: GHOSTTY_SOURCE_COMMIT.into(),
            snapshot_magic: GHOSTTY_SNAPSHOT_MAGIC.into(),
            snapshot_format_version: GHOSTTY_SNAPSHOT_FORMAT_VERSION,
            unicode_width_policy: GHOSTTY_UNICODE_WIDTH_POLICY.into(),
            graphics_policy: GHOSTTY_GRAPHICS_POLICY.into(),
            max_snapshot_bytes: broker.max_snapshot_bytes as u64,
            max_terminal_history_bytes: broker.max_terminal_history_bytes as u64,
            max_global_history_bytes: broker.max_global_history_bytes as u64,
            max_delta_bytes: broker.max_delta_bytes as u64,
            max_recovery_pinned_bytes: broker.max_recovery_pinned_bytes as u64,
            max_chunk_bytes: RECOVERY_CHUNK_BYTES as u32,
            // This describes recovery transport compression. Ghostty's
            // internal cold-page compression remains independently scheduled.
            compression: "none".into(),
        })
    }
}

impl LiveTerminalEngineFactory for GhosttyEngineFactory {
    fn create(&self, live: LiveTerminalEngineConfig) -> io::Result<Box<dyn LiveTerminalEngine>> {
        let config = Config {
            columns: live.columns,
            rows: live.rows,
            cell_width_px: live.cell_width_px,
            cell_height_px: live.cell_height_px,
            ..self.config
        };
        let terminal = Terminal::new_with_page_budget(config, &self.page_budget)
            .map_err(|error| map_error("create", error))?;
        Ok(Box::new(GhosttyLiveTerminal {
            terminal,
            input_config: InputConfig::default(),
        }))
    }

    fn restore(
        &self,
        live: LiveTerminalEngineConfig,
        checkpoint: &[u8],
    ) -> io::Result<Box<dyn LiveTerminalEngine>> {
        let config = Config {
            columns: live.columns,
            rows: live.rows,
            cell_width_px: live.cell_width_px,
            cell_height_px: live.cell_height_px,
            ..self.config
        };
        let terminal = Terminal::restore_with_page_budget(config, &self.page_budget, checkpoint)
            .map_err(|error| map_error("restore", error))?;
        Ok(Box::new(GhosttyLiveTerminal {
            terminal,
            input_config: InputConfig::default(),
        }))
    }

    fn supports_normalized_input(&self) -> bool {
        true
    }

    fn supports_pointer_disposition(&self) -> bool {
        true
    }
}

struct GhosttyLiveTerminal {
    terminal: Terminal,
    input_config: InputConfig,
}

impl LiveTerminalEngine for GhosttyLiveTerminal {
    fn feed(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.terminal
            .feed(bytes)
            .map_err(|error| map_error("feed", error))
    }

    fn take_pty_responses(&mut self) -> io::Result<Vec<u8>> {
        self.terminal
            .take_pty_responses()
            .map_err(|error| map_error("pty response", error))
    }

    fn resize(
        &mut self,
        columns: u16,
        rows: u16,
        cell_width_px: u32,
        cell_height_px: u32,
    ) -> io::Result<()> {
        self.terminal
            .resize(columns, rows, cell_width_px, cell_height_px)
            .map_err(|error| map_error("resize", error))
    }

    fn export_checkpoint(&mut self) -> io::Result<Vec<u8>> {
        self.terminal
            .snapshot()
            .map_err(|error| map_error("snapshot", error))
    }

    fn compression_activity(&self) -> io::Result<Option<u64>> {
        self.terminal
            .compression_activity()
            .map(Some)
            .map_err(|error| map_error("compression activity", error))
    }

    fn compress_incremental(&mut self) -> io::Result<LiveTerminalCompression> {
        self.terminal
            .compress_incremental_step()
            .map(|step| match step {
                CompressionStep::Unsupported => LiveTerminalCompression::Unsupported,
                CompressionStep::Pending => LiveTerminalCompression::Pending,
                CompressionStep::Complete => LiveTerminalCompression::Complete,
            })
            .map_err(|error| map_error("incremental compression", error))
    }

    fn encode_normalized_input(
        &mut self,
        event: &NormalizedInputEvent,
        output: &mut [u8],
    ) -> io::Result<LiveTerminalInputEncode> {
        let mut input = self
            .terminal
            .input(self.input_config)
            .map_err(|error| map_error("input context", error))?;
        let outcome = match event {
            NormalizedInputEvent::Key {
                hid_usage,
                action,
                modifiers,
                consumed_modifiers,
                composing,
                unshifted_codepoint,
                utf8,
                ..
            } => input.encode_key(
                KeyEvent {
                    hid_usage: *hid_usage,
                    action: match action {
                        NormalizedKeyAction::Release => KeyAction::Release,
                        NormalizedKeyAction::Press => KeyAction::Press,
                        NormalizedKeyAction::Repeat => KeyAction::Repeat,
                    },
                    modifiers: *modifiers,
                    consumed_modifiers: *consumed_modifiers,
                    composing: *composing,
                    unshifted_codepoint: *unshifted_codepoint,
                    utf8,
                },
                output,
            ),
            NormalizedInputEvent::CommittedText { utf8 } => {
                input.encode_committed_text(utf8, output)
            }
            NormalizedInputEvent::MouseGeometry { geometry, .. } => {
                input
                    .set_mouse_geometry(mouse_geometry(*geometry))
                    .map_err(|error| map_error("mouse geometry", error))?;
                return Ok(LiveTerminalInputEncode::Written(0));
            }
            NormalizedInputEvent::Mouse {
                action,
                button,
                modifiers,
                x_q8,
                y_q8,
                ..
            } => input.encode_mouse(
                MouseEvent {
                    action: match action {
                        NormalizedMouseAction::Press => MouseAction::Press,
                        NormalizedMouseAction::Release | NormalizedMouseAction::Cancel => {
                            MouseAction::Release
                        }
                        NormalizedMouseAction::Motion => MouseAction::Motion,
                    },
                    button: match button {
                        NormalizedMouseButton::None => MouseButton::None,
                        NormalizedMouseButton::Left => MouseButton::Left,
                        NormalizedMouseButton::Right => MouseButton::Right,
                        NormalizedMouseButton::Middle => MouseButton::Middle,
                        NormalizedMouseButton::Four => MouseButton::Four,
                        NormalizedMouseButton::Five => MouseButton::Five,
                        NormalizedMouseButton::Six => MouseButton::Six,
                        NormalizedMouseButton::Seven => MouseButton::Seven,
                        NormalizedMouseButton::Eight => MouseButton::Eight,
                        NormalizedMouseButton::Nine => MouseButton::Nine,
                        NormalizedMouseButton::Ten => MouseButton::Ten,
                        NormalizedMouseButton::Eleven => MouseButton::Eleven,
                    },
                    modifiers: *modifiers,
                    x: f64::from(*x_q8) / 256.0,
                    y: f64::from(*y_q8) / 256.0,
                },
                output,
            ),
            NormalizedInputEvent::Scroll {
                direction,
                modifiers,
                x_q8,
                y_q8,
                ..
            } => input.encode_scroll(
                ScrollEvent {
                    direction: match direction {
                        NormalizedScrollDirection::Up => ScrollDirection::Up,
                        NormalizedScrollDirection::Down => ScrollDirection::Down,
                        NormalizedScrollDirection::Left => ScrollDirection::Left,
                        NormalizedScrollDirection::Right => ScrollDirection::Right,
                    },
                    modifiers: *modifiers,
                    x: f64::from(*x_q8) / 256.0,
                    y: f64::from(*y_q8) / 256.0,
                },
                output,
            ),
            NormalizedInputEvent::Paste { utf8 } => input.encode_paste(utf8, output),
            NormalizedInputEvent::Focus { focused } => input.encode_focus(*focused, output),
        }
        .map_err(|error| map_error("encode normalized input", error))?;
        Ok(match outcome {
            EncodeOutcome::Written(written) => LiveTerminalInputEncode::Written(written),
            EncodeOutcome::BufferTooSmall { required } => {
                LiveTerminalInputEncode::BufferTooSmall { required }
            }
        })
    }

    fn pointer_disposition(
        &mut self,
        event: &NormalizedInputEvent,
    ) -> io::Result<Option<PointerDisposition>> {
        const SHIFT_MODIFIER: u16 = 1 << 0;
        match event {
            // Geometry configures the canonical encoder but is not itself a
            // gesture with a local-versus-PTY route.
            NormalizedInputEvent::MouseGeometry { .. } => Ok(None),
            NormalizedInputEvent::Mouse { modifiers, .. } => {
                if modifiers & SHIFT_MODIFIER != 0 {
                    return Ok(Some(PointerDisposition::LocalSelection));
                }
                let input = self
                    .terminal
                    .input(self.input_config)
                    .map_err(|error| map_error("input context", error))?;
                let reporting = input
                    .mouse_reporting()
                    .map_err(|error| map_error("mouse reporting", error))?;
                Ok(Some(if reporting {
                    PointerDisposition::Pty
                } else {
                    PointerDisposition::LocalSelection
                }))
            }
            NormalizedInputEvent::Scroll { modifiers, .. } => {
                if modifiers & SHIFT_MODIFIER != 0 {
                    return Ok(Some(PointerDisposition::LocalScrollback));
                }
                let input = self
                    .terminal
                    .input(self.input_config)
                    .map_err(|error| map_error("input context", error))?;
                let reporting = input
                    .mouse_reporting()
                    .map_err(|error| map_error("mouse reporting", error))?;
                Ok(Some(if reporting {
                    PointerDisposition::Pty
                } else {
                    PointerDisposition::LocalScrollback
                }))
            }
            _ => Ok(None),
        }
    }
}

fn mouse_geometry(value: crate::NormalizedMouseGeometry) -> MouseGeometry {
    MouseGeometry {
        screen_width: f64::from(value.screen_width_q8) / 256.0,
        screen_height: f64::from(value.screen_height_q8) / 256.0,
        cell_width: f64::from(value.cell_width_q8) / 256.0,
        cell_height: f64::from(value.cell_height_q8) / 256.0,
        padding_top: f64::from(value.padding_top_q8) / 256.0,
        padding_bottom: f64::from(value.padding_bottom_q8) / 256.0,
        padding_right: f64::from(value.padding_right_q8) / 256.0,
        padding_left: f64::from(value.padding_left_q8) / 256.0,
    }
}

fn map_error(operation: &str, error: GhosttyError) -> io::Error {
    let kind = match error {
        GhosttyError::InvalidArgument => io::ErrorKind::InvalidInput,
        GhosttyError::BufferTooSmall => io::ErrorKind::FileTooLarge,
        GhosttyError::OutOfMemory | GhosttyError::Engine | GhosttyError::Unknown(_) => {
            io::ErrorKind::Other
        }
    };
    io::Error::new(kind, format!("Ghostty {operation} failed: {error:?}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn factory_shares_one_page_budget_across_create_and_restore() {
        let factory = GhosttyEngineFactory::new(Config::default(), 128 * 1024 * 1024).unwrap();
        let live = LiveTerminalEngineConfig {
            columns: 12,
            rows: 5,
            cell_width_px: 8,
            cell_height_px: 16,
        };

        let mut source = factory.create(live).unwrap();
        source.feed(b"factory-shared-budget\r\n").unwrap();
        let source_reserved = factory.page_budget_stats().unwrap().reserved_bytes;
        assert!(source_reserved > 0);
        let checkpoint = source.export_checkpoint().unwrap();

        let restored = factory.restore(live, &checkpoint).unwrap();
        assert!(factory.page_budget_stats().unwrap().reserved_bytes > source_reserved);
        drop(restored);
        assert_eq!(
            factory.page_budget_stats().unwrap().reserved_bytes,
            source_reserved
        );
        drop(source);
        assert_eq!(factory.page_budget_stats().unwrap().reserved_bytes, 0);
    }
}
