//! Non-authoritative metadata joining one broker-owned PTY to an agent run.
//!
//! The values in this module are declarations made by a terminal-control
//! client. They are useful for discovery and reconciliation only. They never
//! grant attach, input, steering, or session-message authority; those remain
//! guarded by the broker generation, authenticated peer, and live lease.

use crate::session_message::BoundedId;
use serde::{Deserialize, Serialize};

/// Exact Ouroboros attempt identity declared when the broker creates its PTY.
///
/// Keeping all join columns together prevents consumers from accidentally
/// joining a terminal to the latest attempt of a reused session. `source_id`
/// names the MCP/runtime source; the remaining values identify one immutable
/// execution attempt within that source.
#[derive(Clone, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DeclaredSessionBindingV1 {
    pub source_id: BoundedId,
    pub session_id: BoundedId,
    pub execution_id: BoundedId,
    pub session_scope_id: BoundedId,
    pub session_attempt_id: BoundedId,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_an_exact_bounded_attempt_identity() {
        let value: DeclaredSessionBindingV1 = serde_json::from_value(serde_json::json!({
            "source_id": "ouroboros-local",
            "session_id": "session-7",
            "execution_id": "execution-8",
            "session_scope_id": "scope-9",
            "session_attempt_id": "attempt-10"
        }))
        .unwrap();

        assert_eq!(value.source_id.as_str(), "ouroboros-local");
        assert_eq!(value.session_attempt_id.as_str(), "attempt-10");
    }

    #[test]
    fn rejects_ambiguous_or_unbounded_identity_fields() {
        for invalid in ["", " leading", "trailing "] {
            let result = serde_json::from_value::<DeclaredSessionBindingV1>(serde_json::json!({
                "source_id": invalid,
                "session_id": "session-7",
                "execution_id": "execution-8",
                "session_scope_id": "scope-9",
                "session_attempt_id": "attempt-10"
            }));
            assert!(
                result.is_err(),
                "accepted invalid source identity {invalid:?}"
            );
        }

        let result = serde_json::from_value::<DeclaredSessionBindingV1>(serde_json::json!({
            "source_id": "x".repeat(257),
            "session_id": "session-7",
            "execution_id": "execution-8",
            "session_scope_id": "scope-9",
            "session_attempt_id": "attempt-10"
        }));
        assert!(result.is_err());
    }
}
