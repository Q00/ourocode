//! Closed durable-acknowledgement codec for principal registration.
//!
//! This protocol is carried only by the inherited privileged registration
//! descriptor. It is intentionally unrelated to terminal control, public MCP
//! HTTP, and the session-message bridge. A durable token can be minted only by
//! decoding an ACK against an expectation derived from a prepared registration
//! envelope.

use crate::principal_binding_registration::{
    PrincipalBindingAcknowledgementKindV1, PrincipalBindingEnvelopeError,
    PrincipalBindingEnvelopeV1,
};
use crate::session_message::{BoundedId, Version1, MAX_WIRE_FRAME_BYTES};
use serde::{Deserialize, Serialize};
use std::fmt;
use std::num::NonZeroU64;

const LENGTH_PREFIX_BYTES: usize = 4;
pub const MAX_PRINCIPAL_BINDING_ACK_BYTES: usize = MAX_WIRE_FRAME_BYTES;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum PrincipalBindingAckResultV1 {
    #[serde(rename = "principal_binding_registered")]
    Registered,
    #[serde(rename = "principal_binding_revoked")]
    Revoked,
}

impl From<PrincipalBindingAcknowledgementKindV1> for PrincipalBindingAckResultV1 {
    fn from(value: PrincipalBindingAcknowledgementKindV1) -> Self {
        match value {
            PrincipalBindingAcknowledgementKindV1::Registered => Self::Registered,
            PrincipalBindingAcknowledgementKindV1::Revoked => Self::Revoked,
        }
    }
}

/// Exact identity expected from the durable service for one prepared frame.
/// There is no public constructor; the registration envelope is the authority
/// for every field.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PrincipalBindingAckExpectationV1 {
    request_id: NonZeroU64,
    broker_generation: NonZeroU64,
    binding_id: BoundedId,
    authority_epoch: u64,
    result: PrincipalBindingAckResultV1,
}

impl PrincipalBindingAckExpectationV1 {
    pub fn request_id(&self) -> NonZeroU64 {
        self.request_id
    }

    pub fn broker_generation(&self) -> NonZeroU64 {
        self.broker_generation
    }

    pub fn binding_id(&self) -> &BoundedId {
        &self.binding_id
    }

    pub fn authority_epoch(&self) -> u64 {
        self.authority_epoch
    }

    pub fn result(&self) -> PrincipalBindingAckResultV1 {
        self.result
    }

    pub(crate) fn from_envelope(envelope: &PrincipalBindingEnvelopeV1) -> Self {
        let (request_id, broker_generation, binding_id, authority_epoch, result) =
            envelope.ack_identity();
        Self {
            request_id,
            broker_generation,
            binding_id: binding_id.clone(),
            authority_epoch,
            result: result.into(),
        }
    }
}

/// Length-prefixed registration frame paired with its unforgeable expectation.
pub struct PrincipalBindingDispatchFrameV1 {
    expectation: PrincipalBindingAckExpectationV1,
    bytes: Vec<u8>,
}

impl fmt::Debug for PrincipalBindingDispatchFrameV1 {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PrincipalBindingDispatchFrameV1")
            .field("expectation", &self.expectation)
            .field("bytes", &"<redacted>")
            .finish()
    }
}

impl Drop for PrincipalBindingDispatchFrameV1 {
    fn drop(&mut self) {
        self.bytes.fill(0);
    }
}

impl PrincipalBindingDispatchFrameV1 {
    pub fn expectation(&self) -> &PrincipalBindingAckExpectationV1 {
        &self.expectation
    }

    /// Four-byte big-endian length followed by one closed JSON object.
    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }
}

pub fn encode_registration(
    envelope: PrincipalBindingEnvelopeV1,
) -> Result<PrincipalBindingDispatchFrameV1, PrincipalBindingAckWireError> {
    let expectation = PrincipalBindingAckExpectationV1::from_envelope(&envelope);
    let payload = envelope
        .to_bounded_json()
        .map_err(PrincipalBindingAckWireError::Encode)?;
    let length = u32::try_from(payload.len())
        .map_err(|_| PrincipalBindingAckWireError::FrameTooLarge(payload.len()))?;
    let mut bytes = Vec::with_capacity(LENGTH_PREFIX_BYTES + payload.len());
    bytes.extend_from_slice(&length.to_be_bytes());
    bytes.extend_from_slice(&payload);
    Ok(PrincipalBindingDispatchFrameV1 { expectation, bytes })
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct PrincipalBindingAckFrameV1 {
    version: Version1,
    broker_generation: NonZeroU64,
    id: NonZeroU64,
    result: PrincipalBindingAckResultV1,
    binding_id: BoundedId,
    authority_epoch: u64,
    changed: bool,
}

/// Opaque proof that the private service returned the exact durable ACK.
/// The type has no public constructor and does not implement `Deserialize`.
#[derive(Debug, Eq, PartialEq)]
pub struct DurablyAcknowledgedPrincipalBindingV1 {
    expectation: PrincipalBindingAckExpectationV1,
    changed: bool,
}

impl DurablyAcknowledgedPrincipalBindingV1 {
    pub fn request_id(&self) -> NonZeroU64 {
        self.expectation.request_id
    }

    pub fn broker_generation(&self) -> NonZeroU64 {
        self.expectation.broker_generation
    }

    pub fn binding_id(&self) -> &BoundedId {
        &self.expectation.binding_id
    }

    pub fn authority_epoch(&self) -> u64 {
        self.expectation.authority_epoch
    }

    pub fn result(&self) -> PrincipalBindingAckResultV1 {
        self.expectation.result
    }

    pub fn changed(&self) -> bool {
        self.changed
    }

    pub(crate) fn acknowledges_registration(
        &self,
        broker_generation: NonZeroU64,
        binding_id: &BoundedId,
        epoch: u64,
    ) -> bool {
        self.result() == PrincipalBindingAckResultV1::Registered
            && self.broker_generation() == broker_generation
            && self.binding_id() == binding_id
            && self.authority_epoch() == epoch
    }

    pub(crate) fn acknowledges_revocation(
        &self,
        broker_generation: NonZeroU64,
        binding_id: &BoundedId,
        epoch: u64,
    ) -> bool {
        self.result() == PrincipalBindingAckResultV1::Revoked
            && self.broker_generation() == broker_generation
            && self.binding_id() == binding_id
            && self.authority_epoch() == epoch
    }
}

/// Decode a complete length-prefixed ACK frame and match every authority field
/// against the prepared registration. Unknown fields and non-canonical IDs are
/// rejected by serde/the bounded value types before a token can be minted.
pub fn decode_ack_frame(
    expected: &PrincipalBindingAckExpectationV1,
    frame: &[u8],
) -> Result<DurablyAcknowledgedPrincipalBindingV1, PrincipalBindingAckWireError> {
    if frame.len() < LENGTH_PREFIX_BYTES {
        return Err(PrincipalBindingAckWireError::TruncatedFrame);
    }
    let length = u32::from_be_bytes(
        frame[..LENGTH_PREFIX_BYTES]
            .try_into()
            .expect("checked four-byte prefix"),
    ) as usize;
    if length == 0 {
        return Err(PrincipalBindingAckWireError::EmptyFrame);
    }
    if length > MAX_PRINCIPAL_BINDING_ACK_BYTES {
        return Err(PrincipalBindingAckWireError::FrameTooLarge(length));
    }
    if frame.len() != LENGTH_PREFIX_BYTES + length {
        return Err(PrincipalBindingAckWireError::LengthMismatch {
            declared: length,
            actual: frame.len().saturating_sub(LENGTH_PREFIX_BYTES),
        });
    }
    decode_ack_payload(expected, &frame[LENGTH_PREFIX_BYTES..])
}

pub fn decode_ack_payload(
    expected: &PrincipalBindingAckExpectationV1,
    payload: &[u8],
) -> Result<DurablyAcknowledgedPrincipalBindingV1, PrincipalBindingAckWireError> {
    if payload.is_empty() {
        return Err(PrincipalBindingAckWireError::EmptyFrame);
    }
    if payload.len() > MAX_PRINCIPAL_BINDING_ACK_BYTES {
        return Err(PrincipalBindingAckWireError::FrameTooLarge(payload.len()));
    }
    let ack: PrincipalBindingAckFrameV1 =
        serde_json::from_slice(payload).map_err(|_| PrincipalBindingAckWireError::BadAck)?;
    let _version = ack.version;
    if ack.id != expected.request_id
        || ack.broker_generation != expected.broker_generation
        || ack.binding_id != expected.binding_id
        || ack.authority_epoch != expected.authority_epoch
        || ack.result != expected.result
    {
        return Err(PrincipalBindingAckWireError::IdentityMismatch);
    }
    Ok(DurablyAcknowledgedPrincipalBindingV1 {
        expectation: expected.clone(),
        changed: ack.changed,
    })
}

#[derive(Debug)]
pub enum PrincipalBindingAckWireError {
    Encode(PrincipalBindingEnvelopeError),
    EmptyFrame,
    TruncatedFrame,
    FrameTooLarge(usize),
    LengthMismatch { declared: usize, actual: usize },
    BadAck,
    IdentityMismatch,
}

impl fmt::Display for PrincipalBindingAckWireError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Encode(_) => formatter.write_str("principal-binding request encoding failed"),
            Self::EmptyFrame => formatter.write_str("principal-binding ACK frame is empty"),
            Self::TruncatedFrame => {
                formatter.write_str("principal-binding ACK prefix is truncated")
            }
            Self::FrameTooLarge(length) => write!(
                formatter,
                "principal-binding ACK exceeds its byte bound ({length} bytes)"
            ),
            Self::LengthMismatch { declared, actual } => write!(
                formatter,
                "principal-binding ACK length mismatch (declared {declared}, actual {actual})"
            ),
            Self::BadAck => {
                formatter.write_str("principal-binding ACK is not a closed protocol value")
            }
            Self::IdentityMismatch => {
                formatter.write_str("principal-binding ACK identity does not match request")
            }
        }
    }
}

impl std::error::Error for PrincipalBindingAckWireError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Encode(error) => Some(error),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::authority_registry::SignedDesktopAuthorityV1;
    use crate::principal_binding_registration::{
        PrincipalBindingEnvelopeV1, VerifiedInstallationAuthorityV1,
    };
    use crate::session_message::Timestamp;
    use crate::session_message_gateway::DurablyActivatedDesktopAuthority;
    use serde_json::{json, Value};

    const GENERATION: u64 = 873_421;

    fn nonzero(value: u64) -> NonZeroU64 {
        NonZeroU64::new(value).unwrap()
    }

    fn id(value: &str) -> BoundedId {
        BoundedId::try_from(value).unwrap()
    }

    fn dispatch() -> PrincipalBindingDispatchFrameV1 {
        encode_registration(PrincipalBindingEnvelopeV1::revoke(
            nonzero(7_003),
            nonzero(GENERATION),
            id("binding-a"),
            3,
        ))
        .unwrap()
    }

    fn ack_value() -> Value {
        let vector: Value = serde_json::from_str(include_str!(
            "../../../docs/rfcs/fixtures/principal-binding-registration-v1-known-vector.json"
        ))
        .unwrap();
        vector["acks"]["session_revoked"].clone()
    }

    fn desktop_registration_dispatch() -> PrincipalBindingDispatchFrameV1 {
        let policy = VerifiedInstallationAuthorityV1::from_verified_installation(
            id("workspace-code"),
            id("execution-1"),
        );
        encode_registration(PrincipalBindingEnvelopeV1::signed_desktop(
            nonzero(7_001),
            nonzero(GENERATION),
            id("desktop-binding-1"),
            501,
            5,
            &policy,
            [0x44; 32],
            [0x24; 24],
            Timestamp::parse("2099-08-10T15:08:00Z").unwrap(),
        ))
        .unwrap()
    }

    fn desktop_ack_value() -> Value {
        let vector: Value = serde_json::from_str(include_str!(
            "../../../docs/rfcs/fixtures/principal-binding-registration-v1-known-vector.json"
        ))
        .unwrap();
        vector["acks"]["desktop_registered"].clone()
    }

    fn framed(value: &Value) -> Vec<u8> {
        let payload = serde_json::to_vec(value).unwrap();
        let mut frame = Vec::with_capacity(4 + payload.len());
        frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        frame.extend_from_slice(&payload);
        frame
    }

    #[test]
    fn exact_closed_ack_mints_opaque_durable_token() {
        let dispatch = dispatch();
        let acknowledgement =
            decode_ack_frame(dispatch.expectation(), &framed(&ack_value())).unwrap();
        assert_eq!(acknowledgement.request_id(), nonzero(7_003));
        assert_eq!(acknowledgement.broker_generation(), nonzero(GENERATION));
        assert_eq!(acknowledgement.binding_id(), &id("binding-a"));
        assert_eq!(acknowledgement.authority_epoch(), 3);
        assert_eq!(
            acknowledgement.result(),
            PrincipalBindingAckResultV1::Revoked
        );
        assert!(acknowledgement.changed());

        let encoded_length = u32::from_be_bytes(dispatch.bytes()[..4].try_into().unwrap()) as usize;
        assert_eq!(encoded_length, dispatch.bytes().len() - 4);
    }

    #[test]
    fn desktop_activation_consumes_only_an_exact_registration_token() {
        let authority = SignedDesktopAuthorityV1 {
            binding_id: id("desktop-binding-1"),
            authority_epoch: 5,
            expires_at: Timestamp::parse("2099-08-10T15:08:00Z").unwrap(),
        };
        let desktop_dispatch = desktop_registration_dispatch();
        let acknowledgement = decode_ack_frame(
            desktop_dispatch.expectation(),
            &framed(&desktop_ack_value()),
        )
        .unwrap();
        assert!(DurablyActivatedDesktopAuthority::from_acknowledged(
            authority,
            acknowledgement,
            nonzero(GENERATION),
        )
        .is_some());

        let mismatched_authority = SignedDesktopAuthorityV1 {
            binding_id: id("desktop-binding-1"),
            authority_epoch: 6,
            expires_at: Timestamp::parse("2099-08-10T15:08:00Z").unwrap(),
        };
        let acknowledgement = decode_ack_frame(
            desktop_dispatch.expectation(),
            &framed(&desktop_ack_value()),
        )
        .unwrap();
        assert!(DurablyActivatedDesktopAuthority::from_acknowledged(
            mismatched_authority,
            acknowledgement,
            nonzero(GENERATION),
        )
        .is_none());

        let revoke_dispatch = dispatch();
        let revoke_acknowledgement =
            decode_ack_frame(revoke_dispatch.expectation(), &framed(&ack_value())).unwrap();
        let authority = SignedDesktopAuthorityV1 {
            binding_id: id("binding-a"),
            authority_epoch: 3,
            expires_at: Timestamp::parse("2099-08-10T15:08:00Z").unwrap(),
        };
        assert!(DurablyActivatedDesktopAuthority::from_acknowledged(
            authority,
            revoke_acknowledgement,
            nonzero(GENERATION),
        )
        .is_none());

        let authority = SignedDesktopAuthorityV1 {
            binding_id: id("desktop-binding-1"),
            authority_epoch: 5,
            expires_at: Timestamp::parse("2099-08-10T15:08:00Z").unwrap(),
        };
        let acknowledgement = decode_ack_frame(
            desktop_dispatch.expectation(),
            &framed(&desktop_ack_value()),
        )
        .unwrap();
        assert!(DurablyActivatedDesktopAuthority::from_acknowledged(
            authority,
            acknowledgement,
            nonzero(GENERATION + 1),
        )
        .is_none());
    }

    #[test]
    fn every_authority_identity_field_and_result_kind_must_match() {
        let dispatch = dispatch();
        let mutations = [
            ("broker_generation", json!(GENERATION + 1)),
            ("id", json!(7_004)),
            ("result", json!("principal_binding_registered")),
            ("binding_id", json!("binding-b")),
            ("authority_epoch", json!(4)),
        ];
        for (field, replacement) in mutations {
            let mut value = ack_value();
            value[field] = replacement;
            assert!(matches!(
                decode_ack_frame(dispatch.expectation(), &framed(&value)),
                Err(PrincipalBindingAckWireError::IdentityMismatch)
            ));
        }
    }

    #[test]
    fn unknown_fields_bad_version_zero_id_and_noncanonical_binding_fail_closed() {
        let dispatch = dispatch();
        let mutations = [
            ("extra", json!(true)),
            ("version", json!(2)),
            ("id", json!(0)),
            ("binding_id", json!(" binding-a")),
        ];
        for (field, replacement) in mutations {
            let mut value = ack_value();
            value[field] = replacement;
            assert!(matches!(
                decode_ack_frame(dispatch.expectation(), &framed(&value)),
                Err(PrincipalBindingAckWireError::BadAck)
            ));
        }
    }

    #[test]
    fn framing_is_exact_and_bounded() {
        let dispatch = dispatch();
        assert!(matches!(
            decode_ack_frame(dispatch.expectation(), &[]),
            Err(PrincipalBindingAckWireError::TruncatedFrame)
        ));
        assert!(matches!(
            decode_ack_frame(dispatch.expectation(), &[0, 0, 0, 0]),
            Err(PrincipalBindingAckWireError::EmptyFrame)
        ));

        let mut trailing = framed(&ack_value());
        trailing.push(0);
        assert!(matches!(
            decode_ack_frame(dispatch.expectation(), &trailing),
            Err(PrincipalBindingAckWireError::LengthMismatch { .. })
        ));

        let oversized = ((MAX_PRINCIPAL_BINDING_ACK_BYTES + 1) as u32).to_be_bytes();
        assert!(matches!(
            decode_ack_frame(dispatch.expectation(), &oversized),
            Err(PrincipalBindingAckWireError::FrameTooLarge(_))
        ));
    }
}
