import Foundation
import Network

enum SyncError: LocalizedError {
    case unreachable
    case wrongCode
    case badResponse
    case empty

    var errorDescription: String? {
        switch self {
        case .unreachable:
            return "Could not reach that phone. Check that both are on the same Wi-Fi and that Send is on."
        case .wrongCode:
            return "Wrong code, or sharing is off on that phone."
        case .badResponse:
            return "The other phone sent something unexpected."
        case .empty:
            return "That phone has no stock or sales to receive."
        }
    }
}

/// Holds the data and code that the server hands out. Written from the main thread, read by the network thread.
final class SyncState: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()
    private var _code = ""

    var data: Data {
        get { lock.lock(); defer { lock.unlock() }; return _data }
        set { lock.lock(); _data = newValue; lock.unlock() }
    }

    var code: String {
        get { lock.lock(); defer { lock.unlock() }; return _code }
        set { lock.lock(); _code = newValue; lock.unlock() }
    }
}

/// A small HTTP server on port 3001, the same port and path the Android app uses.
/// GET /sync/export?code=1234 returns this phone's data as JSON.
final class LanSyncServer: @unchecked Sendable {
    private let state: SyncState
    private var listener: NWListener?

    init(state: SyncState) {
        self.state = state
    }

    func start(deviceName: String) throws {
        let l = try NWListener(using: .tcp, on: 3001)
        l.service = NWListener.Service(name: deviceName, type: "_wanishop._tcp")
        l.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        l.start(queue: .global())
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [state] data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")

            var status = "404 Not Found"
            var body = Data()
            if parts.count >= 2,
               let comps = URLComponents(string: String(parts[1])),
               comps.path == "/sync/export" {
                let given = comps.queryItems?.first(where: { $0.name == "code" })?.value ?? ""
                if !state.code.isEmpty && given == state.code {
                    status = "200 OK"
                    body = state.data
                } else {
                    status = "403 Forbidden"
                    body = Data("Wrong code".utf8)
                }
            }

            var out = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            out.append(body)
            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}

/// Asks another phone (Bonjour name or typed address) for its data.
enum LanSyncClient {
    static func fetch(_ endpoint: NWEndpoint, code: String) async throws -> Data {
        let conn = NWConnection(to: endpoint, using: .tcp)
        defer { conn.cancel() }
        try await ready(conn)

        let request = "GET /sync/export?code=\(code) HTTP/1.1\r\nHost: wanishop\r\nConnection: close\r\n\r\n"
        try await send(conn, Data(request.utf8))

        var response = Data()
        while true {
            let (chunk, finished) = try await receive(conn)
            response.append(chunk)
            if finished { break }
        }

        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else {
            throw SyncError.badResponse
        }
        let head = String(decoding: response[..<split.lowerBound], as: UTF8.self)
        if head.contains(" 403 ") { throw SyncError.wrongCode }
        guard head.contains(" 200 ") else { throw SyncError.badResponse }
        return Data(response[split.upperBound...])
    }

    private static func ready(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            conn.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume()
                case .failed, .cancelled:
                    resumed = true
                    cont.resume(throwing: SyncError.unreachable)
                default:
                    break
                }
            }
            conn.start(queue: .global())
        }
    }

    private static func send(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    private static func receive(_ conn: NWConnection) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, Bool), Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                cont.resume(returning: (data ?? Data(), isComplete))
            }
        }
    }
}

struct SyncDevice: Identifiable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { name }
}

/// Finds other WaniShop phones on the same Wi-Fi.
final class LanBrowser: ObservableObject {
    @Published var devices: [SyncDevice] = []
    private var browser: NWBrowser?

    func start(ownName: String) {
        stop()
        let b = NWBrowser(for: .bonjour(type: "_wanishop._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [SyncDevice] = results.compactMap { (r) -> SyncDevice? in
                guard case let .service(name, _, _, _) = r.endpoint, name != ownName else { return nil }
                return SyncDevice(name: name, endpoint: r.endpoint)
            }
            DispatchQueue.main.async {
                self?.devices = found
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
