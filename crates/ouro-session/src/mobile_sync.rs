//! Bounded broker-to-client synchronization primitives.
//!
//! Desktop and paired mobile clients consume snapshots and ordered deltas. The
//! broker keeps PTY file descriptors and MCP capabilities private.

use std::collections::VecDeque;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TerminalSnapshot {
    pub terminal_id: String,
    pub generation: u64,
    pub cursor: u64,
    pub columns: u16,
    pub rows: u16,
    pub visible_screen: Vec<u8>,
    pub scrollback_tail: Vec<u8>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SnapshotLimits {
    pub max_visible_bytes: usize,
    pub max_scrollback_bytes: usize,
}

impl Default for SnapshotLimits {
    fn default() -> Self {
        Self {
            max_visible_bytes: 256 * 1024,
            max_scrollback_bytes: 2 * 1024 * 1024,
        }
    }
}

impl TerminalSnapshot {
    pub fn validate(&self, limits: SnapshotLimits) -> Result<(), SyncError> {
        if self.terminal_id.trim().is_empty() {
            return Err(SyncError::EmptyTerminalId);
        }
        if self.columns == 0 || self.rows == 0 {
            return Err(SyncError::InvalidDimensions);
        }
        if self.visible_screen.len() > limits.max_visible_bytes {
            return Err(SyncError::SnapshotTooLarge {
                field: SnapshotField::VisibleScreen,
                limit: limits.max_visible_bytes,
                actual: self.visible_screen.len(),
            });
        }
        if self.scrollback_tail.len() > limits.max_scrollback_bytes {
            return Err(SyncError::SnapshotTooLarge {
                field: SnapshotField::ScrollbackTail,
                limit: limits.max_scrollback_bytes,
                actual: self.scrollback_tail.len(),
            });
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TerminalDelta {
    pub terminal_id: String,
    pub generation: u64,
    pub cursor: u64,
    pub payload: TerminalDeltaPayload,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TerminalDeltaPayload {
    Output(Vec<u8>),
    Resize { columns: u16, rows: u16 },
}

impl TerminalDeltaPayload {
    /// Number of payload bytes retained against the bounded delta window.
    ///
    /// Output is already encoded as terminal bytes. A resize is encoded as
    /// two fixed-width, 16-bit dimensions.
    pub fn encoded_size(&self) -> usize {
        match self {
            Self::Output(bytes) => bytes.len(),
            Self::Resize { .. } => size_of::<u16>() * 2,
        }
    }

    fn validate(&self) -> Result<(), SyncError> {
        match self {
            Self::Output(bytes) if bytes.is_empty() => Err(SyncError::EmptyDelta),
            Self::Resize { columns, rows } if *columns == 0 || *rows == 0 => {
                Err(SyncError::InvalidDimensions)
            }
            Self::Output(_) | Self::Resize { .. } => Ok(()),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Resume<'a> {
    Deltas(Vec<&'a TerminalDelta>),
    SnapshotRequired(ResyncReason),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ResyncReason {
    BrokerRestarted,
    CursorAhead,
    DeltaWindowExceeded,
}

#[derive(Clone, Debug)]
pub struct DeltaWindow {
    generation: u64,
    maximum_bytes: usize,
    retained_bytes: usize,
    terminal_id: Option<String>,
    last_cursor: Option<u64>,
    dropped_through: Option<u64>,
    deltas: VecDeque<TerminalDelta>,
}

impl DeltaWindow {
    pub fn new(generation: u64, maximum_bytes: usize) -> Self {
        Self {
            generation,
            maximum_bytes,
            retained_bytes: 0,
            terminal_id: None,
            last_cursor: None,
            dropped_through: None,
            deltas: VecDeque::new(),
        }
    }

    pub fn retained_bytes(&self) -> usize {
        self.retained_bytes
    }

    pub fn push(&mut self, delta: TerminalDelta) -> Result<(), SyncError> {
        if delta.terminal_id.trim().is_empty() {
            return Err(SyncError::EmptyTerminalId);
        }
        delta.payload.validate()?;
        if let Some(expected) = &self.terminal_id {
            if expected != &delta.terminal_id {
                return Err(SyncError::TerminalMismatch);
            }
        } else {
            self.terminal_id = Some(delta.terminal_id.clone());
        }
        if delta.generation != self.generation {
            return Err(SyncError::GenerationMismatch {
                expected: self.generation,
                actual: delta.generation,
            });
        }
        if let Some(previous) = self.last_cursor {
            let expected = previous.saturating_add(1);
            if delta.cursor != expected {
                return Err(SyncError::NonMonotonicCursor {
                    expected,
                    actual: delta.cursor,
                });
            }
        }
        self.last_cursor = Some(delta.cursor);
        let payload_size = delta.payload.encoded_size();
        if payload_size > self.maximum_bytes {
            self.deltas.clear();
            self.retained_bytes = 0;
            self.dropped_through = Some(delta.cursor);
            return Ok(());
        }

        self.retained_bytes = self.retained_bytes.saturating_add(payload_size);
        self.deltas.push_back(delta);
        while self.retained_bytes > self.maximum_bytes {
            if let Some(removed) = self.deltas.pop_front() {
                self.retained_bytes = self
                    .retained_bytes
                    .saturating_sub(removed.payload.encoded_size());
                self.dropped_through = Some(removed.cursor);
            }
        }
        Ok(())
    }

    pub fn resume_after(&self, generation: u64, cursor: u64) -> Resume<'_> {
        if generation != self.generation {
            return Resume::SnapshotRequired(ResyncReason::BrokerRestarted);
        }
        if self.last_cursor.is_some_and(|last| cursor > last) {
            return Resume::SnapshotRequired(ResyncReason::CursorAhead);
        }
        if self.dropped_through.is_some_and(|dropped| cursor < dropped) {
            return Resume::SnapshotRequired(ResyncReason::DeltaWindowExceeded);
        }
        let Some(_) = self.deltas.back() else {
            return Resume::Deltas(Vec::new());
        };
        let first = self.deltas.front().expect("back implies front").cursor;
        if cursor.saturating_add(1) < first {
            return Resume::SnapshotRequired(ResyncReason::DeltaWindowExceeded);
        }
        Resume::Deltas(
            self.deltas
                .iter()
                .filter(|delta| delta.cursor > cursor)
                .collect(),
        )
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InputLease {
    pub lease_id: String,
    pub device_id: String,
    pub terminal_id: String,
    pub generation: u64,
    pub expires_at_millis: u64,
}

impl InputLease {
    pub fn authorize(
        &self,
        device_id: &str,
        terminal_id: &str,
        generation: u64,
        now_millis: u64,
    ) -> Result<(), LeaseError> {
        if self.device_id != device_id || self.terminal_id != terminal_id {
            return Err(LeaseError::WrongHolder);
        }
        if self.generation != generation {
            return Err(LeaseError::StaleGeneration);
        }
        if now_millis >= self.expires_at_millis {
            return Err(LeaseError::Expired);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SnapshotField {
    VisibleScreen,
    ScrollbackTail,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SyncError {
    EmptyTerminalId,
    EmptyDelta,
    TerminalMismatch,
    InvalidDimensions,
    SnapshotTooLarge {
        field: SnapshotField,
        limit: usize,
        actual: usize,
    },
    GenerationMismatch {
        expected: u64,
        actual: u64,
    },
    NonMonotonicCursor {
        expected: u64,
        actual: u64,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LeaseError {
    WrongHolder,
    StaleGeneration,
    Expired,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn delta(cursor: u64, bytes: usize) -> TerminalDelta {
        TerminalDelta {
            terminal_id: "term-1".into(),
            generation: 7,
            cursor,
            payload: TerminalDeltaPayload::Output(vec![b'x'; bytes]),
        }
    }

    fn resize_delta(cursor: u64, columns: u16, rows: u16) -> TerminalDelta {
        TerminalDelta {
            terminal_id: "term-1".into(),
            generation: 7,
            cursor,
            payload: TerminalDeltaPayload::Resize { columns, rows },
        }
    }

    #[test]
    fn slow_client_resyncs_after_the_byte_window_is_exceeded() {
        let mut window = DeltaWindow::new(7, 6);
        window.push(delta(10, 3)).unwrap();
        window.push(delta(11, 3)).unwrap();
        window.push(delta(12, 3)).unwrap();

        assert_eq!(window.retained_bytes(), 6);
        assert_eq!(
            window.resume_after(7, 9),
            Resume::SnapshotRequired(ResyncReason::DeltaWindowExceeded)
        );
        match window.resume_after(7, 10) {
            Resume::Deltas(values) => {
                assert_eq!(
                    values.iter().map(|value| value.cursor).collect::<Vec<_>>(),
                    vec![11, 12]
                );
            }
            other => panic!("expected retained deltas, got {other:?}"),
        }
    }

    #[test]
    fn broker_incarnation_change_requires_a_fresh_snapshot() {
        let window = DeltaWindow::new(7, 1024);
        assert_eq!(
            window.resume_after(8, 0),
            Resume::SnapshotRequired(ResyncReason::BrokerRestarted)
        );
    }

    #[test]
    fn window_rejects_empty_or_cross_terminal_deltas() {
        let mut window = DeltaWindow::new(7, 1024);
        let empty = delta(1, 0);
        assert_eq!(window.push(empty.clone()), Err(SyncError::EmptyDelta));

        window.push(delta(1, 1)).unwrap();
        let mut other = delta(2, 1);
        other.terminal_id = "term-2".into();
        assert_eq!(window.push(other), Err(SyncError::TerminalMismatch));
    }

    #[test]
    fn payloads_report_their_encoded_window_size() {
        assert_eq!(TerminalDeltaPayload::Output(vec![0; 13]).encoded_size(), 13);
        assert_eq!(
            TerminalDeltaPayload::Resize {
                columns: 120,
                rows: 40
            }
            .encoded_size(),
            4
        );
    }

    #[test]
    fn window_accounts_for_output_and_resize_payloads() {
        let mut window = DeltaWindow::new(7, 7);
        window.push(delta(10, 3)).unwrap();
        window.push(resize_delta(11, 120, 40)).unwrap();

        assert_eq!(window.retained_bytes(), 7);

        window.push(delta(12, 1)).unwrap();
        assert_eq!(window.retained_bytes(), 5);
        assert_eq!(
            window.resume_after(7, 9),
            Resume::SnapshotRequired(ResyncReason::DeltaWindowExceeded)
        );
        let Resume::Deltas(values) = window.resume_after(7, 10) else {
            panic!("expected retained resize and output deltas");
        };
        assert_eq!(values.len(), 2);
        assert!(matches!(
            &values[0].payload,
            TerminalDeltaPayload::Resize {
                columns: 120,
                rows: 40
            }
        ));
        assert_eq!(values[1].payload, TerminalDeltaPayload::Output(vec![b'x']));
    }

    #[test]
    fn window_rejects_zero_resize_dimensions_without_advancing_cursor() {
        let mut window = DeltaWindow::new(7, 1024);
        assert_eq!(
            window.push(resize_delta(1, 0, 40)),
            Err(SyncError::InvalidDimensions)
        );
        assert_eq!(
            window.push(resize_delta(1, 120, 0)),
            Err(SyncError::InvalidDimensions)
        );

        window.push(resize_delta(1, 120, 40)).unwrap();
        assert_eq!(window.retained_bytes(), 4);
    }

    #[test]
    fn generation_and_cursor_checks_apply_to_every_payload_type() {
        let mut window = DeltaWindow::new(7, 1024);
        let mut stale = delta(1, 1);
        stale.generation = 6;
        assert_eq!(
            window.push(stale),
            Err(SyncError::GenerationMismatch {
                expected: 7,
                actual: 6
            })
        );

        window.push(delta(1, 1)).unwrap();
        assert_eq!(
            window.push(resize_delta(3, 120, 40)),
            Err(SyncError::NonMonotonicCursor {
                expected: 2,
                actual: 3
            })
        );
        window.push(resize_delta(2, 120, 40)).unwrap();
        assert_eq!(window.retained_bytes(), 5);
    }

    #[test]
    fn one_oversized_delta_invalidates_older_resume_cursors() {
        let mut window = DeltaWindow::new(7, 4);
        window.push(delta(20, 8)).unwrap();
        assert_eq!(window.retained_bytes(), 0);
        assert_eq!(
            window.resume_after(7, 19),
            Resume::SnapshotRequired(ResyncReason::DeltaWindowExceeded)
        );
        assert_eq!(window.resume_after(7, 20), Resume::Deltas(Vec::new()));
    }

    #[test]
    fn lease_fails_closed_for_wrong_device_generation_or_time() {
        let lease = InputLease {
            lease_id: "lease-1".into(),
            device_id: "phone".into(),
            terminal_id: "term-1".into(),
            generation: 7,
            expires_at_millis: 1_000,
        };
        assert_eq!(lease.authorize("phone", "term-1", 7, 999), Ok(()));
        assert_eq!(
            lease.authorize("desktop", "term-1", 7, 999),
            Err(LeaseError::WrongHolder)
        );
        assert_eq!(
            lease.authorize("phone", "term-1", 6, 999),
            Err(LeaseError::StaleGeneration)
        );
        assert_eq!(
            lease.authorize("phone", "term-1", 7, 1_000),
            Err(LeaseError::Expired)
        );
    }

    #[test]
    fn snapshot_enforces_bounded_screen_and_scrollback() {
        let snapshot = TerminalSnapshot {
            terminal_id: "term-1".into(),
            generation: 7,
            cursor: 12,
            columns: 120,
            rows: 40,
            visible_screen: vec![0; 5],
            scrollback_tail: vec![0; 9],
        };
        assert_eq!(
            snapshot.validate(SnapshotLimits {
                max_visible_bytes: 4,
                max_scrollback_bytes: 10
            }),
            Err(SyncError::SnapshotTooLarge {
                field: SnapshotField::VisibleScreen,
                limit: 4,
                actual: 5,
            })
        );
    }
}
