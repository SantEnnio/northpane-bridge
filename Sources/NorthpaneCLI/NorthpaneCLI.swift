import Foundation
import NorthpaneConnection
import NorthpaneProtocol

@main
struct NorthpaneCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "mcp" {
                try await MCPServer().run()
            } else {
                let result = try await CommandRunner().run(arguments)
                FileHandle.standardOutput.write(result)
                if !result.isEmpty, result.last != 0x0A { FileHandle.standardOutput.write(Data("\n".utf8)) }
            }
        } catch let error as CLIError {
            FileHandle.standardError.write(Data("northpane: \(error.message)\n".utf8))
            Foundation.exit(error.exitCode)
        } catch {
            FileHandle.standardError.write(Data("northpane: operation failed\n".utf8))
            Foundation.exit(4)
        }
    }
}

private struct CommandRunner {
    func run(_ arguments: [String]) async throws -> Data {
        if arguments.isEmpty || arguments == ["help"] || arguments == ["--help"] || arguments == ["-h"] {
            return Data((CLIError.usage.message + "\n").utf8)
        }
        if arguments == ["version"] || arguments == ["--version"] {
            return Data("northpane \(NorthpaneRelease.version)\n".utf8)
        }
        let connection = try await LocalBridgeConnection.open()
        defer { Task { await connection.close() } }
        let client = connection.client
        _ = try await client.handshake(clientVersion: "northpane-cli/\(NorthpaneRelease.version)")
        if Array(arguments.prefix(2)) == ["auth", "github"] {
            return try await runGitHubAuthorization(arguments, client: client)
        }
        let snapshot = try await client.observe()
        let command = try makeCommand(arguments, snapshot: snapshot)
        let result = try await client.performResourceCommand(command)
        if arguments.contains("--output"), command.kind == .readArtifact {
            guard let index = arguments.firstIndex(of: "--output"), arguments.indices.contains(index + 1) else { throw CLIError.usage }
            try result.body.write(to: URL(fileURLWithPath: arguments[index + 1]), options: .atomic)
            return Data("written \(result.body.count) bytes\n".utf8)
        }
        let resourceKind: ResourceKind? = Array(arguments.prefix(2)) == ["preview", "list"] ? .preview
            : (Array(arguments.prefix(2)) == ["artifact", "list"] ? .artifact : nil)
        return try output(result, json: arguments.contains("--json"), resourceKind: resourceKind)
    }

    private func runGitHubAuthorization(_ arguments: [String], client: NorthpaneBridgeClient) async throws -> Data {
        let scopes = (optionalValue("--scopes", in: arguments) ?? "gist,read:org,repo")
            .split(separator: ",").map(String.init)
        let created = try await client.performAuthorizationCommand(.init(kind: .create, scopes: scopes, provenance: "northpane-cli"))
        guard let request = created.requests.first else { throw CLIError.connection }
        FileHandle.standardError.write(Data("northpane: authorization \(request.id.uuidString) is waiting for strong confirmation in the Northpane app\n".utf8))
        var lastRevision = request.revision
        while true {
            try await Task.sleep(for: .seconds(1))
            let status = try await client.performAuthorizationCommand(.init(kind: .status, requestID: request.id))
            guard let current = status.requests.first else { throw CLIError.connection }
            if current.revision != lastRevision, !current.userCode.isEmpty {
                FileHandle.standardError.write(Data("northpane: enter code \(current.userCode) at \(current.verificationURL?.absoluteString ?? "https://github.com/login/device")\n".utf8))
                lastRevision = current.revision
            }
            if [.completed, .cancelled, .expired, .failed].contains(current.state) {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                let output = try encoder.encode(current)
                if current.state != .completed { throw CLIError.authorization(String(decoding: output, as: UTF8.self)) }
                return arguments.contains("--json") ? output : Data("GitHub CLI authenticated as \(current.account)\n".utf8)
            }
        }
    }

    private func makeCommand(_ arguments: [String], snapshot: WireRuntimeSnapshot) throws -> ResourceCommand {
        let root = Array(arguments.prefix(2))
        if arguments[0] == "status" || root == ["preview", "status"] || root == ["preview", "list"] || root == ["artifact", "list"] {
            return .init(kind: .listResources)
        }
        if root == ["preview", "server"] {
            let origin = try value("--origin", in: arguments)
            let workspace = try workspaceID(in: arguments, snapshot: snapshot)
            return .init(kind: .registerPreview, workspaceID: workspace, origin: origin,
                         title: optionalValue("--title", in: arguments) ?? "",
                         healthPath: optionalValue("--health", in: arguments) ?? "/",
                         ttlSeconds: integer("--ttl", in: arguments) ?? 0,
                         idempotencyKey: optionalValue("--idempotency-key", in: arguments) ?? UUID().uuidString,
                         paneID: optionalValue("--pane", in: arguments) ?? "")
        }
        if root == ["preview", "close"] {
            guard arguments.count >= 3, let id = UUID(uuidString: arguments[2]) else { throw CLIError.usage }
            return .init(kind: .closePreview, resourceID: id, expectedRevision: try requiredInteger("--revision", in: arguments))
        }
        if root == ["artifact", "publish"] {
            guard arguments.count >= 3 else { throw CLIError.usage }
            let workspace = try workspaceID(in: arguments, snapshot: snapshot)
            guard let record = snapshot.workspaces.first(where: { $0.id == workspace }), let rootPath = record.worktreePath else { throw CLIError.workspace }
            let source = URL(fileURLWithPath: arguments[2], relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
            let base = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
            guard source.path.hasPrefix(base.path + "/") else { throw CLIError.workspace }
            let relative = String(source.path.dropFirst(base.path.count + 1))
            return .init(kind: .publishArtifact, workspaceID: workspace, path: relative,
                         ttlSeconds: integer("--ttl", in: arguments) ?? 0,
                         mediaType: optionalValue("--media-type", in: arguments) ?? Self.mediaType(for: source),
                         idempotencyKey: optionalValue("--idempotency-key", in: arguments) ?? UUID().uuidString)
        }
        if root == ["artifact", "read"] {
            guard arguments.count >= 3, let id = UUID(uuidString: arguments[2]) else { throw CLIError.usage }
            return .init(kind: .readArtifact, resourceID: id, path: optionalValue("--path", in: arguments) ?? "", offset: integer("--offset", in: arguments) ?? 0, length: integer("--length", in: arguments) ?? 768 * 1_024)
        }
        if root == ["artifact", "delete"] {
            guard arguments.count >= 3, let id = UUID(uuidString: arguments[2]) else { throw CLIError.usage }
            return .init(kind: .deleteArtifact, resourceID: id, expectedRevision: try requiredInteger("--revision", in: arguments))
        }
        throw CLIError.usage
    }

    private func workspaceID(in arguments: [String], snapshot: WireRuntimeSnapshot) throws -> String {
        if let explicit = optionalValue("--workspace", in: arguments), snapshot.workspaces.contains(where: { $0.id == explicit }) { return explicit }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path
        let matches = snapshot.workspaces.compactMap { workspace -> (String, Int)? in
            guard let root = workspace.worktreePath, cwd == root || cwd.hasPrefix(root + "/") else { return nil }
            return (workspace.id, root.count)
        }.sorted { $0.1 > $1.1 }
        guard let match = matches.first else { throw CLIError.workspace }
        return match.0
    }

    private func output(_ result: ResourceResult, json: Bool, resourceKind: ResourceKind?) throws -> Data {
        let filtered = resourceKind.map { kind in result.resources.filter { $0.kind == kind } } ?? result.resources
        if json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(ResourceOutput(result: result, resources: filtered))
        }
        if result.deleted { return Data("deleted\n".utf8) }
        if !result.body.isEmpty { return result.body }
        if !filtered.isEmpty {
            return Data(filtered.map { "\($0.kind.rawValue)\t\($0.resourceID.uuidString)\trev \($0.revision)\t\($0.title)" }.joined(separator: "\n").utf8)
        }
        return Data("ok\n".utf8)
    }

    private func value(_ flag: String, in arguments: [String]) throws -> String {
        guard let value = optionalValue(flag, in: arguments) else { throw CLIError.usage }
        return value
    }
    private func optionalValue(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    private func integer(_ flag: String, in arguments: [String]) -> Int? { optionalValue(flag, in: arguments).flatMap(Int.init) }
    private func requiredInteger(_ flag: String, in arguments: [String]) throws -> Int {
        guard let number = integer(flag, in: arguments) else { throw CLIError.usage }
        return number
    }
    private static func mediaType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": "text/html"
        case "pdf": "application/pdf"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "svg": "image/svg+xml"
        case "md", "markdown": "text/markdown"
        case "json": "application/json"
        default: "application/octet-stream"
        }
    }
}

private struct ResourceOutput: Codable {
    let commandID: UUID
    let resources: [ResourceDescriptor]
    let statusCode: Int
    let deleted: Bool
    let relativePath: String
    let mediaType: String
    let totalBytes: Int
    init(result: ResourceResult, resources: [ResourceDescriptor]) {
        commandID = result.commandID; self.resources = resources; statusCode = result.statusCode
        deleted = result.deleted; relativePath = result.relativePath; mediaType = result.mediaType; totalBytes = result.totalBytes
    }
}

private final class LocalBridgeConnection: @unchecked Sendable {
    let client: NorthpaneBridgeClient
    private let process: Process?
    private init(client: NorthpaneBridgeClient, process: Process?) { self.client = client; self.process = process }

    static func open() async throws -> LocalBridgeConnection {
        #if os(macOS)
        let state = ProcessInfo.processInfo.environment["NORTHPANE_STATE_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".northpane", directoryHint: .isDirectory)
        let socket = ProcessInfo.processInfo.environment["NORTHPANE_BRIDGE_SOCKET"] ?? state.appending(path: "bridge.sock").path
        if let transport = try? UnixSocketBridgeTransport(path: socket) { return .init(client: .init(transport: transport), process: nil) }
        let candidates = [
            ProcessInfo.processInfo.environment["NORTHPANE_BRIDGE_EXECUTABLE"],
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: "northpane-bridge").path,
            FileManager.default.currentDirectoryPath + "/.build/debug/northpane-bridge",
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/northpane-bridge").path,
            "/usr/local/bin/northpane-bridge", "/opt/homebrew/bin/northpane-bridge",
        ].compactMap { $0 }
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { throw CLIError.connection }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = ["serve", "--socket", socket]
        var environment = ProcessInfo.processInfo.environment; environment["NORTHPANE_STATE_DIRECTORY"] = state.path; process.environment = environment
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<100 {
            if let transport = try? UnixSocketBridgeTransport(path: socket) { return .init(client: .init(transport: transport), process: process) }
            try await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning { process.terminate() }
        throw CLIError.connection
        #elseif os(Linux) || os(Windows)
        #if os(Windows)
        let executableName = "northpane-bridge.exe"
        #else
        let executableName = "northpane-bridge"
        #endif
        let candidates = [
            ProcessInfo.processInfo.environment["NORTHPANE_BRIDGE_EXECUTABLE"],
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: executableName).path,
            FileManager.default.currentDirectoryPath + "/.build/debug/\(executableName)",
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/\(executableName)").path,
            "/usr/local/bin/northpane-bridge",
        ].compactMap { $0 }
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { throw CLIError.connection }
        let transport = try ProcessBridgeTransport(kind: .localIPC, executableURL: URL(fileURLWithPath: executable), arguments: ["serve", "--local-stdio"])
        return .init(client: .init(transport: transport), process: nil)
        #else
        throw CLIError.connection
        #endif
    }

    func close() async {
        await client.close()
        if process?.isRunning == true { process?.terminate() }
    }
}

private struct MCPServer {
    func run() async throws {
        while let line = readLine() {
            guard let data = line.data(using: .utf8), let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = request["id"] else { continue }
            let method = request["method"] as? String
            if method == "initialize" {
                write(id: id, result: ["protocolVersion": "2025-06-18", "capabilities": ["tools": [:]], "serverInfo": ["name": "northpane", "version": "1"]])
            } else if method == "tools/list" {
                write(id: id, result: ["tools": Self.tools])
            } else if method == "tools/call", let params = request["params"] as? [String: Any], let name = params["name"] as? String {
                do {
                    let args = params["arguments"] as? [String: Any] ?? [:]
                    let output = try await CommandRunner().run(try Self.arguments(for: name, values: args) + ["--json"])
                    write(id: id, result: ["content": [["type": "text", "text": String(decoding: output, as: UTF8.self)]], "isError": false])
                } catch {
                    write(id: id, result: ["content": [["type": "text", "text": "Northpane operation failed"]], "isError": true])
                }
            } else if id as? String != nil || id as? NSNumber != nil {
                write(id: id, error: ["code": -32601, "message": "Method not found"])
            }
        }
    }

    private static var tools: [[String: Any]] {
        [
            tool("preview_status", "Check Bridge and viewer availability", [:]),
            tool("preview_server", "Register a loopback Preview", ["origin": ["type": "string"], "workspace": ["type": "string"], "title": ["type": "string"]], required: ["origin"]),
            tool("publish_artifact", "Publish a file or directory inside a worktree", ["path": ["type": "string"], "workspace": ["type": "string"], "media_type": ["type": "string"]], required: ["path"]),
            tool("list_previews", "List active Preview resources", [:]),
            tool("list_artifacts", "List active Artifact resources", [:]),
            tool("close_preview", "Close a Preview by id and revision", ["id": ["type": "string"], "revision": ["type": "integer"]], required: ["id", "revision"]),
            tool("read_artifact", "Read a bounded Artifact chunk", ["id": ["type": "string"], "path": ["type": "string"]], required: ["id"]),
            tool("delete_artifact", "Delete an Artifact by id and revision", ["id": ["type": "string"], "revision": ["type": "integer"]], required: ["id", "revision"]),
        ]
    }
    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }
    private static func arguments(for tool: String, values: [String: Any]) throws -> [String] {
        func required(_ key: String) throws -> String { guard let value = values[key] else { throw CLIError.usage }; return String(describing: value) }
        func option(_ key: String, _ flag: String) -> [String] { values[key].map { [flag, String(describing: $0)] } ?? [] }
        switch tool {
        case "preview_status": return ["preview", "status"]
        case "list_previews": return ["preview", "list"]
        case "list_artifacts": return ["artifact", "list"]
        case "preview_server": return ["preview", "server", "--origin", try required("origin")] + option("workspace", "--workspace") + option("title", "--title")
        case "publish_artifact": return ["artifact", "publish", try required("path")] + option("workspace", "--workspace") + option("media_type", "--media-type")
        case "close_preview": return ["preview", "close", try required("id"), "--revision", try required("revision")]
        case "read_artifact": return ["artifact", "read", try required("id")] + option("path", "--path")
        case "delete_artifact": return ["artifact", "delete", try required("id"), "--revision", try required("revision")]
        default: throw CLIError.usage
        }
    }
    private func write(id: Any, result: Any? = nil, error: Any? = nil) {
        var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let result { response["result"] = result }
        if let error { response["error"] = error }
        guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private enum CLIError: Error {
    case usage, connection, workspace, authorization(String)
    var exitCode: Int32 { switch self { case .usage: 2; case .connection: 3; case .workspace, .authorization: 4 } }
    var message: String {
        switch self {
        case .usage: "usage: northpane status | preview status|server|list|close | artifact publish|list|read|delete | auth github | mcp [--json]"
        case .connection: "Northpane Bridge is unavailable"
        case .workspace: "the path must belong to a current Herdr worktree (or pass --workspace)"
        case let .authorization(detail): "GitHub authorization did not complete: \(detail)"
        }
    }
}
