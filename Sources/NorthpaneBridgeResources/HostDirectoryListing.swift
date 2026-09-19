import Foundation

/// Lists the folders inside one folder of the Host, so the operator can walk to the place a new
/// Workspace should open instead of typing its path.
///
/// Folders only, by name: no file is named and nothing is read. The walk stays inside the home
/// directory and the temporary directories — roots `WorkspacePathSearch` already answers for by
/// name — and leaves out what that search leaves out: hidden folders, the stores a user keeps
/// credentials in, and Northpane's own state. It reveals nothing a search does not.
public enum HostDirectoryListing {
    public struct Listing: Equatable, Sendable {
        /// The folder that was listed, resolved: what the operator is looking at.
        public let directory: String
        /// The folder above it, or nil at the top of a root, where there is nowhere to go up to.
        public let parent: String?
        public let rootLabel: String
        public let folders: [String]
        public let truncated: Bool
    }

    public enum Failure: Error, Equatable, Sendable { case outsideRoots, notADirectory, refused }

    public static let defaultLimit = 500

    /// `path` empty means the home directory, which is where a walk starts.
    public static func list(
        path: String,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        temporaryDirectories: [String] = WorkspaceFileReader.defaultTemporaryDirectories(),
        limit: Int = defaultLimit
    ) throws -> Listing {
        let roots = WorkspaceFileReader.allowedRoots(workspace: nil, homeDirectory: homeDirectory, temporaryDirectories: temporaryDirectories)
        let requested = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: URL
        if requested.isEmpty {
            target = roots.first { $0.label == "home" }?.url ?? homeDirectory
        } else {
            let normalized = HostPath.normalized(requested)
            guard HostPath.isAbsolute(normalized) else { throw Failure.outsideRoots }
            target = URL(fileURLWithPath: normalized, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        }
        let components = target.pathComponents
        guard let root = roots.first(where: { $0.url.pathComponents == components || WorkspaceFileReader.contains($0.url, components) }) else {
            throw Failure.outsideRoots
        }
        let below = Array(components.dropFirst(root.url.pathComponents.count))
        guard !below.contains(where: { $0.hasPrefix(".") || WorkspaceFileReader.isRefusedComponent($0) }) else { throw Failure.refused }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw Failure.notADirectory }

        let entries = (try? FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let names = entries.compactMap { entry -> String? in
            let name = entry.lastPathComponent
            guard !name.hasPrefix("."), !WorkspaceFileReader.isRefusedComponent(name),
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            return name
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return Listing(directory: target.path,
                       parent: components.count > root.url.pathComponents.count ? target.deletingLastPathComponent().path : nil,
                       rootLabel: root.label,
                       folders: Array(names.prefix(max(0, limit))),
                       truncated: names.count > limit)
    }
}
