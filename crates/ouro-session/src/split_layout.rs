//! Bounded terminal split layout for desktop projections.
//!
//! A leaf contains only a stable broker terminal ID. It never owns a PTY,
//! renderer, scrollback buffer, or process. Persisted metadata is therefore a
//! recipe for reattaching broker-owned terminals, not permission to recreate a
//! shell when a terminal is missing.

use std::cmp::Reverse;
use std::collections::HashSet;

pub const SPLIT_LAYOUT_METADATA_VERSION: u16 = 1;
pub const MAX_TERMINAL_ID_BYTES: usize = 256;
pub const LAYOUT_UNITS: u32 = 1_000_000;
pub const MAX_SPLIT_LEAVES: usize = 32;
pub const MAX_SPLIT_DEPTH: usize = 8;

#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct TerminalId(String);

impl TerminalId {
    pub fn new(value: impl Into<String>) -> Result<Self, SplitLayoutError> {
        let value = value.into();
        if value.trim().is_empty() {
            return Err(SplitLayoutError::EmptyTerminalId);
        }
        if value.len() > MAX_TERMINAL_ID_BYTES {
            return Err(SplitLayoutError::TerminalIdTooLong {
                maximum: MAX_TERMINAL_ID_BYTES,
                actual: value.len(),
            });
        }
        if value.chars().any(char::is_control) {
            return Err(SplitLayoutError::ControlCharacterInTerminalId);
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct SplitNodeId(u64);

impl SplitNodeId {
    pub fn get(self) -> u64 {
        self.0
    }

    pub fn from_metadata(value: u64) -> Result<Self, SplitLayoutError> {
        if value == 0 {
            return Err(SplitLayoutError::InvalidNodeId);
        }
        Ok(Self(value))
    }
}

/// `LeftRight` places children beside one another; `TopBottom` stacks them.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SplitAxis {
    LeftRight,
    TopBottom,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SplitPlacement {
    Before,
    After,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FocusDirection {
    Left,
    Right,
    Up,
    Down,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SplitRatio(u16);

impl SplitRatio {
    pub const SCALE: u16 = 10_000;
    pub const MIN: u16 = 1_000;
    pub const MAX: u16 = 9_000;
    pub const HALF: Self = Self(5_000);

    pub fn new(basis_points: u16) -> Result<Self, SplitLayoutError> {
        if !(Self::MIN..=Self::MAX).contains(&basis_points) {
            return Err(SplitLayoutError::RatioOutOfRange {
                minimum: Self::MIN,
                maximum: Self::MAX,
                actual: basis_points,
            });
        }
        Ok(Self(basis_points))
    }

    pub fn basis_points(self) -> u16 {
        self.0
    }

    fn from_pointer(position: u32, span: u32) -> Result<Self, SplitLayoutError> {
        if span == 0 {
            return Err(SplitLayoutError::ZeroDragSpan);
        }
        let scaled = (u64::from(position.min(span)) * u64::from(Self::SCALE) + u64::from(span / 2))
            / u64::from(span);
        Ok(Self((scaled as u16).clamp(Self::MIN, Self::MAX)))
    }

    fn shifted(self, delta_basis_points: i16) -> Self {
        let shifted = i32::from(self.0) + i32::from(delta_basis_points);
        Self(shifted.clamp(i32::from(Self::MIN), i32::from(Self::MAX)) as u16)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SplitLimits {
    pub max_leaves: usize,
    pub max_depth: usize,
}

impl Default for SplitLimits {
    fn default() -> Self {
        Self {
            max_leaves: MAX_SPLIT_LEAVES,
            max_depth: MAX_SPLIT_DEPTH,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum SplitNode {
    Leaf {
        id: SplitNodeId,
        terminal_id: TerminalId,
    },
    Branch {
        id: SplitNodeId,
        axis: SplitAxis,
        ratio: SplitRatio,
        first: Box<SplitNode>,
        second: Box<SplitNode>,
    },
}

impl SplitNode {
    fn id(&self) -> SplitNodeId {
        match self {
            Self::Leaf { id, .. } | Self::Branch { id, .. } => *id,
        }
    }

    fn collect_terminals(&self, result: &mut Vec<TerminalId>) {
        match self {
            Self::Leaf { terminal_id, .. } => result.push(terminal_id.clone()),
            Self::Branch { first, second, .. } => {
                first.collect_terminals(result);
                second.collect_terminals(result);
            }
        }
    }

    fn contains_terminal(&self, target: &TerminalId) -> bool {
        match self {
            Self::Leaf { terminal_id, .. } => terminal_id == target,
            Self::Branch { first, second, .. } => {
                first.contains_terminal(target) || second.contains_terminal(target)
            }
        }
    }

    fn depth_of_terminal(&self, target: &TerminalId, depth: usize) -> Option<usize> {
        match self {
            Self::Leaf { terminal_id, .. } => (terminal_id == target).then_some(depth),
            Self::Branch { first, second, .. } => first
                .depth_of_terminal(target, depth + 1)
                .or_else(|| second.depth_of_terminal(target, depth + 1)),
        }
    }

    fn branch_ratio(&self, target: SplitNodeId) -> Option<SplitRatio> {
        match self {
            Self::Leaf { .. } => None,
            Self::Branch {
                id,
                ratio,
                first,
                second,
                ..
            } => {
                if *id == target {
                    Some(*ratio)
                } else {
                    first
                        .branch_ratio(target)
                        .or_else(|| second.branch_ratio(target))
                }
            }
        }
    }

    fn set_branch_ratio(&mut self, target: SplitNodeId, replacement: SplitRatio) -> bool {
        match self {
            Self::Leaf { .. } => false,
            Self::Branch {
                id,
                ratio,
                first,
                second,
                ..
            } => {
                if *id == target {
                    *ratio = replacement;
                    true
                } else {
                    first.set_branch_ratio(target, replacement)
                        || second.set_branch_ratio(target, replacement)
                }
            }
        }
    }

    /// Restores every recursive divider to an even 50/50 ratio. This walks
    /// the existing tree in place and allocates nothing; callers can therefore
    /// equalize the production four-pane layout without rebuilding terminal
    /// identity or renderer authority.
    fn equalize_ratios(&mut self) -> bool {
        match self {
            Self::Leaf { .. } => false,
            Self::Branch {
                ratio,
                first,
                second,
                ..
            } => {
                let changed = *ratio != SplitRatio::HALF;
                *ratio = SplitRatio::HALF;
                let first_changed = first.equalize_ratios();
                let second_changed = second.equalize_ratios();
                changed || first_changed || second_changed
            }
        }
    }

    fn descendants(&self, target: SplitNodeId, result: &mut Vec<TerminalId>) -> bool {
        if self.id() == target {
            self.collect_terminals(result);
            return true;
        }
        match self {
            Self::Leaf { .. } => false,
            Self::Branch { first, second, .. } => {
                first.descendants(target, result) || second.descendants(target, result)
            }
        }
    }

    fn replace_leaf(&mut self, target: &TerminalId, replacement: SplitNode) -> bool {
        if matches!(self, Self::Leaf { terminal_id, .. } if terminal_id == target) {
            *self = replacement;
            return true;
        }
        match self {
            Self::Leaf { .. } => false,
            Self::Branch { first, second, .. } => {
                if first.contains_terminal(target) {
                    first.replace_leaf(target, replacement)
                } else {
                    second.replace_leaf(target, replacement)
                }
            }
        }
    }

    fn remove_leaf(self, target: &TerminalId) -> Result<Option<Self>, Self> {
        match self {
            Self::Leaf {
                ref terminal_id, ..
            } if terminal_id == target => Ok(None),
            leaf @ Self::Leaf { .. } => Err(leaf),
            Self::Branch {
                id,
                axis,
                ratio,
                first,
                second,
            } => {
                let first_value = *first;
                match first_value.remove_leaf(target) {
                    Ok(None) => Ok(Some(*second)),
                    Ok(Some(first)) => Ok(Some(Self::Branch {
                        id,
                        axis,
                        ratio,
                        first: Box::new(first),
                        second,
                    })),
                    Err(first) => {
                        let second_value = *second;
                        match second_value.remove_leaf(target) {
                            Ok(None) => Ok(Some(first)),
                            Ok(Some(second)) => Ok(Some(Self::Branch {
                                id,
                                axis,
                                ratio,
                                first: Box::new(first),
                                second: Box::new(second),
                            })),
                            Err(second) => Err(Self::Branch {
                                id,
                                axis,
                                ratio,
                                first: Box::new(first),
                                second: Box::new(second),
                            }),
                        }
                    }
                }
            }
        }
    }

    fn metadata(&self) -> SplitNodeMetadata {
        match self {
            Self::Leaf { id, terminal_id } => SplitNodeMetadata::Leaf {
                id: *id,
                terminal_id: terminal_id.clone(),
            },
            Self::Branch {
                id,
                axis,
                ratio,
                first,
                second,
            } => SplitNodeMetadata::Branch {
                id: *id,
                axis: *axis,
                ratio: *ratio,
                first: Box::new(first.metadata()),
                second: Box::new(second.metadata()),
            },
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SplitNodeMetadata {
    Leaf {
        id: SplitNodeId,
        terminal_id: TerminalId,
    },
    Branch {
        id: SplitNodeId,
        axis: SplitAxis,
        ratio: SplitRatio,
        first: Box<SplitNodeMetadata>,
        second: Box<SplitNodeMetadata>,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SplitLayoutMetadata {
    pub version: u16,
    pub revision: u64,
    pub focused_terminal: TerminalId,
    pub root: SplitNodeMetadata,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ResizeCause {
    DividerCommit,
    Keyboard,
    Equalize,
}

/// The sole handoff from layout mutation to viewport calculation/broker resize.
/// A UI adapter maps this one intent to the final cell sizes for the listed
/// broker terminals and coalesces each terminal to one protocol-v4 resize.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResizeIntent {
    pub layout_revision: u64,
    pub cause: ResizeCause,
    pub affected_terminals: Vec<TerminalId>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PresentationUpdate {
    pub divider: SplitNodeId,
    pub ratio: SplitRatio,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct DividerDrag {
    divider: SplitNodeId,
    committed: SplitRatio,
    presentation: SplitRatio,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LeafGeometry {
    pub node_id: SplitNodeId,
    pub terminal_id: TerminalId,
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

impl LeafGeometry {
    fn right(&self) -> u32 {
        self.x.saturating_add(self.width)
    }

    fn bottom(&self) -> u32 {
        self.y.saturating_add(self.height)
    }

    fn center_x(&self) -> u64 {
        u64::from(self.x) * 2 + u64::from(self.width)
    }

    fn center_y(&self) -> u64 {
        u64::from(self.y) * 2 + u64::from(self.height)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SplitLayoutError {
    EmptyTerminalId,
    TerminalIdTooLong {
        maximum: usize,
        actual: usize,
    },
    ControlCharacterInTerminalId,
    InvalidLimits,
    DuplicateTerminal(TerminalId),
    MissingTerminal(TerminalId),
    MissingBrokerTerminal(TerminalId),
    CannotCloseLastLeaf,
    LeafLimit {
        limit: usize,
    },
    DepthLimit {
        limit: usize,
    },
    NodeIdExhausted,
    InvalidNodeId,
    DuplicateNodeId(SplitNodeId),
    RatioOutOfRange {
        minimum: u16,
        maximum: u16,
        actual: u16,
    },
    MissingDivider(SplitNodeId),
    DragAlreadyActive,
    DragNotActive,
    StructureMutationDuringDrag,
    ZeroDragSpan,
    UnsupportedMetadataVersion {
        expected: u16,
        actual: u16,
    },
    MissingFocusedTerminal(TerminalId),
}

#[derive(Clone, Debug)]
pub struct SplitLayout {
    root: SplitNode,
    focused: TerminalId,
    limits: SplitLimits,
    leaves: usize,
    next_node_id: u64,
    revision: u64,
    drag: Option<DividerDrag>,
}

impl SplitLayout {
    pub fn new(initial: TerminalId, limits: SplitLimits) -> Result<Self, SplitLayoutError> {
        validate_limits(limits)?;
        Ok(Self {
            root: SplitNode::Leaf {
                id: SplitNodeId(1),
                terminal_id: initial.clone(),
            },
            focused: initial,
            limits,
            leaves: 1,
            next_node_id: 2,
            revision: 0,
            drag: None,
        })
    }

    pub fn focused(&self) -> &TerminalId {
        &self.focused
    }

    pub fn leaf_count(&self) -> usize {
        self.leaves
    }

    pub fn revision(&self) -> u64 {
        self.revision
    }

    pub fn terminal_ids(&self) -> Vec<TerminalId> {
        let mut result = Vec::with_capacity(self.leaves);
        self.root.collect_terminals(&mut result);
        result
    }

    pub fn focus(&mut self, terminal: &TerminalId) -> Result<(), SplitLayoutError> {
        if !self.root.contains_terminal(terminal) {
            return Err(SplitLayoutError::MissingTerminal(terminal.clone()));
        }
        self.focused = terminal.clone();
        Ok(())
    }

    pub fn focus_next(&mut self) -> &TerminalId {
        self.focus_by_offset(1)
    }

    pub fn focus_previous(&mut self) -> &TerminalId {
        self.focus_by_offset(-1)
    }

    fn focus_by_offset(&mut self, offset: isize) -> &TerminalId {
        let terminals = self.terminal_ids();
        let current = terminals
            .iter()
            .position(|terminal| terminal == &self.focused)
            .expect("focused terminal is a layout invariant");
        let next = (current as isize + offset).rem_euclid(terminals.len() as isize) as usize;
        self.focused = terminals[next].clone();
        &self.focused
    }

    pub fn focus_direction(&mut self, direction: FocusDirection) -> Option<&TerminalId> {
        let geometry = self.geometry();
        let current = geometry
            .iter()
            .find(|leaf| leaf.terminal_id == self.focused)
            .expect("focused terminal is a layout invariant");
        let candidate = geometry
            .iter()
            .enumerate()
            .filter(|(_, leaf)| is_in_direction(current, leaf, direction))
            .min_by_key(|(order, leaf)| directional_rank(current, leaf, direction, *order))
            .map(|(_, leaf)| leaf.terminal_id.clone());
        if let Some(candidate) = candidate {
            self.focused = candidate;
            Some(&self.focused)
        } else {
            None
        }
    }

    pub fn split_focused(
        &mut self,
        axis: SplitAxis,
        terminal: TerminalId,
        placement: SplitPlacement,
    ) -> Result<SplitNodeId, SplitLayoutError> {
        self.ensure_structure_mutable()?;
        if self.root.contains_terminal(&terminal) {
            return Err(SplitLayoutError::DuplicateTerminal(terminal));
        }
        if self.leaves >= self.limits.max_leaves {
            return Err(SplitLayoutError::LeafLimit {
                limit: self.limits.max_leaves,
            });
        }
        let focused_depth = self
            .root
            .depth_of_terminal(&self.focused, 1)
            .expect("focused terminal is a layout invariant");
        if focused_depth >= self.limits.max_depth {
            return Err(SplitLayoutError::DepthLimit {
                limit: self.limits.max_depth,
            });
        }
        let branch_value = self.next_node_id;
        let leaf_value = branch_value
            .checked_add(1)
            .ok_or(SplitLayoutError::NodeIdExhausted)?;
        let next_value = leaf_value
            .checked_add(1)
            .ok_or(SplitLayoutError::NodeIdExhausted)?;
        let branch_id = SplitNodeId(branch_value);
        let old_leaf_id = find_leaf_id(&self.root, &self.focused)
            .expect("focused terminal is a layout invariant");
        let old_leaf = SplitNode::Leaf {
            id: old_leaf_id,
            terminal_id: self.focused.clone(),
        };
        let new_leaf = SplitNode::Leaf {
            id: SplitNodeId(leaf_value),
            terminal_id: terminal.clone(),
        };
        let (first, second) = match placement {
            SplitPlacement::Before => (new_leaf, old_leaf),
            SplitPlacement::After => (old_leaf, new_leaf),
        };
        let replacement = SplitNode::Branch {
            id: branch_id,
            axis,
            ratio: SplitRatio::HALF,
            first: Box::new(first),
            second: Box::new(second),
        };
        let replaced = self.root.replace_leaf(&self.focused, replacement);
        debug_assert!(replaced);
        self.next_node_id = next_value;
        self.leaves += 1;
        self.focused = terminal;
        self.revision = self.revision.saturating_add(1);
        Ok(branch_id)
    }

    pub fn close(&mut self, terminal: &TerminalId) -> Result<(), SplitLayoutError> {
        self.ensure_structure_mutable()?;
        if self.leaves == 1 {
            return if self.root.contains_terminal(terminal) {
                Err(SplitLayoutError::CannotCloseLastLeaf)
            } else {
                Err(SplitLayoutError::MissingTerminal(terminal.clone()))
            };
        }
        let before = self.terminal_ids();
        let Some(closed_index) = before.iter().position(|candidate| candidate == terminal) else {
            return Err(SplitLayoutError::MissingTerminal(terminal.clone()));
        };
        let root = self.root.clone();
        self.root = root
            .remove_leaf(terminal)
            .map_err(|_| SplitLayoutError::MissingTerminal(terminal.clone()))?
            .expect("last leaf is rejected before removal");
        self.leaves -= 1;
        if &self.focused == terminal {
            let after = self.terminal_ids();
            self.focused = after[closed_index.min(after.len() - 1)].clone();
        }
        self.revision = self.revision.saturating_add(1);
        Ok(())
    }

    pub fn begin_divider_drag(
        &mut self,
        divider: SplitNodeId,
    ) -> Result<PresentationUpdate, SplitLayoutError> {
        if self.drag.is_some() {
            return Err(SplitLayoutError::DragAlreadyActive);
        }
        let committed = self
            .root
            .branch_ratio(divider)
            .ok_or(SplitLayoutError::MissingDivider(divider))?;
        self.drag = Some(DividerDrag {
            divider,
            committed,
            presentation: committed,
        });
        Ok(PresentationUpdate {
            divider,
            ratio: committed,
        })
    }

    /// Updates presentation geometry only. This method cannot produce a resize
    /// intent, so pointer-rate updates cannot leak into PTY `SIGWINCH` traffic.
    pub fn update_divider_drag(
        &mut self,
        position_from_start: u32,
        available_span: u32,
    ) -> Result<PresentationUpdate, SplitLayoutError> {
        let ratio = SplitRatio::from_pointer(position_from_start, available_span)?;
        let drag = self.drag.as_mut().ok_or(SplitLayoutError::DragNotActive)?;
        drag.presentation = ratio;
        Ok(PresentationUpdate {
            divider: drag.divider,
            ratio,
        })
    }

    pub fn commit_divider_drag(&mut self) -> Result<Option<ResizeIntent>, SplitLayoutError> {
        let drag = self.drag.take().ok_or(SplitLayoutError::DragNotActive)?;
        if drag.presentation == drag.committed {
            return Ok(None);
        }
        let changed = self.root.set_branch_ratio(drag.divider, drag.presentation);
        debug_assert!(changed);
        self.revision = self.revision.saturating_add(1);
        Ok(Some(
            self.resize_intent(drag.divider, ResizeCause::DividerCommit)?,
        ))
    }

    pub fn cancel_divider_drag(&mut self) -> Result<PresentationUpdate, SplitLayoutError> {
        let drag = self.drag.take().ok_or(SplitLayoutError::DragNotActive)?;
        Ok(PresentationUpdate {
            divider: drag.divider,
            ratio: drag.committed,
        })
    }

    pub fn resize_divider_from_keyboard(
        &mut self,
        divider: SplitNodeId,
        delta_basis_points: i16,
    ) -> Result<Option<ResizeIntent>, SplitLayoutError> {
        self.ensure_structure_mutable()?;
        let current = self
            .root
            .branch_ratio(divider)
            .ok_or(SplitLayoutError::MissingDivider(divider))?;
        let replacement = current.shifted(delta_basis_points);
        if replacement == current {
            return Ok(None);
        }
        let changed = self.root.set_branch_ratio(divider, replacement);
        debug_assert!(changed);
        self.revision = self.revision.saturating_add(1);
        Ok(Some(self.resize_intent(divider, ResizeCause::Keyboard)?))
    }

    /// Equalizes the complete recursive tree in one revision and one bounded
    /// resize intent. No intent is emitted when all dividers are already even.
    pub fn equalize(&mut self) -> Result<Option<ResizeIntent>, SplitLayoutError> {
        self.ensure_structure_mutable()?;
        if !self.root.equalize_ratios() {
            return Ok(None);
        }
        self.revision = self.revision.saturating_add(1);
        Ok(Some(ResizeIntent {
            layout_revision: self.revision,
            cause: ResizeCause::Equalize,
            affected_terminals: self.terminal_ids(),
        }))
    }

    pub fn committed_ratio(&self, divider: SplitNodeId) -> Result<SplitRatio, SplitLayoutError> {
        self.root
            .branch_ratio(divider)
            .ok_or(SplitLayoutError::MissingDivider(divider))
    }

    pub fn presented_ratio(&self, divider: SplitNodeId) -> Result<SplitRatio, SplitLayoutError> {
        if let Some(drag) = &self.drag {
            if drag.divider == divider {
                return Ok(drag.presentation);
            }
        }
        self.committed_ratio(divider)
    }

    pub fn geometry(&self) -> Vec<LeafGeometry> {
        let mut result = Vec::with_capacity(self.leaves);
        collect_geometry(
            &self.root,
            Rect {
                x: 0,
                y: 0,
                width: LAYOUT_UNITS,
                height: LAYOUT_UNITS,
            },
            self.drag.as_ref(),
            &mut result,
        );
        result
    }

    pub fn metadata(&self) -> SplitLayoutMetadata {
        SplitLayoutMetadata {
            version: SPLIT_LAYOUT_METADATA_VERSION,
            revision: self.revision,
            focused_terminal: self.focused.clone(),
            root: self.root.metadata(),
        }
    }

    /// Restores only a layout projection. Every leaf must resolve to a terminal
    /// currently advertised by the authoritative broker; missing IDs fail
    /// closed instead of spawning replacement PTYs.
    pub fn restore(
        metadata: SplitLayoutMetadata,
        limits: SplitLimits,
        broker_terminals: &HashSet<TerminalId>,
    ) -> Result<Self, SplitLayoutError> {
        validate_limits(limits)?;
        if metadata.version != SPLIT_LAYOUT_METADATA_VERSION {
            return Err(SplitLayoutError::UnsupportedMetadataVersion {
                expected: SPLIT_LAYOUT_METADATA_VERSION,
                actual: metadata.version,
            });
        }
        let mut node_ids = HashSet::new();
        let mut terminal_ids = HashSet::new();
        let mut leaf_count = 0;
        let mut maximum_node_id = 0;
        let root = restore_node(
            metadata.root,
            1,
            limits,
            broker_terminals,
            &mut node_ids,
            &mut terminal_ids,
            &mut leaf_count,
            &mut maximum_node_id,
        )?;
        if !terminal_ids.contains(&metadata.focused_terminal) {
            return Err(SplitLayoutError::MissingFocusedTerminal(
                metadata.focused_terminal,
            ));
        }
        let next_node_id = maximum_node_id
            .checked_add(1)
            .ok_or(SplitLayoutError::NodeIdExhausted)?;
        Ok(Self {
            root,
            focused: metadata.focused_terminal,
            limits,
            leaves: leaf_count,
            next_node_id,
            revision: metadata.revision,
            drag: None,
        })
    }

    fn resize_intent(
        &self,
        divider: SplitNodeId,
        cause: ResizeCause,
    ) -> Result<ResizeIntent, SplitLayoutError> {
        let mut affected_terminals = Vec::new();
        if !self.root.descendants(divider, &mut affected_terminals) {
            return Err(SplitLayoutError::MissingDivider(divider));
        }
        Ok(ResizeIntent {
            layout_revision: self.revision,
            cause,
            affected_terminals,
        })
    }

    fn ensure_structure_mutable(&self) -> Result<(), SplitLayoutError> {
        if self.drag.is_some() {
            Err(SplitLayoutError::StructureMutationDuringDrag)
        } else {
            Ok(())
        }
    }
}

fn validate_limits(limits: SplitLimits) -> Result<(), SplitLayoutError> {
    if limits.max_leaves == 0
        || limits.max_depth == 0
        || limits.max_leaves > MAX_SPLIT_LEAVES
        || limits.max_depth > MAX_SPLIT_DEPTH
    {
        Err(SplitLayoutError::InvalidLimits)
    } else {
        Ok(())
    }
}

#[allow(clippy::too_many_arguments)]
fn restore_node(
    metadata: SplitNodeMetadata,
    depth: usize,
    limits: SplitLimits,
    broker_terminals: &HashSet<TerminalId>,
    node_ids: &mut HashSet<SplitNodeId>,
    terminal_ids: &mut HashSet<TerminalId>,
    leaf_count: &mut usize,
    maximum_node_id: &mut u64,
) -> Result<SplitNode, SplitLayoutError> {
    if depth > limits.max_depth {
        return Err(SplitLayoutError::DepthLimit {
            limit: limits.max_depth,
        });
    }
    let id = match &metadata {
        SplitNodeMetadata::Leaf { id, .. } | SplitNodeMetadata::Branch { id, .. } => *id,
    };
    if id.0 == 0 {
        return Err(SplitLayoutError::InvalidNodeId);
    }
    if !node_ids.insert(id) {
        return Err(SplitLayoutError::DuplicateNodeId(id));
    }
    *maximum_node_id = (*maximum_node_id).max(id.0);
    match metadata {
        SplitNodeMetadata::Leaf { id, terminal_id } => {
            if !terminal_ids.insert(terminal_id.clone()) {
                return Err(SplitLayoutError::DuplicateTerminal(terminal_id));
            }
            if !broker_terminals.contains(&terminal_id) {
                return Err(SplitLayoutError::MissingBrokerTerminal(terminal_id));
            }
            *leaf_count += 1;
            if *leaf_count > limits.max_leaves {
                return Err(SplitLayoutError::LeafLimit {
                    limit: limits.max_leaves,
                });
            }
            Ok(SplitNode::Leaf { id, terminal_id })
        }
        SplitNodeMetadata::Branch {
            id,
            axis,
            ratio,
            first,
            second,
        } => {
            SplitRatio::new(ratio.0)?;
            let first = restore_node(
                *first,
                depth + 1,
                limits,
                broker_terminals,
                node_ids,
                terminal_ids,
                leaf_count,
                maximum_node_id,
            )?;
            let second = restore_node(
                *second,
                depth + 1,
                limits,
                broker_terminals,
                node_ids,
                terminal_ids,
                leaf_count,
                maximum_node_id,
            )?;
            Ok(SplitNode::Branch {
                id,
                axis,
                ratio,
                first: Box::new(first),
                second: Box::new(second),
            })
        }
    }
}

fn find_leaf_id(node: &SplitNode, terminal: &TerminalId) -> Option<SplitNodeId> {
    match node {
        SplitNode::Leaf { id, terminal_id } => (terminal_id == terminal).then_some(*id),
        SplitNode::Branch { first, second, .. } => {
            find_leaf_id(first, terminal).or_else(|| find_leaf_id(second, terminal))
        }
    }
}

#[derive(Clone, Copy)]
struct Rect {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
}

fn collect_geometry(
    node: &SplitNode,
    rect: Rect,
    drag: Option<&DividerDrag>,
    result: &mut Vec<LeafGeometry>,
) {
    match node {
        SplitNode::Leaf { id, terminal_id } => result.push(LeafGeometry {
            node_id: *id,
            terminal_id: terminal_id.clone(),
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height,
        }),
        SplitNode::Branch {
            id,
            axis,
            ratio,
            first,
            second,
        } => {
            let effective = drag
                .filter(|active| active.divider == *id)
                .map_or(*ratio, |active| active.presentation);
            match axis {
                SplitAxis::LeftRight => {
                    let first_width = split_dimension(rect.width, effective);
                    collect_geometry(
                        first,
                        Rect {
                            width: first_width,
                            ..rect
                        },
                        drag,
                        result,
                    );
                    collect_geometry(
                        second,
                        Rect {
                            x: rect.x + first_width,
                            width: rect.width - first_width,
                            ..rect
                        },
                        drag,
                        result,
                    );
                }
                SplitAxis::TopBottom => {
                    let first_height = split_dimension(rect.height, effective);
                    collect_geometry(
                        first,
                        Rect {
                            height: first_height,
                            ..rect
                        },
                        drag,
                        result,
                    );
                    collect_geometry(
                        second,
                        Rect {
                            y: rect.y + first_height,
                            height: rect.height - first_height,
                            ..rect
                        },
                        drag,
                        result,
                    );
                }
            }
        }
    }
}

fn split_dimension(dimension: u32, ratio: SplitRatio) -> u32 {
    ((u64::from(dimension) * u64::from(ratio.0)) / u64::from(SplitRatio::SCALE)) as u32
}

fn is_in_direction(
    current: &LeafGeometry,
    candidate: &LeafGeometry,
    direction: FocusDirection,
) -> bool {
    match direction {
        FocusDirection::Left => candidate.center_x() < current.center_x(),
        FocusDirection::Right => candidate.center_x() > current.center_x(),
        FocusDirection::Up => candidate.center_y() < current.center_y(),
        FocusDirection::Down => candidate.center_y() > current.center_y(),
    }
}

fn directional_rank(
    current: &LeafGeometry,
    candidate: &LeafGeometry,
    direction: FocusDirection,
    stable_order: usize,
) -> (Reverse<u32>, u64, u64, usize) {
    let (overlap, primary, secondary) = match direction {
        FocusDirection::Left | FocusDirection::Right => (
            overlap(current.y, current.bottom(), candidate.y, candidate.bottom()),
            current.center_x().abs_diff(candidate.center_x()),
            current.center_y().abs_diff(candidate.center_y()),
        ),
        FocusDirection::Up | FocusDirection::Down => (
            overlap(current.x, current.right(), candidate.x, candidate.right()),
            current.center_y().abs_diff(candidate.center_y()),
            current.center_x().abs_diff(candidate.center_x()),
        ),
    };
    (Reverse(overlap), primary, secondary, stable_order)
}

fn overlap(first_start: u32, first_end: u32, second_start: u32, second_end: u32) -> u32 {
    first_end
        .min(second_end)
        .saturating_sub(first_start.max(second_start))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn terminal(value: &str) -> TerminalId {
        TerminalId::new(value).unwrap()
    }

    fn layout(max_leaves: usize, max_depth: usize) -> SplitLayout {
        SplitLayout::new(
            terminal("a"),
            SplitLimits {
                max_leaves,
                max_depth,
            },
        )
        .unwrap()
    }

    fn broker_ids(values: &[&str]) -> HashSet<TerminalId> {
        values.iter().map(|value| terminal(value)).collect()
    }

    #[test]
    fn leaves_are_broker_references_and_splits_preserve_existing_leaf_identity() {
        let mut layout = layout(4, 4);
        let original_leaf = layout.geometry()[0].node_id;
        let divider = layout
            .split_focused(SplitAxis::LeftRight, terminal("b"), SplitPlacement::After)
            .unwrap();
        assert_eq!(layout.terminal_ids(), vec![terminal("a"), terminal("b")]);
        assert_eq!(layout.geometry()[0].node_id, original_leaf);
        assert_ne!(layout.geometry()[1].node_id, original_leaf);
        assert_eq!(layout.committed_ratio(divider), Ok(SplitRatio::HALF));
    }

    #[test]
    fn leaf_and_depth_limits_fail_atomically() {
        let mut leaf_limited = layout(2, 8);
        leaf_limited
            .split_focused(SplitAxis::LeftRight, terminal("b"), SplitPlacement::After)
            .unwrap();
        let before = leaf_limited.metadata();
        assert_eq!(
            leaf_limited.split_focused(SplitAxis::TopBottom, terminal("c"), SplitPlacement::After,),
            Err(SplitLayoutError::LeafLimit { limit: 2 })
        );
        assert_eq!(leaf_limited.metadata(), before);

        let mut depth_limited = layout(8, 2);
        depth_limited
            .split_focused(SplitAxis::LeftRight, terminal("b"), SplitPlacement::After)
            .unwrap();
        let before = depth_limited.metadata();
        assert_eq!(
            depth_limited
                .split_focused(SplitAxis::TopBottom, terminal("c"), SplitPlacement::After,),
            Err(SplitLayoutError::DepthLimit { limit: 2 })
        );
        assert_eq!(depth_limited.metadata(), before);
    }

    #[test]
    fn close_collapses_parent_and_selects_stable_visual_successor() {
        let mut layout = layout(8, 8);
        layout
            .split_focused(SplitAxis::LeftRight, terminal("b"), SplitPlacement::After)
            .unwrap();
        layout
            .split_focused(SplitAxis::TopBottom, terminal("c"), SplitPlacement::After)
            .unwrap();
        let a_leaf = layout
            .geometry()
            .into_iter()
            .find(|leaf| leaf.terminal_id == terminal("a"))
            .unwrap()
            .node_id;
        layout.focus(&terminal("b")).unwrap();
        layout.close(&terminal("b")).unwrap();
        assert_eq!(layout.focused(), &terminal("c"));
        assert_eq!(layout.terminal_ids(), vec![terminal("a"), terminal("c")]);
        assert_eq!(layout.geometry()[0].node_id, a_leaf);
        layout.close(&terminal("a")).unwrap();
        assert_eq!(layout.focused(), &terminal("c"));
        assert_eq!(
            layout.close(&terminal("c")),
            Err(SplitLayoutError::CannotCloseLastLeaf)
        );
    }

    #[test]
    fn four_leaf_recursive_tree_equalizes_in_one_revision() {
        let mut layout = layout(4, 8);
        let root = layout
            .split_focused(SplitAxis::LeftRight, terminal("b"), SplitPlacement::After)
            .unwrap();
        let nested = layout
            .split_focused(SplitAxis::TopBottom, terminal("c"), SplitPlacement::After)
            .unwrap();
        layout
            .split_focused(SplitAxis::LeftRight, terminal("d"), SplitPlacement::After)
            .unwrap();
        layout.resize_divider_from_keyboard(root, 2_000).unwrap();
        layout.resize_divider_from_keyboard(nested, -1_500).unwrap();
        let revision = layout.revision();
        let intent = layout.equalize().unwrap().unwrap();
        assert_eq!(layout.leaf_count(), 4);
        assert_eq!(layout.revision(), revision + 1);
        assert_eq!(intent.layout_revision, revision + 1);
        assert_eq!(intent.cause, ResizeCause::Equalize);
        assert_eq!(intent.affected_terminals, layout.terminal_ids());
        assert_eq!(layout.committed_ratio(root), Ok(SplitRatio::HALF));
        assert_eq!(layout.committed_ratio(nested), Ok(SplitRatio::HALF));
        assert_eq!(layout.equalize().unwrap(), None);
    }

    #[test]
    fn traversal_and_directional_focus_are_deterministic() {
        let mut layout = layout(8, 8);
        layout
            .split_focused(SplitAxis::LeftRight, terminal("b"), SplitPlacement::After)
            .unwrap();
        layout
            .split_focused(SplitAxis::TopBottom, terminal("c"), SplitPlacement::After)
            .unwrap();
        layout.focus(&terminal("a")).unwrap();
        assert_eq!(layout.focus_next(), &terminal("b"));
        assert_eq!(layout.focus_next(), &terminal("c"));
        assert_eq!(layout.focus_next(), &terminal("a"));
        assert_eq!(layout.focus_previous(), &terminal("c"));
        layout.focus(&terminal("a")).unwrap();
        assert_eq!(
            layout.focus_direction(FocusDirection::Right),
            Some(&terminal("b"))
        );
        assert_eq!(
            layout.focus_direction(FocusDirection::Down),
            Some(&terminal("c"))
        );
        assert_eq!(layout.focus_direction(FocusDirection::Down), None);
    }

    #[test]
    fn pointer_updates_are_presentation_only_and_commit_emits_exactly_one_intent() {
        let mut layout = layout(4, 4);
        let divider = layout
            .split_focused(SplitAxis::LeftRight, terminal("b"), SplitPlacement::After)
            .unwrap();
        let revision = layout.revision();
        let committed = layout.metadata();
        layout.begin_divider_drag(divider).unwrap();
        for position in 0..=1_000 {
            let update = layout.update_divider_drag(position, 1_000).unwrap();
            assert_eq!(update.divider, divider);
            assert_eq!(layout.revision(), revision);
            assert_eq!(layout.metadata(), committed);
        }
        assert_eq!(
            layout.presented_ratio(divider).unwrap().basis_points(),
            9_000
        );
        assert_eq!(layout.committed_ratio(divider), Ok(SplitRatio::HALF));
        let intent = layout.commit_divider_drag().unwrap().unwrap();
        assert_eq!(layout.revision(), revision + 1);
        assert_eq!(intent.layout_revision, revision + 1);
        assert_eq!(intent.cause, ResizeCause::DividerCommit);
        assert_eq!(
            intent.affected_terminals,
            vec![terminal("a"), terminal("b")]
        );
        assert_eq!(
            layout.commit_divider_drag(),
            Err(SplitLayoutError::DragNotActive)
        );
    }

    #[test]
    fn cancel_restores_presentation_without_mutating_or_resizing() {
        let mut layout = layout(4, 4);
        let divider = layout
            .split_focused(SplitAxis::TopBottom, terminal("b"), SplitPlacement::After)
            .unwrap();
        let before = layout.metadata();
        layout.begin_divider_drag(divider).unwrap();
        layout.update_divider_drag(2, 10).unwrap();
        assert_ne!(layout.geometry()[0].height, LAYOUT_UNITS / 2);
        assert_eq!(
            layout.cancel_divider_drag().unwrap(),
            PresentationUpdate {
                divider,
                ratio: SplitRatio::HALF,
            }
        );
        assert_eq!(layout.metadata(), before);
        assert_eq!(layout.geometry()[0].height, LAYOUT_UNITS / 2);
    }

    #[test]
    fn keyboard_resize_clamps_and_emits_one_coalescing_intent_per_change() {
        let mut layout = layout(4, 4);
        let divider = layout
            .split_focused(SplitAxis::LeftRight, terminal("b"), SplitPlacement::After)
            .unwrap();
        let first = layout
            .resize_divider_from_keyboard(divider, -10_000)
            .unwrap()
            .unwrap();
        assert_eq!(first.cause, ResizeCause::Keyboard);
        assert_eq!(
            layout.committed_ratio(divider).unwrap().basis_points(),
            SplitRatio::MIN
        );
        assert_eq!(
            layout.resize_divider_from_keyboard(divider, -1).unwrap(),
            None
        );
        let second = layout
            .resize_divider_from_keyboard(divider, 10_000)
            .unwrap()
            .unwrap();
        assert_eq!(second.layout_revision, first.layout_revision + 1);
        assert_eq!(
            layout.committed_ratio(divider).unwrap().basis_points(),
            SplitRatio::MAX
        );
    }

    #[test]
    fn structural_mutation_is_rejected_during_an_interruptible_drag() {
        let mut layout = layout(8, 8);
        let divider = layout
            .split_focused(SplitAxis::LeftRight, terminal("b"), SplitPlacement::After)
            .unwrap();
        layout.begin_divider_drag(divider).unwrap();
        assert_eq!(
            layout.close(&terminal("a")),
            Err(SplitLayoutError::StructureMutationDuringDrag)
        );
        assert_eq!(
            layout.split_focused(SplitAxis::TopBottom, terminal("c"), SplitPlacement::After,),
            Err(SplitLayoutError::StructureMutationDuringDrag)
        );
        assert_eq!(
            layout.resize_divider_from_keyboard(divider, 100),
            Err(SplitLayoutError::StructureMutationDuringDrag)
        );
        layout.cancel_divider_drag().unwrap();
        assert_eq!(layout.terminal_ids(), vec![terminal("a"), terminal("b")]);
    }

    #[test]
    fn restore_requires_every_exact_broker_terminal_and_round_trips_metadata() {
        let mut original = layout(8, 8);
        let divider = original
            .split_focused(SplitAxis::LeftRight, terminal("b"), SplitPlacement::Before)
            .unwrap();
        original.resize_divider_from_keyboard(divider, 700).unwrap();
        let metadata = original.metadata();
        assert!(matches!(
            SplitLayout::restore(
                metadata.clone(),
                SplitLimits::default(),
                &broker_ids(&["a"])
            ),
            Err(SplitLayoutError::MissingBrokerTerminal(terminal_id))
                if terminal_id == terminal("b")
        ));
        let restored = SplitLayout::restore(
            metadata.clone(),
            SplitLimits::default(),
            &broker_ids(&["a", "b", "unrelated"]),
        )
        .unwrap();
        assert_eq!(restored.metadata(), metadata);
        assert_eq!(restored.focused(), &terminal("b"));
    }

    #[test]
    fn malformed_restore_metadata_fails_closed() {
        let duplicate_terminal = SplitLayoutMetadata {
            version: SPLIT_LAYOUT_METADATA_VERSION,
            revision: 0,
            focused_terminal: terminal("a"),
            root: SplitNodeMetadata::Branch {
                id: SplitNodeId(1),
                axis: SplitAxis::LeftRight,
                ratio: SplitRatio::HALF,
                first: Box::new(SplitNodeMetadata::Leaf {
                    id: SplitNodeId(2),
                    terminal_id: terminal("a"),
                }),
                second: Box::new(SplitNodeMetadata::Leaf {
                    id: SplitNodeId(3),
                    terminal_id: terminal("a"),
                }),
            },
        };
        assert!(matches!(
            SplitLayout::restore(
                duplicate_terminal,
                SplitLimits::default(),
                &broker_ids(&["a"]),
            ),
            Err(SplitLayoutError::DuplicateTerminal(terminal_id))
                if terminal_id == terminal("a")
        ));

        let duplicate_node = SplitLayoutMetadata {
            version: SPLIT_LAYOUT_METADATA_VERSION,
            revision: 0,
            focused_terminal: terminal("a"),
            root: SplitNodeMetadata::Branch {
                id: SplitNodeId(1),
                axis: SplitAxis::LeftRight,
                ratio: SplitRatio::HALF,
                first: Box::new(SplitNodeMetadata::Leaf {
                    id: SplitNodeId(2),
                    terminal_id: terminal("a"),
                }),
                second: Box::new(SplitNodeMetadata::Leaf {
                    id: SplitNodeId(2),
                    terminal_id: terminal("b"),
                }),
            },
        };
        assert!(matches!(
            SplitLayout::restore(
                duplicate_node,
                SplitLimits::default(),
                &broker_ids(&["a", "b"]),
            ),
            Err(SplitLayoutError::DuplicateNodeId(SplitNodeId(2)))
        ));
    }

    #[test]
    fn geometry_remains_a_gapless_partition_at_ratio_extremes() {
        let mut layout = layout(4, 4);
        let divider = layout
            .split_focused(SplitAxis::LeftRight, terminal("b"), SplitPlacement::After)
            .unwrap();
        layout.begin_divider_drag(divider).unwrap();
        layout.update_divider_drag(u32::MAX, 1).unwrap();
        let geometry = layout.geometry();
        assert_eq!(geometry[0].x, 0);
        assert_eq!(geometry[0].right(), geometry[1].x);
        assert_eq!(geometry[1].right(), LAYOUT_UNITS);
        assert_eq!(geometry[0].width, 900_000);
        assert_eq!(geometry[1].width, 100_000);
    }

    #[test]
    fn deterministic_operation_walk_preserves_invariants_and_restoreability() {
        let limits = SplitLimits {
            max_leaves: 32,
            max_depth: 8,
        };
        let mut layout = SplitLayout::new(terminal("t0"), limits).unwrap();
        let mut next_terminal = 1_u32;
        let mut state = 0x5eed_cafe_dead_beef_u64;
        for _ in 0..5_000 {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            let terminals = layout.terminal_ids();
            match state % 6 {
                0 | 1 if layout.leaf_count() < limits.max_leaves => {
                    let target = terminals[(state as usize) % terminals.len()].clone();
                    layout.focus(&target).unwrap();
                    let candidate = terminal(&format!("t{next_terminal}"));
                    next_terminal += 1;
                    let _ = layout.split_focused(
                        if state & 1 == 0 {
                            SplitAxis::LeftRight
                        } else {
                            SplitAxis::TopBottom
                        },
                        candidate,
                        if state & 2 == 0 {
                            SplitPlacement::Before
                        } else {
                            SplitPlacement::After
                        },
                    );
                }
                2 if layout.leaf_count() > 1 => {
                    let target = terminals[(state as usize) % terminals.len()].clone();
                    layout.close(&target).unwrap();
                }
                3 => {
                    layout.focus_next();
                }
                4 => {
                    layout.focus_previous();
                }
                _ => {
                    let direction = match state & 3 {
                        0 => FocusDirection::Left,
                        1 => FocusDirection::Right,
                        2 => FocusDirection::Up,
                        _ => FocusDirection::Down,
                    };
                    layout.focus_direction(direction);
                }
            }
            let terminals = layout.terminal_ids();
            let unique: HashSet<_> = terminals.iter().collect();
            assert_eq!(unique.len(), terminals.len());
            assert_eq!(terminals.len(), layout.leaf_count());
            assert!(terminals.contains(layout.focused()));
            let metadata = layout.metadata();
            let available = terminals.into_iter().collect();
            let restored = SplitLayout::restore(metadata.clone(), limits, &available).unwrap();
            assert_eq!(restored.metadata(), metadata);
        }
    }

    #[test]
    fn terminal_ids_are_strictly_bounded() {
        assert_eq!(
            TerminalId::new(" \t "),
            Err(SplitLayoutError::EmptyTerminalId)
        );
        assert_eq!(
            TerminalId::new("bad\nterminal"),
            Err(SplitLayoutError::ControlCharacterInTerminalId)
        );
        assert_eq!(
            TerminalId::new("x".repeat(MAX_TERMINAL_ID_BYTES + 1)),
            Err(SplitLayoutError::TerminalIdTooLong {
                maximum: MAX_TERMINAL_ID_BYTES,
                actual: MAX_TERMINAL_ID_BYTES + 1,
            })
        );
    }

    #[test]
    fn caller_cannot_raise_process_wide_layout_caps() {
        assert_eq!(
            SplitLayout::new(
                terminal("a"),
                SplitLimits {
                    max_leaves: MAX_SPLIT_LEAVES + 1,
                    max_depth: MAX_SPLIT_DEPTH,
                },
            )
            .unwrap_err(),
            SplitLayoutError::InvalidLimits
        );
        assert_eq!(
            SplitLayout::new(
                terminal("a"),
                SplitLimits {
                    max_leaves: MAX_SPLIT_LEAVES,
                    max_depth: MAX_SPLIT_DEPTH + 1,
                },
            )
            .unwrap_err(),
            SplitLayoutError::InvalidLimits
        );
    }
}
