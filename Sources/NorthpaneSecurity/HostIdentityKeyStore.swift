import Foundation
import NorthpaneProtocol

/// Reads from the first store that has the material and writes to the first one only.
///
/// What an older store holds is copied forward when it is first read and never removed from where
/// it was, so the Bridge that was there before still finds it if the Host is rolled back.
public actor LayeredSecureMaterialStore: SecureMaterialStore {
    private let primary: any SecureMaterialStore
    private let earlier: [any SecureMaterialStore]

    public init(primary: any SecureMaterialStore, earlier: [any SecureMaterialStore]) {
        self.primary = primary
        self.earlier = earlier
    }

    public func store(_ data: Data, as reference: CredentialReference) async throws {
        try await primary.store(data, as: reference)
    }

    public func load(_ reference: CredentialReference) async throws -> Data {
        do { return try await primary.load(reference) }
        catch SecureMaterialError.notFound {}
        // A store that has the material and refuses it says more than one that never had it.
        var refusal: SecureMaterialError?
        for store in earlier {
            do {
                let data = try await store.load(reference)
                try await primary.store(data, as: reference)
                return data
            } catch SecureMaterialError.notFound {
                continue
            } catch let error as SecureMaterialError {
                refusal = refusal ?? error
            }
        }
        throw refusal ?? SecureMaterialError.notFound
    }

    public func delete(_ reference: CredentialReference) async throws {
        var deleted = false
        for store in [primary] + earlier {
            do { try await store.delete(reference); deleted = true }
            catch SecureMaterialError.notFound { continue }
        }
        guard deleted else { throw SecureMaterialError.notFound }
    }
}

public enum HostIdentityKeyStore {
    /// Where the key that proves a Host is kept: the same place whatever built the Bridge.
    ///
    /// Until 1.0.3 the place depended on the build. A development build kept the key in a file
    /// under the state directory; a release build kept it in the Keychain on a Mac and in the
    /// user's secure-material directory elsewhere. A release Bridge installed where a development
    /// one had run could not find the Host's key and did not start (two Macs at once, 2026-09-18).
    /// Now every build looks in every place a key was ever put. On a Mac the file is the home and
    /// the Keychain only a place to look, for the reasons `FileSecureMaterialStore` gives;
    /// elsewhere the release store was a file all along and stays the home.
    public static func standard(stateDirectory: URL) throws -> LayeredSecureMaterialStore {
        let file = try FileSecureMaterialStore(
            directory: stateDirectory.appending(path: "secure-material/host-identity", directoryHint: .isDirectory))
        let platform = KeychainSecureMaterialStore(service: "it.ambiens.northpane.host-identity")
        #if canImport(Security)
        return LayeredSecureMaterialStore(primary: file, earlier: [platform])
        #else
        return LayeredSecureMaterialStore(primary: platform, earlier: [file])
        #endif
    }
}
