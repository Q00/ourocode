//! Privileged persistence-registration values for RFC 0005 principals.
//!
//! These frames are never parsed from a terminal, desktop, or agent request.
//! The authority registry can construct them only after it has matched an
//! opaque verified peer/service capability to a live local binding. Workspace
//! and forest scope come from the installation-owned policy capability below,
//! not from request JSON.

use crate::session_message::{BoundedId, SessionCause, Timestamp, Version1, MAX_WIRE_FRAME_BYTES};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use serde::Serialize;
use std::num::NonZeroU64;

/// Installation-owned workspace/forest scope.
///
/// There is intentionally no public constructor and no `Deserialize`
/// implementation. The future installer/launch verifier must mint this value
/// after verifying its owned configuration. Until that verifier exists,
/// production registration therefore fails closed instead of accepting scope
/// strings from a client frame.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VerifiedInstallationAuthorityV1 {
    workspace_authority: BoundedId,
    forest_id: BoundedId,
}

impl VerifiedInstallationAuthorityV1 {
    pub fn workspace_authority(&self) -> &BoundedId {
        &self.workspace_authority
    }

    pub fn forest_id(&self) -> &BoundedId {
        &self.forest_id
    }

    /// Handoff reserved for the installation verifier inside this crate.
    #[allow(dead_code)] // Production caller lands with the installer verifier; no public fallback.
    pub(crate) fn from_verified_installation(
        workspace_authority: BoundedId,
        forest_id: BoundedId,
    ) -> Self {
        Self {
            workspace_authority,
            forest_id,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub enum PrincipalBindingOperationV1 {
    #[serde(rename = "principal_binding_register_desktop")]
    RegisterDesktop,
    #[serde(rename = "principal_binding_register_session")]
    RegisterSession,
    #[serde(rename = "principal_binding_revoke")]
    Revoke,
}

/// Flat, closed signed-desktop registration frame. Identity bytes are encoded
/// canonically for JSON only after kernel/code-signing verification.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct SignedDesktopBindingRegistrationV1 {
    version: Version1,
    id: NonZeroU64,
    op: PrincipalBindingOperationV1,
    broker_generation: NonZeroU64,
    binding_id: BoundedId,
    uid: u32,
    authority_epoch: u64,
    workspace_authority: BoundedId,
    forest_id: BoundedId,
    audit_identity_digest: String,
    desktop_incarnation: String,
    expires_at: Timestamp,
}

/// Flat, closed session registration frame. Source generation is deliberately
/// absent: Ouroboros derives it from the exact active-attempt guard while
/// checking owner/workspace/forest under the same write transaction.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct SessionBindingRegistrationV1 {
    version: Version1,
    id: NonZeroU64,
    op: PrincipalBindingOperationV1,
    broker_generation: NonZeroU64,
    binding_id: BoundedId,
    uid: u32,
    authority_epoch: u64,
    workspace_authority: BoundedId,
    forest_id: BoundedId,
    source_session_id: BoundedId,
    source_execution_id: BoundedId,
    source_scope_id: BoundedId,
    source_attempt_id: BoundedId,
    owner_incarnation: BoundedId,
    expires_at: Timestamp,
    cause_signal_id: Option<BoundedId>,
    cause_hop_count: Option<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct PrincipalBindingRevocationV1 {
    version: Version1,
    id: NonZeroU64,
    op: PrincipalBindingOperationV1,
    broker_generation: NonZeroU64,
    binding_id: BoundedId,
    authority_epoch: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(untagged)]
pub enum PrincipalBindingEnvelopeV1 {
    SignedDesktop(SignedDesktopBindingRegistrationV1),
    Session(SessionBindingRegistrationV1),
    Revoke(PrincipalBindingRevocationV1),
}

impl PrincipalBindingEnvelopeV1 {
    pub fn to_bounded_json(&self) -> Result<Vec<u8>, PrincipalBindingEnvelopeError> {
        let encoded = serde_json::to_vec(self).map_err(PrincipalBindingEnvelopeError::Serialize)?;
        if encoded.is_empty() || encoded.len() > MAX_WIRE_FRAME_BYTES {
            return Err(PrincipalBindingEnvelopeError::FrameTooLarge(encoded.len()));
        }
        Ok(encoded)
    }

    /// Identity the private persistence service must echo after durably
    /// committing this exact operation. Kept crate-private so callers cannot
    /// manufacture ACK expectations independently of a prepared registry
    /// operation.
    pub(crate) fn ack_identity(
        &self,
    ) -> (
        NonZeroU64,
        NonZeroU64,
        &BoundedId,
        u64,
        PrincipalBindingAcknowledgementKindV1,
    ) {
        match self {
            Self::SignedDesktop(frame) => (
                frame.id,
                frame.broker_generation,
                &frame.binding_id,
                frame.authority_epoch,
                PrincipalBindingAcknowledgementKindV1::Registered,
            ),
            Self::Session(frame) => (
                frame.id,
                frame.broker_generation,
                &frame.binding_id,
                frame.authority_epoch,
                PrincipalBindingAcknowledgementKindV1::Registered,
            ),
            Self::Revoke(frame) => (
                frame.id,
                frame.broker_generation,
                &frame.binding_id,
                frame.authority_epoch,
                PrincipalBindingAcknowledgementKindV1::Revoked,
            ),
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn signed_desktop(
        id: NonZeroU64,
        broker_generation: NonZeroU64,
        binding_id: BoundedId,
        uid: u32,
        authority_epoch: u64,
        policy: &VerifiedInstallationAuthorityV1,
        audit_identity_digest: [u8; 32],
        desktop_incarnation: [u8; 24],
        expires_at: Timestamp,
    ) -> Self {
        Self::SignedDesktop(SignedDesktopBindingRegistrationV1 {
            version: Version1,
            id,
            op: PrincipalBindingOperationV1::RegisterDesktop,
            broker_generation,
            binding_id,
            uid,
            authority_epoch,
            workspace_authority: policy.workspace_authority.clone(),
            forest_id: policy.forest_id.clone(),
            audit_identity_digest: URL_SAFE_NO_PAD.encode(audit_identity_digest),
            desktop_incarnation: URL_SAFE_NO_PAD.encode(desktop_incarnation),
            expires_at,
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn session(
        id: NonZeroU64,
        broker_generation: NonZeroU64,
        binding_id: BoundedId,
        uid: u32,
        authority_epoch: u64,
        policy: &VerifiedInstallationAuthorityV1,
        source_session_id: BoundedId,
        source_execution_id: BoundedId,
        source_scope_id: BoundedId,
        source_attempt_id: BoundedId,
        owner_incarnation: BoundedId,
        expires_at: Timestamp,
        cause: Option<SessionCause>,
    ) -> Self {
        let (cause_signal_id, cause_hop_count) = match cause {
            Some(cause) => (Some(cause.signal_id), Some(cause.hop_count)),
            None => (None, None),
        };
        Self::Session(SessionBindingRegistrationV1 {
            version: Version1,
            id,
            op: PrincipalBindingOperationV1::RegisterSession,
            broker_generation,
            binding_id,
            uid,
            authority_epoch,
            workspace_authority: policy.workspace_authority.clone(),
            forest_id: policy.forest_id.clone(),
            source_session_id,
            source_execution_id,
            source_scope_id,
            source_attempt_id,
            owner_incarnation,
            expires_at,
            cause_signal_id,
            cause_hop_count,
        })
    }

    pub(crate) fn revoke(
        id: NonZeroU64,
        broker_generation: NonZeroU64,
        binding_id: BoundedId,
        authority_epoch: u64,
    ) -> Self {
        Self::Revoke(PrincipalBindingRevocationV1 {
            version: Version1,
            id,
            op: PrincipalBindingOperationV1::Revoke,
            broker_generation,
            binding_id,
            authority_epoch,
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum PrincipalBindingAcknowledgementKindV1 {
    Registered,
    Revoked,
}

#[derive(Debug)]
pub enum PrincipalBindingEnvelopeError {
    FrameTooLarge(usize),
    Serialize(serde_json::Error),
}

impl std::fmt::Display for PrincipalBindingEnvelopeError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::FrameTooLarge(length) => {
                write!(
                    formatter,
                    "principal-binding frame exceeds its bound ({length} bytes)"
                )
            }
            Self::Serialize(_) => {
                formatter.write_str("principal-binding frame serialization failed")
            }
        }
    }
}

impl std::error::Error for PrincipalBindingEnvelopeError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Serialize(error) => Some(error),
            Self::FrameTooLarge(_) => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::authority_registry::{
        AuthorityConnectionId, AuthorityRegistry, AuthorityRegistryError,
        RegisterSessionAuthorityV1, SessionBridgeRegistrationV1, SignedDesktopAuthorityV1,
        VerifiedDesktopPeer, VerifiedOuroborosServicePeer,
    };
    use serde_json::Value;

    const GENERATION: u64 = 873_421;

    fn nonzero(value: u64) -> NonZeroU64 {
        NonZeroU64::new(value).unwrap()
    }

    fn id(value: &str) -> BoundedId {
        BoundedId::try_from(value).unwrap()
    }

    fn timestamp(value: &str) -> Timestamp {
        Timestamp::parse(value).unwrap()
    }

    fn connection(value: u64) -> AuthorityConnectionId {
        AuthorityConnectionId::new(nonzero(value))
    }

    fn vector() -> Value {
        serde_json::from_str(include_str!(
            "../../../docs/rfcs/fixtures/principal-binding-registration-v1-known-vector.json"
        ))
        .unwrap()
    }

    fn policy() -> VerifiedInstallationAuthorityV1 {
        let vector = vector();
        VerifiedInstallationAuthorityV1::from_verified_installation(
            id(vector["installation_policy"]["workspace_authority"]
                .as_str()
                .unwrap()),
            id(vector["installation_policy"]["forest_id"].as_str().unwrap()),
        )
    }

    #[test]
    fn verified_capabilities_reproduce_cross_language_vectors_before_activation() {
        let vector = vector();
        let now = timestamp("2026-08-10T15:00:00Z");
        let expiry = timestamp("2099-08-10T15:08:00Z");
        let mut registry = AuthorityRegistry::new(nonzero(GENERATION));

        let desktop_peer = VerifiedDesktopPeer::from_verified_transport(
            connection(10),
            501,
            [0x44; 32],
            [0x24; 24],
            nonzero(GENERATION),
        );
        let desktop_authority = SignedDesktopAuthorityV1 {
            binding_id: id("desktop-binding-1"),
            authority_epoch: 5,
            expires_at: expiry,
        };
        let desktop = registry
            .prepare_signed_desktop_principal_registration(
                &desktop_peer,
                &desktop_authority,
                &policy(),
                nonzero(7001),
                now,
            )
            .unwrap();
        assert_eq!(
            desktop.to_bounded_json().unwrap(),
            vector["desktop_register"]["canonical_json"]
                .as_str()
                .unwrap()
                .as_bytes()
        );
        assert!(!registry.contains_connection(connection(10)));

        let service_peer = VerifiedOuroborosServicePeer::from_verified_transport(
            connection(90),
            501,
            [0x51; 32],
            id("service-incarnation-1"),
            nonzero(GENERATION),
        );
        let service = registry.admit_authenticated_service(service_peer).unwrap();
        let registration = SessionBridgeRegistrationV1 {
            connection_id: connection(11),
            authority: RegisterSessionAuthorityV1 {
                binding_id: id("binding-a"),
                session_id: id("session-a"),
                execution_id: id("execution-1"),
                scope_id: id("scope-a"),
                attempt_id: id("attempt-a1"),
                authority_epoch: 3,
                owner_incarnation: id("owner-a"),
                terminal_id: Some(id("terminal-a")),
                expires_at: expiry,
                cause: None,
            },
        };
        let session = registry
            .prepare_session_principal_registration(
                &service,
                &registration,
                &policy(),
                nonzero(7002),
                now,
            )
            .unwrap();
        assert_eq!(
            session.to_bounded_json().unwrap(),
            vector["session_register"]["canonical_json"]
                .as_str()
                .unwrap()
                .as_bytes()
        );
        assert!(!registry.contains_connection(connection(11)));

        registry
            .register_session_authority(&service, registration, now)
            .unwrap();
        let revoke = registry
            .prepare_session_principal_revocation(&service, &id("binding-a"), 3, nonzero(7003))
            .unwrap();
        assert_eq!(
            revoke.to_bounded_json().unwrap(),
            vector["revoke"]["canonical_json"]
                .as_str()
                .unwrap()
                .as_bytes()
        );
    }

    #[test]
    fn another_authenticated_service_cannot_prepare_or_apply_revoke() {
        let now = timestamp("2026-08-10T15:00:00Z");
        let expiry = timestamp("2099-08-10T15:08:00Z");
        let mut registry = AuthorityRegistry::new(nonzero(GENERATION));
        let first = registry
            .admit_authenticated_service(VerifiedOuroborosServicePeer::from_verified_transport(
                connection(90),
                501,
                [0x51; 32],
                id("service-one"),
                nonzero(GENERATION),
            ))
            .unwrap();
        let second = registry
            .admit_authenticated_service(VerifiedOuroborosServicePeer::from_verified_transport(
                connection(91),
                501,
                [0x52; 32],
                id("service-two"),
                nonzero(GENERATION),
            ))
            .unwrap();
        registry
            .register_session_authority(
                &first,
                SessionBridgeRegistrationV1 {
                    connection_id: connection(11),
                    authority: RegisterSessionAuthorityV1 {
                        binding_id: id("binding-a"),
                        session_id: id("session-a"),
                        execution_id: id("execution-1"),
                        scope_id: id("scope-a"),
                        attempt_id: id("attempt-a1"),
                        authority_epoch: 3,
                        owner_incarnation: id("owner-a"),
                        terminal_id: None,
                        expires_at: expiry,
                        cause: None,
                    },
                },
                now,
            )
            .unwrap();

        assert_eq!(
            registry
                .prepare_session_principal_revocation(&second, &id("binding-a"), 3, nonzero(1),),
            Err(AuthorityRegistryError::Unauthorized)
        );
        assert!(!registry
            .revoke_session_authority(&second, &id("binding-a"), 3)
            .unwrap());
        assert!(registry.contains_connection(connection(11)));
    }
}
