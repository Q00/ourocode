//! Bounded stop-and-wait coordinator for the privileged principal-binding FD.
//!
//! The coordinator owns no installer or service authority. It only serializes
//! registry-prepared frames, requires an exact durable ACK before advancing,
//! and becomes permanently ambiguous after a possibly-visible transport
//! failure. Callers must roll the broker generation rather than retrying an
//! ambiguous registration automatically.

use crate::principal_binding_ack_wire::{
    decode_ack_frame, encode_registration, DurablyAcknowledgedPrincipalBindingV1,
    PrincipalBindingAckExpectationV1, PrincipalBindingAckResultV1, PrincipalBindingAckWireError,
    PrincipalBindingDispatchFrameV1,
};
use crate::principal_binding_registration::PrincipalBindingEnvelopeV1;
use crate::session_message::{BoundedId, MAX_WIRE_FRAME_BYTES};
use std::collections::{BTreeSet, VecDeque};
use std::fmt;
use std::num::NonZeroU64;

pub const MAX_PRINCIPAL_BINDING_QUEUE: usize = 16;
pub const MAX_PRINCIPAL_BINDING_QUEUE_BYTES: usize =
    MAX_PRINCIPAL_BINDING_QUEUE * (MAX_WIRE_FRAME_BYTES + 4);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PrincipalBindingCoordinatorPhase {
    Idle,
    Writing,
    AwaitingAck,
    DrainingAbandonedAck,
    Ambiguous,
    ProtocolFailed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PrincipalBindingTransportFailure {
    CleanIdle,
    RetryableUnsent,
    Ambiguous,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PrincipalBindingAbandonment {
    NothingPending,
    RemovedBeforeWrite,
    DrainingPossiblyDurable,
}

#[derive(Debug, Eq, PartialEq)]
pub enum PrincipalBindingAckCompletion {
    Durable(DurablyAcknowledgedPrincipalBindingV1),
    AbandonedButDurable(DurablyAcknowledgedPrincipalBindingV1),
}

impl PrincipalBindingAckCompletion {
    pub fn acknowledgement(&self) -> &DurablyAcknowledgedPrincipalBindingV1 {
        match self {
            Self::Durable(acknowledgement) | Self::AbandonedButDurable(acknowledgement) => {
                acknowledgement
            }
        }
    }

    pub fn into_acknowledgement(self) -> DurablyAcknowledgedPrincipalBindingV1 {
        match self {
            Self::Durable(acknowledgement) | Self::AbandonedButDurable(acknowledgement) => {
                acknowledgement
            }
        }
    }
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct BindingKey {
    binding_id: BoundedId,
    authority_epoch: u64,
}

impl BindingKey {
    fn from_expectation(expectation: &PrincipalBindingAckExpectationV1) -> Self {
        Self {
            binding_id: expectation.binding_id().clone(),
            authority_epoch: expectation.authority_epoch(),
        }
    }
}

struct PendingPrincipalBinding {
    frame: PrincipalBindingDispatchFrameV1,
    write_offset: usize,
    abandoned: bool,
}

impl PendingPrincipalBinding {
    fn new(frame: PrincipalBindingDispatchFrameV1) -> Self {
        Self {
            frame,
            write_offset: 0,
            abandoned: false,
        }
    }

    fn remaining(&self) -> &[u8] {
        &self.frame.bytes()[self.write_offset..]
    }
}

/// Single-descriptor coordinator. The current frame is always written and
/// acknowledged before another frame becomes writable.
pub struct PrincipalBindingAckCoordinator {
    broker_generation: NonZeroU64,
    phase: PrincipalBindingCoordinatorPhase,
    current: Option<PendingPrincipalBinding>,
    queued: VecDeque<PendingPrincipalBinding>,
    queued_bytes: usize,
    last_request_id: Option<NonZeroU64>,
    registrations_awaiting_revoke: BTreeSet<BindingKey>,
}

impl PrincipalBindingAckCoordinator {
    pub fn new(broker_generation: NonZeroU64) -> Self {
        Self {
            broker_generation,
            phase: PrincipalBindingCoordinatorPhase::Idle,
            current: None,
            queued: VecDeque::new(),
            queued_bytes: 0,
            last_request_id: None,
            registrations_awaiting_revoke: BTreeSet::new(),
        }
    }

    pub fn phase(&self) -> PrincipalBindingCoordinatorPhase {
        self.phase
    }

    pub fn queued_count(&self) -> usize {
        self.queued.len() + usize::from(self.current.is_some())
    }

    pub fn queued_bytes(&self) -> usize {
        self.queued_bytes
    }

    pub fn current_expectation(&self) -> Option<&PrincipalBindingAckExpectationV1> {
        self.current
            .as_ref()
            .map(|pending| pending.frame.expectation())
    }

    pub fn enqueue(
        &mut self,
        envelope: PrincipalBindingEnvelopeV1,
    ) -> Result<(), PrincipalBindingCoordinatorError> {
        self.ensure_operational()?;
        let frame =
            encode_registration(envelope).map_err(PrincipalBindingCoordinatorError::Wire)?;
        let expectation = frame.expectation();
        if expectation.broker_generation() != self.broker_generation {
            return Err(PrincipalBindingCoordinatorError::WrongGeneration);
        }
        if self
            .last_request_id
            .is_some_and(|last| expectation.request_id() <= last)
        {
            return Err(PrincipalBindingCoordinatorError::NonMonotonicRequestId);
        }
        if self.queued_count() >= MAX_PRINCIPAL_BINDING_QUEUE {
            return Err(PrincipalBindingCoordinatorError::QueueFull);
        }
        let next_bytes = self
            .queued_bytes
            .checked_add(frame.bytes().len())
            .ok_or(PrincipalBindingCoordinatorError::QueueBytesExceeded)?;
        if next_bytes > MAX_PRINCIPAL_BINDING_QUEUE_BYTES {
            return Err(PrincipalBindingCoordinatorError::QueueBytesExceeded);
        }
        let key = BindingKey::from_expectation(expectation);
        if expectation.result() == PrincipalBindingAckResultV1::Registered
            && (self.registrations_awaiting_revoke.contains(&key)
                || self.pending_registration_contains(&key))
        {
            return Err(PrincipalBindingCoordinatorError::BindingAwaitingRevoke);
        }

        self.last_request_id = Some(expectation.request_id());
        self.queued_bytes = next_bytes;
        self.queued.push_back(PendingPrincipalBinding::new(frame));
        Ok(())
    }

    /// Returns at most `maximum` bytes from the one writable frame. Advancing
    /// the cursor requires a matching `record_written` call.
    pub fn writable_bytes(
        &mut self,
        maximum: usize,
    ) -> Result<Option<&[u8]>, PrincipalBindingCoordinatorError> {
        self.ensure_operational()?;
        if maximum == 0 {
            return Ok(None);
        }
        self.promote_next();
        if self.phase != PrincipalBindingCoordinatorPhase::Writing {
            return Ok(None);
        }
        let pending = self.current.as_ref().expect("writing has a current frame");
        let length = pending.remaining().len().min(maximum);
        Ok(Some(&pending.remaining()[..length]))
    }

    pub fn record_written(
        &mut self,
        byte_count: usize,
    ) -> Result<(), PrincipalBindingCoordinatorError> {
        self.ensure_operational()?;
        if self.phase != PrincipalBindingCoordinatorPhase::Writing {
            return Err(PrincipalBindingCoordinatorError::InvalidPhase);
        }
        let pending = self.current.as_mut().expect("writing has a current frame");
        if byte_count == 0 || byte_count > pending.remaining().len() {
            self.phase = PrincipalBindingCoordinatorPhase::ProtocolFailed;
            return Err(PrincipalBindingCoordinatorError::InvalidWriteAdvance);
        }
        pending.write_offset += byte_count;
        if pending.remaining().is_empty() {
            self.phase = if pending.abandoned {
                PrincipalBindingCoordinatorPhase::DrainingAbandonedAck
            } else {
                PrincipalBindingCoordinatorPhase::AwaitingAck
            };
        }
        Ok(())
    }

    /// Complete the current stop-and-wait transaction. A malformed or
    /// mismatched ACK leaves the durable outcome unknown and permanently closes
    /// this coordinator to further writes.
    pub fn acknowledge(
        &mut self,
        frame: &[u8],
    ) -> Result<PrincipalBindingAckCompletion, PrincipalBindingCoordinatorError> {
        self.ensure_operational()?;
        if !matches!(
            self.phase,
            PrincipalBindingCoordinatorPhase::AwaitingAck
                | PrincipalBindingCoordinatorPhase::DrainingAbandonedAck
        ) {
            return Err(PrincipalBindingCoordinatorError::InvalidPhase);
        }
        let pending = self
            .current
            .as_ref()
            .expect("ACK phase has a current frame");
        let acknowledgement = match decode_ack_frame(pending.frame.expectation(), frame) {
            Ok(value) => value,
            Err(error) => {
                self.phase = PrincipalBindingCoordinatorPhase::Ambiguous;
                return Err(PrincipalBindingCoordinatorError::Wire(error));
            }
        };
        let key = BindingKey::from_expectation(pending.frame.expectation());
        match acknowledgement.result() {
            PrincipalBindingAckResultV1::Registered => {
                self.registrations_awaiting_revoke.insert(key);
            }
            PrincipalBindingAckResultV1::Revoked => {
                self.registrations_awaiting_revoke.remove(&key);
            }
        }
        let abandoned = pending.abandoned;
        let completed = self.current.take().expect("ACK phase has a current frame");
        self.queued_bytes = self
            .queued_bytes
            .saturating_sub(completed.frame.bytes().len());
        self.phase = PrincipalBindingCoordinatorPhase::Idle;
        Ok(if abandoned {
            PrincipalBindingAckCompletion::AbandonedButDurable(acknowledgement)
        } else {
            PrincipalBindingAckCompletion::Durable(acknowledgement)
        })
    }

    /// Abandoning an unsent operation removes it. Once any byte might have
    /// reached the service, the coordinator finishes the exact frame and drains
    /// its exact ACK; a durable registration is surfaced so the caller can send
    /// a compensating revoke.
    pub fn abandon_current(&mut self) -> PrincipalBindingAbandonment {
        if matches!(
            self.phase,
            PrincipalBindingCoordinatorPhase::Ambiguous
                | PrincipalBindingCoordinatorPhase::ProtocolFailed
        ) {
            return PrincipalBindingAbandonment::DrainingPossiblyDurable;
        }
        let Some(pending) = self.current.as_mut() else {
            return PrincipalBindingAbandonment::NothingPending;
        };
        if pending.write_offset == 0 {
            let removed = self.current.take().expect("current frame exists");
            self.queued_bytes = self
                .queued_bytes
                .saturating_sub(removed.frame.bytes().len());
            self.phase = PrincipalBindingCoordinatorPhase::Idle;
            PrincipalBindingAbandonment::RemovedBeforeWrite
        } else {
            pending.abandoned = true;
            if pending.remaining().is_empty() {
                self.phase = PrincipalBindingCoordinatorPhase::DrainingAbandonedAck;
            }
            PrincipalBindingAbandonment::DrainingPossiblyDurable
        }
    }

    /// Report descriptor failure. Zero tracked bytes are safe to retry with the
    /// same ID; any partial/full write is ambiguous and forbids automatic
    /// registration on this coordinator.
    pub fn transport_failed(&mut self) -> PrincipalBindingTransportFailure {
        let Some(pending) = self.current.as_ref() else {
            return PrincipalBindingTransportFailure::CleanIdle;
        };
        if pending.write_offset == 0 {
            self.phase = PrincipalBindingCoordinatorPhase::Writing;
            PrincipalBindingTransportFailure::RetryableUnsent
        } else {
            self.phase = PrincipalBindingCoordinatorPhase::Ambiguous;
            PrincipalBindingTransportFailure::Ambiguous
        }
    }

    fn promote_next(&mut self) {
        if self.phase == PrincipalBindingCoordinatorPhase::Idle && self.current.is_none() {
            if let Some(next) = self.queued.pop_front() {
                self.current = Some(next);
                self.phase = PrincipalBindingCoordinatorPhase::Writing;
            }
        }
    }

    fn ensure_operational(&self) -> Result<(), PrincipalBindingCoordinatorError> {
        match self.phase {
            PrincipalBindingCoordinatorPhase::Ambiguous => {
                Err(PrincipalBindingCoordinatorError::Ambiguous)
            }
            PrincipalBindingCoordinatorPhase::ProtocolFailed => {
                Err(PrincipalBindingCoordinatorError::ProtocolFailed)
            }
            _ => Ok(()),
        }
    }

    fn pending_registration_contains(&self, key: &BindingKey) -> bool {
        self.current
            .iter()
            .chain(self.queued.iter())
            .any(|pending| {
                pending.frame.expectation().result() == PrincipalBindingAckResultV1::Registered
                    && BindingKey::from_expectation(pending.frame.expectation()) == *key
            })
    }
}

#[derive(Debug)]
pub enum PrincipalBindingCoordinatorError {
    Wire(PrincipalBindingAckWireError),
    WrongGeneration,
    NonMonotonicRequestId,
    QueueFull,
    QueueBytesExceeded,
    BindingAwaitingRevoke,
    InvalidPhase,
    InvalidWriteAdvance,
    Ambiguous,
    ProtocolFailed,
}

impl fmt::Display for PrincipalBindingCoordinatorError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Wire(_) => "principal-binding wire operation failed",
            Self::WrongGeneration => "principal-binding request has the wrong broker generation",
            Self::NonMonotonicRequestId => {
                "principal-binding request ID is not strictly increasing"
            }
            Self::QueueFull => "principal-binding queue reached its item bound",
            Self::QueueBytesExceeded => "principal-binding queue reached its byte bound",
            Self::BindingAwaitingRevoke => "principal binding must be durably revoked before reuse",
            Self::InvalidPhase => "principal-binding coordinator is in the wrong phase",
            Self::InvalidWriteAdvance => "principal-binding write cursor advance is invalid",
            Self::Ambiguous => "principal-binding durable outcome is ambiguous",
            Self::ProtocolFailed => "principal-binding coordinator protocol has failed",
        })
    }
}

impl std::error::Error for PrincipalBindingCoordinatorError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Wire(error) => Some(error),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::principal_binding_registration::{
        PrincipalBindingEnvelopeV1, VerifiedInstallationAuthorityV1,
    };
    use crate::session_message::Timestamp;
    use serde_json::json;

    const GENERATION: u64 = 873_421;

    fn nonzero(value: u64) -> NonZeroU64 {
        NonZeroU64::new(value).unwrap()
    }

    fn id(value: impl AsRef<str>) -> BoundedId {
        BoundedId::try_from(value.as_ref()).unwrap()
    }

    fn registration(request_id: u64, binding: &str, epoch: u64) -> PrincipalBindingEnvelopeV1 {
        let policy = VerifiedInstallationAuthorityV1::from_verified_installation(
            id("workspace-a"),
            id("forest-a"),
        );
        PrincipalBindingEnvelopeV1::signed_desktop(
            nonzero(request_id),
            nonzero(GENERATION),
            id(binding),
            501,
            epoch,
            &policy,
            [0x44; 32],
            [0x24; 24],
            Timestamp::parse("2099-08-10T15:08:00Z").unwrap(),
        )
    }

    fn revoke(request_id: u64, binding: &str, epoch: u64) -> PrincipalBindingEnvelopeV1 {
        PrincipalBindingEnvelopeV1::revoke(
            nonzero(request_id),
            nonzero(GENERATION),
            id(binding),
            epoch,
        )
    }

    fn ack_frame(expectation: &PrincipalBindingAckExpectationV1) -> Vec<u8> {
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
            "changed": true
        }))
        .unwrap();
        let mut frame = Vec::with_capacity(4 + payload.len());
        frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        frame.extend_from_slice(&payload);
        frame
    }

    fn finish_write(coordinator: &mut PrincipalBindingAckCoordinator, chunk: usize) {
        while coordinator.phase() != PrincipalBindingCoordinatorPhase::AwaitingAck
            && coordinator.phase() != PrincipalBindingCoordinatorPhase::DrainingAbandonedAck
        {
            let length = coordinator.writable_bytes(chunk).unwrap().unwrap().len();
            coordinator.record_written(length).unwrap();
        }
    }

    fn acknowledge_current(
        coordinator: &mut PrincipalBindingAckCoordinator,
    ) -> PrincipalBindingAckCompletion {
        let frame = ack_frame(coordinator.current_expectation().unwrap());
        coordinator.acknowledge(&frame).unwrap()
    }

    #[test]
    fn queue_is_stop_and_wait_even_with_partial_writes() {
        let mut coordinator = PrincipalBindingAckCoordinator::new(nonzero(GENERATION));
        coordinator
            .enqueue(registration(1, "binding-a", 3))
            .unwrap();
        coordinator
            .enqueue(registration(2, "binding-b", 4))
            .unwrap();

        finish_write(&mut coordinator, 7);
        assert_eq!(
            coordinator.phase(),
            PrincipalBindingCoordinatorPhase::AwaitingAck
        );
        assert!(coordinator.writable_bytes(64).unwrap().is_none());
        let first = acknowledge_current(&mut coordinator);
        assert_eq!(first.acknowledgement().binding_id(), &id("binding-a"));

        finish_write(&mut coordinator, usize::MAX);
        let second = acknowledge_current(&mut coordinator);
        assert_eq!(second.acknowledgement().binding_id(), &id("binding-b"));
        assert_eq!(coordinator.phase(), PrincipalBindingCoordinatorPhase::Idle);
        assert_eq!(coordinator.queued_count(), 0);
        assert_eq!(coordinator.queued_bytes(), 0);
    }

    #[test]
    fn item_queue_is_hard_bounded() {
        let mut coordinator = PrincipalBindingAckCoordinator::new(nonzero(GENERATION));
        for request_id in 1..=MAX_PRINCIPAL_BINDING_QUEUE as u64 {
            coordinator
                .enqueue(registration(
                    request_id,
                    &format!("binding-{request_id}"),
                    request_id,
                ))
                .unwrap();
        }
        assert_eq!(coordinator.queued_count(), MAX_PRINCIPAL_BINDING_QUEUE);
        assert!(matches!(
            coordinator.enqueue(registration(17, "binding-17", 17)),
            Err(PrincipalBindingCoordinatorError::QueueFull)
        ));
    }

    #[test]
    fn failure_after_any_write_is_ambiguous_and_permanently_fail_closed() {
        let mut coordinator = PrincipalBindingAckCoordinator::new(nonzero(GENERATION));
        coordinator
            .enqueue(registration(1, "binding-a", 3))
            .unwrap();
        let written = coordinator.writable_bytes(1).unwrap().unwrap().len();
        coordinator.record_written(written).unwrap();
        assert_eq!(
            coordinator.transport_failed(),
            PrincipalBindingTransportFailure::Ambiguous
        );
        assert_eq!(
            coordinator.phase(),
            PrincipalBindingCoordinatorPhase::Ambiguous
        );
        assert!(matches!(
            coordinator.enqueue(registration(2, "binding-b", 4)),
            Err(PrincipalBindingCoordinatorError::Ambiguous)
        ));
        assert!(matches!(
            coordinator.writable_bytes(64),
            Err(PrincipalBindingCoordinatorError::Ambiguous)
        ));
    }

    #[test]
    fn failure_before_a_tracked_write_retries_only_the_same_frame() {
        let mut coordinator = PrincipalBindingAckCoordinator::new(nonzero(GENERATION));
        coordinator
            .enqueue(registration(1, "binding-a", 3))
            .unwrap();
        let before = coordinator
            .writable_bytes(usize::MAX)
            .unwrap()
            .unwrap()
            .to_vec();
        assert_eq!(
            coordinator.transport_failed(),
            PrincipalBindingTransportFailure::RetryableUnsent
        );
        let after = coordinator
            .writable_bytes(usize::MAX)
            .unwrap()
            .unwrap()
            .to_vec();
        assert_eq!(before, after);
    }

    #[test]
    fn mismatched_ack_makes_the_durable_outcome_ambiguous() {
        let mut coordinator = PrincipalBindingAckCoordinator::new(nonzero(GENERATION));
        coordinator
            .enqueue(registration(1, "binding-a", 3))
            .unwrap();
        finish_write(&mut coordinator, usize::MAX);
        let mut wrong = ack_frame(coordinator.current_expectation().unwrap());
        let payload_length = u32::from_be_bytes(wrong[..4].try_into().unwrap()) as usize;
        let mut value: serde_json::Value = serde_json::from_slice(&wrong[4..]).unwrap();
        value["authority_epoch"] = json!(4);
        let payload = serde_json::to_vec(&value).unwrap();
        wrong.clear();
        wrong.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        wrong.extend_from_slice(&payload);
        assert_ne!(payload_length, 0);

        assert!(matches!(
            coordinator.acknowledge(&wrong),
            Err(PrincipalBindingCoordinatorError::Wire(
                PrincipalBindingAckWireError::IdentityMismatch
            ))
        ));
        assert_eq!(
            coordinator.phase(),
            PrincipalBindingCoordinatorPhase::Ambiguous
        );
    }

    #[test]
    fn abandoned_visible_registration_is_drained_then_requires_exact_revoke() {
        let mut coordinator = PrincipalBindingAckCoordinator::new(nonzero(GENERATION));
        coordinator
            .enqueue(registration(1, "binding-a", 3))
            .unwrap();
        let written = coordinator.writable_bytes(9).unwrap().unwrap().len();
        coordinator.record_written(written).unwrap();
        assert_eq!(
            coordinator.abandon_current(),
            PrincipalBindingAbandonment::DrainingPossiblyDurable
        );
        finish_write(&mut coordinator, 9);
        assert!(matches!(
            acknowledge_current(&mut coordinator),
            PrincipalBindingAckCompletion::AbandonedButDurable(_)
        ));

        assert!(matches!(
            coordinator.enqueue(registration(2, "binding-a", 3)),
            Err(PrincipalBindingCoordinatorError::BindingAwaitingRevoke)
        ));
        coordinator.enqueue(revoke(3, "binding-a", 3)).unwrap();
        finish_write(&mut coordinator, usize::MAX);
        assert!(matches!(
            acknowledge_current(&mut coordinator),
            PrincipalBindingAckCompletion::Durable(_)
        ));
        coordinator
            .enqueue(registration(4, "binding-a", 3))
            .unwrap();
    }

    #[test]
    fn abandonment_before_write_removes_frame_without_durable_effect() {
        let mut coordinator = PrincipalBindingAckCoordinator::new(nonzero(GENERATION));
        coordinator
            .enqueue(registration(1, "binding-a", 3))
            .unwrap();
        assert!(coordinator.writable_bytes(8).unwrap().is_some());
        assert_eq!(
            coordinator.abandon_current(),
            PrincipalBindingAbandonment::RemovedBeforeWrite
        );
        assert_eq!(coordinator.queued_count(), 0);
        assert_eq!(coordinator.queued_bytes(), 0);
    }

    #[test]
    fn request_ids_are_strictly_monotonic_and_generation_is_exact() {
        let mut coordinator = PrincipalBindingAckCoordinator::new(nonzero(GENERATION));
        coordinator
            .enqueue(registration(2, "binding-a", 3))
            .unwrap();
        assert!(matches!(
            coordinator.enqueue(registration(2, "binding-b", 4)),
            Err(PrincipalBindingCoordinatorError::NonMonotonicRequestId)
        ));

        let wrong_generation = PrincipalBindingEnvelopeV1::revoke(
            nonzero(3),
            nonzero(GENERATION + 1),
            id("binding-c"),
            5,
        );
        assert!(matches!(
            coordinator.enqueue(wrong_generation),
            Err(PrincipalBindingCoordinatorError::WrongGeneration)
        ));
    }
}
