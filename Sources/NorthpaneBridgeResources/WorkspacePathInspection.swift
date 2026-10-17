import Foundation
import NorthpaneProtocol

/// Read-only inspection uses the same roots and refusal rules as referenced-file reads.
/// Root aliases supplied by the OS (for example its temporary directory) are allowed;
/// symlinks and reparse points anywhere below a root are not followed.
public enum WorkspacePathInspection {
    public static let maximumFileBytes = 32 * 1_024 * 1_024
    public static let maximumEntries = 500

    struct Location {
        let url: URL
        let root: URL
    }

    public static func problem(for error: WorkspaceFileError) -> Problem {
        let suffix: String = switch error {
        case .invalidPath: "invalid_path"
        case .outsideWorkspace: "outside_workspace"
        case .symbolicLink: "symbolic_link"
        case .notAFile: "not_a_file"
        case .notFound: "not_found"
        case .tooLarge: "too_large"
        case .notText: "not_text"
        case .secretMaterial: "secret_material"
        }
        return .init(code: "workspace_file_" + suffix, locus: .bridge, retry: .afterUserAction,
            recoveryAction: "reviewResourceAndRetry", phase: .resource)
    }

    static func resolve(path: String, cwd: String?, workspaceRoot: String?, homeDirectory: URL,
                        temporaryDirectories: [String]) throws -> Location {
        var printed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if printed.lowercased().hasPrefix("file://") { printed = String(printed.dropFirst(7)).removingPercentEncoding ?? "" }
        guard !printed.isEmpty, !printed.contains("\0"), !printed.contains("://"),
              HostPath.isWindows || !printed.contains("\\") else { throw WorkspaceFileError.invalidPath }
        printed = HostPath.normalized(printed)
        let workspace = WorkspaceFileReader.workspaceURL(workspaceRoot)
        let candidate: URL
        if HostPath.isAbsolute(printed) { candidate = URL(fileURLWithPath: printed) }
        else if printed == "~" || printed.hasPrefix("~/") {
            candidate = homeDirectory.appending(path: String(printed.dropFirst(printed == "~" ? 1 : 2)))
        } else {
            let base = cwd.flatMap { HostPath.isAbsolute(HostPath.normalized($0)) ? URL(fileURLWithPath: HostPath.normalized($0)) : nil }
            candidate = (base ?? workspace ?? homeDirectory).appending(path: printed)
        }
        let lexical = candidate.standardizedFileURL
        let resolved = lexical.resolvingSymlinksInPath().standardizedFileURL
        let roots = WorkspaceFileReader.allowedRoots(workspace: workspace, homeDirectory: homeDirectory, temporaryDirectories: temporaryDirectories)
        let containing = roots.filter { $0.url.pathComponents == resolved.pathComponents || WorkspaceFileReader.contains($0.url, resolved.pathComponents) }
        guard let root = containing.min(by: { $0.url.pathComponents.count < $1.url.pathComponents.count }) else { throw WorkspaceFileError.outsideWorkspace }
        // A configured Workspace root cannot turn a credential store into an allowed location.
        try WorkspaceFileReader.validateComponentNames(resolved.pathComponents)

        let rawRoots = ([workspace, homeDirectory] + temporaryDirectories.map { URL(fileURLWithPath: $0) }).compactMap { $0 }.map(\.standardizedFileURL)
        let lexicalRoots = rawRoots + roots.map(\.url)
        guard let lexicalRoot = lexicalRoots.filter({ $0.pathComponents == lexical.pathComponents || WorkspaceFileReader.contains($0, lexical.pathComponents) })
            .min(by: { $0.pathComponents.count < $1.pathComponents.count }) else { throw WorkspaceFileError.symbolicLink }
        let below = Array(lexical.pathComponents.dropFirst(lexicalRoot.pathComponents.count))
        try WorkspaceFileReader.validateComponentNames(below)
        var walked = lexicalRoot
        for part in below {
            walked.append(path: part)
            if HostFileMetadata.read(walked, includingDetails: false)?.isSymbolicLink == true { throw WorkspaceFileError.symbolicLink }
        }
        return Location(url: resolved, root: root.url)
    }

    public static func list(path: String, cwd: String?, workspaceRoot: String?,
                            homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
                            temporaryDirectories: [String] = WorkspaceFileReader.defaultTemporaryDirectories(),
                            limit: Int = maximumEntries) throws -> WorkspaceDirectoryListing {
        let location = try resolve(path: path, cwd: cwd, workspaceRoot: workspaceRoot, homeDirectory: homeDirectory, temporaryDirectories: temporaryDirectories)
        guard let metadata = HostFileMetadata.read(location.url, includingDetails: false) else { throw WorkspaceFileError.notFound }
        guard metadata.isDirectory else { throw WorkspaceFileError.notAFile }
        var walkError: Error?
        guard let enumerator = FileManager.default.enumerator(at: location.url, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants], errorHandler: { _, error in walkError = error; return false }) else { throw WorkspaceFileError.notFound }
        var entries: [ResourcePathHit] = [], omitted = 0, visited = 0, truncated = false
        let cap = max(1, min(limit, maximumEntries))
        for case let entry as URL in enumerator {
            visited += 1
            if entries.count >= cap || visited > maximumEntries * 4 { truncated = true; break }
            do {
                try WorkspaceFileReader.validateComponentNames(Array(entry.pathComponents.dropFirst(location.root.pathComponents.count)))
                guard let metadata = HostFileMetadata.read(entry), !metadata.isSymbolicLink,
                      metadata.isDirectory || metadata.isRegularFile else { omitted += 1; continue }
                entries.append(.init(path: entry.path, relativePath: entry.lastPathComponent, rootLabel: "",
                    isDirectory: metadata.isDirectory, byteCount: metadata.byteCount, modified: metadata.modified))
            } catch { omitted += 1 }
        }
        if walkError != nil { throw WorkspaceFileError.notFound }
        entries.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        let parent = location.url.deletingLastPathComponent()
        return .init(path: location.url.path, parentPath: location.url.pathComponents == location.root.pathComponents ? nil : parent.path,
            rootPath: location.root.path, entries: entries, omittedEntries: omitted, truncated: truncated)
    }

    static func read(path: String, cwd: String?, workspaceRoot: String?, homeDirectory: URL,
                     temporaryDirectories: [String]) throws -> (path: String, data: Data, mediaType: String) {
        let location = try resolve(path: path, cwd: cwd, workspaceRoot: workspaceRoot, homeDirectory: homeDirectory, temporaryDirectories: temporaryDirectories)
        guard let metadata = HostFileMetadata.read(location.url) else { throw WorkspaceFileError.notFound }
        guard metadata.isRegularFile else { throw WorkspaceFileError.notAFile }
        guard metadata.byteCount <= maximumFileBytes else { throw WorkspaceFileError.tooLarge }
        let handle = try FileHandle(forReadingFrom: location.url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumFileBytes {
            let part = try handle.read(upToCount: min(512 * 1_024, maximumFileBytes + 1 - data.count)) ?? Data()
            if part.isEmpty { break }
            data.append(part)
        }
        guard data.count <= maximumFileBytes else { throw WorkspaceFileError.tooLarge }
        // Check the whole download, including binary files with embedded recognizable secrets.
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + 900_000)
            if WorkspaceFileReader.containsSecret(text: String(decoding: data[offset..<end], as: UTF8.self)) { throw WorkspaceFileError.secretMaterial }
            if end == data.count { break }
            offset = end - 256
        }
        return (location.url.path, data, WorkspaceFileReader.mediaType(for: location.url.path))
    }
}

/// One instance per Bridge session. Chunks refer to a bounded immutable copy, never a file that
/// can change between requests. Handles cannot be used by another session or for another path.
public actor WorkspaceFileDownloads {
    private struct Key: Equatable {
        let path: String
        let pane: String
        let workspace: String
        let incarnation: String
    }
    private struct Snapshot {
        let key: Key
        let path: String
        let data: Data
        let mediaType: String
        let isText: Bool
        let expires: Date
    }
    private var snapshots: [UUID: Snapshot] = [:]

    public init() {}

    public func chunk(_ command: ResourceCommand, cwd: String?, workspaceRoot: String?, incarnation: String,
                      homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
                      temporaryDirectories: [String] = WorkspaceFileReader.defaultTemporaryDirectories(),
                      now: Date = Date()) throws -> ResourceResult {
        let length = command.length == 0 ? 768 * 1_024 : command.length
        guard command.offset >= 0, length > 0, length <= 768 * 1_024 else { throw Problem.malformedFrame }
        snapshots = snapshots.filter { $0.value.expires > now }
        let key = Key(path: command.path, pane: command.paneID, workspace: command.workspaceID, incarnation: incarnation)
        if command.method == "DELETE", let handle = command.streamID {
            if let existing = snapshots[handle], existing.key != key { throw Problem.unauthorized }
            snapshots.removeValue(forKey: handle)
            return .init(commandID: command.commandID, isFinal: true)
        }
        let id: UUID
        let snapshot: Snapshot
        if let handle = command.streamID {
            guard let existing = snapshots[handle], existing.key == key else { throw Self.problem("workspace_download_expired") }
            id = handle; snapshot = existing
        } else {
            guard command.offset == 0 else { throw Problem.malformedFrame }
            guard snapshots.count < 2 else { throw Self.problem("workspace_download_busy") }
            let file = try WorkspacePathInspection.read(path: command.path, cwd: cwd, workspaceRoot: workspaceRoot,
                homeDirectory: homeDirectory, temporaryDirectories: temporaryDirectories)
            id = UUID()
            snapshot = Snapshot(key: key, path: file.path, data: file.data, mediaType: file.mediaType,
                isText: String(data: file.data, encoding: .utf8).map { !$0.contains("\0") } ?? false, expires: now.addingTimeInterval(120))
            snapshots[id] = snapshot
        }
        guard command.offset <= snapshot.data.count else { throw Problem.malformedFrame }
        let end = min(snapshot.data.count, command.offset + length)
        let final = end == snapshot.data.count
        if final { snapshots.removeValue(forKey: id) }
        return .init(commandID: command.commandID, body: Data(snapshot.data[command.offset..<end]), relativePath: snapshot.path,
            mediaType: snapshot.mediaType, totalBytes: snapshot.data.count, streamID: id, isFinal: final,
            isText: snapshot.isText)
    }

    private static func problem(_ code: String) -> Problem {
        .init(code: code, locus: .bridge, retry: .afterUserAction, recoveryAction: "retryDownload", phase: .resource)
    }
}
