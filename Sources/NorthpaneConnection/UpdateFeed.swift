#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NorthpaneProtocol

public enum UpdateChannel: String, Codable, Sendable { case stable, beta }

public struct UpdateFeedArtifact: Equatable, Codable, Sendable {
    public let version: String
    public let platform: String
    public let downloadURL: URL
    public let sha256: String
    public let rolloutPercent: Int
    public let publishedAt: Date
    public init(version: String, platform: String, downloadURL: URL, sha256: String, rolloutPercent: Int, publishedAt: Date) {
        self.version = version; self.platform = platform; self.downloadURL = downloadURL; self.sha256 = sha256
        self.rolloutPercent = rolloutPercent; self.publishedAt = publishedAt
    }
}

public struct UpdateFeedDocument: Equatable, Codable, Sendable {
    public let channel: UpdateChannel
    public let generatedAt: Date
    public let expiresAt: Date
    public let minimumSafeVersion: String?
    public let revokedVersions: Set<String>
    public let artifacts: [UpdateFeedArtifact]
    public init(channel: UpdateChannel, generatedAt: Date, expiresAt: Date, minimumSafeVersion: String?, revokedVersions: Set<String>, artifacts: [UpdateFeedArtifact]) {
        self.channel = channel; self.generatedAt = generatedAt; self.expiresAt = expiresAt
        self.minimumSafeVersion = minimumSafeVersion; self.revokedVersions = revokedVersions; self.artifacts = artifacts
    }
}

public struct SignedUpdateFeed: Codable, Sendable {
    public let payload: Data
    public let signature: Data
    public init(payload: Data, signature: Data) { self.payload = payload; self.signature = signature }
}

public struct UpdateDecision: Equatable, Sendable {
    public let artifact: UpdateFeedArtifact?
    public let currentVersionRevoked: Bool
    public let belowMinimumSafeVersion: Bool
}

public enum UpdateFeedError: Error, Equatable, Sendable { case insecureURL, oversized, invalidSignature, malformed, invalidArtifact, digestMismatch }

public enum UpdateFeedVerifier {
    public static func verify(_ signed: SignedUpdateFeed, trustedSigningPublicKey: Data, now: Date = Date()) throws -> UpdateFeedDocument {
        guard signed.payload.count <= 1_024 * 1_024 else { throw UpdateFeedError.oversized }
        guard trustedSigningPublicKey.count == 65 else { throw UpdateFeedError.invalidSignature }
        do {
            let key = try P256.Signing.PublicKey(x963Representation: trustedSigningPublicKey)
            let signature = try P256.Signing.ECDSASignature(derRepresentation: signed.signature)
            guard key.isValidSignature(signature, for: signed.payload) else { throw UpdateFeedError.invalidSignature }
        } catch let error as UpdateFeedError { throw error }
        catch { throw UpdateFeedError.invalidSignature }
        let document: UpdateFeedDocument
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            document = try decoder.decode(UpdateFeedDocument.self, from: signed.payload)
        }
        catch { throw UpdateFeedError.malformed }
        guard document.generatedAt <= now.addingTimeInterval(5 * 60), document.expiresAt > now,
              document.expiresAt.timeIntervalSince(document.generatedAt) <= 7 * 24 * 60 * 60,
              document.artifacts.allSatisfy({
                  !$0.version.isEmpty && !$0.platform.isEmpty && $0.downloadURL.scheme == "https"
                      && (0...100).contains($0.rolloutPercent)
                      && $0.publishedAt <= now.addingTimeInterval(5 * 60)
                      && $0.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
              }) else { throw UpdateFeedError.invalidArtifact }
        return document
    }

    public static func decide(document: UpdateFeedDocument, currentVersion: String, platform: String, deviceID: ClientDeviceID) -> UpdateDecision {
        let digest = SHA256.hash(data: Data(deviceID.rawValue.uuidString.utf8))
        let bucket = digest.prefix(8).reduce(UInt64.zero) { ($0 << 8) | UInt64($1) } % 100
        let unsafe = document.revokedVersions.contains(currentVersion)
            || (document.minimumSafeVersion.map { compare(currentVersion, $0) == .orderedAscending } ?? false)
        let artifact = document.artifacts.filter {
            $0.platform == platform && compare($0.version, currentVersion) == .orderedDescending
                && (unsafe || bucket < UInt64($0.rolloutPercent))
        }
            .max { compare($0.version, $1.version) == .orderedAscending }
        return .init(artifact: artifact, currentVersionRevoked: document.revokedVersions.contains(currentVersion),
            belowMinimumSafeVersion: document.minimumSafeVersion.map { compare(currentVersion, $0) == .orderedAscending } ?? false)
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }
}

public actor HTTPSUpdateFeedClient {
    private let session: URLSession
    public init() { let configuration = URLSessionConfiguration.ephemeral; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; session = URLSession(configuration: configuration) }
    public func load(_ url: URL) async throws -> SignedUpdateFeed {
        guard url.scheme == "https" else { throw UpdateFeedError.insecureURL }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 2 * 1_024 * 1_024 else { throw UpdateFeedError.oversized }
        return try JSONDecoder().decode(SignedUpdateFeed.self, from: data)
    }
    public func download(_ artifact: UpdateFeedArtifact) async throws -> Data {
        guard artifact.downloadURL.scheme == "https" else { throw UpdateFeedError.insecureURL }
        let (data, response) = try await session.data(from: artifact.downloadURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 500 * 1_024 * 1_024 else { throw UpdateFeedError.oversized }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == artifact.sha256 else { throw UpdateFeedError.digestMismatch }
        return data
    }
}
