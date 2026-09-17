import Foundation

public struct PrivateEndpointConfiguration: Equatable, Sendable {
    public let enabled: Bool
    public let bindAddress: String
    public let port: UInt16
    public let certificateFingerprint: String
    public init(enabled: Bool, bindAddress: String, port: UInt16, certificateFingerprint: String) {
        self.enabled = enabled; self.bindAddress = bindAddress; self.port = port; self.certificateFingerprint = certificateFingerprint
    }
}

public enum PrivateEndpointError: Error, Equatable, Sendable { case disabled, publicBind, missingIdentity }

public enum PrivateEndpointPolicy {
    public static func validate(_ configuration: PrivateEndpointConfiguration) throws {
        guard configuration.enabled else { throw PrivateEndpointError.disabled }
        guard !configuration.certificateFingerprint.isEmpty else { throw PrivateEndpointError.missingIdentity }
        guard isPrivate(configuration.bindAddress) else { throw PrivateEndpointError.publicBind }
    }

    private static func isPrivate(_ address: String) -> Bool {
        if address == "127.0.0.1" || address == "::1" { return true }
        if address.hasPrefix("10.") || address.hasPrefix("192.168.") { return true }
        if address.hasPrefix("fd") || address.hasPrefix("fc") { return true }
        let parts = address.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 172 && (16...31).contains(parts[1])
    }
}
