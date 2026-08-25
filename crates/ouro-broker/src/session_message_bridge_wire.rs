//! Closed wire codec between the broker reactor and the inherited-FD
//! Ouroboros persistence bridge.
//!
//! Request bodies never carry a source principal. Only an already-authorized
//! dispatch envelope can be encoded, and the binding identifier is injected
//! from registry-derived authority. Framing remains separate from the public
//! terminal-control protocol.

use crate::session_message::{
    ExactSessionIdentity, ExactSourceIdentity, SessionMessageErrorV1, SessionMessageReceiptV1,
    MAX_RECEIPT_BYTES, MAX_WIRE_FRAME_BYTES,
};
use crate::session_message_transport::{
    AdapterReply, AuthorizedDispatchEnvelope, AuthorizedDispatchRef, PendingRequestId,
};
use serde::Deserialize;
use serde_json::Value;
use std::fmt;
use std::num::NonZeroU64;

const LENGTH_PREFIX_BYTES: usize = 4;

pub struct BridgeDispatchFrame {
    pending_id: PendingRequestId,
    bridge_response_id: NonZeroU64,
    client_response_id: NonZeroU64,
    broker_generation: NonZeroU64,
    exact_target: Option<ExactSessionIdentity>,
    expected_source: ExpectedSourceIdentity,
    bytes: Vec<u8>,
}

impl fmt::Debug for BridgeDispatchFrame {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("BridgeDispatchFrame")
            .field("pending_id", &self.pending_id)
            .field("bridge_response_id", &self.bridge_response_id)
            .field("client_response_id", &self.client_response_id)
            .field("broker_generation", &self.broker_generation)
            .field("has_exact_target", &self.exact_target.is_some())
            .field("bytes", &"<redacted>")
            .finish()
    }
}

impl Drop for BridgeDispatchFrame {
    fn drop(&mut self) {
        self.bytes.fill(0);
    }
}

impl BridgeDispatchFrame {
    pub fn pending_id(&self) -> PendingRequestId {
        self.pending_id
    }

    pub fn bridge_response_id(&self) -> NonZeroU64 {
        self.bridge_response_id
    }

    pub fn client_response_id(&self) -> NonZeroU64 {
        self.client_response_id
    }

    pub fn broker_generation(&self) -> NonZeroU64 {
        self.broker_generation
    }

    /// Four-byte big-endian length followed by one closed JSON object.
    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }
}

pub fn encode_dispatch(
    envelope: &AuthorizedDispatchEnvelope,
) -> Result<BridgeDispatchFrame, BridgeWireError> {
    let (principal, request_value, client_response_id, broker_generation, exact_target) =
        match envelope.operation() {
            AuthorizedDispatchRef::ResolveAndAdmit(authorized) => (
                authorized.principal(),
                serde_json::to_value(authorized.request()).map_err(|_| BridgeWireError::Encode)?,
                authorized.request().id,
                authorized.request().broker_generation,
                None,
            ),
            AuthorizedDispatchRef::ExactResolveAndAdmit(authorized) => (
                authorized.principal(),
                serde_json::to_value(authorized.request()).map_err(|_| BridgeWireError::Encode)?,
                authorized.request().id,
                authorized.request().broker_generation,
                Some(authorized.request().target.clone()),
            ),
            AuthorizedDispatchRef::Status(authorized) => (
                authorized.principal(),
                serde_json::to_value(authorized.request()).map_err(|_| BridgeWireError::Encode)?,
                authorized.request().id,
                authorized.request().broker_generation,
                None,
            ),
        };
    let mut object = request_value
        .as_object()
        .cloned()
        .ok_or(BridgeWireError::Encode)?;
    if object
        .insert(
            "principal_binding_id".into(),
            Value::String(principal.binding_id().as_str().to_owned()),
        )
        .is_some()
    {
        return Err(BridgeWireError::AuthorityFieldCollision);
    }
    let bridge_response_id = NonZeroU64::new(envelope.pending_id().get())
        .expect("pending request identifiers are nonzero");
    object.insert(
        "id".into(),
        Value::Number(serde_json::Number::from(bridge_response_id.get())),
    );
    let payload = serde_json::to_vec(&object).map_err(|_| BridgeWireError::Encode)?;
    if payload.is_empty() || payload.len() > MAX_WIRE_FRAME_BYTES {
        return Err(BridgeWireError::FrameTooLarge);
    }
    let length = u32::try_from(payload.len()).map_err(|_| BridgeWireError::FrameTooLarge)?;
    let mut bytes = Vec::with_capacity(LENGTH_PREFIX_BYTES + payload.len());
    bytes.extend_from_slice(&length.to_be_bytes());
    bytes.extend_from_slice(&payload);
    Ok(BridgeDispatchFrame {
        pending_id: envelope.pending_id(),
        bridge_response_id,
        client_response_id,
        broker_generation,
        exact_target,
        expected_source: expected_source(principal),
        bytes,
    })
}

#[derive(Deserialize)]
#[serde(untagged)]
enum BridgeReply {
    Receipt(Box<SessionMessageReceiptV1>),
    Error(SessionMessageErrorV1),
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum ExpectedSourceIdentity {
    User {
        authority_epoch: u64,
    },
    Session {
        session_id: String,
        execution_id: String,
        scope_id: String,
        attempt_id: String,
    },
}

fn expected_source(
    principal: &crate::session_message::AuthoritativePrincipal,
) -> ExpectedSourceIdentity {
    match principal {
        crate::session_message::AuthoritativePrincipal::SignedDesktop {
            authority_epoch, ..
        } => ExpectedSourceIdentity::User {
            authority_epoch: *authority_epoch,
        },
        crate::session_message::AuthoritativePrincipal::OuroborosSession {
            session_id,
            execution_id,
            scope_id,
            attempt_id,
            ..
        } => ExpectedSourceIdentity::Session {
            session_id: session_id.as_str().to_owned(),
            execution_id: execution_id.as_str().to_owned(),
            scope_id: scope_id.as_str().to_owned(),
            attempt_id: attempt_id.as_str().to_owned(),
        },
    }
}

fn source_matches(expected: &ExpectedSourceIdentity, actual: &ExactSourceIdentity) -> bool {
    match (expected, actual) {
        (
            ExpectedSourceIdentity::User { authority_epoch },
            ExactSourceIdentity::User {
                authority_epoch: actual_epoch,
                ..
            },
        ) => authority_epoch == actual_epoch,
        (
            ExpectedSourceIdentity::Session {
                session_id,
                execution_id,
                scope_id,
                attempt_id,
            },
            ExactSourceIdentity::Session {
                session_id: actual_session,
                execution_id: actual_execution,
                scope_id: actual_scope,
                attempt_id: actual_attempt,
                ..
            },
        ) => {
            session_id == actual_session.as_str()
                && execution_id == actual_execution.as_str()
                && scope_id == actual_scope.as_str()
                && attempt_id == actual_attempt.as_str()
        }
        _ => false,
    }
}

pub fn decode_reply(
    expected: &BridgeDispatchFrame,
    payload: &[u8],
) -> Result<AdapterReply, BridgeWireError> {
    if payload.is_empty() {
        return Err(BridgeWireError::BadReply);
    }
    if payload.len() > MAX_RECEIPT_BYTES {
        return Err(BridgeWireError::ReplyTooLarge);
    }
    let reply: BridgeReply =
        serde_json::from_slice(payload).map_err(|_| BridgeWireError::BadReply)?;
    match reply {
        BridgeReply::Receipt(mut receipt) => {
            if receipt.id != expected.bridge_response_id
                || receipt.broker_generation != expected.broker_generation
            {
                return Err(BridgeWireError::ReplyIdentityMismatch);
            }
            receipt
                .validate()
                .map_err(|_| BridgeWireError::InvalidReceipt)?;
            if expected
                .exact_target
                .as_ref()
                .is_some_and(|target| target != &receipt.target)
            {
                return Err(BridgeWireError::TargetIdentityMismatch);
            }
            if !source_matches(&expected.expected_source, &receipt.source) {
                return Err(BridgeWireError::SourceIdentityMismatch);
            }
            receipt.id = expected.client_response_id;
            Ok(AdapterReply::Receipt(receipt))
        }
        BridgeReply::Error(mut error) => {
            if error.id != expected.bridge_response_id
                || error.broker_generation != expected.broker_generation
            {
                return Err(BridgeWireError::ReplyIdentityMismatch);
            }
            error.id = expected.client_response_id;
            Ok(AdapterReply::Error(error))
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BridgeWireError {
    Encode,
    AuthorityFieldCollision,
    FrameTooLarge,
    ReplyTooLarge,
    BadReply,
    ReplyIdentityMismatch,
    InvalidReceipt,
    TargetIdentityMismatch,
    SourceIdentityMismatch,
}

impl fmt::Display for BridgeWireError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Encode => "authorized bridge request could not be encoded",
            Self::AuthorityFieldCollision => "request attempted to supply bridge authority",
            Self::FrameTooLarge => "private bridge request exceeds its byte bound",
            Self::ReplyTooLarge => "private bridge reply exceeds its byte bound",
            Self::BadReply => "private bridge reply is not a closed protocol value",
            Self::ReplyIdentityMismatch => "private bridge reply identity does not match dispatch",
            Self::InvalidReceipt => "private bridge receipt violates its state contract",
            Self::TargetIdentityMismatch => {
                "private bridge receipt does not match the exact target attempt"
            }
            Self::SourceIdentityMismatch => {
                "private bridge receipt does not match the registry-derived source"
            }
        })
    }
}

impl std::error::Error for BridgeWireError {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::authority_registry::{
        AuthorityConnectionId, SignedDesktopAuthorityV1, VerifiedDesktopPeer,
    };
    use crate::session_message::{BoundedId, Timestamp};
    use crate::session_message_transport::SessionMessageTransport;

    const GENERATION: u64 = 873_421;

    fn authorized_dispatch() -> BridgeDispatchFrame {
        let generation = NonZeroU64::new(GENERATION).unwrap();
        let connection_id = AuthorityConnectionId::new(NonZeroU64::new(7).unwrap());
        let peer = VerifiedDesktopPeer::from_verified_transport(
            connection_id,
            501,
            [0x11; 32],
            [0x22; 24],
            generation,
        );
        let now = Timestamp::parse("2026-08-10T15:00:00Z").unwrap();
        let mut transport = SessionMessageTransport::new(generation);
        transport
            .bind_verified_signed_desktop(
                &peer,
                SignedDesktopAuthorityV1 {
                    binding_id: BoundedId::try_from("desktop-binding").unwrap(),
                    authority_epoch: 3,
                    expires_at: Timestamp::parse("2026-08-10T16:00:00Z").unwrap(),
                },
                now,
            )
            .unwrap();
        let request = br#"{"version":1,"id":42,"op":"session_message_resolve_and_admit","broker_generation":873421,"authority_epoch":3,"request_nonce":"EiQ2SFpscYKTpLXNZ2mr7A","target_session_id":"session-b","expected_execution_id":"execution-1","expected_target_generation":7,"mode":"after_turn","message":"Re-check the reconnect boundary.","reason":"Session A found a stale-owner race.","expires_at":"2026-08-10T15:04:05.000Z","correlation_id":"review-17"}"#;
        let pending = transport
            .prepare_resolve_and_admit_frame(connection_id, request, now)
            .unwrap();
        let envelope = transport.begin_dispatch(pending).unwrap();
        encode_dispatch(&envelope).unwrap()
    }

    fn exact_authorized_dispatch() -> BridgeDispatchFrame {
        let generation = NonZeroU64::new(GENERATION).unwrap();
        let connection_id = AuthorityConnectionId::new(NonZeroU64::new(8).unwrap());
        let peer = VerifiedDesktopPeer::from_verified_transport(
            connection_id,
            501,
            [0x11; 32],
            [0x22; 24],
            generation,
        );
        let now = Timestamp::parse("2026-08-10T15:00:00Z").unwrap();
        let mut transport = SessionMessageTransport::new(generation);
        transport
            .bind_verified_signed_desktop(
                &peer,
                SignedDesktopAuthorityV1 {
                    binding_id: BoundedId::try_from("desktop-binding").unwrap(),
                    authority_epoch: 3,
                    expires_at: Timestamp::parse("2026-08-10T16:00:00Z").unwrap(),
                },
                now,
            )
            .unwrap();
        let request = br#"{"version":2,"id":44,"op":"session_message_resolve_and_admit_exact","broker_generation":873421,"authority_epoch":3,"request_nonce":"EiQ2SFpscYKTpLXNZ2mr7A","target":{"session_id":"session-fanout","execution_id":"execution-1","scope_id":"scope-pane-b","attempt_id":"attempt-pane-b","generation":7},"mode":"after_turn","message":"Re-check pane B only.","reason":"Human steering from selected pane.","expires_at":"2026-08-10T15:04:05Z","correlation_id":"pane-b-review"}"#;
        let pending = transport
            .prepare_exact_resolve_and_admit_frame(connection_id, request, now)
            .unwrap();
        let envelope = transport.begin_dispatch(pending).unwrap();
        encode_dispatch(&envelope).unwrap()
    }

    #[test]
    fn encode_injects_only_registry_binding_into_flat_closed_envelope() {
        let encoded = authorized_dispatch();
        let length = u32::from_be_bytes(encoded.bytes()[..4].try_into().unwrap()) as usize;
        assert_eq!(length, encoded.bytes().len() - 4);
        let value: Value = serde_json::from_slice(&encoded.bytes()[4..]).unwrap();
        let object = value.as_object().unwrap();
        assert_eq!(object["principal_binding_id"], "desktop-binding");
        assert_eq!(object["op"], "session_message_resolve_and_admit");
        assert_eq!(object["id"], 1);
        assert_eq!(encoded.client_response_id().get(), 42);
        for forbidden in [
            "principal_binding",
            "source",
            "source_attempt_id",
            "target_attempt_id",
            "hop_count",
            "bearer",
        ] {
            assert!(!object.contains_key(forbidden), "unexpected {forbidden}");
        }
    }

    #[test]
    fn reply_must_match_exact_dispatch_identity() {
        let encoded = authorized_dispatch();
        let wrong = br#"{"version":1,"broker_generation":873421,"id":43,"error":"session_message_error","code":"upstream_unavailable","message":"Unavailable."}"#;
        assert_eq!(
            decode_reply(&encoded, wrong),
            Err(BridgeWireError::ReplyIdentityMismatch)
        );
        let exact = br#"{"version":1,"broker_generation":873421,"id":1,"error":"session_message_error","code":"upstream_unavailable","message":"Unavailable."}"#;
        let reply = decode_reply(&encoded, exact).unwrap();
        let AdapterReply::Error(error) = reply else {
            panic!("expected error reply")
        };
        assert_eq!(error.id.get(), 42);
    }

    #[test]
    fn exact_v2_receipt_cannot_switch_to_a_sibling_pane() {
        let encoded = exact_authorized_dispatch();
        let upstream: Value = serde_json::from_slice(&encoded.bytes()[4..]).unwrap();
        assert_eq!(upstream["principal_binding_id"], "desktop-binding");
        assert_eq!(upstream["target"]["attempt_id"], "attempt-pane-b");
        assert!(upstream.get("source").is_none());

        let sibling = br#"{"version":1,"broker_generation":873421,"id":1,"result":"session_message_receipt","request_nonce":"EiQ2SFpscYKTpLXNZ2mr7A","request_digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","signal_id":"signal-1","source":{"kind":"user","principal_id":"desktop-user","authority_epoch":3},"target":{"session_id":"session-fanout","execution_id":"execution-1","scope_id":"scope-pane-a","attempt_id":"attempt-pane-a","generation":7},"mode":"after_turn","state":"queued","durable_cursor":1,"application_proven":false,"replayed":false,"hop_count":0,"expires_at":"2026-08-10T15:04:05Z","reply_summary":null}"#;
        assert_eq!(
            decode_reply(&encoded, sibling),
            Err(BridgeWireError::TargetIdentityMismatch)
        );
    }

    #[test]
    fn exact_v2_receipt_cannot_switch_the_registry_derived_source() {
        let encoded = exact_authorized_dispatch();
        let wrong_source = br#"{"version":1,"broker_generation":873421,"id":1,"result":"session_message_receipt","request_nonce":"EiQ2SFpscYKTpLXNZ2mr7A","request_digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","signal_id":"signal-1","source":{"kind":"session","session_id":"session-a","execution_id":"execution-1","scope_id":"scope-a","attempt_id":"attempt-a","generation":4},"target":{"session_id":"session-fanout","execution_id":"execution-1","scope_id":"scope-pane-b","attempt_id":"attempt-pane-b","generation":7},"mode":"after_turn","state":"queued","durable_cursor":1,"application_proven":false,"replayed":false,"hop_count":0,"expires_at":"2026-08-10T15:04:05Z","reply_summary":null}"#;
        assert_eq!(
            decode_reply(&encoded, wrong_source),
            Err(BridgeWireError::SourceIdentityMismatch)
        );
    }

    #[test]
    fn oversized_or_open_replies_fail_closed() {
        let encoded = authorized_dispatch();
        assert_eq!(
            decode_reply(&encoded, &vec![b'x'; MAX_RECEIPT_BYTES + 1]),
            Err(BridgeWireError::ReplyTooLarge)
        );
        let open = br#"{"version":1,"broker_generation":873421,"id":1,"error":"session_message_error","code":"upstream_unavailable","message":"Unavailable.","source":{"kind":"user"}}"#;
        assert_eq!(decode_reply(&encoded, open), Err(BridgeWireError::BadReply));
    }
}
