import Foundation

final class LoopbackMCPHTTPTransport: MCPV2CatalogTransport {
    private let endpoint: URL
    private let bearerToken: String
    private let lock = NSLock()
    private var tasks: [URLSessionTask] = []
    private let session: URLSession

    init(endpoint: URL, bearerToken: String) {
        precondition(endpoint.scheme == "http", "MCP loopback transport requires http")
        precondition(bearerToken.utf8.count == 64, "MCP loopback transport requires a 64-character token")
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        self.session = URLSession(configuration: configuration)
    }

    func request(
        id: Int,
        method: String,
        params: [String: Any],
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        send(id: id, method: method, params: params, completion: completion)
    }

    func notify(method: String, params: [String: Any]) {
        send(id: nil, method: method, params: params) { _ in }
    }

    func cancel() {
        lock.lock()
        let active = tasks
        tasks.removeAll(keepingCapacity: false)
        lock.unlock()
        active.forEach { $0.cancel() }
    }

    private func send(
        id: Int?,
        method: String,
        params: [String: Any],
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        var object: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { object["id"] = id }
        guard JSONSerialization.isValidJSONObject(object),
              let body = try? JSONSerialization.data(withJSONObject: object) else {
            completion(.failure(LoopbackMCPHTTPError.invalidRequest))
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if method != "initialize" {
            request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        }
        request.httpBody = body
        var task: URLSessionDataTask!
        task = session.dataTask(with: request) { [weak self] data, response, error in
            defer { self?.remove(task) }
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode), let data else {
                completion(.failure(LoopbackMCPHTTPError.httpStatus(
                    (response as? HTTPURLResponse)?.statusCode ?? -1
                )))
                return
            }
            guard id != nil else { completion(.success(Data())); return }
            guard data.count <= MCPV2CatalogLimits.desktop.maximumResponseBytes else {
                completion(.failure(LoopbackMCPHTTPError.oversized))
                return
            }
            if let envelope = Self.decodeEnvelope(data) {
                completion(.success(envelope))
            } else {
                completion(.failure(LoopbackMCPHTTPError.invalidResponse))
            }
        }
        lock.lock()
        tasks.append(task)
        lock.unlock()
        task.resume()
    }

    private func remove(_ task: URLSessionTask) {
        lock.lock()
        tasks.removeAll { $0 === task }
        lock.unlock()
    }

    private static func decodeEnvelope(_ data: Data) -> Data? {
        if (try? JSONSerialization.jsonObject(with: data)) != nil { return data }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: { $0.isNewline }) where line.hasPrefix("data:") {
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let payloadData = payload.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: payloadData)) != nil else { continue }
            return payloadData
        }
        return nil
    }
}

enum LoopbackMCPHTTPError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)
    case oversized

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Invalid MCP request"
        case .invalidResponse: return "Invalid MCP response"
        case .httpStatus(let status): return "MCP HTTP \(status)"
        case .oversized: return "MCP response exceeded the safety bound"
        }
    }
}
