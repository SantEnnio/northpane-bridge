import Foundation
#if os(Windows)
import WinSDK
#endif

/// Lists the folders inside one folder of the Host, so the operator can walk to the place a new
/// Workspace should open instead of typing its path.
///
/// Folders only, by name: no file is named and nothing is read. The walk stays inside the home
/// directory and the temporary directories on POSIX Hosts. On Windows, the directory picker
/// also walks the logical drives. File reads and path searches keep their own confined roots.
/// Hidden folders, credential stores and Northpane's own state are excluded everywhere.
public enum HostDirectoryListing {
    public struct Listing: Equatable, Sendable {
        /// The folder that was listed, resolved: what the operator is looking at.
        public let directory: String
        /// The folder above it, or nil at the top of a root, where there is nowhere to go up to.
        public let parent: String?
        public let rootLabel: String
        public let folders: [String]
        public let truncated: Bool
        public var folderPaths: [String] {
            if rootLabel == "computer" { return folders }
            return folders.map { directory + (directory.hasSuffix("/") || directory.hasSuffix("\\") ? "" : "/") + $0 }
        }
    }

    public enum Failure: Error, Equatable, Sendable { case outsideRoots, notADirectory, refused }

    public static let defaultLimit = 500

    public static let computerPath = "/"

    public static func defaultVolumeDirectories() -> [URL] {
        #if os(Windows)
        let mask = GetLogicalDrives()
        return (0..<26).compactMap { index in
            guard mask & (DWORD(1) << index) != 0 else { return nil }
            let letter = UnicodeScalar(65 + index)!
            return URL(fileURLWithPath: "\(letter):/", isDirectory: true)
        }
        #else
        return []
        #endif
    }

    /// Empty starts at home. On Windows `/` names the virtual computer, not a working directory.
    public static func list(
        path: String,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        temporaryDirectories: [String] = WorkspaceFileReader.defaultTemporaryDirectories(),
        limit: Int = defaultLimit,
        volumeDirectories: [URL] = defaultVolumeDirectories()
    ) throws -> Listing {
        let volumes = volumeDirectories.sorted { $0.path < $1.path }
        let requested = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !volumes.isEmpty, requested == computerPath {
            return Listing(directory: computerPath, parent: nil, rootLabel: "computer",
                           folders: Array(volumes.map(\.path).prefix(max(0, limit))), truncated: volumes.count > limit)
        }
        let volumeRoots = volumes.map {
            WorkspaceFileReader.Root(url: $0.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL, label: "volume")
        }
        let roots = volumeRoots + WorkspaceFileReader.allowedRoots(workspace: nil, homeDirectory: homeDirectory, temporaryDirectories: temporaryDirectories)
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
                       parent: components.count > root.url.pathComponents.count ? target.deletingLastPathComponent().path : (root.label == "volume" ? computerPath : nil),
                       rootLabel: root.label,
                       folders: Array(names.prefix(max(0, limit))),
                       truncated: names.count > limit)
    }
}
