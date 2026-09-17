import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import NorthpaneBridgeResources
@testable import NorthpaneProtocol

private final class SuccessfulPreviewURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ready".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A body of `streamedBodyBytes` bytes, delivered in four pieces like a server writing as it goes.
private let streamedBodyBytes = 40 * 1_024

private final class StreamingPreviewURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for piece in 0..<4 {
            client?.urlProtocol(self, didLoad: Data(repeating: UInt8(ascii: "a") + UInt8(piece), count: streamedBodyBytes / 4))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func streamingProxy(maximumResponseBytes: Int) -> PreviewProxyClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StreamingPreviewURLProtocol.self]
    return PreviewProxyClient(session: URLSession(configuration: configuration), maximumResponseBytes: maximumResponseBytes)
}

/// The streamed body arrives whole and in order, then a final empty chunk. On Linux this runs
/// through the delegate that stands in for `URLSession.bytes(for:)`.
@Test func previewStreamDeliversTheWholeBodyThenAFinalChunk() async throws {
    let store = PreviewStore()
    let registration = try await store.register(hostID: HostID(), workspaceID: "w", origin: URL(string: "http://127.0.0.1:5173")!)
    try await store.setHealth(true, id: registration.id)
    let stream = try await streamingProxy(maximumResponseBytes: 1_024 * 1_024)
        .stream(store: store, id: registration.id, target: URL(string: "http://127.0.0.1:5173/events")!)
    #expect(stream.statusCode == 200)
    var body = Data()
    var sawFinal = false
    for try await chunk in stream.chunks {
        #expect(!sawFinal)
        body.append(chunk.bytes)
        sawFinal = chunk.isFinal
    }
    #expect(sawFinal)
    #expect(body.count == streamedBodyBytes)
    #expect(body.first == UInt8(ascii: "a") && body.last == UInt8(ascii: "d"))
}

@Test func previewStreamStopsAtTheResponseLimit() async throws {
    let store = PreviewStore()
    let registration = try await store.register(hostID: HostID(), workspaceID: "w", origin: URL(string: "http://127.0.0.1:5173")!)
    try await store.setHealth(true, id: registration.id)
    let stream = try await streamingProxy(maximumResponseBytes: streamedBodyBytes / 2)
        .stream(store: store, id: registration.id, target: URL(string: "http://127.0.0.1:5173/events")!)
    await #expect(throws: PreviewError.responseTooLarge) {
        for try await _ in stream.chunks {}
    }
}

@Test func previewSupportsHMRAndSSEButBlocksCrossOriginLoopback() async throws {
    let store = PreviewStore()
    let registration = try await store.register(hostID: HostID(), workspaceID: "w", origin: URL(string: "http://127.0.0.1:5173")!)
    try await store.setHealth(true, id: registration.id)
    #expect(try await store.resolve(id: registration.id, target: URL(string: "http://127.0.0.1:5173/@vite/client")!, transport: .webSocket).path == "/@vite/client")
    #expect(try await store.resolve(id: registration.id, target: URL(string: "http://127.0.0.1:5173/events")!, transport: .serverSentEvents).path == "/events")
    await #expect(throws: PreviewError.crossOrigin) {
        try await store.resolve(id: registration.id, target: URL(string: "http://localhost:3000/private")!, transport: .http)
    }
}

@Test func previewPaneProvenancePersistsWithTheRegistration() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "northpane-preview-store-\(UUID().uuidString)")
    let file = directory.appending(path: "previews.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PreviewStore(fileURL: file)
    let registration = try await store.register(hostID: HostID(), workspaceID: "workspace-1", paneID: "pane-1",
                                                origin: URL(string: "http://127.0.0.1:5173")!, idempotencyKey: "fixture")
    #expect(registration.paneID == "pane-1")

    let reloaded = try PreviewStore(fileURL: file)
    #expect(await reloaded.list().first?.paneID == "pane-1")
}

@Test func readinessProbeTransitionsANewRegistrationToHealthy() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SuccessfulPreviewURLProtocol.self]
    let proxy = PreviewProxyClient(session: URLSession(configuration: configuration))
    let store = PreviewStore()
    let registration = try await store.register(
        hostID: HostID(),
        workspaceID: "workspace-1",
        paneID: "pane-1",
        origin: URL(string: "http://127.0.0.1:8765")!
    )

    try await proxy.probe(store: store, id: registration.id, timeout: 1)

    #expect(try await store.registration(id: registration.id).isHealthy)
}
