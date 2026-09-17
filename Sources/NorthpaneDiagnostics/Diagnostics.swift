#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import NorthpaneProtocol

public struct ComponentVersion: Equatable, Codable, Sendable {
    public let component: String
    public let version: String
    public init(component: String, version: String) {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        self.component = component.unicodeScalars.allSatisfy(allowed.contains) ? component : "redacted"
        self.version = version.unicodeScalars.allSatisfy(allowed.contains) ? version : "redacted"
    }
}

public enum SelfCheckResult: String, Codable, Sendable { case passed, failed, unavailable }

public struct DiagnosticEntry: Equatable, Codable, Sendable {
    public let recordedAt: Date
    public let problemCode: String
    public let locus: ProblemLocus
    public let phase: OperationPhase?
    public let correlationPseudonym: String?

    public init(recordedAt: Date = Date(), problem: Problem) {
        self.recordedAt = recordedAt
        self.problemCode = problem.code
        self.locus = problem.locus
        self.phase = problem.phase
        self.correlationPseudonym = problem.correlationID.map(Self.pseudonymize)
    }

    private static func pseudonymize(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

public struct DiagnosticBundle: Equatable, Codable, Sendable {
    public let formatVersion: Int
    public let generatedAt: Date
    public let deleteAfter: Date
    public let versions: [ComponentVersion]
    public let capabilities: Set<Capability>
    public let selfChecks: [String: SelfCheckResult]
    public let entries: [DiagnosticEntry]

    public init(generatedAt: Date = Date(), versions: [ComponentVersion], capabilities: Set<Capability>, selfChecks: [String: SelfCheckResult], entries: [DiagnosticEntry]) {
        self.formatVersion = 1; self.generatedAt = generatedAt; self.deleteAfter = generatedAt.addingTimeInterval(24 * 60 * 60); self.versions = versions; self.capabilities = capabilities; self.selfChecks = selfChecks; self.entries = entries
    }
}

public enum DiagnosticExporter {
    public static func export(_ bundle: DiagnosticBundle, to parent: URL) throws -> URL {
        let directory = parent.appending(path: "northpane-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bundle).write(to: directory.appending(path: "diagnostics.json"), options: protectedAtomicWriteOptions)
        return directory
    }

    public static func purgeExpired(in parent: URL, now: Date = Date()) {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for directory in (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            let manifest = directory.appending(path: "diagnostics.json")
            guard let data = try? Data(contentsOf: manifest), let bundle = try? decoder.decode(DiagnosticBundle.self, from: data), bundle.deleteAfter < now else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static var protectedAtomicWriteOptions: Data.WritingOptions {
#if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
        [.atomic, .completeFileProtection]
#else
        [.atomic]
#endif
    }
}
