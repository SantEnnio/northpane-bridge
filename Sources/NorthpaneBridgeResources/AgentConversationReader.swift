import Foundation
import NorthpaneProtocol
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Host-local, bounded readers. A connection grants terminalControl before calling this:
/// conversation contents can include files and tool output, not just runtime metadata.
public enum AgentConversationReader {
    public static func read(_ request: AgentConversationRequest, directory: String) async -> AgentConversationReading {
        #if os(macOS) || os(Linux)
        guard await ConversationReadGate.shared.acquire() else {
            return .init(agent: request.agent, sessionID: request.sessionID, problem: .sourceUnavailable)
        }
        let result = await readAvailable(request, directory: directory)
        await ConversationReadGate.shared.release()
        return result
        #else
        return .init(agent: request.agent, sessionID: request.sessionID, problem: .unsupportedVersion)
        #endif
    }

    #if os(macOS) || os(Linux)
    private static func readAvailable(_ request: AgentConversationRequest, directory: String) async -> AgentConversationReading {
        do {
            var reading: AgentConversationReading
            switch request.agent {
            case .codex: reading = try await Task.detached { try codex(request, directory: directory) }.value
            case .claude: reading = try await Task.detached { try claude(request, directory: directory) }.value
            case .opencode: reading = try await openCode(request, directory: directory)
            }
            reading.sessionID = request.sessionID
            return bounded(reading)
        } catch let failure as CodexObservationSocket.Failure {
            let problem: AgentConversationReading.Problem
            switch failure {
            case .unavailable: problem = .sourceUnavailable
            case .unsupported: problem = .unsupportedVersion
            case .unreadable: problem = .unreadable
            case .tooLarge: problem = .outputTooLarge
            case .unauthorized: problem = .unauthorized
            }
            return .init(agent: request.agent, sessionID: request.sessionID, problem: problem)
        } catch { return .init(agent: request.agent, sessionID: request.sessionID, problem: .sourceUnavailable) }
    }
    #endif

    /// Bound the *encoded* body as well as individual blocks. Newest items survive a large
    /// history; IDs never depend on clipped content and diff counts use the original diff.
    static func bounded(_ original: AgentConversationReading) -> AgentConversationReading {
        var result = original
        var seen = Set<String>()
        result.items = result.items.filter { seen.insert($0.id).inserted }
        guard result.sessionID.utf8.count <= 512,
              result.sessions.allSatisfy({ $0.id.utf8.count <= 512 }),
              result.items.allSatisfy({ $0.id.utf8.count <= 512 && $0.turnID.utf8.count <= 512 }) else {
            return .init(agent: result.agent, sessionID: result.sessionID, problem: .outputTooLarge)
        }
        result.source = String(result.source.prefix(512))
        result.version = String(result.version.prefix(128))
        result.sessions = result.sessions.prefix(50).map {
            .init(id: $0.id, title: String($0.title.prefix(512)), directory: String($0.directory.prefix(4096)), loaded: $0.loaded)
        }
        var kept: [AgentConversationItem] = []
        var budget = 600 * 1_024
        for item in result.items.reversed() {
            let text = String(item.text.prefix(24_000))
            if text != item.text { result.truncated = true }
            let clipped = AgentConversationItem(id: item.id, turnID: item.turnID, kind: item.kind, title: String(item.title.prefix(512)),
                         text: text, status: String(item.status.prefix(128)), added: item.added, removed: item.removed)
            let size = (try? JSONEncoder().encode(clipped).count) ?? budget + 1
            guard size <= budget, kept.count < 2_000 else { result.truncated = true; break }
            budget -= size; kept.append(clipped)
        }
        result.items = kept.reversed()
        // Session metadata and JSON escaping also count towards the transport limit.
        if ((try? JSONEncoder().encode(result).count) ?? Int.max) > 768 * 1_024 {
            return .init(agent: result.agent, sessionID: result.sessionID, problem: .outputTooLarge)
        }
        return result
    }

    public static func codexItems(turns: [[String: Any]]) -> [AgentConversationItem] {
        turns.flatMap { turn -> [AgentConversationItem] in
            let turnID = turn["id"] as? String ?? ""
            return (turn["items"] as? [[String: Any]] ?? []).flatMap { item -> [AgentConversationItem] in
                guard let id = item["id"] as? String, let type = item["type"] as? String else { return [] }
                let status = item["status"] as? String ?? turn["status"] as? String ?? ""
                switch type {
                case "userMessage":
                    let blocks = item["content"] as? [[String: Any]] ?? []
                    let text = blocks.map { block in (block["text"] as? String) ?? "[\(block["type"] as? String ?? "attachment")]" }.joined(separator: "\n\n")
                    return [.init(id: id, turnID: turnID, kind: .user, text: text)]
                case "agentMessage", "plan":
                    return [.init(id: id, turnID: turnID, kind: .assistant, text: item["text"] as? String ?? "", status: status)]
                case "fileChange":
                    return (item["changes"] as? [[String: Any]] ?? []).enumerated().map { index, change in
                        let diff = change["diff"] as? String ?? ""
                        let counts = unifiedDiffCounts(diff)
                        return .init(id: "\(id):\(index)", turnID: turnID, kind: .fileChange,
                            title: change["path"] as? String ?? "", text: diff, status: status,
                            added: counts?.added, removed: counts?.removed)
                    }
                case "commandExecution":
                    return [.init(id: id, turnID: turnID, kind: .activity, title: item["command"] as? String ?? type,
                                  text: item["aggregatedOutput"] as? String ?? "", status: status)]
                case "reasoning":
                    // Only the summary offered by the source, never private chain of thought.
                    let summary = (item["summary"] as? [String] ?? []).joined(separator: "\n\n")
                    return summary.isEmpty ? [] : [.init(id: id, turnID: turnID, kind: .activity, title: type, text: summary)]
                case "contextCompaction":
                    return [.init(id: id, turnID: turnID, kind: .notice, title: type, text: "")]
                default:
                    return [.init(id: id, turnID: turnID, kind: .activity, title: item["tool"] as? String ?? type,
                                  text: jsonText(item["result"] ?? item["arguments"] ?? item["query"] ?? ""), status: status)]
                }
            }
        }
    }

    /// Some sources return the full file for an add/delete rather than a unified patch.
    /// In that case no line count is asserted. Within a hunk, +++/--- are content too.
    static func unifiedDiffCounts(_ diff: String) -> (added: Int, removed: Int)? {
        var inHunk = false
        var added = 0
        var removed = 0
        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("@@ ") { inHunk = true; continue }
            if line.hasPrefix("diff --git ") { inHunk = false; continue }
            guard inHunk else { continue }
            if line.hasPrefix("+") { added += 1 }
            if line.hasPrefix("-") { removed += 1 }
        }
        return diff.components(separatedBy: "\n").contains(where: { $0.hasPrefix("@@ ") }) ? (added, removed) : nil
    }

    static func jsonText(_ value: Any) -> String {
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value), let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    #if os(macOS) || os(Linux)
    private static func executable(_ name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return dirs.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    private static func codex(_ request: AgentConversationRequest, directory: String) throws -> AgentConversationReading {
        guard request.endpoint.isEmpty || (request.endpoint.hasPrefix("/") && request.endpoint.utf8.count < 108) else {
            return .init(agent: .codex, problem: .invalidEndpoint)
        }
        guard let executable = executable("codex") else { throw CodexObservationSocket.Failure.unavailable }
        let socket = try CodexObservationSocket(executable: executable, endpoint: request.endpoint)
        let loaded = try socket.call("thread/loaded/list")
        let ids = Set(loaded["data"] as? [String] ?? [])
        if request.sessionID.isEmpty {
            var parameters: [String: Any] = ["limit": 50, "sortKey": "updated_at"]
            if !directory.isEmpty { parameters["cwd"] = directory }
            let page = try socket.call("thread/list", parameters)
            let sessions = (page["data"] as? [[String: Any]] ?? []).compactMap { thread -> AgentConversationSession? in
                guard let id = thread["id"] as? String else { return nil }
                return .init(id: id, title: thread["name"] as? String ?? thread["preview"] as? String ?? id,
                             directory: thread["cwd"] as? String ?? "", loaded: ids.contains(id))
            }
            return .init(agent: .codex, source: "Codex App Server", sessions: sessions, hasOlder: page["nextCursor"] is String)
        }
        // A stored thread in another executor is not an attach to the Pane's current task.
        guard ids.contains(request.sessionID) else { return .init(agent: .codex, sessionID: request.sessionID, problem: .sessionNotLoaded) }
        let metadata = try socket.call("thread/read", ["threadId": request.sessionID, "includeTurns": false])
        guard let thread = metadata["thread"] as? [String: Any], thread["id"] as? String == request.sessionID,
              ["legacy", "paginated"].contains(thread["historyMode"] as? String ?? "legacy") else { throw CodexObservationSocket.Failure.unsupported }
        let page = try socket.call("thread/turns/list", ["threadId": request.sessionID, "limit": min(20, max(1, request.limit)), "sortDirection": "desc", "itemsView": "full"])
        guard let turns = page["data"] as? [[String: Any]], turns.allSatisfy({ ($0["itemsView"] as? String ?? "full") == "full" }) else { throw CodexObservationSocket.Failure.unreadable }
        return .init(agent: .codex, sessionID: request.sessionID, source: "Codex App Server · \(thread["historyMode"] as? String ?? "legacy")",
                     version: thread["cliVersion"] as? String ?? "", items: codexItems(turns: Array(turns.reversed())), hasOlder: page["nextCursor"] is String)
    }

    private static func claude(_ request: AgentConversationRequest, directory: String) throws -> AgentConversationReading {
        guard let node = executable("node") else { return .init(agent: .claude, problem: .sdkMissing) }
        // An explicitly installed Host integration, never resolution against the Workspace's
        // node_modules. Loading an arbitrary project's package would execute its code.
        let module = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".northpane/integrations/claude-reader/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs").path
        guard FileManager.default.fileExists(atPath: module) else { return .init(agent: .claude, problem: .sdkMissing) }
        let metadata = URL(fileURLWithPath: module).deletingLastPathComponent().appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: metadata), let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              package["version"] as? String == "0.3.293" else { return .init(agent: .claude, problem: .unsupportedVersion) }
        guard request.sessionID.isEmpty || UUID(uuidString: request.sessionID) != nil else { return .init(agent: .claude, problem: .unreadable) }

        let script = #"""
        const [module, directory, id, limit] = process.argv.slice(1);
        const {listSessions, getSessionMessages, getSessionInfo} = await import(module);
        if (!id) console.log(JSON.stringify({sessions: await listSessions({dir: directory, limit: 50})}));
        else {
          const info = await getSessionInfo(id, {dir: directory});
          if (!info) console.log(JSON.stringify({problem: "unreadable"}));
          else if (info.fileSize > 16 * 1024 * 1024) console.log(JSON.stringify({problem: "outputTooLarge"}));
          else {
            const messages = await getSessionMessages(id, {dir: directory, includeSystemMessages: true});
            console.log(JSON.stringify({messages: messages.slice(-Number(limit)), hasOlder: messages.length > Number(limit)}));
          }
        }
        """#
        let pipe = try AgentCLIConversation(executable: node, arguments: ["--max-old-space-size=128", "--input-type=module", "-e", script, module, directory, request.sessionID, String(min(20, max(2, request.limit)) * 10)], timeout: 12)
        defer { pipe.finish() }
        guard let line = pipe.nextLine(), let result = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { return .init(agent: .claude, problem: .unreadable) }
        if let code = result["problem"] as? String, let problem = AgentConversationReading.Problem(rawValue: code) { return .init(agent: .claude, problem: problem) }
        let sessions = (result["sessions"] as? [[String: Any]] ?? []).compactMap { session -> AgentConversationSession? in
            guard let id = session["sessionId"] as? String else { return nil }
            return .init(id: id, title: session["customTitle"] as? String ?? session["summary"] as? String ?? id,
                         directory: session["cwd"] as? String ?? directory, loaded: true)
        }
        let messages = result["messages"] as? [[String: Any]] ?? []
        return .init(agent: .claude, sessionID: request.sessionID, source: "Claude Agent SDK · transcript", version: "0.3.293", sessions: sessions,
                     items: claudeItems(messages: messages), hasOlder: result["hasOlder"] as? Bool ?? false)
    }
    #endif

    public static func claudeItems(messages: [[String: Any]]) -> [AgentConversationItem] {
        messages.flatMap { entry -> [AgentConversationItem] in
            guard let id = entry["uuid"] as? String, let message = entry["message"] as? [String: Any] else { return [] }
            if entry["type"] as? String == "system" {
                return [.init(id: id, turnID: id, kind: .notice, title: message["subtype"] as? String ?? "system", text: message["content"] as? String ?? "")]
            }
            let user = (entry["type"] as? String ?? message["role"] as? String) == "user"
            let content = message["content"]
            if let text = content as? String { return [.init(id: id, turnID: id, kind: user ? .user : .assistant, text: text)] }
            return (content as? [[String: Any]] ?? []).enumerated().compactMap { index, block in
                let type = block["type"] as? String ?? ""
                if type == "thinking" { return nil }
                if type == "text" { return .init(id: "\(id):\(index)", turnID: id, kind: user ? .user : .assistant, text: block["text"] as? String ?? "") }
                return .init(id: "\(id):\(index)", turnID: id, kind: .activity, title: block["name"] as? String ?? type,
                             text: jsonText(block["input"] ?? block["content"] ?? ""), status: block["is_error"] as? Bool == true ? "error" : "")
            }
        }
    }

    #if os(macOS) || os(Linux)
    private static func openCode(_ request: AgentConversationRequest, directory: String) async throws -> AgentConversationReading {
        guard let origin = URL(string: request.endpoint), origin.scheme == "http",
              ["127.0.0.1", "[::1]", "::1"].contains(origin.host ?? ""), origin.port != nil,
              origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              origin.path.isEmpty || origin.path == "/" else { return .init(agent: .opencode, problem: .invalidEndpoint) }
        func get(_ path: String, query: [URLQueryItem] = []) async throws -> Any {
            var components = URLComponents(url: origin.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            components.queryItems = query
            var call = URLRequest(url: components.url!); call.httpMethod = "GET"
            if let password = ProcessInfo.processInfo.environment["OPENCODE_SERVER_PASSWORD"], !password.isEmpty {
                let user = ProcessInfo.processInfo.environment["OPENCODE_SERVER_USERNAME"] ?? "opencode"
                call.setValue("Basic " + Data("\(user):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            }
            let data = try await ConversationHTTPFetch.read(call)
            return try JSONSerialization.jsonObject(with: data)
        }
        guard let health = try await get("global/health") as? [String: Any], health["healthy"] as? Bool == true,
              let version = health["version"] as? String, version.hasPrefix("1.18.") else {
            return .init(agent: .opencode, problem: .unsupportedVersion)
        }
        let scope = directory.isEmpty ? [] : [URLQueryItem(name: "directory", value: directory)]
        if request.sessionID.isEmpty {
            guard let rows = try await get("session", query: scope) as? [[String: Any]] else { throw CodexObservationSocket.Failure.unreadable }
            let sessions = rows.prefix(50).compactMap { row -> AgentConversationSession? in
                guard let id = row["id"] as? String else { return nil }
                return .init(id: id, title: row["title"] as? String ?? id, directory: row["directory"] as? String ?? "", loaded: true)
            }
            return .init(agent: .opencode, source: "OpenCode server · V1", version: version, sessions: sessions, hasOlder: rows.count > 50)
        }
        guard request.sessionID.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else { throw CodexObservationSocket.Failure.unreadable }
        guard let rows = try await get("session/\(request.sessionID)/message", query: scope + [URLQueryItem(name: "limit", value: String(min(20, max(2, request.limit)) * 10))]) as? [[String: Any]] else { throw CodexObservationSocket.Failure.unreadable }
        return .init(agent: .opencode, sessionID: request.sessionID, source: "OpenCode server · V1", version: version,
                     items: openCodeItems(messages: rows), hasOlder: rows.count >= min(200, max(20, request.limit * 10)))
    }
    #endif

    public static func openCodeItems(messages: [[String: Any]]) -> [AgentConversationItem] {
        messages.flatMap { row -> [AgentConversationItem] in
            guard let info = row["info"] as? [String: Any], let id = info["id"] as? String else { return [] }
            return (row["parts"] as? [[String: Any]] ?? []).compactMap { part -> AgentConversationItem? in
                guard let partID = part["id"] as? String, let type = part["type"] as? String else { return nil }
                if type == "reasoning" { return nil }
                if type == "text" { return .init(id: partID, turnID: id, kind: info["role"] as? String == "user" ? .user : .assistant, text: part["text"] as? String ?? "") }
                if type == "tool" {
                    let state = part["state"] as? [String: Any] ?? [:]
                    return .init(id: partID, turnID: id, kind: .activity, title: part["tool"] as? String ?? type,
                        text: jsonText(state["output"] ?? state["error"] ?? state["input"] ?? ""), status: state["status"] as? String ?? "")
                }
                return .init(id: partID, turnID: id, kind: .notice, title: type, text: part["filename"] as? String ?? "")
            }
        }
    }
}

#if os(macOS) || os(Linux)
private actor ConversationReadGate {
    static let shared = ConversationReadGate()
    private var count = 0
    func acquire() -> Bool { guard count < 2 else { return false }; count += 1; return true }
    func release() { count -= 1 }
}

/// A serial delegate bounds bytes before buffering, including on swift-corelibs Foundation.
private final class ConversationHTTPFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Data, any Error>?
    private var body = Data()
    private var failure: (any Error)?
    private var session: URLSession?
    static func read(_ request: URLRequest) async throws -> Data {
        let reader = ConversationHTTPFetch()
        return try await withCheckedThrowingContinuation { continuation in
            reader.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 12
            reader.session = URLSession(configuration: configuration, delegate: reader, delegateQueue: nil)
            reader.session?.dataTask(with: request).resume()
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let response = response as? HTTPURLResponse, [401, 403].contains(response.statusCode) {
            failure = CodexObservationSocket.Failure.unauthorized; completionHandler(.cancel); return
        }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            failure = CodexObservationSocket.Failure.unavailable; completionHandler(.cancel); return
        }
        guard response.expectedContentLength <= 8 * 1_024 * 1_024 else {
            failure = CodexObservationSocket.Failure.tooLarge; completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count + data.count <= 8 * 1_024 * 1_024 else {
            failure = CodexObservationSocket.Failure.tooLarge; dataTask.cancel(); return
        }
        body.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error = failure ?? error { continuation?.resume(throwing: error) }
        else { continuation?.resume(returning: body) }
        continuation = nil; self.session = nil; session.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
#endif
