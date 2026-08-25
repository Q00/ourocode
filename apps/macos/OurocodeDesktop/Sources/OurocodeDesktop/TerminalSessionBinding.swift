import Foundation

/// UI projection of the MCP-owned attempt/surface contract. Identity remains
/// owned by `OuroborosSessionTerminalIdentity`; this type adds only the human
/// label and status needed by terminal chrome.
typealias TerminalSessionLeafIdentity = OuroborosSessionAttemptIdentityV1

extension OuroborosSessionAttemptIdentityV1 {
    var stableKey: String {
        OuroborosSessionTerminalIdentityDecoderV1.stableTabID(for: self)
    }
}

struct TerminalSessionBinding: Equatable {
    let surface: OuroborosPTYSurfaceBindingV1
    let label: String
    let status: String
    let depth: Int
    /// Provider-owned parent identity. Nil means this surface is a root;
    /// depth, label, cwd, and shared session IDs never imply a parent.
    let parentAgentID: String?

    init(
        surface: OuroborosPTYSurfaceBindingV1,
        label: String,
        status: String,
        depth: Int,
        parentAgentID: String? = nil
    ) {
        self.surface = surface
        self.label = label
        self.status = status
        self.depth = depth
        self.parentAgentID = parentAgentID
    }

    /// Adapter used by `OuroborosSessionTab.surface`. Read-only or malformed
    /// leaves remain visible in the rail but cannot claim a terminal tab.
    init?(
        surfaceResolution: OuroborosSessionSurfaceResolutionV1,
        label: String,
        status: String,
        depth: Int,
        parentAgentID: String? = nil
    ) {
        guard case .pty(let surface) = surfaceResolution else { return nil }
        self.init(
            surface: surface,
            label: label,
            status: status,
            depth: depth,
            parentAgentID: parentAgentID
        )
    }

    /// Stable provider-owned identity for graph joins. This is deliberately
    /// distinct from the Ouroboros session ID: one session may contain many
    /// independent attempts or agents.
    var agentID: String { leaf.stableKey }

    var terminalID: String { surface.terminalID }
    var brokerGeneration: UInt64 { surface.brokerGeneration }
    var leaf: TerminalSessionLeafIdentity { surface.identity }

    /// A compact tab title keeps the semantic session name visible while
    /// status stays in the secondary line/accessibility value.
    var tabTitle: String {
        let title = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Session" : title
    }

    var tabDetail: String {
        let state = status.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.isEmpty ? "Session" : state.capitalized
    }
}


enum TerminalSessionActivationFailure: Equatable {
    case noCurrentBrokerGeneration
    case noVerifiedBinding
    case terminalNotOpen
    case brokerUnavailable
    case tabLimitReached

    var summary: String {
        switch self {
        case .noCurrentBrokerGeneration: return "Terminal broker is not connected"
        case .noVerifiedBinding: return "No current verified terminal binding"
        case .terminalNotOpen: return "The terminal is no longer open"
        case .brokerUnavailable: return "Terminal broker could not verify this terminal"
        case .tabLimitReached: return "Close a terminal tab before opening this session"
        }
    }
}

enum TerminalSessionActivationResult: Equatable {
    /// The exact terminal view was selected or adopted. This does not bypass
    /// the host's recovery, first-present, or input-lease gates; keyboard input
    /// remains locked until those independent PTY readiness checks complete.
    case activated
    case unavailable(TerminalSessionActivationFailure)

    var isActivated: Bool {
        if case .activated = self { return true }
        return false
    }
}

struct TerminalSessionOpenSurfaceTab: Equatable {
    let primaryTerminalID: String?
    let workspaceTerminalIDs: [String]
}

enum TerminalSessionOpenSurfaceResolution: Equatable {
    case primary(tabIndex: Int)
    case splitPane(tabIndex: Int)
    case none
    case ambiguous

    var isOpen: Bool {
        switch self {
        case .primary, .splitPane, .ambiguous: return true
        case .none: return false
        }
    }
}

/// Resolves an already-open PTY across both tab primaries and split leaves.
/// A terminal may appear as the primary and as a leaf in the same workspace;
/// that is one location. Any cross-tab duplicate fails closed.
enum TerminalSessionOpenSurfacePolicy {
    static func resolve(
        terminalID: String,
        tabs: some Collection<TerminalSessionOpenSurfaceTab>
    ) -> TerminalSessionOpenSurfaceResolution {
        guard !terminalID.isEmpty else { return .none }
        var match: TerminalSessionOpenSurfaceResolution?
        for (index, tab) in tabs.enumerated() {
            let primaryMatches = tab.primaryTerminalID == terminalID
            let workspaceMatchCount = tab.workspaceTerminalIDs.reduce(into: 0) {
                if $1 == terminalID { $0 += 1 }
            }
            guard workspaceMatchCount <= 1 else { return .ambiguous }
            guard primaryMatches || workspaceMatchCount == 1 else { continue }
            guard match == nil else { return .ambiguous }
            match = primaryMatches
                ? .primary(tabIndex: index)
                : .splitPane(tabIndex: index)
        }
        return match ?? .none
    }
}

enum TerminalSessionBindingPolicy {
    static func binding(
        for leaf: TerminalSessionLeafIdentity,
        brokerGeneration: UInt64,
        bindings: some Sequence<TerminalSessionBinding>
    ) -> TerminalSessionBinding? {
        unique(bindings, where: {
            $0.brokerGeneration == brokerGeneration && $0.leaf == leaf
        })
    }

    /// Resolve only through the broker-owned terminal id and its incarnation.
    /// Labels, cwd, AC ids, and display paths can all repeat during fanout.
    static func terminalID(
        for leaf: TerminalSessionLeafIdentity,
        brokerGeneration: UInt64,
        bindings: some Sequence<TerminalSessionBinding>
    ) -> String? {
        binding(
            for: leaf,
            brokerGeneration: brokerGeneration,
            bindings: bindings
        )?.terminalID
    }

    static func leaf(
        for terminalID: String,
        brokerGeneration: UInt64,
        bindings: some Sequence<TerminalSessionBinding>
    ) -> TerminalSessionLeafIdentity? {
        unique(bindings, where: {
            $0.brokerGeneration == brokerGeneration && $0.terminalID == terminalID
        })?.leaf
    }

    static func groupKey(_ leaf: TerminalSessionLeafIdentity) -> String {
        OuroborosSessionTerminalIdentityDecoderV1.stableGroupID(
            sourceID: leaf.sourceID,
            executionID: leaf.executionID
        )
    }

    /// A non-bijective projection is a contract violation, not a hint to pick
    /// the first row. Both join directions stay unavailable until a fresh,
    /// unambiguous broker snapshot arrives.
    private static func unique(
        _ bindings: some Sequence<TerminalSessionBinding>,
        where matches: (TerminalSessionBinding) -> Bool
    ) -> TerminalSessionBinding? {
        var candidate: TerminalSessionBinding?
        for binding in bindings where matches(binding) {
            guard candidate == nil else { return nil }
            candidate = binding
        }
        return candidate
    }
}

/// Revalidates the MCP-owned join after an asynchronous broker list round
/// trip. Equality of the leaf, terminal id, and broker generation is necessary
/// but not sufficient: the binding projection must also be the same revision
/// that authorized the request, so revoke-and-readd cannot revive a stale
/// response.
enum TerminalSessionBindingRevisionPolicy {
    static func accepts(
        expectedRevision: UInt64,
        currentRevision: UInt64,
        expectedBinding: TerminalSessionBinding,
        leaf: TerminalSessionLeafIdentity,
        brokerGeneration: UInt64,
        currentBindings: some Sequence<TerminalSessionBinding>
    ) -> Bool {
        guard expectedRevision == currentRevision,
              expectedBinding.leaf == leaf,
              expectedBinding.brokerGeneration == brokerGeneration,
              let current = TerminalSessionBindingPolicy.binding(
                for: leaf,
                brokerGeneration: brokerGeneration,
                bindings: currentBindings
              ) else {
            return false
        }
        return current == expectedBinding
    }
}

/// Fail-closed gate between an MCP-advertised surface and a broker `list`
/// result. A label or terminal id alone never authorizes adopting a PTY view.
enum TerminalSessionBrokerAdoptionPolicy {
    static func accepts(
        expectedTerminalID: String,
        expectedBrokerGeneration: UInt64,
        currentBrokerGeneration: UInt64?,
        listedTerminalID: String,
        listedTerminalIsRunning: Bool,
        terminalAlreadyOpen: Bool,
        hasTabCapacity: Bool
    ) -> Bool {
        !expectedTerminalID.isEmpty
            && expectedBrokerGeneration > 0
            && currentBrokerGeneration == expectedBrokerGeneration
            && listedTerminalID == expectedTerminalID
            && listedTerminalIsRunning
            && !terminalAlreadyOpen
            && hasTabCapacity
    }
}
