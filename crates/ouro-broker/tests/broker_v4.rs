use ouro_broker::session_terminal_binding::DeclaredSessionBindingV1;
use ouro_broker::{
    checkpoint_digest_v4, Broker, BrokerConfig, CapabilityManifestV4, CommandV4, ErrorCode,
    IdentifySurfaceV1, LiveTerminalCompression, LiveTerminalEngine, LiveTerminalEngineConfig,
    LiveTerminalEngineFactory, ReplyV4, RequestV4, ServerBodyV4, ServerMessageV4, TerminalSummary,
    WireStateEvent, CAPABILITY_DECLARED_SESSION_BINDING_V1, CAPABILITY_IDENTIFY_SURFACE_V1,
    CAPABILITY_LEASE_DETACH_V4, PROTOCOL_VERSION_V4, RECOVERY_CHUNK_BYTES,
};
#[cfg(feature = "ghostty-engine")]
use ouro_broker::{
    normalized_input_event_digest_v1, LiveTerminalInputEncode, NormalizedInputEvent,
    NormalizedKeyAction, NormalizedMouseAction, NormalizedMouseButton, NormalizedMouseGeometry,
    NormalizedScrollDirection, PointerDisposition, CAPABILITY_NORMALIZED_INPUT_V1,
    CAPABILITY_POINTER_DISPOSITION_V1,
};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command as ProcessCommand, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};
use tempfile::TempDir;

struct BrokerProcess {
    child: Child,
    _directory: TempDir,
    socket: PathBuf,
}

impl BrokerProcess {
    fn start() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let socket = directory.path().join("broker-v4.sock");
        let child = ProcessCommand::new(env!("CARGO_BIN_EXE_ouro-broker-v4"))
            .arg(&socket)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while !socket.exists() {
            assert!(
                Instant::now() < deadline,
                "v4 broker socket was not created"
            );
            thread::sleep(Duration::from_millis(10));
        }
        Self {
            child,
            _directory: directory,
            socket,
        }
    }
}

impl Drop for BrokerProcess {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(feature = "ghostty-engine")]
struct GhosttyBrokerProcess {
    child: Child,
    _directory: TempDir,
    socket: PathBuf,
}

#[cfg(feature = "ghostty-engine")]
impl GhosttyBrokerProcess {
    fn start() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let socket = directory.path().join("broker-v4-ghostty.sock");
        let child = ProcessCommand::new(env!("CARGO_BIN_EXE_ouro-broker-v4-ghostty"))
            .arg(&socket)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while !socket.exists() {
            assert!(
                Instant::now() < deadline,
                "Ghostty v4 broker socket was not created"
            );
            thread::sleep(Duration::from_millis(10));
        }
        Self {
            child,
            _directory: directory,
            socket,
        }
    }
}

#[cfg(feature = "ghostty-engine")]
impl Drop for GhosttyBrokerProcess {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

struct BrokerThread {
    _directory: TempDir,
    socket: PathBuf,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl BrokerThread {
    fn start(recovery_ttl: Duration, max_recovery_pinned_bytes: usize) -> Self {
        let directory = tempfile::tempdir().unwrap();
        let socket = directory.path().join("broker-v4.sock");
        let mut config = BrokerConfig::new(&socket);
        config.poll_timeout = Duration::from_millis(5);
        config.engine_idle_compression_delay = Duration::from_millis(10);
        config.recovery_ttl = recovery_ttl;
        config.max_recovery_pinned_bytes = max_recovery_pinned_bytes;
        let mut broker = Broker::bind_v4_fixture(config).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&stop);
        let thread = thread::spawn(move || {
            while !thread_stop.load(Ordering::Acquire) {
                broker.tick().unwrap();
            }
        });
        Self {
            _directory: directory,
            socket,
            stop,
            thread: Some(thread),
        }
    }

    fn start_with_live_engine(factory: Arc<dyn LiveTerminalEngineFactory>) -> Self {
        Self::start_with_live_engine_checkpoint_budget(factory, 32 * 1024 * 1024)
    }

    fn start_with_live_engine_checkpoint_budget(
        factory: Arc<dyn LiveTerminalEngineFactory>,
        max_live_checkpoint_bytes: usize,
    ) -> Self {
        let directory = tempfile::tempdir().unwrap();
        let socket = directory.path().join("broker-v4-live-engine.sock");
        let mut config = BrokerConfig::new(&socket);
        config.poll_timeout = Duration::from_millis(5);
        config.engine_idle_compression_delay = Duration::from_millis(10);
        config.max_live_checkpoint_bytes = max_live_checkpoint_bytes;
        let mut manifest = CapabilityManifestV4::canonical_replay_fixture(&config);
        manifest.terminal_abi_version = 99;
        manifest.engine_source_commit = "test:broker-owned-live-engine".into();
        manifest.snapshot_magic = "TEST-LIVE-ENGINE".into();
        let mut broker = Broker::bind_v4_engine(config, manifest, factory).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&stop);
        let thread = thread::spawn(move || {
            while !thread_stop.load(Ordering::Acquire) {
                broker.tick().unwrap();
            }
        });
        Self {
            _directory: directory,
            socket,
            stop,
            thread: Some(thread),
        }
    }

    #[cfg(feature = "ghostty-engine")]
    fn start_with_ghostty_input_queue(
        max_terminal_input_bytes: usize,
        max_terminal_write_bytes_per_tick: usize,
    ) -> Self {
        use ouro_broker::ghostty_engine::GhosttyEngineFactory;
        use ouro_terminal_ghostty::Config as GhosttyConfig;

        let directory = tempfile::tempdir().unwrap();
        let socket = directory.path().join("broker-v4-ghostty-input.sock");
        let mut config = BrokerConfig::new(&socket);
        config.poll_timeout = Duration::from_millis(5);
        config.max_snapshot_bytes = 16 * 1024 * 1024;
        config.max_live_checkpoint_bytes = 64 * 1024 * 1024;
        config.max_recovery_pinned_bytes = 32 * 1024 * 1024;
        config.max_terminal_input_bytes = max_terminal_input_bytes;
        config.max_terminal_write_bytes_per_tick = max_terminal_write_bytes_per_tick;
        let factory = GhosttyEngineFactory::new(
            GhosttyConfig {
                snapshot_max_bytes: config.max_snapshot_bytes,
                scrollback_max_bytes: config.max_terminal_history_bytes,
                ..GhosttyConfig::default()
            },
            config.max_global_history_bytes,
        )
        .unwrap();
        let manifest = factory.manifest(&config).unwrap();
        let mut broker = Broker::bind_v4_engine(config, manifest, Arc::new(factory)).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&stop);
        let thread = thread::spawn(move || {
            while !thread_stop.load(Ordering::Acquire) {
                broker.tick().unwrap();
            }
        });
        Self {
            _directory: directory,
            socket,
            stop,
            thread: Some(thread),
        }
    }
}

impl Drop for BrokerThread {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        // Keep the wake peer alive until the broker has left poll and joined.
        // Dropping it immediately races macOS SO_NOSIGPIPE admission.
        let wake = UnixStream::connect(&self.socket).ok();
        if let Some(thread) = self.thread.take() {
            thread.join().unwrap();
        }
        drop(wake);
    }
}

struct Client {
    writer: UnixStream,
    reader: BufReader<UnixStream>,
    generation: u64,
    manifest: CapabilityManifestV4,
    capabilities: Vec<String>,
    next_id: u64,
}

impl Client {
    fn connect(path: &Path) -> Self {
        let deadline = Instant::now() + Duration::from_secs(5);
        let writer = loop {
            match UnixStream::connect(path) {
                Ok(stream) => break stream,
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
                    ) && Instant::now() < deadline =>
                {
                    thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("could not connect to v4 broker: {error}"),
            }
        };
        writer
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let reader = BufReader::new(writer.try_clone().unwrap());
        let mut client = Self {
            writer,
            reader,
            generation: 0,
            manifest: CapabilityManifestV4 {
                protocol_version: 0,
                terminal_abi_version: 0,
                engine_source_commit: String::new(),
                snapshot_magic: String::new(),
                snapshot_format_version: 0,
                unicode_width_policy: String::new(),
                graphics_policy: String::new(),
                max_snapshot_bytes: 0,
                max_terminal_history_bytes: 0,
                max_global_history_bytes: 0,
                max_delta_bytes: 0,
                max_recovery_pinned_bytes: 0,
                max_chunk_bytes: 0,
                compression: String::new(),
            },
            capabilities: Vec::new(),
            next_id: 1,
        };
        let hello = client.read();
        assert_eq!(hello.version, PROTOCOL_VERSION_V4);
        match hello.body {
            ServerBodyV4::Hello {
                capabilities,
                manifest,
                ..
            } => {
                assert!(capabilities
                    .iter()
                    .any(|value| value == CAPABILITY_LEASE_DETACH_V4));
                assert!(capabilities
                    .iter()
                    .any(|value| value == CAPABILITY_DECLARED_SESSION_BINDING_V1));
                assert!(capabilities
                    .iter()
                    .any(|value| value == CAPABILITY_IDENTIFY_SURFACE_V1));
                assert_eq!(manifest.max_chunk_bytes as usize, RECOVERY_CHUNK_BYTES);
                assert_eq!(manifest.compression, "none");
                manifest.validate().unwrap();
                client.capabilities = capabilities;
                client.manifest = manifest;
            }
            other => panic!("expected hello, got {other:?}"),
        }
        client.generation = hello.broker_generation;
        client
    }

    fn send(&mut self, command: CommandV4) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        serde_json::to_writer(
            &mut self.writer,
            &RequestV4 {
                version: PROTOCOL_VERSION_V4,
                id,
                command,
            },
        )
        .unwrap();
        self.writer.write_all(b"\n").unwrap();
        self.writer.flush().unwrap();
        id
    }

    fn request(&mut self, command: CommandV4) -> ServerMessageV4 {
        let id = self.send(command);
        loop {
            let message = self.read();
            match message.body {
                ServerBodyV4::Reply { id: response, .. }
                | ServerBodyV4::Error { id: response, .. }
                    if response == id =>
                {
                    return message;
                }
                _ => {}
            }
        }
    }

    fn request_without_live_events(&mut self, command: CommandV4) -> ServerMessageV4 {
        let id = self.send(command);
        loop {
            let message = self.read();
            match message.body {
                ServerBodyV4::StateEvent { .. } => {
                    panic!("live state_event interleaved with suspended recovery")
                }
                ServerBodyV4::Reply { id: response, .. }
                | ServerBodyV4::Error { id: response, .. }
                    if response == id =>
                {
                    return message;
                }
                _ => {}
            }
        }
    }

    fn read(&mut self) -> ServerMessageV4 {
        let mut line = String::new();
        self.reader.read_line(&mut line).unwrap();
        assert!(!line.is_empty(), "broker disconnected");
        serde_json::from_str(&line).unwrap()
    }

    fn create(&mut self, script: &str) -> TerminalSummary {
        let nonce = format!("v4-create-{}", self.next_id);
        match self
            .request(CommandV4::Create {
                create_nonce: nonce,
                session_binding: None,
                program: "/bin/sh".into(),
                args: vec!["-c".into(), script.into()],
                current_directory: None,
                environment: HashMap::new(),
                columns: 80,
                rows: 24,
            })
            .body
        {
            ServerBodyV4::Reply {
                result: ReplyV4::Created { terminal, .. },
                ..
            } => terminal,
            other => panic!("create failed: {other:?}"),
        }
    }

    fn list(&mut self) -> Vec<ouro_broker::TerminalSummaryV4> {
        match self.request(CommandV4::List).body {
            ServerBodyV4::Reply {
                result: ReplyV4::Listed { terminals },
                ..
            } => terminals,
            other => panic!("list failed: {other:?}"),
        }
    }

    fn prepare(&mut self, terminal_id: &str) -> RecoveryBegin {
        let message = self.request(CommandV4::AttachPrepare {
            terminal_id: terminal_id.into(),
            broker_generation: self.generation,
            after_state_seq: None,
        });
        let ServerBodyV4::Reply {
            result:
                ReplyV4::RecoveryBegin {
                    recovery_id,
                    cutover_state_seq,
                    total_bytes,
                    chunk_count,
                    digest,
                    manifest,
                    ..
                },
            ..
        } = message.body
        else {
            panic!("attach_prepare failed: {:?}", message.body);
        };
        let mut checkpoint = Vec::new();
        for expected in 0..chunk_count {
            match self.read().body {
                ServerBodyV4::RecoveryChunk {
                    recovery_id: actual,
                    index,
                    data,
                } => {
                    assert_eq!(actual, recovery_id);
                    assert_eq!(index, expected);
                    assert!(data.len() <= RECOVERY_CHUNK_BYTES);
                    checkpoint.extend(data);
                }
                other => panic!("expected ordered chunk {expected}, got {other:?}"),
            }
        }
        match self.read().body {
            ServerBodyV4::RecoveryEnd {
                recovery_id: actual,
                digest: actual_digest,
            } => {
                assert_eq!(actual, recovery_id);
                assert_eq!(actual_digest, digest);
            }
            other => panic!("expected recovery_end, got {other:?}"),
        }
        assert_eq!(checkpoint.len() as u64, total_bytes);
        assert_eq!(checkpoint_digest_v4(&manifest, &checkpoint), digest);
        RecoveryBegin {
            recovery_id,
            cutover_state_seq,
            digest,
            checkpoint,
        }
    }

    fn commit(&mut self, terminal_id: &str, prepared: &RecoveryBegin) -> Authority {
        let id = self.send(CommandV4::RecoveryCommit {
            recovery_id: prepared.recovery_id.clone(),
            terminal_id: terminal_id.into(),
            broker_generation: self.generation,
            cutover_state_seq: prepared.cutover_state_seq,
            digest: prepared.digest.clone(),
        });
        loop {
            match self.read().body {
                ServerBodyV4::RecoveryDelta { recovery_id, .. } => {
                    assert_eq!(recovery_id, prepared.recovery_id);
                }
                ServerBodyV4::Reply {
                    id: response,
                    result:
                        ReplyV4::AttachedReady {
                            input_epoch,
                            lease_id,
                            ..
                        },
                } if response == id => {
                    return Authority {
                        input_epoch,
                        lease_id,
                    };
                }
                other => panic!("unexpected commit response: {other:?}"),
            }
        }
    }

    fn detach(&mut self, terminal_id: &str, authority: &Authority) -> u64 {
        match self
            .request(CommandV4::Detach {
                terminal_id: terminal_id.into(),
                broker_generation: self.generation,
                input_epoch: authority.input_epoch,
                lease_id: authority.lease_id.clone(),
            })
            .body
        {
            ServerBodyV4::Reply {
                result:
                    ReplyV4::Detached {
                        terminal_id: detached,
                        state_seq,
                    },
                ..
            } => {
                assert_eq!(detached, terminal_id);
                state_seq
            }
            other => panic!("detach failed: {other:?}"),
        }
    }
}

struct RecoveryBegin {
    recovery_id: String,
    cutover_state_seq: u64,
    digest: String,
    checkpoint: Vec<u8>,
}

struct Authority {
    input_epoch: u64,
    lease_id: String,
}

#[derive(Default)]
struct ProbeEngineState {
    bytes: Vec<u8>,
    resizes: Vec<(u16, u16, u32, u32)>,
    snapshots: usize,
    activity: u64,
    compression_steps: usize,
    last_compressed_activity: u64,
}

struct ProbeEngineFactory {
    state: Arc<Mutex<ProbeEngineState>>,
    fail_feed: bool,
}

impl LiveTerminalEngineFactory for ProbeEngineFactory {
    fn create(
        &self,
        config: LiveTerminalEngineConfig,
    ) -> std::io::Result<Box<dyn LiveTerminalEngine>> {
        self.state.lock().unwrap().resizes.push((
            config.columns,
            config.rows,
            config.cell_width_px,
            config.cell_height_px,
        ));
        Ok(Box::new(ProbeEngine {
            state: Arc::clone(&self.state),
            fail_feed: self.fail_feed,
        }))
    }

    fn restore(
        &self,
        _config: LiveTerminalEngineConfig,
        checkpoint: &[u8],
    ) -> std::io::Result<Box<dyn LiveTerminalEngine>> {
        if self.fail_feed {
            return Err(std::io::Error::other(
                "injected live-engine restore failure",
            ));
        }
        let bytes = checkpoint
            .strip_prefix(b"BROKER-OWNED\0")
            .ok_or_else(|| std::io::Error::other("invalid probe checkpoint"))?;
        self.state.lock().unwrap().bytes = bytes.to_vec();
        Ok(Box::new(ProbeEngine {
            state: Arc::clone(&self.state),
            fail_feed: false,
        }))
    }
}

struct ProbeEngine {
    state: Arc<Mutex<ProbeEngineState>>,
    fail_feed: bool,
}

struct RotationFailEngineFactory;

impl LiveTerminalEngineFactory for RotationFailEngineFactory {
    fn create(
        &self,
        _config: LiveTerminalEngineConfig,
    ) -> std::io::Result<Box<dyn LiveTerminalEngine>> {
        Ok(Box::new(RotationFailEngine {
            exported_initial: false,
        }))
    }

    fn restore(
        &self,
        _config: LiveTerminalEngineConfig,
        _checkpoint: &[u8],
    ) -> std::io::Result<Box<dyn LiveTerminalEngine>> {
        Err(std::io::Error::other(
            "rotation-failure probe cannot restore",
        ))
    }
}

struct RotationFailEngine {
    exported_initial: bool,
}

impl LiveTerminalEngine for RotationFailEngine {
    fn feed(&mut self, _bytes: &[u8]) -> std::io::Result<()> {
        Ok(())
    }

    fn resize(
        &mut self,
        _columns: u16,
        _rows: u16,
        _cell_width_px: u32,
        _cell_height_px: u32,
    ) -> std::io::Result<()> {
        Ok(())
    }

    fn export_checkpoint(&mut self) -> std::io::Result<Vec<u8>> {
        if self.exported_initial {
            Err(std::io::Error::other(
                "injected checkpoint rotation failure",
            ))
        } else {
            self.exported_initial = true;
            Ok(b"ROTATION-BASELINE".to_vec())
        }
    }
}

struct TransientRotationEngineFactory {
    remaining_failures: Arc<AtomicUsize>,
}

impl LiveTerminalEngineFactory for TransientRotationEngineFactory {
    fn create(
        &self,
        _config: LiveTerminalEngineConfig,
    ) -> std::io::Result<Box<dyn LiveTerminalEngine>> {
        Ok(Box::new(TransientRotationEngine {
            exported_initial: false,
            remaining_failures: Arc::clone(&self.remaining_failures),
        }))
    }

    fn restore(
        &self,
        _config: LiveTerminalEngineConfig,
        _checkpoint: &[u8],
    ) -> std::io::Result<Box<dyn LiveTerminalEngine>> {
        Ok(Box::new(TransientRotationEngine {
            exported_initial: true,
            remaining_failures: Arc::clone(&self.remaining_failures),
        }))
    }
}

struct TransientRotationEngine {
    exported_initial: bool,
    remaining_failures: Arc<AtomicUsize>,
}

impl LiveTerminalEngine for TransientRotationEngine {
    fn feed(&mut self, _bytes: &[u8]) -> std::io::Result<()> {
        Ok(())
    }

    fn resize(
        &mut self,
        _columns: u16,
        _rows: u16,
        _cell_width_px: u32,
        _cell_height_px: u32,
    ) -> std::io::Result<()> {
        Ok(())
    }

    fn export_checkpoint(&mut self) -> std::io::Result<Vec<u8>> {
        if !self.exported_initial {
            self.exported_initial = true;
            return Ok(b"TRANSIENT-BASELINE".to_vec());
        }
        if self
            .remaining_failures
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |remaining| {
                remaining.checked_sub(1)
            })
            .is_ok()
        {
            return Err(std::io::Error::other(
                "injected transient checkpoint rotation failure",
            ));
        }
        Ok(b"TRANSIENT-RECOVERED".to_vec())
    }
}

#[derive(Default)]
struct RecoveringEngineState {
    bytes: Vec<u8>,
    restores: usize,
}

struct RecoveringEngineFactory {
    state: Arc<Mutex<RecoveringEngineState>>,
}

impl LiveTerminalEngineFactory for RecoveringEngineFactory {
    fn create(
        &self,
        _config: LiveTerminalEngineConfig,
    ) -> std::io::Result<Box<dyn LiveTerminalEngine>> {
        Ok(Box::new(RecoveringEngine {
            state: Arc::clone(&self.state),
            fail_next_feed: true,
        }))
    }

    fn restore(
        &self,
        _config: LiveTerminalEngineConfig,
        checkpoint: &[u8],
    ) -> std::io::Result<Box<dyn LiveTerminalEngine>> {
        let bytes = checkpoint
            .strip_prefix(b"RECOVERABLE\0")
            .ok_or_else(|| std::io::Error::other("invalid recovery test checkpoint"))?;
        let mut state = self.state.lock().unwrap();
        state.bytes = bytes.to_vec();
        state.restores += 1;
        drop(state);
        Ok(Box::new(RecoveringEngine {
            state: Arc::clone(&self.state),
            fail_next_feed: false,
        }))
    }
}

struct RecoveringEngine {
    state: Arc<Mutex<RecoveringEngineState>>,
    fail_next_feed: bool,
}

#[cfg(feature = "ghostty-engine")]
#[derive(Default)]
struct PointerLifetimeState {
    protocol: u8,
    encoded: Vec<(NormalizedMouseAction, u8)>,
    restores: usize,
}

#[cfg(feature = "ghostty-engine")]
struct PointerLifetimeFactory {
    state: Arc<Mutex<PointerLifetimeState>>,
    fail_initial_feed: bool,
}

#[cfg(feature = "ghostty-engine")]
impl LiveTerminalEngineFactory for PointerLifetimeFactory {
    fn create(
        &self,
        _config: LiveTerminalEngineConfig,
    ) -> std::io::Result<Box<dyn LiveTerminalEngine>> {
        self.state.lock().unwrap().protocol = b'A';
        Ok(Box::new(PointerLifetimeEngine {
            state: Arc::clone(&self.state),
            latched_protocol: None,
            fail_next_restore_trigger: self.fail_initial_feed,
        }))
    }

    fn restore(
        &self,
        _config: LiveTerminalEngineConfig,
        _checkpoint: &[u8],
    ) -> std::io::Result<Box<dyn LiveTerminalEngine>> {
        self.state.lock().unwrap().restores += 1;
        Ok(Box::new(PointerLifetimeEngine {
            state: Arc::clone(&self.state),
            latched_protocol: None,
            fail_next_restore_trigger: false,
        }))
    }

    fn supports_normalized_input(&self) -> bool {
        true
    }

    fn supports_pointer_disposition(&self) -> bool {
        true
    }
}

#[cfg(feature = "ghostty-engine")]
struct PointerLifetimeEngine {
    state: Arc<Mutex<PointerLifetimeState>>,
    latched_protocol: Option<u8>,
    fail_next_restore_trigger: bool,
}

#[cfg(feature = "ghostty-engine")]
impl LiveTerminalEngine for PointerLifetimeEngine {
    fn feed(&mut self, bytes: &[u8]) -> std::io::Result<()> {
        if bytes
            .windows(b"MODE-B".len())
            .any(|value| value == b"MODE-B")
        {
            self.state.lock().unwrap().protocol = b'B';
        }
        if self.fail_next_restore_trigger
            && bytes
                .windows(b"RESTORE".len())
                .any(|value| value == b"RESTORE")
        {
            self.fail_next_restore_trigger = false;
            return Err(std::io::Error::other("injected pointer engine restore"));
        }
        Ok(())
    }

    fn resize(
        &mut self,
        _columns: u16,
        _rows: u16,
        _cell_width_px: u32,
        _cell_height_px: u32,
    ) -> std::io::Result<()> {
        Ok(())
    }

    fn export_checkpoint(&mut self) -> std::io::Result<Vec<u8>> {
        Ok(b"POINTER-LIFETIME".to_vec())
    }

    fn encode_normalized_input(
        &mut self,
        event: &NormalizedInputEvent,
        output: &mut [u8],
    ) -> std::io::Result<LiveTerminalInputEncode> {
        let NormalizedInputEvent::Mouse { action, .. } = event else {
            return Ok(LiveTerminalInputEncode::Written(0));
        };
        let current = self.state.lock().unwrap().protocol;
        let protocol = match action {
            NormalizedMouseAction::Press => current,
            NormalizedMouseAction::Motion
            | NormalizedMouseAction::Release
            | NormalizedMouseAction::Cancel => self.latched_protocol.unwrap_or(current),
        };
        // A newline makes the deterministic test child advance from `read`.
        let encoded = [*action as u8, protocol, b'\n'];
        if output.len() < encoded.len() {
            return Ok(LiveTerminalInputEncode::BufferTooSmall {
                required: encoded.len(),
            });
        }
        output[..encoded.len()].copy_from_slice(&encoded);
        match action {
            NormalizedMouseAction::Press => self.latched_protocol = Some(protocol),
            NormalizedMouseAction::Release | NormalizedMouseAction::Cancel => {
                self.latched_protocol = None
            }
            NormalizedMouseAction::Motion => {}
        }
        self.state.lock().unwrap().encoded.push((*action, protocol));
        Ok(LiveTerminalInputEncode::Written(encoded.len()))
    }

    fn pointer_disposition(
        &mut self,
        event: &NormalizedInputEvent,
    ) -> std::io::Result<Option<PointerDisposition>> {
        Ok(matches!(event, NormalizedInputEvent::Mouse { .. }).then_some(PointerDisposition::Pty))
    }
}

impl LiveTerminalEngine for RecoveringEngine {
    fn feed(&mut self, bytes: &[u8]) -> std::io::Result<()> {
        if self.fail_next_feed {
            self.fail_next_feed = false;
            let partial = bytes.len().saturating_div(2).max(1).min(bytes.len());
            self.state
                .lock()
                .unwrap()
                .bytes
                .extend_from_slice(&bytes[..partial]);
            return Err(std::io::Error::other("injected partial feed failure"));
        }
        self.state.lock().unwrap().bytes.extend_from_slice(bytes);
        Ok(())
    }

    fn resize(
        &mut self,
        _columns: u16,
        _rows: u16,
        _cell_width_px: u32,
        _cell_height_px: u32,
    ) -> std::io::Result<()> {
        Ok(())
    }

    fn export_checkpoint(&mut self) -> std::io::Result<Vec<u8>> {
        let mut checkpoint = b"RECOVERABLE\0".to_vec();
        checkpoint.extend_from_slice(&self.state.lock().unwrap().bytes);
        Ok(checkpoint)
    }
}

impl LiveTerminalEngine for ProbeEngine {
    fn feed(&mut self, bytes: &[u8]) -> std::io::Result<()> {
        if self.fail_feed {
            return Err(std::io::Error::other("injected live-engine feed failure"));
        }
        let mut state = self.state.lock().unwrap();
        state.bytes.extend_from_slice(bytes);
        state.activity = state.activity.saturating_add(1);
        Ok(())
    }

    fn resize(
        &mut self,
        columns: u16,
        rows: u16,
        cell_width_px: u32,
        cell_height_px: u32,
    ) -> std::io::Result<()> {
        let mut state = self.state.lock().unwrap();
        state
            .resizes
            .push((columns, rows, cell_width_px, cell_height_px));
        state.activity = state.activity.saturating_add(1);
        Ok(())
    }

    fn export_checkpoint(&mut self) -> std::io::Result<Vec<u8>> {
        let mut state = self.state.lock().unwrap();
        state.snapshots += 1;
        let mut snapshot = b"BROKER-OWNED\0".to_vec();
        snapshot.extend_from_slice(&state.bytes);
        Ok(snapshot)
    }

    fn compression_activity(&self) -> std::io::Result<Option<u64>> {
        Ok(Some(self.state.lock().unwrap().activity))
    }

    fn compress_incremental(&mut self) -> std::io::Result<LiveTerminalCompression> {
        let mut state = self.state.lock().unwrap();
        state.compression_steps += 1;
        state.last_compressed_activity = state.activity;
        Ok(LiveTerminalCompression::Complete)
    }
}

struct FixedCheckpointFactory {
    bytes: usize,
}

impl LiveTerminalEngineFactory for FixedCheckpointFactory {
    fn create(
        &self,
        _config: LiveTerminalEngineConfig,
    ) -> std::io::Result<Box<dyn LiveTerminalEngine>> {
        Ok(Box::new(FixedCheckpointEngine {
            bytes: Vec::new(),
            checkpoint_bytes: self.bytes,
        }))
    }

    fn restore(
        &self,
        _config: LiveTerminalEngineConfig,
        checkpoint: &[u8],
    ) -> std::io::Result<Box<dyn LiveTerminalEngine>> {
        if checkpoint.len() != self.bytes {
            return Err(std::io::Error::other("fixed checkpoint length mismatch"));
        }
        Ok(Box::new(FixedCheckpointEngine {
            bytes: checkpoint.to_vec(),
            checkpoint_bytes: self.bytes,
        }))
    }
}

struct FixedCheckpointEngine {
    bytes: Vec<u8>,
    checkpoint_bytes: usize,
}

impl LiveTerminalEngine for FixedCheckpointEngine {
    fn feed(&mut self, bytes: &[u8]) -> std::io::Result<()> {
        self.bytes.extend_from_slice(bytes);
        Ok(())
    }

    fn resize(
        &mut self,
        _columns: u16,
        _rows: u16,
        _cell_width_px: u32,
        _cell_height_px: u32,
    ) -> std::io::Result<()> {
        Ok(())
    }

    fn export_checkpoint(&mut self) -> std::io::Result<Vec<u8>> {
        let mut checkpoint = vec![0; self.checkpoint_bytes];
        let marker = b"FIXED-CHECKPOINT\0";
        let marker_len = marker.len().min(checkpoint.len());
        checkpoint[..marker_len].copy_from_slice(&marker[..marker_len]);
        let copy_len = self
            .bytes
            .len()
            .min(checkpoint.len().saturating_sub(marker.len()));
        if copy_len > 0 {
            let destination = checkpoint.len() - copy_len;
            checkpoint[destination..].copy_from_slice(&self.bytes[self.bytes.len() - copy_len..]);
        }
        Ok(checkpoint)
    }
}

fn assert_error(message: ServerMessageV4, expected: ErrorCode) {
    match message.body {
        ServerBodyV4::Error { code, .. } => assert_eq!(code, expected),
        other => panic!("expected {expected:?}, got {other:?}"),
    }
}

#[cfg(feature = "ghostty-engine")]
fn normalized_command(
    generation: u64,
    terminal_id: &str,
    authority: &Authority,
    input_seq: u64,
    event: NormalizedInputEvent,
) -> CommandV4 {
    let event_digest = normalized_input_event_digest_v1(&event);
    CommandV4::NormalizedInput {
        terminal_id: terminal_id.into(),
        broker_generation: generation,
        input_epoch: authority.input_epoch,
        input_seq,
        lease_id: authority.lease_id.clone(),
        event_digest,
        event,
    }
}

#[cfg(feature = "ghostty-engine")]
fn assert_input_receipt(
    message: ServerMessageV4,
    terminal_id: &str,
    authority: &Authority,
    input_seq: u64,
    event_digest: &str,
) {
    match message.body {
        ServerBodyV4::Reply {
            result:
                ReplyV4::InputReceipt {
                    terminal_id: actual_terminal,
                    input_epoch,
                    input_seq: actual_seq,
                    lease_id: actual_lease,
                    event_digest: actual_digest,
                    observed_state_seq: _,
                    layout_epoch: _,
                    pointer_disposition,
                },
            ..
        } => {
            assert_eq!(actual_terminal, terminal_id);
            assert_eq!(input_epoch, authority.input_epoch);
            assert_eq!(actual_seq, input_seq);
            assert_eq!(actual_lease, authority.lease_id);
            assert_eq!(actual_digest, event_digest);
            assert_eq!(pointer_disposition, None);
        }
        other => panic!("expected normalized input receipt, got {other:?}"),
    }
}

#[cfg(feature = "ghostty-engine")]
fn assert_pointer_receipt(
    message: ServerMessageV4,
    terminal_id: &str,
    authority: &Authority,
    input_seq: u64,
    event_digest: &str,
    expected: Option<PointerDisposition>,
) {
    match message.body {
        ServerBodyV4::Reply {
            result:
                ReplyV4::InputReceipt {
                    terminal_id: actual_terminal,
                    input_epoch,
                    input_seq: actual_seq,
                    lease_id: actual_lease,
                    event_digest: actual_digest,
                    observed_state_seq: _,
                    layout_epoch: _,
                    pointer_disposition,
                },
            ..
        } => {
            assert_eq!(actual_terminal, terminal_id);
            assert_eq!(input_epoch, authority.input_epoch);
            assert_eq!(actual_seq, input_seq);
            assert_eq!(actual_lease, authority.lease_id);
            assert_eq!(actual_digest, event_digest);
            assert_eq!(pointer_disposition, expected);
        }
        other => panic!("expected pointer input receipt, got {other:?}"),
    }
}

#[test]
fn digest_preimage_has_a_cross_language_known_vector() {
    let config = BrokerConfig::new("unused.sock");
    let manifest = CapabilityManifestV4::canonical_replay_fixture(&config);
    assert_eq!(
        checkpoint_digest_v4(&manifest, b"abc"),
        "sha256:295f150351bd02910106ee8a36dd64855f1a1f2547dfa26aa7163acd2ad80657"
    );
    assert_eq!(
        ouro_broker::normalized_input_event_digest_v1(&ouro_broker::NormalizedInputEvent::Focus {
            focused: true
        }),
        "sha256:26fbfeca81af92b8d75869e54552f09881cff9540377db5d73624db1656d915e"
    );
}

#[test]
fn identify_surface_wire_is_flat_and_rejects_unknown_fields() {
    let exact = serde_json::json!({
        "version": PROTOCOL_VERSION_V4,
        "id": 17,
        "op": "identify_surface",
        "terminal_id": "term-4",
        "broker_generation": 91,
        "create_nonce": "create-4",
        "session_binding": {
            "source_id": "ouroboros-local",
            "session_id": "session-4",
            "execution_id": "execution-4",
            "session_scope_id": "scope-4",
            "session_attempt_id": "attempt-4"
        }
    });
    let decoded: RequestV4 = serde_json::from_value(exact.clone()).unwrap();
    assert!(matches!(
        &decoded.command,
        CommandV4::IdentifySurface(IdentifySurfaceV1 {
            terminal_id,
            broker_generation: 91,
            create_nonce,
            ..
        }) if terminal_id == "term-4" && create_nonce == "create-4"
    ));
    assert_eq!(serde_json::to_value(decoded).unwrap(), exact);

    let mut unknown = exact;
    unknown
        .as_object_mut()
        .unwrap()
        .insert("trusted".into(), serde_json::json!(true));
    assert!(serde_json::from_value::<RequestV4>(unknown).is_err());
}

#[test]
fn create_binds_exact_attempt_metadata_and_returns_it_with_terminal_identity() {
    let broker = BrokerThread::start(Duration::from_secs(5), 1024 * 1024);
    let mut client = Client::connect(&broker.socket);
    let binding = DeclaredSessionBindingV1 {
        source_id: "ouroboros-local".try_into().unwrap(),
        session_id: "session-7".try_into().unwrap(),
        execution_id: "execution-8".try_into().unwrap(),
        session_scope_id: "scope-9".try_into().unwrap(),
        session_attempt_id: "attempt-10".try_into().unwrap(),
    };
    let created = client.request(CommandV4::Create {
        create_nonce: "bound-create-1".into(),
        session_binding: Some(binding.clone()),
        program: "/bin/sh".into(),
        args: vec!["-c".into(), "sleep 5".into()],
        current_directory: None,
        environment: HashMap::new(),
        columns: 80,
        rows: 24,
    });
    let (terminal, returned_binding) = match created.body {
        ServerBodyV4::Reply {
            result:
                ReplyV4::Created {
                    terminal,
                    session_binding,
                    ..
                },
            ..
        } => (terminal, session_binding),
        other => panic!("bound create failed: {other:?}"),
    };
    assert_eq!(returned_binding, Some(binding.clone()));
    assert!(!terminal.id.is_empty());
    assert_ne!(created.broker_generation, 0);

    let listed = client.list();
    let listed = listed
        .into_iter()
        .find(|entry| entry.terminal.id == terminal.id)
        .expect("bound terminal remains discoverable");
    assert_eq!(listed.session_binding, Some(binding.clone()));

    // A second nonce cannot create an ambiguous second PTY for one exact
    // attempt. This rejection is not a privilege grant or attach mechanism.
    let duplicate = client.request(CommandV4::Create {
        create_nonce: "bound-create-2".into(),
        session_binding: Some(binding),
        program: "/bin/sh".into(),
        args: vec!["-c".into(), "sleep 5".into()],
        current_directory: None,
        environment: HashMap::new(),
        columns: 80,
        rows: 24,
    });
    assert_error(duplicate, ErrorCode::BadRequest);
}

#[test]
fn identify_surface_proves_the_exact_live_pty_only_to_its_creator() {
    let broker = BrokerThread::start(Duration::from_secs(5), 1024 * 1024);
    let mut creator = Client::connect(&broker.socket);
    let mut foreign_connection = Client::connect(&broker.socket);
    let binding = DeclaredSessionBindingV1 {
        source_id: "ouroboros-local".try_into().unwrap(),
        session_id: "session-proof".try_into().unwrap(),
        execution_id: "execution-proof".try_into().unwrap(),
        session_scope_id: "scope-proof".try_into().unwrap(),
        session_attempt_id: "attempt-proof".try_into().unwrap(),
    };
    let create_nonce = "surface-proof-create";
    let created = creator.request(CommandV4::Create {
        create_nonce: create_nonce.into(),
        session_binding: Some(binding.clone()),
        program: "/bin/sh".into(),
        args: vec!["-c".into(), "sleep 5".into()],
        current_directory: None,
        environment: HashMap::new(),
        columns: 80,
        rows: 24,
    });
    let terminal_id = match created.body {
        ServerBodyV4::Reply {
            result: ReplyV4::Created { terminal, .. },
            ..
        } => terminal.id,
        other => panic!("surface create failed: {other:?}"),
    };

    assert_error(
        foreign_connection.request(CommandV4::IdentifySurface(IdentifySurfaceV1 {
            terminal_id: terminal_id.clone(),
            broker_generation: foreign_connection.generation,
            create_nonce: create_nonce.into(),
            session_binding: binding.clone(),
        })),
        ErrorCode::ResyncRequired,
    );
    assert_error(
        creator.request(CommandV4::IdentifySurface(IdentifySurfaceV1 {
            terminal_id: terminal_id.clone(),
            broker_generation: creator.generation.wrapping_add(1),
            create_nonce: create_nonce.into(),
            session_binding: binding.clone(),
        })),
        ErrorCode::StaleGeneration,
    );
    assert_error(
        creator.request(CommandV4::IdentifySurface(IdentifySurfaceV1 {
            terminal_id: terminal_id.clone(),
            broker_generation: creator.generation,
            create_nonce: "wrong-create-nonce".into(),
            session_binding: binding.clone(),
        })),
        ErrorCode::BadRequest,
    );
    let mut sibling_binding = binding.clone();
    sibling_binding.session_attempt_id = "attempt-sibling".try_into().unwrap();
    assert_error(
        creator.request(CommandV4::IdentifySurface(IdentifySurfaceV1 {
            terminal_id: terminal_id.clone(),
            broker_generation: creator.generation,
            create_nonce: create_nonce.into(),
            session_binding: sibling_binding,
        })),
        ErrorCode::BadRequest,
    );

    let creator_generation = creator.generation;
    let identify = || {
        CommandV4::IdentifySurface(IdentifySurfaceV1 {
            terminal_id: terminal_id.clone(),
            broker_generation: creator_generation,
            create_nonce: create_nonce.into(),
            session_binding: binding.clone(),
        })
    };
    let first = creator.request(identify());
    assert_eq!(first.broker_generation, creator.generation);
    let first_receipt = match first.body {
        ServerBodyV4::Reply {
            result:
                ReplyV4::SurfaceIdentified {
                    terminal_id: actual_terminal,
                    create_nonce: actual_nonce,
                    session_binding,
                    producer_receipt,
                },
            ..
        } => {
            assert_eq!(actual_terminal, terminal_id);
            assert_eq!(actual_nonce, create_nonce);
            assert_eq!(session_binding, binding);
            assert_eq!(producer_receipt.len(), 48);
            assert!(producer_receipt
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit()));
            producer_receipt
        }
        other => panic!("surface identification failed: {other:?}"),
    };
    let second = creator.request(identify());
    match second.body {
        ServerBodyV4::Reply {
            result: ReplyV4::SurfaceIdentified {
                producer_receipt, ..
            },
            ..
        } => assert_eq!(producer_receipt, first_receipt),
        other => panic!("surface identification retry failed: {other:?}"),
    }

    let list_json = serde_json::to_string(&ReplyV4::Listed {
        terminals: creator.list(),
    })
    .unwrap();
    assert!(!list_json.contains("producer_receipt"));
    assert!(!list_json.contains(&first_receipt));
}

#[test]
fn bound_create_retry_reconciles_the_same_surface_after_a_fast_exit() {
    let broker = BrokerThread::start(Duration::from_secs(5), 1024 * 1024);
    let mut client = Client::connect(&broker.socket);
    let binding = DeclaredSessionBindingV1 {
        source_id: "ouroboros-local".try_into().unwrap(),
        session_id: "session-fast".try_into().unwrap(),
        execution_id: "execution-fast".try_into().unwrap(),
        session_scope_id: "scope-fast".try_into().unwrap(),
        session_attempt_id: "attempt-fast".try_into().unwrap(),
    };
    let create = |nonce: &str, binding: DeclaredSessionBindingV1| CommandV4::Create {
        create_nonce: nonce.into(),
        session_binding: Some(binding),
        program: "/bin/sh".into(),
        args: vec!["-c".into(), "exit 0".into()],
        current_directory: None,
        environment: HashMap::new(),
        columns: 80,
        rows: 24,
    };

    let first = client.request(create("bound-fast-create", binding.clone()));
    let first_id = match first.body {
        ServerBodyV4::Reply {
            result: ReplyV4::Created { terminal, .. },
            ..
        } => terminal.id,
        other => panic!("fast bound create failed: {other:?}"),
    };
    let deadline = Instant::now() + Duration::from_secs(2);
    while client
        .list()
        .iter()
        .any(|entry| entry.terminal.id == first_id)
    {
        assert!(Instant::now() < deadline, "fast terminal was not reaped");
        thread::sleep(Duration::from_millis(5));
    }

    assert_error(
        client.request(CommandV4::IdentifySurface(IdentifySurfaceV1 {
            terminal_id: first_id.clone(),
            broker_generation: client.generation,
            create_nonce: "bound-fast-create".into(),
            session_binding: binding.clone(),
        })),
        ErrorCode::NotFound,
    );

    let replay = client.request(create("bound-fast-create", binding.clone()));
    match replay.body {
        ServerBodyV4::Reply {
            result:
                ReplyV4::Created {
                    terminal,
                    session_binding,
                    ..
                },
            ..
        } => {
            assert_eq!(terminal.id, first_id);
            assert!(!terminal.running);
            assert_eq!(session_binding, Some(binding.clone()));
        }
        other => panic!("tombstone reconciliation failed: {other:?}"),
    }

    assert_error(
        client.request(create("different-nonce", binding)),
        ErrorCode::BadRequest,
    );
}

#[test]
fn broker_owned_live_engine_receives_pty_resize_and_exports_the_checkpoint() {
    let state = Arc::new(Mutex::new(ProbeEngineState::default()));
    let broker = BrokerThread::start_with_live_engine(Arc::new(ProbeEngineFactory {
        state: Arc::clone(&state),
        fail_feed: false,
    }));
    let mut client = Client::connect(&broker.socket);
    assert_eq!(client.manifest.snapshot_magic, "TEST-LIVE-ENGINE");
    let terminal = client.create("printf 'ENGINE-OWNED'; sleep 5");
    let deadline = Instant::now() + Duration::from_secs(2);
    while !state
        .lock()
        .unwrap()
        .bytes
        .windows(b"ENGINE-OWNED".len())
        .any(|window| window == b"ENGINE-OWNED")
    {
        assert!(Instant::now() < deadline, "live engine missed PTY output");
        thread::sleep(Duration::from_millis(5));
    }

    let prepared = client.prepare(&terminal.id);
    assert!(prepared.checkpoint.starts_with(b"BROKER-OWNED\0"));
    assert!(prepared
        .checkpoint
        .windows(b"ENGINE-OWNED".len())
        .any(|window| window == b"ENGINE-OWNED"));
    let authority = client.commit(&terminal.id, &prepared);
    let resized = client.request(CommandV4::Resize {
        terminal_id: terminal.id,
        broker_generation: client.generation,
        input_epoch: authority.input_epoch,
        lease_id: authority.lease_id,
        columns: 96,
        rows: 31,
        cell_width_px: 9,
        cell_height_px: 18,
        layout_epoch: 1,
    });
    assert!(matches!(
        resized.body,
        ServerBodyV4::Reply {
            result: ReplyV4::Accepted,
            ..
        }
    ));
    let state = state.lock().unwrap();
    assert_eq!(state.snapshots, 2);
    assert!(state.resizes.contains(&(96, 31, 9, 18)));
}

#[test]
fn failed_live_engine_feed_disables_checkpoint_export_without_killing_the_pty() {
    let state = Arc::new(Mutex::new(ProbeEngineState::default()));
    let broker = BrokerThread::start_with_live_engine(Arc::new(ProbeEngineFactory {
        state,
        fail_feed: true,
    }));
    let mut client = Client::connect(&broker.socket);
    let terminal = client.create("printf 'TRIGGER-FAILURE'; sleep 5");
    thread::sleep(Duration::from_millis(40));
    let rejected = client.request(CommandV4::AttachPrepare {
        terminal_id: terminal.id.clone(),
        broker_generation: client.generation,
        after_state_seq: None,
    });
    assert_error(rejected, ErrorCode::Internal);

    let listed = client.request(CommandV4::List);
    let ServerBodyV4::Reply {
        result: ReplyV4::Listed { terminals },
        ..
    } = listed.body
    else {
        panic!("terminal disappeared after live-engine failure")
    };
    assert!(terminals
        .iter()
        .any(|entry| entry.terminal.id == terminal.id));
}

#[test]
fn failed_live_engine_feed_restores_immutable_checkpoint_and_replays_raw_tail() {
    let state = Arc::new(Mutex::new(RecoveringEngineState::default()));
    let broker = BrokerThread::start_with_live_engine(Arc::new(RecoveringEngineFactory {
        state: Arc::clone(&state),
    }));
    let mut client = Client::connect(&broker.socket);
    let terminal = client.create("printf 'RESTORED-FROM-TAIL'; sleep 5");
    let deadline = Instant::now() + Duration::from_secs(2);
    while state.lock().unwrap().restores == 0 {
        assert!(
            Instant::now() < deadline,
            "broker never attempted immutable checkpoint recovery"
        );
        thread::sleep(Duration::from_millis(5));
    }

    let prepared = client.prepare(&terminal.id);
    assert!(prepared.checkpoint.starts_with(b"RECOVERABLE\0"));
    assert!(prepared
        .checkpoint
        .windows(b"RESTORED-FROM-TAIL".len())
        .any(|window| window == b"RESTORED-FROM-TAIL"));
    assert_eq!(
        prepared
            .checkpoint
            .windows(b"RESTORED-FROM-TAIL".len())
            .filter(|window| *window == b"RESTORED-FROM-TAIL")
            .count(),
        1,
        "partial bytes from the failed handle leaked into restored state"
    );
}

#[test]
fn immutable_live_checkpoints_obey_a_broker_global_admission_budget() {
    let state = Arc::new(Mutex::new(ProbeEngineState::default()));
    let one_checkpoint = b"BROKER-OWNED\0".len();
    let broker = BrokerThread::start_with_live_engine_checkpoint_budget(
        Arc::new(ProbeEngineFactory {
            state,
            fail_feed: false,
        }),
        one_checkpoint,
    );
    let mut client = Client::connect(&broker.socket);
    let first = client.create("sleep 5");
    let second = client.request(CommandV4::Create {
        create_nonce: "checkpoint-budget-second".into(),
        session_binding: None,
        program: "/bin/sh".into(),
        args: vec!["-c".into(), "sleep 5".into()],
        current_directory: None,
        environment: HashMap::new(),
        columns: 80,
        rows: 24,
    });
    let second = match second.body {
        ServerBodyV4::Reply {
            result: ReplyV4::Created { terminal, .. },
            ..
        } => terminal,
        other => panic!("second terminal was not admitted through inactive eviction: {other:?}"),
    };
    assert_eq!(
        second.checkpoint_state,
        ouro_broker::CheckpointStateV4::Resident
    );
    let listed = client.list();
    let first_status = listed
        .iter()
        .find(|entry| entry.terminal.id == first.id)
        .expect("first terminal remains listed");
    let second_status = listed
        .iter()
        .find(|entry| entry.terminal.id == second.id)
        .expect("second terminal remains listed");
    assert_eq!(
        first_status.terminal.checkpoint_state,
        ouro_broker::CheckpointStateV4::Evicted
    );
    assert!(first_status.terminal.checkpoint_evictions >= 1);
    assert_eq!(
        second_status.terminal.checkpoint_bytes as usize,
        one_checkpoint
    );
    assert!(
        listed
            .iter()
            .map(|entry| entry.terminal.checkpoint_bytes)
            .sum::<u64>()
            <= one_checkpoint as u64
    );

    // Rebuilding the evicted terminal protects it while attached and evicts
    // the previously resident inactive terminal instead of exceeding the
    // global immutable budget.
    let prepared = client.prepare(&first.id);
    assert_eq!(prepared.checkpoint, b"BROKER-OWNED\0");
    let authority = client.commit(&first.id, &prepared);
    let listed = client.list();
    let first_status = listed
        .iter()
        .find(|entry| entry.terminal.id == first.id)
        .expect("rebuilt terminal remains listed");
    assert_eq!(
        first_status.terminal.checkpoint_state,
        ouro_broker::CheckpointStateV4::Resident
    );
    assert!(first_status.terminal.checkpoint_protected);
    assert!(first_status.terminal.checkpoint_rebuilds >= 1);
    let second_status = listed
        .iter()
        .find(|entry| entry.terminal.id == second.id)
        .expect("evicted inactive terminal remains listed");
    assert_eq!(
        second_status.terminal.checkpoint_state,
        ouro_broker::CheckpointStateV4::Evicted
    );
    client.detach(&first.id, &authority);

    let terminated = client.request(CommandV4::Terminate {
        terminal_id: first.id.clone(),
        broker_generation: client.generation,
    });
    assert!(matches!(
        terminated.body,
        ServerBodyV4::Reply {
            result: ReplyV4::Accepted,
            ..
        }
    ));
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let listed = client.request(CommandV4::List);
        let ServerBodyV4::Reply {
            result: ReplyV4::Listed { terminals },
            ..
        } = listed.body
        else {
            panic!("unexpected list response")
        };
        if terminals.iter().all(|entry| entry.terminal.id != first.id) {
            break;
        }
        assert!(Instant::now() < deadline, "terminal was not reaped");
        thread::sleep(Duration::from_millis(5));
    }
    let _replacement = client.create("sleep 5");
}

#[test]
fn thirty_two_terminals_evict_inactive_checkpoints_without_permanent_pollin_stall() {
    let checkpoint_bytes = 64;
    let broker = BrokerThread::start_with_live_engine_checkpoint_budget(
        Arc::new(FixedCheckpointFactory {
            bytes: checkpoint_bytes,
        }),
        checkpoint_bytes,
    );
    let mut client = Client::connect(&broker.socket);
    let mut terminals = Vec::new();
    for _ in 0..31 {
        terminals.push(client.create("sleep 5"));
    }

    // Keep one terminal visible/attached. It is protected while the final
    // terminal is admitted and emits output into an evicted/degraded engine.
    let first = terminals.first().expect("first terminal").clone();
    let first_recovery = client.prepare(&first.id);
    let first_authority = client.commit(&first.id, &first_recovery);
    let flood = client.create("printf 'FANOUT-TAIL'; sleep 5");

    thread::sleep(Duration::from_millis(120));
    let listed = client.list();
    let first_status = listed
        .iter()
        .find(|entry| entry.terminal.id == first.id)
        .expect("visible terminal remains listed");
    assert_eq!(
        first_status.terminal.checkpoint_state,
        ouro_broker::CheckpointStateV4::Resident
    );
    assert!(first_status.terminal.checkpoint_protected);
    assert_eq!(first_status.terminal.recovery_paused_ms, None);
    let flood_status = listed
        .iter()
        .find(|entry| entry.terminal.id == flood.id)
        .expect("flood terminal remains listed");
    assert_eq!(
        flood_status.terminal.checkpoint_state,
        ouro_broker::CheckpointStateV4::Evicted
    );
    assert_eq!(flood_status.terminal.recovery_pause_count, 0);
    assert!(
        listed
            .iter()
            .map(|entry| entry.terminal.checkpoint_bytes)
            .sum::<u64>()
            <= checkpoint_bytes as u64
    );

    // Detaching the visible terminal makes it reclaimable. The previously
    // degraded terminal then rebuilds its fixed checkpoint and proves that
    // its PTY output was not permanently blocked by the saturated cache.
    client.detach(&first.id, &first_authority);
    let flood_recovery = client.prepare(&flood.id);
    assert!(flood_recovery
        .checkpoint
        .windows(b"FANOUT-TAIL".len())
        .any(|window| window == b"FANOUT-TAIL"));
    let flood_status = client
        .list()
        .into_iter()
        .find(|entry| entry.terminal.id == flood.id)
        .expect("rebuilt flood terminal remains listed");
    assert_eq!(
        flood_status.terminal.checkpoint_state,
        ouro_broker::CheckpointStateV4::Resident
    );
    assert!(flood_status.terminal.checkpoint_rebuilds >= 1);
    assert_eq!(flood_status.terminal.recovery_paused_ms, None);
}

#[test]
fn idle_compression_is_activity_gated_and_runs_in_bounded_reactor_slices() {
    let state = Arc::new(Mutex::new(ProbeEngineState::default()));
    let broker = BrokerThread::start_with_live_engine(Arc::new(ProbeEngineFactory {
        state: Arc::clone(&state),
        fail_feed: false,
    }));
    let mut client = Client::connect(&broker.socket);
    let _terminal = client.create("printf 'COMPRESS-ME'; sleep 5");
    let deadline = Instant::now() + Duration::from_secs(2);
    while state.lock().unwrap().last_compressed_activity == 0 {
        assert!(
            Instant::now() < deadline,
            "idle engine never received a bounded compression step"
        );
        thread::sleep(Duration::from_millis(5));
    }
    let steps = state.lock().unwrap().compression_steps;
    thread::sleep(Duration::from_millis(40));
    let state = state.lock().unwrap();
    assert_eq!(state.compression_steps, steps);
    assert_eq!(state.last_compressed_activity, state.activity);
}

#[test]
fn checkpoint_rotation_failure_backpressures_pty_without_starving_reactor() {
    let broker = BrokerThread::start_with_live_engine(Arc::new(RotationFailEngineFactory));
    let mut client = Client::connect(&broker.socket);
    let terminal = client.create("/usr/bin/yes x | /usr/bin/head -c 655360; sleep 5");

    // The ordered tail reaches its rotation boundary, where the probe engine
    // rejects every replacement checkpoint. The PTY must pause, but the one
    // reactor thread must still return from read_terminal and admit clients.
    thread::sleep(Duration::from_millis(100));
    let stream = UnixStream::connect(&broker.socket).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_millis(500)))
        .unwrap();
    let mut reader = BufReader::new(stream);
    let mut hello = String::new();
    reader.read_line(&mut hello).unwrap();
    let hello: ServerMessageV4 = serde_json::from_str(&hello).unwrap();
    assert!(matches!(hello.body, ServerBodyV4::Hello { .. }));

    let listed = client.request(CommandV4::List);
    let ServerBodyV4::Reply {
        result: ReplyV4::Listed { terminals },
        ..
    } = listed.body
    else {
        panic!("unexpected list response")
    };
    assert!(terminals
        .iter()
        .any(|entry| entry.terminal.id == terminal.id && entry.terminal.running));
}

#[test]
fn transient_checkpoint_pause_is_telemetrized_and_releases_pollin() {
    let failures = Arc::new(AtomicUsize::new(0));
    let broker = BrokerThread::start_with_live_engine(Arc::new(TransientRotationEngineFactory {
        remaining_failures: Arc::clone(&failures),
    }));
    let mut client = Client::connect(&broker.socket);
    let terminal = client.create(
        "read gate; /usr/bin/yes x | /usr/bin/head -c 2097152; printf 'TRANSIENT-DONE'; sleep 5",
    );
    let prepared = client.prepare(&terminal.id);
    let authority = client.commit(&terminal.id, &prepared);
    failures.store(4, Ordering::Release);
    let trigger = client.request(CommandV4::Input {
        terminal_id: terminal.id.clone(),
        broker_generation: client.generation,
        input_epoch: authority.input_epoch,
        lease_id: authority.lease_id,
        data: b"go\n".to_vec(),
    });
    assert!(matches!(
        trigger.body,
        ServerBodyV4::Reply {
            result: ReplyV4::Accepted,
            ..
        }
    ));

    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        let status = client
            .list()
            .into_iter()
            .find(|entry| entry.terminal.id == terminal.id)
            .expect("transient terminal remains listed")
            .terminal;
        if status.recovery_pause_count >= 1
            && status.recovery_paused_ms.is_none()
            && status.checkpoint_state == ouro_broker::CheckpointStateV4::Resident
        {
            assert_eq!(failures.load(Ordering::Acquire), 0);
            assert!(status.recovery_tail_bytes < client.manifest.max_delta_bytes);
            break;
        }
        assert!(
            Instant::now() < deadline,
            "transient checkpoint pause did not recover: {status:?}"
        );
        thread::sleep(Duration::from_millis(10));
    }
}

#[cfg(feature = "ghostty-engine")]
#[test]
fn exact_pin_ghostty_broker_exports_live_engine_snapshots_and_raw_tail() {
    let broker = GhosttyBrokerProcess::start();
    let mut client = Client::connect(&broker.socket);
    assert_eq!(
        client.manifest.terminal_abi_version,
        ouro_terminal_ghostty::TERMINAL_ENGINE_ABI_VERSION
    );
    assert_eq!(client.manifest.snapshot_magic, "GHOSTSNP");
    assert_eq!(
        client.manifest.engine_source_commit,
        "136f436a3bbb14fd48d18e927a83fc6585d5a63c"
    );
    assert!(client
        .capabilities
        .iter()
        .any(|capability| capability == CAPABILITY_NORMALIZED_INPUT_V1));
    assert!(client
        .capabilities
        .iter()
        .any(|capability| capability == CAPABILITY_POINTER_DISPOSITION_V1));

    let terminal = client.create("printf '\\033[1;32mGHOSTTY-HEAD\\033[0m\\r\\n'; exec /bin/cat");
    thread::sleep(Duration::from_millis(40));
    let first = client.prepare(&terminal.id);
    assert!(first.checkpoint.starts_with(b"GHOSTSNP\x01\x00"));
    let authority = client.commit(&terminal.id, &first);

    let raw = client.request(CommandV4::Input {
        terminal_id: terminal.id.clone(),
        broker_generation: client.generation,
        input_epoch: authority.input_epoch,
        lease_id: authority.lease_id.clone(),
        data: b"GHOSTTY-LIVE-TAIL\n".to_vec(),
    });
    assert_error(raw, ErrorCode::Unsupported);

    let event = NormalizedInputEvent::Paste {
        utf8: b"GHOSTTY-LIVE-TAIL\n".to_vec(),
    };
    let digest = normalized_input_event_digest_v1(&event);
    let input_id = client.send(normalized_command(
        client.generation,
        &terminal.id,
        &authority,
        1,
        event,
    ));
    let mut accepted = false;
    let mut raw_tail = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(3);
    while !accepted
        || !raw_tail
            .windows(b"GHOSTTY-LIVE-TAIL".len())
            .any(|window| window == b"GHOSTTY-LIVE-TAIL")
    {
        assert!(
            Instant::now() < deadline,
            "live Ghostty tail was not observed"
        );
        match client.read().body {
            ServerBodyV4::Reply {
                id,
                result:
                    ReplyV4::InputReceipt {
                        input_seq: 1,
                        event_digest,
                        ..
                    },
            } if id == input_id && event_digest == digest => accepted = true,
            ServerBodyV4::StateEvent {
                event: WireStateEvent::PtyBytes { data, .. },
                ..
            } => raw_tail.extend(data),
            _ => {}
        }
    }

    let second = client.prepare(&terminal.id);
    assert!(second.checkpoint.starts_with(b"GHOSTSNP\x01\x00"));
    assert_ne!(first.checkpoint, second.checkpoint);
}

#[cfg(feature = "ghostty-engine")]
#[test]
fn normalized_input_is_exactly_once_and_rejects_digest_conflicts_and_gaps() {
    let broker = GhosttyBrokerProcess::start();
    let mut client = Client::connect(&broker.socket);
    let terminal = client.create("stty -echo; IFS= read -r line; printf '<%s>' \"$line\"; exit 0");
    thread::sleep(Duration::from_millis(40));
    let prepared = client.prepare(&terminal.id);
    let authority = client.commit(&terminal.id, &prepared);

    let gap_event = NormalizedInputEvent::Focus { focused: true };
    let generation = client.generation;
    let gap = client.request(normalized_command(
        generation,
        &terminal.id,
        &authority,
        2,
        gap_event,
    ));
    assert_error(gap, ErrorCode::InputGap);

    let event = NormalizedInputEvent::Paste {
        utf8: b"EXACTLY-ONCE\n".to_vec(),
    };
    let digest = normalized_input_event_digest_v1(&event);
    let command = normalized_command(generation, &terminal.id, &authority, 1, event);
    let first_id = client.send(command.clone());
    let duplicate_id = client.send(command);
    let conflict_event = NormalizedInputEvent::Focus { focused: false };
    let conflict_id = client.send(normalized_command(
        generation,
        &terminal.id,
        &authority,
        1,
        conflict_event,
    ));
    let mut receipts = 0;
    let mut conflict_rejected = false;
    let mut output = Vec::new();
    let mut exited = false;
    let deadline = Instant::now() + Duration::from_secs(3);
    while receipts != 2 || !conflict_rejected || !exited {
        assert!(
            Instant::now() < deadline,
            "normalized duplicate test timed out"
        );
        match client.read().body {
            ServerBodyV4::Reply {
                id,
                result:
                    ReplyV4::InputReceipt {
                        input_epoch,
                        input_seq,
                        event_digest,
                        ..
                    },
            } if id == first_id || id == duplicate_id => {
                assert_eq!(input_epoch, authority.input_epoch);
                assert_eq!(input_seq, 1);
                assert_eq!(event_digest, digest);
                receipts += 1;
            }
            ServerBodyV4::StateEvent {
                event: WireStateEvent::PtyBytes { data, .. },
                ..
            } => output.extend(data),
            ServerBodyV4::Exited { terminal_id, .. } => {
                assert_eq!(terminal_id, terminal.id);
                exited = true;
            }
            ServerBodyV4::Error {
                id,
                code: ErrorCode::InputConflict,
                ..
            } if id == conflict_id => conflict_rejected = true,
            _ => {}
        }
    }
    assert_eq!(
        output
            .windows(b"<EXACTLY-ONCE>".len())
            .filter(|window| *window == b"<EXACTLY-ONCE>")
            .count(),
        1,
        "duplicate input was written to the PTY more than once"
    );
}

#[cfg(feature = "ghostty-engine")]
#[test]
fn shell_two_cutover_committed_text_and_hid_return_reach_the_second_pty() {
    // This is the smallest broker-level reproduction of the Shell 2 acting
    // path: the first attachment is committed, a second attachment cuts it
    // over, and the second lease receives the exact AppKit event sequence
    // (committed text, Return press, Return release). The child only exits
    // after the canonical PTY line discipline observes the Return.
    let broker = GhosttyBrokerProcess::start();
    let mut client = Client::connect(&broker.socket);
    let first = client.create("exec /bin/cat");
    let first_prepared = client.prepare(&first.id);
    let _first_authority = client.commit(&first.id, &first_prepared);

    let second =
        client.create("stty -echo; IFS= read -r line; printf '<SHELL2:%s>\\n' \"$line\"; exit 0");
    let second_prepared = client.prepare(&second.id);
    let second_authority = client.commit(&second.id, &second_prepared);

    let events = [
        NormalizedInputEvent::CommittedText {
            utf8: b"SHELL2-NORMALIZED".to_vec(),
        },
        NormalizedInputEvent::Key {
            hid_usage: 0x28,
            action: NormalizedKeyAction::Press,
            modifiers: 0,
            consumed_modifiers: 0,
            composing: false,
            unshifted_codepoint: 0,
            utf8: Vec::new(),
        },
        NormalizedInputEvent::Key {
            hid_usage: 0x28,
            action: NormalizedKeyAction::Release,
            modifiers: 0,
            consumed_modifiers: 0,
            composing: false,
            unshifted_codepoint: 0,
            utf8: Vec::new(),
        },
    ];
    let mut command_ids = HashMap::new();
    for (offset, event) in events.into_iter().enumerate() {
        let digest = normalized_input_event_digest_v1(&event);
        let id = client.send(normalized_command(
            client.generation,
            &second.id,
            &second_authority,
            offset as u64 + 1,
            event,
        ));
        command_ids.insert(id, (offset as u64 + 1, digest));
    }

    let expected_receipts = command_ids.len();
    let mut output = Vec::new();
    let mut exited = false;
    let deadline = Instant::now() + Duration::from_secs(3);
    while !command_ids.is_empty()
        || !output
            .windows(b"<SHELL2:SHELL2-NORMALIZED>".len())
            .any(|window| window == b"<SHELL2:SHELL2-NORMALIZED>")
        || !exited
    {
        assert!(
            Instant::now() < deadline,
            "Shell 2 did not execute committed text + HID Return: receipts={}/{expected_receipts}, output={output:?}, exited={exited}",
            expected_receipts - command_ids.len()
        );
        match client.read().body {
            ServerBodyV4::Reply {
                id,
                result:
                    ReplyV4::InputReceipt {
                        input_seq,
                        event_digest,
                        ..
                    },
            } => {
                let (expected_seq, expected_digest) = command_ids
                    .remove(&id)
                    .unwrap_or_else(|| panic!("unexpected input receipt id {id}"));
                assert_eq!(expected_seq, input_seq);
                assert_eq!(expected_digest, event_digest);
            }
            ServerBodyV4::StateEvent {
                terminal_id,
                event: WireStateEvent::PtyBytes { data, .. },
                ..
            } if terminal_id == second.id => output.extend(data),
            ServerBodyV4::Exited { terminal_id, .. } if terminal_id == second.id => exited = true,
            _ => {}
        }
    }
    assert_eq!(
        output
            .windows(b"<SHELL2:SHELL2-NORMALIZED>".len())
            .filter(|window| *window == b"<SHELL2:SHELL2-NORMALIZED>")
            .count(),
        1,
        "Shell 2 command was executed more than once"
    );
}

#[cfg(feature = "ghostty-engine")]
#[test]
fn normalized_pointer_receipt_atomically_routes_local_pty_and_geometry() {
    let broker = GhosttyBrokerProcess::start();
    let mut client = Client::connect(&broker.socket);
    let terminal = client.create("sleep 5");
    let prepared = client.prepare(&terminal.id);
    let authority = client.commit(&terminal.id, &prepared);
    let generation = client.generation;
    assert!(client
        .capabilities
        .iter()
        .any(|capability| capability == CAPABILITY_POINTER_DISPOSITION_V1));

    let geometry = NormalizedInputEvent::MouseGeometry {
        layout_epoch: 0,
        geometry: NormalizedMouseGeometry {
            screen_width_q8: 900 * 256,
            screen_height_q8: 600 * 256,
            cell_width_q8: 9 * 256,
            cell_height_q8: 19 * 256,
            padding_top_q8: 10 * 256,
            padding_bottom_q8: 10 * 256,
            padding_right_q8: 10 * 256,
            padding_left_q8: 10 * 256,
        },
    };
    let geometry_digest = normalized_input_event_digest_v1(&geometry);
    let geometry_receipt = client.request(normalized_command(
        generation,
        &terminal.id,
        &authority,
        1,
        geometry,
    ));
    assert_pointer_receipt(
        geometry_receipt,
        &terminal.id,
        &authority,
        1,
        &geometry_digest,
        None,
    );

    let pointer = NormalizedInputEvent::Mouse {
        gesture_id: 1,
        layout_epoch: 0,
        action: NormalizedMouseAction::Press,
        button: NormalizedMouseButton::Left,
        modifiers: 0,
        x_q8: 10 * 256,
        y_q8: 10 * 256,
    };
    let pointer_digest = normalized_input_event_digest_v1(&pointer);
    let pointer_receipt = client.request(normalized_command(
        generation,
        &terminal.id,
        &authority,
        2,
        pointer.clone(),
    ));
    assert_pointer_receipt(
        pointer_receipt,
        &terminal.id,
        &authority,
        2,
        &pointer_digest,
        Some(PointerDisposition::LocalSelection),
    );
    let duplicate = client.request(normalized_command(
        generation,
        &terminal.id,
        &authority,
        2,
        pointer,
    ));
    assert_pointer_receipt(
        duplicate,
        &terminal.id,
        &authority,
        2,
        &pointer_digest,
        Some(PointerDisposition::LocalSelection),
    );

    let scroll = NormalizedInputEvent::Scroll {
        gesture_id: 2,
        layout_epoch: 0,
        direction: NormalizedScrollDirection::Up,
        modifiers: 0,
        x_q8: 10 * 256,
        y_q8: 10 * 256,
    };
    let scroll_digest = normalized_input_event_digest_v1(&scroll);
    let scroll_receipt = client.request(normalized_command(
        generation,
        &terminal.id,
        &authority,
        3,
        scroll,
    ));
    assert_pointer_receipt(
        scroll_receipt,
        &terminal.id,
        &authority,
        3,
        &scroll_digest,
        Some(PointerDisposition::LocalScrollback),
    );

    let focus = NormalizedInputEvent::Focus { focused: true };
    let digest = normalized_input_event_digest_v1(&focus);
    let accepted = client.request(normalized_command(
        generation,
        &terminal.id,
        &authority,
        4,
        focus,
    ));
    assert_input_receipt(accepted, &terminal.id, &authority, 4, &digest);

    let local_release = NormalizedInputEvent::Mouse {
        gesture_id: 1,
        layout_epoch: 0,
        action: NormalizedMouseAction::Release,
        button: NormalizedMouseButton::Left,
        modifiers: 0,
        x_q8: 10 * 256,
        y_q8: 10 * 256,
    };
    let local_release_digest = normalized_input_event_digest_v1(&local_release);
    let local_release_receipt = client.request(normalized_command(
        generation,
        &terminal.id,
        &authority,
        5,
        local_release,
    ));
    assert_pointer_receipt(
        local_release_receipt,
        &terminal.id,
        &authority,
        5,
        &local_release_digest,
        Some(PointerDisposition::LocalSelection),
    );

    let resized = client.request(CommandV4::Resize {
        terminal_id: terminal.id.clone(),
        broker_generation: generation,
        input_epoch: authority.input_epoch,
        lease_id: authority.lease_id.clone(),
        columns: 90,
        rows: 30,
        cell_width_px: 9,
        cell_height_px: 19,
        layout_epoch: 1,
    });
    assert!(matches!(
        resized.body,
        ServerBodyV4::Reply {
            result: ReplyV4::Accepted,
            ..
        }
    ));
    let stale_scroll = NormalizedInputEvent::Scroll {
        gesture_id: 3,
        layout_epoch: 0,
        direction: NormalizedScrollDirection::Up,
        modifiers: 0,
        x_q8: 10 * 256,
        y_q8: 10 * 256,
    };
    let stale = client.request(normalized_command(
        generation,
        &terminal.id,
        &authority,
        6,
        stale_scroll,
    ));
    assert_error(stale, ErrorCode::BadRequest);

    let resized_geometry = NormalizedInputEvent::MouseGeometry {
        layout_epoch: 1,
        geometry: NormalizedMouseGeometry {
            screen_width_q8: 900 * 256,
            screen_height_q8: 600 * 256,
            cell_width_q8: 9 * 256,
            cell_height_q8: 19 * 256,
            padding_top_q8: 10 * 256,
            padding_bottom_q8: 10 * 256,
            padding_right_q8: 10 * 256,
            padding_left_q8: 10 * 256,
        },
    };
    let resized_geometry_digest = normalized_input_event_digest_v1(&resized_geometry);
    let resized_geometry_receipt = client.request(normalized_command(
        generation,
        &terminal.id,
        &authority,
        6,
        resized_geometry,
    ));
    assert_pointer_receipt(
        resized_geometry_receipt,
        &terminal.id,
        &authority,
        6,
        &resized_geometry_digest,
        None,
    );

    let mouse_terminal = client.create("printf '\\033[?1000h'; sleep 5");
    thread::sleep(Duration::from_millis(40));
    let mouse_prepared = client.prepare(&mouse_terminal.id);
    let mouse_authority = client.commit(&mouse_terminal.id, &mouse_prepared);
    let mouse_geometry = NormalizedInputEvent::MouseGeometry {
        layout_epoch: 0,
        geometry: NormalizedMouseGeometry {
            screen_width_q8: 900 * 256,
            screen_height_q8: 600 * 256,
            cell_width_q8: 9 * 256,
            cell_height_q8: 19 * 256,
            padding_top_q8: 10 * 256,
            padding_bottom_q8: 10 * 256,
            padding_right_q8: 10 * 256,
            padding_left_q8: 10 * 256,
        },
    };
    let mouse_geometry_digest = normalized_input_event_digest_v1(&mouse_geometry);
    let mouse_geometry_receipt = client.request(normalized_command(
        generation,
        &mouse_terminal.id,
        &mouse_authority,
        1,
        mouse_geometry,
    ));
    assert_pointer_receipt(
        mouse_geometry_receipt,
        &mouse_terminal.id,
        &mouse_authority,
        1,
        &mouse_geometry_digest,
        None,
    );
    let pty_pointer = NormalizedInputEvent::Mouse {
        gesture_id: 10,
        layout_epoch: 0,
        action: NormalizedMouseAction::Press,
        button: NormalizedMouseButton::Left,
        modifiers: 0,
        x_q8: 10 * 256,
        y_q8: 10 * 256,
    };
    let pty_digest = normalized_input_event_digest_v1(&pty_pointer);
    let pty_receipt = client.request(normalized_command(
        generation,
        &mouse_terminal.id,
        &mouse_authority,
        2,
        pty_pointer,
    ));
    assert_pointer_receipt(
        pty_receipt,
        &mouse_terminal.id,
        &mouse_authority,
        2,
        &pty_digest,
        Some(PointerDisposition::Pty),
    );
    let resize_during_press = client.request(CommandV4::Resize {
        terminal_id: mouse_terminal.id.clone(),
        broker_generation: generation,
        input_epoch: mouse_authority.input_epoch,
        lease_id: mouse_authority.lease_id.clone(),
        columns: 81,
        rows: 24,
        cell_width_px: 9,
        cell_height_px: 19,
        layout_epoch: 1,
    });
    assert_error(resize_during_press, ErrorCode::BadRequest);
    // The release keeps the route latched even though Shift changes after the
    // PTY-routed press. This prevents a remote application from seeing a press
    // without its matching release.
    let pty_release = NormalizedInputEvent::Mouse {
        gesture_id: 10,
        layout_epoch: 0,
        action: NormalizedMouseAction::Release,
        button: NormalizedMouseButton::Left,
        modifiers: 1,
        x_q8: 10 * 256,
        y_q8: 10 * 256,
    };
    let release_digest = normalized_input_event_digest_v1(&pty_release);
    let release_receipt = client.request(normalized_command(
        generation,
        &mouse_terminal.id,
        &mouse_authority,
        3,
        pty_release,
    ));
    assert_pointer_receipt(
        release_receipt,
        &mouse_terminal.id,
        &mouse_authority,
        3,
        &release_digest,
        Some(PointerDisposition::Pty),
    );

    let shifted = NormalizedInputEvent::Mouse {
        gesture_id: 11,
        layout_epoch: 0,
        action: NormalizedMouseAction::Press,
        button: NormalizedMouseButton::Left,
        modifiers: 1,
        x_q8: 10 * 256,
        y_q8: 10 * 256,
    };
    let shifted_digest = normalized_input_event_digest_v1(&shifted);
    let shifted_receipt = client.request(normalized_command(
        generation,
        &mouse_terminal.id,
        &mouse_authority,
        4,
        shifted,
    ));
    assert_pointer_receipt(
        shifted_receipt,
        &mouse_terminal.id,
        &mouse_authority,
        4,
        &shifted_digest,
        Some(PointerDisposition::LocalSelection),
    );
}

#[cfg(feature = "ghostty-engine")]
fn pointer_lifetime_event(action: NormalizedMouseAction) -> NormalizedInputEvent {
    NormalizedInputEvent::Mouse {
        gesture_id: 91,
        layout_epoch: 0,
        action,
        button: NormalizedMouseButton::Left,
        modifiers: 0,
        x_q8: 12 * 256,
        y_q8: 8 * 256,
    }
}

#[cfg(feature = "ghostty-engine")]
fn wait_for_pointer_action(
    state: &Arc<Mutex<PointerLifetimeState>>,
    action: NormalizedMouseAction,
) {
    let deadline = Instant::now() + Duration::from_secs(2);
    while !state
        .lock()
        .unwrap()
        .encoded
        .iter()
        .any(|(encoded, _)| *encoded == action)
    {
        assert!(Instant::now() < deadline, "pointer action was not encoded");
        thread::sleep(Duration::from_millis(5));
    }
}

#[cfg(feature = "ghostty-engine")]
#[test]
fn detach_enqueues_matching_pointer_cancel_before_revoking_the_lease() {
    let state = Arc::new(Mutex::new(PointerLifetimeState::default()));
    let broker = BrokerThread::start_with_live_engine(Arc::new(PointerLifetimeFactory {
        state: Arc::clone(&state),
        fail_initial_feed: false,
    }));
    let mut client = Client::connect(&broker.socket);
    let terminal = client.create("stty -echo; exec /bin/cat");
    let prepared = client.prepare(&terminal.id);
    let authority = client.commit(&terminal.id, &prepared);
    let press = pointer_lifetime_event(NormalizedMouseAction::Press);
    let digest = normalized_input_event_digest_v1(&press);
    let receipt = client.request(normalized_command(
        client.generation,
        &terminal.id,
        &authority,
        1,
        press,
    ));
    assert_pointer_receipt(
        receipt,
        &terminal.id,
        &authority,
        1,
        &digest,
        Some(PointerDisposition::Pty),
    );

    client.detach(&terminal.id, &authority);
    wait_for_pointer_action(&state, NormalizedMouseAction::Cancel);
    assert_eq!(
        state.lock().unwrap().encoded,
        vec![
            (NormalizedMouseAction::Press, b'A'),
            (NormalizedMouseAction::Cancel, b'A')
        ]
    );
}

#[cfg(feature = "ghostty-engine")]
#[test]
fn cross_connection_takeover_cancels_old_pointer_without_stale_detach_touching_new_owner() {
    let state = Arc::new(Mutex::new(PointerLifetimeState::default()));
    let broker = BrokerThread::start_with_live_engine(Arc::new(PointerLifetimeFactory {
        state: Arc::clone(&state),
        fail_initial_feed: false,
    }));
    let mut first = Client::connect(&broker.socket);
    let terminal = first.create("stty -echo -isig; sleep 30");
    thread::sleep(Duration::from_millis(40));
    let first_prepared = first.prepare(&terminal.id);
    let first_authority = first.commit(&terminal.id, &first_prepared);
    let first_press = pointer_lifetime_event(NormalizedMouseAction::Press);
    let first_digest = normalized_input_event_digest_v1(&first_press);
    assert_pointer_receipt(
        first.request(normalized_command(
            first.generation,
            &terminal.id,
            &first_authority,
            1,
            first_press,
        )),
        &terminal.id,
        &first_authority,
        1,
        &first_digest,
        Some(PointerDisposition::Pty),
    );

    let mut second = Client::connect(&broker.socket);
    let second_prepared = second.prepare(&terminal.id);
    wait_for_pointer_action(&state, NormalizedMouseAction::Cancel);
    let second_authority = second.commit(&terminal.id, &second_prepared);
    let second_press = pointer_lifetime_event(NormalizedMouseAction::Press);
    let second_digest = normalized_input_event_digest_v1(&second_press);
    assert_pointer_receipt(
        second.request(normalized_command(
            second.generation,
            &terminal.id,
            &second_authority,
            1,
            second_press,
        )),
        &terminal.id,
        &second_authority,
        1,
        &second_digest,
        Some(PointerDisposition::Pty),
    );

    let before_stale_detach = state.lock().unwrap().encoded.clone();
    assert_eq!(
        before_stale_detach,
        vec![
            (NormalizedMouseAction::Press, b'A'),
            (NormalizedMouseAction::Cancel, b'A'),
            (NormalizedMouseAction::Press, b'A'),
        ]
    );
    first.detach(&terminal.id, &first_authority);
    assert_eq!(state.lock().unwrap().encoded, before_stale_detach);
}

#[cfg(feature = "ghostty-engine")]
#[test]
fn transport_loss_enqueues_matching_pointer_cancel() {
    let state = Arc::new(Mutex::new(PointerLifetimeState::default()));
    let broker = BrokerThread::start_with_live_engine(Arc::new(PointerLifetimeFactory {
        state: Arc::clone(&state),
        fail_initial_feed: false,
    }));
    let mut client = Client::connect(&broker.socket);
    let terminal = client.create("stty -echo; exec /bin/cat");
    let prepared = client.prepare(&terminal.id);
    let authority = client.commit(&terminal.id, &prepared);
    let press = pointer_lifetime_event(NormalizedMouseAction::Press);
    let receipt = client.request(normalized_command(
        client.generation,
        &terminal.id,
        &authority,
        1,
        press.clone(),
    ));
    assert_pointer_receipt(
        receipt,
        &terminal.id,
        &authority,
        1,
        &normalized_input_event_digest_v1(&press),
        Some(PointerDisposition::Pty),
    );

    drop(client);
    wait_for_pointer_action(&state, NormalizedMouseAction::Cancel);
    assert_eq!(
        state.lock().unwrap().encoded.last(),
        Some(&(NormalizedMouseAction::Cancel, b'A'))
    );
}

#[cfg(feature = "ghostty-engine")]
#[test]
fn live_engine_restore_cancels_pointer_before_replacing_input_sidecar() {
    let state = Arc::new(Mutex::new(PointerLifetimeState::default()));
    let broker = BrokerThread::start_with_live_engine(Arc::new(PointerLifetimeFactory {
        state: Arc::clone(&state),
        fail_initial_feed: true,
    }));
    let mut client = Client::connect(&broker.socket);
    let terminal = client.create("stty -echo; read ignored; printf RESTORE; sleep 5");
    let prepared = client.prepare(&terminal.id);
    let authority = client.commit(&terminal.id, &prepared);
    let press = pointer_lifetime_event(NormalizedMouseAction::Press);
    let _ = client.request(normalized_command(
        client.generation,
        &terminal.id,
        &authority,
        1,
        press,
    ));

    wait_for_pointer_action(&state, NormalizedMouseAction::Cancel);
    let deadline = Instant::now() + Duration::from_secs(2);
    while state.lock().unwrap().restores == 0 {
        assert!(Instant::now() < deadline, "live engine was not restored");
        thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(
        state.lock().unwrap().encoded,
        vec![
            (NormalizedMouseAction::Press, b'A'),
            (NormalizedMouseAction::Cancel, b'A')
        ]
    );
}

#[cfg(feature = "ghostty-engine")]
#[test]
fn release_uses_press_time_protocol_after_child_changes_mouse_mode() {
    let state = Arc::new(Mutex::new(PointerLifetimeState::default()));
    let broker = BrokerThread::start_with_live_engine(Arc::new(PointerLifetimeFactory {
        state: Arc::clone(&state),
        fail_initial_feed: false,
    }));
    let mut client = Client::connect(&broker.socket);
    let terminal = client.create("stty -echo; read ignored; printf MODE-B; sleep 5");
    let prepared = client.prepare(&terminal.id);
    let authority = client.commit(&terminal.id, &prepared);
    let press = pointer_lifetime_event(NormalizedMouseAction::Press);
    let _ = client.request(normalized_command(
        client.generation,
        &terminal.id,
        &authority,
        1,
        press,
    ));
    let deadline = Instant::now() + Duration::from_secs(2);
    while state.lock().unwrap().protocol != b'B' {
        assert!(
            Instant::now() < deadline,
            "child did not change pointer protocol"
        );
        thread::sleep(Duration::from_millis(5));
    }

    let release = pointer_lifetime_event(NormalizedMouseAction::Release);
    let digest = normalized_input_event_digest_v1(&release);
    let receipt = client.request(normalized_command(
        client.generation,
        &terminal.id,
        &authority,
        2,
        release,
    ));
    assert_pointer_receipt(
        receipt,
        &terminal.id,
        &authority,
        2,
        &digest,
        Some(PointerDisposition::Pty),
    );
    assert_eq!(
        state.lock().unwrap().encoded.last(),
        Some(&(NormalizedMouseAction::Release, b'A'))
    );
}

#[cfg(feature = "ghostty-engine")]
#[test]
fn normalized_input_detach_is_fifo_and_old_epoch_fails_closed_after_reattach() {
    let broker = GhosttyBrokerProcess::start();
    let mut client = Client::connect(&broker.socket);
    let terminal = client.create("stty -echo; exec /bin/cat");
    thread::sleep(Duration::from_millis(40));
    let prepared = client.prepare(&terminal.id);
    let authority = client.commit(&terminal.id, &prepared);
    let event = NormalizedInputEvent::Paste {
        utf8: b"DETACH-BARRIER\n".to_vec(),
    };
    let digest = normalized_input_event_digest_v1(&event);
    let input_id = client.send(normalized_command(
        client.generation,
        &terminal.id,
        &authority,
        1,
        event,
    ));
    let detach_id = client.send(CommandV4::Detach {
        terminal_id: terminal.id.clone(),
        broker_generation: client.generation,
        input_epoch: authority.input_epoch,
        lease_id: authority.lease_id.clone(),
    });
    let mut saw_receipt = false;
    loop {
        match client.read().body {
            ServerBodyV4::Reply {
                id,
                result:
                    ReplyV4::InputReceipt {
                        input_seq: 1,
                        event_digest,
                        ..
                    },
            } if id == input_id => {
                assert_eq!(event_digest, digest);
                saw_receipt = true;
            }
            ServerBodyV4::Reply {
                id,
                result: ReplyV4::Detached { .. },
            } if id == detach_id => {
                assert!(saw_receipt, "detach crossed its pending input receipt");
                break;
            }
            _ => {}
        }
    }

    let replacement_prepare = client.prepare(&terminal.id);
    let replacement = client.commit(&terminal.id, &replacement_prepare);
    assert_ne!(replacement.input_epoch, authority.input_epoch);
    let stale = client.request(normalized_command(
        client.generation,
        &terminal.id,
        &authority,
        2,
        NormalizedInputEvent::Focus { focused: true },
    ));
    assert_error(stale, ErrorCode::StaleLease);

    let first_new_event = NormalizedInputEvent::Focus { focused: true };
    let first_new_digest = normalized_input_event_digest_v1(&first_new_event);
    let accepted = client.request(normalized_command(
        client.generation,
        &terminal.id,
        &replacement,
        1,
        first_new_event,
    ));
    assert_input_receipt(accepted, &terminal.id, &replacement, 1, &first_new_digest);
}

#[cfg(feature = "ghostty-engine")]
#[test]
fn normalized_input_queue_full_does_not_consume_sequence_and_retry_succeeds() {
    let broker = BrokerThread::start_with_ghostty_input_queue(8, 1);
    let mut client = Client::connect(&broker.socket);
    let terminal = client.create("stty -echo; exec /bin/cat");
    thread::sleep(Duration::from_millis(40));
    let prepared = client.prepare(&terminal.id);
    let authority = client.commit(&terminal.id, &prepared);
    let first_event = NormalizedInputEvent::CommittedText {
        utf8: b"12345678".to_vec(),
    };
    let second_event = NormalizedInputEvent::CommittedText {
        utf8: b"XY".to_vec(),
    };
    let second_digest = normalized_input_event_digest_v1(&second_event);
    let generation = client.generation;
    let first_id = client.send(normalized_command(
        generation,
        &terminal.id,
        &authority,
        1,
        first_event,
    ));
    let full_id = client.send(normalized_command(
        generation,
        &terminal.id,
        &authority,
        2,
        second_event.clone(),
    ));
    let mut first_accepted = false;
    let mut queue_full = false;
    while !first_accepted || !queue_full {
        match client.read().body {
            ServerBodyV4::Reply {
                id,
                result: ReplyV4::InputReceipt { input_seq: 1, .. },
            } if id == first_id => first_accepted = true,
            ServerBodyV4::Error {
                id,
                code: ErrorCode::QueueFull,
                ..
            } if id == full_id => queue_full = true,
            _ => {}
        }
    }

    thread::sleep(Duration::from_millis(100));
    let retry = client.request(normalized_command(
        generation,
        &terminal.id,
        &authority,
        2,
        second_event,
    ));
    assert_input_receipt(retry, &terminal.id, &authority, 2, &second_digest);
}

#[test]
fn terminal_summary_checkpoint_telemetry_is_an_additive_wire_contract() {
    let legacy = serde_json::json!({
        "id": "term-legacy",
        "create_nonce": "legacy-nonce",
        "cursor": 7,
        "columns": 80,
        "rows": 24,
        "layout_epoch": 3,
        "running": true,
        "foreground_process": false
    });
    let summary: TerminalSummary = serde_json::from_value(legacy).unwrap();
    assert_eq!(
        summary.checkpoint_state,
        ouro_broker::CheckpointStateV4::Evicted
    );
    assert_eq!(summary.checkpoint_bytes, 0);
    assert_eq!(summary.recovery_paused_ms, None);
    assert!(!summary.checkpoint_protected);

    let encoded = serde_json::to_value(summary).unwrap();
    assert_eq!(encoded["checkpoint_state"], "evicted");
    assert_eq!(encoded["checkpoint_bytes"], 0);
    assert_eq!(encoded["recovery_tail_bytes"], 0);
    assert_eq!(encoded["checkpoint_evictions"], 0);
    assert_eq!(encoded["checkpoint_rebuilds"], 0);
    assert_eq!(encoded["recovery_pause_count"], 0);
    assert_eq!(encoded["checkpoint_protected"], false);
    assert!(encoded.get("recovery_paused_ms").is_none());
}

#[test]
fn prepare_is_chunked_manifest_bound_and_grants_no_early_input_authority() {
    let broker = BrokerProcess::start();
    let mut client = Client::connect(&broker.socket);
    let terminal = client.create("printf '\\x1b[31mhello-세계\\x1b[0m'; sleep 5");
    let prepared = client.prepare(&terminal.id);
    assert!(!prepared.checkpoint.is_empty());

    let early = client.request(CommandV4::Input {
        terminal_id: terminal.id,
        broker_generation: client.generation,
        input_epoch: 0,
        lease_id: String::new(),
        data: b"forbidden".to_vec(),
    });
    assert_error(early, ErrorCode::StaleLease);
}

#[test]
fn conflicting_commit_fails_closed_and_releases_the_client_recovery_slot() {
    let broker = BrokerProcess::start();
    let mut client = Client::connect(&broker.socket);
    let terminal = client.create("sleep 5");
    let prepared = client.prepare(&terminal.id);
    let failed = client.request(CommandV4::RecoveryCommit {
        recovery_id: prepared.recovery_id,
        terminal_id: terminal.id.clone(),
        broker_generation: client.generation,
        cutover_state_seq: prepared.cutover_state_seq,
        digest: "sha256:wrong".into(),
    });
    assert_error(failed, ErrorCode::ResyncRequired);
    let replacement = client.prepare(&terminal.id);
    assert!(!replacement.recovery_id.is_empty());
}

#[test]
fn commit_catches_up_ordered_output_then_enables_typed_live_resize() {
    let broker = BrokerProcess::start();
    let mut client = Client::connect(&broker.socket);
    let terminal = client.create("printf before; sleep 0.2; printf after; sleep 5");
    let prepared = client.prepare(&terminal.id);
    thread::sleep(Duration::from_millis(350));
    let commit_id = client.send(CommandV4::RecoveryCommit {
        recovery_id: prepared.recovery_id.clone(),
        terminal_id: terminal.id.clone(),
        broker_generation: client.generation,
        cutover_state_seq: prepared.cutover_state_seq,
        digest: prepared.digest,
    });
    let mut last_seq = prepared.cutover_state_seq;
    let authority = loop {
        match client.read().body {
            ServerBodyV4::RecoveryDelta { recovery_id, event } => {
                assert_eq!(recovery_id, prepared.recovery_id);
                let seq = match event {
                    WireStateEvent::PtyBytes { state_seq, .. }
                    | WireStateEvent::Resize { state_seq, .. }
                    | WireStateEvent::HistoryTrim { state_seq, .. }
                    | WireStateEvent::CanonicalCheckpoint { state_seq, .. } => state_seq,
                };
                assert_eq!(seq, last_seq + 1);
                last_seq = seq;
            }
            ServerBodyV4::Reply {
                id,
                result:
                    ReplyV4::AttachedReady {
                        state_seq,
                        input_epoch,
                        lease_id,
                        ..
                    },
            } => {
                assert_eq!(id, commit_id);
                assert_eq!(state_seq, last_seq);
                break (input_epoch, lease_id);
            }
            other => panic!("unexpected commit message: {other:?}"),
        }
    };

    let resize_id = client.send(CommandV4::Resize {
        terminal_id: terminal.id.clone(),
        broker_generation: client.generation,
        input_epoch: authority.0,
        lease_id: authority.1,
        columns: 100,
        rows: 32,
        cell_width_px: 9,
        cell_height_px: 18,
        layout_epoch: 4,
    });
    let mut saw_resize = false;
    loop {
        match client.read().body {
            ServerBodyV4::StateEvent {
                event:
                    WireStateEvent::Resize {
                        state_seq,
                        columns,
                        rows,
                        layout_epoch,
                        ..
                    },
                ..
            } => {
                assert_eq!(state_seq, last_seq + 1);
                assert_eq!((columns, rows, layout_epoch), (100, 32, 4));
                saw_resize = true;
            }
            ServerBodyV4::Reply {
                id,
                result: ReplyV4::Accepted,
            } if id == resize_id => break,
            _ => {}
        }
    }
    assert!(saw_resize);
}

#[test]
fn one_recovery_per_client_is_enforced() {
    let broker = BrokerProcess::start();
    let mut client = Client::connect(&broker.socket);
    let first = client.create("sleep 5");
    let second = client.create("sleep 5");
    let _prepared = client.prepare(&first.id);
    let rejected = client.request(CommandV4::AttachPrepare {
        terminal_id: second.id,
        broker_generation: client.generation,
        after_state_seq: None,
    });
    assert_error(rejected, ErrorCode::LimitReached);
}

#[test]
fn four_global_recoveries_are_bounded_and_disconnect_releases_a_pin() {
    let broker = BrokerProcess::start();
    let mut owner = Client::connect(&broker.socket);
    let terminal = owner.create("sleep 5");
    let mut holders = Vec::new();
    for _ in 0..4 {
        let mut client = Client::connect(&broker.socket);
        let _prepared = client.prepare(&terminal.id);
        holders.push(client);
    }
    let mut waiting = Client::connect(&broker.socket);
    let rejected = waiting.request(CommandV4::AttachPrepare {
        terminal_id: terminal.id.clone(),
        broker_generation: waiting.generation,
        after_state_seq: None,
    });
    assert_error(rejected, ErrorCode::LimitReached);

    drop(holders.pop());
    thread::sleep(Duration::from_millis(50));
    let replacement = waiting.prepare(&terminal.id);
    assert!(!replacement.recovery_id.is_empty());
}

#[test]
fn expired_recovery_rejects_commit_and_releases_its_pin() {
    let broker = BrokerThread::start(Duration::from_millis(20), 16 * 1024 * 1024);
    let mut client = Client::connect(&broker.socket);
    let terminal = client.create("sleep 5");
    let prepared = client.prepare(&terminal.id);
    thread::sleep(Duration::from_millis(50));
    let expired = client.request(CommandV4::RecoveryCommit {
        recovery_id: prepared.recovery_id,
        terminal_id: terminal.id.clone(),
        broker_generation: client.generation,
        cutover_state_seq: prepared.cutover_state_seq,
        digest: prepared.digest,
    });
    assert_error(expired, ErrorCode::ResyncRequired);
    let replacement = client.prepare(&terminal.id);
    assert!(!replacement.recovery_id.is_empty());
}

#[test]
fn checkpoint_is_rejected_before_pinning_past_the_global_byte_budget() {
    let broker = BrokerThread::start(Duration::from_secs(5), 1);
    let mut client = Client::connect(&broker.socket);
    let terminal = client.create("printf checkpoint; sleep 5");
    thread::sleep(Duration::from_millis(30));
    let rejected = client.request(CommandV4::AttachPrepare {
        terminal_id: terminal.id,
        broker_generation: client.generation,
        after_state_seq: None,
    });
    assert_error(rejected, ErrorCode::LimitReached);
}

#[test]
fn rapid_connect_close_rejects_dead_admissions_without_stopping_the_reactor() {
    let broker = BrokerThread::start(Duration::from_secs(5), 16 * 1024 * 1024);
    let mut hammers = Vec::new();
    for _ in 0..4 {
        let socket = broker.socket.clone();
        hammers.push(thread::spawn(move || {
            for _ in 0..250 {
                drop(UnixStream::connect(&socket));
            }
        }));
    }
    for hammer in hammers {
        hammer.join().unwrap();
    }

    let mut live = Client::connect(&broker.socket);
    let terminals = live.request(CommandV4::List);
    assert!(matches!(
        terminals.body,
        ServerBodyV4::Reply {
            result: ReplyV4::Listed { .. },
            ..
        }
    ));
}

#[test]
fn prepare_revokes_old_lease_and_suspends_live_events_on_the_same_connection() {
    let broker = BrokerProcess::start();
    let mut client = Client::connect(&broker.socket);
    let terminal = client.create(
        "sleep 0.15; i=0; while [ $i -lt 40 ]; do printf noisy; i=$((i+1)); sleep 0.01; done; sleep 5",
    );
    let first = client.prepare(&terminal.id);
    let old = client.commit(&terminal.id, &first);

    let suspended = client.prepare(&terminal.id);
    thread::sleep(Duration::from_millis(250));
    let stale_input = client.request_without_live_events(CommandV4::Input {
        terminal_id: terminal.id.clone(),
        broker_generation: client.generation,
        input_epoch: old.input_epoch,
        lease_id: old.lease_id.clone(),
        data: b"must-not-run".to_vec(),
    });
    assert_error(stale_input, ErrorCode::StaleLease);
    let stale_resize = client.request_without_live_events(CommandV4::Resize {
        terminal_id: terminal.id.clone(),
        broker_generation: client.generation,
        input_epoch: old.input_epoch,
        lease_id: old.lease_id.clone(),
        columns: 90,
        rows: 30,
        cell_width_px: 9,
        cell_height_px: 18,
        layout_epoch: 2,
    });
    assert_error(stale_resize, ErrorCode::StaleLease);
    let stale_detach = client.request_without_live_events(CommandV4::Detach {
        terminal_id: terminal.id.clone(),
        broker_generation: client.generation,
        input_epoch: old.input_epoch,
        lease_id: old.lease_id,
    });
    assert_error(stale_detach, ErrorCode::StaleLease);

    let aborted = client.request(CommandV4::RecoveryAbort {
        recovery_id: suspended.recovery_id,
        terminal_id: terminal.id,
        broker_generation: client.generation,
    });
    assert!(matches!(
        aborted.body,
        ServerBodyV4::Reply {
            result: ReplyV4::Accepted,
            ..
        }
    ));
}

#[test]
fn detach_is_a_non_destructive_ordering_barrier_and_reattach_recovers_headless_output() {
    let broker = BrokerProcess::start();
    let mut client = Client::connect(&broker.socket);
    let terminal = client
        .create("read ignored; printf before-detach; sleep 0.6; printf after-detach; sleep 5");
    let prepared = client.prepare(&terminal.id);
    let authority = client.commit(&terminal.id, &prepared);

    let trigger = client.request(CommandV4::Input {
        terminal_id: terminal.id.clone(),
        broker_generation: client.generation,
        input_epoch: authority.input_epoch,
        lease_id: authority.lease_id.clone(),
        data: b"go\n".to_vec(),
    });
    assert!(matches!(
        trigger.body,
        ServerBodyV4::Reply {
            result: ReplyV4::Accepted,
            ..
        }
    ));
    thread::sleep(Duration::from_millis(100));
    let detach_id = client.send(CommandV4::Detach {
        terminal_id: terminal.id.clone(),
        broker_generation: client.generation,
        input_epoch: authority.input_epoch,
        lease_id: authority.lease_id.clone(),
    });
    let mut last_event_seq = None;
    let detached_state_seq = loop {
        match client.read().body {
            ServerBodyV4::StateEvent { terminal_id, event } => {
                assert_eq!(terminal_id, terminal.id);
                last_event_seq = Some(match event {
                    WireStateEvent::PtyBytes { state_seq, .. }
                    | WireStateEvent::Resize { state_seq, .. }
                    | WireStateEvent::HistoryTrim { state_seq, .. }
                    | WireStateEvent::CanonicalCheckpoint { state_seq, .. } => state_seq,
                });
            }
            ServerBodyV4::Reply {
                id,
                result:
                    ReplyV4::Detached {
                        terminal_id,
                        state_seq,
                    },
            } if id == detach_id => {
                assert_eq!(terminal_id, terminal.id);
                break state_seq;
            }
            other => panic!("unexpected detach barrier message: {other:?}"),
        }
    };
    assert_eq!(last_event_seq, Some(detached_state_seq));

    // The shell and broker-owned canonical state continue while no client is
    // subscribed. A later list reply must not be preceded by the headless
    // output as a late event for the detached attachment.
    thread::sleep(Duration::from_millis(1_100));
    let list_id = client.send(CommandV4::List);
    let listed = client.read();
    match listed.body {
        ServerBodyV4::Reply {
            id,
            result: ReplyV4::Listed { terminals },
        } if id == list_id => {
            let summary = terminals
                .iter()
                .find(|summary| summary.terminal.id == terminal.id)
                .expect("detached terminal remains broker-owned");
            assert!(summary.terminal.running);
            assert!(summary.state_seq > detached_state_seq);
        }
        other => panic!("state event appeared after detached reply: {other:?}"),
    }

    let recovered = client.prepare(&terminal.id);
    assert!(recovered.cutover_state_seq > detached_state_seq);
    let replacement = client.commit(&terminal.id, &recovered);
    assert_ne!(replacement.lease_id, authority.lease_id);
}

#[test]
fn detach_fails_closed_for_generation_terminal_and_attachment_lease() {
    let broker = BrokerProcess::start();
    let mut client = Client::connect(&broker.socket);
    let terminal = client.create("cat >/dev/null");
    let prepared = client.prepare(&terminal.id);
    let authority = client.commit(&terminal.id, &prepared);

    let wrong_generation = client.request(CommandV4::Detach {
        terminal_id: terminal.id.clone(),
        broker_generation: client.generation.wrapping_add(1),
        input_epoch: authority.input_epoch,
        lease_id: authority.lease_id.clone(),
    });
    assert_error(wrong_generation, ErrorCode::StaleGeneration);
    let wrong_terminal = client.request(CommandV4::Detach {
        terminal_id: "term-does-not-match".into(),
        broker_generation: client.generation,
        input_epoch: authority.input_epoch,
        lease_id: authority.lease_id.clone(),
    });
    assert_error(wrong_terminal, ErrorCode::NotFound);
    let wrong_lease = client.request(CommandV4::Detach {
        terminal_id: terminal.id.clone(),
        broker_generation: client.generation,
        input_epoch: authority.input_epoch,
        lease_id: "not-the-attachment-lease".into(),
    });
    assert_error(wrong_lease, ErrorCode::StaleLease);

    let still_attached = client.request(CommandV4::Input {
        terminal_id: terminal.id.clone(),
        broker_generation: client.generation,
        input_epoch: authority.input_epoch,
        lease_id: authority.lease_id.clone(),
        data: b"still-authorized".to_vec(),
    });
    assert!(matches!(
        still_attached.body,
        ServerBodyV4::Reply {
            result: ReplyV4::Accepted,
            ..
        }
    ));
    client.detach(&terminal.id, &authority);

    let input_after_detach = client.request(CommandV4::Input {
        terminal_id: terminal.id.clone(),
        broker_generation: client.generation,
        input_epoch: authority.input_epoch,
        lease_id: authority.lease_id.clone(),
        data: b"must-not-run".to_vec(),
    });
    assert_error(input_after_detach, ErrorCode::StaleLease);
    let duplicate = client.request(CommandV4::Detach {
        terminal_id: terminal.id,
        broker_generation: client.generation,
        input_epoch: authority.input_epoch,
        lease_id: authority.lease_id,
    });
    assert_error(duplicate, ErrorCode::StaleLease);
}

#[test]
fn displaced_input_owner_can_detach_its_own_subscription_without_revoking_new_owner() {
    let broker = BrokerProcess::start();
    let mut first = Client::connect(&broker.socket);
    let terminal = first.create("cat >/dev/null");
    let first_recovery = first.prepare(&terminal.id);
    let first_authority = first.commit(&terminal.id, &first_recovery);

    let mut second = Client::connect(&broker.socket);
    let second_recovery = second.prepare(&terminal.id);
    let second_authority = second.commit(&terminal.id, &second_recovery);
    assert_ne!(first_authority.lease_id, second_authority.lease_id);

    first.detach(&terminal.id, &first_authority);
    let accepted = second.request(CommandV4::Input {
        terminal_id: terminal.id,
        broker_generation: second.generation,
        input_epoch: second_authority.input_epoch,
        lease_id: second_authority.lease_id,
        data: b"new-owner-retained".to_vec(),
    });
    assert!(matches!(
        accepted.body,
        ServerBodyV4::Reply {
            result: ReplyV4::Accepted,
            ..
        }
    ));
}

#[test]
fn import_failure_abort_is_idempotent_and_allows_a_fresh_prepare() {
    let broker = BrokerProcess::start();
    let mut client = Client::connect(&broker.socket);
    let terminal = client.create("sleep 5");
    let failed_import = client.prepare(&terminal.id);
    for _ in 0..2 {
        let aborted = client.request(CommandV4::RecoveryAbort {
            recovery_id: failed_import.recovery_id.clone(),
            terminal_id: terminal.id.clone(),
            broker_generation: client.generation,
        });
        assert!(matches!(
            aborted.body,
            ServerBodyV4::Reply {
                result: ReplyV4::Accepted,
                ..
            }
        ));
    }
    let retry = client.prepare(&terminal.id);
    assert_ne!(retry.recovery_id, failed_import.recovery_id);
}

#[test]
fn abort_wrong_client_terminal_or_generation_fails_closed_without_releasing_owner_pin() {
    let broker = BrokerProcess::start();
    let mut owner = Client::connect(&broker.socket);
    let terminal = owner.create("sleep 5");
    let prepared = owner.prepare(&terminal.id);
    let mut foreign = Client::connect(&broker.socket);

    let foreign_abort = foreign.request(CommandV4::RecoveryAbort {
        recovery_id: prepared.recovery_id.clone(),
        terminal_id: terminal.id.clone(),
        broker_generation: foreign.generation,
    });
    assert_error(foreign_abort, ErrorCode::ResyncRequired);
    let wrong_terminal = owner.request(CommandV4::RecoveryAbort {
        recovery_id: prepared.recovery_id.clone(),
        terminal_id: "term-does-not-match".into(),
        broker_generation: owner.generation,
    });
    assert_error(wrong_terminal, ErrorCode::ResyncRequired);
    let wrong_generation = owner.request(CommandV4::RecoveryAbort {
        recovery_id: prepared.recovery_id.clone(),
        terminal_id: terminal.id.clone(),
        broker_generation: owner.generation.wrapping_add(1),
    });
    assert_error(wrong_generation, ErrorCode::StaleGeneration);

    let owner_abort = owner.request(CommandV4::RecoveryAbort {
        recovery_id: prepared.recovery_id,
        terminal_id: terminal.id.clone(),
        broker_generation: owner.generation,
    });
    assert!(matches!(
        owner_abort.body,
        ServerBodyV4::Reply {
            result: ReplyV4::Accepted,
            ..
        }
    ));
    let replacement = owner.prepare(&terminal.id);
    assert!(!replacement.recovery_id.is_empty());
}
