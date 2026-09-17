import Foundation
import NorthpaneProtocol
import NorthpaneSecurity

public actor GitHubAuthorizationService {
    private let hostID: HostID
    private let flow: GitHubDeviceFlow?
    private let secureStore: any SecureMaterialStore
    private let installer: any GitHubCLICredentialInstaller
    private let pollSleep: @Sendable (TimeInterval) async throws -> Void
    private var records: [UUID: AuthorizationRequestDescriptor] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init(hostID: HostID, clientID: String?, secureStore: any SecureMaterialStore, installer: any GitHubCLICredentialInstaller = SystemGitHubCLICredentialInstaller(), http: any GitHubDeviceFlowHTTPClient = SystemGitHubDeviceFlowHTTPClient(), pollSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.hostID = hostID
        self.flow = clientID.flatMap { $0.isEmpty ? nil : GitHubDeviceFlow(clientID: $0, http: http) }
        self.secureStore = secureStore
        self.installer = installer
        self.pollSleep = pollSleep
    }

    public func create(processID: Int32, hostname: String, scopes: [String], provenance: String, now: Date = Date()) throws -> AuthorizationRequestDescriptor {
        guard processID > 0, hostname.lowercased() == "github.com" else { throw AuthorizationError.unsupportedHostname }
        let scopes = try canonicalScopes(scopes)
        let provenance = provenance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provenance.isEmpty, provenance.utf8.count <= 160, !provenance.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AuthorizationError.malformedProviderResponse
        }
        let request = AuthorizationRequestDescriptor(requestID: UUID(), revision: 1, state: .pending, hostID: hostID,
            processID: processID, hostname: "github.com", scopes: scopes, provenance: provenance,
            createdAt: now, expiresAt: now.addingTimeInterval(15 * 60))
        records[request.id] = request
        return request
    }

    public func list(now: Date = Date()) -> [AuthorizationRequestDescriptor] {
        expire(now: now)
        return records.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func status(id: UUID, processID: Int32? = nil, now: Date = Date()) throws -> AuthorizationRequestDescriptor {
        expire(now: now)
        guard let request = records[id], processID == nil || request.processID == processID else { throw AuthorizationError.notFound }
        return request
    }

    public func approve(id: UUID, expectedRevision: Int, now: Date = Date()) async throws -> AuthorizationRequestDescriptor {
        expire(now: now)
        guard var request = records[id] else { throw AuthorizationError.notFound }
        guard request.state == .pending else { throw AuthorizationError.terminal }
        guard request.revision == expectedRevision else { throw AuthorizationError.terminal }
        guard let flow else {
            request = replacing(request, state: .failed, revision: request.revision + 1, problemCode: "github_oauth_client_unconfigured")
            records[id] = request
            return request
        }
        let authorization = try await flow.begin(hostname: request.hostname, scopes: request.scopes, now: now)
        request = replacing(request, state: .awaitingUser, revision: request.revision + 1,
            userCode: authorization.userCode, verificationURL: authorization.verificationURL)
        records[id] = request
        tasks[id] = Task { [weak self] in await self?.pollAndInstall(id: id, authorization: authorization) }
        return request
    }

    public func cancel(id: UUID, expectedRevision: Int, processID: Int32? = nil) throws -> AuthorizationRequestDescriptor {
        guard var request = records[id], processID == nil || request.processID == processID else { throw AuthorizationError.notFound }
        guard request.revision == expectedRevision, !Self.isTerminal(request.state) else { throw AuthorizationError.terminal }
        tasks.removeValue(forKey: id)?.cancel()
        request = replacing(request, state: .cancelled, revision: request.revision + 1)
        records[id] = request
        return request
    }

    private func pollAndInstall(id: UUID, authorization: GitHubDeviceAuthorization) async {
        guard var request = records[id], request.state == .awaitingUser, let flow else { return }
        request = replacing(request, state: .polling, revision: request.revision + 1)
        records[id] = request
        do {
            let result = try await flow.poll(authorization, expectedScopes: request.scopes, sleep: pollSleep)
            try Task.checkCancellation()
            let reference = CredentialReference(rawValue: "provider.github.\(id.uuidString)")
            try await secureStore.store(result.token, as: reference)
            do {
                try await installer.install(token: result.token, hostname: request.hostname, expectedAccount: result.verified.account, expectedScopes: request.scopes)
                try await secureStore.delete(reference)
            } catch {
                try? await secureStore.delete(reference)
                throw error
            }
            guard let current = records[id], !Self.isTerminal(current.state) else { return }
            records[id] = replacing(current, state: .completed, revision: current.revision + 1, account: result.verified.account)
        } catch is CancellationError {
        } catch {
            guard let current = records[id], !Self.isTerminal(current.state) else { return }
            records[id] = replacing(current, state: error as? AuthorizationError == .expired ? .expired : .failed,
                revision: current.revision + 1, problemCode: Self.problemCode(error))
        }
        tasks[id] = nil
    }

    private func expire(now: Date) {
        for (id, record) in records where record.expiresAt < now && !Self.isTerminal(record.state) {
            tasks.removeValue(forKey: id)?.cancel()
            records[id] = replacing(record, state: .expired, revision: record.revision + 1, problemCode: "authorization_expired")
        }
    }

    private func canonicalScopes(_ scopes: [String]) throws -> [String] {
        let values = Array(Set(scopes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })).sorted()
        guard !values.isEmpty, values.allSatisfy({ $0.range(of: #"^[A-Za-z0-9:_-]+$"#, options: .regularExpression) != nil }) else { throw AuthorizationError.invalidScopes }
        return values
    }

    private func replacing(_ value: AuthorizationRequestDescriptor, state: AuthorizationWireState, revision: Int,
                           userCode: String? = nil, verificationURL: URL? = nil, account: String? = nil, problemCode: String? = nil) -> AuthorizationRequestDescriptor {
        .init(requestID: value.id, revision: revision, state: state, hostID: value.hostID, processID: value.processID,
              hostname: value.hostname, scopes: value.scopes, provenance: value.provenance, createdAt: value.createdAt,
              expiresAt: value.expiresAt, userCode: userCode ?? value.userCode, verificationURL: verificationURL ?? value.verificationURL,
              account: account ?? value.account, problemCode: problemCode ?? value.problemCode)
    }

    private static func isTerminal(_ state: AuthorizationWireState) -> Bool {
        [.completed, .cancelled, .expired, .failed].contains(state)
    }
    private static func problemCode(_ error: Error) -> String {
        switch error as? AuthorizationError {
        case .expired: "authorization_expired"
        case .secureCredentialStoreUnavailable: "secure_credential_store_unavailable"
        case .githubCLIUnavailable: "github_cli_unavailable"
        case .invalidScopes: "github_scope_mismatch"
        case .credentialVerificationFailed: "github_credential_verification_failed"
        default: "github_authorization_failed"
        }
    }
}
