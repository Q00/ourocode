//! Dedicated, length-prefixed session-message gateway reactor.
//!
//! This namespace never shares the terminal-control listener or `CommandV4`
//! parser. Mutation clients enter through either an inherited session socket
//! whose principal was durably registered by Ouroboros, or a signed desktop
//! admission whose registration activator proves that the separate privileged
//! registration descriptor has already acknowledged the binding. The latter
//! activator intentionally has no production implementation in this crate yet:
//! installer authority and reciprocal service verification remain fail-closed.

use crate::authority_registry::{
    AuthenticatedOuroborosService, AuthorityConnectionId, SessionBridgeRegistrationV1,
    SignedDesktopAuthorityV1, VerifiedDesktopPeer, VerifiedOuroborosServicePeer,
};
use crate::desktop_peer_verifier::{
    verify_accepted_desktop_peer, DesktopCodePolicy, DesktopPeerAdmission,
    DesktopPeerVerificationError, ExpectedDesktopPeer,
};
use crate::principal_binding_ack_wire::DurablyAcknowledgedPrincipalBindingV1;
use crate::session_message::{
    BoundedErrorMessage, ErrorResult, SessionMessageErrorCode, SessionMessageErrorV1, Timestamp,
    Version1, MAX_CLIENT_OUTPUT_QUEUE_BYTES, MAX_RECEIPT_BYTES, MAX_WIRE_FRAME_BYTES,
};
use crate::session_message_bridge_wire::{
    decode_reply, encode_dispatch, BridgeDispatchFrame, BridgeWireError,
};
use crate::session_message_transport::{
    AdapterReply, PendingRequestId, QueuedClientEgress, SessionMessageTransport, TransportError,
};
use std::collections::{HashMap, HashSet, VecDeque};
use std::fmt;
use std::fs;
use std::io;
use std::num::NonZeroU64;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, OwnedFd, RawFd};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::Duration;

const LENGTH_PREFIX_BYTES: usize = 4;
const MAX_PREPARED_REQUESTS: usize = 64;
const MAX_VERIFICATION_QUEUE: usize = 1;

#[derive(Clone, Debug)]
pub struct SessionMessageGatewayConfig {
    pub socket_path: PathBuf,
    pub broker_generation: NonZeroU64,
    pub max_clients: usize,
    pub max_accepts_per_tick: usize,
    pub max_client_read_bytes_per_tick: usize,
    pub max_client_frames_per_tick: usize,
    pub max_client_write_bytes_per_tick: usize,
    pub max_upstream_read_bytes_per_tick: usize,
    pub max_upstream_write_bytes_per_tick: usize,
}

impl SessionMessageGatewayConfig {
    pub fn new(socket_path: impl Into<PathBuf>, broker_generation: NonZeroU64) -> Self {
        Self {
            socket_path: socket_path.into(),
            broker_generation,
            max_clients: 64,
            max_accepts_per_tick: 8,
            max_client_read_bytes_per_tick: 64 * 1_024,
            max_client_frames_per_tick: 32,
            max_client_write_bytes_per_tick: 64 * 1_024,
            max_upstream_read_bytes_per_tick: 64 * 1_024,
            max_upstream_write_bytes_per_tick: 64 * 1_024,
        }
    }

    fn validate(&self) -> io::Result<()> {
        let limits = [
            self.max_clients,
            self.max_accepts_per_tick,
            self.max_client_read_bytes_per_tick,
            self.max_client_frames_per_tick,
            self.max_client_write_bytes_per_tick,
            self.max_upstream_read_bytes_per_tick,
            self.max_upstream_write_bytes_per_tick,
        ];
        if limits.contains(&0) || self.max_clients > 256 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid session-message gateway limit",
            ));
        }
        if !self.socket_path.is_absolute() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "session-message socket path must be absolute",
            ));
        }
        Ok(())
    }
}

pub trait DesktopAdmissionVerifier: Send + Sync + 'static {
    fn verify(
        &self,
        socket: BorrowedFd<'_>,
        connection_id: AuthorityConnectionId,
        broker_generation: NonZeroU64,
    ) -> Result<DesktopPeerAdmission, DesktopPeerVerificationError>;
}

pub struct SecurityFrameworkDesktopVerifier {
    expected: ExpectedDesktopPeer,
    policy: DesktopCodePolicy,
}

impl SecurityFrameworkDesktopVerifier {
    pub fn new(expected: ExpectedDesktopPeer, policy: DesktopCodePolicy) -> Self {
        Self { expected, policy }
    }
}

impl DesktopAdmissionVerifier for SecurityFrameworkDesktopVerifier {
    fn verify(
        &self,
        socket: BorrowedFd<'_>,
        connection_id: AuthorityConnectionId,
        broker_generation: NonZeroU64,
    ) -> Result<DesktopPeerAdmission, DesktopPeerVerificationError> {
        verify_accepted_desktop_peer(
            socket,
            connection_id,
            broker_generation,
            self.expected,
            &self.policy,
        )
    }
}

/// Opaque proof that the privileged registration descriptor durably
/// acknowledged this authority before local activation.
pub struct DurablyActivatedDesktopAuthority(SignedDesktopAuthorityV1);

impl DurablyActivatedDesktopAuthority {
    #[allow(dead_code)] // Production caller lands with installer/service verification.
    pub(crate) fn from_acknowledged(
        authority: SignedDesktopAuthorityV1,
        acknowledgement: DurablyAcknowledgedPrincipalBindingV1,
        broker_generation: NonZeroU64,
    ) -> Option<Self> {
        acknowledgement
            .acknowledges_registration(
                broker_generation,
                &authority.binding_id,
                authority.authority_epoch,
            )
            .then_some(Self(authority))
    }
}

/// Non-blocking handoff seam for the future principal-registration
/// coordinator. Implementations must return only cached, already-acknowledged
/// authority; they must never perform Security or upstream I/O on the reactor.
pub trait DesktopAuthorityActivator: Send + Sync + 'static {
    fn activated_authority(
        &self,
        peer: &VerifiedDesktopPeer,
        now: Timestamp,
    ) -> Option<DurablyActivatedDesktopAuthority>;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum GatewayRequestPhase {
    Prepared,
    QueuedNotWritten,
    Writing,
    AwaitingReply,
    Completed,
    DrainingRevokedReply,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct SessionMessageGatewayStats {
    pub clients: usize,
    pub verification_admissions: usize,
    pub prepared_requests: usize,
    pub current_phase: Option<GatewayRequestPhase>,
    pub upstream_available: bool,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct ClientKey {
    fd: RawFd,
    incarnation: u64,
}

struct VerificationTask {
    key: ClientKey,
    connection_id: AuthorityConnectionId,
    stream: UnixStream,
}

struct VerificationResult {
    task: VerificationTask,
    admission: Result<DesktopPeerAdmission, DesktopPeerVerificationError>,
}

struct VerificationWorker {
    tasks: mpsc::SyncSender<VerificationTask>,
    results: mpsc::Receiver<VerificationResult>,
}

impl VerificationWorker {
    fn spawn(verifier: Arc<dyn DesktopAdmissionVerifier>, generation: NonZeroU64) -> Self {
        let (task_tx, task_rx) = mpsc::sync_channel::<VerificationTask>(MAX_VERIFICATION_QUEUE);
        let (result_tx, result_rx) = mpsc::sync_channel::<VerificationResult>(1);
        thread::Builder::new()
            .name("ouro-session-security".into())
            .spawn(move || {
                while let Ok(task) = task_rx.recv() {
                    let admission =
                        verifier.verify(task.stream.as_fd(), task.connection_id, generation);
                    if result_tx
                        .send(VerificationResult { task, admission })
                        .is_err()
                    {
                        break;
                    }
                }
            })
            .expect("spawn bounded Security verification worker");
        Self {
            tasks: task_tx,
            results: result_rx,
        }
    }
}

struct ClientOutput {
    bytes: Vec<u8>,
    offset: usize,
    reservation: Option<QueuedClientEgress>,
}

struct GatewayClient {
    _stream: UnixStream,
    key: ClientKey,
    connection_id: AuthorityConnectionId,
    input: Vec<u8>,
    output: VecDeque<ClientOutput>,
    output_bytes: usize,
    unreserved_output_bytes: usize,
}

#[derive(Clone, Copy)]
struct PreparedDispatch {
    client: ClientKey,
    connection_id: AuthorityConnectionId,
    pending_id: PendingRequestId,
    client_response_id: NonZeroU64,
}

struct ActiveDispatch {
    client: ClientKey,
    frame: BridgeDispatchFrame,
    write_offset: usize,
    reply_prefix: [u8; LENGTH_PREFIX_BYTES],
    reply_prefix_read: usize,
    reply_payload: Vec<u8>,
    reply_payload_read: usize,
}

impl ActiveDispatch {
    fn new(client: ClientKey, frame: BridgeDispatchFrame) -> Self {
        Self {
            client,
            frame,
            write_offset: 0,
            reply_prefix: [0; LENGTH_PREFIX_BYTES],
            reply_prefix_read: 0,
            reply_payload: Vec::new(),
            reply_payload_read: 0,
        }
    }
}

enum UpstreamState {
    QueuedNotWritten(ActiveDispatch),
    Writing(ActiveDispatch),
    AwaitingReply(ActiveDispatch),
    Completed,
    DrainingRevokedReply(ActiveDispatch),
}

impl UpstreamState {
    fn phase(&self) -> GatewayRequestPhase {
        match self {
            Self::QueuedNotWritten(_) => GatewayRequestPhase::QueuedNotWritten,
            Self::Writing(_) => GatewayRequestPhase::Writing,
            Self::AwaitingReply(_) => GatewayRequestPhase::AwaitingReply,
            Self::Completed => GatewayRequestPhase::Completed,
            Self::DrainingRevokedReply(_) => GatewayRequestPhase::DrainingRevokedReply,
        }
    }
}

pub struct SessionMessageGateway {
    config: SessionMessageGatewayConfig,
    listener: UnixListener,
    upstream: UnixStream,
    upstream_available: bool,
    verifier: VerificationWorker,
    activator: Option<Arc<dyn DesktopAuthorityActivator>>,
    pending_admissions: HashSet<ClientKey>,
    clients: HashMap<RawFd, GatewayClient>,
    prepared: VecDeque<PreparedDispatch>,
    upstream_state: Option<UpstreamState>,
    transport: SessionMessageTransport,
    next_incarnation: u64,
}

impl SessionMessageGateway {
    pub fn bind(
        config: SessionMessageGatewayConfig,
        upstream_fd: OwnedFd,
        verifier: Arc<dyn DesktopAdmissionVerifier>,
        activator: Option<Arc<dyn DesktopAuthorityActivator>>,
    ) -> io::Result<Self> {
        config.validate()?;
        validate_socket_parent(&config.socket_path)?;
        // The validated mode-0700 parent is the atomic privacy boundary. Do
        // not mutate process-global umask from a library reactor: concurrent
        // PTY/test file creation must be unaffected.
        let listener = UnixListener::bind(&config.socket_path)?;
        fs::set_permissions(&config.socket_path, fs::Permissions::from_mode(0o600))?;
        listener.set_nonblocking(true)?;
        set_cloexec(listener.as_raw_fd())?;

        let upstream = UnixStream::from(upstream_fd);
        upstream.set_nonblocking(true)?;
        configure_stream(upstream.as_raw_fd())?;
        let generation = config.broker_generation;
        Ok(Self {
            config,
            listener,
            upstream,
            upstream_available: true,
            verifier: VerificationWorker::spawn(verifier, generation),
            activator,
            pending_admissions: HashSet::new(),
            clients: HashMap::new(),
            prepared: VecDeque::new(),
            upstream_state: None,
            transport: SessionMessageTransport::new(generation),
            next_incarnation: 1,
        })
    }

    pub fn stats(&self) -> SessionMessageGatewayStats {
        SessionMessageGatewayStats {
            clients: self.clients.len(),
            verification_admissions: self.pending_admissions.len(),
            prepared_requests: self.prepared.len() + usize::from(self.upstream_state.is_some()),
            current_phase: self
                .upstream_state
                .as_ref()
                .map(UpstreamState::phase)
                .or_else(|| (!self.prepared.is_empty()).then_some(GatewayRequestPhase::Prepared)),
            upstream_available: self.upstream_available,
        }
    }

    pub fn admit_authenticated_service(
        &mut self,
        peer: VerifiedOuroborosServicePeer,
    ) -> Result<AuthenticatedOuroborosService, GatewayError> {
        self.transport
            .admit_authenticated_service(peer)
            .map_err(GatewayError::Transport)
    }

    /// Activate a session bridge only after its separate privileged
    /// registration frame was durably acknowledged by Ouroboros.
    pub fn register_inherited_session_after_durable_ack(
        &mut self,
        stream: UnixStream,
        service: &AuthenticatedOuroborosService,
        registration: SessionBridgeRegistrationV1,
        acknowledgement: DurablyAcknowledgedPrincipalBindingV1,
        now: Timestamp,
    ) -> Result<(), GatewayError> {
        if !acknowledgement.acknowledges_registration(
            self.config.broker_generation,
            &registration.authority.binding_id,
            registration.authority.authority_epoch,
        ) {
            return Err(GatewayError::DurableAcknowledgementMismatch);
        }
        let connection_id = registration.connection_id;
        self.transport
            .register_session_authority(service, registration, now)
            .map_err(GatewayError::Transport)?;
        self.reconcile_revoked_clients();
        if let Err(error) = self.insert_client(stream, connection_id, None) {
            self.transport.disconnect(connection_id);
            return Err(error);
        }
        Ok(())
    }

    pub fn revoke_session_after_durable_ack(
        &mut self,
        service: &AuthenticatedOuroborosService,
        binding_id: &crate::session_message::BoundedId,
        authority_epoch: u64,
        acknowledgement: DurablyAcknowledgedPrincipalBindingV1,
    ) -> Result<(), GatewayError> {
        if !acknowledgement.acknowledges_revocation(
            self.config.broker_generation,
            binding_id,
            authority_epoch,
        ) {
            return Err(GatewayError::DurableAcknowledgementMismatch);
        }
        self.transport
            .revoke_session_authority(service, binding_id, authority_epoch)
            .map_err(GatewayError::Transport)?;
        self.reconcile_revoked_clients();
        Ok(())
    }

    pub fn tick(&mut self, timeout: Duration, now: Timestamp) -> io::Result<()> {
        self.reap_verification_results(now);
        self.transport.revoke_expired(now);
        self.reconcile_revoked_clients();
        self.finish_completed_state();
        self.drive_dispatch();

        let mut pollfds = Vec::with_capacity(2 + self.clients.len());
        pollfds.push(libc::pollfd {
            fd: self.listener.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        });
        if self.upstream_available {
            pollfds.push(libc::pollfd {
                fd: self.upstream.as_raw_fd(),
                events: self.upstream_poll_events(),
                revents: 0,
            });
        }
        for client in self.clients.values() {
            let mut events = libc::POLLIN;
            if !client.output.is_empty() {
                events |= libc::POLLOUT;
            }
            pollfds.push(libc::pollfd {
                fd: client.key.fd,
                events,
                revents: 0,
            });
        }
        let timeout_ms = timeout.as_millis().min(i32::MAX as u128) as i32;
        let result = unsafe { libc::poll(pollfds.as_mut_ptr(), pollfds.len() as _, timeout_ms) };
        if result < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
        let ready: HashMap<RawFd, i16> = pollfds
            .into_iter()
            .map(|descriptor| (descriptor.fd, descriptor.revents))
            .collect();
        if ready
            .get(&self.listener.as_raw_fd())
            .is_some_and(|events| events & libc::POLLIN != 0)
        {
            self.accept_clients()?;
        }
        if self.upstream_available {
            let events = ready.get(&self.upstream.as_raw_fd()).copied().unwrap_or(0);
            self.service_upstream(events);
        }
        let client_keys: Vec<_> = self.clients.values().map(|client| client.key).collect();
        for key in client_keys {
            let events = ready.get(&key.fd).copied().unwrap_or(0);
            if events != 0 {
                self.service_client(key, events, now);
            }
        }
        self.reap_verification_results(now);
        self.finish_completed_state();
        self.drive_dispatch();
        Ok(())
    }
}

impl SessionMessageGateway {
    fn accept_clients(&mut self) -> io::Result<()> {
        for _ in 0..self.config.max_accepts_per_tick {
            let (stream, _) = match self.listener.accept() {
                Ok(accepted) => accepted,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(()),
                Err(error) => return Err(error),
            };
            if self.clients.len() + self.pending_admissions.len() >= self.config.max_clients {
                continue;
            }
            let key = self.allocate_client_key(stream.as_raw_fd())?;
            let connection_id = AuthorityConnectionId::new(
                NonZeroU64::new(key.incarnation).expect("client incarnation is nonzero"),
            );
            let task = VerificationTask {
                key,
                connection_id,
                stream,
            };
            match self.verifier.tasks.try_send(task) {
                Ok(()) => {
                    self.pending_admissions.insert(key);
                }
                Err(mpsc::TrySendError::Full(_)) | Err(mpsc::TrySendError::Disconnected(_)) => {
                    // Admission is deliberately bounded. The accepted stream
                    // is dropped without ever reading or parsing caller bytes.
                }
            }
        }
        Ok(())
    }

    fn allocate_client_key(&mut self, fd: RawFd) -> io::Result<ClientKey> {
        let incarnation = self.next_incarnation;
        self.next_incarnation = self.next_incarnation.checked_add(1).ok_or_else(|| {
            io::Error::other("session-message client incarnation space exhausted")
        })?;
        Ok(ClientKey { fd, incarnation })
    }

    fn reap_verification_results(&mut self, now: Timestamp) {
        while let Ok(result) = self.verifier.results.try_recv() {
            if !self.pending_admissions.remove(&result.task.key) {
                continue;
            }
            let connection_id = result.task.connection_id;
            let bound = match result.admission {
                Ok(DesktopPeerAdmission::ReadOnly(peer)) => self
                    .transport
                    .bind_pathname_read_only_uid(connection_id, peer.uid())
                    .is_ok(),
                Ok(DesktopPeerAdmission::Mutation(peer)) => self
                    .activator
                    .as_ref()
                    .and_then(|activator| activator.activated_authority(&peer, now))
                    .is_some_and(|activated| {
                        self.transport
                            .bind_verified_signed_desktop(&peer, activated.0, now)
                            .is_ok()
                    }),
                Err(_) => false,
            };
            if bound
                && self
                    .insert_client(result.task.stream, connection_id, Some(result.task.key))
                    .is_err()
            {
                self.transport.disconnect(connection_id);
            }
        }
    }

    fn insert_client(
        &mut self,
        stream: UnixStream,
        connection_id: AuthorityConnectionId,
        verified_key: Option<ClientKey>,
    ) -> Result<(), GatewayError> {
        if self.clients.len() >= self.config.max_clients {
            return Err(GatewayError::ClientLimit);
        }
        let fd = stream.as_raw_fd();
        if self.clients.contains_key(&fd) {
            return Err(GatewayError::ConnectionCollision);
        }
        stream.set_nonblocking(true)?;
        configure_stream(fd)?;
        let key = match verified_key {
            Some(key) if key.fd == fd => key,
            Some(_) => return Err(GatewayError::ConnectionCollision),
            None => self.allocate_client_key(fd)?,
        };
        self.clients.insert(
            fd,
            GatewayClient {
                _stream: stream,
                key,
                connection_id,
                input: Vec::new(),
                output: VecDeque::new(),
                output_bytes: 0,
                unreserved_output_bytes: 0,
            },
        );
        Ok(())
    }

    fn service_client(&mut self, key: ClientKey, events: i16, now: Timestamp) {
        let fatal = events & (libc::POLLERR | libc::POLLNVAL) != 0
            || (events & libc::POLLIN != 0 && !self.read_client(key, now))
            || (events & libc::POLLOUT != 0 && !self.write_client(key));
        if fatal || events & libc::POLLHUP != 0 {
            self.remove_client(key);
        }
    }

    fn read_client(&mut self, key: ClientKey, now: Timestamp) -> bool {
        let mut read_total = 0usize;
        let mut frame_total = 0usize;
        loop {
            while frame_total < self.config.max_client_frames_per_tick {
                let frame = match self.take_client_frame(key) {
                    Ok(Some(frame)) => frame,
                    Ok(None) => break,
                    Err(()) => return false,
                };
                if !self.handle_client_frame(key, &frame, now) {
                    return false;
                }
                frame_total += 1;
            }
            if frame_total >= self.config.max_client_frames_per_tick
                || read_total >= self.config.max_client_read_bytes_per_tick
            {
                return true;
            }
            let remaining = self.config.max_client_read_bytes_per_tick - read_total;
            let mut scratch = [0_u8; 16 * 1_024];
            let allowance = remaining.min(scratch.len());
            match socket_read(key.fd, &mut scratch[..allowance]) {
                Ok(0) => return false,
                Ok(count) => {
                    let Some(client) = self.clients.get_mut(&key.fd).filter(|c| c.key == key)
                    else {
                        return false;
                    };
                    if client.input.len().saturating_add(count)
                        > LENGTH_PREFIX_BYTES + MAX_WIRE_FRAME_BYTES
                    {
                        return false;
                    }
                    if client.input.try_reserve(count).is_err() {
                        return false;
                    }
                    client.input.extend_from_slice(&scratch[..count]);
                    read_total += count;
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return true,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => return false,
            }
        }
    }

    fn take_client_frame(&mut self, key: ClientKey) -> Result<Option<Vec<u8>>, ()> {
        let Some(client) = self
            .clients
            .get_mut(&key.fd)
            .filter(|client| client.key == key)
        else {
            return Err(());
        };
        if client.input.len() < LENGTH_PREFIX_BYTES {
            return Ok(None);
        }
        let length =
            u32::from_be_bytes(client.input[..LENGTH_PREFIX_BYTES].try_into().unwrap()) as usize;
        if length == 0 || length > MAX_WIRE_FRAME_BYTES {
            return Err(());
        }
        let frame_length = LENGTH_PREFIX_BYTES + length;
        if client.input.len() < frame_length {
            return Ok(None);
        }
        let frame = client.input[LENGTH_PREFIX_BYTES..frame_length].to_vec();
        client.input.drain(..frame_length);
        Ok(Some(frame))
    }

    fn handle_client_frame(&mut self, key: ClientKey, frame: &[u8], now: Timestamp) -> bool {
        let header: serde_json::Value = match serde_json::from_slice(frame) {
            Ok(value) => value,
            Err(_) => return false,
        };
        let Some(id) = header
            .get("id")
            .and_then(serde_json::Value::as_u64)
            .and_then(NonZeroU64::new)
        else {
            return false;
        };
        let Some(operation) = header.get("op").and_then(serde_json::Value::as_str) else {
            return self.enqueue_protocol_error(
                key,
                id,
                SessionMessageErrorCode::BadRequest,
                "unknown session-message operation",
            );
        };
        if self.transport.pending_count() >= MAX_PREPARED_REQUESTS {
            return self.enqueue_protocol_error(
                key,
                id,
                SessionMessageErrorCode::QueueFull,
                "session-message queue is full",
            );
        }
        let Some(connection_id) = self
            .clients
            .get(&key.fd)
            .filter(|client| client.key == key)
            .map(|client| client.connection_id)
        else {
            return false;
        };
        let prepared = match operation {
            "session_message_resolve_and_admit" => {
                self.transport
                    .prepare_resolve_and_admit_frame(connection_id, frame, now)
            }
            "session_message_resolve_and_admit_exact" => self
                .transport
                .prepare_exact_resolve_and_admit_frame(connection_id, frame, now),
            "session_message_status" => {
                self.transport
                    .prepare_status_frame(connection_id, frame, now)
            }
            _ => {
                return self.enqueue_protocol_error(
                    key,
                    id,
                    SessionMessageErrorCode::BadRequest,
                    "unknown session-message operation",
                )
            }
        };
        match prepared {
            Ok(pending_id) => {
                self.prepared.push_back(PreparedDispatch {
                    client: key,
                    connection_id,
                    pending_id,
                    client_response_id: id,
                });
                true
            }
            Err(error) => {
                let (code, message) = protocol_error_for_transport(error);
                self.enqueue_protocol_error(key, id, code, message)
            }
        }
    }

    fn write_client(&mut self, key: ClientKey) -> bool {
        let mut written_total = 0usize;
        while written_total < self.config.max_client_write_bytes_per_tick {
            let write_result = {
                let Some(client) = self.clients.get(&key.fd).filter(|client| client.key == key)
                else {
                    return false;
                };
                let Some(front) = client.output.front() else {
                    return true;
                };
                let remaining = self.config.max_client_write_bytes_per_tick - written_total;
                socket_write(
                    key.fd,
                    &front.bytes[front.offset..][..remaining.min(front.bytes.len() - front.offset)],
                )
            };
            match write_result {
                Ok(0) => return false,
                Ok(count) => {
                    written_total += count;
                    let complete = {
                        let client = self.clients.get_mut(&key.fd).unwrap();
                        let front = client.output.front_mut().unwrap();
                        front.offset += count;
                        front.offset == front.bytes.len()
                    };
                    if complete {
                        let mut output = self
                            .clients
                            .get_mut(&key.fd)
                            .unwrap()
                            .output
                            .pop_front()
                            .unwrap();
                        let client = self.clients.get_mut(&key.fd).unwrap();
                        client.output_bytes -= output.bytes.len();
                        if output.reservation.is_none() {
                            client.unreserved_output_bytes -= output.bytes.len();
                        }
                        if let Some(reservation) = output.reservation.take() {
                            if self
                                .transport
                                .release_fully_written_egress(reservation)
                                .is_err()
                            {
                                return false;
                            }
                        }
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return true,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => return false,
            }
        }
        true
    }

    fn enqueue_protocol_error(
        &mut self,
        key: ClientKey,
        id: NonZeroU64,
        code: SessionMessageErrorCode,
        message: &str,
    ) -> bool {
        let error = make_error(self.config.broker_generation, id, code, message);
        let bytes = match encode_client_reply(&AdapterReply::Error(error)) {
            Ok(bytes) => bytes,
            Err(_) => return false,
        };
        let Some(client) = self
            .clients
            .get_mut(&key.fd)
            .filter(|client| client.key == key)
        else {
            return false;
        };
        let reserved = self
            .transport
            .egress_reserved_bytes_for(client.connection_id);
        if client
            .unreserved_output_bytes
            .checked_add(bytes.len())
            .and_then(|value| value.checked_add(reserved))
            .is_none_or(|value| value > MAX_CLIENT_OUTPUT_QUEUE_BYTES)
        {
            return false;
        }
        client.output_bytes += bytes.len();
        client.unreserved_output_bytes += bytes.len();
        client.output.push_back(ClientOutput {
            bytes,
            offset: 0,
            reservation: None,
        });
        true
    }

    fn drive_dispatch(&mut self) {
        if !self.upstream_available || self.upstream_state.is_some() {
            return;
        }
        while let Some(prepared) = self.prepared.pop_front() {
            if !self.client_is_current(prepared.client, prepared.connection_id) {
                self.transport.cancel(prepared.pending_id);
                continue;
            }
            let envelope = match self.transport.begin_dispatch(prepared.pending_id) {
                Ok(envelope) => envelope,
                Err(error) => {
                    self.transport.cancel(prepared.pending_id);
                    let (code, message) = protocol_error_for_transport(error);
                    self.enqueue_protocol_error(
                        prepared.client,
                        prepared.client_response_id,
                        code,
                        message,
                    );
                    continue;
                }
            };
            match encode_dispatch(&envelope) {
                Ok(frame) => {
                    self.upstream_state = Some(UpstreamState::QueuedNotWritten(
                        ActiveDispatch::new(prepared.client, frame),
                    ));
                    return;
                }
                Err(_) => {
                    let error = make_error(
                        self.config.broker_generation,
                        prepared.client_response_id,
                        SessionMessageErrorCode::Internal,
                        "session-message request could not be encoded",
                    );
                    self.complete_with_reply(
                        prepared.client,
                        prepared.pending_id,
                        AdapterReply::Error(error),
                    );
                }
            }
        }
    }

    fn upstream_poll_events(&self) -> i16 {
        match self.upstream_state {
            Some(UpstreamState::QueuedNotWritten(_) | UpstreamState::Writing(_)) => libc::POLLOUT,
            Some(UpstreamState::AwaitingReply(_) | UpstreamState::DrainingRevokedReply(_)) => {
                libc::POLLIN
            }
            Some(UpstreamState::Completed) | None => 0,
        }
    }

    fn service_upstream(&mut self, events: i16) {
        if events & (libc::POLLERR | libc::POLLNVAL) != 0 {
            self.fail_upstream();
            return;
        }
        if events & libc::POLLOUT != 0 {
            self.write_upstream();
        }
        if self.upstream_available && events & (libc::POLLIN | libc::POLLHUP) != 0 {
            self.read_upstream();
        }
    }

    fn write_upstream(&mut self) {
        let Some(state) = self.upstream_state.take() else {
            return;
        };
        let mut active = match state {
            UpstreamState::QueuedNotWritten(active) | UpstreamState::Writing(active) => active,
            other => {
                self.upstream_state = Some(other);
                return;
            }
        };
        let remaining_budget = self.config.max_upstream_write_bytes_per_tick;
        let end = (active.write_offset + remaining_budget).min(active.frame.bytes().len());
        match socket_write(
            self.upstream.as_raw_fd(),
            &active.frame.bytes()[active.write_offset..end],
        ) {
            Ok(0) => {
                self.fail_active_write(active);
            }
            Ok(count) => {
                active.write_offset += count;
                self.upstream_state = Some(if active.write_offset == active.frame.bytes().len() {
                    UpstreamState::AwaitingReply(active)
                } else {
                    UpstreamState::Writing(active)
                });
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                self.upstream_state = Some(if active.write_offset == 0 {
                    UpstreamState::QueuedNotWritten(active)
                } else {
                    UpstreamState::Writing(active)
                });
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {
                self.upstream_state = Some(if active.write_offset == 0 {
                    UpstreamState::QueuedNotWritten(active)
                } else {
                    UpstreamState::Writing(active)
                });
            }
            Err(_) => self.fail_active_write(active),
        }
    }

    fn read_upstream(&mut self) {
        let Some(state) = self.upstream_state.take() else {
            return;
        };
        let draining = matches!(state, UpstreamState::DrainingRevokedReply(_));
        let mut active = match state {
            UpstreamState::AwaitingReply(active) | UpstreamState::DrainingRevokedReply(active) => {
                active
            }
            other => {
                self.upstream_state = Some(other);
                return;
            }
        };
        let read = self.read_active_reply(&mut active);
        match read {
            Ok(false) => {
                self.upstream_state = Some(if draining {
                    UpstreamState::DrainingRevokedReply(active)
                } else {
                    UpstreamState::AwaitingReply(active)
                });
            }
            Ok(true) if draining => {
                self.upstream_state = Some(UpstreamState::Completed);
            }
            Ok(true) => {
                let decoded = decode_reply(&active.frame, &active.reply_payload);
                match decoded {
                    Ok(reply) => {
                        self.complete_with_reply(active.client, active.frame.pending_id(), reply);
                        self.upstream_state = Some(UpstreamState::Completed);
                    }
                    Err(_) => {
                        self.fail_active_ambiguous(active);
                    }
                }
            }
            Err(_) if draining => self.mark_upstream_unavailable(),
            Err(_) => self.fail_active_ambiguous(active),
        }
    }

    fn read_active_reply(&self, active: &mut ActiveDispatch) -> io::Result<bool> {
        let mut budget = self.config.max_upstream_read_bytes_per_tick;
        while active.reply_prefix_read < LENGTH_PREFIX_BYTES && budget > 0 {
            match socket_read(
                self.upstream.as_raw_fd(),
                &mut active.reply_prefix[active.reply_prefix_read..],
            ) {
                Ok(0) => return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "upstream EOF")),
                Ok(count) => {
                    active.reply_prefix_read += count;
                    budget = budget.saturating_sub(count);
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(false),
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }
        if active.reply_prefix_read < LENGTH_PREFIX_BYTES {
            return Ok(false);
        }
        if active.reply_payload.is_empty() {
            let length = u32::from_be_bytes(active.reply_prefix) as usize;
            if length == 0 || length > MAX_RECEIPT_BYTES {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "invalid upstream reply length",
                ));
            }
            active.reply_payload.resize(length, 0);
        }
        while active.reply_payload_read < active.reply_payload.len() && budget > 0 {
            let remaining = active.reply_payload.len() - active.reply_payload_read;
            let allowance = remaining.min(budget);
            match socket_read(
                self.upstream.as_raw_fd(),
                &mut active.reply_payload
                    [active.reply_payload_read..active.reply_payload_read + allowance],
            ) {
                Ok(0) => return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "upstream EOF")),
                Ok(count) => {
                    active.reply_payload_read += count;
                    budget -= count;
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(false),
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }
        Ok(active.reply_payload_read == active.reply_payload.len())
    }

    fn fail_active_write(&mut self, active: ActiveDispatch) {
        let (code, message) = if active.write_offset == 0 {
            (
                SessionMessageErrorCode::UpstreamUnavailable,
                "Ouroboros is unavailable before request delivery",
            )
        } else {
            (
                SessionMessageErrorCode::OutcomeUnknown,
                "Ouroboros disconnected after request delivery began",
            )
        };
        let error = make_error(
            self.config.broker_generation,
            active.frame.client_response_id(),
            code,
            message,
        );
        self.complete_with_reply(
            active.client,
            active.frame.pending_id(),
            AdapterReply::Error(error),
        );
        self.mark_upstream_unavailable();
    }

    fn fail_active_ambiguous(&mut self, active: ActiveDispatch) {
        let error = make_error(
            self.config.broker_generation,
            active.frame.client_response_id(),
            SessionMessageErrorCode::OutcomeUnknown,
            "Ouroboros reply was unavailable after request delivery",
        );
        self.complete_with_reply(
            active.client,
            active.frame.pending_id(),
            AdapterReply::Error(error),
        );
        self.mark_upstream_unavailable();
    }

    fn fail_upstream(&mut self) {
        let state = self.upstream_state.take();
        match state {
            Some(UpstreamState::QueuedNotWritten(active)) => self.fail_active_write(active),
            Some(UpstreamState::Writing(active)) => self.fail_active_write(active),
            Some(UpstreamState::AwaitingReply(active)) => self.fail_active_ambiguous(active),
            Some(UpstreamState::DrainingRevokedReply(_) | UpstreamState::Completed) | None => {
                self.mark_upstream_unavailable();
            }
        }
    }

    fn mark_upstream_unavailable(&mut self) {
        self.upstream_available = false;
        self.upstream_state = None;
        while let Some(prepared) = self.prepared.pop_front() {
            if !self.client_is_current(prepared.client, prepared.connection_id) {
                self.transport.cancel(prepared.pending_id);
                continue;
            }
            match self.transport.begin_dispatch(prepared.pending_id) {
                Ok(_) => {
                    let error = make_error(
                        self.config.broker_generation,
                        prepared.client_response_id,
                        SessionMessageErrorCode::UpstreamUnavailable,
                        "Ouroboros is unavailable before request delivery",
                    );
                    self.complete_with_reply(
                        prepared.client,
                        prepared.pending_id,
                        AdapterReply::Error(error),
                    );
                }
                Err(_) => {
                    self.transport.cancel(prepared.pending_id);
                }
            }
        }
    }

    fn complete_with_reply(
        &mut self,
        key: ClientKey,
        pending_id: PendingRequestId,
        reply: AdapterReply,
    ) {
        let completed = match self.transport.complete_dispatch(pending_id, reply) {
            Ok(completed) => completed,
            Err(TransportError::LateOrDuplicateCompletion) => return,
            Err(_) => {
                self.remove_client(key);
                return;
            }
        };
        let bytes = match encode_client_reply(completed.reply()) {
            Ok(bytes) => bytes,
            Err(_) => {
                self.remove_client(key);
                return;
            }
        };
        let queued = match self.transport.handoff_egress(completed) {
            Ok(queued) => queued,
            Err(_) => {
                self.remove_client(key);
                return;
            }
        };
        let Some(client) = self
            .clients
            .get_mut(&key.fd)
            .filter(|client| client.key == key)
        else {
            self.transport.disconnect(queued.connection_id());
            return;
        };
        client.output_bytes += bytes.len();
        client.output.push_back(ClientOutput {
            bytes,
            offset: 0,
            reservation: Some(queued),
        });
    }

    fn finish_completed_state(&mut self) {
        if matches!(self.upstream_state, Some(UpstreamState::Completed)) {
            self.upstream_state = None;
        }
    }

    fn client_is_current(&self, key: ClientKey, connection_id: AuthorityConnectionId) -> bool {
        self.clients.get(&key.fd).is_some_and(|client| {
            client.key == key
                && client.connection_id == connection_id
                && self
                    .transport
                    .authorities()
                    .contains_connection(connection_id)
        })
    }

    fn remove_client(&mut self, key: ClientKey) {
        let Some(client) = self.clients.get(&key.fd).filter(|client| client.key == key) else {
            return;
        };
        let connection_id = client.connection_id;
        self.transport.disconnect(connection_id);
        self.clients.remove(&key.fd);
        self.prepared.retain(|request| request.client != key);

        let state = self.upstream_state.take();
        self.upstream_state = match state {
            Some(UpstreamState::QueuedNotWritten(active)) if active.client == key => None,
            Some(UpstreamState::Writing(active)) if active.client == key => {
                self.mark_upstream_unavailable();
                None
            }
            Some(UpstreamState::AwaitingReply(active)) if active.client == key => {
                Some(UpstreamState::DrainingRevokedReply(active))
            }
            other => other,
        };
    }

    fn reconcile_revoked_clients(&mut self) {
        let revoked: Vec<_> = self
            .clients
            .values()
            .filter(|client| {
                !self
                    .transport
                    .authorities()
                    .contains_connection(client.connection_id)
            })
            .map(|client| client.key)
            .collect();
        for key in revoked {
            self.remove_client(key);
        }
    }
}

fn encode_client_reply(reply: &AdapterReply) -> Result<Vec<u8>, GatewayError> {
    let payload = match reply {
        AdapterReply::Receipt(receipt) => serde_json::to_vec(receipt),
        AdapterReply::Error(error) => serde_json::to_vec(error),
    }
    .map_err(|_| GatewayError::Bridge(BridgeWireError::Encode))?;
    if payload.is_empty() || payload.len() > MAX_RECEIPT_BYTES {
        return Err(GatewayError::Bridge(BridgeWireError::ReplyTooLarge));
    }
    let length = u32::try_from(payload.len())
        .map_err(|_| GatewayError::Bridge(BridgeWireError::ReplyTooLarge))?;
    let mut frame = Vec::with_capacity(LENGTH_PREFIX_BYTES + payload.len());
    frame.extend_from_slice(&length.to_be_bytes());
    frame.extend_from_slice(&payload);
    Ok(frame)
}

fn make_error(
    generation: NonZeroU64,
    id: NonZeroU64,
    code: SessionMessageErrorCode,
    message: &str,
) -> SessionMessageErrorV1 {
    SessionMessageErrorV1 {
        version: Version1,
        broker_generation: generation,
        id,
        error: ErrorResult::SessionMessageError,
        code,
        message: BoundedErrorMessage::try_from(message)
            .expect("static gateway error message is bounded"),
    }
}

fn protocol_error_for_transport(error: TransportError) -> (SessionMessageErrorCode, &'static str) {
    use crate::authority_registry::AuthorityRegistryError;
    match error {
        TransportError::BadFrame | TransportError::FrameTooLarge => (
            SessionMessageErrorCode::BadRequest,
            "invalid session-message request",
        ),
        TransportError::ReadOnlyTransport => (
            SessionMessageErrorCode::Unauthorized,
            "session-message transport is read-only",
        ),
        TransportError::GlobalInflightLimit
        | TransportError::ClientInflightLimit
        | TransportError::PendingBytesLimit
        | TransportError::ClientEgressLimit => (
            SessionMessageErrorCode::QueueFull,
            "session-message queue is full",
        ),
        TransportError::Authority(AuthorityRegistryError::StaleGeneration) => (
            SessionMessageErrorCode::StaleGeneration,
            "broker generation is stale",
        ),
        TransportError::Authority(AuthorityRegistryError::StaleAuthority) => (
            SessionMessageErrorCode::StaleAuthority,
            "session authority is stale",
        ),
        TransportError::Authority(AuthorityRegistryError::Expired) => (
            SessionMessageErrorCode::Expired,
            "session authority expired",
        ),
        TransportError::Authority(AuthorityRegistryError::Unauthenticated) => (
            SessionMessageErrorCode::Unauthenticated,
            "session-message connection is unauthenticated",
        ),
        TransportError::Authority(_) => (
            SessionMessageErrorCode::Unauthorized,
            "session-message authority rejected the request",
        ),
        _ => (
            SessionMessageErrorCode::Internal,
            "session-message gateway state rejected the request",
        ),
    }
}

#[derive(Debug)]
pub enum GatewayError {
    Io(io::Error),
    Transport(TransportError),
    Bridge(BridgeWireError),
    ConnectionCollision,
    ClientLimit,
    DurableAcknowledgementMismatch,
}

impl fmt::Display for GatewayError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "session-message I/O failed: {error}"),
            Self::Transport(error) => {
                write!(formatter, "session-message transport failed: {error}")
            }
            Self::Bridge(error) => write!(formatter, "session-message bridge failed: {error}"),
            Self::ConnectionCollision => {
                formatter.write_str("session-message connection collision")
            }
            Self::ClientLimit => formatter.write_str("session-message client limit reached"),
            Self::DurableAcknowledgementMismatch => formatter
                .write_str("principal-binding durable acknowledgement does not match activation"),
        }
    }
}

impl std::error::Error for GatewayError {}

impl From<io::Error> for GatewayError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

fn validate_socket_parent(path: &PathBuf) -> io::Result<()> {
    if fs::symlink_metadata(path).is_ok() {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "session-message socket path already exists",
        ));
    }
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "session-message socket has no parent",
        )
    })?;
    let metadata = fs::symlink_metadata(parent)?;
    if metadata.file_type().is_symlink()
        || !metadata.file_type().is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o777 != 0o700
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "session-message socket parent must be owned mode-0700 directory",
        ));
    }
    Ok(())
}

fn set_cloexec(fd: RawFd) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn configure_stream(fd: RawFd) -> io::Result<()> {
    set_cloexec(fd)?;
    #[cfg(target_os = "macos")]
    {
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
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

fn socket_write(fd: RawFd, bytes: &[u8]) -> io::Result<usize> {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    let result = unsafe { libc::send(fd, bytes.as_ptr().cast(), bytes.len(), libc::MSG_NOSIGNAL) };
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    let result = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
    if result < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(result as usize)
    }
}

fn socket_read(fd: RawFd, bytes: &mut [u8]) -> io::Result<usize> {
    let result = unsafe { libc::read(fd, bytes.as_mut_ptr().cast(), bytes.len()) };
    if result < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(result as usize)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::authority_registry::RegisterSessionAuthorityV1;
    use crate::principal_binding_ack_wire::{
        decode_ack_frame, encode_registration, PrincipalBindingAckResultV1,
    };
    use crate::principal_binding_registration::{
        PrincipalBindingEnvelopeV1, VerifiedInstallationAuthorityV1,
    };
    use crate::session_message::BoundedId;
    use serde_json::{json, Value};
    use std::io::{Read, Write};
    use std::os::fd::{FromRawFd, IntoRawFd};
    use std::os::unix::fs::FileTypeExt;
    use std::os::unix::process::CommandExt;
    use std::process::{Child, Command};
    use std::sync::Mutex;
    use std::time::Instant;
    use tempfile::TempDir;

    const GENERATION: u64 = 873_421;
    const UID: u32 = 501;

    fn nonzero(value: u64) -> NonZeroU64 {
        NonZeroU64::new(value).unwrap()
    }

    fn connection(value: u64) -> AuthorityConnectionId {
        AuthorityConnectionId::new(nonzero(value))
    }

    fn id(value: impl AsRef<str>) -> BoundedId {
        BoundedId::try_from(value.as_ref()).unwrap()
    }

    fn now() -> Timestamp {
        Timestamp::parse("2026-08-10T15:00:00Z").unwrap()
    }

    fn expiry() -> Timestamp {
        Timestamp::parse("2026-08-10T16:00:00Z").unwrap()
    }

    fn acknowledged(envelope: PrincipalBindingEnvelopeV1) -> DurablyAcknowledgedPrincipalBindingV1 {
        let dispatch = encode_registration(envelope).unwrap();
        let expectation = dispatch.expectation();
        let result = match expectation.result() {
            PrincipalBindingAckResultV1::Registered => "principal_binding_registered",
            PrincipalBindingAckResultV1::Revoked => "principal_binding_revoked",
        };
        let payload = serde_json::to_vec(&json!({
            "version": 1,
            "broker_generation": expectation.broker_generation().get(),
            "id": expectation.request_id().get(),
            "result": result,
            "binding_id": expectation.binding_id().as_str(),
            "authority_epoch": expectation.authority_epoch(),
            "changed": true,
        }))
        .unwrap();
        let mut frame = Vec::with_capacity(LENGTH_PREFIX_BYTES + payload.len());
        frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        frame.extend_from_slice(&payload);
        decode_ack_frame(expectation, &frame).unwrap()
    }

    fn acknowledged_session_registration(
        registration: &SessionBridgeRegistrationV1,
        broker_generation: u64,
    ) -> DurablyAcknowledgedPrincipalBindingV1 {
        let authority = &registration.authority;
        let policy = VerifiedInstallationAuthorityV1::from_verified_installation(
            id("workspace-code"),
            id("forest-1"),
        );
        acknowledged(PrincipalBindingEnvelopeV1::session(
            nonzero(7_001),
            nonzero(broker_generation),
            authority.binding_id.clone(),
            UID,
            authority.authority_epoch,
            &policy,
            authority.session_id.clone(),
            authority.execution_id.clone(),
            authority.scope_id.clone(),
            authority.attempt_id.clone(),
            authority.owner_incarnation.clone(),
            authority.expires_at,
            authority.cause.clone(),
        ))
    }

    fn acknowledged_session_revocation(
        binding_id: &BoundedId,
        authority_epoch: u64,
        broker_generation: u64,
    ) -> DurablyAcknowledgedPrincipalBindingV1 {
        acknowledged(PrincipalBindingEnvelopeV1::revoke(
            nonzero(7_002),
            nonzero(broker_generation),
            binding_id.clone(),
            authority_epoch,
        ))
    }

    fn session_registration(
        connection_id: AuthorityConnectionId,
        index: u64,
    ) -> SessionBridgeRegistrationV1 {
        SessionBridgeRegistrationV1 {
            connection_id,
            authority: RegisterSessionAuthorityV1 {
                binding_id: id(format!("binding-{index}")),
                session_id: id(format!("session-{index}")),
                execution_id: id("execution-1"),
                scope_id: id(format!("scope-{index}")),
                attempt_id: id(format!("attempt-{index}")),
                authority_epoch: 3,
                owner_incarnation: id(format!("owner-{index}")),
                terminal_id: None,
                expires_at: expiry(),
                cause: None,
            },
        }
    }

    struct RejectVerifier;

    impl DesktopAdmissionVerifier for RejectVerifier {
        fn verify(
            &self,
            _socket: BorrowedFd<'_>,
            _connection_id: AuthorityConnectionId,
            _broker_generation: NonZeroU64,
        ) -> Result<DesktopPeerAdmission, DesktopPeerVerificationError> {
            Err(DesktopPeerVerificationError::CodeIdentityRejected)
        }
    }

    struct Fixture {
        _directory: TempDir,
        gateway: SessionMessageGateway,
        upstream: UnixStream,
        service: AuthenticatedOuroborosService,
        next_connection: u64,
    }

    impl Fixture {
        fn new(upstream_write_budget: usize) -> Self {
            let directory = tempfile::tempdir().unwrap();
            fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
            let socket_path = directory.path().join("session-message-v1.sock");
            let (gateway_upstream, upstream) = UnixStream::pair().unwrap();
            let mut config = SessionMessageGatewayConfig::new(&socket_path, nonzero(GENERATION));
            config.max_upstream_write_bytes_per_tick = upstream_write_budget;
            let upstream_fd = unsafe { OwnedFd::from_raw_fd(gateway_upstream.into_raw_fd()) };
            let mut gateway =
                SessionMessageGateway::bind(config, upstream_fd, Arc::new(RejectVerifier), None)
                    .unwrap();
            let service_peer = VerifiedOuroborosServicePeer::from_verified_transport(
                connection(9_000),
                UID,
                [0x51; 32],
                id("service-incarnation-1"),
                nonzero(GENERATION),
            );
            let service = gateway.admit_authenticated_service(service_peer).unwrap();
            Self {
                _directory: directory,
                gateway,
                upstream,
                service,
                next_connection: 100,
            }
        }

        fn add_session(&mut self, index: u64) -> (UnixStream, ClientKey, BoundedId) {
            let connection_id = connection(self.next_connection);
            self.next_connection += 1;
            let registration = session_registration(connection_id, index);
            let binding_id = registration.authority.binding_id.clone();
            let (gateway_stream, client) = UnixStream::pair().unwrap();
            let acknowledgement = acknowledged_session_registration(&registration, GENERATION);
            self.gateway
                .register_inherited_session_after_durable_ack(
                    gateway_stream,
                    &self.service,
                    registration,
                    acknowledgement,
                    now(),
                )
                .unwrap();
            let key = self
                .gateway
                .clients
                .values()
                .find(|client| client.connection_id == connection_id)
                .unwrap()
                .key;
            (client, key, binding_id)
        }
    }

    fn request(index: u64, request_id: u64) -> Vec<u8> {
        serde_json::to_vec(&json!({
            "version": 1,
            "id": request_id,
            "op": "session_message_resolve_and_admit",
            "broker_generation": GENERATION,
            "authority_epoch": 3,
            "request_nonce": "EiQ2SFpscYKTpLXNZ2mr7A",
            "target_session_id": "session-target",
            "expected_execution_id": null,
            "expected_target_generation": null,
            "mode": "after_turn",
            "message": format!("message from {index}"),
            "reason": "gateway fixture",
            "expires_at": "2026-08-10T15:30:00Z",
            "correlation_id": null
        }))
        .unwrap()
    }

    fn exact_request(request_id: u64, nonce: &str, scope_id: &str, attempt_id: &str) -> Vec<u8> {
        serde_json::to_vec(&json!({
            "version": 2,
            "id": request_id,
            "op": "session_message_resolve_and_admit_exact",
            "broker_generation": GENERATION,
            "authority_epoch": 3,
            "request_nonce": nonce,
            "target": {
                "session_id": "session-fanout",
                "execution_id": "execution-1",
                "scope_id": scope_id,
                "attempt_id": attempt_id,
                "generation": 7
            },
            "mode": "after_turn",
            "message": format!("message for {attempt_id}"),
            "reason": "human steering fixture",
            "expires_at": "2026-08-10T15:30:00Z",
            "correlation_id": "multiplexer-pane"
        }))
        .unwrap()
    }

    fn send_frame(stream: &mut UnixStream, payload: &[u8]) {
        stream
            .write_all(&(payload.len() as u32).to_be_bytes())
            .unwrap();
        stream.write_all(payload).unwrap();
    }

    fn read_frame(stream: &mut UnixStream) -> Vec<u8> {
        let mut prefix = [0_u8; 4];
        stream.read_exact(&mut prefix).unwrap();
        let mut payload = vec![0_u8; u32::from_be_bytes(prefix) as usize];
        stream.read_exact(&mut payload).unwrap();
        payload
    }

    fn read_upstream_request(stream: &mut UnixStream) -> Value {
        serde_json::from_slice(&read_frame(stream)).unwrap()
    }

    fn write_upstream_error(stream: &mut UnixStream, request: &Value) {
        let payload = serde_json::to_vec(&json!({
            "version": 1,
            "broker_generation": GENERATION,
            "id": request["id"],
            "error": "session_message_error",
            "code": "upstream_unavailable",
            "message": "bounded fixture response"
        }))
        .unwrap();
        send_frame(stream, &payload);
    }

    fn queued_error_code(
        gateway: &SessionMessageGateway,
        key: ClientKey,
    ) -> SessionMessageErrorCode {
        let output = gateway.clients[&key.fd].output.front().unwrap();
        let error: SessionMessageErrorV1 = serde_json::from_slice(&output.bytes[4..]).unwrap();
        error.code
    }

    fn drive_full_write(gateway: &mut SessionMessageGateway) {
        while !matches!(
            gateway.upstream_state,
            Some(UpstreamState::AwaitingReply(_))
        ) {
            gateway.write_upstream();
        }
    }

    fn exact_socket_exchange(
        fixture: &mut Fixture,
        client: &mut UnixStream,
        key: ClientKey,
        request: &[u8],
        upstream_reply: impl FnOnce(&Value) -> Value,
    ) -> (Value, Value) {
        send_frame(client, request);
        assert!(fixture.gateway.read_client(key, now()));
        fixture.gateway.drive_dispatch();
        drive_full_write(&mut fixture.gateway);
        let upstream_request = read_upstream_request(&mut fixture.upstream);
        let reply = serde_json::to_vec(&upstream_reply(&upstream_request)).unwrap();
        send_frame(&mut fixture.upstream, &reply);
        fixture.gateway.read_upstream();
        fixture.gateway.finish_completed_state();
        assert!(fixture.gateway.write_client(key));
        let client_reply = serde_json::from_slice(&read_frame(client)).unwrap();
        (upstream_request, client_reply)
    }

    #[test]
    fn listener_is_separate_owned_and_mode_0600() {
        let fixture = Fixture::new(MAX_WIRE_FRAME_BYTES + LENGTH_PREFIX_BYTES);
        let metadata = fs::symlink_metadata(&fixture.gateway.config.socket_path).unwrap();
        assert!(metadata.file_type().is_socket());
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        assert_eq!(metadata.uid(), unsafe { libc::geteuid() });
    }

    #[test]
    fn session_activation_rejects_wrong_kind_and_generation_acknowledgements() {
        let mut fixture = Fixture::new(1);
        let registration = session_registration(connection(700), 7);
        let binding_id = registration.authority.binding_id.clone();
        let (gateway_stream, _client) = UnixStream::pair().unwrap();
        let result = fixture
            .gateway
            .register_inherited_session_after_durable_ack(
                gateway_stream,
                &fixture.service,
                registration.clone(),
                acknowledged_session_revocation(&binding_id, 3, GENERATION),
                now(),
            );
        assert!(matches!(
            result,
            Err(GatewayError::DurableAcknowledgementMismatch)
        ));
        assert!(!fixture
            .gateway
            .transport
            .authorities()
            .contains_connection(connection(700)));

        let (gateway_stream, _client) = UnixStream::pair().unwrap();
        let result = fixture
            .gateway
            .register_inherited_session_after_durable_ack(
                gateway_stream,
                &fixture.service,
                registration.clone(),
                acknowledged_session_registration(&registration, GENERATION + 1),
                now(),
            );
        assert!(matches!(
            result,
            Err(GatewayError::DurableAcknowledgementMismatch)
        ));
        assert!(!fixture
            .gateway
            .transport
            .authorities()
            .contains_connection(connection(700)));
        assert!(fixture.gateway.clients.is_empty());
    }

    #[test]
    fn session_revocation_rejects_registration_and_cross_generation_tokens() {
        let mut fixture = Fixture::new(1);
        let (_, key, binding_id) = fixture.add_session(8);
        let connection_id = fixture.gateway.clients[&key.fd].connection_id;
        let registration = session_registration(connection(701), 8);
        let result = fixture.gateway.revoke_session_after_durable_ack(
            &fixture.service,
            &binding_id,
            3,
            acknowledged_session_registration(&registration, GENERATION),
        );
        assert!(matches!(
            result,
            Err(GatewayError::DurableAcknowledgementMismatch)
        ));
        assert!(fixture.gateway.client_is_current(key, connection_id));

        let result = fixture.gateway.revoke_session_after_durable_ack(
            &fixture.service,
            &binding_id,
            3,
            acknowledged_session_revocation(&binding_id, 3, GENERATION + 1),
        );
        assert!(matches!(
            result,
            Err(GatewayError::DurableAcknowledgementMismatch)
        ));
        assert!(fixture.gateway.client_is_current(key, connection_id));
    }

    #[test]
    fn phases_are_nonblocking_and_local_request_ids_do_not_collide_upstream() {
        let mut fixture = Fixture::new(1);
        let (_, first, _) = fixture.add_session(1);
        let (_, second, _) = fixture.add_session(2);
        assert!(fixture
            .gateway
            .handle_client_frame(first, &request(1, 42), now()));
        assert!(fixture
            .gateway
            .handle_client_frame(second, &request(2, 42), now()));
        assert_eq!(
            fixture.gateway.stats().current_phase,
            Some(GatewayRequestPhase::Prepared)
        );
        fixture.gateway.drive_dispatch();
        assert_eq!(
            fixture.gateway.stats().current_phase,
            Some(GatewayRequestPhase::QueuedNotWritten)
        );
        fixture.gateway.write_upstream();
        assert_eq!(
            fixture.gateway.stats().current_phase,
            Some(GatewayRequestPhase::Writing)
        );
        drive_full_write(&mut fixture.gateway);
        let first_upstream = read_upstream_request(&mut fixture.upstream);
        assert_eq!(first_upstream["id"], 1);
        assert_eq!(first_upstream["principal_binding_id"], "binding-1");
        write_upstream_error(&mut fixture.upstream, &first_upstream);
        fixture.gateway.read_upstream();
        assert_eq!(
            fixture.gateway.stats().current_phase,
            Some(GatewayRequestPhase::Completed)
        );
        fixture.gateway.finish_completed_state();
        fixture.gateway.drive_dispatch();
        drive_full_write(&mut fixture.gateway);
        let second_upstream = read_upstream_request(&mut fixture.upstream);
        assert_eq!(second_upstream["id"], 2);
        assert_ne!(first_upstream["id"], second_upstream["id"]);
    }

    #[test]
    fn exact_pane_socket_path_proves_queued_rejected_and_delivery_uncertain() {
        let mut fixture = Fixture::new(MAX_WIRE_FRAME_BYTES + LENGTH_PREFIX_BYTES);
        let (mut source_client, source_key, _) = fixture.add_session(1);

        let queued = exact_request(
            101,
            "EiQ2SFpscYKTpLXNZ2mr7A",
            "scope-pane-b",
            "attempt-pane-b",
        );
        let (queued_upstream, queued_client) = exact_socket_exchange(
            &mut fixture,
            &mut source_client,
            source_key,
            &queued,
            |request| {
                assert_eq!(request["principal_binding_id"], "binding-1");
                assert_eq!(request["mode"], "after_turn");
                assert_eq!(request["target"]["scope_id"], "scope-pane-b");
                assert_eq!(request["target"]["attempt_id"], "attempt-pane-b");
                for forbidden in ["source", "source_session_id", "source_attempt_id"] {
                    assert!(request.get(forbidden).is_none());
                }
                json!({
                    "version": 1,
                    "broker_generation": GENERATION,
                    "id": request["id"],
                    "result": "session_message_receipt",
                    "request_nonce": "EiQ2SFpscYKTpLXNZ2mr7A",
                    "request_digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
                    "signal_id": "signal-pane-b",
                    "source": {
                        "kind": "session",
                        "session_id": "session-1",
                        "execution_id": "execution-1",
                        "scope_id": "scope-1",
                        "attempt_id": "attempt-1",
                        "generation": 4
                    },
                    "target": request["target"],
                    "mode": "after_turn",
                    "state": "queued",
                    "durable_cursor": 41,
                    "application_proven": false,
                    "replayed": false,
                    "hop_count": 1,
                    "expires_at": "2026-08-10T15:30:00Z",
                    "reply_summary": null
                })
            },
        );
        assert_eq!(queued_upstream["id"], 1);
        assert_eq!(queued_client["id"], 101);
        assert_eq!(queued_client["state"], "queued");
        assert_eq!(queued_client["target"]["attempt_id"], "attempt-pane-b");
        assert_eq!(queued_client["source"]["attempt_id"], "attempt-1");

        // Pane A shares the session, execution and generation with pane B but
        // is a different exact attempt. The fixture upstream rejects it rather
        // than silently resolving the stable session to whichever pane wins.
        let sibling = exact_request(
            102,
            "AAAAAAAAAAAAAAAAAAAAAA",
            "scope-pane-a",
            "attempt-pane-a",
        );
        let (sibling_upstream, sibling_client) = exact_socket_exchange(
            &mut fixture,
            &mut source_client,
            source_key,
            &sibling,
            |request| {
                assert_eq!(request["target"]["session_id"], "session-fanout");
                assert_eq!(request["target"]["execution_id"], "execution-1");
                assert_eq!(request["target"]["generation"], 7);
                assert_ne!(request["target"]["attempt_id"], "attempt-pane-b");
                json!({
                    "version": 1,
                    "broker_generation": GENERATION,
                    "id": request["id"],
                    "error": "session_message_error",
                    "code": "target_not_active",
                    "message": "exact sibling pane is not active"
                })
            },
        );
        assert_eq!(sibling_upstream["id"], 2);
        assert_eq!(sibling_client["id"], 102);
        assert_eq!(sibling_client["code"], "target_not_active");

        let uncertain = exact_request(
            103,
            "AQEBAQEBAQEBAQEBAQEBAQ",
            "scope-pane-b",
            "attempt-pane-b",
        );
        let (uncertain_upstream, uncertain_client) = exact_socket_exchange(
            &mut fixture,
            &mut source_client,
            source_key,
            &uncertain,
            |request| {
                json!({
                    "version": 1,
                    "broker_generation": GENERATION,
                    "id": request["id"],
                    "result": "session_message_receipt",
                    "request_nonce": "AQEBAQEBAQEBAQEBAQEBAQ",
                    "request_digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
                    "signal_id": "signal-pane-b-uncertain",
                    "source": {
                        "kind": "session",
                        "session_id": "session-1",
                        "execution_id": "execution-1",
                        "scope_id": "scope-1",
                        "attempt_id": "attempt-1",
                        "generation": 4
                    },
                    "target": request["target"],
                    "mode": "after_turn",
                    "state": "delivery_uncertain",
                    "durable_cursor": 43,
                    "application_proven": false,
                    "replayed": false,
                    "hop_count": 1,
                    "expires_at": "2026-08-10T15:30:00Z",
                    "reply_summary": null
                })
            },
        );
        assert_eq!(uncertain_upstream["id"], 3);
        assert_eq!(uncertain_client["id"], 103);
        assert_eq!(uncertain_client["state"], "delivery_uncertain");
        assert_eq!(uncertain_client["application_proven"], false);
    }

    #[test]
    fn sixty_fifth_prepared_request_gets_bounded_queue_full() {
        let mut fixture = Fixture::new(1);
        let mut peers = Vec::new();
        for index in 0..32 {
            let (peer, key, _) = fixture.add_session(index);
            assert!(fixture
                .gateway
                .handle_client_frame(key, &request(index, 1), now()));
            assert!(fixture
                .gateway
                .handle_client_frame(key, &request(index, 2), now()));
            peers.push(peer);
        }
        let (_peer, key, _) = fixture.add_session(99);
        assert!(fixture
            .gateway
            .handle_client_frame(key, &request(99, 65), now()));
        assert_eq!(fixture.gateway.transport.pending_count(), 64);
        assert_eq!(
            queued_error_code(&fixture.gateway, key),
            SessionMessageErrorCode::QueueFull
        );
        drop(peers);
    }

    fn failed_dispatch_code(
        write_budget: usize,
        writes_before_death: usize,
    ) -> SessionMessageErrorCode {
        let mut fixture = Fixture::new(write_budget);
        let (_, key, _) = fixture.add_session(1);
        assert!(fixture
            .gateway
            .handle_client_frame(key, &request(1, 77), now()));
        fixture.gateway.drive_dispatch();
        if writes_before_death == 0 {
            let Some(UpstreamState::QueuedNotWritten(active)) =
                fixture.gateway.upstream_state.take()
            else {
                panic!("dispatch was not queued")
            };
            drop(fixture.upstream);
            fixture.gateway.fail_active_write(active);
            return queued_error_code(&fixture.gateway, key);
        }
        for _ in 0..writes_before_death {
            fixture.gateway.write_upstream();
        }
        fixture
            .upstream
            .shutdown(std::net::Shutdown::Both)
            .expect("simulate deterministic upstream shutdown");
        drop(fixture.upstream);
        for _ in 0..1_000 {
            match fixture.gateway.upstream_state {
                Some(UpstreamState::AwaitingReply(_)) => fixture.gateway.read_upstream(),
                _ => fixture.gateway.write_upstream(),
            }
            if fixture.gateway.clients[&key.fd].output.front().is_some() {
                return queued_error_code(&fixture.gateway, key);
            }
            std::thread::yield_now();
        }
        panic!("upstream death was not observed")
    }

    #[test]
    fn zero_byte_upstream_death_is_unavailable_without_retry() {
        assert_eq!(
            failed_dispatch_code(1, 0),
            SessionMessageErrorCode::UpstreamUnavailable
        );
    }

    #[test]
    fn partial_write_upstream_death_is_outcome_unknown_without_retry() {
        assert_eq!(
            failed_dispatch_code(1, 1),
            SessionMessageErrorCode::OutcomeUnknown
        );
    }

    #[test]
    fn full_write_upstream_death_is_outcome_unknown_without_retry() {
        assert_eq!(
            failed_dispatch_code(MAX_WIRE_FRAME_BYTES + LENGTH_PREFIX_BYTES, 1),
            SessionMessageErrorCode::OutcomeUnknown
        );
    }

    #[test]
    fn malformed_reply_becomes_outcome_unknown_and_disables_upstream() {
        let mut fixture = Fixture::new(MAX_WIRE_FRAME_BYTES + LENGTH_PREFIX_BYTES);
        let (_, key, _) = fixture.add_session(1);
        fixture
            .gateway
            .handle_client_frame(key, &request(1, 91), now());
        fixture.gateway.drive_dispatch();
        drive_full_write(&mut fixture.gateway);
        let _ = read_upstream_request(&mut fixture.upstream);
        send_frame(&mut fixture.upstream, br#"{"not":"a reply"}"#);
        fixture.gateway.read_upstream();
        assert_eq!(
            queued_error_code(&fixture.gateway, key),
            SessionMessageErrorCode::OutcomeUnknown
        );
        assert!(!fixture.gateway.upstream_available);
    }

    #[test]
    fn revoke_drains_late_reply_before_reusing_upstream() {
        let mut fixture = Fixture::new(MAX_WIRE_FRAME_BYTES + LENGTH_PREFIX_BYTES);
        let (_, old_key, binding) = fixture.add_session(1);
        fixture
            .gateway
            .handle_client_frame(old_key, &request(1, 11), now());
        fixture.gateway.drive_dispatch();
        drive_full_write(&mut fixture.gateway);
        let old_upstream = read_upstream_request(&mut fixture.upstream);
        fixture
            .gateway
            .revoke_session_after_durable_ack(
                &fixture.service,
                &binding,
                3,
                acknowledged_session_revocation(&binding, 3, GENERATION),
            )
            .unwrap();
        assert_eq!(
            fixture.gateway.stats().current_phase,
            Some(GatewayRequestPhase::DrainingRevokedReply)
        );
        let (_, new_key, _) = fixture.add_session(2);
        assert_ne!(old_key.incarnation, new_key.incarnation);
        write_upstream_error(&mut fixture.upstream, &old_upstream);
        fixture.gateway.read_upstream();
        assert!(fixture.gateway.clients[&new_key.fd].output.is_empty());
    }

    struct GateVerifier {
        entered: mpsc::SyncSender<()>,
        release: Mutex<mpsc::Receiver<()>>,
    }

    impl DesktopAdmissionVerifier for GateVerifier {
        fn verify(
            &self,
            _socket: BorrowedFd<'_>,
            _connection_id: AuthorityConnectionId,
            _broker_generation: NonZeroU64,
        ) -> Result<DesktopPeerAdmission, DesktopPeerVerificationError> {
            self.entered.send(()).unwrap();
            self.release.lock().unwrap().recv().unwrap();
            Err(DesktopPeerVerificationError::CodeIdentityRejected)
        }
    }

    #[test]
    fn five_second_security_stall_never_parses_on_reactor() {
        let directory = tempfile::tempdir().unwrap();
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let socket = directory.path().join("gateway.sock");
        let (gateway_upstream, _upstream) = UnixStream::pair().unwrap();
        let (entered_tx, entered_rx) = mpsc::sync_channel(1);
        let (release_tx, release_rx) = mpsc::sync_channel(1);
        let verifier = Arc::new(GateVerifier {
            entered: entered_tx,
            release: Mutex::new(release_rx),
        });
        let mut gateway = SessionMessageGateway::bind(
            SessionMessageGatewayConfig::new(&socket, nonzero(GENERATION)),
            unsafe { OwnedFd::from_raw_fd(gateway_upstream.into_raw_fd()) },
            verifier,
            None,
        )
        .unwrap();
        let mut client = UnixStream::connect(&socket).unwrap();
        send_frame(&mut client, b"not-json");
        gateway.tick(Duration::ZERO, now()).unwrap();
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let started = Instant::now();
        for _ in 0..20 {
            gateway.tick(Duration::ZERO, now()).unwrap();
        }
        assert!(started.elapsed() < Duration::from_millis(250));
        assert_eq!(gateway.transport.pending_count(), 0);
        assert_eq!(gateway.clients.len(), 0);
        release_tx.send(()).unwrap();
    }

    #[test]
    fn inherited_fd_python_upstream_is_stop_and_wait_and_remaps_id() {
        let mut fixture = Fixture::new(MAX_WIRE_FRAME_BYTES + LENGTH_PREFIX_BYTES);
        let (replacement, replacement_peer) = UnixStream::pair().unwrap();
        drop(replacement_peer);
        let child_upstream = std::mem::replace(&mut fixture.upstream, replacement);
        let child_fd = child_upstream.into_raw_fd();
        let script = r#"
import json, os, struct
def exact(n):
    out=b''
    while len(out)<n:
        chunk=os.read(3,n-len(out))
        if not chunk: raise SystemExit(2)
        out+=chunk
    return out
n=struct.unpack('>I',exact(4))[0]
req=json.loads(exact(n))
reply={'version':1,'broker_generation':req['broker_generation'],'id':req['id'],'error':'session_message_error','code':'upstream_unavailable','message':'python fixture'}
body=json.dumps(reply,separators=(',',':')).encode()
os.write(3,struct.pack('>I',len(body))+body)
"#;
        let mut command = Command::new("python3");
        command.args(["-u", "-c", script]);
        unsafe {
            command.pre_exec(move || {
                if child_fd != 3 && libc::dup2(child_fd, 3) < 0 {
                    return Err(io::Error::last_os_error());
                }
                let flags = libc::fcntl(3, libc::F_GETFD);
                if flags < 0 || libc::fcntl(3, libc::F_SETFD, flags & !libc::FD_CLOEXEC) < 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let mut child: Child = command.spawn().unwrap();
        unsafe { libc::close(child_fd) };
        let (mut client, key, _) = fixture.add_session(1);
        send_frame(&mut client, &request(1, 4_242));
        client.set_nonblocking(true).unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            fixture
                .gateway
                .tick(Duration::from_millis(1), now())
                .unwrap();
            if fixture.gateway.clients[&key.fd].output.is_empty() {
                assert!(Instant::now() < deadline, "Python upstream did not reply");
                continue;
            }
            fixture.gateway.write_client(key);
            break;
        }
        client.set_nonblocking(false).unwrap();
        let reply: SessionMessageErrorV1 =
            serde_json::from_slice(&read_frame(&mut client)).unwrap();
        assert_eq!(reply.id.get(), 4_242);
        assert!(child.wait().unwrap().success());
    }
}
