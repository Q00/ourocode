import Foundation

struct LiveTerminalSession: Equatable {
    let id: UUID
    let title: String
    let path: String
    let selected: Bool
    let running: Bool
    let foregroundProcess: Bool
    let binding: TerminalSessionBinding?

    var status: String {
        guard running else { return "ended" }
        return foregroundProcess ? "active" : "ready"
    }

    var detail: String {
        let location = (path as NSString).abbreviatingWithTildeInPath
        if let binding {
            return "\(binding.tabDetail) · \(location)"
        }
        return foregroundProcess ? "Agent running · \(location)" : location
    }
}
