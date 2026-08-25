//! Protocol-v4 ordered terminal state retained by the broker.
//!
//! This is deliberately independent of any terminal engine. Checkpoint bytes
//! are supplied by the broker's exact-pin engine adapter; this module owns only
//! sequence validation and a bounded post-checkpoint event window.

use std::collections::VecDeque;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StateEvent {
    pub state_seq: u64,
    pub payload: StateEventPayload,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum StateEventPayload {
    PtyBytes(Vec<u8>),
    Resize {
        columns: u16,
        rows: u16,
        cell_width_px: u16,
        cell_height_px: u16,
        layout_epoch: u64,
    },
    HistoryTrim {
        history_epoch: u64,
        first_retained_line: u64,
    },
    CanonicalCheckpoint {
        checkpoint_id: String,
    },
}

impl StateEventPayload {
    pub fn encoded_size(&self) -> usize {
        match self {
            Self::PtyBytes(bytes) => bytes.len(),
            Self::Resize { .. } => 2 * size_of::<u16>() + 2 * size_of::<u16>() + size_of::<u64>(),
            Self::HistoryTrim { .. } => 2 * size_of::<u64>(),
            Self::CanonicalCheckpoint { checkpoint_id } => checkpoint_id.len(),
        }
    }

    fn validate(&self) -> Result<(), OrderedStateError> {
        match self {
            Self::PtyBytes(bytes) if bytes.is_empty() => Err(OrderedStateError::EmptyEvent),
            Self::Resize {
                columns,
                rows,
                cell_width_px,
                cell_height_px,
                ..
            } if *columns == 0 || *rows == 0 || *cell_width_px == 0 || *cell_height_px == 0 => {
                Err(OrderedStateError::InvalidDimensions)
            }
            Self::CanonicalCheckpoint { checkpoint_id } if checkpoint_id.is_empty() => {
                Err(OrderedStateError::EmptyCheckpointId)
            }
            _ => Ok(()),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum OrderedStateError {
    EmptyEvent,
    InvalidDimensions,
    EmptyCheckpointId,
    SequenceGap { expected: u64, actual: u64 },
    ConflictingDuplicate { state_seq: u64 },
    CursorAhead { requested: u64, latest: u64 },
    WindowExceeded { requested: u64, first_retained: u64 },
    TailCapacityExceeded { maximum: usize, required: usize },
}

#[derive(Clone, Debug)]
pub struct OrderedStateLog {
    maximum_bytes: usize,
    retained_bytes: usize,
    latest_seq: u64,
    dropped_through: u64,
    events: VecDeque<StateEvent>,
}

impl OrderedStateLog {
    pub fn new(maximum_bytes: usize) -> Self {
        Self {
            maximum_bytes,
            retained_bytes: 0,
            latest_seq: 0,
            dropped_through: 0,
            events: VecDeque::new(),
        }
    }

    pub fn latest_seq(&self) -> u64 {
        self.latest_seq
    }

    pub fn retained_bytes(&self) -> usize {
        self.retained_bytes
    }

    pub fn maximum_bytes(&self) -> usize {
        self.maximum_bytes
    }

    pub fn dropped_through(&self) -> u64 {
        self.dropped_through
    }

    pub fn first_retained_seq(&self) -> u64 {
        self.events
            .front()
            .map_or(self.latest_seq.saturating_add(1), |event| event.state_seq)
    }

    /// Inserts one event. An exact duplicate is idempotent; a conflicting
    /// duplicate or a gap fails closed and leaves the log unchanged.
    pub fn push(&mut self, event: StateEvent) -> Result<bool, OrderedStateError> {
        event.payload.validate()?;
        if event.state_seq <= self.latest_seq {
            return match self
                .events
                .iter()
                .find(|retained| retained.state_seq == event.state_seq)
            {
                Some(retained) if retained == &event => Ok(false),
                _ => Err(OrderedStateError::ConflictingDuplicate {
                    state_seq: event.state_seq,
                }),
            };
        }
        let expected = self.latest_seq.saturating_add(1);
        if event.state_seq != expected {
            return Err(OrderedStateError::SequenceGap {
                expected,
                actual: event.state_seq,
            });
        }

        self.latest_seq = event.state_seq;
        let size = event.payload.encoded_size();
        if size > self.maximum_bytes {
            self.events.clear();
            self.retained_bytes = 0;
            self.dropped_through = event.state_seq;
            return Ok(true);
        }
        self.retained_bytes = self.retained_bytes.saturating_add(size);
        self.events.push_back(event);
        while self.retained_bytes > self.maximum_bytes {
            if let Some(removed) = self.events.pop_front() {
                self.retained_bytes = self
                    .retained_bytes
                    .saturating_sub(removed.payload.encoded_size());
                self.dropped_through = removed.state_seq;
            }
        }
        Ok(true)
    }

    /// Appends without evicting any event after an active engine checkpoint.
    /// Production recovery uses this after reserving tail capacity.
    pub fn push_preserving_tail(&mut self, event: StateEvent) -> Result<bool, OrderedStateError> {
        let required = self
            .retained_bytes
            .saturating_add(event.payload.encoded_size());
        if required > self.maximum_bytes {
            return Err(OrderedStateError::TailCapacityExceeded {
                maximum: self.maximum_bytes,
                required,
            });
        }
        self.push(event)
    }

    pub fn events_after(&self, state_seq: u64) -> Result<Vec<&StateEvent>, OrderedStateError> {
        if state_seq > self.latest_seq {
            return Err(OrderedStateError::CursorAhead {
                requested: state_seq,
                latest: self.latest_seq,
            });
        }
        if state_seq < self.dropped_through {
            return Err(OrderedStateError::WindowExceeded {
                requested: state_seq,
                first_retained: self.first_retained_seq(),
            });
        }
        Ok(self
            .events
            .iter()
            .filter(|event| event.state_seq > state_seq)
            .collect())
    }

    /// Removes events represented by an immutable checkpoint while
    /// preserving the monotonic sequence cursor for the next tail event.
    pub fn checkpoint_through(&mut self, state_seq: u64) -> Result<(), OrderedStateError> {
        if state_seq > self.latest_seq {
            return Err(OrderedStateError::CursorAhead {
                requested: state_seq,
                latest: self.latest_seq,
            });
        }
        while self
            .events
            .front()
            .is_some_and(|event| event.state_seq <= state_seq)
        {
            let removed = self.events.pop_front().expect("front was present");
            self.retained_bytes = self
                .retained_bytes
                .saturating_sub(removed.payload.encoded_size());
        }
        self.dropped_through = self.dropped_through.max(state_seq);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn output(state_seq: u64, byte: u8, count: usize) -> StateEvent {
        StateEvent {
            state_seq,
            payload: StateEventPayload::PtyBytes(vec![byte; count]),
        }
    }

    #[test]
    fn exact_duplicates_are_idempotent_but_conflicts_and_gaps_fail_closed() {
        let mut log = OrderedStateLog::new(16);
        assert_eq!(log.push(output(1, b'a', 1)), Ok(true));
        assert_eq!(log.push(output(1, b'a', 1)), Ok(false));
        assert_eq!(
            log.push(output(1, b'b', 1)),
            Err(OrderedStateError::ConflictingDuplicate { state_seq: 1 })
        );
        assert_eq!(
            log.push(output(3, b'c', 1)),
            Err(OrderedStateError::SequenceGap {
                expected: 2,
                actual: 3
            })
        );
        assert_eq!(log.latest_seq(), 1);
    }

    #[test]
    fn byte_eviction_requires_resync_without_returning_a_partial_tail() {
        let mut log = OrderedStateLog::new(4);
        log.push(output(1, b'a', 3)).unwrap();
        log.push(output(2, b'b', 3)).unwrap();
        assert!(matches!(
            log.events_after(0),
            Err(OrderedStateError::WindowExceeded { .. })
        ));
        assert_eq!(log.events_after(1).unwrap(), vec![&output(2, b'b', 3)]);
    }

    #[test]
    fn typed_resize_is_ordered_with_output() {
        let mut log = OrderedStateLog::new(1024);
        log.push(output(1, b'x', 1)).unwrap();
        log.push(StateEvent {
            state_seq: 2,
            payload: StateEventPayload::Resize {
                columns: 120,
                rows: 40,
                cell_width_px: 9,
                cell_height_px: 18,
                layout_epoch: 7,
            },
        })
        .unwrap();
        assert_eq!(log.events_after(0).unwrap().len(), 2);
        assert_eq!(log.latest_seq(), 2);
    }

    #[test]
    fn active_checkpoint_tail_never_evicts_to_accept_a_new_event() {
        let mut log = OrderedStateLog::new(4);
        log.push_preserving_tail(output(1, b'a', 3)).unwrap();
        assert_eq!(
            log.push_preserving_tail(output(2, b'b', 2)),
            Err(OrderedStateError::TailCapacityExceeded {
                maximum: 4,
                required: 5,
            })
        );
        assert_eq!(log.latest_seq(), 1);
        assert_eq!(log.dropped_through(), 0);
        assert_eq!(log.events_after(0).unwrap(), vec![&output(1, b'a', 3)]);
    }
}
