import Foundation

/// Finds directories and files by name inside the roots `WorkspaceFileReader` already reads
/// from — the workspace root, the Host user's home directory and the temporary directories.
///
/// Only names and their metadata leave the Host; no file is ever opened. The refused names
/// (`.ssh`, `.env*`, key material, Northpane's own secure material) are invisible here for the
/// same reason they are unreadable there, and a symbolic link is neither reported nor followed.
///
/// The walk is breadth-first and bounded. That pairing is the point: when a budget stops the
/// search early the answer is still the *shallowest* matches, which are the ones an operator
/// was looking for. A depth-first walk cut at the same budget would return whichever corner of
/// the disk it happened to fall into.
public enum WorkspacePathSearch {
    public struct Budget: Equatable, Sendable {
        /// How deep to walk below each kind of root. They differ because the roots differ in
        /// size: the workspace is one project and can be searched right through, while the home
        /// directory is everything the operator owns and is walked only as deep as it can be
        /// walked to the end — past five levels the walk stops finishing, and an answer that
        /// always says "truncated" tells the operator nothing. Anything deeper in the project
        /// being worked on is still reached through the workspace root.
        public var maximumWorkspaceDepth: Int
        public var maximumHomeDepth: Int
        /// The temporary directories exist so an agent's artifacts can be read; below the first
        /// level or two they are lock files and caches.
        public var maximumTemporaryDepth: Int
        public var deadline: TimeInterval
        public var maximumVisitedDirectories: Int
        public init(maximumWorkspaceDepth: Int = 8, maximumHomeDepth: Int = 5, maximumTemporaryDepth: Int = 2,
                    deadline: TimeInterval = 2.5, maximumVisitedDirectories: Int = 60_000) {
            self.maximumWorkspaceDepth = maximumWorkspaceDepth; self.maximumHomeDepth = maximumHomeDepth
            self.maximumTemporaryDepth = maximumTemporaryDepth
            self.deadline = deadline; self.maximumVisitedDirectories = maximumVisitedDirectories
        }
        public static let `default` = Budget()
    }

    public struct Hit: Equatable, Sendable {
        public let path: String
        public let relativePath: String
        public let rootLabel: String
        public let isDirectory: Bool
        public let byteCount: Int
        public let modified: Date?
    }

    public struct Results: Equatable, Sendable {
        public let hits: [Hit]
        /// A budget stopped the walk, or more entries matched than `limit` allowed through.
        public let truncated: Bool
    }

    public static let defaultLimit = 120
    /// A single character matches most of a disk, which is neither useful nor cheap.
    public static let minimumQueryLength = 2

    /// Directories that hold generated or vendored trees. They are never descended into, but
    /// they remain matchable themselves: someone searching for `dist` should still find it.
    static let prunedNames: Set<String> = [
        "node_modules", ".build", "deriveddata", ".cache", "caches", ".npm", ".cargo", ".gradle",
        ".venv", "venv", "pods", ".trash", "dist", "target", ".next", ".nuxt", "vendor", ".terraform",
        "worktrees",
    ]
    /// Pruned only directly below the home directory, where they are the system's, not a project's.
    static let prunedHomeChildren: Set<String> = ["library", "applications", "movies", "music", "pictures"]

    public static func search(
        query: String,
        workspaceRoot: String?,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        temporaryDirectories: [String] = WorkspaceFileReader.defaultTemporaryDirectories(),
        limit: Int = defaultLimit,
        budget: Budget = .default,
        isCancelled: () -> Bool = { false }
    ) -> Results {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = trimmed.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard trimmed.count >= minimumQueryLength, !terms.isEmpty, limit > 0 else { return Results(hits: [], truncated: false) }

        let roots = WorkspaceFileReader.allowedRoots(
            workspace: WorkspaceFileReader.workspaceURL(workspaceRoot),
            homeDirectory: homeDirectory,
            temporaryDirectories: temporaryDirectories)
        let home = homeDirectory.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL

        let deadline = Date().addingTimeInterval(budget.deadline)
        // Bounded so a broad query cannot grow without limit before ranking; generous enough
        // that ranking still has something to choose from.
        let collectionCeiling = limit * 8
        var scored: [(hit: Hit, rank: Rank)] = []
        var visitedDirectories = 0
        var seen = Set<String>()
        var truncated = false

        // Roots are walked one at a time in priority order, not interleaved. The temporary
        // directories hold thousands of lock files and caches; interleaved, their first level
        // would exhaust the budget before the home directory had been searched at all.
        // A root already covered by an earlier one (the workspace usually lives inside home)
        // is not walked again; the earlier, more specific root keeps the label.
        // The relative path is carried down the walk rather than derived from a string prefix:
        // `contentsOfDirectory` and `standardizedFileURL` disagree about the `/private` prefix
        // on macOS, and a prefix comparison silently loses every parent directory.
        rootLoop: for root in roots {
            guard !seen.contains(root.url.path), FileManager.default.fileExists(atPath: root.url.path) else { continue }
            seen.insert(root.url.path)
            // Depth follows what the root actually is, not what it is called. A workspace whose
            // panes sit in the home directory *is* the home directory (the root is the common
            // ancestor of the pane directories), and walking that eight levels deep never
            // finishes. Anything at or above home gets the shallower, completable walk.
            let coversHome = home.path == root.url.path || home.path.hasPrefix(root.url.path + "/")
            let maximumDepth = if coversHome {
                budget.maximumHomeDepth
            } else {
                switch root.label {
                case "workspace": budget.maximumWorkspaceDepth
                case "home": budget.maximumHomeDepth
                default: budget.maximumTemporaryDepth
                }
            }
            var queue: [(url: URL, relative: String, depth: Int)] = [(root.url, "", 0)]
            var index = 0

            while index < queue.count {
                if isCancelled() { truncated = true; break rootLoop }
                if Date() >= deadline || visitedDirectories >= budget.maximumVisitedDirectories { truncated = true; break rootLoop }
                let (directory, parentRelative, depth) = queue[index]
                index += 1
                visitedDirectories += 1

                let entries: [URL]
                do {
                    entries = try FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                        options: [])
                } catch { continue }   // an unreadable directory is simply not part of the answer

                for entry in entries {
                    let name = entry.lastPathComponent
                    if WorkspaceFileReader.isRefusedComponent(name) { continue }
                    guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
                    if values.isSymbolicLink == true { continue }
                    let isDirectory = values.isDirectory == true
                    let relative = parentRelative.isEmpty ? name : parentRelative + "/" + name
                    // Northpane's own secure material sits at a known place below home.
                    if root.label == "home", relative.lowercased().hasPrefix(".local/share/northpane") { continue }

                    // Size and date cost a stat each, and only a match ever shows them.
                    if let rank = rank(name: name, relativePath: relative, terms: terms, depth: depth + 1,
                                       isDirectory: isDirectory, rootPriority: priority(of: root.label)) {
                        if scored.count < collectionCeiling {
                            let detail = try? entry.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                            scored.append((Hit(path: entry.path, relativePath: relative, rootLabel: root.label,
                                               isDirectory: isDirectory, byteCount: detail?.fileSize ?? 0,
                                               modified: detail?.contentModificationDate), rank))
                        } else {
                            truncated = true
                        }
                    }

                    guard isDirectory, depth + 1 < maximumDepth else { continue }
                    let lowered = name.lowercased()
                    if prunedNames.contains(lowered) { continue }
                    // Hidden directories are descended into only inside the workspace, where
                    // `.github` and `.scratch` are part of the work. Below home they are caches
                    // and per-tool state — `~/.claude/projects`, `~/.gemini`, `~/.oh-my-zsh` —
                    // large enough that a level-by-level walk never reaches the real projects.
                    // They stay matchable themselves, like every other pruned directory.
                    if root.label != "workspace", name.hasPrefix(".") { continue }
                    if directory.path == home.path, prunedHomeChildren.contains(lowered) { continue }
                    guard !seen.contains(entry.path) else { continue }
                    seen.insert(entry.path)
                    queue.append((entry, relative, depth + 1))
                }
            }
        }

        if scored.count > limit { truncated = true }
        let hits = scored
            .sorted { $0.rank < $1.rank }
            .prefix(limit)
            .map(\.hit)
        return Results(hits: Array(hits), truncated: truncated)
    }

    /// How well an entry answers the query, smaller being better. `nil` means it does not.
    struct Rank: Comparable {
        let nameScore: Int      // 0 exact, 1 prefix, 2 substring
        let rootPriority: Int   // what you are working in beats your home, which beats scratch space
        let fileFirst: Int      // directories first: the question is usually "where is that folder"
        let depth: Int
        let path: String

        static func < (a: Rank, b: Rank) -> Bool {
            if a.nameScore != b.nameScore { return a.nameScore < b.nameScore }
            if a.rootPriority != b.rootPriority { return a.rootPriority < b.rootPriority }
            if a.fileFirst != b.fileFirst { return a.fileFirst < b.fileFirst }
            if a.depth != b.depth { return a.depth < b.depth }
            return a.path < b.path
        }
    }

    /// A hit in the workspace is what the operator is working in; the temporary directories are
    /// scratch space full of lock files, and lose every tie.
    static func priority(of rootLabel: String) -> Int {
        switch rootLabel {
        case "workspace": 0
        case "home": 1
        default: 2
        }
    }

    /// Every term must appear somewhere in the relative path, and at least one of them in the
    /// entry's own name. Without the second rule `sources` would return every file under every
    /// directory called `Sources`; with it, `crook sources` still narrows the way one expects.
    static func rank(name: String, relativePath: String, terms: [String], depth: Int, isDirectory: Bool, rootPriority: Int = 0) -> Rank? {
        let loweredPath = relativePath.lowercased()
        guard terms.allSatisfy({ loweredPath.contains($0) }) else { return nil }
        let loweredName = name.lowercased()
        var best = Int.max
        for term in terms {
            if loweredName == term { best = min(best, 0) }
            else if loweredName.hasPrefix(term) { best = min(best, 1) }
            else if loweredName.contains(term) { best = min(best, 2) }
        }
        guard best != Int.max else { return nil }
        return Rank(nameScore: best, rootPriority: rootPriority, fileFirst: isDirectory ? 0 : 1,
                    depth: depth, path: relativePath)
    }
}
