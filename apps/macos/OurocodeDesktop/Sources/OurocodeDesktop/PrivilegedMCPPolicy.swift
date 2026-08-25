import Foundation

enum PrivilegedMCPApprovalScope: String, Codable, Equatable {
    case denied
    case ask
    case session
    case workspace
}

enum PrivilegedMCPToolRisk: Int, Comparable {
    case inspect = 0
    case capture = 1
    case interact = 2
    case input = 3
    case destructive = 4

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct PrivilegedMCPRequestContext: Equatable {
    let sourceID: String
    let sessionID: String
    let workspace: String
    let toolName: String
    let destructiveConfirmed: Bool
}

enum PrivilegedMCPDecision: Equatable {
    case allow
    case requireApproval(PrivilegedMCPToolRisk)
    case deny(String)
}

enum PrivilegedMCPPolicy {
    static func risk(toolName rawName: String) -> PrivilegedMCPToolRisk {
        let name = rawName.lowercased()
        if name.contains("delete") || name.contains("erase") || name.contains("remove") {
            return .destructive
        }
        if name.contains("type") || name.contains("press_key") || name.contains("drag") {
            return .input
        }
        if name.contains("click") || name.contains("scroll") || name.contains("hover") {
            return .interact
        }
        if name.contains("screenshot") || name.contains("capture") {
            return .capture
        }
        return .inspect
    }

    static func decide(
        context: PrivilegedMCPRequestContext,
        approval: PrivilegedMCPApprovalScope,
        approvedSessionID: String? = nil,
        approvedWorkspace: String? = nil
    ) -> PrivilegedMCPDecision {
        guard context.sourceID == "computer-use" else { return .allow }
        let risk = risk(toolName: context.toolName)
        if risk == .destructive, !context.destructiveConfirmed {
            return .deny("Destructive Computer Use action requires explicit confirmation")
        }
        switch approval {
        case .denied:
            return .deny("Computer Use is denied for this terminal")
        case .ask:
            return .requireApproval(risk)
        case .session:
            return approvedSessionID == context.sessionID
                ? .allow
                : .requireApproval(risk)
        case .workspace:
            return approvedWorkspace == context.workspace
                ? .allow
                : .requireApproval(risk)
        }
    }
}

struct PrivilegedMCPApprovalStore {
    private static let keyPrefix = "privilegedMCPApproval."
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func scope(sourceID: String) -> PrivilegedMCPApprovalScope {
        defaults.string(forKey: Self.keyPrefix + sourceID)
            .flatMap(PrivilegedMCPApprovalScope.init(rawValue:)) ?? .ask
    }

    func setScope(_ scope: PrivilegedMCPApprovalScope, sourceID: String) {
        defaults.set(scope.rawValue, forKey: Self.keyPrefix + sourceID)
    }
}
