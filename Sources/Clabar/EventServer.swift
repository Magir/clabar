import Foundation
import Network

/// Minimal localhost HTTP listener: hooks POST their stdin JSON to /event.
/// ponytail: hand-rolled HTTP/1.1 parse, POST-only, 256KB cap — swap for a real
/// server lib if the protocol ever grows.
final class EventServer {
    private var listener: NWListener?
    private let handler: @Sendable ([String: Any], [String: String]) -> Void

    private static let maxBody = 256 * 1024

    init(handler: @escaping @Sendable ([String: Any], [String: String]) -> Void) {
        self.handler = handler
    }

    func start(port: UInt16) throws {
        stop()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: .global(qos: .utility))
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if buffer.count > Self.maxBody * 2 || error != nil {
                Self.respond(connection, status: "413 Payload Too Large")
                return
            }

            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete {
                    Self.respond(connection, status: "400 Bad Request")
                } else {
                    self.receive(connection, buffer: buffer)
                }
                return
            }

            let headerData = buffer[..<headerEnd.lowerBound]
            guard let head = String(data: headerData, encoding: .utf8) else {
                Self.respond(connection, status: "400 Bad Request")
                return
            }
            let lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.first ?? ""

            if requestLine.hasPrefix("GET /ping") {
                Self.respond(connection, status: "200 OK", body: "clabar")
                return
            }
            guard requestLine.hasPrefix("POST /event") else {
                Self.respond(connection, status: "404 Not Found")
                return
            }

            var headers = [String: String]()
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }

            let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
            guard contentLength <= Self.maxBody else {
                Self.respond(connection, status: "413 Payload Too Large")
                return
            }
            let body = buffer[headerEnd.upperBound...]
            if body.count < contentLength && !isComplete {
                self.receive(connection, buffer: buffer)
                return
            }

            if let json = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any] {
                self.handler(json, headers)
                Self.respond(connection, status: "204 No Content")
            } else {
                Self.respond(connection, status: "400 Bad Request")
            }
        }
    }

    private static func respond(_ connection: NWConnection, status: String, body: String = "") {
        let payload = "HTTP/1.1 \(status)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(payload.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
