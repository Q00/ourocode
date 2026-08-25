//! Bounded, server-authoritative session projection for Ourocode Desktop.
//!
//! Ouroboros fanout is a forest: each session has at most one parent. Cross-session
//! messages belong in an append-only audit log, not in this topology structure.

use std::collections::{HashMap, HashSet};

pub mod mobile_sync;
pub mod recovery_v4;
pub mod split_layout;

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct SessionId(String);

impl SessionId {
    pub fn new(value: impl Into<String>) -> Result<Self, ProjectionError> {
        let value = value.into();
        if value.trim().is_empty() {
            return Err(ProjectionError::EmptySessionId);
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionStatus {
    Queued,
    Running,
    Waiting,
    Completed,
    Failed,
    Cancelled,
    Stale,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SurfaceKind {
    Pty(u64),
    Transcript(String),
    None,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionSnapshot {
    pub id: SessionId,
    pub parent_id: Option<SessionId>,
    pub attempt_id: Option<String>,
    pub label: String,
    pub status: SessionStatus,
    pub seq: u64,
    pub surface: SurfaceKind,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionRow {
    pub id: SessionId,
    pub parent_id: Option<SessionId>,
    pub attempt_id: Option<String>,
    pub label: String,
    pub status: SessionStatus,
    pub last_seq: u64,
    pub unread: u32,
    pub surface: SurfaceKind,
}

impl From<SessionSnapshot> for SessionRow {
    fn from(snapshot: SessionSnapshot) -> Self {
        Self {
            id: snapshot.id,
            parent_id: snapshot.parent_id,
            attempt_id: snapshot.attempt_id,
            label: snapshot.label,
            status: snapshot.status,
            last_seq: snapshot.seq,
            unread: 0,
            surface: snapshot.surface,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ProjectionLimits {
    pub max_sessions: usize,
    pub max_children_per_session: usize,
}

impl Default for ProjectionLimits {
    fn default() -> Self {
        Self {
            max_sessions: 4_096,
            max_children_per_session: 256,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SessionEventKind {
    Created {
        parent_id: Option<SessionId>,
        attempt_id: Option<String>,
        label: String,
        status: SessionStatus,
        surface: SurfaceKind,
    },
    StatusChanged(SessionStatus),
    AttemptChanged(Option<String>),
    SurfaceChanged(SurfaceKind),
    UnreadIncremented(u32),
    Read,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionEvent {
    pub session_id: SessionId,
    pub seq: u64,
    pub kind: SessionEventKind,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ApplyOutcome {
    Applied,
    Duplicate,
    Gap { expected: u64, actual: u64 },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProjectionError {
    EmptySessionId,
    DuplicateSession(SessionId),
    MissingSession(SessionId),
    MissingParent(SessionId),
    Cycle(SessionId),
    SessionLimit { limit: usize },
    ChildLimit { parent: SessionId, limit: usize },
    CreationSequenceMustStartAtOne { session: SessionId, actual: u64 },
}

#[derive(Debug)]
pub struct SessionForest {
    rows: HashMap<SessionId, SessionRow>,
    children: HashMap<SessionId, Vec<SessionId>>,
    roots: Vec<SessionId>,
    selected: Option<SessionId>,
    limits: ProjectionLimits,
}

impl Default for SessionForest {
    fn default() -> Self {
        Self::new(ProjectionLimits::default())
    }
}

impl SessionForest {
    pub fn new(limits: ProjectionLimits) -> Self {
        Self {
            rows: HashMap::new(),
            children: HashMap::new(),
            roots: Vec::new(),
            selected: None,
            limits,
        }
    }

    pub fn len(&self) -> usize {
        self.rows.len()
    }

    pub fn is_empty(&self) -> bool {
        self.rows.is_empty()
    }

    pub fn row(&self, id: &SessionId) -> Option<&SessionRow> {
        self.rows.get(id)
    }

    pub fn selected(&self) -> Option<&SessionId> {
        self.selected.as_ref()
    }

    pub fn select(&mut self, id: &SessionId) -> Result<(), ProjectionError> {
        if !self.rows.contains_key(id) {
            return Err(ProjectionError::MissingSession(id.clone()));
        }
        self.selected = Some(id.clone());
        Ok(())
    }

    /// Atomically replaces the forest from an authoritative recovery snapshot.
    pub fn replace_snapshot(
        &mut self,
        snapshots: Vec<SessionSnapshot>,
    ) -> Result<(), ProjectionError> {
        if snapshots.len() > self.limits.max_sessions {
            return Err(ProjectionError::SessionLimit {
                limit: self.limits.max_sessions,
            });
        }

        let mut rows = HashMap::with_capacity(snapshots.len());
        for snapshot in snapshots {
            let id = snapshot.id.clone();
            if rows
                .insert(id.clone(), SessionRow::from(snapshot))
                .is_some()
            {
                return Err(ProjectionError::DuplicateSession(id));
            }
        }

        let mut children: HashMap<SessionId, Vec<SessionId>> = HashMap::new();
        let mut roots = Vec::new();

        for row in rows.values() {
            match &row.parent_id {
                Some(parent_id) => {
                    if !rows.contains_key(parent_id) {
                        return Err(ProjectionError::MissingParent(parent_id.clone()));
                    }
                    let siblings = children.entry(parent_id.clone()).or_default();
                    if siblings.len() >= self.limits.max_children_per_session {
                        return Err(ProjectionError::ChildLimit {
                            parent: parent_id.clone(),
                            limit: self.limits.max_children_per_session,
                        });
                    }
                    siblings.push(row.id.clone());
                }
                None => roots.push(row.id.clone()),
            }
        }

        validate_acyclic(&rows)?;
        sort_topology(&rows, &mut roots, &mut children);

        let selected = self.selected.take().filter(|id| rows.contains_key(id));
        self.rows = rows;
        self.children = children;
        self.roots = roots;
        self.selected = selected.or_else(|| self.roots.first().cloned());
        Ok(())
    }

    pub fn apply(&mut self, event: SessionEvent) -> Result<ApplyOutcome, ProjectionError> {
        if let Some(row) = self.rows.get(&event.session_id) {
            if event.seq <= row.last_seq {
                return Ok(ApplyOutcome::Duplicate);
            }
            let expected = row.last_seq.saturating_add(1);
            if event.seq != expected {
                return Ok(ApplyOutcome::Gap {
                    expected,
                    actual: event.seq,
                });
            }
        } else if event.seq != 1 {
            return Err(ProjectionError::CreationSequenceMustStartAtOne {
                session: event.session_id,
                actual: event.seq,
            });
        }

        match event.kind {
            SessionEventKind::Created {
                parent_id,
                attempt_id,
                label,
                status,
                surface,
            } => self.insert_created(
                event.session_id,
                parent_id,
                attempt_id,
                label,
                status,
                surface,
                event.seq,
            )?,
            kind => {
                let row = self
                    .rows
                    .get_mut(&event.session_id)
                    .ok_or_else(|| ProjectionError::MissingSession(event.session_id.clone()))?;
                match kind {
                    SessionEventKind::StatusChanged(status) => row.status = status,
                    SessionEventKind::AttemptChanged(attempt_id) => row.attempt_id = attempt_id,
                    SessionEventKind::SurfaceChanged(surface) => row.surface = surface,
                    SessionEventKind::UnreadIncremented(amount) => {
                        row.unread = row.unread.saturating_add(amount)
                    }
                    SessionEventKind::Read => row.unread = 0,
                    SessionEventKind::Created { .. } => unreachable!(),
                }
                row.last_seq = event.seq;
            }
        }

        Ok(ApplyOutcome::Applied)
    }

    pub fn visible_rows(&self) -> Vec<(usize, &SessionRow)> {
        let mut output = Vec::with_capacity(self.rows.len());
        for root in &self.roots {
            self.visit(root, 0, &mut output);
        }
        output
    }

    #[allow(clippy::too_many_arguments)]
    fn insert_created(
        &mut self,
        id: SessionId,
        parent_id: Option<SessionId>,
        attempt_id: Option<String>,
        label: String,
        status: SessionStatus,
        surface: SurfaceKind,
        seq: u64,
    ) -> Result<(), ProjectionError> {
        if self.rows.contains_key(&id) {
            return Err(ProjectionError::DuplicateSession(id));
        }
        if self.rows.len() >= self.limits.max_sessions {
            return Err(ProjectionError::SessionLimit {
                limit: self.limits.max_sessions,
            });
        }

        if let Some(parent) = &parent_id {
            if !self.rows.contains_key(parent) {
                return Err(ProjectionError::MissingParent(parent.clone()));
            }
            let siblings = self.children.entry(parent.clone()).or_default();
            if siblings.len() >= self.limits.max_children_per_session {
                return Err(ProjectionError::ChildLimit {
                    parent: parent.clone(),
                    limit: self.limits.max_children_per_session,
                });
            }
            siblings.push(id.clone());
        } else {
            self.roots.push(id.clone());
        }

        self.rows.insert(
            id.clone(),
            SessionRow {
                id: id.clone(),
                parent_id,
                attempt_id,
                label,
                status,
                last_seq: seq,
                unread: 0,
                surface,
            },
        );
        self.sort_branch(&id);
        if self.selected.is_none() {
            self.selected = Some(id);
        }
        Ok(())
    }

    fn sort_branch(&mut self, id: &SessionId) {
        if let Some(parent) = self.rows.get(id).and_then(|row| row.parent_id.clone()) {
            if let Some(children) = self.children.get_mut(&parent) {
                children.sort_by(|left, right| row_order(&self.rows, left, right));
            }
        } else {
            self.roots
                .sort_by(|left, right| row_order(&self.rows, left, right));
        }
    }

    fn visit<'a>(
        &'a self,
        id: &SessionId,
        depth: usize,
        output: &mut Vec<(usize, &'a SessionRow)>,
    ) {
        let Some(row) = self.rows.get(id) else {
            return;
        };
        output.push((depth, row));
        if let Some(children) = self.children.get(id) {
            for child in children {
                self.visit(child, depth + 1, output);
            }
        }
    }
}

fn row_order(
    rows: &HashMap<SessionId, SessionRow>,
    left: &SessionId,
    right: &SessionId,
) -> std::cmp::Ordering {
    let left_row = rows.get(left);
    let right_row = rows.get(right);
    left_row
        .map(|row| row.label.as_str())
        .cmp(&right_row.map(|row| row.label.as_str()))
        .then_with(|| left.as_str().cmp(right.as_str()))
}

fn sort_topology(
    rows: &HashMap<SessionId, SessionRow>,
    roots: &mut [SessionId],
    children: &mut HashMap<SessionId, Vec<SessionId>>,
) {
    roots.sort_by(|left, right| row_order(rows, left, right));
    for siblings in children.values_mut() {
        siblings.sort_by(|left, right| row_order(rows, left, right));
    }
}

fn validate_acyclic(rows: &HashMap<SessionId, SessionRow>) -> Result<(), ProjectionError> {
    for start in rows.keys() {
        let mut path = HashSet::new();
        let mut cursor = Some(start);
        while let Some(id) = cursor {
            if !path.insert(id.clone()) {
                return Err(ProjectionError::Cycle(id.clone()));
            }
            cursor = rows.get(id).and_then(|row| row.parent_id.as_ref());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(value: &str) -> SessionId {
        SessionId::new(value).unwrap()
    }

    fn snapshot(value: &str, parent: Option<&str>, label: &str) -> SessionSnapshot {
        SessionSnapshot {
            id: id(value),
            parent_id: parent.map(id),
            attempt_id: None,
            label: label.to_owned(),
            status: SessionStatus::Running,
            seq: 7,
            surface: SurfaceKind::Transcript(format!("stream:{value}")),
        }
    }

    #[test]
    fn replaces_an_unordered_snapshot_with_a_stable_forest() {
        let mut forest = SessionForest::default();
        forest
            .replace_snapshot(vec![
                snapshot("child-b", Some("root"), "Beta"),
                snapshot("root", None, "Root"),
                snapshot("child-a", Some("root"), "Alpha"),
            ])
            .unwrap();

        let visible: Vec<_> = forest
            .visible_rows()
            .into_iter()
            .map(|(depth, row)| (depth, row.id.as_str()))
            .collect();
        assert_eq!(visible, vec![(0, "root"), (1, "child-a"), (1, "child-b")]);
        assert_eq!(forest.selected(), Some(&id("root")));
    }

    #[test]
    fn duplicate_is_ignored_and_a_gap_requires_recovery() {
        let mut forest = SessionForest::default();
        forest
            .replace_snapshot(vec![snapshot("root", None, "Root")])
            .unwrap();

        let duplicate = SessionEvent {
            session_id: id("root"),
            seq: 7,
            kind: SessionEventKind::StatusChanged(SessionStatus::Completed),
        };
        assert_eq!(forest.apply(duplicate).unwrap(), ApplyOutcome::Duplicate);

        let gap = SessionEvent {
            session_id: id("root"),
            seq: 9,
            kind: SessionEventKind::StatusChanged(SessionStatus::Completed),
        };
        assert_eq!(
            forest.apply(gap).unwrap(),
            ApplyOutcome::Gap {
                expected: 8,
                actual: 9
            }
        );
        assert_eq!(
            forest.row(&id("root")).unwrap().status,
            SessionStatus::Running
        );
    }

    #[test]
    fn rejects_orphans_and_cycles_in_authoritative_snapshots() {
        let mut forest = SessionForest::default();
        let orphan = forest.replace_snapshot(vec![snapshot("child", Some("missing"), "Child")]);
        assert_eq!(orphan, Err(ProjectionError::MissingParent(id("missing"))));

        let cycle = forest.replace_snapshot(vec![
            snapshot("a", Some("b"), "A"),
            snapshot("b", Some("a"), "B"),
        ]);
        assert!(matches!(cycle, Err(ProjectionError::Cycle(_))));
    }

    #[test]
    fn enforces_child_limits_before_mutating() {
        let limits = ProjectionLimits {
            max_sessions: 4,
            max_children_per_session: 1,
        };
        let mut forest = SessionForest::new(limits);
        forest
            .replace_snapshot(vec![snapshot("root", None, "Root")])
            .unwrap();

        let first = SessionEvent {
            session_id: id("one"),
            seq: 1,
            kind: SessionEventKind::Created {
                parent_id: Some(id("root")),
                attempt_id: None,
                label: "One".to_owned(),
                status: SessionStatus::Queued,
                surface: SurfaceKind::None,
            },
        };
        assert_eq!(forest.apply(first).unwrap(), ApplyOutcome::Applied);

        let second = SessionEvent {
            session_id: id("two"),
            seq: 1,
            kind: SessionEventKind::Created {
                parent_id: Some(id("root")),
                attempt_id: None,
                label: "Two".to_owned(),
                status: SessionStatus::Queued,
                surface: SurfaceKind::None,
            },
        };
        assert_eq!(
            forest.apply(second),
            Err(ProjectionError::ChildLimit {
                parent: id("root"),
                limit: 1
            })
        );
        assert_eq!(forest.len(), 2);
    }
}
