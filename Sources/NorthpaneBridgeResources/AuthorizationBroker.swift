import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NorthpaneProtocol
import NorthpaneSecurity

public enum AuthorizationProvider: String, Codable, Sendable { case github }
public enum AuthorizationRequestState: Equatable, Codable, Sendable { case pending, completed(CredentialReference), cancelled, expired }

public struct AuthorizationRequest: Equatable, Codable, Sendable {
    public let id: UUID
    public let processID: Int32
    public let provider: AuthorizationProvider
    public let createdAt: Date
    public let expiresAt: Date
    public fileprivate(set) var state: AuthorizationRequestState
}

public enum AuthorizationError: Error, Equatable, Sendable {
    case notFound, expired, terminal, insufficientGrant, invalidProvider
    case unsupportedHostname, invalidScopes, providerRejected(String), malformedProviderResponse
    case githubCLIUnavailable, secureCredentialStoreUnavailable, credentialVerificationFailed
}

public actor AuthorizationBroker {
    private let secureStore: any SecureMaterialStore
    private var requests: [UUID: AuthorizationRequest] = [:]
    public init(secureStore: any SecureMaterialStore) { self.secureStore = secureStore }

    public func request(processID: Int32, provider: AuthorizationProvider = .github, ttl: TimeInterval = 900, now: Date = Date()) -> AuthorizationRequest {
        let request = AuthorizationRequest(id: UUID(), processID: processID, provider: provider, createdAt: now, expiresAt: now.addingTimeInterval(ttl), state: .pending)
        requests[request.id] = request
        return request
    }

    public func complete(id: UUID, provider: AuthorizationProvider, providerCredential: Data, grant: DeviceGrant, now: Date = Date()) async throws -> CredentialReference {
        guard var request = requests[id] else { throw AuthorizationError.notFound }
        guard request.state == .pending else { throw AuthorizationError.terminal }
        guard request.expiresAt >= now else { request.state = .expired; requests[id] = request; throw AuthorizationError.expired }
        guard request.provider == provider else { throw AuthorizationError.invalidProvider }
        guard grant.grants.contains(.authorizationBroker) else { throw AuthorizationError.insufficientGrant }
        let reference = CredentialReference(rawValue: "provider.github.\(id.uuidString)")
        try await secureStore.store(providerCredential, as: reference)
        request.state = .completed(reference)
        requests[id] = request
        return reference
    }

    public func cancel(id: UUID) throws {
        guard var request = requests[id] else { throw AuthorizationError.notFound }
        guard request.state == .pending else { throw AuthorizationError.terminal }
        request.state = .cancelled
        requests[id] = request
    }

    public func status(id: UUID, now: Date = Date()) throws -> AuthorizationRequestState {
        guard var request = requests[id] else { throw AuthorizationError.notFound }
        if request.state == .pending, request.expiresAt < now { request.state = .expired; requests[id] = request }
        return request.state
    }
}

public struct GitHubDeviceAuthorization: Equatable, Sendable {
    public let userCode: String
    public let verificationURL: URL
    public let expiresAt: Date
    public let pollingInterval: TimeInterval
    fileprivate let deviceCode: String
}

public struct VerifiedGitHubCredential: Equatable, Sendable {
    public let account: String
    public let scopes: [String]
}

public protocol GitHubDeviceFlowHTTPClient: Sendable {
    func post(url: URL, form: [URLQueryItem]) async throws -> (Data, HTTPURLResponse)
    func get(url: URL, bearerToken: String) async throws -> (Data, HTTPURLResponse)
}

public struct SystemGitHubDeviceFlowHTTPClient: GitHubDeviceFlowHTTPClient {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        self.session = URLSession(configuration: configuration)
    }

    public func post(url: URL, form: [URLQueryItem]) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents()
        components.queryItems = form
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AuthorizationError.malformedProviderResponse }
        return (data, response)
    }

    public func get(url: URL, bearerToken: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AuthorizationError.malformedProviderResponse }
        return (data, response)
    }
}

public actor GitHubDeviceFlow {
    private struct DeviceCodeResponse: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationURI: URL
        let expiresIn: Int
        let interval: Int
        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code", userCode = "user_code", verificationURI = "verification_uri"
            case expiresIn = "expires_in", interval
        }
    }
    private struct TokenResponse: Decodable {
        let accessToken: String?
        let scope: String?
        let error: String?
        let interval: Int?
        enum CodingKeys: String, CodingKey { case accessToken = "access_token", scope, error, interval }
    }
    private struct UserResponse: Decodable { let login: String }

    private let clientID: String
    private let http: any GitHubDeviceFlowHTTPClient
    private let deviceURL = URL(string: "https://github.com/login/device/code")!
    private let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!
    private let userURL = URL(string: "https://api.github.com/user")!

    public init(clientID: String, http: any GitHubDeviceFlowHTTPClient = SystemGitHubDeviceFlowHTTPClient()) {
        self.clientID = clientID
        self.http = http
    }

    public func begin(hostname: String = "github.com", scopes: [String], now: Date = Date()) async throws -> GitHubDeviceAuthorization {
        guard hostname.lowercased() == "github.com" else { throw AuthorizationError.unsupportedHostname }
        let scopes = try Self.canonicalScopes(scopes)
        let (data, response) = try await http.post(url: deviceURL, form: [
            .init(name: "client_id", value: clientID),
            .init(name: "scope", value: scopes.joined(separator: " ")),
        ])
        guard response.statusCode == 200 else { throw AuthorizationError.providerRejected("device_code_http_\(response.statusCode)") }
        guard let decoded = try? JSONDecoder().decode(DeviceCodeResponse.self, from: data), decoded.expiresIn > 0, decoded.interval > 0,
              decoded.verificationURI.scheme == "https", decoded.verificationURI.host?.lowercased() == "github.com"
        else { throw AuthorizationError.malformedProviderResponse }
        return .init(userCode: decoded.userCode, verificationURL: decoded.verificationURI,
                     expiresAt: now.addingTimeInterval(TimeInterval(decoded.expiresIn)),
                     pollingInterval: TimeInterval(decoded.interval), deviceCode: decoded.deviceCode)
    }

    public func poll(
        _ authorization: GitHubDeviceAuthorization,
        expectedScopes: [String],
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async throws -> (token: Data, verified: VerifiedGitHubCredential) {
        let expected = try Self.canonicalScopes(expectedScopes)
        var interval = authorization.pollingInterval
        while now() < authorization.expiresAt {
            try await sleep(interval)
            let (data, response) = try await http.post(url: tokenURL, form: [
                .init(name: "client_id", value: clientID),
                .init(name: "device_code", value: authorization.deviceCode),
                .init(name: "grant_type", value: "urn:ietf:params:oauth:grant-type:device_code"),
            ])
            guard response.statusCode == 200 else { throw AuthorizationError.providerRejected("token_http_\(response.statusCode)") }
            guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else { throw AuthorizationError.malformedProviderResponse }
            if let token = decoded.accessToken {
                let actualScopes = try Self.canonicalScopes((decoded.scope ?? "").split(separator: ",").map(String.init))
                guard Set(expected).isSubset(of: Set(actualScopes)) else { throw AuthorizationError.invalidScopes }
                let verified = try await verify(token: token, expectedScopes: expected)
                return (Data(token.utf8), verified)
            }
            switch decoded.error {
            case "authorization_pending": continue
            case "slow_down": interval = max(interval + 5, TimeInterval(decoded.interval ?? 0))
            case "expired_token": throw AuthorizationError.expired
            case let error?: throw AuthorizationError.providerRejected(error)
            case nil: throw AuthorizationError.malformedProviderResponse
            }
        }
        throw AuthorizationError.expired
    }

    private func verify(token: String, expectedScopes: [String]) async throws -> VerifiedGitHubCredential {
        let (data, response) = try await http.get(url: userURL, bearerToken: token)
        guard response.statusCode == 200, let user = try? JSONDecoder().decode(UserResponse.self, from: data) else {
            throw AuthorizationError.credentialVerificationFailed
        }
        let headerScopes = response.value(forHTTPHeaderField: "X-OAuth-Scopes")?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        guard Set(expectedScopes).isSubset(of: Set(headerScopes)) else { throw AuthorizationError.invalidScopes }
        return .init(account: user.login, scopes: headerScopes.sorted())
    }

    private static func canonicalScopes(_ scopes: [String]) throws -> [String] {
        let normalized = Array(Set(scopes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })).sorted()
        guard normalized.allSatisfy({ !$0.isEmpty && $0.range(of: #"^[A-Za-z0-9:_-]+$"#, options: .regularExpression) != nil }) else {
            throw AuthorizationError.invalidScopes
        }
        return normalized
    }
}

public protocol GitHubCLICredentialInstaller: Sendable {
    func install(token: Data, hostname: String, expectedAccount: String, expectedScopes: [String]) async throws
}

/// Gives the provider token to `gh` through stdin and rejects its documented
/// plaintext fallback. No token is placed in arguments, environment or files.
public struct SystemGitHubCLICredentialInstaller: GitHubCLICredentialInstaller {
    public let executableURL: URL
    public init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/env")) { self.executableURL = executableURL }

    public func install(token: Data, hostname: String, expectedAccount: String, expectedScopes: [String]) async throws {
        guard hostname == "github.com" else { throw AuthorizationError.unsupportedHostname }
        let login = try await run(arguments: ["gh", "auth", "login", "--hostname", hostname, "--with-token"], stdin: token + Data("\n".utf8))
        guard login.status == 0 else { throw AuthorizationError.credentialVerificationFailed }
        let status = try await run(arguments: ["gh", "auth", "status", "--hostname", hostname, "--active"], stdin: nil)
        guard status.status == 0 else { throw AuthorizationError.credentialVerificationFailed }
        let output = String(decoding: status.output, as: UTF8.self)
        guard output.contains("(keyring)"), output.contains("account \(expectedAccount)") else {
            throw AuthorizationError.secureCredentialStoreUnavailable
        }
        for scope in expectedScopes where !output.contains("'\(scope)'") { throw AuthorizationError.invalidScopes }
    }

    private func run(arguments: [String], stdin: Data?) async throws -> (status: Int32, output: Data) {
        #if os(macOS) || os(Linux)
        try await Task.detached {
            let process = Process()
            let input = Pipe(); let output = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            do { try process.run() } catch { throw AuthorizationError.githubCLIUnavailable }
            if let stdin { try input.fileHandleForWriting.write(contentsOf: stdin) }
            try? input.fileHandleForWriting.close()
            let data = try output.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            return (process.terminationStatus, Data(data.prefix(64 * 1_024)))
        }.value
        #else
        throw AuthorizationError.githubCLIUnavailable
        #endif
    }
}

public actor GitHubAuthorizationCoordinator {
    private let broker: AuthorizationBroker
    private let flow: GitHubDeviceFlow
    private let installer: any GitHubCLICredentialInstaller

    public init(broker: AuthorizationBroker, flow: GitHubDeviceFlow, installer: any GitHubCLICredentialInstaller = SystemGitHubCLICredentialInstaller()) {
        self.broker = broker; self.flow = flow; self.installer = installer
    }

    public func authorize(
        requestID: UUID,
        authorization: GitHubDeviceAuthorization,
        scopes: [String],
        grant: DeviceGrant
    ) async throws -> VerifiedGitHubCredential {
        let result = try await flow.poll(authorization, expectedScopes: scopes)
        let reference = try await broker.complete(id: requestID, provider: .github, providerCredential: result.token, grant: grant)
        do {
            try await installer.install(token: result.token, hostname: "github.com", expectedAccount: result.verified.account, expectedScopes: result.verified.scopes)
            try? await broker.deleteCredential(reference)
            return result.verified
        } catch {
            try? await broker.deleteCredential(reference)
            throw error
        }
    }
}

private extension AuthorizationBroker {
    func deleteCredential(_ reference: CredentialReference) async throws { try await secureStore.delete(reference) }
}
