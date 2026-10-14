#if os(macOS) || os(Linux)
import Foundation
import NorthpaneHostRuntime
import NorthpaneProtocol

struct NativePaneInformation: Sendable {
    let scrollbackLines: Int
    let conversation: RuntimeConversationIdentity?
    let lastActivity: Date?
}

extension NativeRuntimeConnection {
    func openTerminal(paneID: String, mode: TerminalAttachMode, columns: Int, rows: Int) throws -> NativeTerminalView {
        guard let columns = UInt32(exactly: columns), let rows = UInt32(exactly: rows) else { throw NativeRuntimeProcessError.invalidConfiguration }
        var command = Northpane_Runtime_V1_TerminalCommand()
        command.open.paneID = paneID; command.open.columns = columns; command.open.rows = rows
        command.open.mode = switch mode { case .observe: .observe; case .control: .control; case .takeover: .takeover }
        return try terminal(command)
    }

    func pollTerminal(attachmentID: UUID, afterRevision: Int) throws -> NativeTerminalView {
        var command = Northpane_Runtime_V1_TerminalCommand()
        command.attachmentID = attachmentID.uuidString; command.poll.afterRevision = Int64(afterRevision)
        return try terminal(command)
    }

    func inputTerminal(attachmentID: UUID, bytes: Data) throws {
        var command = Northpane_Runtime_V1_TerminalCommand()
        command.attachmentID = attachmentID.uuidString; command.input.data = bytes
        _ = try terminal(command)
    }

    func resizeTerminal(attachmentID: UUID, columns: Int, rows: Int) throws {
        guard let columns = UInt32(exactly: columns), let rows = UInt32(exactly: rows) else { throw NativeRuntimeProcessError.invalidConfiguration }
        var command = Northpane_Runtime_V1_TerminalCommand()
        command.attachmentID = attachmentID.uuidString; command.resize.columns = columns; command.resize.rows = rows
        _ = try terminal(command)
    }

    func scrollTerminal(attachmentID: UUID, direction: TerminalScrollDirection, lines: Int) throws {
        guard let lines = UInt32(exactly: lines), lines > 0 else { throw NativeRuntimeProcessError.invalidConfiguration }
        var command = Northpane_Runtime_V1_TerminalCommand()
        command.attachmentID = attachmentID.uuidString; command.scroll.direction = direction == .up ? .scrollUp : .scrollDown
        command.scroll.lines = lines
        _ = try terminal(command)
    }

    func releaseTerminal(attachmentID: UUID) throws {
        var command = Northpane_Runtime_V1_TerminalCommand()
        command.attachmentID = attachmentID.uuidString; command.release = .init()
        _ = try terminal(command)
    }

    private func terminal(_ command: Northpane_Runtime_V1_TerminalCommand) throws -> NativeTerminalView {
        guard status.terminalFrames else { throw NativeRuntimeProcessError.rejected("terminal_frames_unavailable") }
        var request = Northpane_Runtime_V1_Request(); request.id = 4; request.terminal = command
        let response = try socket.exchange(request)
        if case let .failure(failure) = response.outcome { throw NativeRuntimeProcessError.rejected(failure.code) }
        guard case let .terminal(result) = response.outcome,
              let id = UUID(uuidString: result.attachmentID), UUID(uuidString: result.processProof) != nil,
              let revision = Int(exactly: result.revision), revision >= 0,
              command.attachmentID.isEmpty || id.uuidString == command.attachmentID else { throw NativeRuntimeProcessError.invalidFrame }
        return NativeTerminalView(attachmentID: id, processProof: result.processProof, revision: revision,
            bytes: result.frame, controlling: result.controlling, ended: result.ended)
    }

    func observedRevision() throws -> Int {
        guard status.terminalFrames else { throw NativeRuntimeProcessError.rejected("terminal_frames_unavailable") }
        var request = Northpane_Runtime_V1_Request(); request.id = 5; request.observe = .init()
        let response = try socket.exchange(request)
        if case let .failure(failure) = response.outcome { throw NativeRuntimeProcessError.rejected(failure.code) }
        guard case let .changes(changes) = response.outcome, let value = Int(exactly: changes.revision), value >= 0 else {
            throw NativeRuntimeProcessError.invalidFrame
        }
        return value
    }

    public func startAgent(paneID: String, kind: WorkspaceAgentKind, executable: URL) async throws {
        guard status.terminalFrames else { throw NativeRuntimeProcessError.rejected("terminal_frames_unavailable") }
        try await Task.detached { [self] in
            var request = Northpane_Runtime_V1_Request(); request.id = 6
            request.startAgent.paneID = paneID; request.startAgent.kind = NativeRuntimeServer.agentKind(kind.rawValue)
            request.startAgent.executable = executable.path
            let response = try socket.exchange(request)
            if case let .failure(failure) = response.outcome { throw NativeRuntimeProcessError.rejected(failure.code) }
            guard case .acknowledged = response.outcome else { throw NativeRuntimeProcessError.invalidFrame }
        }.value
    }

    func paneInformation(paneID: String) async throws -> NativePaneInformation {
        guard status.terminalFrames else { throw NativeRuntimeProcessError.rejected("terminal_frames_unavailable") }
        return try await Task.detached { [self] in
            var request = Northpane_Runtime_V1_Request(); request.id = 7; request.paneQuery.paneID = paneID
            let response = try socket.exchange(request)
            if case let .failure(failure) = response.outcome { throw NativeRuntimeProcessError.rejected(failure.code) }
            guard case let .pane(info) = response.outcome, let lines = Int(exactly: info.scrollbackLines), lines >= 0 else {
                throw NativeRuntimeProcessError.invalidFrame
            }
            let identity: RuntimeConversationIdentity?
            if info.agent == .agentUnspecified { identity = nil }
            else {
                guard UUID(uuidString: info.processProof) != nil else { throw NativeRuntimeProcessError.invalidFrame }
                identity = RuntimeConversationIdentity(agent: try NativeRuntimeServer.agentKind(info.agent).rawValue.lowercased(),
                    sessionID: info.sessionID.isEmpty ? nil : info.sessionID, processProof: info.processProof)
            }
            let date = info.lastActivityMilliseconds > 0 ? Date(timeIntervalSince1970: Double(info.lastActivityMilliseconds) / 1000) : nil
            return NativePaneInformation(scrollbackLines: lines, conversation: identity, lastActivity: date)
        }.value
    }
}
#endif
