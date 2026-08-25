import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum PrivilegedMCPPolicyFixture {
    static func main() {
        let context = PrivilegedMCPRequestContext(
            sourceID: "computer-use",
            sessionID: "session-1",
            workspace: "/fixture/project",
            toolName: "cua_click",
            destructiveConfirmed: false
        )
        require(
            PrivilegedMCPPolicy.decide(context: context, approval: .denied)
                == .deny("Computer Use is denied for this terminal"),
            "denied CUA was allowed"
        )
        require(
            PrivilegedMCPPolicy.decide(context: context, approval: .ask) == .requireApproval(.interact),
            "interactive CUA did not require approval"
        )
        require(
            PrivilegedMCPPolicy.decide(
                context: context,
                approval: .session,
                approvedSessionID: "session-1"
            ) == .allow,
            "session approval did not allow CUA"
        )
        let destructive = PrivilegedMCPRequestContext(
            sourceID: context.sourceID,
            sessionID: context.sessionID,
            workspace: context.workspace,
            toolName: "cua_delete",
            destructiveConfirmed: false
        )
        require(
            PrivilegedMCPPolicy.decide(context: destructive, approval: .session, approvedSessionID: "session-1")
                == .deny("Destructive Computer Use action requires explicit confirmation"),
            "destructive CUA bypassed confirmation"
        )
        print("PASS: privileged CUA policy scopes access and gates destructive actions")
    }
}
