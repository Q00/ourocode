//! Durable, app-independent PTY ownership for Ourocode.
//!
//! The broker is deliberately one non-blocking `poll(2)` loop. There is no
//! thread per terminal or client. The Unix socket is mode `0600`, and every
//! accepted connection is authenticated against the broker's effective UID.

pub mod authority_registry;
pub mod desktop_peer_verifier;
pub mod gateway_runtime_contract;
pub mod principal_binding_ack_wire;
pub mod principal_binding_coordinator;
pub mod principal_binding_registration;
pub mod session_message;
pub mod session_message_bridge_wire;
pub mod session_message_gateway;
pub mod session_message_transport;
pub mod session_terminal_binding;
pub mod terminal_state;
pub use session_terminal_binding::DeclaredSessionBindingV1;

#[cfg(feature = "ghostty-engine")]
pub mod ghostty_engine;

use ouro_session::mobile_sync::{DeltaWindow, Resume, TerminalDelta, TerminalDeltaPayload};
use ouro_session::recovery_v4::{OrderedStateLog, StateEvent, StateEventPayload};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, VecDeque};
use std::ffi::CString;
use std::fs;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use terminal_state::{CanonicalTerminalState, RecoveryFrame};

/// Wire protocol version. Version 3 is namespaced onto a new socket because
/// create reconciliation and reaped termination acknowledgements cannot be
/// safely inferred by older clients.
pub const PROTOCOL_VERSION: u16 = 3;
pub const PROTOCOL_VERSION_V4: u16 = 4;
pub const RECOVERY_CHUNK_BYTES: usize = 64 * 1024;
pub const BROKER_BUILD: &str = env!("CARGO_PKG_VERSION");
pub const CAPABILITY_CANONICAL_RECOVERY: &str = "terminal.recovery.ansi_replay.viewport.v1";
pub const CAPABILITY_DELTA_RESUME: &str = "terminal.resume.delta.v1";
pub const CAPABILITY_CREATE_IDEMPOTENCY: &str = "terminal.create.idempotency.v1";
pub const CAPABILITY_REAPED_TERMINATION: &str = "terminal.terminate.reaped_ack.v1";
pub const BROKER_CAPABILITIES: &[&str] = &[
    CAPABILITY_CANONICAL_RECOVERY,
    CAPABILITY_DELTA_RESUME,
    CAPABILITY_CREATE_IDEMPOTENCY,
    CAPABILITY_REAPED_TERMINATION,
];
pub const CAPABILITY_ORDERED_STATE_V4: &str = "terminal.state.ordered.v4";
pub const CAPABILITY_TWO_PHASE_RECOVERY_V4: &str = "terminal.recovery.two_phase.v4";
pub const CAPABILITY_LEASE_DETACH_V4: &str = "terminal.detach.lease.v4";
/// Carries a bounded, non-authoritative exact-attempt join key on Create/List.
pub const CAPABILITY_DECLARED_SESSION_BINDING_V1: &str = "terminal.session_binding.declared.v1";
/// Proves that one live broker-owned PTY is the surface created for an exact
/// session attempt. The opaque receipt is returned only to the connection
/// that created the PTY and is deliberately absent from `List`.
pub const CAPABILITY_IDENTIFY_SURFACE_V1: &str = "terminal.surface.identify.v1";
/// Exactly-once key, committed-text, paste, focus, and pointer input.
pub const CAPABILITY_NORMALIZED_INPUT_V1: &str = "terminal.input.normalized.v1";
/// Every accepted pointer event carries the broker's atomic decision: encode
/// it against the canonical PTY modes or apply it to this client's local view.
pub const CAPABILITY_POINTER_DISPOSITION_V1: &str = "terminal.pointer.disposition.v1";
const INPUT_RECEIPT_CACHE_LIMIT: usize = 64;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct CapabilityManifestV4 {
    pub protocol_version: u16,
    pub terminal_abi_version: u32,
    pub engine_source_commit: String,
    pub snapshot_magic: String,
    pub snapshot_format_version: u32,
    pub unicode_width_policy: String,
    pub graphics_policy: String,
    pub max_snapshot_bytes: u64,
    pub max_terminal_history_bytes: u64,
    pub max_global_history_bytes: u64,
    pub max_delta_bytes: u64,
    pub max_recovery_pinned_bytes: u64,
    pub max_chunk_bytes: u32,
    pub compression: String,
}

impl CapabilityManifestV4 {
    pub fn validate(&self) -> io::Result<()> {
        if self.protocol_version != PROTOCOL_VERSION_V4
            || self.terminal_abi_version == 0
            || self.engine_source_commit.is_empty()
            || self.snapshot_magic.is_empty()
            || self.snapshot_format_version == 0
            || self.unicode_width_policy.is_empty()
            || self.graphics_policy.is_empty()
            || self.max_snapshot_bytes == 0
            || self.max_delta_bytes == 0
            || self.max_recovery_pinned_bytes == 0
            || self.max_chunk_bytes as usize != RECOVERY_CHUNK_BYTES
            || self.compression != "none"
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid protocol-v4 capability manifest",
            ));
        }
        Ok(())
    }

    /// A non-production adapter manifest used by the standalone v4 binary and
    /// protocol tests. Production must inject the exact-pin Ghostty provider
    /// and matching manifest through `Broker::bind_v4`.
    pub fn canonical_replay_fixture(config: &BrokerConfig) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION_V4,
            terminal_abi_version: 1,
            engine_source_commit: "fixture:vt100-0.15.2".into(),
            snapshot_magic: "OUROCODE-ANSI-REPLAY".into(),
            snapshot_format_version: 1,
            unicode_width_policy: "unicode-width:fixture".into(),
            graphics_policy: "disabled".into(),
            max_snapshot_bytes: config.max_snapshot_bytes as u64,
            max_terminal_history_bytes: config.max_terminal_history_bytes as u64,
            max_global_history_bytes: config.max_global_history_bytes as u64,
            max_delta_bytes: config.max_delta_bytes as u64,
            max_recovery_pinned_bytes: config.max_recovery_pinned_bytes as u64,
            max_chunk_bytes: RECOVERY_CHUNK_BYTES as u32,
            compression: "none".into(),
        }
    }
}

pub struct CheckpointRequest<'a> {
    pub terminal_id: &'a str,
    pub state_seq: u64,
    pub columns: u16,
    pub rows: u16,
    pub canonical_replay: &'a [u8],
}

/// Exact-pin engines implement this boundary. The broker treats returned
/// checkpoint bytes as opaque and enforces manifest, size, digest and pinning
/// bounds without depending on Ghostty's private representation.
pub trait CheckpointProvider: Send + Sync {
    fn export_checkpoint(&self, request: CheckpointRequest<'_>) -> io::Result<Vec<u8>>;
}

/// Construction parameters for a broker-owned terminal engine. The broker
/// creates exactly one engine for each PTY and then serializes every mutation
/// through its single reactor thread.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LiveTerminalEngineConfig {
    pub columns: u16,
    pub rows: u16,
    pub cell_width_px: u32,
    pub cell_height_px: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LiveTerminalCompression {
    Unsupported,
    Pending,
    Complete,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum NormalizedKeyAction {
    Release,
    Press,
    Repeat,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum NormalizedMouseAction {
    Press,
    Release,
    Motion,
    Cancel,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum NormalizedMouseButton {
    None,
    Left,
    Right,
    Middle,
    Four,
    Five,
    Six,
    Seven,
    Eight,
    Nine,
    Ten,
    Eleven,
}

impl NormalizedMouseButton {
    fn route_index(self) -> Option<usize> {
        match self {
            Self::None => None,
            Self::Left => Some(0),
            Self::Right => Some(1),
            Self::Middle => Some(2),
            Self::Four => Some(3),
            Self::Five => Some(4),
            Self::Six => Some(5),
            Self::Seven => Some(6),
            Self::Eight => Some(7),
            Self::Nine => Some(8),
            Self::Ten => Some(9),
            Self::Eleven => Some(10),
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum NormalizedScrollDirection {
    Up,
    Down,
    Left,
    Right,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PointerDisposition {
    Pty,
    LocalSelection,
    LocalScrollback,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Serialize)]
pub struct NormalizedMouseGeometry {
    pub screen_width_q8: u32,
    pub screen_height_q8: u32,
    pub cell_width_q8: u32,
    pub cell_height_q8: u32,
    pub padding_top_q8: u32,
    pub padding_bottom_q8: u32,
    pub padding_right_q8: u32,
    pub padding_left_q8: u32,
}

/// AppKit-normalized input. This is the only input accepted by an engine that
/// advertises [`CAPABILITY_NORMALIZED_INPUT_V1`]. IME preedit is deliberately
/// absent: only its final committed UTF-8 text crosses the broker boundary.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum NormalizedInputEvent {
    Key {
        hid_usage: u32,
        action: NormalizedKeyAction,
        modifiers: u16,
        consumed_modifiers: u16,
        composing: bool,
        unshifted_codepoint: u32,
        #[serde(with = "base64_bytes")]
        utf8: Vec<u8>,
    },
    CommittedText {
        #[serde(with = "base64_bytes")]
        utf8: Vec<u8>,
    },
    MouseGeometry {
        layout_epoch: u64,
        geometry: NormalizedMouseGeometry,
    },
    Mouse {
        gesture_id: u64,
        layout_epoch: u64,
        action: NormalizedMouseAction,
        button: NormalizedMouseButton,
        modifiers: u16,
        x_q8: i32,
        y_q8: i32,
    },
    Scroll {
        gesture_id: u64,
        layout_epoch: u64,
        direction: NormalizedScrollDirection,
        modifiers: u16,
        x_q8: i32,
        y_q8: i32,
    },
    Paste {
        #[serde(with = "base64_bytes")]
        utf8: Vec<u8>,
    },
    Focus {
        focused: bool,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LiveTerminalInputEncode {
    Written(usize),
    BufferTooSmall { required: usize },
}

/// A live, per-PTY terminal state owned by the broker.
///
/// Implementations receive the original PTY byte stream and ordered resizes,
/// not a replay synthesized at attach time. A failed mutation invalidates the
/// engine for recovery: the broker keeps the PTY alive for an attached client
/// but will not export a checkpoint from possibly partially mutated state.
pub trait LiveTerminalEngine: Send {
    fn feed(&mut self, bytes: &[u8]) -> io::Result<()>;

    /// Drain terminal-generated replies that must be written to the PTY.
    fn take_pty_responses(&mut self) -> io::Result<Vec<u8>> {
        Ok(Vec::new())
    }

    fn resize(
        &mut self,
        columns: u16,
        rows: u16,
        cell_width_px: u32,
        cell_height_px: u32,
    ) -> io::Result<()>;

    fn export_checkpoint(&mut self) -> io::Result<Vec<u8>>;

    /// Opaque activity generation used to cancel stale idle work. `None`
    /// means this engine does not expose incremental compression.
    fn compression_activity(&self) -> io::Result<Option<u64>> {
        Ok(None)
    }

    /// Perform at most one bounded compression unit. The reactor never calls
    /// this on the PTY read path and rechecks the activity generation before
    /// every step.
    fn compress_incremental(&mut self) -> io::Result<LiveTerminalCompression> {
        Ok(LiveTerminalCompression::Unsupported)
    }

    /// Encode against the canonical terminal modes owned by this live engine.
    /// Implementations must make a `BufferTooSmall` result retry-safe: no key,
    /// pointer, paste or focus event may become externally consumed until a
    /// subsequent call returns `Written` and the broker has queue capacity.
    /// A committed pointer press must also latch its mouse tracking/encoding
    /// protocol through the matching release or cancel; PTY output may change
    /// terminal modes between those two events.
    fn encode_normalized_input(
        &mut self,
        _event: &NormalizedInputEvent,
        _output: &mut [u8],
    ) -> io::Result<LiveTerminalInputEncode> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "normalized input is unsupported by this terminal engine",
        ))
    }

    /// Classifies a pointer event against the same canonical terminal modes
    /// used by `encode_normalized_input`. The single broker reactor calls this
    /// immediately before commit, so no PTY output can change the modes between
    /// classification and the receipt. Non-pointer events return `None`.
    fn pointer_disposition(
        &mut self,
        _event: &NormalizedInputEvent,
    ) -> io::Result<Option<PointerDisposition>> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "pointer disposition is unsupported by this terminal engine",
        ))
    }
}

/// Creates the exact engine state stored inside each broker terminal.
pub trait LiveTerminalEngineFactory: Send + Sync {
    fn create(&self, config: LiveTerminalEngineConfig) -> io::Result<Box<dyn LiveTerminalEngine>>;

    /// Reconstructs a terminal from an immutable engine checkpoint. The
    /// broker replays the ordered raw event tail after this returns, so the
    /// restored handle is never published in a partially caught-up state.
    fn restore(
        &self,
        config: LiveTerminalEngineConfig,
        checkpoint: &[u8],
    ) -> io::Result<Box<dyn LiveTerminalEngine>>;

    fn supports_normalized_input(&self) -> bool {
        false
    }

    fn supports_pointer_disposition(&self) -> bool {
        false
    }
}

#[derive(Default)]
pub struct CanonicalReplayCheckpoint;

impl CheckpointProvider for CanonicalReplayCheckpoint {
    fn export_checkpoint(&self, request: CheckpointRequest<'_>) -> io::Result<Vec<u8>> {
        Ok(request.canonical_replay.to_vec())
    }
}

#[derive(Clone, Debug)]
pub struct BrokerConfig {
    pub socket_path: PathBuf,
    pub max_clients: usize,
    pub max_terminals: usize,
    pub max_tombstones: usize,
    pub max_request_bytes: usize,
    pub max_client_queue_bytes: usize,
    pub max_terminal_input_bytes: usize,
    pub max_delta_bytes: usize,
    pub max_snapshot_bytes: usize,
    pub max_terminal_history_bytes: usize,
    pub max_global_history_bytes: usize,
    pub max_live_checkpoint_bytes: usize,
    pub canonical_scrollback_lines: usize,
    pub max_pending_escape_bytes: usize,
    pub max_output_chunk_bytes: usize,
    pub output_coalesce: Duration,
    pub headless_output_coalesce: Duration,
    pub poll_timeout: Duration,
    pub max_accepts_per_tick: usize,
    pub max_client_read_bytes_per_tick: usize,
    pub max_client_requests_per_tick: usize,
    pub max_client_write_bytes_per_tick: usize,
    pub max_terminal_read_bytes_per_tick: usize,
    pub max_terminal_write_bytes_per_tick: usize,
    pub engine_idle_compression_delay: Duration,
    pub max_engine_compression_steps_per_tick: usize,
    pub max_recoveries: usize,
    pub max_recovery_pinned_bytes: usize,
    pub recovery_ttl: Duration,
    pub max_aborted_recoveries: usize,
}

impl BrokerConfig {
    pub fn new(socket_path: impl Into<PathBuf>) -> Self {
        Self {
            socket_path: socket_path.into(),
            max_clients: 64,
            max_terminals: 32,
            max_tombstones: 64,
            max_request_bytes: 1024 * 1024,
            max_client_queue_bytes: 2 * 1024 * 1024,
            max_terminal_input_bytes: 64 * 1024,
            max_delta_bytes: 512 * 1024,
            max_snapshot_bytes: 16 * 1024 * 1024,
            max_terminal_history_bytes: 8 * 1024 * 1024,
            max_global_history_bytes: 128 * 1024 * 1024,
            max_live_checkpoint_bytes: 32 * 1024 * 1024,
            // Snapshot v1 is explicitly viewport-scoped. Retaining hidden
            // canonical scrollback here would spend memory without making it
            // recoverable, so the bootstrap default is zero.
            canonical_scrollback_lines: 0,
            max_pending_escape_bytes: 32 * 1024,
            max_output_chunk_bytes: 16 * 1024,
            output_coalesce: Duration::from_millis(4),
            headless_output_coalesce: Duration::from_millis(500),
            // All hot paths are descriptor-driven. This is only the maximum
            // maintenance wakeup; output-coalescing and termination deadlines
            // reduce it below, avoiding a permanent 20 Hz idle syscall loop.
            poll_timeout: Duration::from_secs(5),
            max_accepts_per_tick: 8,
            max_client_read_bytes_per_tick: 64 * 1024,
            max_client_requests_per_tick: 32,
            max_client_write_bytes_per_tick: 64 * 1024,
            max_terminal_read_bytes_per_tick: 64 * 1024,
            max_terminal_write_bytes_per_tick: 64 * 1024,
            engine_idle_compression_delay: Duration::from_secs(2),
            max_engine_compression_steps_per_tick: 1,
            max_recoveries: 4,
            max_recovery_pinned_bytes: 16 * 1024 * 1024,
            recovery_ttl: Duration::from_secs(15),
            max_aborted_recoveries: 64,
        }
    }

    fn validate(&self) -> io::Result<()> {
        let non_zero = [
            ("max_output_chunk_bytes", self.max_output_chunk_bytes),
            ("max_snapshot_bytes", self.max_snapshot_bytes),
            (
                "max_terminal_history_bytes",
                self.max_terminal_history_bytes,
            ),
            ("max_global_history_bytes", self.max_global_history_bytes),
            ("max_live_checkpoint_bytes", self.max_live_checkpoint_bytes),
            ("max_pending_escape_bytes", self.max_pending_escape_bytes),
            ("max_recoveries", self.max_recoveries),
            ("max_recovery_pinned_bytes", self.max_recovery_pinned_bytes),
            ("max_aborted_recoveries", self.max_aborted_recoveries),
            ("max_accepts_per_tick", self.max_accepts_per_tick),
            (
                "max_client_read_bytes_per_tick",
                self.max_client_read_bytes_per_tick,
            ),
            (
                "max_client_requests_per_tick",
                self.max_client_requests_per_tick,
            ),
            (
                "max_client_write_bytes_per_tick",
                self.max_client_write_bytes_per_tick,
            ),
            (
                "max_terminal_read_bytes_per_tick",
                self.max_terminal_read_bytes_per_tick,
            ),
            (
                "max_terminal_write_bytes_per_tick",
                self.max_terminal_write_bytes_per_tick,
            ),
            (
                "max_engine_compression_steps_per_tick",
                self.max_engine_compression_steps_per_tick,
            ),
        ];
        if let Some((name, _)) = non_zero.into_iter().find(|(_, value)| *value == 0) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("{name} must be non-zero"),
            ));
        }
        if self.max_terminal_history_bytes > self.max_global_history_bytes {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "per-terminal history budget exceeds the global history budget",
            ));
        }
        if self.max_delta_bytes
            <= self
                .max_pending_escape_bytes
                .saturating_add(self.max_output_chunk_bytes)
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "ordered tail budget must exceed parser-continuation and one output chunk reserve",
            ));
        }
        if self.engine_idle_compression_delay.is_zero() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "engine idle compression delay must be non-zero",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Request {
    pub version: u16,
    pub id: u64,
    #[serde(flatten)]
    pub command: Command,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct RequestV4 {
    pub version: u16,
    pub id: u64,
    #[serde(flatten)]
    pub command: CommandV4,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct IdentifySurfaceV1 {
    pub terminal_id: String,
    pub broker_generation: u64,
    pub create_nonce: String,
    pub session_binding: DeclaredSessionBindingV1,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum CommandV4 {
    Create {
        create_nonce: String,
        /// Discovery-only identity. It is never accepted as attach or input
        /// authority; authorization continues to use the authenticated peer,
        /// broker generation, and live lease.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        session_binding: Option<DeclaredSessionBindingV1>,
        program: String,
        #[serde(default)]
        args: Vec<String>,
        #[serde(default)]
        current_directory: Option<String>,
        #[serde(default)]
        environment: HashMap<String, String>,
        columns: u16,
        rows: u16,
    },
    /// Converts discovery-only Create metadata into a broker-observed live
    /// PTY proof. Every request field is checked against the stored Create
    /// signature; none of these caller declarations grants authority.
    IdentifySurface(IdentifySurfaceV1),
    List,
    AttachPrepare {
        terminal_id: String,
        broker_generation: u64,
        #[serde(default)]
        after_state_seq: Option<u64>,
    },
    RecoveryCommit {
        recovery_id: String,
        terminal_id: String,
        broker_generation: u64,
        cutover_state_seq: u64,
        digest: String,
    },
    RecoveryAbort {
        recovery_id: String,
        terminal_id: String,
        broker_generation: u64,
    },
    /// Releases only this connection's live subscription and attachment
    /// lease. The broker-owned PTY and canonical terminal state keep running.
    Detach {
        terminal_id: String,
        broker_generation: u64,
        input_epoch: u64,
        lease_id: String,
    },
    Input {
        terminal_id: String,
        broker_generation: u64,
        input_epoch: u64,
        lease_id: String,
        #[serde(with = "base64_bytes")]
        data: Vec<u8>,
    },
    NormalizedInput {
        terminal_id: String,
        broker_generation: u64,
        input_epoch: u64,
        input_seq: u64,
        lease_id: String,
        event_digest: String,
        event: NormalizedInputEvent,
    },
    Resize {
        terminal_id: String,
        broker_generation: u64,
        input_epoch: u64,
        lease_id: String,
        columns: u16,
        rows: u16,
        cell_width_px: u16,
        cell_height_px: u16,
        layout_epoch: u64,
    },
    Terminate {
        terminal_id: String,
        broker_generation: u64,
    },
    Forget {
        terminal_id: String,
        broker_generation: u64,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ServerMessageV4 {
    pub version: u16,
    pub broker_generation: u64,
    #[serde(flatten)]
    pub body: ServerBodyV4,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerBodyV4 {
    Hello {
        pid: u32,
        build: String,
        capabilities: Vec<String>,
        manifest: CapabilityManifestV4,
    },
    Reply {
        id: u64,
        #[serde(flatten)]
        result: ReplyV4,
    },
    Error {
        id: u64,
        code: ErrorCode,
        message: String,
    },
    RecoveryChunk {
        recovery_id: String,
        index: u32,
        #[serde(with = "base64_bytes")]
        data: Vec<u8>,
    },
    RecoveryEnd {
        recovery_id: String,
        digest: String,
    },
    RecoveryDelta {
        recovery_id: String,
        event: WireStateEvent,
    },
    StateEvent {
        terminal_id: String,
        event: WireStateEvent,
    },
    Exited {
        terminal_id: String,
        status: Option<i32>,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum ReplyV4 {
    Created {
        terminal: TerminalSummary,
        state_seq: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        session_binding: Option<DeclaredSessionBindingV1>,
    },
    SurfaceIdentified {
        terminal_id: String,
        create_nonce: String,
        session_binding: DeclaredSessionBindingV1,
        /// CSPRNG bearer returned only over the creating connection. It is
        /// not terminal discovery metadata and must never enter `List`.
        producer_receipt: String,
    },
    Listed {
        terminals: Vec<TerminalSummaryV4>,
    },
    RecoveryBegin {
        terminal: TerminalSummary,
        recovery_id: String,
        cutover_state_seq: u64,
        total_bytes: u64,
        chunk_count: u32,
        digest: String,
        manifest: Box<CapabilityManifestV4>,
    },
    AttachedReady {
        terminal: TerminalSummary,
        state_seq: u64,
        input_epoch: u64,
        lease_id: String,
    },
    /// Every state event queued for this attachment precedes this reply. Once
    /// this reply is queued, no later state event for the detached lease can
    /// be queued on the same connection.
    Detached {
        terminal_id: String,
        state_seq: u64,
    },
    InputReceipt {
        /// The normalized event has been encoded and accepted into the
        /// broker-owned bounded PTY queue. This is not a kernel-delivery ack;
        /// a later terminal write failure revokes the attachment and requires
        /// resynchronization instead of pretending delivery succeeded.
        terminal_id: String,
        input_epoch: u64,
        input_seq: u64,
        lease_id: String,
        event_digest: String,
        observed_state_seq: u64,
        layout_epoch: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        pointer_disposition: Option<PointerDisposition>,
    },
    Accepted,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct TerminalSummaryV4 {
    #[serde(flatten)]
    pub terminal: TerminalSummary,
    pub state_seq: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_binding: Option<DeclaredSessionBindingV1>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum WireStateEvent {
    PtyBytes {
        state_seq: u64,
        #[serde(with = "base64_bytes")]
        data: Vec<u8>,
    },
    Resize {
        state_seq: u64,
        columns: u16,
        rows: u16,
        cell_width_px: u16,
        cell_height_px: u16,
        layout_epoch: u64,
    },
    HistoryTrim {
        state_seq: u64,
        history_epoch: u64,
        first_retained_line: u64,
    },
    CanonicalCheckpoint {
        state_seq: u64,
        checkpoint_id: String,
    },
}

impl From<&StateEvent> for WireStateEvent {
    fn from(event: &StateEvent) -> Self {
        match &event.payload {
            StateEventPayload::PtyBytes(data) => Self::PtyBytes {
                state_seq: event.state_seq,
                data: data.clone(),
            },
            StateEventPayload::Resize {
                columns,
                rows,
                cell_width_px,
                cell_height_px,
                layout_epoch,
            } => Self::Resize {
                state_seq: event.state_seq,
                columns: *columns,
                rows: *rows,
                cell_width_px: *cell_width_px,
                cell_height_px: *cell_height_px,
                layout_epoch: *layout_epoch,
            },
            StateEventPayload::HistoryTrim {
                history_epoch,
                first_retained_line,
            } => Self::HistoryTrim {
                state_seq: event.state_seq,
                history_epoch: *history_epoch,
                first_retained_line: *first_retained_line,
            },
            StateEventPayload::CanonicalCheckpoint { checkpoint_id } => Self::CanonicalCheckpoint {
                state_seq: event.state_seq,
                checkpoint_id: checkpoint_id.clone(),
            },
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Command {
    Create {
        create_nonce: String,
        program: String,
        #[serde(default)]
        args: Vec<String>,
        #[serde(default)]
        current_directory: Option<String>,
        #[serde(default)]
        environment: HashMap<String, String>,
        columns: u16,
        rows: u16,
    },
    List,
    Attach {
        terminal_id: String,
        broker_generation: u64,
        after_cursor: Option<u64>,
    },
    Input {
        terminal_id: String,
        broker_generation: u64,
        input_epoch: u64,
        lease_id: String,
        #[serde(with = "base64_bytes")]
        data: Vec<u8>,
    },
    Resize {
        terminal_id: String,
        broker_generation: u64,
        input_epoch: u64,
        lease_id: String,
        columns: u16,
        rows: u16,
    },
    Terminate {
        terminal_id: String,
        broker_generation: u64,
    },
    Forget {
        terminal_id: String,
        broker_generation: u64,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ServerMessage {
    pub version: u16,
    pub broker_generation: u64,
    #[serde(flatten)]
    pub body: ServerBody,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerBody {
    Hello {
        pid: u32,
        build: String,
        capabilities: Vec<String>,
    },
    Reply {
        id: u64,
        #[serde(flatten)]
        result: Reply,
    },
    Error {
        id: u64,
        code: ErrorCode,
        message: String,
    },
    Output {
        terminal_id: String,
        cursor: u64,
        #[serde(with = "base64_bytes")]
        data: Vec<u8>,
    },
    Exited {
        terminal_id: String,
        status: Option<i32>,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum Reply {
    Created {
        terminal: TerminalSummary,
    },
    Listed {
        terminals: Vec<TerminalSummary>,
    },
    Attached {
        terminal: TerminalSummary,
        input_epoch: u64,
        lease_id: String,
        recovery: Recovery,
    },
    Accepted,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "mode", rename_all = "snake_case")]
pub enum Recovery {
    Snapshot {
        cursor: u64,
        format: String,
        scope: String,
        snapshot_version: u16,
        #[serde(with = "base64_bytes")]
        data: Vec<u8>,
    },
    Resume {
        deltas: Vec<WireDelta>,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct WireDelta {
    pub cursor: u64,
    #[serde(with = "base64_bytes")]
    pub data: Vec<u8>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct TerminalSummary {
    pub id: String,
    pub create_nonce: String,
    pub cursor: u64,
    pub columns: u16,
    pub rows: u16,
    /// Current pointer/resize coordinate-space generation. A newly attached
    /// desktop must advance from this value instead of restarting at zero.
    pub layout_epoch: u64,
    pub running: bool,
    pub foreground_process: bool,
    /// Immutable recovery state is intentionally visible to diagnostics. An
    /// evicted checkpoint means the PTY and live engine are still running,
    /// but a fresh checkpoint must be exported before the next attachment.
    #[serde(default)]
    pub checkpoint_state: CheckpointStateV4,
    #[serde(default)]
    pub checkpoint_bytes: u64,
    #[serde(default)]
    pub recovery_tail_bytes: u64,
    #[serde(default)]
    pub checkpoint_evictions: u64,
    #[serde(default)]
    pub checkpoint_rebuilds: u64,
    #[serde(default)]
    pub recovery_pause_count: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recovery_paused_ms: Option<u64>,
    /// Set on v4 list projections when an attachment, subscription, or pinned
    /// recovery makes this checkpoint ineligible for inactive eviction.
    #[serde(default)]
    pub checkpoint_protected: bool,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CheckpointStateV4 {
    Resident,
    #[default]
    Evicted,
    Paused,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    BadVersion,
    BadRequest,
    NotFound,
    LimitReached,
    QueueFull,
    StaleGeneration,
    StaleLease,
    InputConflict,
    InputGap,
    Unsupported,
    InvalidDimensions,
    SpawnFailed,
    ResyncRequired,
    Internal,
}

struct ByteQueue {
    chunks: VecDeque<Vec<u8>>,
    front_offset: usize,
    bytes: usize,
    limit: usize,
    emergency_reserved: usize,
}

impl ByteQueue {
    fn new(limit: usize) -> Self {
        Self {
            chunks: VecDeque::new(),
            front_offset: 0,
            bytes: 0,
            limit,
            emergency_reserved: 0,
        }
    }

    fn push(&mut self, bytes: Vec<u8>) -> Result<(), ()> {
        if bytes.len() > self.remaining() {
            return Err(());
        }
        self.chunks.try_reserve(1).map_err(|_| ())?;
        self.push_reserved(bytes);
        Ok(())
    }

    fn reserve_chunk(&mut self, bytes: usize) -> Result<(), ()> {
        if bytes > self.remaining() {
            return Err(());
        }
        self.chunks.try_reserve(1).map_err(|_| ())
    }

    fn push_reserved(&mut self, bytes: Vec<u8>) {
        debug_assert!(bytes.len() <= self.remaining());
        self.bytes += bytes.len();
        self.chunks.push_back(bytes);
    }

    fn is_empty(&self) -> bool {
        self.chunks.is_empty()
    }

    fn remaining(&self) -> usize {
        self.limit
            .saturating_sub(self.bytes)
            .saturating_sub(self.emergency_reserved)
    }

    fn reserve_emergency(&mut self, bytes: usize) -> Result<(), ()> {
        if bytes > self.remaining() {
            return Err(());
        }
        self.emergency_reserved += bytes;
        Ok(())
    }

    fn release_emergency(&mut self, bytes: usize) {
        debug_assert!(bytes <= self.emergency_reserved);
        self.emergency_reserved = self.emergency_reserved.saturating_sub(bytes);
    }

    fn front(&self) -> Option<&[u8]> {
        self.chunks.front().map(|v| &v[self.front_offset..])
    }

    fn consume(&mut self, count: usize) {
        self.bytes = self.bytes.saturating_sub(count);
        self.front_offset += count;
        if self
            .chunks
            .front()
            .is_some_and(|v| self.front_offset == v.len())
        {
            self.chunks.pop_front();
            self.front_offset = 0;
        }
    }
}

struct Client {
    _stream: UnixStream,
    incarnation: u64,
    input: Vec<u8>,
    output: ByteQueue,
    subscriptions: HashMap<String, AttachmentLease>,
    protocol_version: u16,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct AttachmentLease {
    input_epoch: u64,
    lease_id: String,
}

struct Terminal {
    id: String,
    create_nonce: String,
    create_signature: CreateSignature,
    surface_provenance: Option<SurfaceProvenance>,
    master: OwnedFd,
    child_pid: libc::pid_t,
    cursor: u64,
    columns: u16,
    rows: u16,
    canonical: Option<CanonicalTerminalState>,
    live_engine_config: LiveTerminalEngineConfig,
    live_engine: Option<Box<dyn LiveTerminalEngine>>,
    live_checkpoint: Option<LiveEngineCheckpoint>,
    live_engine_failure: Option<String>,
    input_failure: Option<String>,
    live_engine_activity: Option<u64>,
    live_engine_compressed_activity: Option<u64>,
    live_engine_idle_since: Instant,
    live_recovery_paused: Option<String>,
    live_recovery_paused_since: Option<Instant>,
    checkpoint_evictions: u64,
    checkpoint_rebuilds: u64,
    recovery_pause_count: u64,
    deltas: Option<DeltaWindow>,
    ordered_state: OrderedStateLog,
    pending_output: Vec<u8>,
    pending_output_since: Option<Instant>,
    input: ByteQueue,
    input_epoch: u64,
    lease_id: String,
    lease_holder: Option<RawFd>,
    next_input_seq: u64,
    input_receipts: VecDeque<InputReceipt>,
    pointer_routes: [Option<PointerGesture>; 11],
    layout_epoch: u64,
    running: bool,
    exit_status: Option<i32>,
    termination: Option<Termination>,
    termination_waiters: Vec<TerminationWaiter>,
}

struct SurfaceProvenance {
    creator_client_incarnation: u64,
    /// A Terminal is inserted only after the CLOEXEC spawn-status pipe has
    /// observed successful exec. Keeping that fact explicit prevents a future
    /// alternate spawn path from silently weakening IdentifySurface.
    exec_startup_proven: bool,
    producer_receipt: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct InputReceipt {
    input_epoch: u64,
    input_seq: u64,
    event_digest: String,
    metadata: InputReceiptMetadata,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct InputReceiptMetadata {
    pointer_disposition: Option<PointerDisposition>,
    observed_state_seq: u64,
    layout_epoch: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PointerRouteCommit {
    None,
    Set {
        index: usize,
        gesture: PointerGesture,
    },
    Clear {
        index: usize,
        gesture: PointerGesture,
    },
    Update {
        index: usize,
        gesture: PointerGesture,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct PointerGesture {
    id: u64,
    disposition: PointerDisposition,
    button: NormalizedMouseButton,
    modifiers: u16,
    x_q8: i32,
    y_q8: i32,
    cleanup_reservation: usize,
}

// A Ghostty mouse release is currently at most a few dozen bytes even with
// pixel coordinates. Keep this deliberately generous and reserve it at press
// admission time: detach and transport-loss cleanup must never compete with
// ordinary queued input after the broker has acknowledged a PTY-routed press.
const POINTER_CLEANUP_RESERVATION_BYTES: usize = 128;

/// Cross-language digest for a normalized input event. The preimage is fixed
/// binary data rather than JSON, so dictionary order and escaping cannot
/// change receipt identity across AppKit, Rust, or a future mobile client.
pub fn normalized_input_event_digest_v1(event: &NormalizedInputEvent) -> String {
    let digest = normalized_input_event_digest_bytes_v1(event);
    let mut encoded = String::with_capacity(7 + digest.len() * 2);
    encoded.push_str("sha256:");
    for byte in digest {
        use std::fmt::Write as _;
        write!(&mut encoded, "{byte:02x}").expect("writing to String cannot fail");
    }
    encoded
}

fn normalized_input_event_digest_bytes_v1(event: &NormalizedInputEvent) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(b"ourocode-terminal-input-normalized-v1\0");
    match event {
        NormalizedInputEvent::Key {
            hid_usage,
            action,
            modifiers,
            consumed_modifiers,
            composing,
            unshifted_codepoint,
            utf8,
        } => {
            hasher.update([0]);
            hasher.update(hid_usage.to_be_bytes());
            hasher.update([*action as u8]);
            hasher.update(modifiers.to_be_bytes());
            hasher.update(consumed_modifiers.to_be_bytes());
            hasher.update([u8::from(*composing)]);
            hasher.update(unshifted_codepoint.to_be_bytes());
            digest_bytes(&mut hasher, utf8);
        }
        NormalizedInputEvent::CommittedText { utf8 } => {
            hasher.update([1]);
            digest_bytes(&mut hasher, utf8);
        }
        NormalizedInputEvent::MouseGeometry {
            layout_epoch,
            geometry,
        } => {
            hasher.update([2]);
            hasher.update(layout_epoch.to_be_bytes());
            digest_mouse_geometry(&mut hasher, geometry);
        }
        NormalizedInputEvent::Mouse {
            gesture_id,
            layout_epoch,
            action,
            button,
            modifiers,
            x_q8,
            y_q8,
        } => {
            hasher.update([3]);
            hasher.update(gesture_id.to_be_bytes());
            hasher.update(layout_epoch.to_be_bytes());
            hasher.update([*action as u8, *button as u8]);
            hasher.update(modifiers.to_be_bytes());
            hasher.update(x_q8.to_be_bytes());
            hasher.update(y_q8.to_be_bytes());
        }
        NormalizedInputEvent::Scroll {
            gesture_id,
            layout_epoch,
            direction,
            modifiers,
            x_q8,
            y_q8,
        } => {
            hasher.update([4]);
            hasher.update(gesture_id.to_be_bytes());
            hasher.update(layout_epoch.to_be_bytes());
            hasher.update([*direction as u8]);
            hasher.update(modifiers.to_be_bytes());
            hasher.update(x_q8.to_be_bytes());
            hasher.update(y_q8.to_be_bytes());
        }
        NormalizedInputEvent::Paste { utf8 } => {
            hasher.update([5]);
            digest_bytes(&mut hasher, utf8);
        }
        NormalizedInputEvent::Focus { focused } => {
            hasher.update([6, u8::from(*focused)]);
        }
    }
    hasher.finalize().into()
}

fn normalized_input_event_digest_matches_v1(event: &NormalizedInputEvent, encoded: &str) -> bool {
    let Some(hex) = encoded.strip_prefix("sha256:") else {
        return false;
    };
    if hex.len() != 64 {
        return false;
    }
    let expected = normalized_input_event_digest_bytes_v1(event);
    hex.as_bytes()
        .chunks_exact(2)
        .zip(expected)
        .all(|(pair, expected)| decode_hex_byte(pair) == Some(expected))
}

fn decode_hex_byte(pair: &[u8]) -> Option<u8> {
    fn nibble(value: u8) -> Option<u8> {
        match value {
            b'0'..=b'9' => Some(value - b'0'),
            b'a'..=b'f' => Some(value - b'a' + 10),
            _ => None,
        }
    }
    let high = nibble(pair.first().copied()?)?;
    let low = nibble(pair.get(1).copied()?)?;
    Some((high << 4) | low)
}

fn digest_mouse_geometry(hasher: &mut Sha256, geometry: &NormalizedMouseGeometry) {
    for value in [
        geometry.screen_width_q8,
        geometry.screen_height_q8,
        geometry.cell_width_q8,
        geometry.cell_height_q8,
        geometry.padding_top_q8,
        geometry.padding_bottom_q8,
        geometry.padding_right_q8,
        geometry.padding_left_q8,
    ] {
        hasher.update(value.to_be_bytes());
    }
}

fn digest_bytes(hasher: &mut Sha256, bytes: &[u8]) {
    hasher.update((bytes.len() as u64).to_be_bytes());
    hasher.update(bytes);
}

fn normalized_input_error(error: io::Error) -> (ErrorCode, String) {
    let code = match error.kind() {
        io::ErrorKind::InvalidInput => ErrorCode::BadRequest,
        io::ErrorKind::Unsupported => ErrorCode::Unsupported,
        _ => ErrorCode::Internal,
    };
    (code, error.to_string())
}

fn try_clone_string(value: &str) -> Option<String> {
    let mut cloned = String::new();
    cloned.try_reserve_exact(value.len()).ok()?;
    cloned.push_str(value);
    Some(cloned)
}

fn pointer_bad_request(message: impl Into<String>) -> (ErrorCode, String) {
    (ErrorCode::BadRequest, message.into())
}

fn classify_pointer_route(
    terminal: &mut Terminal,
    event: &NormalizedInputEvent,
) -> Result<(Option<PointerDisposition>, PointerRouteCommit), (ErrorCode, String)> {
    let event_layout_epoch = match event {
        NormalizedInputEvent::MouseGeometry { layout_epoch, .. }
        | NormalizedInputEvent::Mouse { layout_epoch, .. }
        | NormalizedInputEvent::Scroll { layout_epoch, .. } => *layout_epoch,
        _ => return Ok((None, PointerRouteCommit::None)),
    };
    if event_layout_epoch != terminal.layout_epoch {
        return Err(pointer_bad_request(format!(
            "pointer layout epoch {event_layout_epoch} is stale; expected {}",
            terminal.layout_epoch
        )));
    }

    match event {
        NormalizedInputEvent::MouseGeometry { geometry, .. } => {
            if geometry.screen_width_q8 == 0
                || geometry.screen_height_q8 == 0
                || geometry.cell_width_q8 == 0
                || geometry.cell_height_q8 == 0
            {
                return Err(pointer_bad_request("pointer geometry must be non-zero"));
            }
            let disposition = terminal
                .live_engine
                .as_mut()
                .ok_or_else(|| {
                    (
                        ErrorCode::ResyncRequired,
                        "canonical terminal input context is unavailable".into(),
                    )
                })?
                .pointer_disposition(event)
                .map_err(normalized_input_error)?;
            Ok((disposition, PointerRouteCommit::None))
        }
        NormalizedInputEvent::Mouse {
            gesture_id,
            action,
            button,
            modifiers,
            x_q8,
            y_q8,
            ..
        } => {
            if *gesture_id == 0 || *x_q8 < 0 || *y_q8 < 0 {
                return Err(pointer_bad_request(
                    "pointer gesture id and coordinates must be positive",
                ));
            }
            let index = button.route_index();
            match action {
                NormalizedMouseAction::Press => {
                    let index = index.ok_or_else(|| {
                        pointer_bad_request("pointer press requires a concrete button")
                    })?;
                    if terminal.pointer_routes[index].is_some() {
                        return Err(pointer_bad_request(
                            "pointer button already belongs to an active gesture",
                        ));
                    }
                    let disposition = terminal
                        .live_engine
                        .as_mut()
                        .ok_or_else(|| {
                            (
                                ErrorCode::ResyncRequired,
                                "canonical terminal input context is unavailable".into(),
                            )
                        })?
                        .pointer_disposition(event)
                        .map_err(normalized_input_error)?
                        .ok_or_else(|| {
                            (
                                ErrorCode::Internal,
                                "pointer press produced no disposition".into(),
                            )
                        })?;
                    Ok((
                        Some(disposition),
                        PointerRouteCommit::Set {
                            index,
                            gesture: PointerGesture {
                                id: *gesture_id,
                                disposition,
                                button: *button,
                                modifiers: *modifiers,
                                x_q8: *x_q8,
                                y_q8: *y_q8,
                                cleanup_reservation: if disposition == PointerDisposition::Pty {
                                    POINTER_CLEANUP_RESERVATION_BYTES
                                } else {
                                    0
                                },
                            },
                        },
                    ))
                }
                NormalizedMouseAction::Motion => {
                    if let Some(index) = index {
                        let gesture = terminal.pointer_routes[index].ok_or_else(|| {
                            pointer_bad_request("pointer motion has no matching press")
                        })?;
                        if gesture.id != *gesture_id {
                            return Err(pointer_bad_request(
                                "pointer motion gesture does not match its press",
                            ));
                        }
                        Ok((
                            Some(gesture.disposition),
                            PointerRouteCommit::Update {
                                index,
                                gesture: PointerGesture {
                                    modifiers: *modifiers,
                                    x_q8: *x_q8,
                                    y_q8: *y_q8,
                                    ..gesture
                                },
                            },
                        ))
                    } else {
                        let disposition = terminal
                            .live_engine
                            .as_mut()
                            .ok_or_else(|| {
                                (
                                    ErrorCode::ResyncRequired,
                                    "canonical terminal input context is unavailable".into(),
                                )
                            })?
                            .pointer_disposition(event)
                            .map_err(normalized_input_error)?;
                        Ok((disposition, PointerRouteCommit::None))
                    }
                }
                NormalizedMouseAction::Release | NormalizedMouseAction::Cancel => {
                    let index = index.ok_or_else(|| {
                        pointer_bad_request("pointer release requires a concrete button")
                    })?;
                    let gesture = terminal.pointer_routes[index].ok_or_else(|| {
                        pointer_bad_request("pointer release has no matching press")
                    })?;
                    if gesture.id != *gesture_id {
                        return Err(pointer_bad_request(
                            "pointer release gesture does not match its press",
                        ));
                    }
                    Ok((
                        Some(gesture.disposition),
                        PointerRouteCommit::Clear { index, gesture },
                    ))
                }
            }
        }
        NormalizedInputEvent::Scroll {
            gesture_id,
            x_q8,
            y_q8,
            ..
        } => {
            if *gesture_id == 0 || *x_q8 < 0 || *y_q8 < 0 {
                return Err(pointer_bad_request(
                    "scroll gesture id and coordinates must be positive",
                ));
            }
            let disposition = terminal
                .live_engine
                .as_mut()
                .ok_or_else(|| {
                    (
                        ErrorCode::ResyncRequired,
                        "canonical terminal input context is unavailable".into(),
                    )
                })?
                .pointer_disposition(event)
                .map_err(normalized_input_error)?;
            Ok((disposition, PointerRouteCommit::None))
        }
        _ => Ok((None, PointerRouteCommit::None)),
    }
}

fn prospective_input_receipt_metadata(
    terminal: &Terminal,
    input_seq: u64,
    event_digest: &str,
) -> InputReceiptMetadata {
    terminal
        .input_receipts
        .iter()
        .find(|receipt| receipt.input_seq == input_seq && receipt.event_digest == event_digest)
        .map_or(
            InputReceiptMetadata {
                pointer_disposition: None,
                observed_state_seq: terminal.ordered_state.latest_seq(),
                layout_epoch: terminal.layout_epoch,
            },
            |receipt| receipt.metadata,
        )
}

/// The receipt replay window is bounded independently of terminal lifetime.
/// Clients normally use stop-and-wait, while the small window also tolerates
/// delayed duplicate delivery without retaining one allocation per keystroke.
///
/// Encoding is two-pass. The ABI v6 zero-capacity pass is explicitly
/// retry-safe (including mouse last-cell/pressed-button state). Queue capacity
/// and fallible allocation are checked before the second, committing encode;
/// the single reactor guarantees `ByteQueue::push` cannot race that preflight.
#[allow(clippy::too_many_arguments)]
fn accept_normalized_input(
    terminal: &mut Terminal,
    fd: RawFd,
    input_epoch: u64,
    input_seq: u64,
    lease_id: &str,
    event_digest: &str,
    event: &NormalizedInputEvent,
) -> Result<InputReceiptMetadata, (ErrorCode, String)> {
    if let Some(reason) = &terminal.input_failure {
        return Err((
            ErrorCode::ResyncRequired,
            format!("terminal input delivery is no longer trustworthy: {reason}"),
        ));
    }
    if terminal.input_epoch != input_epoch
        || terminal.lease_id != lease_id
        || terminal.lease_holder != Some(fd)
    {
        return Err((
            ErrorCode::StaleLease,
            "normalized input authority was replaced".into(),
        ));
    }
    if input_seq == 0 || input_seq == u64::MAX {
        return Err((
            ErrorCode::BadRequest,
            "input_seq must be between 1 and u64::MAX - 1".into(),
        ));
    }
    if !normalized_input_event_digest_matches_v1(event, event_digest) {
        return Err((
            ErrorCode::InputConflict,
            "event_digest does not match the normalized event".into(),
        ));
    }
    if input_seq < terminal.next_input_seq {
        return match terminal
            .input_receipts
            .iter()
            .find(|receipt| receipt.input_seq == input_seq)
        {
            Some(receipt)
                if receipt.input_epoch == input_epoch && receipt.event_digest == event_digest =>
            {
                Ok(receipt.metadata)
            }
            _ => Err((
                ErrorCode::InputConflict,
                format!(
                    "input_seq {input_seq} conflicts with committed input; expected {}",
                    terminal.next_input_seq
                ),
            )),
        };
    }
    if input_seq > terminal.next_input_seq {
        return Err((
            ErrorCode::InputGap,
            format!(
                "input_seq gap: received {input_seq}, expected {}",
                terminal.next_input_seq
            ),
        ));
    }
    let receipt_digest = try_clone_string(event_digest).ok_or_else(|| {
        (
            ErrorCode::LimitReached,
            "could not reserve normalized input receipt".into(),
        )
    })?;
    if terminal.input_receipts.len() < INPUT_RECEIPT_CACHE_LIMIT {
        terminal.input_receipts.try_reserve(1).map_err(|_| {
            (
                ErrorCode::LimitReached,
                "could not reserve normalized input receipt slot".into(),
            )
        })?;
    }

    let observed_state_seq = terminal.ordered_state.latest_seq();
    let layout_epoch = terminal.layout_epoch;
    let (pointer_disposition, pointer_route_commit) = classify_pointer_route(terminal, event)?;
    let cleanup_transition = match pointer_route_commit {
        PointerRouteCommit::Set { gesture, .. } if gesture.cleanup_reservation != 0 => {
            terminal
                .input
                .reserve_emergency(gesture.cleanup_reservation)
                .map_err(|_| {
                    (
                        ErrorCode::QueueFull,
                        "terminal input queue cannot reserve a matching pointer cancel".into(),
                    )
                })?;
            Some((true, gesture.cleanup_reservation))
        }
        PointerRouteCommit::Clear { gesture, .. } if gesture.cleanup_reservation != 0 => {
            terminal
                .input
                .release_emergency(gesture.cleanup_reservation);
            Some((false, gesture.cleanup_reservation))
        }
        _ => None,
    };
    let encoded = encode_normalized_input_for_queue(terminal, event, pointer_disposition);
    let bytes = match encoded {
        Ok(bytes) => bytes,
        Err(error) => {
            if let Some((reserved, bytes)) = cleanup_transition {
                if reserved {
                    terminal.input.release_emergency(bytes);
                } else {
                    // This reservation existed before the attempted release;
                    // restoring it cannot fail because no bytes were queued.
                    terminal
                        .input
                        .reserve_emergency(bytes)
                        .expect("pointer cleanup reservation rollback");
                }
            }
            return Err(error);
        }
    };
    if !bytes.is_empty() {
        terminal.input.push_reserved(bytes);
    }
    match pointer_route_commit {
        PointerRouteCommit::None => {}
        PointerRouteCommit::Set { index, gesture }
        | PointerRouteCommit::Update { index, gesture } => {
            terminal.pointer_routes[index] = Some(gesture);
        }
        PointerRouteCommit::Clear { index, .. } => {
            terminal.pointer_routes[index] = None;
        }
    }
    let metadata = InputReceiptMetadata {
        pointer_disposition,
        observed_state_seq,
        layout_epoch,
    };
    let receipt = InputReceipt {
        input_epoch,
        input_seq,
        event_digest: receipt_digest,
        metadata,
    };
    terminal.next_input_seq += 1;
    if terminal.input_receipts.len() == INPUT_RECEIPT_CACHE_LIMIT {
        terminal.input_receipts.pop_front();
    }
    terminal.input_receipts.push_back(receipt);
    Ok(metadata)
}

fn encode_normalized_input_for_queue(
    terminal: &mut Terminal,
    event: &NormalizedInputEvent,
    pointer_disposition: Option<PointerDisposition>,
) -> Result<Vec<u8>, (ErrorCode, String)> {
    let engine = terminal.live_engine.as_mut().ok_or_else(|| {
        (
            ErrorCode::ResyncRequired,
            "canonical terminal input context is unavailable".into(),
        )
    })?;
    let mut empty = [];
    let preflight = if matches!(
        pointer_disposition,
        Some(PointerDisposition::LocalSelection | PointerDisposition::LocalScrollback)
    ) {
        LiveTerminalInputEncode::Written(0)
    } else {
        engine
            .encode_normalized_input(event, &mut empty)
            .map_err(normalized_input_error)?
    };
    Ok(match preflight {
        LiveTerminalInputEncode::Written(0) => Vec::new(),
        LiveTerminalInputEncode::Written(_) => {
            return Err((
                ErrorCode::Internal,
                "terminal input encoder wrote into a zero-capacity preflight".into(),
            ));
        }
        LiveTerminalInputEncode::BufferTooSmall { required } => {
            if required == 0 {
                return Err((
                    ErrorCode::Internal,
                    "terminal input encoder returned an empty retry requirement".into(),
                ));
            }
            if required > terminal.input.remaining() {
                return Err((
                    ErrorCode::QueueFull,
                    format!(
                        "terminal input queue is full: requires {required} bytes, {} available",
                        terminal.input.remaining()
                    ),
                ));
            }
            terminal.input.reserve_chunk(required).map_err(|_| {
                (
                    ErrorCode::LimitReached,
                    "could not reserve terminal input queue slot".into(),
                )
            })?;
            let mut output = Vec::new();
            output.try_reserve_exact(required).map_err(|_| {
                (
                    ErrorCode::LimitReached,
                    "could not allocate bounded terminal input encoding".into(),
                )
            })?;
            output.resize(required, 0);
            match engine
                .encode_normalized_input(event, &mut output)
                .map_err(normalized_input_error)?
            {
                LiveTerminalInputEncode::Written(written) if written <= output.len() => {
                    output.truncate(written);
                    output
                }
                LiveTerminalInputEncode::Written(_) => {
                    return Err((
                        ErrorCode::Internal,
                        "terminal input encoder exceeded its preflight size".into(),
                    ));
                }
                LiveTerminalInputEncode::BufferTooSmall { .. } => {
                    return Err((
                        ErrorCode::Internal,
                        "terminal input encoder changed size after preflight".into(),
                    ));
                }
            }
        }
    })
}

/// Resolve every broker-owned press before its attachment or input encoder is
/// discarded. PTY gestures consume the capacity reserved with their press;
/// local gestures have no child-side state and can be dropped directly.
fn cancel_active_pointer_gestures(terminal: &mut Terminal) -> Result<(), (ErrorCode, String)> {
    for index in 0..terminal.pointer_routes.len() {
        let Some(gesture) = terminal.pointer_routes[index] else {
            continue;
        };
        if gesture.disposition != PointerDisposition::Pty {
            terminal.pointer_routes[index] = None;
            continue;
        }

        terminal
            .input
            .release_emergency(gesture.cleanup_reservation);
        let cancel = NormalizedInputEvent::Mouse {
            gesture_id: gesture.id,
            layout_epoch: terminal.layout_epoch,
            action: NormalizedMouseAction::Cancel,
            button: gesture.button,
            modifiers: gesture.modifiers,
            x_q8: gesture.x_q8,
            y_q8: gesture.y_q8,
        };
        match encode_normalized_input_for_queue(terminal, &cancel, Some(PointerDisposition::Pty)) {
            Ok(bytes) => {
                if !bytes.is_empty() {
                    terminal.input.push_reserved(bytes);
                }
                terminal.pointer_routes[index] = None;
            }
            Err(error) => {
                terminal
                    .input
                    .reserve_emergency(gesture.cleanup_reservation)
                    .expect("pointer cleanup reservation rollback");
                return Err(error);
            }
        }
    }
    Ok(())
}

/// A failed PTY can no longer consume cleanup bytes. Local routes are safe to
/// discard, but PTY routes remain explicit until the child is hung up/reaped;
/// clearing them here would falsely claim that a release was delivered.
fn retain_undelivered_pty_pointer_routes(routes: &mut [Option<PointerGesture>]) -> bool {
    for route in routes.iter_mut() {
        if route.is_some_and(|gesture| gesture.disposition != PointerDisposition::Pty) {
            *route = None;
        }
    }
    routes.iter().any(Option::is_some)
}

#[derive(Clone)]
struct LiveEngineCheckpoint {
    state_seq: u64,
    config: LiveTerminalEngineConfig,
    bytes: Arc<[u8]>,
}

fn restore_live_engine_from_checkpoint(
    terminal: &mut Terminal,
    factory: &dyn LiveTerminalEngineFactory,
) -> io::Result<()> {
    if let Err((_, message)) = cancel_active_pointer_gestures(terminal) {
        let reason =
            format!("engine replacement could not deliver active pointer cancel: {message}");
        terminal.input_failure = Some(reason.clone());
        if terminal.running {
            signal_terminal(terminal, libc::SIGHUP);
        }
        terminal.revoke_input_lease_preserving_pointer_state();
        return Err(io::Error::other(reason));
    }
    let checkpoint = terminal
        .live_checkpoint
        .clone()
        .ok_or_else(|| io::Error::other("live terminal checkpoint is unavailable"))?;
    let tail: Vec<StateEvent> = terminal
        .ordered_state
        .events_after(checkpoint.state_seq)
        .map_err(|error| io::Error::other(format!("live terminal recovery tail: {error:?}")))?
        .into_iter()
        .cloned()
        .collect();
    // A checkpoint contains terminal state, not the transient Ghostty input
    // sidecar (pressed mouse buttons, motion dedupe, paste/focus encoder
    // state). Replacing the engine while preserving the lease would let a
    // client continue from an input history the broker no longer owns.
    terminal.revoke_input_lease();
    terminal.live_engine = None;
    let mut restored = factory.restore(checkpoint.config, &checkpoint.bytes)?;
    for event in &tail {
        match &event.payload {
            StateEventPayload::PtyBytes(bytes) => {
                restored.feed(bytes)?;
                // Historical query replies were already written when the
                // event was live. Replay rebuilds state but never duplicates
                // those writes into the child process.
                let _ = restored.take_pty_responses()?;
            }
            StateEventPayload::Resize {
                columns,
                rows,
                cell_width_px,
                cell_height_px,
                ..
            } => restored.resize(
                *columns,
                *rows,
                u32::from(*cell_width_px),
                u32::from(*cell_height_px),
            )?,
            StateEventPayload::HistoryTrim { .. }
            | StateEventPayload::CanonicalCheckpoint { .. } => {}
        }
    }
    terminal.live_engine_activity = restored.compression_activity()?;
    terminal.live_engine_compressed_activity = None;
    terminal.live_engine_idle_since = Instant::now();
    terminal.live_engine = Some(restored);
    terminal.live_engine_failure = None;
    Ok(())
}

fn preserve_live_recovery_capacity(
    terminal: &mut Terminal,
    next_event_bytes: usize,
    max_snapshot_bytes: usize,
    checkpoint_bytes: usize,
    max_checkpoint_bytes: usize,
    rotation_reserve_bytes: usize,
) -> io::Result<usize> {
    let Some(checkpoint) = terminal.live_checkpoint.as_ref() else {
        return Ok(checkpoint_bytes);
    };
    if terminal.ordered_state.dropped_through() > checkpoint.state_seq {
        return Err(io::Error::other(
            "ordered recovery tail already passed the live checkpoint",
        ));
    }
    if next_event_bytes > terminal.ordered_state.maximum_bytes() {
        return Err(io::Error::new(
            io::ErrorKind::FileTooLarge,
            "one terminal state event exceeds the ordered recovery tail budget",
        ));
    }
    let required_tail_bytes = terminal
        .ordered_state
        .retained_bytes()
        .saturating_add(next_event_bytes);
    let soft_limit = terminal
        .ordered_state
        .maximum_bytes()
        .saturating_sub(rotation_reserve_bytes);
    if required_tail_bytes <= soft_limit {
        return Ok(checkpoint_bytes);
    }

    let state_seq = terminal.ordered_state.latest_seq();
    let checkpoint_result = terminal
        .live_engine
        .as_mut()
        .ok_or_else(|| io::Error::other("live terminal engine is unavailable"))?
        .export_checkpoint();
    let bytes = match checkpoint_result {
        Ok(bytes) => bytes,
        // A bounded parser continuation can make a checkpoint temporarily
        // unavailable. The reserve above lets those bytes continue until the
        // parser reaches ground; only the hard tail boundary fails closed.
        Err(_) if required_tail_bytes <= terminal.ordered_state.maximum_bytes() => {
            return Ok(checkpoint_bytes);
        }
        Err(error) => return Err(error),
    };
    if bytes.len() > max_snapshot_bytes {
        return Err(io::Error::new(
            io::ErrorKind::FileTooLarge,
            "live terminal checkpoint exceeds snapshot budget",
        ));
    }
    let old_checkpoint_bytes = checkpoint.bytes.len();
    let next_checkpoint_bytes = checkpoint_bytes
        .saturating_sub(old_checkpoint_bytes)
        .checked_add(bytes.len())
        .ok_or_else(|| io::Error::other("live checkpoint accounting overflow"))?;
    if next_checkpoint_bytes > max_checkpoint_bytes {
        return Err(io::Error::other(
            "global immutable live checkpoint budget reached",
        ));
    }
    let replacement = LiveEngineCheckpoint {
        state_seq,
        config: terminal.live_engine_config,
        bytes: bytes.into(),
    };
    terminal
        .ordered_state
        .checkpoint_through(state_seq)
        .map_err(|error| io::Error::other(format!("checkpoint tail rotation: {error:?}")))?;
    terminal.live_checkpoint = Some(replacement);
    Ok(next_checkpoint_bytes)
}

fn live_checkpoint_rotation_required(
    terminal: &Terminal,
    next_event_bytes: usize,
    rotation_reserve_bytes: usize,
) -> bool {
    if terminal.live_checkpoint.is_none() {
        // An evicted/degraded terminal intentionally uses the ordinary
        // bounded journal until its next successful fresh attachment.
        return false;
    }
    terminal
        .ordered_state
        .retained_bytes()
        .saturating_add(next_event_bytes)
        > terminal
            .ordered_state
            .maximum_bytes()
            .saturating_sub(rotation_reserve_bytes)
}

struct PinnedRecovery {
    client_fd: RawFd,
    client_incarnation: u64,
    terminal_id: String,
    cutover_state_seq: u64,
    digest: String,
    bytes: Arc<[u8]>,
    expires_at: Instant,
}

struct AbortedRecovery {
    recovery_id: String,
    client_incarnation: u64,
    terminal_id: String,
    expires_at: Instant,
}

struct TerminationWaiter {
    fd: RawFd,
    client_incarnation: u64,
    request_id: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct CreateSignature {
    session_binding: Option<DeclaredSessionBindingV1>,
    program: String,
    args: Vec<String>,
    current_directory: Option<String>,
    environment: HashMap<String, String>,
    columns: u16,
    rows: u16,
}

struct Termination {
    stage: u8,
    deadline: Instant,
}

struct TerminalTombstone {
    summary: TerminalSummary,
    create_signature: CreateSignature,
    state_seq: u64,
    _exit_status: Option<i32>,
}

pub struct Broker {
    config: BrokerConfig,
    listener: UnixListener,
    generation: u64,
    next_terminal: u64,
    next_lease: u64,
    next_client_incarnation: u64,
    clients: HashMap<RawFd, Client>,
    terminals: HashMap<String, Terminal>,
    tombstones: VecDeque<TerminalTombstone>,
    client_round_robin: usize,
    terminal_round_robin: usize,
    engine_compression_round_robin: usize,
    protocol_version: u16,
    manifest_v4: Option<CapabilityManifestV4>,
    checkpoint_provider: Option<Arc<dyn CheckpointProvider>>,
    live_engine_factory: Option<Arc<dyn LiveTerminalEngineFactory>>,
    live_checkpoint_bytes: usize,
    recoveries: HashMap<String, PinnedRecovery>,
    pinned_recovery_bytes: usize,
    aborted_recoveries: VecDeque<AbortedRecovery>,
}

impl Broker {
    pub fn bind(config: BrokerConfig) -> io::Result<Self> {
        Self::bind_inner(config, PROTOCOL_VERSION, None, None, None)
    }

    pub fn bind_v4(
        config: BrokerConfig,
        manifest: CapabilityManifestV4,
        checkpoint_provider: Arc<dyn CheckpointProvider>,
    ) -> io::Result<Self> {
        Self::validate_v4_configuration(&config, &manifest)?;
        Self::bind_inner(
            config,
            PROTOCOL_VERSION_V4,
            Some(manifest),
            Some(checkpoint_provider),
            None,
        )
    }

    /// Bind protocol v4 to broker-owned live terminal engines.
    ///
    /// Unlike `bind_v4`, this path never constructs a canonical checkpoint
    /// from the ANSI fixture provider. Each terminal engine is created with
    /// the PTY, receives every byte/resize mutation, and exports its own
    /// exact-pin checkpoint.
    pub fn bind_v4_engine(
        config: BrokerConfig,
        manifest: CapabilityManifestV4,
        live_engine_factory: Arc<dyn LiveTerminalEngineFactory>,
    ) -> io::Result<Self> {
        Self::validate_v4_configuration(&config, &manifest)?;
        Self::bind_inner(
            config,
            PROTOCOL_VERSION_V4,
            Some(manifest),
            None,
            Some(live_engine_factory),
        )
    }

    fn validate_v4_configuration(
        config: &BrokerConfig,
        manifest: &CapabilityManifestV4,
    ) -> io::Result<()> {
        manifest.validate()?;
        if manifest.max_snapshot_bytes != config.max_snapshot_bytes as u64
            || manifest.max_terminal_history_bytes != config.max_terminal_history_bytes as u64
            || manifest.max_global_history_bytes != config.max_global_history_bytes as u64
            || manifest.max_delta_bytes != config.max_delta_bytes as u64
            || manifest.max_recovery_pinned_bytes != config.max_recovery_pinned_bytes as u64
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "v4 manifest budgets do not match broker configuration",
            ));
        }
        Ok(())
    }

    pub fn bind_v4_fixture(config: BrokerConfig) -> io::Result<Self> {
        let manifest = CapabilityManifestV4::canonical_replay_fixture(&config);
        Self::bind_v4(config, manifest, Arc::new(CanonicalReplayCheckpoint))
    }

    fn bind_inner(
        config: BrokerConfig,
        protocol_version: u16,
        manifest_v4: Option<CapabilityManifestV4>,
        checkpoint_provider: Option<Arc<dyn CheckpointProvider>>,
        live_engine_factory: Option<Arc<dyn LiveTerminalEngineFactory>>,
    ) -> io::Result<Self> {
        config.validate()?;
        // Generate the incarnation before touching the socket path. A CSPRNG
        // failure must not leave behind a newly-created, unusable endpoint.
        let generation = broker_generation()?;
        prepare_socket(&config.socket_path)?;
        let previous_umask = unsafe { libc::umask(0o177) };
        let listener_result = UnixListener::bind(&config.socket_path);
        unsafe { libc::umask(previous_umask) };
        let listener = listener_result?;
        fs::set_permissions(&config.socket_path, fs::Permissions::from_mode(0o600))?;
        listener.set_nonblocking(true)?;
        set_cloexec(listener.as_raw_fd())?;
        Ok(Self {
            config,
            listener,
            generation,
            next_terminal: 1,
            next_lease: 1,
            next_client_incarnation: 1,
            clients: HashMap::new(),
            terminals: HashMap::new(),
            tombstones: VecDeque::new(),
            client_round_robin: 0,
            terminal_round_robin: 0,
            engine_compression_round_robin: 0,
            protocol_version,
            manifest_v4,
            checkpoint_provider,
            live_engine_factory,
            live_checkpoint_bytes: 0,
            recoveries: HashMap::new(),
            pinned_recovery_bytes: 0,
            aborted_recoveries: VecDeque::new(),
        })
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn run(mut self) -> io::Result<()> {
        loop {
            self.tick()?;
        }
    }

    pub fn tick(&mut self) -> io::Result<()> {
        let mut pollfds = Vec::with_capacity(1 + self.clients.len() + self.terminals.len());
        pollfds.push(libc::pollfd {
            fd: self.listener.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        });
        for (&fd, client) in &self.clients {
            let mut events = libc::POLLIN;
            if !client.output.is_empty() {
                events |= libc::POLLOUT;
            }
            pollfds.push(libc::pollfd {
                fd,
                events,
                revents: 0,
            });
        }
        for terminal in self.terminals.values() {
            if terminal.running {
                let events = terminal_poll_events(
                    terminal.live_recovery_paused.is_some(),
                    !terminal.input.is_empty() && terminal.input_failure.is_none(),
                );
                pollfds.push(libc::pollfd {
                    fd: terminal.master.as_raw_fd(),
                    events,
                    revents: 0,
                });
            }
        }
        let timeout = self.next_poll_timeout().as_millis().min(i32::MAX as u128) as i32;
        let result =
            unsafe { libc::poll(pollfds.as_mut_ptr(), pollfds.len() as libc::nfds_t, timeout) };
        if result < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(io_error_context("poll broker reactor descriptors", error));
            }
        }

        let ready: HashMap<RawFd, i16> = pollfds.into_iter().map(|p| (p.fd, p.revents)).collect();
        if ready
            .get(&self.listener.as_raw_fd())
            .is_some_and(|v| v & libc::POLLIN != 0)
        {
            self.accept_clients()
                .map_err(|error| io_error_context("accept ready broker clients", error))?;
        }
        let mut client_fds: Vec<_> = self.clients.keys().copied().collect();
        client_fds.sort_unstable();
        if !client_fds.is_empty() {
            let rotation = self.client_round_robin % client_fds.len();
            client_fds.rotate_left(rotation);
            self.client_round_robin = self.client_round_robin.wrapping_add(1);
        }
        for fd in client_fds {
            let buffered_request = self
                .clients
                .get(&fd)
                .is_some_and(|client| client.input.contains(&b'\n'));
            let mut revents = ready.get(&fd).copied().unwrap_or(0);
            if buffered_request {
                revents |= libc::POLLIN;
            }
            if revents != 0 {
                self.service_client(fd, revents);
            }
        }
        let mut terminal_ids: Vec<_> = self.terminals.keys().cloned().collect();
        terminal_ids.sort_unstable();
        if !terminal_ids.is_empty() {
            let rotation = self.terminal_round_robin % terminal_ids.len();
            terminal_ids.rotate_left(rotation);
            self.terminal_round_robin = self.terminal_round_robin.wrapping_add(1);
        }
        for id in terminal_ids {
            let Some(terminal) = self.terminals.get(&id) else {
                continue;
            };
            let revents = ready
                .get(&terminal.master.as_raw_fd())
                .copied()
                .unwrap_or(0);
            if revents & libc::POLLIN != 0 {
                self.read_terminal(&id);
            }
            if revents & libc::POLLOUT != 0
                || (revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0
                    && self
                        .terminals
                        .get(&id)
                        .is_some_and(|terminal| !terminal.input.is_empty()))
            {
                self.write_terminal(&id);
            }
            if revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0 {
                self.reap_terminal(&id);
            }
        }
        self.flush_due_outputs();
        self.compress_idle_live_engines();
        self.expire_recoveries();
        self.advance_terminations();
        self.reap_all();
        Ok(())
    }

    fn accept_clients(&mut self) -> io::Result<()> {
        for _ in 0..self.config.max_accepts_per_tick {
            match self.listener.accept() {
                Ok((stream, _)) => {
                    if self.clients.len() >= self.config.max_clients {
                        continue;
                    }
                    if verify_peer_uid(stream.as_raw_fd()).is_err() {
                        // Credential lookup failures and foreign UIDs both
                        // fail closed for this connection. They must not take
                        // down the broker or consume a client slot.
                        continue;
                    }
                    stream.set_nonblocking(true).map_err(|error| {
                        io_error_context("set accepted client nonblocking", error)
                    })?;
                    if let Err(error) = configure_client_socket(stream.as_raw_fd()) {
                        let peer_closed_during_admission = error.raw_os_error()
                            == Some(libc::EINVAL)
                            && accepted_peer_is_closed(stream.as_raw_fd()).map_err(
                                |probe_error| {
                                    io_error_context(
                                        "probe accepted client after socket configuration failed",
                                        probe_error,
                                    )
                                },
                            )?;
                        if peer_closed_during_admission {
                            // On macOS SO_NOSIGPIPE returns EINVAL when the
                            // accepted peer closes between getpeereid and
                            // setsockopt. EOF proves this individual admission
                            // is already dead; reject it without taking down the
                            // listener. EINVAL on a live peer still propagates.
                            continue;
                        }
                        return Err(io_error_context("configure accepted client socket", error));
                    }
                    set_cloexec(stream.as_raw_fd()).map_err(|error| {
                        io_error_context("set accepted client close-on-exec", error)
                    })?;
                    let fd = stream.as_raw_fd();
                    let incarnation = self.next_client_incarnation;
                    self.next_client_incarnation = self
                        .next_client_incarnation
                        .checked_add(1)
                        .expect("client incarnation space exhausted");
                    let mut client = Client {
                        _stream: stream,
                        incarnation,
                        input: Vec::new(),
                        output: ByteQueue::new(self.config.max_client_queue_bytes),
                        subscriptions: HashMap::new(),
                        protocol_version: self.protocol_version,
                    };
                    let hello = if self.protocol_version == PROTOCOL_VERSION_V4 {
                        let mut capabilities = vec![
                            CAPABILITY_ORDERED_STATE_V4.into(),
                            CAPABILITY_TWO_PHASE_RECOVERY_V4.into(),
                            CAPABILITY_LEASE_DETACH_V4.into(),
                            CAPABILITY_DECLARED_SESSION_BINDING_V1.into(),
                            CAPABILITY_IDENTIFY_SURFACE_V1.into(),
                            CAPABILITY_CREATE_IDEMPOTENCY.into(),
                            CAPABILITY_REAPED_TERMINATION.into(),
                        ];
                        if self
                            .live_engine_factory
                            .as_ref()
                            .is_some_and(|factory| factory.supports_normalized_input())
                        {
                            capabilities.push(CAPABILITY_NORMALIZED_INPUT_V1.into());
                        }
                        if self
                            .live_engine_factory
                            .as_ref()
                            .is_some_and(|factory| factory.supports_pointer_disposition())
                        {
                            capabilities.push(CAPABILITY_POINTER_DISPOSITION_V1.into());
                        }
                        let message = ServerMessageV4 {
                            version: PROTOCOL_VERSION_V4,
                            broker_generation: self.generation,
                            body: ServerBodyV4::Hello {
                                pid: std::process::id(),
                                build: BROKER_BUILD.to_owned(),
                                capabilities,
                                manifest: self
                                    .manifest_v4
                                    .as_ref()
                                    .expect("v4 broker has manifest")
                                    .clone(),
                            },
                        };
                        encode_message(&message)
                    } else {
                        encode_message(
                            &self.message(ServerBody::Hello {
                                pid: std::process::id(),
                                build: BROKER_BUILD.to_owned(),
                                capabilities: BROKER_CAPABILITIES
                                    .iter()
                                    .map(|capability| (*capability).to_owned())
                                    .collect(),
                            }),
                        )
                    };
                    if hello.and_then(|bytes| client.output.push(bytes)).is_ok() {
                        self.clients.insert(fd, client);
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(()),
                Err(error) => {
                    return Err(io_error_context("accept Unix client from listener", error))
                }
            }
        }
        Ok(())
    }

    fn service_client(&mut self, fd: RawFd, revents: i16) {
        if revents & libc::POLLIN != 0 && !self.read_client(fd) {
            self.drop_client(fd);
            return;
        }
        if revents & libc::POLLOUT != 0 && !self.write_client(fd) {
            self.drop_client(fd);
            return;
        }
        if revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0 {
            self.drop_client(fd);
        }
    }

    fn read_client(&mut self, fd: RawFd) -> bool {
        let mut scratch = [0u8; 16 * 1024];
        let mut read_bytes = 0usize;
        let mut requests = 0usize;
        loop {
            while requests < self.config.max_client_requests_per_tick {
                let line = {
                    let Some(client) = self.clients.get_mut(&fd) else {
                        return false;
                    };
                    client
                        .input
                        .iter()
                        .position(|b| *b == b'\n')
                        .map(|position| client.input.drain(..=position).collect::<Vec<_>>())
                };
                let Some(line) = line else { break };
                self.handle_line(fd, &line[..line.len() - 1]);
                requests += 1;
                if !self.clients.contains_key(&fd) {
                    return false;
                }
            }
            if requests >= self.config.max_client_requests_per_tick
                || read_bytes >= self.config.max_client_read_bytes_per_tick
            {
                return true;
            }
            let allowance =
                (self.config.max_client_read_bytes_per_tick - read_bytes).min(scratch.len());
            let count = unsafe { libc::read(fd, scratch.as_mut_ptr().cast(), allowance) };
            if count == 0 {
                return false;
            }
            if count < 0 {
                let error = io::Error::last_os_error();
                return error.kind() == io::ErrorKind::WouldBlock;
            }
            let count = count as usize;
            read_bytes += count;
            {
                let Some(client) = self.clients.get_mut(&fd) else {
                    return false;
                };
                if client.input.len().saturating_add(count) > self.config.max_request_bytes {
                    return false;
                }
                client.input.extend_from_slice(&scratch[..count]);
            }
        }
    }

    fn write_client(&mut self, fd: RawFd) -> bool {
        let Some(client) = self.clients.get_mut(&fd) else {
            return false;
        };
        let mut written = 0usize;
        while written < self.config.max_client_write_bytes_per_tick {
            let Some(bytes) = client.output.front() else {
                return true;
            };
            let allowance =
                (self.config.max_client_write_bytes_per_tick - written).min(bytes.len());
            let count = send_client(fd, &bytes[..allowance]);
            if count < 0 {
                let error = io::Error::last_os_error();
                return error.kind() == io::ErrorKind::WouldBlock;
            }
            let count = count as usize;
            written += count;
            client.output.consume(count);
        }
        true
    }

    fn handle_line(&mut self, fd: RawFd, line: &[u8]) {
        if self.protocol_version == PROTOCOL_VERSION_V4 {
            self.handle_line_v4(fd, line);
            return;
        }
        let request: Request = match serde_json::from_slice(line) {
            Ok(request) => request,
            Err(error) => {
                self.error(
                    fd,
                    0,
                    ErrorCode::BadRequest,
                    format!("invalid JSON: {error}"),
                );
                return;
            }
        };
        if request.version != PROTOCOL_VERSION {
            self.error(
                fd,
                request.id,
                ErrorCode::BadVersion,
                "unsupported protocol version".into(),
            );
            return;
        }
        self.handle_command(fd, request.id, request.command);
    }

    fn handle_line_v4(&mut self, fd: RawFd, line: &[u8]) {
        let request: RequestV4 = match serde_json::from_slice(line) {
            Ok(request) => request,
            Err(error) => {
                self.error_v4(
                    fd,
                    0,
                    ErrorCode::BadRequest,
                    format!("invalid JSON: {error}"),
                );
                return;
            }
        };
        if request.version != PROTOCOL_VERSION_V4 {
            self.error_v4(
                fd,
                request.id,
                ErrorCode::BadVersion,
                "unsupported protocol version".into(),
            );
            return;
        }
        self.handle_command_v4(fd, request.id, request.command);
    }

    fn handle_command_v4(&mut self, fd: RawFd, id: u64, command: CommandV4) {
        match command {
            CommandV4::Create {
                create_nonce,
                session_binding,
                program,
                args,
                current_directory,
                environment,
                columns,
                rows,
            } => {
                let Some(creator_client_incarnation) =
                    self.clients.get(&fd).map(|client| client.incarnation)
                else {
                    return;
                };
                let signature = CreateSignature {
                    session_binding,
                    program,
                    args,
                    current_directory,
                    environment,
                    columns,
                    rows,
                };
                if create_nonce.is_empty() || create_nonce.len() > 128 {
                    self.error_v4(
                        fd,
                        id,
                        ErrorCode::BadRequest,
                        "create_nonce must contain 1 to 128 bytes".into(),
                    );
                } else if let Some(existing) = self
                    .terminals
                    .values()
                    .find(|terminal| terminal.create_nonce == create_nonce)
                {
                    if existing.create_signature == signature {
                        self.reply_v4(
                            fd,
                            id,
                            ReplyV4::Created {
                                terminal: existing.summary(),
                                state_seq: existing.ordered_state.latest_seq(),
                                session_binding: existing.create_signature.session_binding.clone(),
                            },
                        );
                    } else {
                        self.error_v4(
                            fd,
                            id,
                            ErrorCode::BadRequest,
                            "create_nonce was already used with different parameters".into(),
                        );
                    }
                } else if let Some(existing) = self
                    .tombstones
                    .iter()
                    .find(|tombstone| tombstone.summary.create_nonce == create_nonce)
                {
                    if existing.create_signature == signature {
                        self.reply_v4(
                            fd,
                            id,
                            ReplyV4::Created {
                                terminal: existing.summary.clone(),
                                state_seq: existing.state_seq,
                                session_binding: existing.create_signature.session_binding.clone(),
                            },
                        );
                    } else {
                        self.error_v4(
                            fd,
                            id,
                            ErrorCode::BadRequest,
                            "create_nonce was already used with different parameters".into(),
                        );
                    }
                } else if signature.session_binding.as_ref().is_some_and(|binding| {
                    self.terminals.values().any(|terminal| {
                        terminal.create_signature.session_binding.as_ref() == Some(binding)
                    }) || self.tombstones.iter().any(|tombstone| {
                        tombstone.create_signature.session_binding.as_ref() == Some(binding)
                    })
                }) {
                    // One exact attempt may own at most one live broker PTY.
                    // This is an ambiguity guard, not an authorization check:
                    // the binding came from the request and remains merely
                    // discovery metadata.
                    self.error_v4(
                        fd,
                        id,
                        ErrorCode::BadRequest,
                        "session_binding is already registered to a terminal".into(),
                    );
                } else if self.terminals.len() >= self.config.max_terminals {
                    self.error_v4(
                        fd,
                        id,
                        ErrorCode::LimitReached,
                        "terminal limit reached".into(),
                    );
                } else if let Err(error) = CanonicalTerminalState::validate_snapshot_capacity(
                    rows,
                    columns,
                    self.config.max_snapshot_bytes,
                    self.config.max_pending_escape_bytes,
                ) {
                    self.error_v4(fd, id, ErrorCode::InvalidDimensions, error.to_string());
                } else {
                    let session_binding = signature.session_binding.clone();
                    match self.create_terminal(
                        create_nonce,
                        signature,
                        Some(creator_client_incarnation),
                    ) {
                        Ok(terminal) => self.reply_v4(
                            fd,
                            id,
                            ReplyV4::Created {
                                terminal,
                                state_seq: 0,
                                session_binding,
                            },
                        ),
                        Err(error) if error.kind() == io::ErrorKind::OutOfMemory => {
                            self.error_v4(fd, id, ErrorCode::LimitReached, error.to_string())
                        }
                        Err(error) => {
                            self.error_v4(fd, id, ErrorCode::SpawnFailed, error.to_string())
                        }
                    }
                }
            }
            CommandV4::IdentifySurface(IdentifySurfaceV1 {
                terminal_id,
                broker_generation,
                create_nonce,
                session_binding,
            }) => self.identify_surface_v4(
                fd,
                id,
                terminal_id,
                broker_generation,
                create_nonce,
                session_binding,
            ),
            CommandV4::List => {
                let mut terminals: Vec<_> = self
                    .terminals
                    .values()
                    .map(|terminal| TerminalSummaryV4 {
                        terminal: terminal
                            .summary_with_protection(self.checkpoint_is_protected(&terminal.id)),
                        state_seq: terminal.ordered_state.latest_seq(),
                        session_binding: terminal.create_signature.session_binding.clone(),
                    })
                    .collect();
                terminals.sort_by(|a, b| a.terminal.id.cmp(&b.terminal.id));
                self.reply_v4(fd, id, ReplyV4::Listed { terminals });
            }
            CommandV4::AttachPrepare {
                terminal_id,
                broker_generation,
                after_state_seq,
            } => self.attach_prepare_v4(fd, id, terminal_id, broker_generation, after_state_seq),
            CommandV4::RecoveryCommit {
                recovery_id,
                terminal_id,
                broker_generation,
                cutover_state_seq,
                digest,
            } => self.recovery_commit_v4(
                fd,
                id,
                recovery_id,
                terminal_id,
                broker_generation,
                cutover_state_seq,
                digest,
            ),
            CommandV4::RecoveryAbort {
                recovery_id,
                terminal_id,
                broker_generation,
            } => self.recovery_abort_v4(fd, id, recovery_id, terminal_id, broker_generation),
            CommandV4::Detach {
                terminal_id,
                broker_generation,
                input_epoch,
                lease_id,
            } => self.detach_v4(
                fd,
                id,
                terminal_id,
                broker_generation,
                input_epoch,
                lease_id,
            ),
            CommandV4::Input {
                terminal_id,
                broker_generation,
                input_epoch,
                lease_id,
                data,
            } => {
                if !self.check_generation_v4(fd, id, broker_generation) {
                    return;
                }
                if self
                    .live_engine_factory
                    .as_ref()
                    .is_some_and(|factory| factory.supports_normalized_input())
                {
                    self.error_v4(
                        fd,
                        id,
                        ErrorCode::Unsupported,
                        "raw PTY input is disabled; use terminal.input.normalized.v1".into(),
                    );
                    return;
                }
                let Some(terminal) = self.terminals.get_mut(&terminal_id) else {
                    self.error_v4(fd, id, ErrorCode::NotFound, "terminal not found".into());
                    return;
                };
                if terminal.input_epoch != input_epoch
                    || terminal.lease_id != lease_id
                    || terminal.lease_holder != Some(fd)
                {
                    self.error_v4(
                        fd,
                        id,
                        ErrorCode::StaleLease,
                        "input authority is unavailable until attached_ready or was replaced"
                            .into(),
                    );
                } else if data.is_empty() {
                    self.error_v4(fd, id, ErrorCode::BadRequest, "input is empty".into());
                } else if terminal.input.push(data).is_err() {
                    self.error_v4(
                        fd,
                        id,
                        ErrorCode::QueueFull,
                        "terminal input queue is full".into(),
                    );
                } else {
                    self.reply_v4(fd, id, ReplyV4::Accepted);
                }
            }
            CommandV4::NormalizedInput {
                terminal_id,
                broker_generation,
                input_epoch,
                input_seq,
                lease_id,
                event_digest,
                event,
            } => {
                if !self.check_generation_v4(fd, id, broker_generation) {
                    return;
                }
                if !self
                    .live_engine_factory
                    .as_ref()
                    .is_some_and(|factory| factory.supports_normalized_input())
                {
                    self.error_v4(
                        fd,
                        id,
                        ErrorCode::Unsupported,
                        "normalized input is unavailable for this terminal engine".into(),
                    );
                    return;
                }
                let pointer_event = matches!(
                    &event,
                    NormalizedInputEvent::MouseGeometry { .. }
                        | NormalizedInputEvent::Mouse { .. }
                        | NormalizedInputEvent::Scroll { .. }
                );
                let routed_pointer_event = matches!(
                    &event,
                    NormalizedInputEvent::Mouse { .. } | NormalizedInputEvent::Scroll { .. }
                );
                if pointer_event
                    && !self
                        .live_engine_factory
                        .as_ref()
                        .is_some_and(|factory| factory.supports_pointer_disposition())
                {
                    self.error_v4(
                        fd,
                        id,
                        ErrorCode::Unsupported,
                        "atomic pointer disposition is unavailable for this terminal engine".into(),
                    );
                    return;
                }
                let Some(receipt_context) = self.terminals.get(&terminal_id).map(|terminal| {
                    prospective_input_receipt_metadata(terminal, input_seq, &event_digest)
                }) else {
                    self.error_v4(fd, id, ErrorCode::NotFound, "terminal not found".into());
                    return;
                };
                let (Some(reply_digest), Some(reply_terminal_id), Some(reply_lease_id)) = (
                    try_clone_string(&event_digest),
                    try_clone_string(&terminal_id),
                    try_clone_string(&lease_id),
                ) else {
                    self.error_v4(
                        fd,
                        id,
                        ErrorCode::LimitReached,
                        "could not allocate normalized input receipt reply".into(),
                    );
                    return;
                };
                // Pre-encode every possible receipt before committing the
                // event. A local selection decision therefore cannot succeed
                // without a reply buffer already allocated and queue-admitted.
                let mut receipt_variants = Vec::new();
                let dispositions: &[Option<PointerDisposition>] = if routed_pointer_event {
                    &[
                        Some(PointerDisposition::Pty),
                        Some(PointerDisposition::LocalSelection),
                        Some(PointerDisposition::LocalScrollback),
                    ]
                } else {
                    &[None]
                };
                let mut receipt_capacity = 0usize;
                for pointer_disposition in dispositions {
                    let receipt = ServerMessageV4 {
                        version: PROTOCOL_VERSION_V4,
                        broker_generation: self.generation,
                        body: ServerBodyV4::Reply {
                            id,
                            result: ReplyV4::InputReceipt {
                                terminal_id: reply_terminal_id.clone(),
                                input_epoch,
                                input_seq,
                                lease_id: reply_lease_id.clone(),
                                event_digest: reply_digest.clone(),
                                observed_state_seq: receipt_context.observed_state_seq,
                                layout_epoch: receipt_context.layout_epoch,
                                pointer_disposition: *pointer_disposition,
                            },
                        },
                    };
                    let Ok(bytes) = encode_message(&receipt) else {
                        self.error_v4(
                            fd,
                            id,
                            ErrorCode::Internal,
                            "could not encode normalized input receipt reply".into(),
                        );
                        return;
                    };
                    receipt_capacity = receipt_capacity.max(bytes.len());
                    receipt_variants.push((*pointer_disposition, bytes));
                }
                let reply_reserved = self
                    .clients
                    .get_mut(&fd)
                    .is_some_and(|client| client.output.reserve_chunk(receipt_capacity).is_ok());
                if !reply_reserved {
                    self.error_v4(
                        fd,
                        id,
                        ErrorCode::QueueFull,
                        "client queue cannot accept normalized input receipt".into(),
                    );
                    return;
                }
                let result = match self.terminals.get_mut(&terminal_id) {
                    Some(terminal) => accept_normalized_input(
                        terminal,
                        fd,
                        input_epoch,
                        input_seq,
                        &lease_id,
                        &event_digest,
                        &event,
                    ),
                    None => Err((ErrorCode::NotFound, "terminal not found".into())),
                };
                match result {
                    Ok(metadata) => {
                        debug_assert_eq!(
                            (metadata.observed_state_seq, metadata.layout_epoch),
                            (
                                receipt_context.observed_state_seq,
                                receipt_context.layout_epoch
                            )
                        );
                        let receipt_bytes = receipt_variants
                            .into_iter()
                            .find_map(|(candidate, bytes)| {
                                (candidate == metadata.pointer_disposition).then_some(bytes)
                            })
                            .expect("pre-encoded receipt covers every committed disposition");
                        self.clients
                            .get_mut(&fd)
                            .expect("receipt owner disappeared inside serialized reactor")
                            .output
                            .push_reserved(receipt_bytes);
                    }
                    Err((code, message)) => self.error_v4(fd, id, code, message),
                }
            }
            CommandV4::Resize {
                terminal_id,
                broker_generation,
                input_epoch,
                lease_id,
                columns,
                rows,
                cell_width_px,
                cell_height_px,
                layout_epoch,
            } => {
                if !self.check_generation_v4(fd, id, broker_generation) {
                    return;
                }
                if cell_width_px == 0
                    || cell_height_px == 0
                    || CanonicalTerminalState::validate_snapshot_capacity(
                        rows,
                        columns,
                        self.config.max_snapshot_bytes,
                        self.config.max_pending_escape_bytes,
                    )
                    .is_err()
                {
                    self.error_v4(
                        fd,
                        id,
                        ErrorCode::InvalidDimensions,
                        "terminal and cell dimensions must be non-zero and bounded".into(),
                    );
                    return;
                }
                let live_engine_factory = self.live_engine_factory.clone();
                let max_snapshot_bytes = self.config.max_snapshot_bytes;
                let max_checkpoint_bytes = self.config.max_live_checkpoint_bytes;
                let rotation_reserve_bytes = self
                    .config
                    .max_pending_escape_bytes
                    .saturating_add(self.config.max_output_chunk_bytes);
                let checkpoint_bytes = self.live_checkpoint_bytes;
                let next_checkpoint_bytes;
                let event = {
                    let Some(terminal) = self.terminals.get_mut(&terminal_id) else {
                        self.error_v4(fd, id, ErrorCode::NotFound, "terminal not found".into());
                        return;
                    };
                    if terminal.input_epoch != input_epoch
                        || terminal.lease_id != lease_id
                        || terminal.lease_holder != Some(fd)
                    {
                        self.error_v4(
                            fd,
                            id,
                            ErrorCode::StaleLease,
                            "resize authority is unavailable until attached_ready or was replaced"
                                .into(),
                        );
                        return;
                    }
                    if terminal.pointer_routes.iter().any(Option::is_some) {
                        self.error_v4(
                            fd,
                            id,
                            ErrorCode::BadRequest,
                            "cancel active pointer gestures before resizing".into(),
                        );
                        return;
                    }
                    let current_layout_epoch = terminal.layout_epoch;
                    if layout_epoch <= current_layout_epoch {
                        self.error_v4(
                            fd,
                            id,
                            ErrorCode::BadRequest,
                            format!("layout_epoch must advance beyond {current_layout_epoch}"),
                        );
                        return;
                    }
                    let event = StateEvent {
                        state_seq: terminal.ordered_state.latest_seq().saturating_add(1),
                        payload: StateEventPayload::Resize {
                            columns,
                            rows,
                            cell_width_px,
                            cell_height_px,
                            layout_epoch,
                        },
                    };
                    next_checkpoint_bytes = match preserve_live_recovery_capacity(
                        terminal,
                        event.payload.encoded_size(),
                        max_snapshot_bytes,
                        checkpoint_bytes,
                        max_checkpoint_bytes,
                        rotation_reserve_bytes,
                    ) {
                        Ok(bytes) => bytes,
                        Err(error) => {
                            self.error_v4(fd, id, ErrorCode::LimitReached, error.to_string());
                            return;
                        }
                    };
                    if let Err(error) = set_winsize(terminal.master.as_raw_fd(), columns, rows) {
                        self.live_checkpoint_bytes = next_checkpoint_bytes;
                        self.error_v4(fd, id, ErrorCode::Internal, error.to_string());
                        return;
                    }
                    let push_result = if terminal.live_checkpoint.is_some() {
                        terminal.ordered_state.push_preserving_tail(event.clone())
                    } else {
                        terminal.ordered_state.push(event.clone())
                    };
                    push_result.expect("reserved v4 recovery tail accepts the resize");
                    let live_engine_result = terminal.live_engine.as_mut().map(|engine| {
                        engine.resize(
                            columns,
                            rows,
                            u32::from(cell_width_px),
                            u32::from(cell_height_px),
                        )
                    });
                    match live_engine_result {
                        Some(Ok(())) => {
                            terminal.live_engine_activity = terminal
                                .live_engine
                                .as_ref()
                                .and_then(|engine| engine.compression_activity().ok().flatten());
                            terminal.live_engine_compressed_activity = None;
                            terminal.live_engine_idle_since = Instant::now();
                        }
                        Some(Err(error)) => {
                            // Kernel and engine resize cannot be one syscall.
                            // The resize was journaled first, so discard the
                            // possibly partial handle and rebuild C+1..D.
                            terminal.live_engine_activity = None;
                            terminal.live_engine_compressed_activity = None;
                            let recovery = live_engine_factory.as_deref().ok_or_else(|| {
                                io::Error::other("live terminal engine factory is unavailable")
                            });
                            let recovery = recovery.and_then(|factory| {
                                restore_live_engine_from_checkpoint(terminal, factory)
                            });
                            if let Err(recovery_error) = recovery {
                                terminal.live_engine_failure = Some(format!(
                                    "live terminal engine failed while applying resize: {error}; checkpoint replay failed: {recovery_error}"
                                ));
                            }
                        }
                        None => {}
                    }
                    if let Some(canonical) = terminal.canonical.as_mut() {
                        canonical
                            .resize(rows, columns)
                            .expect("validated canonical dimensions");
                    }
                    terminal.columns = columns;
                    terminal.rows = rows;
                    terminal.live_engine_config = LiveTerminalEngineConfig {
                        columns,
                        rows,
                        cell_width_px: u32::from(cell_width_px),
                        cell_height_px: u32::from(cell_height_px),
                    };
                    terminal.layout_epoch = layout_epoch;
                    event
                };
                self.live_checkpoint_bytes = next_checkpoint_bytes;
                self.broadcast_v4(
                    &terminal_id,
                    ServerBodyV4::StateEvent {
                        terminal_id: terminal_id.clone(),
                        event: WireStateEvent::from(&event),
                    },
                );
                self.reply_v4(fd, id, ReplyV4::Accepted);
            }
            CommandV4::Terminate {
                terminal_id,
                broker_generation,
            } => {
                if !self.check_generation_v4(fd, id, broker_generation) {
                    return;
                }
                let Some(terminal) = self.terminals.get_mut(&terminal_id) else {
                    self.error_v4(fd, id, ErrorCode::NotFound, "terminal not found".into());
                    return;
                };
                if terminal.running && terminal.termination.is_none() {
                    signal_terminal(terminal, libc::SIGHUP);
                    terminal.termination = Some(Termination {
                        stage: 1,
                        deadline: Instant::now() + Duration::from_millis(250),
                    });
                }
                self.reply_v4(fd, id, ReplyV4::Accepted);
            }
            CommandV4::Forget {
                terminal_id,
                broker_generation,
            } => {
                if !self.check_generation_v4(fd, id, broker_generation) {
                    return;
                }
                if self.terminals.contains_key(&terminal_id) {
                    self.error_v4(
                        fd,
                        id,
                        ErrorCode::BadRequest,
                        "cannot forget a live terminal; terminate it first".into(),
                    );
                    return;
                }
                let Some(position) = self
                    .tombstones
                    .iter()
                    .position(|tombstone| tombstone.summary.id == terminal_id)
                else {
                    self.error_v4(fd, id, ErrorCode::NotFound, "terminal not found".into());
                    return;
                };
                self.tombstones.remove(position);
                self.reply_v4(fd, id, ReplyV4::Accepted);
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn identify_surface_v4(
        &mut self,
        fd: RawFd,
        id: u64,
        terminal_id: String,
        broker_generation: u64,
        create_nonce: String,
        session_binding: DeclaredSessionBindingV1,
    ) {
        if !self.check_generation_v4(fd, id, broker_generation) {
            return;
        }
        let Some(client_incarnation) = self.clients.get(&fd).map(|client| client.incarnation)
        else {
            return;
        };
        // A child can become a zombie between poll's readiness snapshot and
        // this request. Reap first so `running` cannot be a stale reactor
        // projection while we mint an identity receipt.
        self.reap_terminal(&terminal_id);
        let Some(terminal) = self.terminals.get(&terminal_id) else {
            self.error_v4(fd, id, ErrorCode::NotFound, "terminal not found".into());
            return;
        };
        let Some(provenance) = terminal.surface_provenance.as_ref() else {
            self.error_v4(
                fd,
                id,
                ErrorCode::Unsupported,
                "terminal was not created by the protocol-v4 surface producer".into(),
            );
            return;
        };
        if provenance.creator_client_incarnation != client_incarnation {
            self.error_v4(
                fd,
                id,
                ErrorCode::ResyncRequired,
                "surface identification is restricted to the creating connection".into(),
            );
            return;
        }
        if terminal.create_nonce != create_nonce
            || terminal.create_signature.session_binding.as_ref() != Some(&session_binding)
        {
            self.error_v4(
                fd,
                id,
                ErrorCode::BadRequest,
                "surface identity does not match the stored Create signature".into(),
            );
            return;
        }
        if !provenance.exec_startup_proven || !terminal.running {
            self.error_v4(
                fd,
                id,
                ErrorCode::ResyncRequired,
                "surface has no live successful exec to identify".into(),
            );
            return;
        }
        if let Err(error) = verify_live_surface_kernel_contract(terminal) {
            self.error_v4(
                fd,
                id,
                ErrorCode::ResyncRequired,
                format!("live PTY identity could not be proven: {error}"),
            );
            return;
        }

        let producer_receipt = match provenance.producer_receipt.as_ref() {
            Some(receipt) => receipt.clone(),
            None => match random_token() {
                Ok(receipt) => receipt,
                Err(error) => {
                    self.error_v4(
                        fd,
                        id,
                        ErrorCode::Internal,
                        format!("could not mint surface receipt: {error}"),
                    );
                    return;
                }
            },
        };
        let terminal = self
            .terminals
            .get_mut(&terminal_id)
            .expect("identified terminal remains in the single-threaded reactor");
        terminal
            .surface_provenance
            .as_mut()
            .expect("v4 surface provenance was validated")
            .producer_receipt = Some(producer_receipt.clone());
        self.reply_v4(
            fd,
            id,
            ReplyV4::SurfaceIdentified {
                terminal_id,
                create_nonce,
                session_binding,
                producer_receipt,
            },
        );
    }

    fn attach_prepare_v4(
        &mut self,
        fd: RawFd,
        id: u64,
        terminal_id: String,
        broker_generation: u64,
        after_state_seq: Option<u64>,
    ) {
        if !self.check_generation_v4(fd, id, broker_generation) {
            return;
        }
        self.expire_recoveries();
        let Some(client_incarnation) = self.clients.get(&fd).map(|client| client.incarnation)
        else {
            return;
        };
        if self.recoveries.values().any(|recovery| {
            recovery.client_fd == fd && recovery.client_incarnation == client_incarnation
        }) {
            self.error_v4(
                fd,
                id,
                ErrorCode::LimitReached,
                "one recovery per client is already active".into(),
            );
            return;
        }
        if self.recoveries.len() >= self.config.max_recoveries {
            self.error_v4(
                fd,
                id,
                ErrorCode::LimitReached,
                "global recovery limit reached".into(),
            );
            return;
        }

        if !self.terminals.contains_key(&terminal_id) {
            self.error_v4(fd, id, ErrorCode::NotFound, "terminal not found".into());
            return;
        }
        if let Some(reason) = self
            .terminals
            .get(&terminal_id)
            .and_then(|terminal| terminal.input_failure.clone())
        {
            self.error_v4(
                fd,
                id,
                ErrorCode::ResyncRequired,
                format!("terminal input delivery is no longer trustworthy: {reason}"),
            );
            return;
        }

        // A fresh recovery is a suspension boundary, not a second attachment.
        // Revoke the old input authority and live feed before the cutover is
        // flushed so checkpoint/chunk traffic cannot interleave with state_event.
        if let Some(terminal) = self.terminals.get_mut(&terminal_id) {
            // AttachPrepare is the suspension boundary for *any* prior
            // attachment.  A desktop takeover can arrive on a different fd;
            // leaving its pointer route alive while replacing the lease would
            // strand a press/drag in the new surface.
            if terminal.lease_holder.is_some() {
                if let Err((code, message)) = cancel_active_pointer_gestures(terminal) {
                    self.error_v4(
                        fd,
                        id,
                        code,
                        format!("could not safely suspend active pointer gesture: {message}"),
                    );
                    return;
                }
                terminal.lease_holder = None;
                terminal.input_epoch = terminal.input_epoch.saturating_add(1);
                terminal.lease_id.clear();
                terminal.next_input_seq = 1;
                terminal.input_receipts.clear();
                debug_assert!(terminal.pointer_routes.iter().all(Option::is_none));
            }
        }
        if let Some(client) = self.clients.get_mut(&fd) {
            client.subscriptions.remove(&terminal_id);
        }

        self.flush_terminal_output(&terminal_id);
        // AttachPrepare is visibility intent even though the old subscription
        // was just suspended. Reclaim inactive checkpoints before exporting;
        // the target itself is never an eviction candidate in this window.
        let _ = self.ensure_checkpoint_capacity(Some(&terminal_id), self.config.max_snapshot_bytes);
        let checkpoint_provider = self.checkpoint_provider.clone();
        let mut next_live_checkpoint_bytes = self.live_checkpoint_bytes;
        let (
            terminal,
            cutover_state_seq,
            engine_checkpoint,
            engine_failure,
            canonical_replay,
            columns,
            rows,
        ) = {
            let Some(terminal) = self.terminals.get_mut(&terminal_id) else {
                self.error_v4(fd, id, ErrorCode::NotFound, "terminal not found".into());
                return;
            };
            let cutover = terminal.ordered_state.latest_seq();
            if after_state_seq.is_some_and(|seq| seq > cutover) {
                self.error_v4(
                    fd,
                    id,
                    ErrorCode::ResyncRequired,
                    "client state_seq is ahead of the broker".into(),
                );
                return;
            }
            let exported_checkpoint = terminal
                .live_engine
                .as_mut()
                .map(|engine| engine.export_checkpoint());
            let engine_checkpoint = match exported_checkpoint {
                Some(Ok(bytes)) if bytes.len() > self.config.max_snapshot_bytes => {
                    Some(Err(io::Error::new(
                        io::ErrorKind::FileTooLarge,
                        "checkpoint exceeds the manifest snapshot budget",
                    )))
                }
                Some(Ok(bytes)) => {
                    let rebuilding_evicted_checkpoint = terminal.live_checkpoint.is_none();
                    let old_bytes = terminal
                        .live_checkpoint
                        .as_ref()
                        .map_or(0, |checkpoint| checkpoint.bytes.len());
                    let candidate_total = next_live_checkpoint_bytes
                        .saturating_sub(old_bytes)
                        .checked_add(bytes.len());
                    if candidate_total
                        .is_none_or(|total| total > self.config.max_live_checkpoint_bytes)
                    {
                        Some(Err(io::Error::other(
                            "global immutable live checkpoint budget reached",
                        )))
                    } else {
                        let bytes: Arc<[u8]> = bytes.into();
                        next_live_checkpoint_bytes = candidate_total.expect("checked total");
                        terminal.live_checkpoint = Some(LiveEngineCheckpoint {
                            state_seq: cutover,
                            config: terminal.live_engine_config,
                            bytes: Arc::clone(&bytes),
                        });
                        terminal
                            .ordered_state
                            .checkpoint_through(cutover)
                            .expect("checkpoint cutover is the latest broker sequence");
                        terminal.live_recovery_paused = None;
                        terminal.live_recovery_paused_since = None;
                        if rebuilding_evicted_checkpoint {
                            terminal.checkpoint_rebuilds =
                                terminal.checkpoint_rebuilds.saturating_add(1);
                        }
                        Some(Ok(bytes))
                    }
                }
                Some(Err(error)) => Some(Err(error)),
                None => None,
            };
            let engine_failure = terminal.live_engine_failure.clone();
            let canonical_replay = if engine_checkpoint.is_none() && engine_failure.is_none() {
                match terminal
                    .canonical
                    .as_ref()
                    .expect("fixture v4 terminal has an ANSI checkpoint source")
                    .snapshot()
                {
                    Ok(snapshot) => snapshot.replay,
                    Err(error) => {
                        self.error_v4(fd, id, ErrorCode::Internal, error.to_string());
                        return;
                    }
                }
            } else {
                Vec::new()
            };
            (
                terminal.summary_with_protection(true),
                cutover,
                engine_checkpoint,
                engine_failure,
                canonical_replay,
                terminal.columns,
                terminal.rows,
            )
        };
        self.live_checkpoint_bytes = next_live_checkpoint_bytes;
        let checkpoint = match engine_checkpoint {
            Some(result) => result,
            None if engine_failure.is_some() => Err(io::Error::other(
                engine_failure.expect("checked live engine failure"),
            )),
            None => match checkpoint_provider {
                Some(provider) => provider
                    .export_checkpoint(CheckpointRequest {
                        terminal_id: &terminal_id,
                        state_seq: cutover_state_seq,
                        columns,
                        rows,
                        canonical_replay: &canonical_replay,
                    })
                    .map(Arc::<[u8]>::from),
                None => Err(io::Error::other(
                    "v4 live terminal engine and checkpoint provider are unavailable",
                )),
            },
        };
        let checkpoint = match checkpoint {
            Ok(bytes) => bytes,
            Err(error) => {
                self.error_v4(fd, id, ErrorCode::Internal, error.to_string());
                return;
            }
        };
        if checkpoint.len() > self.config.max_snapshot_bytes {
            self.error_v4(
                fd,
                id,
                ErrorCode::LimitReached,
                "checkpoint exceeds the manifest snapshot budget".into(),
            );
            return;
        }
        if checkpoint.len()
            > self
                .config
                .max_recovery_pinned_bytes
                .saturating_sub(self.pinned_recovery_bytes)
        {
            self.error_v4(
                fd,
                id,
                ErrorCode::LimitReached,
                "global pinned recovery byte budget reached".into(),
            );
            return;
        }
        let manifest = self
            .manifest_v4
            .as_ref()
            .expect("v4 broker has manifest")
            .clone();
        let digest = checkpoint_digest_v4(&manifest, &checkpoint);
        let recovery_id = match random_token() {
            Ok(token) => token,
            Err(error) => {
                self.error_v4(fd, id, ErrorCode::Internal, error.to_string());
                return;
            }
        };
        let bytes = checkpoint;
        let chunk_count = bytes.len().div_ceil(RECOVERY_CHUNK_BYTES);
        if chunk_count > u32::MAX as usize {
            self.error_v4(
                fd,
                id,
                ErrorCode::LimitReached,
                "checkpoint has too many transport chunks".into(),
            );
            return;
        }
        self.pinned_recovery_bytes = self.pinned_recovery_bytes.saturating_add(bytes.len());
        self.recoveries.insert(
            recovery_id.clone(),
            PinnedRecovery {
                client_fd: fd,
                client_incarnation,
                terminal_id,
                cutover_state_seq,
                digest: digest.clone(),
                bytes: Arc::clone(&bytes),
                expires_at: Instant::now() + self.config.recovery_ttl,
            },
        );
        self.reply_v4(
            fd,
            id,
            ReplyV4::RecoveryBegin {
                terminal,
                recovery_id: recovery_id.clone(),
                cutover_state_seq,
                total_bytes: bytes.len() as u64,
                chunk_count: chunk_count as u32,
                digest: digest.clone(),
                manifest: Box::new(manifest),
            },
        );
        for (index, chunk) in bytes.chunks(RECOVERY_CHUNK_BYTES).enumerate() {
            if !self.clients.contains_key(&fd) {
                return;
            }
            self.send_v4(
                fd,
                ServerBodyV4::RecoveryChunk {
                    recovery_id: recovery_id.clone(),
                    index: index as u32,
                    data: chunk.to_vec(),
                },
            );
        }
        if self.clients.contains_key(&fd) {
            self.send_v4(
                fd,
                ServerBodyV4::RecoveryEnd {
                    recovery_id,
                    digest,
                },
            );
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn recovery_commit_v4(
        &mut self,
        fd: RawFd,
        id: u64,
        recovery_id: String,
        terminal_id: String,
        broker_generation: u64,
        cutover_state_seq: u64,
        digest: String,
    ) {
        if !self.check_generation_v4(fd, id, broker_generation) {
            return;
        }
        self.expire_recoveries();
        self.flush_terminal_output(&terminal_id);
        let Some(client_incarnation) = self.clients.get(&fd).map(|client| client.incarnation)
        else {
            return;
        };
        let valid = self.recoveries.get(&recovery_id).is_some_and(|recovery| {
            recovery.client_fd == fd
                && recovery.client_incarnation == client_incarnation
                && recovery.terminal_id == terminal_id
                && recovery.cutover_state_seq == cutover_state_seq
                && recovery.digest == digest
                && recovery.expires_at > Instant::now()
        });
        if !valid {
            self.release_recovery(&recovery_id);
            self.error_v4(
                fd,
                id,
                ErrorCode::ResyncRequired,
                "recovery identity, digest, cutover or client incarnation mismatch".into(),
            );
            return;
        }
        let (terminal_summary, ready_state_seq, events) = {
            let Some(terminal) = self.terminals.get(&terminal_id) else {
                self.release_recovery(&recovery_id);
                self.error_v4(
                    fd,
                    id,
                    ErrorCode::ResyncRequired,
                    "terminal disappeared".into(),
                );
                return;
            };
            let events = match terminal.ordered_state.events_after(cutover_state_seq) {
                Ok(events) => events.into_iter().cloned().collect::<Vec<_>>(),
                Err(_) => {
                    self.release_recovery(&recovery_id);
                    self.error_v4(
                        fd,
                        id,
                        ErrorCode::ResyncRequired,
                        "checkpoint cutover left the retained delta window".into(),
                    );
                    return;
                }
            };
            (
                terminal.summary(),
                terminal.ordered_state.latest_seq(),
                events,
            )
        };

        // Preflight the complete commit tail before granting authority. A slow
        // client gets no partial delta stream and no lease.
        let mut encoded = Vec::with_capacity(events.len().saturating_add(1));
        for event in &events {
            let message = ServerMessageV4 {
                version: PROTOCOL_VERSION_V4,
                broker_generation: self.generation,
                body: ServerBodyV4::RecoveryDelta {
                    recovery_id: recovery_id.clone(),
                    event: WireStateEvent::from(event),
                },
            };
            match encode_message(&message) {
                Ok(bytes) => encoded.push(bytes),
                Err(()) => {
                    self.release_recovery(&recovery_id);
                    self.error_v4(fd, id, ErrorCode::Internal, "could not encode delta".into());
                    return;
                }
            }
        }
        let lease_number = self.next_lease;
        self.next_lease = self.next_lease.saturating_add(1);
        let input_epoch = self
            .terminals
            .get(&terminal_id)
            .map_or(1, |terminal| terminal.input_epoch.saturating_add(1));
        let lease_id = format!("{}-{lease_number}", self.generation);
        let ready = ServerMessageV4 {
            version: PROTOCOL_VERSION_V4,
            broker_generation: self.generation,
            body: ServerBodyV4::Reply {
                id,
                result: ReplyV4::AttachedReady {
                    terminal: terminal_summary,
                    state_seq: ready_state_seq,
                    input_epoch,
                    lease_id: lease_id.clone(),
                },
            },
        };
        let Ok(ready_bytes) = encode_message(&ready) else {
            self.release_recovery(&recovery_id);
            self.error_v4(
                fd,
                id,
                ErrorCode::Internal,
                "could not encode attached_ready".into(),
            );
            return;
        };
        let required = encoded
            .iter()
            .map(Vec::len)
            .sum::<usize>()
            .saturating_add(ready_bytes.len());
        let has_capacity = self.clients.get(&fd).is_some_and(|client| {
            required <= client.output.limit.saturating_sub(client.output.bytes)
        });
        if !has_capacity {
            self.release_recovery(&recovery_id);
            self.error_v4(
                fd,
                id,
                ErrorCode::QueueFull,
                "client queue cannot atomically accept recovery deltas".into(),
            );
            return;
        }

        self.release_recovery(&recovery_id);
        let Some(terminal) = self.terminals.get_mut(&terminal_id) else {
            self.error_v4(
                fd,
                id,
                ErrorCode::ResyncRequired,
                "terminal disappeared".into(),
            );
            return;
        };
        terminal.input_epoch = input_epoch;
        terminal.lease_id = lease_id.clone();
        terminal.lease_holder = Some(fd);
        terminal.next_input_seq = 1;
        terminal.input_receipts.clear();
        debug_assert!(terminal.pointer_routes.iter().all(Option::is_none));
        if let Some(client) = self.clients.get_mut(&fd) {
            client.subscriptions.insert(
                terminal_id,
                AttachmentLease {
                    input_epoch,
                    lease_id,
                },
            );
            for bytes in encoded {
                client
                    .output
                    .push(bytes)
                    .expect("commit queue was preflighted");
            }
            client
                .output
                .push(ready_bytes)
                .expect("commit queue was preflighted");
        }
    }

    fn recovery_abort_v4(
        &mut self,
        fd: RawFd,
        id: u64,
        recovery_id: String,
        terminal_id: String,
        broker_generation: u64,
    ) {
        if !self.check_generation_v4(fd, id, broker_generation) {
            return;
        }
        self.expire_recoveries();
        let Some(client_incarnation) = self.clients.get(&fd).map(|client| client.incarnation)
        else {
            return;
        };

        if let Some(recovery) = self.recoveries.get(&recovery_id) {
            if recovery.client_fd != fd
                || recovery.client_incarnation != client_incarnation
                || recovery.terminal_id != terminal_id
            {
                self.error_v4(
                    fd,
                    id,
                    ErrorCode::ResyncRequired,
                    "recovery abort is not bound to this client incarnation and terminal".into(),
                );
                return;
            }
            self.release_recovery(&recovery_id);
            self.aborted_recoveries.push_back(AbortedRecovery {
                recovery_id,
                client_incarnation,
                terminal_id,
                expires_at: Instant::now() + self.config.recovery_ttl,
            });
            while self.aborted_recoveries.len() > self.config.max_aborted_recoveries {
                self.aborted_recoveries.pop_front();
            }
            self.reply_v4(fd, id, ReplyV4::Accepted);
            return;
        }

        let is_idempotent_retry = self.aborted_recoveries.iter().any(|aborted| {
            aborted.recovery_id == recovery_id
                && aborted.client_incarnation == client_incarnation
                && aborted.terminal_id == terminal_id
                && aborted.expires_at > Instant::now()
        });
        if is_idempotent_retry {
            self.reply_v4(fd, id, ReplyV4::Accepted);
        } else {
            self.error_v4(
                fd,
                id,
                ErrorCode::ResyncRequired,
                "recovery abort references an unknown, expired or foreign recovery".into(),
            );
        }
    }

    /// Detach is an output ordering barrier, not terminal lifecycle control.
    ///
    /// The reactor first journals and queues pending PTY bytes for the current
    /// subscription. It then validates the exact per-connection attachment
    /// lease, removes that subscription, conditionally revokes matching input
    /// authority, and finally queues `detached`. Because all of this occurs on
    /// the single reactor thread, matching state events queued before the
    /// barrier precede the reply and no matching state event can follow it.
    #[allow(clippy::too_many_arguments)]
    fn detach_v4(
        &mut self,
        fd: RawFd,
        id: u64,
        terminal_id: String,
        broker_generation: u64,
        input_epoch: u64,
        lease_id: String,
    ) {
        if !self.check_generation_v4(fd, id, broker_generation) {
            return;
        }

        self.flush_terminal_output(&terminal_id);
        let Some(state_seq) = self
            .terminals
            .get(&terminal_id)
            .map(|terminal| terminal.ordered_state.latest_seq())
        else {
            self.error_v4(fd, id, ErrorCode::NotFound, "terminal not found".into());
            return;
        };
        let requested = AttachmentLease {
            input_epoch,
            lease_id,
        };
        let valid = self
            .clients
            .get(&fd)
            .and_then(|client| client.subscriptions.get(&terminal_id))
            == Some(&requested);
        if !valid {
            self.error_v4(
                fd,
                id,
                ErrorCode::StaleLease,
                "detach requires the exact live attachment lease for this connection".into(),
            );
            return;
        }

        let owns_input = self.terminals.get(&terminal_id).is_some_and(|terminal| {
            terminal.lease_holder == Some(fd)
                && terminal.input_epoch == requested.input_epoch
                && terminal.lease_id == requested.lease_id
        });
        if owns_input {
            let cleanup = cancel_active_pointer_gestures(
                self.terminals
                    .get_mut(&terminal_id)
                    .expect("validated terminal exists"),
            );
            if let Err((code, message)) = cleanup {
                self.error_v4(
                    fd,
                    id,
                    code,
                    format!("could not safely detach active pointer gesture: {message}"),
                );
                return;
            }
        }

        if let Some(client) = self.clients.get_mut(&fd) {
            client.subscriptions.remove(&terminal_id);
        }
        if let Some(terminal) = self.terminals.get_mut(&terminal_id) {
            if owns_input {
                terminal.lease_holder = None;
                terminal.input_epoch = terminal.input_epoch.saturating_add(1);
                terminal.lease_id.clear();
                terminal.next_input_seq = 1;
                terminal.input_receipts.clear();
                debug_assert!(terminal.pointer_routes.iter().all(Option::is_none));
            }
        }
        self.reply_v4(
            fd,
            id,
            ReplyV4::Detached {
                terminal_id,
                state_seq,
            },
        );
    }

    fn handle_command(&mut self, fd: RawFd, id: u64, command: Command) {
        match command {
            Command::Create {
                create_nonce,
                program,
                args,
                current_directory,
                environment,
                columns,
                rows,
            } => {
                let signature = CreateSignature {
                    session_binding: None,
                    program,
                    args,
                    current_directory,
                    environment,
                    columns,
                    rows,
                };
                if create_nonce.is_empty() || create_nonce.len() > 128 {
                    self.error(
                        fd,
                        id,
                        ErrorCode::BadRequest,
                        "create_nonce must contain 1 to 128 bytes".into(),
                    );
                } else if let Some(existing) = self
                    .terminals
                    .values()
                    .find(|terminal| terminal.create_nonce == create_nonce)
                {
                    if existing.create_signature == signature {
                        self.reply(
                            fd,
                            id,
                            Reply::Created {
                                terminal: existing.summary(),
                            },
                        );
                    } else {
                        self.error(
                            fd,
                            id,
                            ErrorCode::BadRequest,
                            "create_nonce was already used with different parameters".into(),
                        );
                    }
                } else if let Some(existing) = self
                    .tombstones
                    .iter()
                    .find(|tombstone| tombstone.summary.create_nonce == create_nonce)
                {
                    if existing.create_signature == signature {
                        self.reply(
                            fd,
                            id,
                            Reply::Created {
                                terminal: existing.summary.clone(),
                            },
                        );
                    } else {
                        self.error(
                            fd,
                            id,
                            ErrorCode::BadRequest,
                            "create_nonce was already used with different parameters".into(),
                        );
                    }
                } else if let Err(error) = CanonicalTerminalState::validate_snapshot_capacity(
                    rows,
                    columns,
                    self.config.max_snapshot_bytes,
                    self.config.max_pending_escape_bytes,
                ) {
                    self.error(fd, id, ErrorCode::InvalidDimensions, error.to_string());
                } else if self.terminals.len() >= self.config.max_terminals {
                    self.error(
                        fd,
                        id,
                        ErrorCode::LimitReached,
                        "terminal limit reached".into(),
                    );
                } else {
                    match self.create_terminal(create_nonce, signature, None) {
                        Ok(summary) => self.reply(fd, id, Reply::Created { terminal: summary }),
                        Err(error) => self.error(fd, id, ErrorCode::SpawnFailed, error.to_string()),
                    }
                }
            }
            Command::List => {
                let mut terminals: Vec<_> =
                    self.terminals.values().map(Terminal::summary).collect();
                terminals.extend(
                    self.tombstones
                        .iter()
                        .map(|tombstone| tombstone.summary.clone()),
                );
                terminals.sort_by(|a, b| a.id.cmp(&b.id));
                self.reply(fd, id, Reply::Listed { terminals });
            }
            Command::Attach {
                terminal_id,
                broker_generation,
                after_cursor,
            } => {
                if !self.check_generation(fd, id, broker_generation) {
                    return;
                }
                let lease_number = self.next_lease;
                self.next_lease = self.next_lease.saturating_add(1);
                let generation = self.generation;
                self.flush_terminal_output(&terminal_id);
                let Some(terminal) = self.terminals.get_mut(&terminal_id) else {
                    self.error(fd, id, ErrorCode::NotFound, "terminal not found".into());
                    return;
                };
                let recovery = match after_cursor {
                    Some(cursor) => match terminal
                        .deltas
                        .as_ref()
                        .expect("v3 terminal has a delta window")
                        .resume_after(generation, cursor)
                    {
                        Resume::Deltas(deltas) => Ok(Recovery::Resume {
                            deltas: deltas
                                .into_iter()
                                .map(|d| WireDelta {
                                    cursor: d.cursor,
                                    data: match &d.payload {
                                        TerminalDeltaPayload::Output(data) => data.clone(),
                                        TerminalDeltaPayload::Resize { .. } => {
                                            // Protocol v3 cannot represent typed resize deltas.
                                            // Resize enters the v4 ordered-state contract; until
                                            // then this arm is unreachable because v3 never
                                            // inserts resize payloads into its delta window.
                                            unreachable!("v3 delta window contains a resize event")
                                        }
                                    },
                                })
                                .collect(),
                        }),
                        Resume::SnapshotRequired(_) => terminal.snapshot_recovery(),
                    },
                    None => terminal.snapshot_recovery(),
                };
                let recovery = match recovery {
                    Ok(recovery) => recovery,
                    Err(error) => {
                        self.error(fd, id, ErrorCode::Internal, error.to_string());
                        return;
                    }
                };
                terminal.input_epoch = terminal.input_epoch.saturating_add(1);
                terminal.lease_id = format!("{}-{lease_number}", generation);
                terminal.lease_holder = Some(fd);
                let reply = Reply::Attached {
                    terminal: terminal.summary(),
                    input_epoch: terminal.input_epoch,
                    lease_id: terminal.lease_id.clone(),
                    recovery,
                };
                if let Some(client) = self.clients.get_mut(&fd) {
                    client.subscriptions.insert(
                        terminal_id,
                        AttachmentLease {
                            input_epoch: terminal.input_epoch,
                            lease_id: terminal.lease_id.clone(),
                        },
                    );
                }
                self.reply(fd, id, reply);
            }
            Command::Input {
                terminal_id,
                broker_generation,
                input_epoch,
                lease_id,
                data,
            } => {
                if !self.check_generation(fd, id, broker_generation) {
                    return;
                }
                let Some(terminal) = self.terminals.get_mut(&terminal_id) else {
                    self.error(fd, id, ErrorCode::NotFound, "terminal not found".into());
                    return;
                };
                if terminal.input_epoch != input_epoch
                    || terminal.lease_id != lease_id
                    || terminal.lease_holder != Some(fd)
                {
                    self.error(
                        fd,
                        id,
                        ErrorCode::StaleLease,
                        "input authority was replaced".into(),
                    );
                } else if terminal.input.push(data).is_err() {
                    self.error(
                        fd,
                        id,
                        ErrorCode::QueueFull,
                        "terminal input queue is full".into(),
                    );
                } else {
                    self.reply(fd, id, Reply::Accepted);
                }
            }
            Command::Resize {
                terminal_id,
                broker_generation,
                input_epoch,
                lease_id,
                columns,
                rows,
            } => {
                if !self.check_generation(fd, id, broker_generation) {
                    return;
                }
                if let Err(error) = CanonicalTerminalState::validate_snapshot_capacity(
                    rows,
                    columns,
                    self.config.max_snapshot_bytes,
                    self.config.max_pending_escape_bytes,
                ) {
                    self.error(fd, id, ErrorCode::InvalidDimensions, error.to_string());
                    return;
                }
                let Some(terminal) = self.terminals.get_mut(&terminal_id) else {
                    self.error(fd, id, ErrorCode::NotFound, "terminal not found".into());
                    return;
                };
                if terminal.input_epoch != input_epoch
                    || terminal.lease_id != lease_id
                    || terminal.lease_holder != Some(fd)
                {
                    self.error(
                        fd,
                        id,
                        ErrorCode::StaleLease,
                        "resize authority was replaced".into(),
                    );
                    return;
                }
                match set_winsize(terminal.master.as_raw_fd(), columns, rows) {
                    Ok(()) => {
                        // Dimensions were validated above, so canonical resize
                        // cannot fail after the kernel accepted the winsize.
                        terminal
                            .canonical
                            .as_mut()
                            .expect("v3 terminal has canonical ANSI state")
                            .resize(rows, columns)
                            .expect("validated canonical terminal dimensions");
                        terminal.columns = columns;
                        terminal.rows = rows;
                        self.reply(fd, id, Reply::Accepted);
                    }
                    Err(error) => self.error(fd, id, ErrorCode::Internal, error.to_string()),
                }
            }
            Command::Terminate {
                terminal_id,
                broker_generation,
            } => {
                if !self.check_generation(fd, id, broker_generation) {
                    return;
                }
                let Some(client_incarnation) =
                    self.clients.get(&fd).map(|client| client.incarnation)
                else {
                    return;
                };
                if let Some(terminal) = self.terminals.get_mut(&terminal_id) {
                    if terminal.termination_waiters.len() >= 8 {
                        self.error(
                            fd,
                            id,
                            ErrorCode::QueueFull,
                            "too many pending termination acknowledgements".into(),
                        );
                        return;
                    }
                    terminal.termination_waiters.push(TerminationWaiter {
                        fd,
                        client_incarnation,
                        request_id: id,
                    });
                    if terminal.running && terminal.termination.is_none() {
                        signal_terminal(terminal, libc::SIGHUP);
                        terminal.termination = Some(Termination {
                            stage: 1,
                            deadline: Instant::now() + Duration::from_millis(250),
                        });
                    }
                } else if self
                    .tombstones
                    .iter()
                    .any(|tombstone| tombstone.summary.id == terminal_id)
                {
                    self.reply(fd, id, Reply::Accepted);
                } else {
                    self.error(fd, id, ErrorCode::NotFound, "terminal not found".into());
                }
            }
            Command::Forget {
                terminal_id,
                broker_generation,
            } => {
                if !self.check_generation(fd, id, broker_generation) {
                    return;
                }
                if self.terminals.contains_key(&terminal_id) {
                    self.error(
                        fd,
                        id,
                        ErrorCode::BadRequest,
                        "cannot forget a live terminal; terminate it first".into(),
                    );
                    return;
                }
                let Some(position) = self
                    .tombstones
                    .iter()
                    .position(|tombstone| tombstone.summary.id == terminal_id)
                else {
                    self.error(fd, id, ErrorCode::NotFound, "terminal not found".into());
                    return;
                };
                self.tombstones.remove(position);
                self.reply(fd, id, Reply::Accepted);
            }
        }
    }

    fn create_terminal(
        &mut self,
        create_nonce: String,
        signature: CreateSignature,
        creator_client_incarnation: Option<u64>,
    ) -> io::Result<TerminalSummary> {
        let columns = signature.columns;
        let rows = signature.rows;
        let live_engine_config = LiveTerminalEngineConfig {
            columns,
            rows,
            // Create does not carry pixel geometry. The ordered v4 resize
            // path supplies the authoritative values before a renderer relies
            // on them.
            cell_width_px: 8,
            cell_height_px: 16,
        };
        let mut live_engine = self
            .live_engine_factory
            .as_ref()
            .map(|factory| factory.create(live_engine_config))
            .transpose()?;
        let mut live_checkpoint = live_engine
            .as_mut()
            .map(|engine| engine.export_checkpoint())
            .transpose()?
            .map(|bytes| {
                if bytes.len() > self.config.max_snapshot_bytes {
                    return Err(io::Error::new(
                        io::ErrorKind::FileTooLarge,
                        "initial live terminal checkpoint exceeds snapshot budget",
                    ));
                }
                Ok(LiveEngineCheckpoint {
                    state_seq: 0,
                    config: live_engine_config,
                    bytes: bytes.into(),
                })
            })
            .transpose()?;
        let mut live_checkpoint_len = live_checkpoint
            .as_ref()
            .map_or(0, |checkpoint| checkpoint.bytes.len());
        let mut initial_checkpoint_evictions = 0;
        if live_checkpoint_len > 0 && !self.ensure_checkpoint_capacity(None, live_checkpoint_len) {
            // Admission must not turn a bounded recovery cache into a terminal
            // count limit. The new PTY starts in an explicit degraded state
            // and rebuilds its checkpoint when a client actually attaches.
            live_checkpoint = None;
            live_checkpoint_len = 0;
            initial_checkpoint_evictions = 1;
        }
        let live_engine_activity = live_engine
            .as_ref()
            .map(|engine| engine.compression_activity())
            .transpose()?
            .flatten();
        let canonical =
            if self.protocol_version == PROTOCOL_VERSION_V4 && self.live_engine_factory.is_some() {
                None
            } else {
                Some(
                    CanonicalTerminalState::new(
                        rows,
                        columns,
                        self.config.canonical_scrollback_lines,
                        self.config.max_snapshot_bytes,
                        self.config.max_pending_escape_bytes,
                    )
                    .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?,
                )
            };
        let (master, pid) = spawn_pty(
            &signature.program,
            &signature.args,
            signature.current_directory.as_deref(),
            &signature.environment,
            signature.columns,
            signature.rows,
        )?;
        let id = format!("term-{}", self.next_terminal);
        self.next_terminal = self.next_terminal.saturating_add(1);
        let terminal = Terminal {
            id: id.clone(),
            create_nonce,
            create_signature: signature,
            surface_provenance: creator_client_incarnation.map(|incarnation| SurfaceProvenance {
                creator_client_incarnation: incarnation,
                exec_startup_proven: true,
                producer_receipt: None,
            }),
            master,
            child_pid: pid,
            cursor: 0,
            columns,
            rows,
            canonical,
            live_engine_config,
            live_engine,
            live_checkpoint,
            live_engine_failure: None,
            input_failure: None,
            live_engine_activity,
            live_engine_compressed_activity: None,
            live_engine_idle_since: Instant::now(),
            live_recovery_paused: None,
            live_recovery_paused_since: None,
            checkpoint_evictions: initial_checkpoint_evictions,
            checkpoint_rebuilds: 0,
            recovery_pause_count: 0,
            deltas: (self.protocol_version != PROTOCOL_VERSION_V4
                || self.live_engine_factory.is_none())
            .then(|| DeltaWindow::new(self.generation, self.config.max_delta_bytes)),
            ordered_state: OrderedStateLog::new(self.config.max_delta_bytes),
            pending_output: Vec::new(),
            pending_output_since: None,
            input: ByteQueue::new(self.config.max_terminal_input_bytes),
            input_epoch: 0,
            lease_id: String::new(),
            lease_holder: None,
            next_input_seq: 1,
            input_receipts: VecDeque::new(),
            pointer_routes: [None; 11],
            layout_epoch: 0,
            running: true,
            exit_status: None,
            termination: None,
            termination_waiters: Vec::new(),
        };
        let summary = terminal.summary();
        self.live_checkpoint_bytes = self
            .live_checkpoint_bytes
            .saturating_add(live_checkpoint_len);
        self.terminals.insert(id, terminal);
        Ok(summary)
    }

    fn read_terminal(&mut self, id: &str) {
        if self
            .terminals
            .get(id)
            .is_some_and(|terminal| terminal.live_recovery_paused.is_some())
        {
            return;
        }
        let mut scratch = [0u8; 16 * 1024];
        let mut read_bytes = 0usize;
        while read_bytes < self.config.max_terminal_read_bytes_per_tick {
            let pending_bytes = self
                .terminals
                .get(id)
                .map_or(0, |terminal| terminal.pending_output.len());
            if pending_bytes >= self.config.max_output_chunk_bytes {
                self.flush_terminal_output(id);
                // A checkpoint rotation can fail while the bounded pending
                // chunk remains intact. Returning applies PTY backpressure and
                // lets other terminals, clients, and maintenance work run;
                // retrying the unchanged chunk here would spin inside one
                // reactor turn and starve the entire broker.
                if self.terminals.get(id).is_some_and(|terminal| {
                    terminal.pending_output.len() >= self.config.max_output_chunk_bytes
                }) {
                    return;
                }
                continue;
            }
            let allowance = (self.config.max_terminal_read_bytes_per_tick - read_bytes)
                .min(self.config.max_output_chunk_bytes - pending_bytes)
                .min(scratch.len());
            let count = {
                let Some(terminal) = self.terminals.get_mut(id) else {
                    return;
                };
                unsafe {
                    libc::read(
                        terminal.master.as_raw_fd(),
                        scratch.as_mut_ptr().cast(),
                        allowance,
                    )
                }
            };
            if count == 0 {
                self.flush_terminal_output(id);
                self.reap_terminal(id);
                return;
            }
            if count < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::WouldBlock {
                    return;
                }
                self.flush_terminal_output(id);
                self.reap_terminal(id);
                return;
            }
            let count = count as usize;
            read_bytes += count;
            let should_flush = {
                let terminal = self
                    .terminals
                    .get_mut(id)
                    .expect("terminal exists while reading");
                if terminal.pending_output.is_empty() {
                    terminal.pending_output_since = Some(Instant::now());
                }
                terminal.pending_output.extend_from_slice(&scratch[..count]);
                terminal.pending_output.len() >= self.config.max_output_chunk_bytes
            };
            if should_flush {
                self.flush_terminal_output(id);
            }
        }
    }

    fn flush_terminal_output(&mut self, id: &str) {
        let protocol_version = self.protocol_version;
        let has_live_engine_factory = self.live_engine_factory.is_some();
        let live_engine_factory = self.live_engine_factory.clone();
        let max_snapshot_bytes = self.config.max_snapshot_bytes;
        let max_checkpoint_bytes = self.config.max_live_checkpoint_bytes;
        let rotation_reserve_bytes = self
            .config
            .max_pending_escape_bytes
            .saturating_add(self.config.max_output_chunk_bytes);
        let rotation_required = self.terminals.get(id).is_some_and(|terminal| {
            live_checkpoint_rotation_required(
                terminal,
                terminal.pending_output.len(),
                rotation_reserve_bytes,
            )
        });
        if rotation_required
            && !self.ensure_checkpoint_capacity(Some(id), max_snapshot_bytes)
            && !self.checkpoint_is_protected(id)
        {
            // A headless terminal must never lose PTY POLLIN merely because
            // the immutable cache is saturated by protected surfaces. Degrade
            // this inactive checkpoint and continue with the bounded journal.
            self.evict_inactive_checkpoint(id);
        }
        let mut checkpoint_bytes = self.live_checkpoint_bytes;
        let output = {
            let Some(terminal) = self.terminals.get_mut(id) else {
                return;
            };
            if terminal.pending_output.is_empty() {
                return;
            }
            let mut data = std::mem::take(&mut terminal.pending_output);
            terminal.pending_output = Vec::new();
            terminal.pending_output_since = None;
            let raw_v4_event = if protocol_version == PROTOCOL_VERSION_V4 {
                match preserve_live_recovery_capacity(
                    terminal,
                    data.len(),
                    max_snapshot_bytes,
                    checkpoint_bytes,
                    max_checkpoint_bytes,
                    rotation_reserve_bytes,
                ) {
                    Ok(next_checkpoint_bytes) => {
                        checkpoint_bytes = next_checkpoint_bytes;
                        terminal.live_recovery_paused = None;
                        terminal.live_recovery_paused_since = None;
                    }
                    Err(error) => {
                        terminal.pending_output = data;
                        terminal.pending_output_since = Some(Instant::now());
                        if terminal.live_recovery_paused.is_none() {
                            terminal.recovery_pause_count =
                                terminal.recovery_pause_count.saturating_add(1);
                            terminal.live_recovery_paused_since = Some(Instant::now());
                        }
                        terminal.live_recovery_paused = Some(format!(
                            "ordered recovery tail is full and checkpoint rotation failed: {error}"
                        ));
                        return;
                    }
                }
                let event = StateEvent {
                    state_seq: terminal.ordered_state.latest_seq().saturating_add(1),
                    payload: StateEventPayload::PtyBytes(std::mem::take(&mut data)),
                };
                let push_result = if terminal.live_checkpoint.is_some() {
                    terminal.ordered_state.push_preserving_tail(event.clone())
                } else {
                    terminal.ordered_state.push(event.clone())
                };
                push_result.expect("reserved v4 recovery tail accepts the event");
                Some(event)
            } else {
                None
            };
            let engine_bytes = raw_v4_event
                .as_ref()
                .and_then(|event| match &event.payload {
                    StateEventPayload::PtyBytes(bytes) => Some(bytes.as_slice()),
                    _ => None,
                })
                .unwrap_or(data.as_slice());
            let live_engine_result = terminal.live_engine.as_mut().map(|engine| {
                engine.feed(engine_bytes)?;
                engine.take_pty_responses()
            });
            match live_engine_result {
                Some(Ok(pty_responses)) => {
                    if !pty_responses.is_empty() && terminal.input.push(pty_responses).is_err() {
                        terminal.live_engine_failure = Some(
                            "terminal query response exceeded the bounded PTY input queue".into(),
                        );
                    }
                    terminal.live_engine_activity = terminal
                        .live_engine
                        .as_ref()
                        .and_then(|engine| engine.compression_activity().ok().flatten());
                    terminal.live_engine_compressed_activity = None;
                    terminal.live_engine_idle_since = Instant::now();
                }
                Some(Err(error)) => {
                    // The exact engine may have applied an arbitrary prefix.
                    // Drop that handle and reconstruct only from immutable C
                    // plus the broker-owned raw event tail C+1..D.
                    terminal.live_engine_activity = None;
                    terminal.live_engine_compressed_activity = None;
                    let recovery = live_engine_factory.as_deref().ok_or_else(|| {
                        io::Error::other("live terminal engine factory is unavailable")
                    });
                    let recovery = recovery
                        .and_then(|factory| restore_live_engine_from_checkpoint(terminal, factory));
                    if let Err(recovery_error) = recovery {
                        terminal.live_engine_failure = Some(format!(
                            "live terminal engine failed while processing PTY output: {error}; checkpoint replay failed: {recovery_error}"
                        ));
                    }
                }
                None => {}
            }
            let canonical_frames = terminal
                .canonical
                .as_mut()
                .map(|canonical| canonical.process(engine_bytes));
            let frames = match canonical_frames {
                None => Vec::new(),
                Some(Ok(frames)) => frames,
                Some(Err(error)) => {
                    if protocol_version == PROTOCOL_VERSION_V4 && has_live_engine_factory {
                        // The production checkpoint is owned by the live
                        // engine. The ANSI shadow is not terminal truth in
                        // this mode, so its failure cannot rewrite the raw PTY
                        // journal or the user's live byte stream.
                        Vec::new()
                    } else {
                        // Capacity is validated before create/resize and hostile
                        // control strings are parser-bounded. If an invariant is
                        // still violated, never leave subscribers silently stale:
                        // reset their parser and render an explicit terminal error.
                        terminal.cursor = terminal.cursor.saturating_add(1);
                        let cursor = terminal.cursor;
                        let diagnostic =
                            format!("\x1bc\r\n[ouro-broker recovery error: {error}]\r\n")
                                .into_bytes();
                        let _ = terminal
                            .deltas
                            .as_mut()
                            .expect("fixture and v3 terminals have a delta window")
                            .push(TerminalDelta {
                                terminal_id: id.to_owned(),
                                generation: self.generation,
                                cursor,
                                payload: TerminalDeltaPayload::Output(diagnostic.clone()),
                            });
                        let event = StateEvent {
                            state_seq: terminal.ordered_state.latest_seq().saturating_add(1),
                            payload: StateEventPayload::PtyBytes(diagnostic.clone()),
                        };
                        terminal
                            .ordered_state
                            .push(event.clone())
                            .expect("broker emits consecutive valid state events");
                        if self.protocol_version == PROTOCOL_VERSION_V4 {
                            return self.broadcast_v4(
                                id,
                                ServerBodyV4::StateEvent {
                                    terminal_id: id.to_owned(),
                                    event: WireStateEvent::from(&event),
                                },
                            );
                        }
                        return self.broadcast(
                            id,
                            ServerBody::Output {
                                terminal_id: id.to_owned(),
                                cursor,
                                data: diagnostic,
                            },
                        );
                    }
                }
            };
            if protocol_version == PROTOCOL_VERSION_V4 {
                // V4's recovery tail is the original PTY stream. Rewriting it
                // through the ANSI fixture parser would make a Ghostty
                // checkpoint plus tail non-canonical and can lose parser
                // continuation, inactive-screen, and hyperlink state.
                terminal.cursor = terminal.cursor.saturating_add(1);
                let cursor = terminal.cursor;
                let event = raw_v4_event.expect("v4 raw event is journaled before mutation");
                vec![(cursor, event, Vec::new())]
            } else {
                let mut output = Vec::with_capacity(frames.len());
                for frame in frames {
                    let data = match frame {
                        RecoveryFrame::Raw(data) => data,
                        RecoveryFrame::Resync(snapshot) => {
                            let mut reset = b"\x1bc".to_vec();
                            reset.extend(snapshot.replay);
                            reset
                        }
                    };
                    terminal.cursor = terminal.cursor.saturating_add(1);
                    let cursor = terminal.cursor;
                    let _ = terminal
                        .deltas
                        .as_mut()
                        .expect("v3 terminal has a delta window")
                        .push(TerminalDelta {
                            terminal_id: id.to_owned(),
                            generation: self.generation,
                            cursor,
                            payload: TerminalDeltaPayload::Output(data.clone()),
                        });
                    let event = StateEvent {
                        state_seq: terminal.ordered_state.latest_seq().saturating_add(1),
                        payload: StateEventPayload::PtyBytes(data.clone()),
                    };
                    terminal
                        .ordered_state
                        .push(event.clone())
                        .expect("broker emits consecutive valid state events");
                    output.push((cursor, event, data));
                }
                output
            }
        };
        self.live_checkpoint_bytes = checkpoint_bytes;
        for (cursor, event, data) in output {
            if self.protocol_version == PROTOCOL_VERSION_V4 {
                self.broadcast_v4(
                    id,
                    ServerBodyV4::StateEvent {
                        terminal_id: id.to_owned(),
                        event: WireStateEvent::from(&event),
                    },
                );
            } else {
                self.broadcast(
                    id,
                    ServerBody::Output {
                        terminal_id: id.to_owned(),
                        cursor,
                        data,
                    },
                );
            }
        }
        // A terminal query reply is generated while handling PTY-readable
        // output, after this reactor turn's POLLOUT snapshot was taken. Drain
        // it opportunistically under the ordinary per-tick write budget so a
        // headless shell does not pay another coalescing timeout.
        self.write_terminal(id);
    }

    fn flush_due_outputs(&mut self) {
        let now = Instant::now();
        let due: Vec<_> = self
            .terminals
            .iter()
            .filter(|(id, terminal)| {
                terminal
                    .pending_output_since
                    .is_some_and(|since| now.duration_since(since) >= self.output_coalesce_for(id))
            })
            .map(|(id, _)| id.clone())
            .collect();
        for id in due {
            self.flush_terminal_output(&id);
        }
    }

    fn compress_idle_live_engines(&mut self) {
        let now = Instant::now();
        let live_engine_factory = self.live_engine_factory.clone();
        let mut terminal_ids: Vec<_> = self.terminals.keys().cloned().collect();
        terminal_ids.sort_unstable();
        if !terminal_ids.is_empty() {
            let rotation = self.engine_compression_round_robin % terminal_ids.len();
            terminal_ids.rotate_left(rotation);
            self.engine_compression_round_robin =
                self.engine_compression_round_robin.wrapping_add(1);
        }

        let mut steps = 0usize;
        for id in terminal_ids {
            if steps >= self.config.max_engine_compression_steps_per_tick {
                break;
            }
            let Some(terminal) = self.terminals.get_mut(&id) else {
                continue;
            };
            let Some(expected_activity) = terminal.live_engine_activity else {
                continue;
            };
            if terminal.live_engine_compressed_activity == Some(expected_activity)
                || now.saturating_duration_since(terminal.live_engine_idle_since)
                    < self.config.engine_idle_compression_delay
            {
                continue;
            }
            let Some(engine) = terminal.live_engine.as_mut() else {
                continue;
            };
            let current_activity = match engine.compression_activity() {
                Ok(Some(activity)) => activity,
                Ok(None) | Err(_) => {
                    terminal.live_engine_compressed_activity = Some(expected_activity);
                    continue;
                }
            };
            if current_activity != expected_activity {
                terminal.live_engine_activity = Some(current_activity);
                terminal.live_engine_compressed_activity = None;
                terminal.live_engine_idle_since = now;
                continue;
            }

            steps += 1;
            match engine.compress_incremental() {
                Ok(LiveTerminalCompression::Pending) => {}
                Ok(LiveTerminalCompression::Unsupported | LiveTerminalCompression::Complete) => {
                    terminal.live_engine_compressed_activity = Some(current_activity);
                }
                Err(error) => {
                    // Compression mutates page representation. Rebuild the
                    // logical state from immutable C+tail before publishing
                    // any later checkpoint.
                    terminal.live_engine_activity = None;
                    terminal.live_engine_compressed_activity = None;
                    let recovery = live_engine_factory.as_deref().ok_or_else(|| {
                        io::Error::other("live terminal engine factory is unavailable")
                    });
                    let recovery = recovery
                        .and_then(|factory| restore_live_engine_from_checkpoint(terminal, factory));
                    if let Err(recovery_error) = recovery {
                        terminal.live_engine_failure = Some(format!(
                            "live terminal engine failed during idle compression: {error}; checkpoint replay failed: {recovery_error}"
                        ));
                    }
                }
            }
        }
    }

    fn next_poll_timeout(&self) -> Duration {
        if self
            .clients
            .values()
            .any(|client| client.input.contains(&b'\n'))
        {
            return Duration::ZERO;
        }
        let now = Instant::now();
        let output_timeout = self
            .terminals
            .iter()
            .filter_map(|(id, terminal)| terminal.pending_output_since.map(|since| (id, since)))
            .map(|(id, since)| {
                self.output_coalesce_for(id)
                    .saturating_sub(now.saturating_duration_since(since))
            })
            .fold(self.config.poll_timeout, Duration::min);
        let terminal_timeout = self
            .terminals
            .values()
            .filter_map(|terminal| terminal.termination.as_ref())
            .map(|termination| termination.deadline.saturating_duration_since(now))
            .fold(output_timeout, Duration::min);
        let recovery_timeout = self
            .recoveries
            .values()
            .map(|recovery| recovery.expires_at.saturating_duration_since(now))
            .fold(terminal_timeout, Duration::min);
        self.terminals
            .values()
            .filter(|terminal| {
                terminal.live_engine_activity.is_some()
                    && terminal.live_engine_compressed_activity != terminal.live_engine_activity
            })
            .map(|terminal| {
                self.config
                    .engine_idle_compression_delay
                    .saturating_sub(now.saturating_duration_since(terminal.live_engine_idle_since))
            })
            .fold(recovery_timeout, Duration::min)
    }

    fn output_coalesce_for(&self, terminal_id: &str) -> Duration {
        if self
            .clients
            .values()
            .any(|client| client.subscriptions.contains_key(terminal_id))
        {
            self.config.output_coalesce
        } else {
            self.config.headless_output_coalesce
        }
    }

    fn checkpoint_is_protected(&self, terminal_id: &str) -> bool {
        self.terminals
            .get(terminal_id)
            .is_some_and(|terminal| terminal.lease_holder.is_some())
            || self
                .clients
                .values()
                .any(|client| client.subscriptions.contains_key(terminal_id))
            || self
                .recoveries
                .values()
                .any(|recovery| recovery.terminal_id == terminal_id)
    }

    /// Reclaims only inactive immutable checkpoints. The mutable live engine,
    /// PTY, bounded ordered journal, and process remain alive. Eviction is an
    /// explicit degraded-recovery state: a later AttachPrepare exports a fresh
    /// checkpoint from the live engine before granting a lease.
    fn ensure_checkpoint_capacity(
        &mut self,
        protected_target: Option<&str>,
        replacement_bytes: usize,
    ) -> bool {
        let replaced_bytes = protected_target
            .and_then(|id| self.terminals.get(id))
            .and_then(|terminal| terminal.live_checkpoint.as_ref())
            .map_or(0, |checkpoint| checkpoint.bytes.len());
        let projected = self
            .live_checkpoint_bytes
            .saturating_sub(replaced_bytes)
            .checked_add(replacement_bytes);
        if projected.is_some_and(|bytes| bytes <= self.config.max_live_checkpoint_bytes) {
            return true;
        }

        let mut candidates: Vec<_> = self
            .terminals
            .iter()
            .filter_map(|(id, terminal)| {
                if protected_target.is_some_and(|target| target == id)
                    || terminal.live_checkpoint.is_none()
                    || terminal.live_engine.is_none()
                    || terminal.live_engine_failure.is_some()
                    || self.checkpoint_is_protected(id)
                {
                    return None;
                }
                let checkpoint = terminal
                    .live_checkpoint
                    .as_ref()
                    .expect("filtered resident checkpoint");
                Some((id.clone(), checkpoint.state_seq, checkpoint.bytes.len()))
            })
            .collect();
        // Quiet, old checkpoints are evicted before recently rotated ones;
        // larger checkpoints win the tie to bound the number of degradations.
        candidates.sort_by(|left, right| {
            left.1
                .cmp(&right.1)
                .then_with(|| right.2.cmp(&left.2))
                .then_with(|| left.0.cmp(&right.0))
        });

        for (id, _, _) in candidates {
            if self
                .live_checkpoint_bytes
                .saturating_sub(replaced_bytes)
                .checked_add(replacement_bytes)
                .is_some_and(|bytes| bytes <= self.config.max_live_checkpoint_bytes)
            {
                break;
            }
            self.evict_inactive_checkpoint(&id);
        }
        self.live_checkpoint_bytes
            .saturating_sub(replaced_bytes)
            .checked_add(replacement_bytes)
            .is_some_and(|bytes| bytes <= self.config.max_live_checkpoint_bytes)
    }

    fn evict_inactive_checkpoint(&mut self, terminal_id: &str) -> bool {
        if self.checkpoint_is_protected(terminal_id) {
            return false;
        }
        let Some(terminal) = self.terminals.get_mut(terminal_id) else {
            return false;
        };
        let Some(checkpoint) = terminal.live_checkpoint.take() else {
            return false;
        };
        self.live_checkpoint_bytes = self
            .live_checkpoint_bytes
            .saturating_sub(checkpoint.bytes.len());
        terminal.checkpoint_evictions = terminal.checkpoint_evictions.saturating_add(1);
        // A budget pause can now resume through the ordinary bounded journal.
        // Non-budget engine export failures stay fail-closed because callers
        // only invoke this policy after a capacity check fails.
        terminal.live_recovery_paused = None;
        terminal.live_recovery_paused_since = None;
        true
    }

    fn write_terminal(&mut self, id: &str) {
        let mut failed_holder = None;
        {
            let Some(terminal) = self.terminals.get_mut(id) else {
                return;
            };
            if terminal.input_failure.is_some() {
                return;
            }
            let mut written = 0usize;
            while written < self.config.max_terminal_write_bytes_per_tick {
                let Some(bytes) = terminal.input.front() else {
                    break;
                };
                let allowance =
                    (self.config.max_terminal_write_bytes_per_tick - written).min(bytes.len());
                let count = unsafe {
                    libc::write(
                        terminal.master.as_raw_fd(),
                        bytes.as_ptr().cast(),
                        allowance,
                    )
                };
                if count < 0 {
                    let error = io::Error::last_os_error();
                    if error.kind() == io::ErrorKind::Interrupted {
                        continue;
                    }
                    if error.kind() == io::ErrorKind::WouldBlock {
                        break;
                    }
                    failed_holder = terminal.lease_holder;
                    terminal.input_failure = Some(error.to_string());
                    terminal.lease_holder = None;
                    terminal.input_epoch = terminal.input_epoch.saturating_add(1);
                    terminal.lease_id.clear();
                    terminal.next_input_seq = 1;
                    terminal.input_receipts.clear();
                    if retain_undelivered_pty_pointer_routes(&mut terminal.pointer_routes)
                        && terminal.running
                    {
                        signal_terminal(terminal, libc::SIGHUP);
                    }
                    break;
                }
                if count == 0 {
                    failed_holder = terminal.lease_holder;
                    terminal.input_failure = Some("PTY write made no progress".into());
                    terminal.lease_holder = None;
                    terminal.input_epoch = terminal.input_epoch.saturating_add(1);
                    terminal.lease_id.clear();
                    terminal.next_input_seq = 1;
                    terminal.input_receipts.clear();
                    if retain_undelivered_pty_pointer_routes(&mut terminal.pointer_routes)
                        && terminal.running
                    {
                        signal_terminal(terminal, libc::SIGHUP);
                    }
                    break;
                }
                let count = count as usize;
                written += count;
                terminal.input.consume(count);
            }
        }
        if let Some(fd) = failed_holder {
            // The client may already have received a queue-acceptance receipt.
            // Closing its transport is the only unambiguous asynchronous
            // failure signal in v4; a reconnect then receives ResyncRequired.
            self.drop_client(fd);
        }
    }

    fn reap_terminal(&mut self, id: &str) {
        let Some(terminal) = self.terminals.get(id) else {
            return;
        };
        if !terminal.running {
            return;
        }
        let mut status = 0;
        let result = unsafe { libc::waitpid(terminal.child_pid, &mut status, libc::WNOHANG) };
        if result == terminal.child_pid {
            self.flush_terminal_output(id);
            let Some(mut terminal) = self.terminals.remove(id) else {
                return;
            };
            self.live_checkpoint_bytes = self.live_checkpoint_bytes.saturating_sub(
                terminal
                    .live_checkpoint
                    .as_ref()
                    .map_or(0, |checkpoint| checkpoint.bytes.len()),
            );
            terminal.running = false;
            terminal.exit_status = decode_wait_status(status);
            terminal.termination = None;
            let termination_waiters = std::mem::take(&mut terminal.termination_waiters);
            let create_signature = terminal.create_signature.clone();
            let status = terminal.exit_status;
            let state_seq = terminal.ordered_state.latest_seq();
            let summary = terminal.summary();
            drop(terminal);
            if self.protocol_version == PROTOCOL_VERSION_V4 {
                self.broadcast_v4(
                    id,
                    ServerBodyV4::Exited {
                        terminal_id: id.to_owned(),
                        status,
                    },
                );
            } else {
                self.broadcast(
                    id,
                    ServerBody::Exited {
                        terminal_id: id.to_owned(),
                        status,
                    },
                );
            }
            let stale_recoveries: Vec<_> = self
                .recoveries
                .iter()
                .filter(|(_, recovery)| recovery.terminal_id == id)
                .map(|(recovery_id, _)| recovery_id.clone())
                .collect();
            for recovery_id in stale_recoveries {
                self.release_recovery(&recovery_id);
            }
            for client in self.clients.values_mut() {
                client.subscriptions.remove(id);
            }
            if self.config.max_tombstones > 0 {
                self.tombstones.push_back(TerminalTombstone {
                    summary,
                    create_signature,
                    state_seq,
                    _exit_status: status,
                });
                while self.tombstones.len() > self.config.max_tombstones {
                    self.tombstones.pop_front();
                }
            }
            for waiter in termination_waiters {
                if self
                    .clients
                    .get(&waiter.fd)
                    .is_some_and(|client| client.incarnation == waiter.client_incarnation)
                {
                    self.reply(waiter.fd, waiter.request_id, Reply::Accepted);
                }
            }
        }
    }

    fn reap_all(&mut self) {
        let ids: Vec<_> = self.terminals.keys().cloned().collect();
        for id in ids {
            self.reap_terminal(&id);
        }
    }

    fn advance_terminations(&mut self) {
        let now = Instant::now();
        for terminal in self.terminals.values_mut() {
            let Some((stage, deadline)) = terminal
                .termination
                .as_ref()
                .map(|termination| (termination.stage, termination.deadline))
            else {
                continue;
            };
            if now < deadline || !terminal.running {
                continue;
            }
            match stage {
                1 => {
                    signal_terminal(terminal, libc::SIGTERM);
                    terminal.termination = Some(Termination {
                        stage: 2,
                        deadline: now + Duration::from_millis(500),
                    });
                }
                _ => {
                    signal_terminal(terminal, libc::SIGKILL);
                    terminal.termination = Some(Termination {
                        stage: 3,
                        deadline: now + Duration::from_millis(100),
                    });
                }
            }
        }
    }

    fn check_generation(&mut self, fd: RawFd, id: u64, generation: u64) -> bool {
        if generation == self.generation {
            true
        } else {
            self.error(
                fd,
                id,
                ErrorCode::StaleGeneration,
                "broker restarted; refresh state".into(),
            );
            false
        }
    }

    fn check_generation_v4(&mut self, fd: RawFd, id: u64, generation: u64) -> bool {
        if generation == self.generation {
            true
        } else {
            self.error_v4(
                fd,
                id,
                ErrorCode::StaleGeneration,
                "broker restarted; discard checkpoint, events and lease".into(),
            );
            false
        }
    }

    fn expire_recoveries(&mut self) {
        let now = Instant::now();
        self.aborted_recoveries
            .retain(|aborted| aborted.expires_at > now);
        let expired: Vec<_> = self
            .recoveries
            .iter()
            .filter(|(_, recovery)| recovery.expires_at <= now)
            .map(|(recovery_id, _)| recovery_id.clone())
            .collect();
        for recovery_id in expired {
            self.release_recovery(&recovery_id);
        }
    }

    fn release_recovery(&mut self, recovery_id: &str) {
        if let Some(recovery) = self.recoveries.remove(recovery_id) {
            self.pinned_recovery_bytes = self
                .pinned_recovery_bytes
                .saturating_sub(recovery.bytes.len());
        }
    }

    fn reply(&mut self, fd: RawFd, id: u64, result: Reply) {
        self.send(fd, ServerBody::Reply { id, result });
    }
    fn error(&mut self, fd: RawFd, id: u64, code: ErrorCode, message: String) {
        self.send(fd, ServerBody::Error { id, code, message });
    }
    fn reply_v4(&mut self, fd: RawFd, id: u64, result: ReplyV4) {
        self.send_v4(fd, ServerBodyV4::Reply { id, result });
    }
    fn error_v4(&mut self, fd: RawFd, id: u64, code: ErrorCode, message: String) {
        self.send_v4(fd, ServerBodyV4::Error { id, code, message });
    }
    fn message(&self, body: ServerBody) -> ServerMessage {
        ServerMessage {
            version: PROTOCOL_VERSION,
            broker_generation: self.generation,
            body,
        }
    }

    fn send(&mut self, fd: RawFd, body: ServerBody) {
        let message = self.message(body);
        let failed = self
            .clients
            .get_mut(&fd)
            .is_none_or(|client| enqueue_message(&mut client.output, &message).is_err());
        if failed {
            self.drop_client(fd);
        }
    }

    fn send_v4(&mut self, fd: RawFd, body: ServerBodyV4) {
        let message = ServerMessageV4 {
            version: PROTOCOL_VERSION_V4,
            broker_generation: self.generation,
            body,
        };
        let failed = self
            .clients
            .get_mut(&fd)
            .is_none_or(|client| enqueue_serializable(&mut client.output, &message).is_err());
        if failed {
            self.drop_client(fd);
        }
    }

    fn broadcast(&mut self, terminal_id: &str, body: ServerBody) {
        let message = self.message(body);
        let recipients: Vec<_> = self
            .clients
            .iter()
            .filter(|(_, client)| client.subscriptions.contains_key(terminal_id))
            .map(|(&fd, _)| fd)
            .collect();
        for fd in recipients {
            let failed = self
                .clients
                .get_mut(&fd)
                .is_none_or(|client| enqueue_message(&mut client.output, &message).is_err());
            if failed {
                self.drop_client(fd);
            }
        }
    }

    fn broadcast_v4(&mut self, terminal_id: &str, body: ServerBodyV4) {
        let message = ServerMessageV4 {
            version: PROTOCOL_VERSION_V4,
            broker_generation: self.generation,
            body,
        };
        let recipients: Vec<_> = self
            .clients
            .iter()
            .filter(|(_, client)| {
                client.protocol_version == PROTOCOL_VERSION_V4
                    && client.subscriptions.contains_key(terminal_id)
            })
            .map(|(&fd, _)| fd)
            .collect();
        for fd in recipients {
            let failed = self
                .clients
                .get_mut(&fd)
                .is_none_or(|client| enqueue_serializable(&mut client.output, &message).is_err());
            if failed {
                self.drop_client(fd);
            }
        }
    }

    fn drop_client(&mut self, fd: RawFd) {
        let Some(client) = self.clients.remove(&fd) else {
            return;
        };
        for terminal in self.terminals.values_mut() {
            terminal.termination_waiters.retain(|waiter| {
                waiter.fd != fd || waiter.client_incarnation != client.incarnation
            });
            if terminal.lease_holder == Some(fd) {
                let cleanup = if terminal.input_failure.is_some() {
                    Ok(())
                } else {
                    cancel_active_pointer_gestures(terminal)
                };
                if let Err((_, message)) = cleanup {
                    terminal.input_failure = Some(format!(
                        "transport loss could not deliver active pointer cancel: {message}"
                    ));
                    // Once input delivery cannot be made trustworthy, keeping
                    // the child alive would preserve exactly the stuck pressed
                    // state this cleanup path exists to prevent.
                    if terminal.running {
                        signal_terminal(terminal, libc::SIGHUP);
                    }
                }
                terminal.lease_holder = None;
                terminal.input_epoch = terminal.input_epoch.saturating_add(1);
                terminal.lease_id.clear();
                terminal.next_input_seq = 1;
                terminal.input_receipts.clear();
            }
        }
        let recoveries: Vec<_> = self
            .recoveries
            .iter()
            .filter(|(_, recovery)| {
                recovery.client_fd == fd && recovery.client_incarnation == client.incarnation
            })
            .map(|(recovery_id, _)| recovery_id.clone())
            .collect();
        for recovery_id in recoveries {
            self.release_recovery(&recovery_id);
        }
        self.aborted_recoveries
            .retain(|aborted| aborted.client_incarnation != client.incarnation);
    }
}

fn terminal_poll_events(recovery_paused: bool, has_input: bool) -> i16 {
    let mut events = 0;
    if !recovery_paused {
        events |= libc::POLLIN;
    }
    if has_input {
        events |= libc::POLLOUT;
    }
    events
}

impl Drop for Broker {
    fn drop(&mut self) {
        for terminal in self.terminals.values_mut() {
            if terminal.running {
                signal_terminal(terminal, libc::SIGHUP);
            }
        }
        let _ = fs::remove_file(&self.config.socket_path);
    }
}

impl Terminal {
    fn revoke_input_lease(&mut self) {
        debug_assert!(self.pointer_routes.iter().all(Option::is_none));
        self.revoke_input_lease_preserving_pointer_state();
    }

    fn revoke_input_lease_preserving_pointer_state(&mut self) {
        if self.lease_holder.take().is_none() {
            return;
        }
        self.input_epoch = self.input_epoch.saturating_add(1);
        self.lease_id.clear();
        self.next_input_seq = 1;
        self.input_receipts.clear();
    }

    fn snapshot_recovery(&self) -> Result<Recovery, terminal_state::CanonicalStateError> {
        let snapshot = self
            .canonical
            .as_ref()
            .expect("v3 terminal has canonical ANSI state")
            .snapshot()?;
        Ok(Recovery::Snapshot {
            cursor: self.cursor,
            format: snapshot.format.to_owned(),
            scope: snapshot.scope.to_owned(),
            snapshot_version: snapshot.snapshot_version,
            data: snapshot.replay,
        })
    }

    fn summary(&self) -> TerminalSummary {
        self.summary_with_protection(false)
    }

    fn summary_with_protection(&self, checkpoint_protected: bool) -> TerminalSummary {
        let foreground_group = unsafe { libc::tcgetpgrp(self.master.as_raw_fd()) };
        let checkpoint_state = if self.live_recovery_paused.is_some() {
            CheckpointStateV4::Paused
        } else if self.live_checkpoint.is_some() {
            CheckpointStateV4::Resident
        } else {
            CheckpointStateV4::Evicted
        };
        TerminalSummary {
            id: self.id.clone(),
            create_nonce: self.create_nonce.clone(),
            cursor: self.cursor,
            columns: self.columns,
            rows: self.rows,
            layout_epoch: self.layout_epoch,
            running: self.running,
            foreground_process: self.running
                && foreground_group > 1
                && foreground_group != self.child_pid,
            checkpoint_state,
            checkpoint_bytes: self
                .live_checkpoint
                .as_ref()
                .map_or(0, |checkpoint| checkpoint.bytes.len() as u64),
            recovery_tail_bytes: self.ordered_state.retained_bytes() as u64,
            checkpoint_evictions: self.checkpoint_evictions,
            checkpoint_rebuilds: self.checkpoint_rebuilds,
            recovery_pause_count: self.recovery_pause_count,
            recovery_paused_ms: self
                .live_recovery_paused_since
                .map(|started| started.elapsed().as_millis().min(u64::MAX as u128) as u64),
            checkpoint_protected,
        }
    }
}

fn enqueue_message(queue: &mut ByteQueue, message: &ServerMessage) -> Result<(), ()> {
    enqueue_serializable(queue, message)
}

fn enqueue_serializable<T: Serialize>(queue: &mut ByteQueue, message: &T) -> Result<(), ()> {
    queue.push(encode_message(message)?)
}

fn encode_message<T: Serialize>(message: &T) -> Result<Vec<u8>, ()> {
    let mut bytes = serde_json::to_vec(message).map_err(|_| ())?;
    bytes.push(b'\n');
    Ok(bytes)
}

pub fn checkpoint_digest_v4(manifest: &CapabilityManifestV4, bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    // A fixed binary preimage avoids JSON key-order and escaping differences
    // across Rust, Swift and future mobile implementations.
    hasher.update(b"ourocode-broker-v4-checkpoint\0");
    hasher.update(manifest.protocol_version.to_be_bytes());
    hasher.update(manifest.terminal_abi_version.to_be_bytes());
    digest_string(&mut hasher, &manifest.engine_source_commit);
    digest_string(&mut hasher, &manifest.snapshot_magic);
    hasher.update(manifest.snapshot_format_version.to_be_bytes());
    digest_string(&mut hasher, &manifest.unicode_width_policy);
    digest_string(&mut hasher, &manifest.graphics_policy);
    hasher.update(manifest.max_snapshot_bytes.to_be_bytes());
    hasher.update(manifest.max_terminal_history_bytes.to_be_bytes());
    hasher.update(manifest.max_global_history_bytes.to_be_bytes());
    hasher.update(manifest.max_delta_bytes.to_be_bytes());
    hasher.update(manifest.max_recovery_pinned_bytes.to_be_bytes());
    hasher.update(manifest.max_chunk_bytes.to_be_bytes());
    digest_string(&mut hasher, &manifest.compression);
    hasher.update((bytes.len() as u64).to_be_bytes());
    hasher.update(bytes);
    let digest = hasher.finalize();
    let mut encoded = String::with_capacity(7 + digest.len() * 2);
    encoded.push_str("sha256:");
    for byte in digest {
        use std::fmt::Write as _;
        write!(&mut encoded, "{byte:02x}").expect("writing to String cannot fail");
    }
    encoded
}

fn digest_string(hasher: &mut Sha256, value: &str) {
    hasher.update((value.len() as u64).to_be_bytes());
    hasher.update(value.as_bytes());
}

fn random_token() -> io::Result<String> {
    let mut bytes = [0u8; 24];
    getrandom::getrandom(&mut bytes)
        .map_err(|error| io::Error::other(format!("CSPRNG failed: {error}")))?;
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        use std::fmt::Write as _;
        write!(&mut encoded, "{byte:02x}").expect("writing to String cannot fail");
    }
    Ok(encoded)
}

fn io_error_context(context: &str, error: io::Error) -> io::Error {
    let errno = error.raw_os_error();
    io::Error::new(
        error.kind(),
        format!("{context}: {error} (errno={errno:?})"),
    )
}

mod base64_bytes {
    use base64::engine::general_purpose::STANDARD;
    use base64::Engine;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S>(bytes: &[u8], serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&STANDARD.encode(bytes))
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let encoded = String::deserialize(deserializer)?;
        STANDARD.decode(encoded).map_err(serde::de::Error::custom)
    }
}

fn prepare_socket(path: &Path) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
    }
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_socket() => match UnixStream::connect(path) {
            Ok(_) => Err(io::Error::new(
                io::ErrorKind::AddrInUse,
                "another broker owns the socket",
            )),
            Err(error)
                if matches!(
                    error.raw_os_error(),
                    Some(libc::ECONNREFUSED) | Some(libc::ENOENT)
                ) =>
            {
                fs::remove_file(path)
            }
            Err(error) => Err(error),
        },
        Ok(_) => Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "refusing to replace non-socket path",
        )),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn broker_generation() -> io::Result<u64> {
    loop {
        let mut bytes = [0_u8; std::mem::size_of::<u64>()];
        getrandom::getrandom(&mut bytes)
            .map_err(|error| io::Error::other(format!("OS random source failed: {error}")))?;
        let generation = u64::from_ne_bytes(bytes);
        if generation != 0 {
            return Ok(generation);
        }
    }
}

fn ensure_same_effective_uid(peer_uid: libc::uid_t, effective_uid: libc::uid_t) -> io::Result<()> {
    if peer_uid == effective_uid {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "refusing Unix peer owned by another effective UID",
        ))
    }
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
fn verify_peer_uid(fd: RawFd) -> io::Result<()> {
    let mut peer_uid: libc::uid_t = 0;
    let mut peer_gid: libc::gid_t = 0;
    if unsafe { libc::getpeereid(fd, &mut peer_uid, &mut peer_gid) } < 0 {
        return Err(io::Error::last_os_error());
    }
    ensure_same_effective_uid(peer_uid, unsafe { libc::geteuid() })
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn verify_peer_uid(fd: RawFd) -> io::Result<()> {
    let mut credentials = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut length = std::mem::size_of_val(&credentials) as libc::socklen_t;
    let result = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut length,
        )
    };
    if result < 0 {
        return Err(io::Error::last_os_error());
    }
    if length as usize != std::mem::size_of_val(&credentials) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Unix peer credentials had an unexpected size",
        ));
    }
    ensure_same_effective_uid(credentials.uid, unsafe { libc::geteuid() })
}

/// Re-checks the kernel objects behind a live surface at identification time.
///
/// `forkpty` plus the CLOEXEC status pipe proves that the initial child made
/// it through terminal setup and `execvp`. These parent-side queries prove the
/// surviving object graph: the recorded child is still the session leader,
/// this PTY belongs to that session, and its current foreground process group
/// is in the same session. PID reuse cannot satisfy all four checks while the
/// broker still owns the original open PTY master.
fn verify_live_surface_kernel_contract(terminal: &Terminal) -> io::Result<()> {
    let child_pid = terminal.child_pid;
    if child_pid <= 1 || !terminal.running {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "recorded PTY child is not live",
        ));
    }
    if unsafe { libc::kill(child_pid, 0) } < 0 {
        return Err(io_error_context(
            "probe PTY child",
            io::Error::last_os_error(),
        ));
    }
    let child_session = unsafe { libc::getsid(child_pid) };
    if child_session < 0 {
        return Err(io_error_context(
            "read PTY child session",
            io::Error::last_os_error(),
        ));
    }
    if child_session != child_pid {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "recorded PTY child is not its session leader",
        ));
    }

    let master_fd = terminal.master.as_raw_fd();
    let tty_session = unsafe { libc::tcgetsid(master_fd) };
    if tty_session < 0 {
        return Err(io_error_context(
            "read PTY controlling session",
            io::Error::last_os_error(),
        ));
    }
    if tty_session != child_session {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "PTY controlling session does not belong to the recorded child",
        ));
    }

    let foreground_group = unsafe { libc::tcgetpgrp(master_fd) };
    if foreground_group <= 1 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "PTY has no provable foreground process group",
        ));
    }
    let foreground_session = unsafe { libc::getsid(foreground_group) };
    if foreground_session < 0 {
        return Err(io_error_context(
            "read PTY foreground process group session",
            io::Error::last_os_error(),
        ));
    }
    if foreground_session != child_session {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "PTY foreground process group belongs to another session",
        ));
    }
    Ok(())
}

fn spawn_pty(
    program: &str,
    args: &[String],
    current_directory: Option<&str>,
    environment: &HashMap<String, String>,
    columns: u16,
    rows: u16,
) -> io::Result<(OwnedFd, libc::pid_t)> {
    let program = CString::new(program)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "program contains NUL"))?;
    let args: Vec<CString> = args
        .iter()
        .map(|arg| CString::new(arg.as_str()))
        .collect::<Result<_, _>>()
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "argument contains NUL"))?;
    let current_directory = current_directory
        .map(CString::new)
        .transpose()
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "directory contains NUL"))?;
    let environment: Vec<(CString, CString)> = environment
        .iter()
        .map(|(key, value)| {
            Ok((
                CString::new(key.as_str()).map_err(|_| {
                    io::Error::new(io::ErrorKind::InvalidInput, "environment key contains NUL")
                })?,
                CString::new(value.as_str()).map_err(|_| {
                    io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "environment value contains NUL",
                    )
                })?,
            ))
        })
        .collect::<io::Result<_>>()?;
    let mut argv: Vec<*const libc::c_char> = Vec::with_capacity(args.len() + 2);
    argv.push(program.as_ptr());
    for arg in &args {
        argv.push(arg.as_ptr());
    }
    argv.push(std::ptr::null());
    let mut winsize = libc::winsize {
        ws_row: rows,
        ws_col: columns,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let (status_read, status_write) = cloexec_pipe()?;
    let mut master = -1;
    // Use the platform's login_tty path rather than approximating it with a
    // hand-rolled openpty/setsid/TIOCSCTTY/dup2 sequence. Interactive shells
    // (notably zsh with Powerlevel10k/gitstatus process substitutions) depend
    // on the exact controlling-terminal and foreground-process-group contract.
    let pid = unsafe {
        libc::forkpty(
            &mut master,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut winsize,
        )
    };
    if pid < 0 {
        let error = io::Error::last_os_error();
        unsafe {
            libc::close(status_read);
            libc::close(status_write);
        }
        return Err(error);
    }
    if pid == 0 {
        unsafe {
            libc::close(status_read);
            if reset_child_signal_state() < 0 {
                child_spawn_failed(status_write, SpawnStage::SignalState);
            }
            if verify_child_terminal_contract() < 0 {
                child_spawn_failed(status_write, SpawnStage::TerminalContract);
            }
            if let Some(directory) = &current_directory {
                if libc::chdir(directory.as_ptr()) < 0 {
                    child_spawn_failed(status_write, SpawnStage::ChangeDirectory);
                }
            }
            for (key, value) in &environment {
                if libc::setenv(key.as_ptr(), value.as_ptr(), 1) < 0 {
                    child_spawn_failed(status_write, SpawnStage::Environment);
                }
            }
            libc::execvp(program.as_ptr(), argv.as_ptr());
            child_spawn_failed(status_write, SpawnStage::Exec);
        }
    }
    unsafe {
        libc::close(status_write);
    }
    if let Err(error) = set_cloexec(master) {
        unsafe { libc::close(status_read) };
        kill_and_reap_child(pid, master);
        unsafe { libc::close(master) };
        return Err(error);
    }
    let spawn_status = read_spawn_status(status_read);
    unsafe {
        libc::close(status_read);
    }
    if let Err(error) = spawn_status {
        kill_and_reap_child(pid, master);
        unsafe { libc::close(master) };
        return Err(error);
    }
    if let Err(error) = set_nonblocking(master) {
        kill_and_reap_child(pid, master);
        unsafe { libc::close(master) };
        return Err(error);
    }
    Ok((unsafe { OwnedFd::from_raw_fd(master) }, pid))
}

#[derive(Clone, Copy)]
#[repr(i32)]
enum SpawnStage {
    ChangeDirectory = 7,
    Environment = 8,
    Exec = 9,
    SignalState = 10,
    TerminalContract = 11,
}

impl SpawnStage {
    fn name(value: i32) -> &'static str {
        match value {
            7 => "chdir",
            8 => "setenv",
            9 => "execvp",
            10 => "reset signal state",
            11 => "forkpty terminal contract",
            _ => "child setup",
        }
    }
}

/// Rust ignores SIGPIPE for its own process. Ignored dispositions survive
/// `exec`, so a shell launched directly from the broker would otherwise run
/// pipelines and process substitutions with non-POSIX signal semantics. GUI
/// launchers can also leave signals blocked. Restore the ordinary exec-time
/// contract before the PTY child becomes the user's shell.
unsafe fn reset_child_signal_state() -> libc::c_int {
    let mut action: libc::sigaction = std::mem::zeroed();
    action.sa_sigaction = libc::SIG_DFL;
    if libc::sigemptyset(&mut action.sa_mask) < 0 {
        return -1;
    }
    action.sa_flags = 0;
    for signal in [
        libc::SIGHUP,
        libc::SIGINT,
        libc::SIGQUIT,
        libc::SIGPIPE,
        libc::SIGCHLD,
        libc::SIGTSTP,
        libc::SIGTTIN,
        libc::SIGTTOU,
    ] {
        if libc::sigaction(signal, &action, std::ptr::null_mut()) < 0 {
            return -1;
        }
    }
    let mut mask: libc::sigset_t = std::mem::zeroed();
    if libc::sigemptyset(&mut mask) < 0 {
        return -1;
    }
    libc::sigprocmask(libc::SIG_SETMASK, &mask, std::ptr::null_mut())
}

/// `forkpty` is intentionally trusted for the platform-specific login_tty
/// sequence, but some BSD implementations don't surface a child-side
/// login_tty failure to the parent. Verify the contract before exec so a
/// partially attached shell can never be reported as successfully spawned.
unsafe fn verify_child_terminal_contract() -> libc::c_int {
    let pid = libc::getpid();
    if libc::getsid(0) != pid || libc::tcgetpgrp(libc::STDIN_FILENO) != libc::getpgrp() {
        set_current_errno(libc::ENOTTY);
        return -1;
    }

    let mut stdin_stat: libc::stat = std::mem::zeroed();
    let mut stdout_stat: libc::stat = std::mem::zeroed();
    let mut stderr_stat: libc::stat = std::mem::zeroed();
    if libc::fstat(libc::STDIN_FILENO, &mut stdin_stat) < 0
        || libc::fstat(libc::STDOUT_FILENO, &mut stdout_stat) < 0
        || libc::fstat(libc::STDERR_FILENO, &mut stderr_stat) < 0
    {
        return -1;
    }
    if stdin_stat.st_dev != stdout_stat.st_dev
        || stdin_stat.st_ino != stdout_stat.st_ino
        || stdin_stat.st_dev != stderr_stat.st_dev
        || stdin_stat.st_ino != stderr_stat.st_ino
    {
        set_current_errno(libc::ENOTTY);
        return -1;
    }
    0
}

#[derive(Clone, Copy)]
#[repr(C)]
struct SpawnFailure {
    stage: i32,
    errno: i32,
}

unsafe fn child_spawn_failed(status_fd: RawFd, stage: SpawnStage) -> ! {
    let failure = SpawnFailure {
        stage: stage as i32,
        errno: current_errno(),
    };
    let pointer = (&failure as *const SpawnFailure).cast::<u8>();
    let mut written = 0usize;
    while written < std::mem::size_of::<SpawnFailure>() {
        let result = libc::write(
            status_fd,
            pointer.add(written).cast(),
            std::mem::size_of::<SpawnFailure>() - written,
        );
        if result > 0 {
            written += result as usize;
        } else if result < 0 && current_errno() == libc::EINTR {
            continue;
        } else {
            break;
        }
    }
    libc::_exit(126)
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
unsafe fn current_errno() -> i32 {
    *libc::__error()
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
unsafe fn set_current_errno(value: i32) {
    *libc::__error() = value;
}

#[cfg(any(target_os = "linux", target_os = "android"))]
unsafe fn current_errno() -> i32 {
    *libc::__errno_location()
}

#[cfg(any(target_os = "linux", target_os = "android"))]
unsafe fn set_current_errno(value: i32) {
    *libc::__errno_location() = value;
}

fn read_spawn_status(fd: RawFd) -> io::Result<()> {
    let mut bytes = [0u8; std::mem::size_of::<SpawnFailure>()];
    let mut received = 0usize;
    loop {
        let result = unsafe {
            libc::read(
                fd,
                bytes[received..].as_mut_ptr().cast(),
                bytes.len() - received,
            )
        };
        if result == 0 {
            if received == 0 {
                return Ok(());
            }
            break;
        }
        if result < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        received += result as usize;
        if received == bytes.len() {
            break;
        }
    }
    if received != bytes.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "child returned a truncated exec status",
        ));
    }
    let failure = unsafe { std::ptr::read_unaligned(bytes.as_ptr().cast::<SpawnFailure>()) };
    let cause = io::Error::from_raw_os_error(failure.errno);
    Err(io::Error::new(
        cause.kind(),
        format!("{} failed: {cause}", SpawnStage::name(failure.stage)),
    ))
}

fn cloexec_pipe() -> io::Result<(RawFd, RawFd)> {
    let mut descriptors = [-1; 2];
    if unsafe { libc::pipe(descriptors.as_mut_ptr()) } < 0 {
        return Err(io::Error::last_os_error());
    }
    let read = duplicate_cloexec_above_stdio(descriptors[0]);
    let write = duplicate_cloexec_above_stdio(descriptors[1]);
    unsafe {
        libc::close(descriptors[0]);
        libc::close(descriptors[1]);
    }
    match (read, write) {
        (Ok(read), Ok(write)) => Ok((read, write)),
        (Ok(read), Err(error)) => {
            unsafe { libc::close(read) };
            Err(error)
        }
        (Err(error), Ok(write)) => {
            unsafe { libc::close(write) };
            Err(error)
        }
        (Err(error), Err(_)) => Err(error),
    }
}

fn duplicate_cloexec_above_stdio(fd: RawFd) -> io::Result<RawFd> {
    let duplicate = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 3) };
    if duplicate < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(duplicate)
    }
}

fn set_cloexec(fd: RawFd) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) } < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn kill_and_reap_child(pid: libc::pid_t, master_fd: RawFd) {
    let foreground = unsafe { libc::tcgetpgrp(master_fd) };
    if foreground > 1 {
        signal_group(foreground, libc::SIGKILL);
    }
    signal_group(pid, libc::SIGKILL);
    unsafe { libc::kill(pid, libc::SIGKILL) };
    let mut status = 0;
    loop {
        let result = unsafe { libc::waitpid(pid, &mut status, 0) };
        if result == pid
            || (result < 0 && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted)
        {
            break;
        }
    }
}

fn set_nonblocking(fd: RawFd) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
fn configure_client_socket(fd: RawFd) -> io::Result<()> {
    let enabled: libc::c_int = 1;
    let result = unsafe {
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_NOSIGPIPE,
            (&enabled as *const libc::c_int).cast(),
            std::mem::size_of_val(&enabled) as libc::socklen_t,
        )
    };
    if result < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(not(any(target_os = "macos", target_os = "ios")))]
fn configure_client_socket(_fd: RawFd) -> io::Result<()> {
    Ok(())
}

fn accepted_peer_is_closed(fd: RawFd) -> io::Result<bool> {
    let mut byte = 0u8;
    loop {
        let result = unsafe {
            libc::recv(
                fd,
                (&mut byte as *mut u8).cast(),
                1,
                libc::MSG_PEEK | libc::MSG_DONTWAIT,
            )
        };
        if result == 0 {
            return Ok(true);
        }
        if result > 0 {
            return Ok(false);
        }
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::Interrupted {
            continue;
        }
        if error.kind() == io::ErrorKind::WouldBlock {
            return Ok(false);
        }
        return Err(error);
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn send_client(fd: RawFd, bytes: &[u8]) -> isize {
    unsafe { libc::send(fd, bytes.as_ptr().cast(), bytes.len(), libc::MSG_NOSIGNAL) }
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn send_client(fd: RawFd, bytes: &[u8]) -> isize {
    unsafe { libc::send(fd, bytes.as_ptr().cast(), bytes.len(), 0) }
}

fn set_winsize(fd: RawFd, columns: u16, rows: u16) -> io::Result<()> {
    let winsize = libc::winsize {
        ws_row: rows,
        ws_col: columns,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    if unsafe { libc::ioctl(fd, libc::TIOCSWINSZ as _, &winsize) } < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn signal_group(pgid: libc::pid_t, signal: libc::c_int) {
    if pgid > 1 {
        unsafe {
            libc::kill(-pgid, signal);
        }
    }
}

fn signal_terminal(terminal: &Terminal, signal: libc::c_int) {
    let foreground = unsafe { libc::tcgetpgrp(terminal.master.as_raw_fd()) };
    if foreground > 1 {
        signal_group(foreground, signal);
    }
    if terminal.child_pid > 1 && terminal.child_pid != foreground {
        signal_group(terminal.child_pid, signal);
    }
}

fn decode_wait_status(status: libc::c_int) -> Option<i32> {
    if libc::WIFEXITED(status) {
        Some(libc::WEXITSTATUS(status))
    } else if libc::WIFSIGNALED(status) {
        Some(128 + libc::WTERMSIG(status))
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(target_os = "macos")]
    extern "C" fn write_winch_marker(_signal: libc::c_int) {
        let marker = b"W";
        unsafe {
            libc::write(libc::STDOUT_FILENO, marker.as_ptr().cast(), marker.len());
        }
    }

    #[test]
    fn byte_queue_never_exceeds_bound() {
        let mut queue = ByteQueue::new(5);
        assert!(queue.push(vec![1, 2, 3]).is_ok());
        assert!(queue.push(vec![4, 5]).is_ok());
        assert!(queue.push(vec![6]).is_err());
        queue.consume(4);
        assert!(queue.push(vec![6, 7, 8, 9]).is_ok());
        assert_eq!(queue.bytes, 5);
    }

    #[test]
    fn byte_queue_emergency_reservation_survives_ordinary_backpressure() {
        let mut queue = ByteQueue::new(8);
        queue.reserve_emergency(3).unwrap();
        assert!(queue.push(vec![1; 5]).is_ok());
        assert!(queue.push(vec![2]).is_err());
        queue.release_emergency(3);
        assert!(queue.push(vec![3; 3]).is_ok());
        assert_eq!(queue.bytes, 8);
    }

    #[test]
    fn failed_pty_delivery_never_silently_clears_pty_gesture() {
        let gesture = |disposition| PointerGesture {
            id: 7,
            disposition,
            button: NormalizedMouseButton::Left,
            modifiers: 0,
            x_q8: 0,
            y_q8: 0,
            cleanup_reservation: if disposition == PointerDisposition::Pty {
                POINTER_CLEANUP_RESERVATION_BYTES
            } else {
                0
            },
        };
        let mut routes = [None; 11];
        routes[0] = Some(gesture(PointerDisposition::Pty));
        routes[1] = Some(gesture(PointerDisposition::LocalSelection));
        assert!(retain_undelivered_pty_pointer_routes(&mut routes));
        assert_eq!(routes[0], Some(gesture(PointerDisposition::Pty)));
        assert_eq!(routes[1], None);
    }

    #[test]
    fn broker_generation_is_nonzero() {
        assert_ne!(broker_generation().unwrap(), 0);
    }

    #[test]
    fn pty_child_restores_sigpipe_default_before_exec() {
        let environment = HashMap::new();
        let (master, pid) = spawn_pty(
            "/bin/sh",
            &["-c".into(), "kill -PIPE $$; printf SHOULD_NOT_RUN".into()],
            None,
            &environment,
            80,
            24,
        )
        .unwrap();
        let mut status = 0;
        assert_eq!(unsafe { libc::waitpid(pid, &mut status, 0) }, pid);
        assert!(libc::WIFSIGNALED(status));
        assert_eq!(libc::WTERMSIG(status), libc::SIGPIPE);
        drop(master);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn tiocswinsz_delivers_exactly_one_sigwinch_without_manual_kill() {
        let mut master_fd = -1;
        let mut initial_size = libc::winsize {
            ws_row: 24,
            ws_col: 80,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let pid = unsafe {
            libc::forkpty(
                &mut master_fd,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut initial_size,
            )
        };
        assert!(pid >= 0, "forkpty failed: {}", io::Error::last_os_error());
        if pid == 0 {
            unsafe {
                let mut action: libc::sigaction = std::mem::zeroed();
                action.sa_sigaction = write_winch_marker as *const () as usize;
                libc::sigemptyset(&mut action.sa_mask);
                action.sa_flags = 0;
                if libc::sigaction(libc::SIGWINCH, &action, std::ptr::null_mut()) < 0 {
                    libc::_exit(2);
                }
                let ready = b"READY";
                libc::write(libc::STDOUT_FILENO, ready.as_ptr().cast(), ready.len());
                loop {
                    libc::pause();
                }
            }
        }
        let master = unsafe { OwnedFd::from_raw_fd(master_fd) };
        set_nonblocking(master.as_raw_fd()).unwrap();

        let mut output = Vec::new();
        let ready_deadline = Instant::now() + Duration::from_secs(2);
        while !output
            .windows(b"READY".len())
            .any(|window| window == b"READY")
        {
            let mut buffer = [0_u8; 256];
            let read =
                unsafe { libc::read(master.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len()) };
            if read > 0 {
                output.extend_from_slice(&buffer[..read as usize]);
            } else if read < 0 {
                let error = io::Error::last_os_error();
                assert!(
                    matches!(
                        error.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::Other
                    ),
                    "unexpected PTY read error: {error}"
                );
            }
            assert!(
                Instant::now() < ready_deadline,
                "SIGWINCH fixture did not become ready"
            );
            std::thread::sleep(Duration::from_millis(10));
        }

        output.clear();
        set_winsize(master.as_raw_fd(), 100, 30).unwrap();
        let settle_deadline = Instant::now() + Duration::from_millis(500);
        while Instant::now() < settle_deadline {
            let mut buffer = [0_u8; 256];
            let read =
                unsafe { libc::read(master.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len()) };
            if read > 0 {
                output.extend_from_slice(&buffer[..read as usize]);
            } else if read < 0 {
                let error = io::Error::last_os_error();
                assert!(
                    matches!(
                        error.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::Other
                    ),
                    "unexpected PTY read error: {error}"
                );
            }
            std::thread::sleep(Duration::from_millis(10));
        }

        let signals = output.iter().filter(|byte| **byte == b'W').count();
        signal_group(pid, libc::SIGTERM);
        let mut status = 0;
        assert_eq!(unsafe { libc::waitpid(pid, &mut status, 0) }, pid);
        assert_eq!(
            signals, 1,
            "one resize delivered {signals} SIGWINCH notifications"
        );
        drop(master);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn login_interactive_zsh_reads_profile_and_zshrc_once_in_a_real_pty() {
        let zdotdir = tempfile::tempdir().unwrap();
        std::fs::write(
            zdotdir.path().join(".zprofile"),
            "export OURO_PROFILE_COUNT=$(( ${OURO_PROFILE_COUNT:-0} + 1 ))\n",
        )
        .unwrap();
        std::fs::write(
            zdotdir.path().join(".zshrc"),
            concat!(
                "export OURO_ZSHRC_COUNT=$(( ${OURO_ZSHRC_COUNT:-0} + 1 ))\n",
                "PROMPT=''\n",
                "RPROMPT=''\n"
            ),
        )
        .unwrap();

        let mut environment = HashMap::new();
        environment.insert(
            "ZDOTDIR".into(),
            zdotdir.path().to_string_lossy().into_owned(),
        );
        environment.insert("TERM".into(), "xterm-256color".into());
        environment.insert("COLORTERM".into(), "truecolor".into());
        environment.insert("TERM_PROGRAM".into(), "Ourocode".into());
        environment.insert("TERM_PROGRAM_VERSION".into(), "test".into());
        environment.insert("LC_CTYPE".into(), "UTF-8".into());
        let probe = concat!(
            "printf '<ouro-zsh login=%s interactive=%s monitor=%s profile=%s rc=%s ",
            "term=%s color=%s program=%s version=%s locale=%s>\\n' ",
            "${options[login]} ${options[interactive]} ${options[monitor]} ",
            "${OURO_PROFILE_COUNT:-0} ${OURO_ZSHRC_COUNT:-0} $TERM $COLORTERM ",
            "$TERM_PROGRAM $TERM_PROGRAM_VERSION $LC_CTYPE"
        );
        let (master, pid) = spawn_pty(
            "/bin/zsh",
            &["-l".into(), "-i".into(), "-c".into(), probe.into()],
            Some(zdotdir.path().to_str().unwrap()),
            &environment,
            100,
            30,
        )
        .unwrap();

        let mut output = Vec::new();
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut status = 0;
        loop {
            let mut buffer = [0_u8; 4096];
            let read =
                unsafe { libc::read(master.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len()) };
            if read > 0 {
                output.extend_from_slice(&buffer[..read as usize]);
            } else if read < 0 {
                let error = io::Error::last_os_error();
                assert!(
                    matches!(
                        error.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::Other
                    ),
                    "unexpected PTY read error: {error}"
                );
            }
            let waited = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
            assert!(
                waited >= 0,
                "waitpid failed: {}",
                io::Error::last_os_error()
            );
            if waited == pid {
                break;
            }
            assert!(Instant::now() < deadline, "zsh startup contract timed out");
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(libc::WIFEXITED(status));
        assert_eq!(libc::WEXITSTATUS(status), 0);
        let output = String::from_utf8_lossy(&output);
        assert!(
            output.contains(
                "<ouro-zsh login=on interactive=on monitor=on profile=1 rc=1 term=xterm-256color color=truecolor program=Ourocode version=test locale=UTF-8>"
            ),
            "unexpected zsh startup contract output: {output:?}"
        );
    }

    #[test]
    fn recovery_backpressure_removes_pollin_without_blocking_queued_input() {
        assert_eq!(terminal_poll_events(false, false), libc::POLLIN);
        assert_eq!(terminal_poll_events(true, false), 0);
        assert_eq!(terminal_poll_events(true, true), libc::POLLOUT);
    }

    #[test]
    fn peer_uid_comparison_fails_closed() {
        let current = unsafe { libc::geteuid() };
        assert!(ensure_same_effective_uid(current, current).is_ok());
        let foreign = if current == libc::uid_t::MAX {
            current - 1
        } else {
            current + 1
        };
        let error = ensure_same_effective_uid(foreign, current).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
    }

    #[cfg(any(
        target_os = "macos",
        target_os = "ios",
        target_os = "linux",
        target_os = "android"
    ))]
    #[test]
    fn current_process_unix_peer_is_authenticated() {
        let mut sockets = [-1; 2];
        assert_eq!(
            unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_STREAM, 0, sockets.as_mut_ptr()) },
            0
        );
        let left = unsafe { OwnedFd::from_raw_fd(sockets[0]) };
        let right = unsafe { OwnedFd::from_raw_fd(sockets[1]) };
        verify_peer_uid(left.as_raw_fd()).unwrap();
        verify_peer_uid(right.as_raw_fd()).unwrap();
    }
}
