//! Bounded Phase-1 authority state for session messaging.
//!
//! This module does not open sockets or add a command to the terminal-control
//! protocol. Transport-specific code first authenticates a peer and constructs
//! one of the crate-private verified-peer capabilities below. The registry then
//! freezes the resulting principal onto exactly one connection. Neither an
//! authority epoch nor a request nonce is a bearer credential.

use crate::principal_binding_registration::{
    PrincipalBindingEnvelopeV1, VerifiedInstallationAuthorityV1,
};
use crate::session_message::{
    AuthoritativePrincipal, BoundedId, SessionCause, SessionMessageRequestV1,
    SessionMessageRequestV2, SessionMessageStatusRequestV1, Timestamp,
};
use std::collections::BTreeMap;
use std::fmt;
use std::num::NonZeroU64;

/// Hard ceiling for all desktop, session, and read-only client bindings.
pub const MAX_AUTHORITY_BINDINGS: usize = 256;
/// Hard ceiling for concurrently authenticated Ouroboros service connections.
pub const MAX_AUTHENTICATED_SERVICES: usize = 4;

/// Reactor-owned identity for one accepted connection. It is never read from
/// JSON and is meaningful only inside one broker generation.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct AuthorityConnectionId(NonZeroU64);

impl AuthorityConnectionId {
    pub fn new(value: NonZeroU64) -> Self {
        Self(value)
    }

    pub fn get(self) -> u64 {
        self.0.get()
    }
}

/// Exact, bounded connection identities invalidated by one registry mutation.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct AuthorityRevocations {
    connection_ids: Vec<AuthorityConnectionId>,
}

impl AuthorityRevocations {
    pub fn connection_ids(&self) -> &[AuthorityConnectionId] {
        &self.connection_ids
    }

    pub fn len(&self) -> usize {
        self.connection_ids.len()
    }

    pub fn is_empty(&self) -> bool {
        self.connection_ids.is_empty()
    }
}

/// The principal frozen onto one accepted client connection.
///
/// This type intentionally has no `Deserialize` implementation. Session source
/// identity can only enter through authenticated service registration.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ClientPrincipal {
    ReadOnlyUid {
        uid: u32,
    },
    SignedDesktop {
        uid: u32,
        binding_id: BoundedId,
        audit_identity_digest: [u8; 32],
        desktop_incarnation: [u8; 24],
        authority_epoch: u64,
    },
    OuroborosSession {
        uid: u32,
        binding_id: BoundedId,
        session_id: BoundedId,
        execution_id: BoundedId,
        scope_id: BoundedId,
        attempt_id: BoundedId,
        authority_epoch: u64,
        cause: Option<SessionCause>,
    },
}

impl ClientPrincipal {
    pub fn uid(&self) -> u32 {
        match self {
            Self::ReadOnlyUid { uid }
            | Self::SignedDesktop { uid, .. }
            | Self::OuroborosSession { uid, .. } => *uid,
        }
    }

    pub fn authority_epoch(&self) -> Option<u64> {
        match self {
            Self::ReadOnlyUid { .. } => None,
            Self::SignedDesktop {
                authority_epoch, ..
            }
            | Self::OuroborosSession {
                authority_epoch, ..
            } => Some(*authority_epoch),
        }
    }

    fn authoritative(&self) -> Option<AuthoritativePrincipal> {
        match self {
            Self::ReadOnlyUid { .. } => None,
            Self::SignedDesktop {
                uid,
                binding_id,
                audit_identity_digest,
                desktop_incarnation,
                authority_epoch,
            } => Some(AuthoritativePrincipal::SignedDesktop {
                uid: *uid,
                binding_id: binding_id.clone(),
                audit_identity_digest: *audit_identity_digest,
                desktop_incarnation: *desktop_incarnation,
                authority_epoch: *authority_epoch,
            }),
            Self::OuroborosSession {
                uid,
                binding_id,
                session_id,
                execution_id,
                scope_id,
                attempt_id,
                authority_epoch,
                cause,
            } => Some(AuthoritativePrincipal::OuroborosSession {
                uid: *uid,
                binding_id: binding_id.clone(),
                session_id: session_id.clone(),
                execution_id: execution_id.clone(),
                scope_id: scope_id.clone(),
                attempt_id: attempt_id.clone(),
                authority_epoch: *authority_epoch,
                cause: cause.clone(),
            }),
        }
    }

    fn binding_id(&self) -> Option<&BoundedId> {
        match self {
            Self::ReadOnlyUid { .. } => None,
            Self::SignedDesktop { binding_id, .. } | Self::OuroborosSession { binding_id, .. } => {
                Some(binding_id)
            }
        }
    }
}

/// Authenticated desktop fields supplied by transport verification, never by
/// the desktop's request body. The constructor is crate-private so an external
/// protocol consumer cannot manufacture this capability.
#[derive(Clone, Eq, PartialEq)]
pub struct VerifiedDesktopPeer {
    connection_id: AuthorityConnectionId,
    uid: u32,
    audit_identity_digest: [u8; 32],
    desktop_incarnation: [u8; 24],
    broker_generation: NonZeroU64,
}

impl VerifiedDesktopPeer {
    pub fn connection_id(&self) -> AuthorityConnectionId {
        self.connection_id
    }

    #[cfg(target_os = "macos")]
    pub(crate) fn from_code_identity_evidence(
        evidence: crate::desktop_peer_verifier::VerifiedDesktopEvidence,
    ) -> Self {
        let (connection_id, uid, audit_identity_digest, desktop_incarnation, broker_generation) =
            evidence.into_parts();
        Self {
            connection_id,
            uid,
            audit_identity_digest,
            desktop_incarnation,
            broker_generation,
        }
    }

    #[cfg(test)]
    pub(crate) fn from_verified_transport(
        connection_id: AuthorityConnectionId,
        uid: u32,
        audit_identity_digest: [u8; 32],
        desktop_incarnation: [u8; 24],
        broker_generation: NonZeroU64,
    ) -> Self {
        Self {
            connection_id,
            uid,
            audit_identity_digest,
            desktop_incarnation,
            broker_generation,
        }
    }
}

impl fmt::Debug for VerifiedDesktopPeer {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("VerifiedDesktopPeer")
            .field("connection_id", &self.connection_id)
            .field("identity", &"<redacted>")
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SignedDesktopAuthorityV1 {
    pub binding_id: BoundedId,
    pub authority_epoch: u64,
    pub expires_at: Timestamp,
}

/// Authenticated Ouroboros service fields supplied by reciprocal private-peer
/// verification. There is deliberately no pathname or bearer token here.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VerifiedOuroborosServicePeer {
    connection_id: AuthorityConnectionId,
    uid: u32,
    service_identity_digest: [u8; 32],
    service_incarnation: BoundedId,
    broker_generation: NonZeroU64,
}

impl VerifiedOuroborosServicePeer {
    pub fn connection_id(&self) -> AuthorityConnectionId {
        self.connection_id
    }

    #[cfg(test)]
    pub(crate) fn from_verified_transport(
        connection_id: AuthorityConnectionId,
        uid: u32,
        service_identity_digest: [u8; 32],
        service_incarnation: BoundedId,
        broker_generation: NonZeroU64,
    ) -> Self {
        Self {
            connection_id,
            uid,
            service_identity_digest,
            service_incarnation,
            broker_generation,
        }
    }
}

/// Opaque registration capability. A copied handle is useless after service
/// disconnect, re-admission, or broker restart because every mutation verifies
/// it against live bounded registry state.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthenticatedOuroborosService {
    connection_id: AuthorityConnectionId,
    admission_epoch: u64,
    broker_generation: NonZeroU64,
}

impl AuthenticatedOuroborosService {
    pub fn connection_id(&self) -> AuthorityConnectionId {
        self.connection_id
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RegisterSessionAuthorityV1 {
    pub binding_id: BoundedId,
    pub session_id: BoundedId,
    pub execution_id: BoundedId,
    pub scope_id: BoundedId,
    pub attempt_id: BoundedId,
    pub authority_epoch: u64,
    pub owner_incarnation: BoundedId,
    pub terminal_id: Option<BoundedId>,
    pub expires_at: Timestamp,
    pub cause: Option<SessionCause>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionBridgeRegistrationV1 {
    pub connection_id: AuthorityConnectionId,
    pub authority: RegisterSessionAuthorityV1,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ServiceRecord {
    uid: u32,
    identity_digest: [u8; 32],
    service_incarnation: BoundedId,
    admission_epoch: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ServiceKey {
    connection_id: AuthorityConnectionId,
    admission_epoch: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct BoundConnection {
    principal: ClientPrincipal,
    expires_at: Option<Timestamp>,
    owner_incarnation: Option<BoundedId>,
    terminal_id: Option<BoundedId>,
    registered_by: Option<ServiceKey>,
}

impl BoundConnection {
    fn is_expired(&self, now: Timestamp) -> bool {
        self.expires_at.is_some_and(|expires_at| expires_at <= now)
    }

    fn same_session_identity(&self, registration: &RegisterSessionAuthorityV1) -> bool {
        matches!(
            &self.principal,
            ClientPrincipal::OuroborosSession {
                session_id,
                execution_id,
                scope_id,
                attempt_id,
                ..
            } if session_id == &registration.session_id
                && execution_id == &registration.execution_id
                && scope_id == &registration.scope_id
                && attempt_id == &registration.attempt_id
        )
    }
}

/// Broker-owned, explicitly bounded authority registry.
///
/// The maps never exceed their public hard ceilings. Stored values contain
/// bounded semantic IDs and non-secret identity digests only; no socket path,
/// inherited descriptor token, credential, or message payload is retained.
#[derive(Debug)]
pub struct AuthorityRegistry {
    broker_generation: NonZeroU64,
    next_service_admission_epoch: u64,
    bindings: BTreeMap<AuthorityConnectionId, BoundConnection>,
    services: BTreeMap<AuthorityConnectionId, ServiceRecord>,
}

impl AuthorityRegistry {
    pub fn new(broker_generation: NonZeroU64) -> Self {
        Self {
            broker_generation,
            next_service_admission_epoch: 1,
            bindings: BTreeMap::new(),
            services: BTreeMap::new(),
        }
    }

    pub fn broker_generation(&self) -> NonZeroU64 {
        self.broker_generation
    }

    pub fn binding_count(&self) -> usize {
        self.bindings.len()
    }

    pub fn authenticated_service_count(&self) -> usize {
        self.services.len()
    }

    pub fn contains_connection(&self, connection_id: AuthorityConnectionId) -> bool {
        self.bindings.contains_key(&connection_id) || self.services.contains_key(&connection_id)
    }

    pub fn authenticated_service_uid(
        &self,
        service: &AuthenticatedOuroborosService,
    ) -> Result<u32, AuthorityRegistryError> {
        self.authenticated_service(service).map(|record| record.uid)
    }

    /// Prepare, but do not activate, a durable signed-desktop registration.
    ///
    /// The coordinator must first obtain a durable upstream acknowledgement
    /// and only then call `bind_signed_desktop`. A failure after the durable
    /// acknowledgement must be compensated with an exact revoke frame.
    pub fn prepare_signed_desktop_principal_registration(
        &self,
        peer: &VerifiedDesktopPeer,
        authority: &SignedDesktopAuthorityV1,
        policy: &VerifiedInstallationAuthorityV1,
        request_id: NonZeroU64,
        now: Timestamp,
    ) -> Result<PrincipalBindingEnvelopeV1, AuthorityRegistryError> {
        self.check_generation(peer.broker_generation)?;
        if authority.expires_at <= now {
            return Err(AuthorityRegistryError::Expired);
        }
        self.ensure_connection_available(peer.connection_id)?;
        self.ensure_binding_capacity(false)?;
        self.ensure_binding_id_available(&authority.binding_id, None)?;
        Ok(PrincipalBindingEnvelopeV1::signed_desktop(
            request_id,
            self.broker_generation,
            authority.binding_id.clone(),
            peer.uid,
            authority.authority_epoch,
            policy,
            peer.audit_identity_digest,
            peer.desktop_incarnation,
            authority.expires_at,
        ))
    }

    /// Prepare a durable session registration from one live authenticated
    /// service capability. No bridge connection is exposed by this operation;
    /// `register_session_authority` remains the post-ack activation step.
    pub fn prepare_session_principal_registration(
        &self,
        service: &AuthenticatedOuroborosService,
        registration: &SessionBridgeRegistrationV1,
        policy: &VerifiedInstallationAuthorityV1,
        request_id: NonZeroU64,
        now: Timestamp,
    ) -> Result<PrincipalBindingEnvelopeV1, AuthorityRegistryError> {
        let service_record = self.authenticated_service(service)?;
        if registration.authority.expires_at <= now {
            return Err(AuthorityRegistryError::Expired);
        }
        self.ensure_connection_available(registration.connection_id)?;
        Ok(PrincipalBindingEnvelopeV1::session(
            request_id,
            self.broker_generation,
            registration.authority.binding_id.clone(),
            service_record.uid,
            registration.authority.authority_epoch,
            policy,
            registration.authority.session_id.clone(),
            registration.authority.execution_id.clone(),
            registration.authority.scope_id.clone(),
            registration.authority.attempt_id.clone(),
            registration.authority.owner_incarnation.clone(),
            registration.authority.expires_at,
            registration.authority.cause.clone(),
        ))
    }

    /// Prepare a durable revoke before removing the local session binding.
    /// Only the exact service admission that installed the binding may do so.
    pub fn prepare_session_principal_revocation(
        &self,
        service: &AuthenticatedOuroborosService,
        binding_id: &BoundedId,
        authority_epoch: u64,
        request_id: NonZeroU64,
    ) -> Result<PrincipalBindingEnvelopeV1, AuthorityRegistryError> {
        self.authenticated_service(service)?;
        let service_key = ServiceKey {
            connection_id: service.connection_id,
            admission_epoch: service.admission_epoch,
        };
        let owned = self.bindings.values().any(|bound| {
            bound.registered_by.as_ref() == Some(&service_key)
                && matches!(
                    &bound.principal,
                    ClientPrincipal::OuroborosSession {
                        binding_id: current_binding_id,
                        authority_epoch: current_epoch,
                        ..
                    } if current_binding_id == binding_id && *current_epoch == authority_epoch
                )
        });
        if !owned {
            return Err(AuthorityRegistryError::Unauthorized);
        }
        Ok(PrincipalBindingEnvelopeV1::revoke(
            request_id,
            self.broker_generation,
            binding_id.clone(),
            authority_epoch,
        ))
    }

    /// Prepare a durable revoke before removing one verified desktop binding.
    pub fn prepare_signed_desktop_principal_revocation(
        &self,
        peer: &VerifiedDesktopPeer,
        request_id: NonZeroU64,
    ) -> Result<PrincipalBindingEnvelopeV1, AuthorityRegistryError> {
        self.check_generation(peer.broker_generation)?;
        let bound = self
            .bindings
            .get(&peer.connection_id)
            .ok_or(AuthorityRegistryError::Unauthenticated)?;
        let (binding_id, authority_epoch) = match &bound.principal {
            ClientPrincipal::SignedDesktop {
                uid,
                binding_id,
                audit_identity_digest,
                desktop_incarnation,
                authority_epoch,
            } if *uid == peer.uid
                && *audit_identity_digest == peer.audit_identity_digest
                && *desktop_incarnation == peer.desktop_incarnation =>
            {
                (binding_id.clone(), *authority_epoch)
            }
            _ => return Err(AuthorityRegistryError::Unauthorized),
        };
        Ok(PrincipalBindingEnvelopeV1::revoke(
            request_id,
            self.broker_generation,
            binding_id,
            authority_epoch,
        ))
    }

    /// Same-UID pathname clients enter only this non-authoritative state.
    pub fn bind_read_only_uid(
        &mut self,
        connection_id: AuthorityConnectionId,
        uid: u32,
    ) -> Result<(), AuthorityRegistryError> {
        self.ensure_connection_available(connection_id)?;
        self.ensure_binding_capacity(false)?;
        self.bindings.insert(
            connection_id,
            BoundConnection {
                principal: ClientPrincipal::ReadOnlyUid { uid },
                expires_at: None,
                owner_incarnation: None,
                terminal_id: None,
                registered_by: None,
            },
        );
        Ok(())
    }

    pub fn bind_signed_desktop(
        &mut self,
        peer: &VerifiedDesktopPeer,
        authority: SignedDesktopAuthorityV1,
        now: Timestamp,
    ) -> Result<(), AuthorityRegistryError> {
        self.check_generation(peer.broker_generation)?;
        if authority.expires_at <= now {
            return Err(AuthorityRegistryError::Expired);
        }
        self.ensure_connection_available(peer.connection_id)?;
        self.ensure_binding_capacity(false)?;
        self.ensure_binding_id_available(&authority.binding_id, None)?;

        self.bindings.insert(
            peer.connection_id,
            BoundConnection {
                principal: ClientPrincipal::SignedDesktop {
                    uid: peer.uid,
                    binding_id: authority.binding_id,
                    audit_identity_digest: peer.audit_identity_digest,
                    desktop_incarnation: peer.desktop_incarnation,
                    authority_epoch: authority.authority_epoch,
                },
                expires_at: Some(authority.expires_at),
                owner_incarnation: None,
                terminal_id: None,
                registered_by: None,
            },
        );
        Ok(())
    }

    /// Admit a reciprocally verified private Ouroboros service connection.
    /// Only the returned opaque capability can register or revoke sessions.
    pub fn admit_authenticated_service(
        &mut self,
        peer: VerifiedOuroborosServicePeer,
    ) -> Result<AuthenticatedOuroborosService, AuthorityRegistryError> {
        self.check_generation(peer.broker_generation)?;
        self.ensure_connection_available(peer.connection_id)?;
        if self.services.len() >= MAX_AUTHENTICATED_SERVICES {
            return Err(AuthorityRegistryError::ServiceCapacityExceeded);
        }

        let admission_epoch = self.next_service_admission_epoch;
        self.next_service_admission_epoch = admission_epoch
            .checked_add(1)
            .ok_or(AuthorityRegistryError::AdmissionEpochExhausted)?;
        self.services.insert(
            peer.connection_id,
            ServiceRecord {
                uid: peer.uid,
                identity_digest: peer.service_identity_digest,
                service_incarnation: peer.service_incarnation,
                admission_epoch,
            },
        );
        Ok(AuthenticatedOuroborosService {
            connection_id: peer.connection_id,
            admission_epoch,
            broker_generation: peer.broker_generation,
        })
    }

    /// Register an exact source session onto one inherited bridge connection.
    ///
    /// Re-registering the same exact source is allowed only for a different
    /// owner incarnation and a strictly newer authority epoch. That operation
    /// atomically removes the previous connection binding before installing
    /// the replacement; unrelated bindings remain untouched.
    pub fn register_session_authority(
        &mut self,
        service: &AuthenticatedOuroborosService,
        registration: SessionBridgeRegistrationV1,
        now: Timestamp,
    ) -> Result<(), AuthorityRegistryError> {
        self.register_session_authority_with_revocations(service, registration, now)
            .map(|_| ())
    }

    /// Register a bridge and return the exact older owner connection removed
    /// by replacement, if any.
    pub fn register_session_authority_with_revocations(
        &mut self,
        service: &AuthenticatedOuroborosService,
        registration: SessionBridgeRegistrationV1,
        now: Timestamp,
    ) -> Result<AuthorityRevocations, AuthorityRegistryError> {
        let service_record = self.authenticated_service(service)?.clone();
        if registration.authority.expires_at <= now {
            return Err(AuthorityRegistryError::Expired);
        }
        self.ensure_connection_available(registration.connection_id)?;

        let replaced_connection = self.bindings.iter().find_map(|(connection_id, bound)| {
            bound
                .same_session_identity(&registration.authority)
                .then_some((*connection_id, bound))
        });

        if let Some((old_connection_id, old)) = replaced_connection {
            if old.owner_incarnation.as_ref() == Some(&registration.authority.owner_incarnation) {
                return Err(AuthorityRegistryError::SourceAlreadyBound);
            }
            let old_epoch = old
                .principal
                .authority_epoch()
                .expect("session bindings always have an authority epoch");
            if registration.authority.authority_epoch <= old_epoch {
                return Err(AuthorityRegistryError::StaleAuthority);
            }
            self.ensure_binding_id_available(
                &registration.authority.binding_id,
                Some(old_connection_id),
            )?;
        } else {
            self.ensure_binding_capacity(false)?;
            self.ensure_binding_id_available(&registration.authority.binding_id, None)?;
        }

        let mut revocations = AuthorityRevocations::default();
        if let Some((old_connection_id, _)) = replaced_connection {
            self.bindings.remove(&old_connection_id);
            revocations.connection_ids.push(old_connection_id);
        }

        self.bindings.insert(
            registration.connection_id,
            BoundConnection {
                principal: ClientPrincipal::OuroborosSession {
                    uid: service_record.uid,
                    binding_id: registration.authority.binding_id,
                    session_id: registration.authority.session_id,
                    execution_id: registration.authority.execution_id,
                    scope_id: registration.authority.scope_id,
                    attempt_id: registration.authority.attempt_id,
                    authority_epoch: registration.authority.authority_epoch,
                    cause: registration.authority.cause,
                },
                expires_at: Some(registration.authority.expires_at),
                owner_incarnation: Some(registration.authority.owner_incarnation),
                terminal_id: registration.authority.terminal_id,
                registered_by: Some(ServiceKey {
                    connection_id: service.connection_id,
                    admission_epoch: service.admission_epoch,
                }),
            },
        );
        Ok(revocations)
    }

    /// Authenticated-service-only exact revocation. A stale epoch cannot revoke
    /// a replacement binding.
    pub fn revoke_session_authority(
        &mut self,
        service: &AuthenticatedOuroborosService,
        binding_id: &BoundedId,
        authority_epoch: u64,
    ) -> Result<bool, AuthorityRegistryError> {
        self.revoke_session_authority_with_revocations(service, binding_id, authority_epoch)
            .map(|revocations| !revocations.is_empty())
    }

    pub fn revoke_session_authority_with_revocations(
        &mut self,
        service: &AuthenticatedOuroborosService,
        binding_id: &BoundedId,
        authority_epoch: u64,
    ) -> Result<AuthorityRevocations, AuthorityRegistryError> {
        self.authenticated_service(service)?;
        let service_key = ServiceKey {
            connection_id: service.connection_id,
            admission_epoch: service.admission_epoch,
        };
        let candidate = self.bindings.iter().find_map(|(connection_id, bound)| {
            let matches = matches!(
                &bound.principal,
                ClientPrincipal::OuroborosSession {
                    binding_id: current_binding_id,
                    authority_epoch: current_epoch,
                    ..
                } if current_binding_id == binding_id && *current_epoch == authority_epoch
            ) && bound.registered_by.as_ref() == Some(&service_key);
            matches.then_some(*connection_id)
        });
        let mut revocations = AuthorityRevocations::default();
        if let Some(connection_id) = candidate {
            if self.bindings.remove(&connection_id).is_some() {
                revocations.connection_ids.push(connection_id);
            }
        }
        Ok(revocations)
    }

    /// Validate a closed wire request against the immutable connection
    /// principal. The returned principal is derived registry state, never a
    /// caller assertion.
    pub fn authorize_session_message(
        &mut self,
        connection_id: AuthorityConnectionId,
        request: &SessionMessageRequestV1,
        now: Timestamp,
    ) -> Result<AuthoritativePrincipal, AuthorityRegistryError> {
        self.authorize_session_message_fields(
            connection_id,
            request.broker_generation,
            request.authority_epoch,
            now,
        )
    }

    pub fn authorize_session_message_v2(
        &mut self,
        connection_id: AuthorityConnectionId,
        request: &SessionMessageRequestV2,
        now: Timestamp,
    ) -> Result<AuthoritativePrincipal, AuthorityRegistryError> {
        self.authorize_session_message_fields(
            connection_id,
            request.broker_generation,
            request.authority_epoch,
            now,
        )
    }

    /// Status is authorized by the same immutable connection principal,
    /// generation, and epoch. It accepts no source identity from the caller.
    pub fn authorize_session_message_status(
        &mut self,
        connection_id: AuthorityConnectionId,
        request: &SessionMessageStatusRequestV1,
        now: Timestamp,
    ) -> Result<AuthoritativePrincipal, AuthorityRegistryError> {
        self.authorize_session_message_fields(
            connection_id,
            request.broker_generation,
            request.authority_epoch,
            now,
        )
    }

    fn authorize_session_message_fields(
        &mut self,
        connection_id: AuthorityConnectionId,
        broker_generation: NonZeroU64,
        authority_epoch: u64,
        now: Timestamp,
    ) -> Result<AuthoritativePrincipal, AuthorityRegistryError> {
        self.check_generation(broker_generation)?;
        if self
            .bindings
            .get(&connection_id)
            .is_some_and(|bound| bound.is_expired(now))
        {
            self.bindings.remove(&connection_id);
            return Err(AuthorityRegistryError::Expired);
        }

        let bound = self
            .bindings
            .get(&connection_id)
            .ok_or(AuthorityRegistryError::Unauthenticated)?;
        let Some(principal) = bound.principal.authoritative() else {
            return Err(AuthorityRegistryError::Unauthorized);
        };
        if principal.authority_epoch() != authority_epoch {
            return Err(AuthorityRegistryError::StaleAuthority);
        }
        Ok(principal)
    }

    /// Revoke a disconnected client or service connection. Disconnecting a
    /// service also revokes only the session bindings admitted by that exact
    /// service admission epoch.
    pub fn disconnect(&mut self, connection_id: AuthorityConnectionId) -> usize {
        let was_service = self.services.contains_key(&connection_id);
        self.disconnect_with_revocations(connection_id)
            .len()
            .saturating_sub(usize::from(was_service))
    }

    pub fn disconnect_with_revocations(
        &mut self,
        connection_id: AuthorityConnectionId,
    ) -> AuthorityRevocations {
        let mut revocations = AuthorityRevocations::default();
        if self.bindings.remove(&connection_id).is_some() {
            revocations.connection_ids.push(connection_id);
        }
        if let Some(service) = self.services.remove(&connection_id) {
            revocations.connection_ids.push(connection_id);
            let service_key = ServiceKey {
                connection_id,
                admission_epoch: service.admission_epoch,
            };
            self.bindings.retain(|bound_connection_id, bound| {
                let keep = bound.registered_by.as_ref() != Some(&service_key);
                if !keep {
                    revocations.connection_ids.push(*bound_connection_id);
                }
                keep
            });
        }
        revocations
    }

    /// Remove expired elevated bindings without allocating a removal list.
    pub fn revoke_expired(&mut self, now: Timestamp) -> usize {
        self.revoke_expired_with_revocations(now).len()
    }

    pub fn revoke_expired_with_revocations(&mut self, now: Timestamp) -> AuthorityRevocations {
        let mut revocations = AuthorityRevocations::default();
        self.bindings.retain(|connection_id, bound| {
            let keep = !bound.is_expired(now);
            if !keep {
                revocations.connection_ids.push(*connection_id);
            }
            keep
        });
        revocations
    }

    /// Model a broker incarnation change. All connection and service
    /// capabilities are generation-local and are therefore discarded.
    pub fn restart(
        &mut self,
        new_broker_generation: NonZeroU64,
    ) -> Result<(), AuthorityRegistryError> {
        self.restart_with_revocations(new_broker_generation)
            .map(|_| ())
    }

    pub fn restart_with_revocations(
        &mut self,
        new_broker_generation: NonZeroU64,
    ) -> Result<AuthorityRevocations, AuthorityRegistryError> {
        if new_broker_generation == self.broker_generation {
            return Err(AuthorityRegistryError::StaleGeneration);
        }
        let mut connection_ids: Vec<_> = self.bindings.keys().copied().collect();
        connection_ids.extend(self.services.keys().copied());
        self.bindings.clear();
        self.services.clear();
        self.broker_generation = new_broker_generation;
        self.next_service_admission_epoch = 1;
        Ok(AuthorityRevocations { connection_ids })
    }

    pub fn principal(&self, connection_id: AuthorityConnectionId) -> Option<&ClientPrincipal> {
        self.bindings
            .get(&connection_id)
            .map(|bound| &bound.principal)
    }

    pub fn owner_incarnation(&self, connection_id: AuthorityConnectionId) -> Option<&BoundedId> {
        self.bindings
            .get(&connection_id)
            .and_then(|bound| bound.owner_incarnation.as_ref())
    }

    pub fn terminal_id(&self, connection_id: AuthorityConnectionId) -> Option<&BoundedId> {
        self.bindings
            .get(&connection_id)
            .and_then(|bound| bound.terminal_id.as_ref())
    }

    fn authenticated_service(
        &self,
        service: &AuthenticatedOuroborosService,
    ) -> Result<&ServiceRecord, AuthorityRegistryError> {
        self.check_generation(service.broker_generation)?;
        let record = self
            .services
            .get(&service.connection_id)
            .ok_or(AuthorityRegistryError::ServiceUnauthenticated)?;
        if record.admission_epoch != service.admission_epoch {
            return Err(AuthorityRegistryError::ServiceUnauthenticated);
        }
        Ok(record)
    }

    fn check_generation(&self, generation: NonZeroU64) -> Result<(), AuthorityRegistryError> {
        if generation != self.broker_generation {
            return Err(AuthorityRegistryError::StaleGeneration);
        }
        Ok(())
    }

    fn ensure_connection_available(
        &self,
        connection_id: AuthorityConnectionId,
    ) -> Result<(), AuthorityRegistryError> {
        if self.bindings.contains_key(&connection_id) || self.services.contains_key(&connection_id)
        {
            return Err(AuthorityRegistryError::ConnectionAlreadyBound);
        }
        Ok(())
    }

    fn ensure_binding_capacity(&self, replacing: bool) -> Result<(), AuthorityRegistryError> {
        if !replacing && self.bindings.len() >= MAX_AUTHORITY_BINDINGS {
            return Err(AuthorityRegistryError::BindingCapacityExceeded);
        }
        Ok(())
    }

    fn ensure_binding_id_available(
        &self,
        binding_id: &BoundedId,
        except_connection: Option<AuthorityConnectionId>,
    ) -> Result<(), AuthorityRegistryError> {
        let in_use = self.bindings.iter().any(|(connection_id, bound)| {
            Some(*connection_id) != except_connection
                && bound.principal.binding_id() == Some(binding_id)
        });
        if in_use {
            return Err(AuthorityRegistryError::BindingIdInUse);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AuthorityRegistryError {
    AdmissionEpochExhausted,
    BindingCapacityExceeded,
    BindingIdInUse,
    ConnectionAlreadyBound,
    Expired,
    ServiceCapacityExceeded,
    ServiceUnauthenticated,
    SourceAlreadyBound,
    StaleAuthority,
    StaleGeneration,
    Unauthenticated,
    Unauthorized,
}

impl fmt::Display for AuthorityRegistryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::AdmissionEpochExhausted => "service admission epoch exhausted",
            Self::BindingCapacityExceeded => "authority binding capacity exceeded",
            Self::BindingIdInUse => "authority binding identity is already in use",
            Self::ConnectionAlreadyBound => "connection already has an immutable binding",
            Self::Expired => "authority binding expired",
            Self::ServiceCapacityExceeded => "authenticated service capacity exceeded",
            Self::ServiceUnauthenticated => "Ouroboros service capability is not active",
            Self::SourceAlreadyBound => "exact source session is already bound to this owner",
            Self::StaleAuthority => "authority epoch is stale",
            Self::StaleGeneration => "broker generation is stale",
            Self::Unauthenticated => "connection has no authority binding",
            Self::Unauthorized => "connection principal is read-only",
        })
    }
}

impl std::error::Error for AuthorityRegistryError {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session_message::request_digest;
    use serde_json::{json, Value};

    const GENERATION: u64 = 873_421;

    fn generation(value: u64) -> NonZeroU64 {
        NonZeroU64::new(value).unwrap()
    }

    fn connection(value: u64) -> AuthorityConnectionId {
        AuthorityConnectionId::new(generation(value))
    }

    fn id(value: &str) -> BoundedId {
        BoundedId::try_from(value).unwrap()
    }

    fn timestamp(value: &str) -> Timestamp {
        Timestamp::parse(value).unwrap()
    }

    fn now() -> Timestamp {
        timestamp("2026-08-10T15:00:00Z")
    }

    fn expiry() -> Timestamp {
        timestamp("2026-08-10T15:02:00Z")
    }

    fn service_peer(connection_id: u64, incarnation: &str) -> VerifiedOuroborosServicePeer {
        VerifiedOuroborosServicePeer::from_verified_transport(
            connection(connection_id),
            501,
            [0x51; 32],
            id(incarnation),
            generation(GENERATION),
        )
    }

    fn session_registration(
        connection_id: u64,
        session: &str,
        attempt: &str,
        binding: &str,
        epoch: u64,
        owner: &str,
    ) -> SessionBridgeRegistrationV1 {
        SessionBridgeRegistrationV1 {
            connection_id: connection(connection_id),
            authority: RegisterSessionAuthorityV1 {
                binding_id: id(binding),
                session_id: id(session),
                execution_id: id("execution-1"),
                scope_id: id(&format!("scope-{session}")),
                attempt_id: id(attempt),
                authority_epoch: epoch,
                owner_incarnation: id(owner),
                terminal_id: Some(id(&format!("terminal-{session}"))),
                expires_at: expiry(),
                cause: None,
            },
        }
    }

    fn request(epoch: u64, broker_generation: u64) -> SessionMessageRequestV1 {
        serde_json::from_value(json!({
            "version": 1,
            "id": 42,
            "op": "session_message_resolve_and_admit",
            "broker_generation": broker_generation,
            "authority_epoch": epoch,
            "request_nonce": "EiQ2SFpscYKTpLXNZ2mr7A",
            "target_session_id": "session-target",
            "expected_execution_id": "execution-1",
            "expected_target_generation": 7,
            "mode": "after_turn",
            "message": "Re-check the reconnect boundary.",
            "reason": "Session A found a stale-owner race.",
            "expires_at": "2026-08-10T15:04:05Z",
            "correlation_id": "review-17"
        }))
        .unwrap()
    }

    #[test]
    fn read_only_and_connection_bindings_are_immutable() {
        let mut registry = AuthorityRegistry::new(generation(GENERATION));
        registry.bind_read_only_uid(connection(1), 501).unwrap();
        assert_eq!(
            registry.authorize_session_message(connection(1), &request(0, GENERATION), now()),
            Err(AuthorityRegistryError::Unauthorized)
        );
        assert_eq!(
            registry.bind_read_only_uid(connection(1), 501),
            Err(AuthorityRegistryError::ConnectionAlreadyBound)
        );

        let desktop = VerifiedDesktopPeer {
            connection_id: connection(1),
            uid: 501,
            audit_identity_digest: [0x44; 32],
            desktop_incarnation: [0x24; 24],
            broker_generation: generation(GENERATION),
        };
        assert_eq!(
            registry.bind_signed_desktop(
                &desktop,
                SignedDesktopAuthorityV1 {
                    binding_id: id("desktop-1"),
                    authority_epoch: 1,
                    expires_at: expiry(),
                },
                now()
            ),
            Err(AuthorityRegistryError::ConnectionAlreadyBound)
        );
    }

    #[test]
    fn copied_request_never_copies_connection_or_session_authority() {
        let mut registry = AuthorityRegistry::new(generation(GENERATION));
        let service = registry
            .admit_authenticated_service(service_peer(90, "service-1"))
            .unwrap();
        registry
            .register_session_authority(
                &service,
                session_registration(10, "session-a", "attempt-a", "binding-a", 3, "owner-a"),
                now(),
            )
            .unwrap();
        registry
            .register_session_authority(
                &service,
                session_registration(11, "session-b", "attempt-b", "binding-b", 8, "owner-b"),
                now(),
            )
            .unwrap();

        let copied = request(3, GENERATION);
        let source_a = registry
            .authorize_session_message(connection(10), &copied, now())
            .unwrap();
        assert_eq!(
            registry.authorize_session_message(connection(12), &copied, now()),
            Err(AuthorityRegistryError::Unauthenticated)
        );
        assert_eq!(
            registry.authorize_session_message(connection(11), &copied, now()),
            Err(AuthorityRegistryError::StaleAuthority)
        );

        let rebound_as_b = request(8, GENERATION);
        let source_b = registry
            .authorize_session_message(connection(11), &rebound_as_b, now())
            .unwrap();
        assert_ne!(source_a, source_b);
        assert_ne!(
            request_digest(&source_a, &copied).unwrap(),
            request_digest(&source_b, &rebound_as_b).unwrap()
        );
    }

    #[test]
    fn expiry_revokes_only_the_expired_binding() {
        let mut registry = AuthorityRegistry::new(generation(GENERATION));
        let service = registry
            .admit_authenticated_service(service_peer(90, "service-1"))
            .unwrap();
        let mut expired =
            session_registration(10, "session-a", "attempt-a", "binding-a", 3, "owner-a");
        expired.authority.expires_at = timestamp("2026-08-10T15:01:00Z");
        registry
            .register_session_authority(&service, expired, now())
            .unwrap();
        registry
            .register_session_authority(
                &service,
                session_registration(11, "session-b", "attempt-b", "binding-b", 8, "owner-b"),
                now(),
            )
            .unwrap();

        assert_eq!(
            registry.authorize_session_message(
                connection(10),
                &request(3, GENERATION),
                timestamp("2026-08-10T15:01:00Z")
            ),
            Err(AuthorityRegistryError::Expired)
        );
        assert!(registry
            .authorize_session_message(connection(11), &request(8, GENERATION), now())
            .is_ok());
        assert_eq!(registry.binding_count(), 1);
    }

    #[test]
    fn owner_replacement_revokes_old_connection_and_preserves_unrelated_binding() {
        let mut registry = AuthorityRegistry::new(generation(GENERATION));
        let service = registry
            .admit_authenticated_service(service_peer(90, "service-1"))
            .unwrap();
        registry
            .register_session_authority(
                &service,
                session_registration(10, "session-a", "attempt-a", "binding-a", 3, "owner-a1"),
                now(),
            )
            .unwrap();
        registry
            .register_session_authority(
                &service,
                session_registration(11, "session-b", "attempt-b", "binding-b", 4, "owner-b1"),
                now(),
            )
            .unwrap();

        assert_eq!(
            registry.register_session_authority(
                &service,
                session_registration(12, "session-a", "attempt-a", "binding-a2", 3, "owner-a2"),
                now()
            ),
            Err(AuthorityRegistryError::StaleAuthority)
        );
        registry
            .register_session_authority(
                &service,
                session_registration(12, "session-a", "attempt-a", "binding-a2", 5, "owner-a2"),
                now(),
            )
            .unwrap();

        assert_eq!(registry.principal(connection(10)), None);
        assert_eq!(
            registry.owner_incarnation(connection(12)),
            Some(&id("owner-a2"))
        );
        assert!(registry
            .authorize_session_message(connection(12), &request(5, GENERATION), now())
            .is_ok());
        assert!(registry
            .authorize_session_message(connection(11), &request(4, GENERATION), now())
            .is_ok());
        assert_eq!(registry.binding_count(), 2);
    }

    #[test]
    fn disconnect_and_service_replay_are_exactly_scoped() {
        let mut registry = AuthorityRegistry::new(generation(GENERATION));
        let service_a = registry
            .admit_authenticated_service(service_peer(90, "service-a"))
            .unwrap();
        let service_b = registry
            .admit_authenticated_service(service_peer(91, "service-b"))
            .unwrap();
        registry
            .register_session_authority(
                &service_a,
                session_registration(10, "session-a", "attempt-a", "binding-a", 3, "owner-a"),
                now(),
            )
            .unwrap();
        registry
            .register_session_authority(
                &service_b,
                session_registration(11, "session-b", "attempt-b", "binding-b", 4, "owner-b"),
                now(),
            )
            .unwrap();

        assert_eq!(registry.disconnect(connection(90)), 1);
        assert_eq!(
            registry.register_session_authority(
                &service_a,
                session_registration(12, "session-c", "attempt-c", "binding-c", 5, "owner-c"),
                now()
            ),
            Err(AuthorityRegistryError::ServiceUnauthenticated)
        );
        assert_eq!(registry.principal(connection(10)), None);
        assert!(registry
            .authorize_session_message(connection(11), &request(4, GENERATION), now())
            .is_ok());
    }

    #[test]
    fn restart_revokes_all_old_connections_handles_and_generations() {
        let mut registry = AuthorityRegistry::new(generation(GENERATION));
        let service = registry
            .admit_authenticated_service(service_peer(90, "service-1"))
            .unwrap();
        registry
            .register_session_authority(
                &service,
                session_registration(10, "session-a", "attempt-a", "binding-a", 3, "owner-a"),
                now(),
            )
            .unwrap();

        registry.restart(generation(GENERATION + 1)).unwrap();
        assert_eq!(registry.binding_count(), 0);
        assert_eq!(registry.authenticated_service_count(), 0);
        assert_eq!(
            registry.authorize_session_message(connection(10), &request(3, GENERATION), now()),
            Err(AuthorityRegistryError::StaleGeneration)
        );
        assert_eq!(
            registry.register_session_authority(
                &service,
                session_registration(11, "session-b", "attempt-b", "binding-b", 4, "owner-b"),
                now()
            ),
            Err(AuthorityRegistryError::StaleGeneration)
        );
    }

    #[test]
    fn authenticated_service_is_required_for_registration_and_revocation() {
        let mut registry = AuthorityRegistry::new(generation(GENERATION));
        let service = registry
            .admit_authenticated_service(service_peer(90, "service-1"))
            .unwrap();
        let copied = AuthenticatedOuroborosService {
            connection_id: connection(91),
            admission_epoch: service.admission_epoch,
            broker_generation: generation(GENERATION),
        };
        assert_eq!(
            registry.register_session_authority(
                &copied,
                session_registration(10, "session-a", "attempt-a", "binding-a", 3, "owner-a"),
                now()
            ),
            Err(AuthorityRegistryError::ServiceUnauthenticated)
        );
    }

    #[test]
    fn wire_request_rejects_every_caller_controlled_source_or_authority_field() {
        let canonical = serde_json::to_value(request(3, GENERATION)).unwrap();
        for (field, value) in [
            ("source", json!("user")),
            ("source_session_id", json!("session-a")),
            ("source_attempt_id", json!("attempt-a")),
            ("hop_count", json!(1)),
            ("authority_role", json!("session")),
        ] {
            let mut poisoned = canonical.clone();
            poisoned
                .as_object_mut()
                .unwrap()
                .insert(field.into(), value);
            assert!(
                serde_json::from_value::<SessionMessageRequestV1>(poisoned).is_err(),
                "caller authority field {field} must be rejected"
            );
        }

        let keys = canonical
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        assert!(!keys.iter().any(|key| {
            matches!(
                key.as_str(),
                "source"
                    | "source_session_id"
                    | "source_attempt_id"
                    | "hop_count"
                    | "authority_role"
            )
        }));
        let _: Value = canonical;
    }

    #[test]
    fn registry_capacity_is_hard_bounded() {
        let mut registry = AuthorityRegistry::new(generation(GENERATION));
        for value in 1..=MAX_AUTHORITY_BINDINGS as u64 {
            registry.bind_read_only_uid(connection(value), 501).unwrap();
        }
        assert_eq!(registry.binding_count(), MAX_AUTHORITY_BINDINGS);
        assert_eq!(
            registry.bind_read_only_uid(connection(MAX_AUTHORITY_BINDINGS as u64 + 1), 501),
            Err(AuthorityRegistryError::BindingCapacityExceeded)
        );
    }
}
