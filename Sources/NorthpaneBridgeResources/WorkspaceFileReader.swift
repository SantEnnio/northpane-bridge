import Foundation

public enum WorkspaceFileError: Error, Equatable, Sendable {
    case invalidPath, outsideWorkspace, symbolicLink, notAFile, notFound, tooLarge, notText, secretMaterial
}

/// One confined, read-only look at a file an agent referenced in the terminal.
///
/// The path is taken as printed (absolute, `~`-prefixed, or relative to the pane's working
/// directory) and resolved on the Host. It is served only when the real file lies inside one
/// of the allowed roots (the workspace root, the Host user's home directory, or the user's
/// temporary directories, where agents drop their artifacts), is a regular file reached
/// without any symbolic link, is small enough for its kind, and carries no secret material by
/// the same rules Artifact publication applies. Text, Markdown, HTML, images and PDF are
/// served; anything else is refused. Nothing is ever written, and there is no way past the
/// roots. `WorkspacePathSearch` searches these same roots by name; it shares the roots, the
/// refused-name rules and the symbolic-link refusal defined here.
public enum WorkspaceFileReader {
    public struct File: Equatable, Sendable {
        /// Path relative to the root that contained the file.
        public let relativePath: String
        public let mediaType: String
        public let isText: Bool
        public let data: Data
    }

    public static let maximumTextBytes = 512 * 1_024
    public static let maximumHTMLBytes = 2 * 1_024 * 1_024
    public static let maximumImageBytes = 8 * 1_024 * 1_024
    public static let maximumPDFBytes = 16 * 1_024 * 1_024

    public static func defaultTemporaryDirectories() -> [String] {
        var directories = [NSTemporaryDirectory(), "/tmp", "/private/tmp"]
        if let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"], !tmpdir.isEmpty { directories.append(tmpdir) }
        return directories
    }

    public static func read(
        path printed: String,
        cwd: String?,
        workspaceRoot: String?,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        temporaryDirectories: [String] = defaultTemporaryDirectories()
    ) throws -> File {
        var trimmed = printed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("file://") { trimmed = String(trimmed.dropFirst(7)).removingPercentEncoding ?? "" }
        guard !trimmed.isEmpty, !trimmed.contains("\0"), !trimmed.contains("\\"), !trimmed.contains("://") else { throw WorkspaceFileError.invalidPath }
        let workspace = workspaceURL(workspaceRoot)
        let candidate: URL
        if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed)
        } else if trimmed == "~" || trimmed.hasPrefix("~/") {
            candidate = homeDirectory.appending(path: String(trimmed.dropFirst(trimmed == "~" ? 1 : 2)))
        } else if let cwd, cwd.hasPrefix("/") {
            candidate = URL(fileURLWithPath: cwd, isDirectory: true).appending(path: trimmed)
        } else if let workspace {
            candidate = workspace.appending(path: trimmed)
        } else {
            candidate = homeDirectory.appending(path: trimmed)
        }
        let roots = allowedRoots(workspace: workspace, homeDirectory: homeDirectory, temporaryDirectories: temporaryDirectories)
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let fileComponents = resolved.pathComponents
        guard let root = roots.first(where: { contains($0.url, fileComponents) })?.url else { throw WorkspaceFileError.outsideWorkspace }
        let relativeComponents = Array(fileComponents.dropFirst(root.pathComponents.count))
        try validateComponentNames(relativeComponents)
        // Every component below the root must itself be real: a link inside an allowed root
        // pointing elsewhere is refused even when the target happens to be allowed as well.
        var walked = root
        for component in relativeComponents {
            walked = walked.appending(path: component)
            if (try? walked.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { throw WorkspaceFileError.symbolicLink }
        }
        if (try? candidate.standardizedFileURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { throw WorkspaceFileError.symbolicLink }
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]) else { throw WorkspaceFileError.notFound }
        guard values.isRegularFile == true else { throw values.isDirectory == true ? WorkspaceFileError.notAFile : WorkspaceFileError.notFound }
        let relativePath = relativeComponents.joined(separator: "/")
        let kind = kind(for: relativePath)
        guard let size = values.fileSize, size <= kind.limit else { throw WorkspaceFileError.tooLarge }
        let data: Data
        do { data = try Data(contentsOf: resolved) } catch { throw WorkspaceFileError.notFound }
        guard data.count <= kind.limit else { throw WorkspaceFileError.tooLarge }
        if kind.isText {
            guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw WorkspaceFileError.notText }
            guard !containsSecret(text: text) else { throw WorkspaceFileError.secretMaterial }
        } else {
            guard kind.mediaType.hasPrefix("image/") || kind.mediaType == "application/pdf" else { throw WorkspaceFileError.notText }
        }
        return File(relativePath: relativePath, mediaType: kind.mediaType, isText: kind.isText, data: data)
    }

    struct Kind { let mediaType: String; let isText: Bool; let limit: Int }

    static func kind(for path: String) -> Kind {
        let ext = (path.split(separator: "/").last.map(String.init) ?? path).split(separator: ".").count > 1
            ? (path.split(separator: ".").last.map { $0.lowercased() } ?? "") : ""
        switch ext {
        case "md", "markdown": return Kind(mediaType: "text/markdown", isText: true, limit: maximumTextBytes)
        case "html", "htm": return Kind(mediaType: "text/html", isText: true, limit: maximumHTMLBytes)
        case "css": return Kind(mediaType: "text/css", isText: true, limit: maximumTextBytes)
        case "svg": return Kind(mediaType: "image/svg+xml", isText: true, limit: maximumImageBytes)
        case "png": return Kind(mediaType: "image/png", isText: false, limit: maximumImageBytes)
        case "jpg", "jpeg": return Kind(mediaType: "image/jpeg", isText: false, limit: maximumImageBytes)
        case "gif": return Kind(mediaType: "image/gif", isText: false, limit: maximumImageBytes)
        case "webp": return Kind(mediaType: "image/webp", isText: false, limit: maximumImageBytes)
        case "bmp": return Kind(mediaType: "image/bmp", isText: false, limit: maximumImageBytes)
        case "tif", "tiff": return Kind(mediaType: "image/tiff", isText: false, limit: maximumImageBytes)
        case "heic", "heif": return Kind(mediaType: "image/heic", isText: false, limit: maximumImageBytes)
        case "ico": return Kind(mediaType: "image/x-icon", isText: false, limit: maximumImageBytes)
        case "icns": return Kind(mediaType: "image/icns", isText: false, limit: maximumImageBytes)
        case "pdf": return Kind(mediaType: "application/pdf", isText: false, limit: maximumPDFBytes)
        default: return Kind(mediaType: "text/plain", isText: true, limit: maximumTextBytes)
        }
    }

    public static func mediaType(for path: String) -> String { kind(for: path).mediaType }

    /// One directory a Host is willing to serve from, and the word the client shows to say so.
    struct Root: Equatable, Sendable { let url: URL; let label: String }

    static func workspaceURL(_ workspaceRoot: String?) -> URL? {
        workspaceRoot.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
    }

    /// The roots, most specific first: a path inside the workspace is reported as the
    /// workspace's even when the workspace lives under the home directory.
    static func allowedRoots(workspace: URL?, homeDirectory: URL, temporaryDirectories: [String]) -> [Root] {
        var roots: [Root] = []
        if let workspace { roots.append(Root(url: workspace, label: "workspace")) }
        roots.append(Root(url: homeDirectory, label: "home"))
        roots.append(contentsOf: temporaryDirectories.map { Root(url: URL(fileURLWithPath: $0, isDirectory: true), label: "temporary") })
        return roots.map { Root(url: $0.url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL, label: $0.label) }
    }

    /// Whether `components` names something strictly below `root`.
    static func contains(_ root: URL, _ components: [String]) -> Bool {
        let rootComponents = root.pathComponents
        return components.count > rootComponents.count && Array(components.prefix(rootComponents.count)) == rootComponents
    }

    /// The names Artifact publication refuses as well, plus the stores a Host user keeps
    /// credentials in: repository internals, dotenv files, key material, credential and
    /// password stores, keychains, cookies and Northpane's own secure material.
    static func isRefusedComponent(_ name: String) -> Bool {
        let name = name.lowercased()
        return name == ".git" || name.hasPrefix(".env")
            || [".ssh", ".aws", ".gnupg", ".kube", ".docker", ".password-store", "keychains", "cookies", ".northpane"].contains(name)
            || ["id_rsa", "id_ed25519", "id_ecdsa", ".netrc", "credentials", "credentials.json", ".npmrc", ".pypirc", "hosts.yml"].contains(name)
            || name.hasSuffix(".pem") || name.hasSuffix(".p12") || name.hasSuffix(".key") || name.hasSuffix(".keychain") || name.hasSuffix(".keychain-db")
    }

    static func validateComponentNames(_ components: [String]) throws {
        let lowered = components.map { $0.lowercased() }
        if lowered.contains(where: isRefusedComponent) { throw WorkspaceFileError.secretMaterial }
        if lowered.count >= 3, lowered[0] == ".local", lowered[1] == "share", lowered[2] == "northpane" { throw WorkspaceFileError.secretMaterial }
    }

    static func containsSecret(text: String) -> Bool {
        let head = String(text.prefix(1_000_000))
        return head.range(of: #"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"#, options: .regularExpression) != nil
            || head.range(of: #"gh[pousr]_[A-Za-z0-9]{30,}"#, options: .regularExpression) != nil
            || head.range(of: #"AKIA[0-9A-Z]{16}"#, options: .regularExpression) != nil
            || head.range(of: #"sk-[A-Za-z0-9]{32,}"#, options: .regularExpression) != nil
    }
}

/// The directory a workspace is confined to. A Herdr worktree workspace names it; a plain
/// workspace does not, so its root is the longest common ancestor of its panes' working
/// directories (the directories the operator's shells and agents are actually in). A shell
/// that simply sits in the home directory says nothing about the project and would drag the
/// root up to the whole home, so it is left out whenever another pane is somewhere real
/// (found live on 2026-09-16: an agent in the repository plus a fresh shell at `~` made the
/// Workspace root `~`, and its icon unfindable). The file system root is never accepted.
public enum WorkspaceRootResolver {
    public static func root(worktreePath: String?, paneDirectories: [String], homeDirectory: String = NSHomeDirectory()) -> String? {
        if let worktreePath, worktreePath.hasPrefix("/") { return worktreePath }
        let home = URL(fileURLWithPath: homeDirectory, isDirectory: true).standardizedFileURL.pathComponents
        var absolute = paneDirectories.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.pathComponents }
        let somewhereReal = absolute.filter { $0 != home && $0.count > 1 }
        if !somewhereReal.isEmpty { absolute = somewhereReal }
        guard var common = absolute.first else { return nil }
        for components in absolute.dropFirst() {
            let shared = zip(common, components).prefix { $0 == $1 }.count
            common = Array(common.prefix(shared))
        }
        guard common.count > 1 else { return nil }
        return NSString.path(withComponents: common)
    }
}
