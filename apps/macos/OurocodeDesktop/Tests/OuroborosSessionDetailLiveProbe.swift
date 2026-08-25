import Foundation

@main
enum OuroborosSessionDetailLiveProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else {
            FileHandle.standardError.write(Data("usage: live-probe RESPONSE_DIR SESSION_ID EXECUTION_ID\n".utf8))
            exit(64)
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let sessionID = CommandLine.arguments[2]
        let executionID = CommandLine.arguments[3]
        var pages: [OuroborosSessionDetailProjectionV0511.Page] = []
        for eventType in OuroborosSessionDetailProjectionV0511.EventType.allCases {
            let name = eventType.rawValue.replacingOccurrences(of: ".", with: "_") + ".json"
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                FileHandle.standardError.write(Data("FAIL: response is not a JSON-RPC object\n".utf8))
                exit(1)
            }
            switch OuroborosSessionDetailProjectionV0511.decodePage(
                response: response,
                sessionID: sessionID,
                eventType: eventType
            ) {
            case .success(let page): pages.append(page)
            case .failure(let failure):
                FileHandle.standardError.write(Data("FAIL: \(failure.description)\n".utf8))
                exit(1)
            }
        }
        switch OuroborosSessionDetailProjectionV0511.build(
            pages: pages,
            sessionID: sessionID,
            executionID: executionID
        ) {
        case .success(let snapshot):
            print(
                "PASS: live selected-session detail merged \(snapshot.events.count) recent events"
                    + (snapshot.moreAvailable ? " with bounded older history" : "")
            )
        case .failure(let failure):
            FileHandle.standardError.write(Data("FAIL: \(failure.description)\n".utf8))
            exit(1)
        }
    }
}
