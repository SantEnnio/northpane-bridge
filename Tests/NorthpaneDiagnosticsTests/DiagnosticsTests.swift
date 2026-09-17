import Foundation
import Testing
@testable import NorthpaneDiagnostics
@testable import NorthpaneProtocol

@Test func diagnosticBundlePseudonymizesCorrelationAndContainsNoPayload() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "northpane-diagnostics-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let problem = Problem(code: "connection_failed", locus: .transport, retry: .afterReconnect, recoveryAction: "reconnect", phase: .handshake, correlationID: "/Users/alice/private-project")
    let bundle = DiagnosticBundle(versions: [.init(component: "bridge", version: "1.0.0")], capabilities: [.observeRuntime], selfChecks: ["schema": .passed], entries: [.init(problem: problem)])
    let directory = try DiagnosticExporter.export(bundle, to: base)
    let output = try String(contentsOf: directory.appending(path: "diagnostics.json"), encoding: .utf8)
    #expect(!output.contains("/Users/alice"))
    #expect(!output.contains("private-project"))
    #expect(output.contains("connection_failed"))
}
