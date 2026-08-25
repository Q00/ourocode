//! Phase-0 value contract for authenticated session messaging.
//!
//! This module deliberately has no socket, reactor, principal admission, or
//! database integration. It freezes the bounded wire values and the request
//! digest independently of terminal-control [`crate::CommandV4`].

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use serde::{de, Deserialize, Deserializer, Serialize, Serializer};
use sha2::{Digest, Sha256};
use std::fmt;
use std::num::NonZeroU64;
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;
use unicode_normalization::UnicodeNormalization;

pub const PROTOCOL_VERSION: u16 = 1;
pub const EXACT_TARGET_PROTOCOL_VERSION: u16 = 2;
pub const CAPABILITY_EXACT_TARGET_V2: &str = "session.message.resolve_admit_exact.v2";
pub const MAX_MESSAGE_BYTES: usize = 8_192;
pub const MAX_REASON_BYTES: usize = 1_000;
pub const MAX_REPLY_SUMMARY_BYTES: usize = 1_000;
pub const MAX_ID_BYTES: usize = 256;
pub const MIN_NONCE_BYTES: usize = 16;
pub const MAX_NONCE_BYTES: usize = 32;
pub const MAX_ERROR_MESSAGE_BYTES: usize = 1_000;
pub const MAX_WIRE_FRAME_BYTES: usize = 32 * 1_024;
pub const MAX_RECEIPT_BYTES: usize = 16 * 1_024;
pub const MAX_IN_FLIGHT_PER_CLIENT: usize = 2;
pub const MAX_IN_FLIGHT_GLOBAL: usize = 64;
pub const MAX_UPSTREAM_PENDING_BYTES: usize = 1_024 * 1_024;
pub const MAX_CLIENT_OUTPUT_QUEUE_BYTES: usize = 64 * 1_024;
pub const MAX_REPLAY_RECEIPTS: usize = 256;
pub const MAX_RUNTIME_OUTBOX_BATCH_ROWS: usize = 16;
pub const MAX_RUNTIME_OUTBOX_BATCH_BYTES: usize = 128 * 1_024;

const DIGEST_DOMAIN: &[u8] = b"ourocode.session-message.request-digest.v1";
const EXACT_TARGET_DIGEST_DOMAIN_V2: &[u8] =
    b"ourocode.session-message.exact-target.request-digest.v2";

/// A wire value that can only serialize as the numeric protocol version `1`.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Version1;

impl Serialize for Version1 {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_u16(PROTOCOL_VERSION)
    }
}

impl<'de> Deserialize<'de> for Version1 {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let version = u16::deserialize(deserializer)?;
        if version == PROTOCOL_VERSION {
            Ok(Self)
        } else {
            Err(de::Error::custom("session-message version must be 1"))
        }
    }
}

/// A wire value that can only serialize as the numeric protocol version `2`.
/// Version 2 is additive: it exists solely for an exact target attempt and
/// does not widen the stable-session selector accepted by version 1.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Version2;

impl Serialize for Version2 {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_u16(EXACT_TARGET_PROTOCOL_VERSION)
    }
}

impl<'de> Deserialize<'de> for Version2 {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let version = u16::deserialize(deserializer)?;
        if version == EXACT_TARGET_PROTOCOL_VERSION {
            Ok(Self)
        } else {
            Err(de::Error::custom(
                "exact-target session-message version must be 2",
            ))
        }
    }
}

macro_rules! bounded_string {
    ($name:ident, $max:expr, $description:literal) => {
        #[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
        pub struct $name(String);

        impl $name {
            pub fn as_str(&self) -> &str {
                &self.0
            }

            pub fn len_bytes(&self) -> usize {
                self.0.len()
            }
        }

        impl TryFrom<String> for $name {
            type Error = BoundedValueError;

            fn try_from(value: String) -> Result<Self, Self::Error> {
                let length = value.len();
                if value.is_empty() || length > $max {
                    return Err(BoundedValueError::Length {
                        field: $description,
                        maximum: $max,
                        actual: length,
                    });
                }
                let normalized: String = value.nfc().collect();
                if normalized != value || value.trim() != value {
                    return Err(BoundedValueError::NonCanonical {
                        field: $description,
                    });
                }
                if !value
                    .chars()
                    .any(|character| !character.is_whitespace() && !character.is_control())
                {
                    return Err(BoundedValueError::NoVisibleText {
                        field: $description,
                    });
                }
                Ok(Self(value))
            }
        }

        impl TryFrom<&str> for $name {
            type Error = BoundedValueError;

            fn try_from(value: &str) -> Result<Self, Self::Error> {
                Self::try_from(value.to_owned())
            }
        }

        impl Serialize for $name {
            fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
            where
                S: Serializer,
            {
                serializer.serialize_str(&self.0)
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
            where
                D: Deserializer<'de>,
            {
                let value = String::deserialize(deserializer)?;
                Self::try_from(value).map_err(de::Error::custom)
            }
        }
    };
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BoundedValueError {
    Length {
        field: &'static str,
        maximum: usize,
        actual: usize,
    },
    NonCanonical {
        field: &'static str,
    },
    NoVisibleText {
        field: &'static str,
    },
}

impl fmt::Display for BoundedValueError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Length {
                field,
                maximum,
                actual,
            } => write!(
                formatter,
                "{field} must contain 1..={maximum} UTF-8 bytes (got {actual})"
            ),
            Self::NonCanonical { field } => {
                write!(formatter, "{field} must be NFC without edge whitespace")
            }
            Self::NoVisibleText { field } => {
                write!(formatter, "{field} must contain visible text")
            }
        }
    }
}

impl std::error::Error for BoundedValueError {}

bounded_string!(BoundedId, MAX_ID_BYTES, "identity");
bounded_string!(BoundedMessage, MAX_MESSAGE_BYTES, "message");
bounded_string!(BoundedReason, MAX_REASON_BYTES, "reason");
bounded_string!(BoundedReply, MAX_REPLY_SUMMARY_BYTES, "reply summary");
bounded_string!(
    BoundedErrorMessage,
    MAX_ERROR_MESSAGE_BYTES,
    "error message"
);

/// Canonical, unpadded base64url encoding of 16 through 32 bytes.
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct Nonce(Vec<u8>);

impl Nonce {
    pub fn from_bytes(bytes: Vec<u8>) -> Result<Self, NonceError> {
        if !(MIN_NONCE_BYTES..=MAX_NONCE_BYTES).contains(&bytes.len()) {
            return Err(NonceError::Length(bytes.len()));
        }
        Ok(Self(bytes))
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }

    pub fn to_base64url(&self) -> String {
        URL_SAFE_NO_PAD.encode(&self.0)
    }

    fn parse(encoded: &str) -> Result<Self, NonceError> {
        if encoded.contains('=') {
            return Err(NonceError::NonCanonical);
        }
        let decoded = URL_SAFE_NO_PAD
            .decode(encoded)
            .map_err(|_| NonceError::InvalidEncoding)?;
        let nonce = Self::from_bytes(decoded)?;
        if nonce.to_base64url() != encoded {
            return Err(NonceError::NonCanonical);
        }
        Ok(nonce)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NonceError {
    InvalidEncoding,
    NonCanonical,
    Length(usize),
}

impl fmt::Display for NonceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidEncoding => formatter.write_str("nonce is not base64url"),
            Self::NonCanonical => {
                formatter.write_str("nonce must use canonical unpadded base64url")
            }
            Self::Length(length) => write!(
                formatter,
                "nonce must decode to {MIN_NONCE_BYTES}..={MAX_NONCE_BYTES} bytes (got {length})"
            ),
        }
    }
}

impl std::error::Error for NonceError {}

impl Serialize for Nonce {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&self.to_base64url())
    }
}

impl<'de> Deserialize<'de> for Nonce {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let encoded = String::deserialize(deserializer)?;
        Self::parse(&encoded).map_err(de::Error::custom)
    }
}

/// A normalized RFC 3339 instant. Serialization always uses UTC.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct Timestamp(OffsetDateTime);

impl Timestamp {
    pub fn parse(value: &str) -> Result<Self, TimestampError> {
        let parsed =
            OffsetDateTime::parse(value, &Rfc3339).map_err(|_| TimestampError::InvalidRfc3339)?;
        Ok(Self(parsed.to_offset(time::UtcOffset::UTC)))
    }

    pub fn unix_timestamp_nanos(self) -> i128 {
        self.0.unix_timestamp_nanos()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TimestampError {
    InvalidRfc3339,
    Formatting,
}

impl fmt::Display for TimestampError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidRfc3339 => formatter.write_str("timestamp must be an RFC 3339 instant"),
            Self::Formatting => formatter.write_str("timestamp could not be formatted"),
        }
    }
}

impl std::error::Error for TimestampError {}

impl Serialize for Timestamp {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let value = self.0.format(&Rfc3339).map_err(serde::ser::Error::custom)?;
        serializer.serialize_str(&value)
    }
}

impl<'de> Deserialize<'de> for Timestamp {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::parse(&value).map_err(de::Error::custom)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Sha256Digest([u8; 32]);

impl Sha256Digest {
    pub fn from_bytes(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }

    pub fn to_prefixed_hex(self) -> String {
        let mut encoded = String::with_capacity(71);
        encoded.push_str("sha256:");
        for byte in self.0 {
            use fmt::Write;
            write!(&mut encoded, "{byte:02x}").expect("writing to String cannot fail");
        }
        encoded
    }

    fn parse(value: &str) -> Result<Self, DigestEncodingError> {
        let Some(hex) = value.strip_prefix("sha256:") else {
            return Err(DigestEncodingError);
        };
        if hex.len() != 64 || !hex.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(DigestEncodingError);
        }
        let mut bytes = [0_u8; 32];
        for (index, slot) in bytes.iter_mut().enumerate() {
            let offset = index * 2;
            *slot = u8::from_str_radix(&hex[offset..offset + 2], 16)
                .map_err(|_| DigestEncodingError)?;
        }
        let digest = Self(bytes);
        if digest.to_prefixed_hex() != value {
            return Err(DigestEncodingError);
        }
        Ok(digest)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct DigestEncodingError;

impl fmt::Display for DigestEncodingError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("digest must be canonical lowercase sha256 hex")
    }
}

impl Serialize for Sha256Digest {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&self.to_prefixed_hex())
    }
}

impl<'de> Deserialize<'de> for Sha256Digest {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::parse(&value).map_err(de::Error::custom)
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum ResolveAndAdmitV1 {
    #[serde(rename = "session_message_resolve_and_admit")]
    ResolveAndAdmit,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum ResolveAndAdmitExactV2 {
    #[serde(rename = "session_message_resolve_and_admit_exact")]
    ResolveAndAdmitExact,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum StatusV1 {
    #[serde(rename = "session_message_status")]
    Status,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum SessionMessageMode {
    #[serde(rename = "after_turn")]
    AfterTurn,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SessionMessageRequestV1 {
    pub version: Version1,
    pub id: NonZeroU64,
    pub op: ResolveAndAdmitV1,
    pub broker_generation: NonZeroU64,
    pub authority_epoch: u64,
    pub request_nonce: Nonce,
    pub target_session_id: BoundedId,
    pub expected_execution_id: Option<BoundedId>,
    pub expected_target_generation: Option<u64>,
    pub mode: SessionMessageMode,
    pub message: BoundedMessage,
    pub reason: BoundedReason,
    pub expires_at: Timestamp,
    pub correlation_id: Option<BoundedId>,
}

/// Exact pane/attempt selector for authenticated steering.
///
/// The source is intentionally absent. The broker injects only its opaque
/// registry-derived `principal_binding_id`; Ouroboros resolves that binding to
/// the exact source inside the same transaction that validates this target.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SessionMessageRequestV2 {
    pub version: Version2,
    pub id: NonZeroU64,
    pub op: ResolveAndAdmitExactV2,
    pub broker_generation: NonZeroU64,
    pub authority_epoch: u64,
    pub request_nonce: Nonce,
    pub target: ExactSessionIdentity,
    pub mode: SessionMessageMode,
    pub message: BoundedMessage,
    pub reason: BoundedReason,
    pub expires_at: Timestamp,
    pub correlation_id: Option<BoundedId>,
}

impl SessionMessageRequestV2 {
    pub fn validate(&self) -> Result<(), ExactTargetRequestError> {
        if self.target.generation == 0 {
            Err(ExactTargetRequestError::ZeroTargetGeneration)
        } else {
            Ok(())
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExactTargetRequestError {
    ZeroTargetGeneration,
}

impl fmt::Display for ExactTargetRequestError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("exact target generation must be nonzero")
    }
}

impl std::error::Error for ExactTargetRequestError {}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SessionMessageStatusRequestV1 {
    pub version: Version1,
    pub id: NonZeroU64,
    pub op: StatusV1,
    pub broker_generation: NonZeroU64,
    pub authority_epoch: u64,
    pub request_nonce: Nonce,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ExactSessionIdentity {
    pub session_id: BoundedId,
    pub execution_id: BoundedId,
    pub scope_id: BoundedId,
    pub attempt_id: BoundedId,
    pub generation: u64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum ExactSourceIdentity {
    User {
        principal_id: BoundedId,
        authority_epoch: u64,
    },
    Session {
        session_id: BoundedId,
        execution_id: BoundedId,
        scope_id: BoundedId,
        attempt_id: BoundedId,
        generation: u64,
    },
}

impl ExactSourceIdentity {
    pub fn session(identity: ExactSessionIdentity) -> Self {
        Self::Session {
            session_id: identity.session_id,
            execution_id: identity.execution_id,
            scope_id: identity.scope_id,
            attempt_id: identity.attempt_id,
            generation: identity.generation,
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum ReceiptResult {
    #[serde(rename = "session_message_receipt")]
    SessionMessageReceipt,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionMessageState {
    Queued,
    Delivering,
    Applied,
    Completed,
    Rejected,
    DeliveryUncertain,
}

impl SessionMessageState {
    pub fn application_proven(self) -> bool {
        matches!(self, Self::Applied | Self::Completed)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SessionMessageReceiptV1 {
    pub version: Version1,
    pub broker_generation: NonZeroU64,
    pub id: NonZeroU64,
    pub result: ReceiptResult,
    pub request_nonce: Nonce,
    pub request_digest: Sha256Digest,
    pub signal_id: BoundedId,
    pub source: ExactSourceIdentity,
    pub target: ExactSessionIdentity,
    pub mode: SessionMessageMode,
    pub state: SessionMessageState,
    pub durable_cursor: u64,
    pub application_proven: bool,
    pub replayed: bool,
    pub hop_count: u8,
    pub expires_at: Timestamp,
    pub reply_summary: Option<BoundedReply>,
}

impl SessionMessageReceiptV1 {
    pub fn validate(&self) -> Result<(), ReceiptValidationError> {
        if self.application_proven != self.state.application_proven() {
            return Err(ReceiptValidationError::ApplicationProofMismatch);
        }
        if self.reply_summary.is_some() && self.state != SessionMessageState::Completed {
            return Err(ReceiptValidationError::ReplyBeforeCompletion);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReceiptValidationError {
    ApplicationProofMismatch,
    ReplyBeforeCompletion,
}

impl fmt::Display for ReceiptValidationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ApplicationProofMismatch => {
                formatter.write_str("application_proven does not match receipt state")
            }
            Self::ReplyBeforeCompletion => {
                formatter.write_str("reply_summary is only valid for completed receipts")
            }
        }
    }
}

impl std::error::Error for ReceiptValidationError {}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum ErrorResult {
    #[serde(rename = "session_message_error")]
    SessionMessageError,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionMessageErrorCode {
    BadVersion,
    BadRequest,
    Unauthenticated,
    Unauthorized,
    StaleGeneration,
    StaleAuthority,
    NonceConflict,
    SourceNotActive,
    TargetNotFound,
    TargetAmbiguous,
    TargetNotActive,
    TargetGenerationMismatch,
    ReceiptNotFound,
    CrossForestDenied,
    SelfMessageDenied,
    HopLimitExceeded,
    CapabilityUnsupported,
    Expired,
    QueueFull,
    UpstreamUnavailable,
    OutcomeUnknown,
    Internal,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SessionMessageErrorV1 {
    pub version: Version1,
    pub broker_generation: NonZeroU64,
    pub id: NonZeroU64,
    pub error: ErrorResult,
    pub code: SessionMessageErrorCode,
    pub message: BoundedErrorMessage,
}

/// Trusted principal data. It is intentionally not deserializable from wire
/// JSON; peer admission must construct it from kernel/service authority.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AuthoritativePrincipal {
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

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionCause {
    pub signal_id: BoundedId,
    pub hop_count: u8,
}

impl AuthoritativePrincipal {
    /// Registry-derived persistence binding. This value is exposed only after
    /// transport authorization; it is never accepted from request JSON.
    pub fn binding_id(&self) -> &BoundedId {
        match self {
            Self::SignedDesktop { binding_id, .. } | Self::OuroborosSession { binding_id, .. } => {
                binding_id
            }
        }
    }

    pub fn authority_epoch(&self) -> u64 {
        match self {
            Self::SignedDesktop {
                authority_epoch, ..
            }
            | Self::OuroborosSession {
                authority_epoch, ..
            } => *authority_epoch,
        }
    }

    fn causal_context(&self) -> Result<(Option<&BoundedId>, u8), RequestDigestError> {
        match self {
            Self::SignedDesktop { .. } => Ok((None, 0)),
            Self::OuroborosSession { cause: None, .. } => Ok((None, 1)),
            Self::OuroborosSession {
                cause: Some(cause), ..
            } => cause
                .hop_count
                .checked_add(1)
                .map(|hop| (Some(&cause.signal_id), hop))
                .ok_or(RequestDigestError::HopCountOverflow),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RequestDigestError {
    StaleAuthority,
    HopCountOverflow,
    InvalidExactTarget,
}

impl fmt::Display for RequestDigestError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::StaleAuthority => {
                formatter.write_str("request authority epoch does not match principal")
            }
            Self::HopCountOverflow => formatter.write_str("derived hop count overflowed"),
            Self::InvalidExactTarget => formatter.write_str("exact target identity is invalid"),
        }
    }
}

impl std::error::Error for RequestDigestError {}

/// Produce the cross-language request digest. Each ordered component is
/// prefixed with its unsigned 64-bit big-endian byte length. Numeric values
/// are themselves fixed-width big-endian bytes; optional values are encoded
/// as an empty component when absent. JSON order and broker request IDs never
/// enter the preimage.
pub fn request_digest(
    principal: &AuthoritativePrincipal,
    request: &SessionMessageRequestV1,
) -> Result<Sha256Digest, RequestDigestError> {
    if principal.authority_epoch() != request.authority_epoch {
        return Err(RequestDigestError::StaleAuthority);
    }

    let (causal_parent, hop_count) = principal.causal_context()?;
    let mut preimage = LengthPrefixedDigest::new();
    preimage.field(DIGEST_DOMAIN);

    match principal {
        AuthoritativePrincipal::SignedDesktop {
            uid,
            binding_id,
            audit_identity_digest,
            desktop_incarnation,
            ..
        } => {
            preimage.field(b"signed_desktop");
            preimage.field(&uid.to_be_bytes());
            preimage.field(binding_id.as_str().as_bytes());
            preimage.field(audit_identity_digest);
            preimage.field(desktop_incarnation);
        }
        AuthoritativePrincipal::OuroborosSession {
            uid,
            binding_id,
            session_id,
            execution_id,
            scope_id,
            attempt_id,
            ..
        } => {
            preimage.field(b"ouroboros_session");
            preimage.field(&uid.to_be_bytes());
            preimage.field(binding_id.as_str().as_bytes());
            preimage.field(session_id.as_str().as_bytes());
            preimage.field(execution_id.as_str().as_bytes());
            preimage.field(scope_id.as_str().as_bytes());
            preimage.field(attempt_id.as_str().as_bytes());
        }
    }

    preimage.field(&request.authority_epoch.to_be_bytes());
    preimage.field(request.request_nonce.as_bytes());
    preimage.field(request.target_session_id.as_str().as_bytes());
    preimage.optional_string(request.expected_execution_id.as_ref());
    preimage.optional_u64(request.expected_target_generation);
    preimage.field(b"after_turn");

    let message_digest = Sha256::digest(request.message.as_str().as_bytes());
    let reason_digest = Sha256::digest(request.reason.as_str().as_bytes());
    preimage.field(&message_digest);
    preimage.field(&reason_digest);
    preimage.field(&request.expires_at.unix_timestamp_nanos().to_be_bytes());
    preimage.optional_string(causal_parent);
    preimage.field(&[hop_count]);
    preimage.optional_string(request.correlation_id.as_ref());

    Ok(Sha256Digest::from_bytes(preimage.finish()))
}

/// Version-2 digest freezes the complete target attempt. Request IDs and the
/// broker transport generation remain retry metadata and do not enter the
/// semantic idempotency preimage, matching the v1 replay contract.
pub fn exact_target_request_digest_v2(
    principal: &AuthoritativePrincipal,
    request: &SessionMessageRequestV2,
) -> Result<Sha256Digest, RequestDigestError> {
    request
        .validate()
        .map_err(|_| RequestDigestError::InvalidExactTarget)?;
    if principal.authority_epoch() != request.authority_epoch {
        return Err(RequestDigestError::StaleAuthority);
    }
    let (causal_parent, hop_count) = principal.causal_context()?;
    let mut preimage = LengthPrefixedDigest::new();
    preimage.field(EXACT_TARGET_DIGEST_DOMAIN_V2);
    append_principal_digest_fields(&mut preimage, principal);
    preimage.field(&request.authority_epoch.to_be_bytes());
    preimage.field(request.request_nonce.as_bytes());
    preimage.field(request.target.session_id.as_str().as_bytes());
    preimage.field(request.target.execution_id.as_str().as_bytes());
    preimage.field(request.target.scope_id.as_str().as_bytes());
    preimage.field(request.target.attempt_id.as_str().as_bytes());
    preimage.field(&request.target.generation.to_be_bytes());
    preimage.field(b"after_turn");
    preimage.field(&Sha256::digest(request.message.as_str().as_bytes()));
    preimage.field(&Sha256::digest(request.reason.as_str().as_bytes()));
    preimage.field(&request.expires_at.unix_timestamp_nanos().to_be_bytes());
    preimage.optional_string(causal_parent);
    preimage.field(&[hop_count]);
    preimage.optional_string(request.correlation_id.as_ref());
    Ok(Sha256Digest::from_bytes(preimage.finish()))
}

fn append_principal_digest_fields(
    preimage: &mut LengthPrefixedDigest,
    principal: &AuthoritativePrincipal,
) {
    match principal {
        AuthoritativePrincipal::SignedDesktop {
            uid,
            binding_id,
            audit_identity_digest,
            desktop_incarnation,
            ..
        } => {
            preimage.field(b"signed_desktop");
            preimage.field(&uid.to_be_bytes());
            preimage.field(binding_id.as_str().as_bytes());
            preimage.field(audit_identity_digest);
            preimage.field(desktop_incarnation);
        }
        AuthoritativePrincipal::OuroborosSession {
            uid,
            binding_id,
            session_id,
            execution_id,
            scope_id,
            attempt_id,
            ..
        } => {
            preimage.field(b"ouroboros_session");
            preimage.field(&uid.to_be_bytes());
            preimage.field(binding_id.as_str().as_bytes());
            preimage.field(session_id.as_str().as_bytes());
            preimage.field(execution_id.as_str().as_bytes());
            preimage.field(scope_id.as_str().as_bytes());
            preimage.field(attempt_id.as_str().as_bytes());
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReplayDisposition {
    Replay,
    NonceConflict,
}

pub fn classify_replay(
    stored_digest: Sha256Digest,
    candidate_digest: Sha256Digest,
) -> ReplayDisposition {
    if stored_digest == candidate_digest {
        ReplayDisposition::Replay
    } else {
        ReplayDisposition::NonceConflict
    }
}

struct LengthPrefixedDigest(Sha256);

impl LengthPrefixedDigest {
    fn new() -> Self {
        Self(Sha256::new())
    }

    fn field(&mut self, bytes: &[u8]) {
        self.0.update((bytes.len() as u64).to_be_bytes());
        self.0.update(bytes);
    }

    fn optional_string(&mut self, value: Option<&BoundedId>) {
        self.field(value.map_or(&[], |value| value.as_str().as_bytes()));
    }

    fn optional_u64(&mut self, value: Option<u64>) {
        match value {
            Some(value) => self.field(&value.to_be_bytes()),
            None => self.field(&[]),
        }
    }

    fn finish(self) -> [u8; 32] {
        self.0.finalize().into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn known_vector() -> serde_json::Value {
        serde_json::from_str(include_str!(
            "../../../docs/rfcs/fixtures/session-message-v1-known-vector.json"
        ))
        .expect("cross-language vector must remain valid JSON")
    }

    fn exact_known_vector() -> serde_json::Value {
        serde_json::from_str(include_str!(
            "../../../docs/rfcs/fixtures/session-message-exact-target-v2-known-vector.json"
        ))
        .expect("exact-target cross-language vector must remain valid JSON")
    }

    fn request() -> SessionMessageRequestV1 {
        serde_json::from_value(known_vector()["request"].clone())
            .expect("request fixture must decode")
    }

    fn exact_request() -> SessionMessageRequestV2 {
        serde_json::from_value(exact_known_vector()["request"].clone())
            .expect("exact request fixture must decode")
    }

    fn principal() -> AuthoritativePrincipal {
        let vector = known_vector();
        let principal = &vector["principal"];
        let text = |field: &str| {
            BoundedId::try_from(
                principal[field]
                    .as_str()
                    .expect("principal vector field must be text"),
            )
            .unwrap()
        };
        AuthoritativePrincipal::OuroborosSession {
            uid: principal["uid"].as_u64().unwrap().try_into().unwrap(),
            binding_id: text("binding_id"),
            session_id: text("session_id"),
            execution_id: text("execution_id"),
            scope_id: text("scope_id"),
            attempt_id: text("attempt_id"),
            authority_epoch: principal["authority_epoch"].as_u64().unwrap(),
            cause: None,
        }
    }

    #[test]
    fn utf8_byte_bounds_are_exact() {
        assert!(BoundedId::try_from("i".repeat(MAX_ID_BYTES)).is_ok());
        assert!(BoundedId::try_from("i".repeat(MAX_ID_BYTES + 1)).is_err());
        assert!(BoundedMessage::try_from("m".repeat(MAX_MESSAGE_BYTES)).is_ok());
        assert!(BoundedMessage::try_from("m".repeat(MAX_MESSAGE_BYTES + 1)).is_err());
        assert!(BoundedReason::try_from("r".repeat(MAX_REASON_BYTES)).is_ok());
        assert!(BoundedReason::try_from("r".repeat(MAX_REASON_BYTES + 1)).is_err());
        assert!(BoundedReply::try_from("한".repeat(333)).is_ok());
        assert!(BoundedReply::try_from("한".repeat(334)).is_err());
        assert!(BoundedErrorMessage::try_from("e".repeat(MAX_ERROR_MESSAGE_BYTES)).is_ok());
        assert!(BoundedErrorMessage::try_from("e".repeat(MAX_ERROR_MESSAGE_BYTES + 1)).is_err());
        assert!(BoundedMessage::try_from("").is_err());
        assert!(BoundedMessage::try_from(" intent ").is_err());
        assert!(BoundedMessage::try_from("\n\t").is_err());
        assert!(BoundedMessage::try_from("e\u{301}").is_err());
        assert!(BoundedMessage::try_from("é").is_ok());
    }

    #[test]
    fn nonce_requires_canonical_unpadded_base64url_and_exact_bounds() {
        for length in [MIN_NONCE_BYTES, MAX_NONCE_BYTES] {
            let nonce = Nonce::from_bytes(vec![0xabu8; length]).unwrap();
            let json = serde_json::to_string(&nonce).unwrap();
            assert_eq!(serde_json::from_str::<Nonce>(&json).unwrap(), nonce);
        }

        for length in [MIN_NONCE_BYTES - 1, MAX_NONCE_BYTES + 1] {
            let encoded = URL_SAFE_NO_PAD.encode(vec![0xabu8; length]);
            assert!(serde_json::from_value::<Nonce>(json!(encoded)).is_err());
        }

        assert!(serde_json::from_value::<Nonce>(json!("AAAAAAAAAAAAAAAAAAAAAA==")).is_err());
        assert!(serde_json::from_value::<Nonce>(json!("_____________________!")).is_err());
    }

    #[test]
    fn request_is_closed_and_after_turn_only() {
        let mut source = serde_json::to_value(request()).unwrap();
        source["source"] = json!("user");
        assert!(serde_json::from_value::<SessionMessageRequestV1>(source).is_err());

        let mut hop = serde_json::to_value(request()).unwrap();
        hop["hop_count"] = json!(1);
        assert!(serde_json::from_value::<SessionMessageRequestV1>(hop).is_err());

        let mut source_attempt = serde_json::to_value(request()).unwrap();
        source_attempt["source_attempt_id"] = json!("attempt-a1");
        assert!(serde_json::from_value::<SessionMessageRequestV1>(source_attempt).is_err());

        let mut replace = serde_json::to_value(request()).unwrap();
        replace["mode"] = json!("replace");
        assert!(serde_json::from_value::<SessionMessageRequestV1>(replace).is_err());

        let mut bad_version = serde_json::to_value(request()).unwrap();
        bad_version["version"] = json!(2);
        assert!(serde_json::from_value::<SessionMessageRequestV1>(bad_version).is_err());
    }

    #[test]
    fn exact_target_v2_is_closed_nonzero_and_has_a_distinct_digest_domain() {
        let exact = exact_request();
        exact.validate().unwrap();
        let digest = exact_target_request_digest_v2(&principal(), &exact).unwrap();
        assert_eq!(
            digest.to_prefixed_hex(),
            exact_known_vector()["derived"]["request_digest"]
                .as_str()
                .unwrap()
        );
        assert_ne!(digest, request_digest(&principal(), &request()).unwrap());

        let mut source = serde_json::to_value(&exact).unwrap();
        source["source"] = json!({"kind": "session", "attempt_id": "forged"});
        assert!(serde_json::from_value::<SessionMessageRequestV2>(source).is_err());

        let mut open_target = serde_json::to_value(&exact).unwrap();
        open_target["target"]["label"] = json!("Pane B");
        assert!(serde_json::from_value::<SessionMessageRequestV2>(open_target).is_err());

        let mut zero_generation = exact.clone();
        zero_generation.target.generation = 0;
        assert_eq!(
            zero_generation.validate(),
            Err(ExactTargetRequestError::ZeroTargetGeneration)
        );

        let mut pane_a = exact;
        pane_a.target.scope_id = BoundedId::try_from("scope-pane-a").unwrap();
        pane_a.target.attempt_id = BoundedId::try_from("attempt-pane-a").unwrap();
        assert_ne!(
            exact_target_request_digest_v2(&principal(), &pane_a).unwrap(),
            digest
        );
    }

    #[test]
    fn request_digest_freezes_replay_and_conflict_semantics() {
        let first = request();
        let digest = request_digest(&principal(), &first).unwrap();
        let expected = known_vector()["derived"]["request_digest"]
            .as_str()
            .unwrap()
            .to_owned();
        assert_eq!(digest.to_prefixed_hex(), expected);

        let mut retry = first.clone();
        retry.id = NonZeroU64::new(99).unwrap();
        retry.broker_generation = NonZeroU64::new(444).unwrap();
        let retry_digest = request_digest(&principal(), &retry).unwrap();
        assert_eq!(
            classify_replay(digest, retry_digest),
            ReplayDisposition::Replay
        );

        let mut conflict = retry;
        conflict.message = BoundedMessage::try_from("Different intent").unwrap();
        let conflict_digest = request_digest(&principal(), &conflict).unwrap();
        assert_eq!(
            classify_replay(digest, conflict_digest),
            ReplayDisposition::NonceConflict
        );
    }

    #[test]
    fn receipt_json_is_exact_and_does_not_echo_payload() {
        let request = request();
        let digest = request_digest(&principal(), &request).unwrap();
        let expected_digest = known_vector()["derived"]["request_digest"]
            .as_str()
            .unwrap()
            .to_owned();
        let receipt = SessionMessageReceiptV1 {
            version: Version1,
            broker_generation: NonZeroU64::new(873421).unwrap(),
            id: request.id,
            result: ReceiptResult::SessionMessageReceipt,
            request_nonce: request.request_nonce,
            request_digest: digest,
            signal_id: BoundedId::try_from("signal-91").unwrap(),
            source: ExactSourceIdentity::session(ExactSessionIdentity {
                session_id: BoundedId::try_from("session-a").unwrap(),
                execution_id: BoundedId::try_from("execution-1").unwrap(),
                scope_id: BoundedId::try_from("scope-a").unwrap(),
                attempt_id: BoundedId::try_from("attempt-a1").unwrap(),
                generation: 4,
            }),
            target: ExactSessionIdentity {
                session_id: BoundedId::try_from("session-b").unwrap(),
                execution_id: BoundedId::try_from("execution-1").unwrap(),
                scope_id: BoundedId::try_from("scope-b").unwrap(),
                attempt_id: BoundedId::try_from("attempt-b2").unwrap(),
                generation: 7,
            },
            mode: SessionMessageMode::AfterTurn,
            state: SessionMessageState::Queued,
            durable_cursor: 108,
            application_proven: false,
            replayed: false,
            hop_count: 1,
            expires_at: Timestamp::parse("2026-08-10T15:04:05.000Z").unwrap(),
            reply_summary: None,
        };
        receipt.validate().unwrap();

        let actual = serde_json::to_value(&receipt).unwrap();
        assert_eq!(
            actual,
            json!({
                "version": 1,
                "broker_generation": 873421,
                "id": 42,
                "result": "session_message_receipt",
                "request_nonce": "EiQ2SFpscYKTpLXNZ2mr7A",
                "request_digest": expected_digest,
                "signal_id": "signal-91",
                "source": {
                    "kind": "session",
                    "session_id": "session-a",
                    "execution_id": "execution-1",
                    "scope_id": "scope-a",
                    "attempt_id": "attempt-a1",
                    "generation": 4
                },
                "target": {
                    "session_id": "session-b",
                    "execution_id": "execution-1",
                    "scope_id": "scope-b",
                    "attempt_id": "attempt-b2",
                    "generation": 7
                },
                "mode": "after_turn",
                "state": "queued",
                "durable_cursor": 108,
                "application_proven": false,
                "replayed": false,
                "hop_count": 1,
                "expires_at": "2026-08-10T15:04:05Z",
                "reply_summary": null
            })
        );
        let encoded = serde_json::to_vec(&receipt).unwrap();
        assert!(encoded.len() <= MAX_RECEIPT_BYTES);
        let round_trip: SessionMessageReceiptV1 = serde_json::from_slice(&encoded).unwrap();
        round_trip.validate().unwrap();
    }

    #[test]
    fn error_codes_and_payload_are_closed_and_bounded() {
        let error: SessionMessageErrorV1 = serde_json::from_value(json!({
            "version": 1,
            "broker_generation": 873421,
            "id": 42,
            "error": "session_message_error",
            "code": "nonce_conflict",
            "message": "request nonce was already used"
        }))
        .unwrap();
        assert_eq!(error.code, SessionMessageErrorCode::NonceConflict);

        let receipt_not_found: SessionMessageErrorV1 = serde_json::from_value(json!({
            "version": 1,
            "broker_generation": 873421,
            "id": 43,
            "error": "session_message_error",
            "code": "receipt_not_found",
            "message": "receipt is outside the retained replay window"
        }))
        .unwrap();
        assert_eq!(
            receipt_not_found.code,
            SessionMessageErrorCode::ReceiptNotFound
        );

        let mut unknown = serde_json::to_value(error).unwrap();
        unknown["detail"] = json!({"message": "must not leak"});
        assert!(serde_json::from_value::<SessionMessageErrorV1>(unknown).is_err());

        let oversized = json!({
            "version": 1,
            "broker_generation": 873421,
            "id": 42,
            "error": "session_message_error",
            "code": "internal",
            "message": "x".repeat(MAX_ERROR_MESSAGE_BYTES + 1)
        });
        assert!(serde_json::from_value::<SessionMessageErrorV1>(oversized).is_err());
    }
}
