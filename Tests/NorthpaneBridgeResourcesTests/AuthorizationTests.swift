import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import NorthpaneBridgeResources
@testable import NorthpaneProtocol
@testable import NorthpaneSecurity

@Test func githubCredentialStaysInHostStoreAndLateCompletionIsIgnored() async throws {
    let secureStore = InMemorySecureMaterialStore()
    let broker = AuthorizationBroker(secureStore: secureStore)
    let request = await broker.request(processID: 42)
    let grant = DeviceGrant(grants: [.authorizationBroker])
    let reference = try await broker.complete(id: request.id, provider: .github, providerCredential: Data("token".utf8), grant: grant)
    #expect(try await secureStore.load(reference) == Data("token".utf8))
    await #expect(throws: AuthorizationError.terminal) {
        try await broker.complete(id: request.id, provider: .github, providerCredential: Data("late".utf8), grant: grant)
    }
}

private actor FakeGitHubHTTP: GitHubDeviceFlowHTTPClient {
    private var posts: [(Data, HTTPURLResponse)]
    init(posts: [(Data, HTTPURLResponse)]) { self.posts = posts }
    func post(url: URL, form: [URLQueryItem]) throws -> (Data, HTTPURLResponse) { posts.removeFirst() }
    func get(url: URL, bearerToken: String) throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["X-OAuth-Scopes": "repo, read:org"])!
        return (Data(#"{"login":"octocat"}"#.utf8), response)
    }
}

private func githubResponse(_ body: String) -> (Data, HTTPURLResponse) {
    let url = URL(string: "https://github.com/")!
    return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!)
}

@Test func githubDeviceFlowUsesCanonicalScopesHonorsPendingAndVerifiesAccount() async throws {
    let http = FakeGitHubHTTP(posts: [
        githubResponse(#"{"device_code":"secret-device-code","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#),
        githubResponse(#"{"error":"authorization_pending"}"#),
        githubResponse(#"{"access_token":"gho_secret","scope":"read:org,repo"}"#),
    ])
    let flow = GitHubDeviceFlow(clientID: "client", http: http)
    let authorization = try await flow.begin(scopes: ["repo", "read:org", "repo"])
    #expect(authorization.userCode == "ABCD-EFGH")
    #expect(authorization.verificationURL == URL(string: "https://github.com/login/device")!)
    let result = try await flow.poll(authorization, expectedScopes: ["read:org", "repo"], sleep: { _ in })
    #expect(result.token == Data("gho_secret".utf8))
    #expect(result.verified == .init(account: "octocat", scopes: ["read:org", "repo"]))
}

private actor FakeCredentialInstaller: GitHubCLICredentialInstaller {
    private(set) var account = ""
    func install(token: Data, hostname: String, expectedAccount: String, expectedScopes: [String]) {
        account = expectedAccount
    }
}

@Test func processCorrelatedAuthorizationRequiresRevisionAndReachesIrreversibleSuccess() async throws {
    let http = FakeGitHubHTTP(posts: [
        githubResponse(#"{"device_code":"secret-device-code","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":1}"#),
        githubResponse(#"{"access_token":"gho_secret","scope":"read:org,repo"}"#),
    ])
    let secureStore = InMemorySecureMaterialStore()
    let installer = FakeCredentialInstaller()
    let service = GitHubAuthorizationService(hostID: HostID(), clientID: "client", secureStore: secureStore,
        installer: installer, http: http, pollSleep: { _ in })
    let request = try await service.create(processID: 42, hostname: "github.com", scopes: ["repo", "read:org"], provenance: "northpane-cli")
    await #expect(throws: AuthorizationError.terminal) { try await service.approve(id: request.id, expectedRevision: 99) }
    let approved = try await service.approve(id: request.id, expectedRevision: request.revision)
    #expect(approved.userCode == "ABCD-EFGH")
    var completed = approved
    for _ in 0..<100 where completed.state != .completed {
        await Task.yield()
        completed = try await service.status(id: request.id, processID: 42)
    }
    #expect(completed.state == .completed)
    #expect(completed.account == "octocat")
    #expect(await installer.account == "octocat")
    await #expect(throws: AuthorizationError.terminal) { try await service.cancel(id: request.id, expectedRevision: completed.revision, processID: 42) }
}
