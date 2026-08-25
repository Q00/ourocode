//! Pure, bounded state machine for authenticated session-message dispatch.
//!
//! This module owns the canonical authority registry but opens no socket and
//! invents no wire hello. Platform verification creates opaque capabilities;
//! request JSON can only select closed request fields, never its principal.

use crate::authority_registry::{
    AuthenticatedOuroborosService, AuthorityConnectionId, AuthorityRegistry,
    AuthorityRegistryError, AuthorityRevocations, SessionBridgeRegistrationV1,
    SignedDesktopAuthorityV1, VerifiedDesktopPeer, VerifiedOuroborosServicePeer,
};
use crate::session_message::{
    AuthoritativePrincipal, SessionMessageErrorV1, SessionMessageReceiptV1,
    SessionMessageRequestV1, SessionMessageRequestV2, SessionMessageStatusRequestV1, Timestamp,
    MAX_CLIENT_OUTPUT_QUEUE_BYTES, MAX_IN_FLIGHT_GLOBAL, MAX_IN_FLIGHT_PER_CLIENT,
    MAX_RECEIPT_BYTES, MAX_UPSTREAM_PENDING_BYTES, MAX_WIRE_FRAME_BYTES,
};
use std::collections::HashMap;
use std::fmt;
use std::num::NonZeroU64;

const LENGTH_PREFIX_BYTES: usize = 4;

/// Every upstream commit owns enough downstream capacity for the largest
/// legal length-prefixed reply. The reservation is deliberately based on the
/// protocol bound rather than the eventual serialized reply size: a slow or
/// adversarial client cannot make an already-committed mutation unreportable.
pub const CLIENT_EGRESS_RESERVATION_BYTES: usize = LENGTH_PREFIX_BYTES + MAX_RECEIPT_BYTES;
const _: () = assert!(CLIENT_EGRESS_RESERVATION_BYTES <= MAX_CLIENT_OUTPUT_QUEUE_BYTES);

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct PendingRequestId(NonZeroU64);

impl PendingRequestId {
    pub fn get(self) -> u64 {
        self.0.get()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionMessageTransportKind {
    PathnameReadOnlyUid,
    InheritedSocketpairSession,
    VerifiedSignedDesktop,
}

#[derive(Debug, Eq, PartialEq)]
pub enum AdapterReply {
    Receipt(Box<SessionMessageReceiptV1>),
    Error(SessionMessageErrorV1),
}

/// A completed reply that can only be created by this transport after an
/// authorized, egress-reserved dispatch. Moving this value into the client
/// queue preserves the reservation; inspecting the reply does not consume it.
pub struct AuthorizedClientEgress {
    reservation_id: PendingRequestId,
    connection_id: AuthorityConnectionId,
    reply: AdapterReply,
}

impl AuthorizedClientEgress {
    pub fn connection_id(&self) -> AuthorityConnectionId {
        self.connection_id
    }

    pub fn reply(&self) -> &AdapterReply {
        &self.reply
    }

    pub fn reserved_bytes(&self) -> usize {
        CLIENT_EGRESS_RESERVATION_BYTES
    }
}

/// Queue-owned form of an authorized reply. It must remain alive for partial
/// writes and may only be released after the complete frame was written. A
/// connection drain invalidates the underlying reservation instead.
pub struct QueuedClientEgress {
    reservation_id: PendingRequestId,
    connection_id: AuthorityConnectionId,
    reply: AdapterReply,
}

impl QueuedClientEgress {
    pub fn connection_id(&self) -> AuthorityConnectionId {
        self.connection_id
    }

    pub fn reply(&self) -> &AdapterReply {
        &self.reply
    }

    pub fn reserved_bytes(&self) -> usize {
        CLIENT_EGRESS_RESERVATION_BYTES
    }
}

/// Adapter input whose constructor is private to this state machine. The
/// principal is registry-derived and cannot be supplied by a caller frame.
pub struct AuthorizedResolveAndAdmit<'a> {
    principal: &'a AuthoritativePrincipal,
    request: &'a SessionMessageRequestV1,
}

/// Version-2 exact-target authorization. Like v1, its source principal is
/// immutable registry state and cannot come from the request body.
pub struct AuthorizedExactResolveAndAdmit<'a> {
    principal: &'a AuthoritativePrincipal,
    request: &'a SessionMessageRequestV2,
}

impl<'a> AuthorizedExactResolveAndAdmit<'a> {
    pub fn principal(&self) -> &'a AuthoritativePrincipal {
        self.principal
    }

    pub fn request(&self) -> &'a SessionMessageRequestV2 {
        self.request
    }
}

impl<'a> AuthorizedResolveAndAdmit<'a> {
    pub fn principal(&self) -> &'a AuthoritativePrincipal {
        self.principal
    }

    pub fn request(&self) -> &'a SessionMessageRequestV1 {
        self.request
    }
}

/// Status authorization carries the same immutable source principal and no
/// caller-controlled source fields.
pub struct AuthorizedStatus<'a> {
    principal: &'a AuthoritativePrincipal,
    request: &'a SessionMessageStatusRequestV1,
}

impl<'a> AuthorizedStatus<'a> {
    pub fn principal(&self) -> &'a AuthoritativePrincipal {
        self.principal
    }

    pub fn request(&self) -> &'a SessionMessageStatusRequestV1 {
        self.request
    }
}

/// Owning request handed to a non-blocking upstream driver. Its fields and
/// constructors are private, so only a registry-authorized prepared request
/// can become a dispatch envelope.
pub struct AuthorizedDispatchEnvelope {
    pending_id: PendingRequestId,
    operation: AuthorizedOperation,
}

impl AuthorizedDispatchEnvelope {
    pub fn pending_id(&self) -> PendingRequestId {
        self.pending_id
    }

    pub fn operation(&self) -> AuthorizedDispatchRef<'_> {
        match &self.operation {
            AuthorizedOperation::ResolveAndAdmit { principal, request } => {
                AuthorizedDispatchRef::ResolveAndAdmit(AuthorizedResolveAndAdmit {
                    principal,
                    request,
                })
            }
            AuthorizedOperation::ExactResolveAndAdmit { principal, request } => {
                AuthorizedDispatchRef::ExactResolveAndAdmit(AuthorizedExactResolveAndAdmit {
                    principal,
                    request,
                })
            }
            AuthorizedOperation::Status { principal, request } => {
                AuthorizedDispatchRef::Status(AuthorizedStatus { principal, request })
            }
        }
    }
}

pub enum AuthorizedDispatchRef<'a> {
    ResolveAndAdmit(AuthorizedResolveAndAdmit<'a>),
    ExactResolveAndAdmit(AuthorizedExactResolveAndAdmit<'a>),
    Status(AuthorizedStatus<'a>),
}

enum AuthorizedOperation {
    ResolveAndAdmit {
        principal: AuthoritativePrincipal,
        request: SessionMessageRequestV1,
    },
    ExactResolveAndAdmit {
        principal: AuthoritativePrincipal,
        request: SessionMessageRequestV2,
    },
    Status {
        principal: AuthoritativePrincipal,
        request: SessionMessageStatusRequestV1,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct PreparedRequest {
    connection_id: AuthorityConnectionId,
    operation: PreparedOperation,
    accounted_bytes: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum PreparedOperation {
    ResolveAndAdmit {
        principal: AuthoritativePrincipal,
        request: SessionMessageRequestV1,
    },
    ExactResolveAndAdmit {
        principal: AuthoritativePrincipal,
        request: SessionMessageRequestV2,
    },
    Status {
        principal: AuthoritativePrincipal,
        request: SessionMessageStatusRequestV1,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum PendingRequest {
    Prepared(Box<PreparedRequest>),
    Dispatched {
        connection_id: AuthorityConnectionId,
        accounted_bytes: usize,
    },
}

impl PendingRequest {
    fn connection_id(&self) -> AuthorityConnectionId {
        match self {
            Self::Prepared(prepared) => prepared.connection_id,
            Self::Dispatched { connection_id, .. } => *connection_id,
        }
    }

    fn accounted_bytes(&self) -> usize {
        match self {
            Self::Prepared(prepared) => prepared.accounted_bytes,
            Self::Dispatched {
                accounted_bytes, ..
            } => *accounted_bytes,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum EgressReservationPhase {
    Dispatching,
    Completed,
    Queued,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct EgressReservation {
    connection_id: AuthorityConnectionId,
    phase: EgressReservationPhase,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct DrainSummary {
    pub connections: usize,
    pub pending_requests: usize,
    pub pending_bytes: usize,
    pub egress_reservations: usize,
    pub egress_bytes: usize,
}

#[derive(Debug)]
pub struct SessionMessageTransport {
    authorities: AuthorityRegistry,
    transport_kinds: HashMap<AuthorityConnectionId, SessionMessageTransportKind>,
    pending: HashMap<PendingRequestId, PendingRequest>,
    pending_per_connection: HashMap<AuthorityConnectionId, usize>,
    pending_bytes: usize,
    egress_reservations: HashMap<PendingRequestId, EgressReservation>,
    egress_bytes_per_connection: HashMap<AuthorityConnectionId, usize>,
    egress_bytes: usize,
    next_pending_id: u64,
}

impl SessionMessageTransport {
    pub fn new(broker_generation: NonZeroU64) -> Self {
        Self {
            authorities: AuthorityRegistry::new(broker_generation),
            transport_kinds: HashMap::new(),
            pending: HashMap::new(),
            pending_per_connection: HashMap::new(),
            pending_bytes: 0,
            egress_reservations: HashMap::new(),
            egress_bytes_per_connection: HashMap::new(),
            egress_bytes: 0,
            next_pending_id: 1,
        }
    }

    /// Read-only access prevents registry mutation from bypassing drain.
    pub fn authorities(&self) -> &AuthorityRegistry {
        &self.authorities
    }

    pub fn transport_kind(
        &self,
        connection_id: AuthorityConnectionId,
    ) -> Option<SessionMessageTransportKind> {
        self.transport_kinds.get(&connection_id).copied()
    }

    pub fn pending_count(&self) -> usize {
        self.pending.len()
    }

    pub fn pending_bytes(&self) -> usize {
        self.pending_bytes
    }

    pub fn egress_reserved_bytes(&self) -> usize {
        self.egress_bytes
    }

    pub fn egress_reserved_bytes_for(&self, connection_id: AuthorityConnectionId) -> usize {
        self.egress_bytes_per_connection
            .get(&connection_id)
            .copied()
            .unwrap_or(0)
    }

    pub fn bind_pathname_read_only_uid(
        &mut self,
        connection_id: AuthorityConnectionId,
        kernel_uid: u32,
    ) -> Result<(), TransportError> {
        self.authorities
            .bind_read_only_uid(connection_id, kernel_uid)
            .map_err(TransportError::Authority)?;
        self.transport_kinds.insert(
            connection_id,
            SessionMessageTransportKind::PathnameReadOnlyUid,
        );
        Ok(())
    }

    pub fn bind_verified_signed_desktop(
        &mut self,
        peer: &VerifiedDesktopPeer,
        authority: SignedDesktopAuthorityV1,
        now: Timestamp,
    ) -> Result<(), TransportError> {
        self.authorities
            .bind_signed_desktop(peer, authority, now)
            .map_err(TransportError::Authority)?;
        self.transport_kinds.insert(
            peer.connection_id(),
            SessionMessageTransportKind::VerifiedSignedDesktop,
        );
        Ok(())
    }

    pub fn admit_authenticated_service(
        &mut self,
        peer: VerifiedOuroborosServicePeer,
    ) -> Result<AuthenticatedOuroborosService, TransportError> {
        self.authorities
            .admit_authenticated_service(peer)
            .map_err(TransportError::Authority)
    }

    pub fn register_session_authority(
        &mut self,
        service: &AuthenticatedOuroborosService,
        registration: SessionBridgeRegistrationV1,
        now: Timestamp,
    ) -> Result<DrainSummary, TransportError> {
        let connection_id = registration.connection_id;
        let revocations = self
            .authorities
            .register_session_authority_with_revocations(service, registration, now)
            .map_err(TransportError::Authority)?;
        let drained = self.apply_revocations(&revocations);
        self.transport_kinds.insert(
            connection_id,
            SessionMessageTransportKind::InheritedSocketpairSession,
        );
        Ok(drained)
    }

    pub fn revoke_session_authority(
        &mut self,
        service: &AuthenticatedOuroborosService,
        binding_id: &crate::session_message::BoundedId,
        authority_epoch: u64,
    ) -> Result<DrainSummary, TransportError> {
        let revocations = self
            .authorities
            .revoke_session_authority_with_revocations(service, binding_id, authority_epoch)
            .map_err(TransportError::Authority)?;
        Ok(self.apply_revocations(&revocations))
    }

    pub fn disconnect(&mut self, connection_id: AuthorityConnectionId) -> DrainSummary {
        let revocations = self.authorities.disconnect_with_revocations(connection_id);
        self.apply_revocations(&revocations)
    }

    pub fn revoke_expired(&mut self, now: Timestamp) -> DrainSummary {
        let revocations = self.authorities.revoke_expired_with_revocations(now);
        self.apply_revocations(&revocations)
    }

    pub fn restart(
        &mut self,
        broker_generation: NonZeroU64,
    ) -> Result<DrainSummary, TransportError> {
        let revocations = self
            .authorities
            .restart_with_revocations(broker_generation)
            .map_err(TransportError::Authority)?;
        Ok(self.apply_revocations(&revocations))
    }

    pub fn prepare_resolve_and_admit_frame(
        &mut self,
        connection_id: AuthorityConnectionId,
        frame: &[u8],
        now: Timestamp,
    ) -> Result<PendingRequestId, TransportError> {
        Self::check_frame_length(frame)?;
        let request: SessionMessageRequestV1 =
            serde_json::from_slice(frame).map_err(|_| TransportError::BadFrame)?;
        let principal =
            match self
                .authorities
                .authorize_session_message(connection_id, &request, now)
            {
                Ok(principal) => principal,
                Err(error) => return Err(self.map_authorization_error(connection_id, error)),
            };
        self.reserve(
            connection_id,
            frame.len(),
            PendingRequest::Prepared(Box::new(PreparedRequest {
                connection_id,
                operation: PreparedOperation::ResolveAndAdmit { principal, request },
                accounted_bytes: frame.len(),
            })),
        )
    }

    pub fn prepare_exact_resolve_and_admit_frame(
        &mut self,
        connection_id: AuthorityConnectionId,
        frame: &[u8],
        now: Timestamp,
    ) -> Result<PendingRequestId, TransportError> {
        Self::check_frame_length(frame)?;
        let request: SessionMessageRequestV2 =
            serde_json::from_slice(frame).map_err(|_| TransportError::BadFrame)?;
        request.validate().map_err(|_| TransportError::BadFrame)?;
        let principal =
            match self
                .authorities
                .authorize_session_message_v2(connection_id, &request, now)
            {
                Ok(principal) => principal,
                Err(error) => return Err(self.map_authorization_error(connection_id, error)),
            };
        self.reserve(
            connection_id,
            frame.len(),
            PendingRequest::Prepared(Box::new(PreparedRequest {
                connection_id,
                operation: PreparedOperation::ExactResolveAndAdmit { principal, request },
                accounted_bytes: frame.len(),
            })),
        )
    }

    pub fn prepare_status_frame(
        &mut self,
        connection_id: AuthorityConnectionId,
        frame: &[u8],
        now: Timestamp,
    ) -> Result<PendingRequestId, TransportError> {
        Self::check_frame_length(frame)?;
        let request: SessionMessageStatusRequestV1 =
            serde_json::from_slice(frame).map_err(|_| TransportError::BadFrame)?;
        let principal =
            match self
                .authorities
                .authorize_session_message_status(connection_id, &request, now)
            {
                Ok(principal) => principal,
                Err(error) => return Err(self.map_authorization_error(connection_id, error)),
            };
        self.reserve(
            connection_id,
            frame.len(),
            PendingRequest::Prepared(Box::new(PreparedRequest {
                connection_id,
                operation: PreparedOperation::Status { principal, request },
                accounted_bytes: frame.len(),
            })),
        )
    }

    /// Reserve a worst-case client reply before transferring an authorized
    /// request to the upstream driver. A capacity failure leaves the request
    /// prepared, so the caller cannot commit upstream without downstream
    /// space. In-flight request accounting remains held until completion,
    /// failure, cancellation, or authority drain; egress accounting lives
    /// until a full client write or connection drain.
    pub fn begin_dispatch(
        &mut self,
        pending_id: PendingRequestId,
    ) -> Result<AuthorizedDispatchEnvelope, TransportError> {
        let connection_id = match self.pending.get(&pending_id) {
            Some(PendingRequest::Prepared(prepared)) => prepared.connection_id,
            Some(PendingRequest::Dispatched { .. }) => {
                return Err(TransportError::AlreadyDispatched);
            }
            None => return Err(TransportError::PendingRequestNotFound),
        };
        self.reserve_egress(pending_id, connection_id)?;

        let pending = self
            .pending
            .remove(&pending_id)
            .expect("prepared request cannot disappear during dispatch");
        let prepared = match pending {
            PendingRequest::Prepared(prepared) => *prepared,
            PendingRequest::Dispatched { .. } => unreachable!("dispatch state checked above"),
        };
        let operation = match prepared.operation {
            PreparedOperation::ResolveAndAdmit { principal, request } => {
                AuthorizedOperation::ResolveAndAdmit { principal, request }
            }
            PreparedOperation::ExactResolveAndAdmit { principal, request } => {
                AuthorizedOperation::ExactResolveAndAdmit { principal, request }
            }
            PreparedOperation::Status { principal, request } => {
                AuthorizedOperation::Status { principal, request }
            }
        };
        self.pending.insert(
            pending_id,
            PendingRequest::Dispatched {
                connection_id: prepared.connection_id,
                accounted_bytes: prepared.accounted_bytes,
            },
        );
        Ok(AuthorizedDispatchEnvelope {
            pending_id,
            operation,
        })
    }

    /// Complete an upstream dispatch into a private-authorized egress value.
    /// There is intentionally no production API that returns a bare reply:
    /// the reservation must follow this value into the client queue.
    pub fn complete_dispatch(
        &mut self,
        pending_id: PendingRequestId,
        reply: AdapterReply,
    ) -> Result<AuthorizedClientEgress, TransportError> {
        let pending = self
            .pending
            .remove(&pending_id)
            .ok_or(TransportError::LateOrDuplicateCompletion)?;
        if matches!(pending, PendingRequest::Prepared(_)) {
            self.pending.insert(pending_id, pending);
            return Err(TransportError::NotDispatched);
        }
        let reservation = self
            .egress_reservations
            .get_mut(&pending_id)
            .expect("every dispatched request must own an egress reservation");
        if reservation.phase != EgressReservationPhase::Dispatching {
            self.pending.insert(pending_id, pending);
            return Err(TransportError::InvalidEgressState);
        }
        reservation.phase = EgressReservationPhase::Completed;
        let connection_id = reservation.connection_id;
        self.release_accounting(&pending);
        Ok(AuthorizedClientEgress {
            reservation_id: pending_id,
            connection_id,
            reply,
        })
    }

    /// Release a dispatched request with an already bounded protocol error.
    pub fn fail_dispatch(
        &mut self,
        pending_id: PendingRequestId,
        error: SessionMessageErrorV1,
    ) -> Result<AuthorizedClientEgress, TransportError> {
        self.complete_dispatch(pending_id, AdapterReply::Error(error))
    }

    /// Move a completed, authorized reply into the client output queue. The
    /// returned value owns the reply and its reservation for all partial
    /// writes; it must not be released until the complete frame is written.
    pub fn handoff_egress(
        &mut self,
        completed: AuthorizedClientEgress,
    ) -> Result<QueuedClientEgress, TransportError> {
        let reservation = self
            .egress_reservations
            .get_mut(&completed.reservation_id)
            .ok_or(TransportError::LateOrDuplicateEgress)?;
        if reservation.connection_id != completed.connection_id
            || reservation.phase != EgressReservationPhase::Completed
        {
            return Err(TransportError::InvalidEgressState);
        }
        reservation.phase = EgressReservationPhase::Queued;
        Ok(QueuedClientEgress {
            reservation_id: completed.reservation_id,
            connection_id: completed.connection_id,
            reply: completed.reply,
        })
    }

    /// Release queue memory only after the entire length-prefixed reply was
    /// written. Partial writes keep ownership of `queued` and must not call
    /// this method. A prior connection drain makes the token stale.
    pub fn release_fully_written_egress(
        &mut self,
        queued: QueuedClientEgress,
    ) -> Result<(), TransportError> {
        let reservation = self
            .egress_reservations
            .get(&queued.reservation_id)
            .copied()
            .ok_or(TransportError::LateOrDuplicateEgress)?;
        if reservation.connection_id != queued.connection_id
            || reservation.phase != EgressReservationPhase::Queued
        {
            return Err(TransportError::InvalidEgressState);
        }
        self.egress_reservations.remove(&queued.reservation_id);
        self.release_egress_accounting(queued.connection_id);
        Ok(())
    }

    pub fn cancel(&mut self, pending_id: PendingRequestId) -> bool {
        let Some(pending) = self.pending.remove(&pending_id) else {
            return false;
        };
        if matches!(pending, PendingRequest::Dispatched { .. }) {
            let reservation = self
                .egress_reservations
                .remove(&pending_id)
                .expect("every dispatched request must own an egress reservation");
            self.release_egress_accounting(reservation.connection_id);
        }
        self.release_accounting(&pending);
        true
    }

    fn check_frame_length(frame: &[u8]) -> Result<(), TransportError> {
        if frame.is_empty() {
            return Err(TransportError::BadFrame);
        }
        if frame.len() > MAX_WIRE_FRAME_BYTES {
            return Err(TransportError::FrameTooLarge);
        }
        Ok(())
    }

    fn map_authorization_error(
        &mut self,
        connection_id: AuthorityConnectionId,
        error: AuthorityRegistryError,
    ) -> TransportError {
        if error == AuthorityRegistryError::Expired {
            self.drain_connection_ids(&[connection_id]);
        }
        if error == AuthorityRegistryError::Unauthorized
            && self.transport_kind(connection_id)
                == Some(SessionMessageTransportKind::PathnameReadOnlyUid)
        {
            TransportError::ReadOnlyTransport
        } else {
            TransportError::Authority(error)
        }
    }

    fn reserve(
        &mut self,
        connection_id: AuthorityConnectionId,
        frame_bytes: usize,
        pending: PendingRequest,
    ) -> Result<PendingRequestId, TransportError> {
        if self.pending.len() >= MAX_IN_FLIGHT_GLOBAL {
            return Err(TransportError::GlobalInflightLimit);
        }
        let client_count = self
            .pending_per_connection
            .get(&connection_id)
            .copied()
            .unwrap_or(0);
        if client_count >= MAX_IN_FLIGHT_PER_CLIENT {
            return Err(TransportError::ClientInflightLimit);
        }
        if self
            .pending_bytes
            .checked_add(frame_bytes)
            .is_none_or(|total| total > MAX_UPSTREAM_PENDING_BYTES)
        {
            return Err(TransportError::PendingBytesLimit);
        }

        let pending_id = self.allocate_pending_id()?;
        self.pending.insert(pending_id, pending);
        self.pending_bytes += frame_bytes;
        self.pending_per_connection
            .insert(connection_id, client_count + 1);
        Ok(pending_id)
    }

    fn reserve_egress(
        &mut self,
        pending_id: PendingRequestId,
        connection_id: AuthorityConnectionId,
    ) -> Result<(), TransportError> {
        if self.egress_reservations.contains_key(&pending_id) {
            return Err(TransportError::InvalidEgressState);
        }
        let client_bytes = self
            .egress_bytes_per_connection
            .get(&connection_id)
            .copied()
            .unwrap_or(0);
        if client_bytes
            .checked_add(CLIENT_EGRESS_RESERVATION_BYTES)
            .is_none_or(|total| total > MAX_CLIENT_OUTPUT_QUEUE_BYTES)
        {
            return Err(TransportError::ClientEgressLimit);
        }
        self.egress_reservations.insert(
            pending_id,
            EgressReservation {
                connection_id,
                phase: EgressReservationPhase::Dispatching,
            },
        );
        self.egress_bytes = self
            .egress_bytes
            .checked_add(CLIENT_EGRESS_RESERVATION_BYTES)
            .expect("bounded egress accounting cannot overflow");
        self.egress_bytes_per_connection.insert(
            connection_id,
            client_bytes + CLIENT_EGRESS_RESERVATION_BYTES,
        );
        Ok(())
    }

    fn allocate_pending_id(&mut self) -> Result<PendingRequestId, TransportError> {
        for _ in 0..=(self.pending.len() + self.egress_reservations.len()) {
            let candidate = self.next_pending_id;
            self.next_pending_id = self.next_pending_id.checked_add(1).unwrap_or(1);
            if let Some(nonzero) = NonZeroU64::new(candidate) {
                let id = PendingRequestId(nonzero);
                if !self.pending.contains_key(&id) && !self.egress_reservations.contains_key(&id) {
                    return Ok(id);
                }
            }
        }
        Err(TransportError::PendingIdExhausted)
    }

    fn release_accounting(&mut self, pending: &PendingRequest) {
        self.pending_bytes = self
            .pending_bytes
            .checked_sub(pending.accounted_bytes())
            .expect("pending byte accounting must not underflow");
        let connection_id = pending.connection_id();
        if let Some(count) = self.pending_per_connection.get_mut(&connection_id) {
            *count -= 1;
            if *count == 0 {
                self.pending_per_connection.remove(&connection_id);
            }
        }
    }

    fn release_egress_accounting(&mut self, connection_id: AuthorityConnectionId) {
        self.egress_bytes = self
            .egress_bytes
            .checked_sub(CLIENT_EGRESS_RESERVATION_BYTES)
            .expect("egress byte accounting must not underflow");
        let client_bytes = self
            .egress_bytes_per_connection
            .get_mut(&connection_id)
            .expect("egress connection accounting must exist");
        *client_bytes = client_bytes
            .checked_sub(CLIENT_EGRESS_RESERVATION_BYTES)
            .expect("egress connection accounting must not underflow");
        if *client_bytes == 0 {
            self.egress_bytes_per_connection.remove(&connection_id);
        }
    }

    fn apply_revocations(&mut self, revocations: &AuthorityRevocations) -> DrainSummary {
        self.drain_connection_ids(revocations.connection_ids())
    }

    fn drain_connection_ids(&mut self, connection_ids: &[AuthorityConnectionId]) -> DrainSummary {
        if connection_ids.is_empty() {
            return DrainSummary::default();
        }
        let mut pending_requests = 0;
        let mut pending_bytes = 0;
        self.pending.retain(|_, pending| {
            if connection_ids.contains(&pending.connection_id()) {
                pending_requests += 1;
                pending_bytes += pending.accounted_bytes();
                false
            } else {
                true
            }
        });
        self.pending_bytes = self
            .pending_bytes
            .checked_sub(pending_bytes)
            .expect("drain byte accounting must not underflow");
        let mut egress_reservations = 0;
        let mut egress_bytes = 0;
        self.egress_reservations.retain(|_, reservation| {
            if connection_ids.contains(&reservation.connection_id) {
                egress_reservations += 1;
                egress_bytes += CLIENT_EGRESS_RESERVATION_BYTES;
                false
            } else {
                true
            }
        });
        self.egress_bytes = self
            .egress_bytes
            .checked_sub(egress_bytes)
            .expect("drain egress accounting must not underflow");
        for connection_id in connection_ids {
            self.pending_per_connection.remove(connection_id);
            self.egress_bytes_per_connection.remove(connection_id);
            self.transport_kinds.remove(connection_id);
        }
        DrainSummary {
            connections: connection_ids.len(),
            pending_requests,
            pending_bytes,
            egress_reservations,
            egress_bytes,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TransportError {
    BadFrame,
    FrameTooLarge,
    ReadOnlyTransport,
    GlobalInflightLimit,
    ClientInflightLimit,
    PendingBytesLimit,
    ClientEgressLimit,
    PendingRequestNotFound,
    AlreadyDispatched,
    NotDispatched,
    LateOrDuplicateCompletion,
    LateOrDuplicateEgress,
    InvalidEgressState,
    PendingIdExhausted,
    Authority(AuthorityRegistryError),
}

impl fmt::Display for TransportError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BadFrame => formatter.write_str("invalid session-message frame"),
            Self::FrameTooLarge => formatter.write_str("session-message frame exceeds its bound"),
            Self::ReadOnlyTransport => formatter.write_str("pathname UID transport is read-only"),
            Self::GlobalInflightLimit => {
                formatter.write_str("global in-flight request limit reached")
            }
            Self::ClientInflightLimit => {
                formatter.write_str("client in-flight request limit reached")
            }
            Self::PendingBytesLimit => {
                formatter.write_str("global pending request byte limit reached")
            }
            Self::ClientEgressLimit => {
                formatter.write_str("client output reservation limit reached")
            }
            Self::PendingRequestNotFound => formatter.write_str("pending request was not found"),
            Self::AlreadyDispatched => formatter.write_str("request is already dispatched"),
            Self::NotDispatched => formatter.write_str("request has not begun dispatch"),
            Self::LateOrDuplicateCompletion => {
                formatter.write_str("late or duplicate completion was ignored")
            }
            Self::LateOrDuplicateEgress => {
                formatter.write_str("late or duplicate client egress was ignored")
            }
            Self::InvalidEgressState => {
                formatter.write_str("client egress ownership is in an invalid state")
            }
            Self::PendingIdExhausted => {
                formatter.write_str("pending request identifiers are exhausted")
            }
            Self::Authority(error) => write!(formatter, "authority rejected request: {error}"),
        }
    }
}

impl std::error::Error for TransportError {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::authority_registry::{AuthorityConnectionId, RegisterSessionAuthorityV1};
    use crate::session_message::{
        BoundedErrorMessage, BoundedId, ErrorResult, SessionMessageErrorCode, Version1,
    };
    use serde_json::{json, Value};

    const GENERATION: u64 = 873_421;
    const UID: u32 = 501;

    fn nonzero(value: u64) -> NonZeroU64 {
        NonZeroU64::new(value).unwrap()
    }

    fn connection(value: u64) -> AuthorityConnectionId {
        AuthorityConnectionId::new(nonzero(value))
    }

    fn timestamp(value: &str) -> Timestamp {
        Timestamp::parse(value).unwrap()
    }

    fn now() -> Timestamp {
        timestamp("2026-08-10T15:00:00Z")
    }

    fn expiry() -> Timestamp {
        timestamp("2026-08-10T15:05:00Z")
    }

    fn request_json(id: u64) -> Vec<u8> {
        serde_json::to_vec(&json!({
            "version": 1,
            "id": id,
            "op": "session_message_resolve_and_admit",
            "broker_generation": GENERATION,
            "authority_epoch": 3,
            "request_nonce": "EiQ2SFpscYKTpLXNZ2mr7A",
            "target_session_id": "session-b",
            "expected_execution_id": null,
            "expected_target_generation": null,
            "mode": "after_turn",
            "message": "Check the owner boundary.",
            "reason": "The source found a race.",
            "expires_at": "2026-08-10T15:04:05Z",
            "correlation_id": null
        }))
        .unwrap()
    }

    fn request_json_with_epoch(id: u64, authority_epoch: u64) -> Vec<u8> {
        let mut request: Value = serde_json::from_slice(&request_json(id)).unwrap();
        request["authority_epoch"] = json!(authority_epoch);
        serde_json::to_vec(&request).unwrap()
    }

    fn exact_request_json(id: u64) -> Vec<u8> {
        serde_json::to_vec(&json!({
            "version": 2,
            "id": id,
            "op": "session_message_resolve_and_admit_exact",
            "broker_generation": GENERATION,
            "authority_epoch": 3,
            "request_nonce": "EiQ2SFpscYKTpLXNZ2mr7A",
            "target": {
                "session_id": "session-fanout",
                "execution_id": "execution-1",
                "scope_id": "scope-pane-b",
                "attempt_id": "attempt-pane-b",
                "generation": 7
            },
            "mode": "after_turn",
            "message": "Check pane B.",
            "reason": "Exact target fixture.",
            "expires_at": "2026-08-10T15:04:05Z",
            "correlation_id": null
        }))
        .unwrap()
    }

    fn status_json(id: u64) -> Vec<u8> {
        serde_json::to_vec(&json!({
            "version": 1,
            "id": id,
            "op": "session_message_status",
            "broker_generation": GENERATION,
            "authority_epoch": 3,
            "request_nonce": "EiQ2SFpscYKTpLXNZ2mr7A"
        }))
        .unwrap()
    }

    fn service_peer(connection_id: AuthorityConnectionId) -> VerifiedOuroborosServicePeer {
        VerifiedOuroborosServicePeer::from_verified_transport(
            connection_id,
            UID,
            [0x3c; 32],
            BoundedId::try_from("service-owner").unwrap(),
            nonzero(GENERATION),
        )
    }

    fn registration(
        connection_id: AuthorityConnectionId,
        session_index: u64,
        authority_epoch: u64,
        owner: &str,
        expires_at: Timestamp,
    ) -> SessionBridgeRegistrationV1 {
        SessionBridgeRegistrationV1 {
            connection_id,
            authority: RegisterSessionAuthorityV1 {
                binding_id: BoundedId::try_from(format!(
                    "binding-{session_index}-{authority_epoch}"
                ))
                .unwrap(),
                session_id: BoundedId::try_from(format!("session-{session_index}")).unwrap(),
                execution_id: BoundedId::try_from("execution-1").unwrap(),
                scope_id: BoundedId::try_from(format!("scope-{session_index}")).unwrap(),
                attempt_id: BoundedId::try_from(format!("attempt-{session_index}")).unwrap(),
                authority_epoch,
                owner_incarnation: BoundedId::try_from(owner).unwrap(),
                terminal_id: None,
                expires_at,
                cause: None,
            },
        }
    }

    fn admit_service(transport: &mut SessionMessageTransport) -> AuthenticatedOuroborosService {
        transport
            .admit_authenticated_service(service_peer(connection(9_000)))
            .unwrap()
    }

    fn register_session(
        transport: &mut SessionMessageTransport,
        service: &AuthenticatedOuroborosService,
        connection_id: AuthorityConnectionId,
        index: u64,
    ) {
        transport
            .register_session_authority(
                service,
                registration(connection_id, index, 3, "owner-a", expiry()),
                now(),
            )
            .unwrap();
    }

    fn error_value(id: NonZeroU64, code: SessionMessageErrorCode) -> SessionMessageErrorV1 {
        SessionMessageErrorV1 {
            version: Version1,
            broker_generation: nonzero(GENERATION),
            id,
            error: ErrorResult::SessionMessageError,
            code,
            message: BoundedErrorMessage::try_from("bounded fixture error").unwrap(),
        }
    }

    fn error_reply(id: NonZeroU64, code: SessionMessageErrorCode) -> AdapterReply {
        AdapterReply::Error(error_value(id, code))
    }

    #[test]
    fn public_mutation_shape_uses_only_opaque_verified_capabilities() {
        let _: fn(
            &mut SessionMessageTransport,
            &VerifiedDesktopPeer,
            SignedDesktopAuthorityV1,
            Timestamp,
        ) -> Result<(), TransportError> = SessionMessageTransport::bind_verified_signed_desktop;
        let _: fn(
            &mut SessionMessageTransport,
            VerifiedOuroborosServicePeer,
        ) -> Result<AuthenticatedOuroborosService, TransportError> =
            SessionMessageTransport::admit_authenticated_service;
        let _: fn(
            &mut SessionMessageTransport,
            &AuthenticatedOuroborosService,
            SessionBridgeRegistrationV1,
            Timestamp,
        ) -> Result<DrainSummary, TransportError> =
            SessionMessageTransport::register_session_authority;

        let mut transport = SessionMessageTransport::new(nonzero(GENERATION));
        let peer = VerifiedDesktopPeer::from_verified_transport(
            connection(77),
            UID,
            [0x5a; 32],
            [0xa5; 24],
            nonzero(GENERATION),
        );
        transport
            .bind_verified_signed_desktop(
                &peer,
                SignedDesktopAuthorityV1 {
                    binding_id: BoundedId::try_from("desktop-binding").unwrap(),
                    authority_epoch: 3,
                    expires_at: expiry(),
                },
                now(),
            )
            .unwrap();
        assert_eq!(
            transport.transport_kind(connection(77)),
            Some(SessionMessageTransportKind::VerifiedSignedDesktop)
        );
    }

    #[test]
    fn pathname_uid_is_read_only_and_caller_fields_are_closed() {
        let mut transport = SessionMessageTransport::new(nonzero(GENERATION));
        transport
            .bind_pathname_read_only_uid(connection(1), UID)
            .unwrap();
        assert_eq!(
            transport.prepare_resolve_and_admit_frame(connection(1), &request_json(1), now()),
            Err(TransportError::ReadOnlyTransport)
        );
        assert_eq!(
            transport.prepare_exact_resolve_and_admit_frame(
                connection(1),
                &exact_request_json(2),
                now()
            ),
            Err(TransportError::ReadOnlyTransport)
        );

        let service = admit_service(&mut transport);
        register_session(&mut transport, &service, connection(2), 2);
        for (field, value) in [
            ("source", json!("user")),
            ("source_session_id", json!("session-a")),
            ("hop_count", json!(1)),
            ("target_attempt_id", json!("attempt-b1")),
        ] {
            let mut request: Value = serde_json::from_slice(&request_json(2)).unwrap();
            request[field] = value;
            assert_eq!(
                transport.prepare_resolve_and_admit_frame(
                    connection(2),
                    &serde_json::to_vec(&request).unwrap(),
                    now()
                ),
                Err(TransportError::BadFrame)
            );
        }

        let mut forged_exact: Value = serde_json::from_slice(&exact_request_json(3)).unwrap();
        forged_exact["source"] = json!({"kind": "session", "attempt_id": "forged"});
        assert_eq!(
            transport.prepare_exact_resolve_and_admit_frame(
                connection(2),
                &serde_json::to_vec(&forged_exact).unwrap(),
                now()
            ),
            Err(TransportError::BadFrame)
        );
    }

    #[test]
    fn prepared_dispatch_complete_and_fail_keep_registry_derived_principal() {
        let mut transport = SessionMessageTransport::new(nonzero(GENERATION));
        let service = admit_service(&mut transport);
        register_session(&mut transport, &service, connection(1), 17);
        let request = transport
            .prepare_resolve_and_admit_frame(connection(1), &request_json(1), now())
            .unwrap();
        let status = transport
            .prepare_status_frame(connection(1), &status_json(2), now())
            .unwrap();
        let request_envelope = transport.begin_dispatch(request).unwrap();
        let AuthorizedDispatchRef::ResolveAndAdmit(authorized) = request_envelope.operation()
        else {
            panic!("resolve request must retain its operation kind");
        };
        assert!(matches!(
            authorized.principal(),
            AuthoritativePrincipal::OuroborosSession { session_id, .. }
                if session_id.as_str() == "session-17"
        ));
        assert_eq!(authorized.request().id.get(), 1);
        assert!(matches!(
            transport.begin_dispatch(request),
            Err(TransportError::AlreadyDispatched)
        ));
        assert_eq!(transport.pending_count(), 2);
        let completed = transport
            .complete_dispatch(
                request,
                error_reply(nonzero(1), SessionMessageErrorCode::TargetNotFound),
            )
            .unwrap();
        assert!(matches!(
            completed.reply(),
            AdapterReply::Error(SessionMessageErrorV1 {
                code: SessionMessageErrorCode::TargetNotFound,
                ..
            })
        ));
        assert_eq!(transport.pending_count(), 1);
        assert!(matches!(
            transport.complete_dispatch(
                request,
                error_reply(nonzero(1), SessionMessageErrorCode::Internal)
            ),
            Err(TransportError::LateOrDuplicateCompletion)
        ));
        let queued = transport.handoff_egress(completed).unwrap();
        transport.release_fully_written_egress(queued).unwrap();

        let status_envelope = transport.begin_dispatch(status).unwrap();
        let AuthorizedDispatchRef::Status(authorized) = status_envelope.operation() else {
            panic!("status request must retain its operation kind");
        };
        assert!(matches!(
            authorized.principal(),
            AuthoritativePrincipal::OuroborosSession { session_id, .. }
                if session_id.as_str() == "session-17"
        ));
        let completed = transport
            .fail_dispatch(
                status,
                error_value(nonzero(2), SessionMessageErrorCode::ReceiptNotFound),
            )
            .unwrap();
        assert!(matches!(
            completed.reply(),
            AdapterReply::Error(SessionMessageErrorV1 {
                code: SessionMessageErrorCode::ReceiptNotFound,
                ..
            })
        ));
        let queued = transport.handoff_egress(completed).unwrap();
        transport.release_fully_written_egress(queued).unwrap();
        assert_eq!(transport.pending_count(), 0);
        assert_eq!(transport.pending_bytes(), 0);
        assert_eq!(transport.egress_reserved_bytes(), 0);
    }

    #[test]
    fn dispatch_reserves_worst_case_egress_before_upstream_ownership() {
        assert_eq!(
            CLIENT_EGRESS_RESERVATION_BYTES,
            LENGTH_PREFIX_BYTES + MAX_RECEIPT_BYTES
        );
        let mut transport = SessionMessageTransport::new(nonzero(GENERATION));
        let service = admit_service(&mut transport);
        register_session(&mut transport, &service, connection(1), 1);
        let prepared = transport
            .prepare_resolve_and_admit_frame(connection(1), &request_json(1), now())
            .unwrap();
        assert_eq!(transport.egress_reserved_bytes(), 0);

        let _envelope = transport.begin_dispatch(prepared).unwrap();
        assert_eq!(
            transport.egress_reserved_bytes_for(connection(1)),
            CLIENT_EGRESS_RESERVATION_BYTES
        );
        assert!(transport.cancel(prepared));
        assert_eq!(transport.egress_reserved_bytes(), 0);

        let prepared = transport
            .prepare_status_frame(connection(1), &status_json(2), now())
            .unwrap();
        assert!(transport.cancel(prepared));
        assert_eq!(transport.egress_reserved_bytes(), 0);
    }

    #[test]
    fn completion_and_partial_queue_handoff_keep_egress_reserved_until_full_write() {
        let mut transport = SessionMessageTransport::new(nonzero(GENERATION));
        let service = admit_service(&mut transport);
        register_session(&mut transport, &service, connection(1), 1);
        let pending = transport
            .prepare_resolve_and_admit_frame(connection(1), &request_json(1), now())
            .unwrap();
        let _envelope = transport.begin_dispatch(pending).unwrap();

        let completed = transport
            .complete_dispatch(
                pending,
                error_reply(nonzero(1), SessionMessageErrorCode::TargetNotFound),
            )
            .unwrap();
        assert_eq!(transport.pending_count(), 0);
        assert_eq!(transport.pending_bytes(), 0);
        assert_eq!(
            transport.egress_reserved_bytes(),
            CLIENT_EGRESS_RESERVATION_BYTES
        );
        assert_eq!(completed.connection_id(), connection(1));
        assert_eq!(completed.reserved_bytes(), CLIENT_EGRESS_RESERVATION_BYTES);

        let queued = transport.handoff_egress(completed).unwrap();
        assert_eq!(queued.connection_id(), connection(1));
        assert_eq!(queued.reserved_bytes(), CLIENT_EGRESS_RESERVATION_BYTES);
        assert!(matches!(
            queued.reply(),
            AdapterReply::Error(SessionMessageErrorV1 {
                code: SessionMessageErrorCode::TargetNotFound,
                ..
            })
        ));
        assert_eq!(
            transport.egress_reserved_bytes(),
            CLIENT_EGRESS_RESERVATION_BYTES
        );

        // A reactor retains `queued` across any number of partial writes.
        // Only the explicit full-frame acknowledgement releases capacity.
        transport.release_fully_written_egress(queued).unwrap();
        assert_eq!(transport.egress_reserved_bytes(), 0);
    }

    #[test]
    fn held_replies_enforce_per_client_64k_without_blocking_other_clients() {
        let mut transport = SessionMessageTransport::new(nonzero(GENERATION));
        let service = admit_service(&mut transport);
        register_session(&mut transport, &service, connection(1), 1);
        register_session(&mut transport, &service, connection(2), 2);

        let mut held = Vec::new();
        for id in 1..=3 {
            let pending = transport
                .prepare_resolve_and_admit_frame(connection(1), &request_json(id), now())
                .unwrap();
            let _envelope = transport.begin_dispatch(pending).unwrap();
            let completed = transport
                .complete_dispatch(
                    pending,
                    error_reply(nonzero(id), SessionMessageErrorCode::TargetNotFound),
                )
                .unwrap();
            held.push(transport.handoff_egress(completed).unwrap());
        }
        assert_eq!(
            transport.egress_reserved_bytes_for(connection(1)),
            3 * CLIENT_EGRESS_RESERVATION_BYTES
        );

        let blocked = transport
            .prepare_resolve_and_admit_frame(connection(1), &request_json(4), now())
            .unwrap();
        assert!(matches!(
            transport.begin_dispatch(blocked),
            Err(TransportError::ClientEgressLimit)
        ));
        assert_eq!(transport.pending_count(), 1);

        let unrelated = transport
            .prepare_resolve_and_admit_frame(connection(2), &request_json(5), now())
            .unwrap();
        let _unrelated_envelope = transport.begin_dispatch(unrelated).unwrap();
        assert_eq!(
            transport.egress_reserved_bytes_for(connection(2)),
            CLIENT_EGRESS_RESERVATION_BYTES
        );
        assert!(transport.cancel(unrelated));

        transport
            .release_fully_written_egress(held.remove(0))
            .unwrap();
        let _retried_envelope = transport.begin_dispatch(blocked).unwrap();
        assert!(transport.cancel(blocked));
        for queued in held {
            transport.release_fully_written_egress(queued).unwrap();
        }
        assert_eq!(transport.egress_reserved_bytes(), 0);
    }

    #[test]
    fn pending_id_wrap_skips_queue_owned_egress_tokens() {
        let mut transport = SessionMessageTransport::new(nonzero(GENERATION));
        let service = admit_service(&mut transport);
        register_session(&mut transport, &service, connection(1), 1);
        register_session(&mut transport, &service, connection(2), 2);

        let mut held = Vec::new();
        for id in 1..=3 {
            let pending = transport
                .prepare_resolve_and_admit_frame(connection(1), &request_json(id), now())
                .unwrap();
            assert_eq!(pending.get(), id);
            let _envelope = transport.begin_dispatch(pending).unwrap();
            let completed = transport
                .complete_dispatch(
                    pending,
                    error_reply(nonzero(id), SessionMessageErrorCode::TargetNotFound),
                )
                .unwrap();
            held.push(transport.handoff_egress(completed).unwrap());
        }

        transport.next_pending_id = 1;
        let pending = transport
            .prepare_resolve_and_admit_frame(connection(2), &request_json(4), now())
            .unwrap();
        assert_eq!(pending.get(), 4);
        assert!(transport.cancel(pending));
        for queued in held {
            transport.release_fully_written_egress(queued).unwrap();
        }
    }

    #[test]
    fn connection_drain_releases_dispatching_completed_and_queued_reservations() {
        let mut transport = SessionMessageTransport::new(nonzero(GENERATION));
        let service = admit_service(&mut transport);
        register_session(&mut transport, &service, connection(1), 1);

        let queued_pending = transport
            .prepare_resolve_and_admit_frame(connection(1), &request_json(1), now())
            .unwrap();
        let _queued_envelope = transport.begin_dispatch(queued_pending).unwrap();
        let completed = transport
            .complete_dispatch(
                queued_pending,
                error_reply(nonzero(1), SessionMessageErrorCode::TargetNotFound),
            )
            .unwrap();
        let queued = transport.handoff_egress(completed).unwrap();

        let completed_pending = transport
            .prepare_resolve_and_admit_frame(connection(1), &request_json(2), now())
            .unwrap();
        let _completed_envelope = transport.begin_dispatch(completed_pending).unwrap();
        let completed = transport
            .complete_dispatch(
                completed_pending,
                error_reply(nonzero(2), SessionMessageErrorCode::TargetNotFound),
            )
            .unwrap();

        let dispatching = transport
            .prepare_resolve_and_admit_frame(connection(1), &request_json(3), now())
            .unwrap();
        let _dispatching_envelope = transport.begin_dispatch(dispatching).unwrap();
        assert_eq!(
            transport.egress_reserved_bytes_for(connection(1)),
            3 * CLIENT_EGRESS_RESERVATION_BYTES
        );

        let drained = transport.disconnect(connection(1));
        assert_eq!(drained.connections, 1);
        assert_eq!(drained.pending_requests, 1);
        assert_eq!(drained.egress_reservations, 3);
        assert_eq!(drained.egress_bytes, 3 * CLIENT_EGRESS_RESERVATION_BYTES);
        assert_eq!(transport.egress_reserved_bytes(), 0);
        assert!(matches!(
            transport.handoff_egress(completed),
            Err(TransportError::LateOrDuplicateEgress)
        ));
        assert!(matches!(
            transport.release_fully_written_egress(queued),
            Err(TransportError::LateOrDuplicateEgress)
        ));
        assert!(matches!(
            transport.complete_dispatch(
                dispatching,
                error_reply(nonzero(3), SessionMessageErrorCode::TargetNotFound)
            ),
            Err(TransportError::LateOrDuplicateCompletion)
        ));
    }

    #[test]
    fn backpressure_enforces_global_count_and_pending_bytes() {
        let mut transport = SessionMessageTransport::new(nonzero(GENERATION));
        let service = admit_service(&mut transport);
        for index in 1..=33 {
            register_session(&mut transport, &service, connection(index), index);
        }
        let mut dispatched = Vec::new();
        for index in 0..MAX_IN_FLIGHT_GLOBAL {
            let id = connection((index / MAX_IN_FLIGHT_PER_CLIENT + 1) as u64);
            let pending_id = transport
                .prepare_resolve_and_admit_frame(id, &request_json(index as u64 + 1), now())
                .unwrap();
            dispatched.push(transport.begin_dispatch(pending_id).unwrap());
        }
        assert_eq!(dispatched.len(), MAX_IN_FLIGHT_GLOBAL);
        assert_eq!(
            transport.prepare_resolve_and_admit_frame(connection(33), &request_json(65), now()),
            Err(TransportError::GlobalInflightLimit)
        );

        let mut transport = SessionMessageTransport::new(nonzero(GENERATION));
        let service = admit_service(&mut transport);
        for index in 1..=33 {
            register_session(&mut transport, &service, connection(index), index);
        }
        let mut padded = request_json(1);
        padded.resize(MAX_WIRE_FRAME_BYTES, b' ');
        let admitted = MAX_UPSTREAM_PENDING_BYTES / MAX_WIRE_FRAME_BYTES;
        let mut dispatched = Vec::new();
        for index in 0..admitted {
            let id = connection((index / MAX_IN_FLIGHT_PER_CLIENT + 1) as u64);
            let pending_id = transport
                .prepare_resolve_and_admit_frame(id, &padded, now())
                .unwrap();
            dispatched.push(transport.begin_dispatch(pending_id).unwrap());
        }
        assert_eq!(dispatched.len(), admitted);
        assert_eq!(transport.pending_bytes(), MAX_UPSTREAM_PENDING_BYTES);
        assert_eq!(
            transport.prepare_resolve_and_admit_frame(connection(33), &padded, now()),
            Err(TransportError::PendingBytesLimit)
        );
    }

    #[test]
    fn service_disconnect_drains_all_registered_bridge_pending() {
        let mut transport = SessionMessageTransport::new(nonzero(GENERATION));
        let service = admit_service(&mut transport);
        let mut first_pending = None;
        for index in 1..=2 {
            register_session(&mut transport, &service, connection(index), index);
            let pending_id = transport
                .prepare_resolve_and_admit_frame(connection(index), &request_json(index), now())
                .unwrap();
            if index == 1 {
                first_pending = Some(pending_id);
                let _envelope = transport.begin_dispatch(pending_id).unwrap();
            }
        }
        let drained = transport.disconnect(service.connection_id());
        assert_eq!(drained.connections, 3);
        assert_eq!(drained.pending_requests, 2);
        assert_eq!(drained.egress_reservations, 1);
        assert_eq!(drained.egress_bytes, CLIENT_EGRESS_RESERVATION_BYTES);
        assert_eq!(transport.pending_bytes(), 0);
        assert_eq!(transport.egress_reserved_bytes(), 0);
        assert!(matches!(
            transport.complete_dispatch(
                first_pending.unwrap(),
                error_reply(nonzero(1), SessionMessageErrorCode::TargetNotFound)
            ),
            Err(TransportError::LateOrDuplicateCompletion)
        ));
    }

    #[test]
    fn newer_owner_replacement_drains_old_but_not_new_or_unrelated() {
        let mut transport = SessionMessageTransport::new(nonzero(GENERATION));
        let service = admit_service(&mut transport);
        register_session(&mut transport, &service, connection(1), 1);
        register_session(&mut transport, &service, connection(2), 2);
        let old_pending = transport
            .prepare_resolve_and_admit_frame(connection(1), &request_json(1), now())
            .unwrap();
        let _old_envelope = transport.begin_dispatch(old_pending).unwrap();
        let unrelated = transport
            .prepare_resolve_and_admit_frame(connection(2), &request_json(2), now())
            .unwrap();

        let drained = transport
            .register_session_authority(
                &service,
                registration(connection(3), 1, 4, "owner-b", expiry()),
                now(),
            )
            .unwrap();
        assert_eq!(drained.connections, 1);
        assert_eq!(drained.pending_requests, 1);
        assert_eq!(drained.egress_reservations, 1);
        assert_eq!(drained.egress_bytes, CLIENT_EGRESS_RESERVATION_BYTES);
        assert!(!transport.cancel(old_pending));
        assert!(transport.cancel(unrelated));
        let new_pending = transport
            .prepare_resolve_and_admit_frame(connection(3), &request_json_with_epoch(3, 4), now())
            .unwrap();
        assert!(transport.cancel(new_pending));
    }

    #[test]
    fn explicit_revoke_expiry_and_restart_drain_exact_pending() {
        let mut transport = SessionMessageTransport::new(nonzero(GENERATION));
        let service = admit_service(&mut transport);
        register_session(&mut transport, &service, connection(1), 1);
        let explicit = transport
            .prepare_resolve_and_admit_frame(connection(1), &request_json(1), now())
            .unwrap();
        let _explicit_envelope = transport.begin_dispatch(explicit).unwrap();
        let drained = transport
            .revoke_session_authority(&service, &BoundedId::try_from("binding-1-3").unwrap(), 3)
            .unwrap();
        assert_eq!(drained.pending_requests, 1);
        assert_eq!(drained.egress_reservations, 1);
        assert!(!transport.cancel(explicit));

        transport
            .register_session_authority(
                &service,
                registration(
                    connection(2),
                    2,
                    3,
                    "owner-a",
                    timestamp("2026-08-10T15:01:00Z"),
                ),
                now(),
            )
            .unwrap();
        transport
            .prepare_resolve_and_admit_frame(connection(2), &request_json(2), now())
            .unwrap();
        let expired = transport.revoke_expired(timestamp("2026-08-10T15:01:00Z"));
        assert_eq!(expired.pending_requests, 1);
        assert_eq!(expired.egress_reservations, 0);

        register_session(&mut transport, &service, connection(3), 3);
        let restart_pending = transport
            .prepare_status_frame(connection(3), &status_json(3), now())
            .unwrap();
        let _restart_envelope = transport.begin_dispatch(restart_pending).unwrap();
        let restarted = transport.restart(nonzero(GENERATION + 1)).unwrap();
        assert_eq!(restarted.pending_requests, 1);
        assert_eq!(restarted.egress_reservations, 1);
        assert!(transport.authorities().binding_count() == 0);
        assert_eq!(transport.pending_bytes(), 0);
        assert_eq!(transport.egress_reserved_bytes(), 0);
    }
}
