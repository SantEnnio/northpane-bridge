import Foundation
import Testing
@testable import NorthpaneBridgeResources

#if os(macOS) || os(Linux)
@Test func bundledReaderExtractionRecoversCorruptionAndKeepsRollback() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let previous = Data("previous reader".utf8), current = Data("current reader".utf8)
    let old = try BundledClaudeReader.install(payload: previous, root: root)
    let new = try BundledClaudeReader.install(payload: current, root: root)
    #expect(old != new)
    try Data("corrupt".utf8).write(to: new)
    #expect(try BundledClaudeReader.install(payload: current, root: root) == new)
    #expect(try Data(contentsOf: new) == current)
    #expect(try Data(contentsOf: old) == previous)
    #expect(try BundledClaudeReader.install(payload: previous, root: root) == old)
    #expect(try FileManager.default.attributesOfItem(atPath: new.path)[.posixPermissions] as? Int == 0o700)
}

@Test func bundledReaderExtractionReplacesSymlinksWithoutWritingTheirTargets() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = Data("reader".utf8)
    let file = try BundledClaudeReader.install(payload: payload, root: root)
    let target = root.appendingPathComponent("unrelated")
    try Data("unrelated".utf8).write(to: target)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    #expect(try BundledClaudeReader.install(payload: payload, root: root) == file)
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular)
    #expect(try String(contentsOf: target, encoding: .utf8) == "unrelated")
}

@Test func bundledReaderStartsWithoutExternalRuntimesWhenPackagingRequiresIt() {
    guard ProcessInfo.processInfo.environment["NORTHPANE_CLAUDE_READER_EXECUTABLE"] != nil else { return }
    #expect(AgentConversationReader.checkBundledClaudeReader())
}

@Test func freshHostClaudeConversationDoesNotRequireManualSDKInstallation() async throws {
    guard ProcessInfo.processInfo.environment["NORTHPANE_CLAUDE_READER_EXECUTABLE"] != nil else { return }
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let reading = await AgentConversationReader.read(.init(agent: .claude), directory: workspace.path)
    #expect(reading.problem == nil)
    #expect(reading.sessions.isEmpty)
}
#endif
