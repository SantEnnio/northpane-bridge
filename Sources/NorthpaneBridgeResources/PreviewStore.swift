import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NorthpaneProtocol

public enum PreviewTransport: String, Codable, Sendable { case http, webSocket, serverSentEvents }

public struct PreviewRegistration: Equatable, Codable, Sendable {
    public let id: UUID
    public let hostID: HostID
    public let workspaceID: String
    public let paneID: String?
    public let agentIncarnationID: String?
    public let origin: URL
    public let createdAt: Date
    public fileprivate(set) var revision: Int
    public fileprivate(set) var title: String?
    public fileprivate(set) var healthPath: String
    public fileprivate(set) var expiresAt: Date
    public fileprivate(set) var isHealthy: Bool
}

public enum PreviewError: Error, Equatable, Sendable {
    case invalidOrigin, invalidTTL, notFound, expired, unhealthy, crossOrigin, unsupportedTransport
    case readinessTimeout, responseTooLarge, redirectLoop, disconnected
}

public actor PreviewStore {
    private struct Document: Codable { let schemaVersion: Int; let registrations: [PreviewRegistration]; let idempotency: [String: UUID] }
    private let fileURL: URL?
    private var registrations: [UUID: PreviewRegistration] = [:]
    private var idempotency: [String: UUID] = [:]
    public init() { self.fileURL = nil }
    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
                guard document.schemaVersion == 1 else { throw PreviewError.disconnected }
                registrations = Dictionary(uniqueKeysWithValues: document.registrations.map { ($0.id, $0) })
                idempotency = document.idempotency
            } catch let error as PreviewError { throw error }
            catch { throw PreviewError.disconnected }
        }
    }

    public func register(
        hostID: HostID,
        workspaceID: String,
        paneID: String? = nil,
        agentIncarnationID: String? = nil,
        origin: URL,
        title: String? = nil,
        healthPath: String = "/",
        ttl: TimeInterval = 8 * 60 * 60,
        idempotencyKey: String? = nil,
        now: Date = Date()
    ) throws -> PreviewRegistration {
        if let idempotencyKey, let id = idempotency[idempotencyKey], let prior = registrations[id], prior.expiresAt >= now { return prior }
        guard isLoopback(origin), origin.scheme?.lowercased() == "http" || origin.scheme?.lowercased() == "https" else { throw PreviewError.invalidOrigin }
        guard ttl > 0, ttl <= 24 * 60 * 60 else { throw PreviewError.invalidTTL }
        guard healthPath.hasPrefix("/"), !healthPath.hasPrefix("//") else { throw PreviewError.invalidOrigin }
        let registration = PreviewRegistration(
            id: UUID(), hostID: hostID, workspaceID: workspaceID, paneID: paneID,
            agentIncarnationID: agentIncarnationID, origin: origin, createdAt: now,
            revision: 1, title: title, healthPath: healthPath,
            expiresAt: now.addingTimeInterval(ttl), isHealthy: false
        )
        registrations[registration.id] = registration
        if let idempotencyKey { idempotency[idempotencyKey] = registration.id }
        try persist()
        return registration
    }

    public func update(id: UUID, title: String?, healthPath: String, ttl: TimeInterval, now: Date = Date()) throws -> PreviewRegistration {
        guard var registration = registrations[id] else { throw PreviewError.notFound }
        guard ttl > 0, ttl <= 24 * 60 * 60 else { throw PreviewError.invalidTTL }
        guard healthPath.hasPrefix("/"), !healthPath.hasPrefix("//") else { throw PreviewError.invalidOrigin }
        registration.revision += 1
        registration.title = title
        registration.healthPath = healthPath
        registration.expiresAt = now.addingTimeInterval(ttl)
        registration.isHealthy = false
        registrations[id] = registration
        try persist()
        return registration
    }

    public func setHealth(_ healthy: Bool, id: UUID) throws {
        guard var registration = registrations[id] else { throw PreviewError.notFound }
        registration.isHealthy = healthy
        registrations[id] = registration
        try persist()
    }

    public func registration(id: UUID, now: Date = Date(), requireHealthy: Bool = true) throws -> PreviewRegistration {
        guard let registration = registrations[id] else { throw PreviewError.notFound }
        guard registration.expiresAt >= now else { throw PreviewError.expired }
        if requireHealthy, !registration.isHealthy { throw PreviewError.unhealthy }
        return registration
    }

    public func list(now: Date = Date()) -> [PreviewRegistration] {
        registrations.values.filter { $0.expiresAt >= now }.sorted { $0.createdAt > $1.createdAt }
    }

    public func resolve(id: UUID, target: URL, transport: PreviewTransport, requireHealthy: Bool = true, now: Date = Date()) throws -> URL {
        let registration = try registration(id: id, now: now, requireHealthy: requireHealthy)
        guard [.http, .webSocket, .serverSentEvents].contains(transport) else { throw PreviewError.unsupportedTransport }
        guard Self.origin(of: registration.origin) == Self.origin(of: target) else { throw PreviewError.crossOrigin }
        return target
    }

    public func close(_ id: UUID) throws {
        registrations.removeValue(forKey: id)
        idempotency = idempotency.filter { $0.value != id }
        try persist()
    }

    private func isLoopback(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.fragment == nil, let host = url.host?.lowercased(), url.port != 0 else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    fileprivate static func origin(of url: URL) -> String {
        let rawScheme = url.scheme?.lowercased() ?? ""
        let scheme = rawScheme == "ws" ? "http" : rawScheme == "wss" ? "https" : rawScheme
        return "\(scheme)://\(url.host?.lowercased() ?? ""):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }

    private func persist() throws {
        guard let fileURL else { return }
        let document = Document(schemaVersion: 1, registrations: registrations.values.sorted { $0.id.uuidString < $1.id.uuidString }, idempotency: idempotency)
        try JSONEncoder().encode(document).write(to: fileURL, options: [.atomic])
    }
}

public struct PreviewHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data
}

public struct PreviewBodyChunk: Equatable, Sendable {
    public let bytes: Data
    public let isFinal: Bool
    public init(bytes: Data, isFinal: Bool = false) { self.bytes = bytes; self.isFinal = isFinal }
}
public struct PreviewHTTPStream: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let chunks: AsyncThrowingStream<PreviewBodyChunk, Error>
}

/// Executes the Preview data plane without exposing the loopback origin to a
/// Client. Redirects are followed manually and revalidated at every hop.
public actor PreviewProxyClient {
    private let session: URLSession
    private let maximumResponseBytes: Int

    public init(maximumResponseBytes: Int = 16 * 1_024 * 1_024) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        self.maximumResponseBytes = maximumResponseBytes
    }

    init(session: URLSession, maximumResponseBytes: Int = 16 * 1_024 * 1_024) {
        self.session = session
        self.maximumResponseBytes = maximumResponseBytes
    }

    public func probe(store: PreviewStore, id: UUID, timeout: TimeInterval = 60) async throws {
        guard timeout > 0, timeout <= 60 else { throw PreviewError.readinessTimeout }
        let registration = try await store.registration(id: id, requireHealthy: false)
        guard let target = URL(string: registration.healthPath, relativeTo: registration.origin)?.absoluteURL else { throw PreviewError.invalidOrigin }
        do {
            _ = try await withThrowingTaskGroup(of: PreviewHTTPResponse.self) { group in
                group.addTask { try await self.fetch(store: store, id: id, target: target, requireHealthy: false) }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw PreviewError.readinessTimeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            try await store.setHealth(true, id: id)
        } catch {
            try? await store.setHealth(false, id: id)
            throw error
        }
    }

    public func fetch(
        store: PreviewStore,
        id: UUID,
        target: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        requireHealthy: Bool = true
    ) async throws -> PreviewHTTPResponse {
        var current = target
        for _ in 0..<6 {
            _ = try await store.resolve(id: id, target: current, transport: .http, requireHealthy: requireHealthy)
            var request = URLRequest(url: current)
            request.httpMethod = method
            request.httpBody = body
            for (name, value) in Self.sanitizedRequestHeaders(headers) { request.setValue(value, forHTTPHeaderField: name) }
            let (data, response) = try await session.data(for: request)
            guard data.count <= maximumResponseBytes else { throw PreviewError.responseTooLarge }
            guard let http = response as? HTTPURLResponse else { throw PreviewError.disconnected }
            if (300..<400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"), let redirected = URL(string: location, relativeTo: current)?.absoluteURL {
                _ = try await store.resolve(id: id, target: redirected, transport: .http, requireHealthy: requireHealthy)
                current = redirected
                continue
            }
            return PreviewHTTPResponse(statusCode: http.statusCode, headers: Self.sanitizedResponseHeaders(http.allHeaderFields), body: data)
        }
        throw PreviewError.redirectLoop
    }

    public func openWebSocket(store: PreviewStore, id: UUID, target: URL) async throws -> PreviewWebSocketTunnel {
        _ = try await store.resolve(id: id, target: target, transport: .webSocket)
        var components = URLComponents(url: target, resolvingAgainstBaseURL: true)
        if components?.scheme == "http" { components?.scheme = "ws" }
        if components?.scheme == "https" { components?.scheme = "wss" }
        guard let socketURL = components?.url else { throw PreviewError.invalidOrigin }
        let task = session.webSocketTask(with: socketURL)
        task.resume()
        return PreviewWebSocketTunnel(task: task)
    }

    /// Streams HTTP/SSE bodies through a bounded queue. A slow Client closes
    /// the stream instead of allowing unbounded Host memory growth.
    public func stream(store: PreviewStore, id: UUID, target: URL, headers: [String: String] = [:]) async throws -> PreviewHTTPStream {
        _ = try await store.resolve(id: id, target: target, transport: .serverSentEvents)
        var request = URLRequest(url: target)
        request.httpMethod = "GET"
        for (name, value) in Self.sanitizedRequestHeaders(headers) { request.setValue(value, forHTTPHeaderField: name) }
        #if canImport(FoundationNetworking)
        let (bytes, response) = try await StreamingBodyDelegate.start(request, configuration: session.configuration, limit: maximumResponseBytes)
        #else
        let (bytes, response) = try await session.bytes(for: request)
        #endif
        guard let http = response as? HTTPURLResponse else { throw PreviewError.disconnected }
        guard !(300..<400).contains(http.statusCode) else { throw PreviewError.crossOrigin }
        let chunks = AsyncThrowingStream<PreviewBodyChunk, Error>(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let task = Task {
                do {
                    var chunk = Data(); chunk.reserveCapacity(16 * 1_024)
                    var total = 0
                    func append(_ byte: UInt8) throws {
                        chunk.append(byte); total += 1
                        guard total <= maximumResponseBytes else { throw PreviewError.responseTooLarge }
                        if chunk.count >= 16 * 1_024 {
                            if case .dropped = continuation.yield(.init(bytes: chunk)) { throw PreviewError.disconnected }
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    #if canImport(FoundationNetworking)
                    for try await piece in bytes {
                        try Task.checkCancellation()
                        for byte in piece { try append(byte) }
                    }
                    #else
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        try append(byte)
                    }
                    #endif
                    if !chunk.isEmpty, case .dropped = continuation.yield(.init(bytes: chunk)) { throw PreviewError.disconnected }
                    continuation.yield(.init(bytes: Data(), isFinal: true))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return PreviewHTTPStream(statusCode: http.statusCode, headers: Self.sanitizedResponseHeaders(http.allHeaderFields), chunks: chunks)
    }

    private static func sanitizedRequestHeaders(_ headers: [String: String]) -> [String: String] {
        let forbidden = Set(["authorization", "proxy-authorization", "cookie", "host", "connection", "upgrade"])
        return headers.filter { !forbidden.contains($0.key.lowercased()) }
    }

    private static func sanitizedResponseHeaders(_ headers: [AnyHashable: Any]) -> [String: String] {
        let forbidden = Set(["set-cookie", "set-cookie2", "www-authenticate", "proxy-authenticate"])
        return headers.reduce(into: [:]) { result, entry in
            let name = String(describing: entry.key)
            guard !forbidden.contains(name.lowercased()) else { return }
            result[name] = String(describing: entry.value)
        }
    }
}

public actor PreviewWebSocketTunnel {
    private let task: URLSessionWebSocketTask
    private var closed = false
    fileprivate init(task: URLSessionWebSocketTask) { self.task = task }

    public func send(_ data: Data, isText: Bool = false) async throws {
        guard !closed else { throw PreviewError.disconnected }
        if isText { try await task.send(.string(String(decoding: data, as: UTF8.self))) }
        else { try await task.send(.data(data)) }
    }

    public func receive() async throws -> Data {
        try await receiveMessage().data
    }

    public func receiveMessage() async throws -> (data: Data, isText: Bool) {
        guard !closed else { throw PreviewError.disconnected }
        switch try await task.receive() {
        case let .data(data): return (data, false)
        case let .string(text): return (Data(text.utf8), true)
        @unknown default: throw PreviewError.disconnected
        }
    }

    public func close() {
        guard !closed else { return }
        closed = true
        task.cancel(with: .goingAway, reason: nil)
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

#if canImport(FoundationNetworking)
/// swift-corelibs-foundation has no `URLSession.bytes(for:)`: this delegate streams a body in the
/// pieces the session delivers. It owns a session of its own (a delegate is per session), refuses
/// redirects like `NoRedirectDelegate`, and cancels the transfer once more than `limit` bytes
/// arrived, so a Client that reads slowly cannot make the Host buffer an unbounded body.
private final class StreamingBodyDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let body: AsyncThrowingStream<Data, Error>
    private let bodyContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let limit: Int
    private let lock = NSLock()
    private var pendingResponse: CheckedContinuation<URLResponse, Error>?
    private var received = 0

    private init(limit: Int) {
        self.limit = limit
        (body, bodyContinuation) = AsyncThrowingStream.makeStream(of: Data.self)
    }

    static func start(_ request: URLRequest, configuration: URLSessionConfiguration, limit: Int) async throws -> (AsyncThrowingStream<Data, Error>, URLResponse) {
        let delegate = StreamingBodyDelegate(limit: limit)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        delegate.bodyContinuation.onTermination = { _ in
            task.cancel()
            session.finishTasksAndInvalidate()
        }
        let response = try await withCheckedThrowingContinuation { continuation in
            delegate.lock.withLock { delegate.pendingResponse = continuation }
            task.resume()
        }
        return (delegate.body, response)
    }

    private func takePendingResponse() -> CheckedContinuation<URLResponse, Error>? {
        lock.withLock {
            defer { pendingResponse = nil }
            return pendingResponse
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        takePendingResponse()?.resume(returning: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceeded = lock.withLock {
            received += data.count
            return received > limit
        }
        if exceeded {
            bodyContinuation.finish(throwing: PreviewError.responseTooLarge)
            dataTask.cancel()
        } else {
            bodyContinuation.yield(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        takePendingResponse()?.resume(throwing: error ?? PreviewError.disconnected)
        if let error { bodyContinuation.finish(throwing: error) } else { bodyContinuation.finish() }
        session.finishTasksAndInvalidate()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}
#endif
