import Testing
@testable import NorthpaneConnection

@Test func privateEndpointCannotBindPubliclyOrWithoutIdentity() throws {
    #expect(throws: PrivateEndpointError.publicBind) {
        try PrivateEndpointPolicy.validate(.init(enabled: true, bindAddress: "0.0.0.0", port: 443, certificateFingerprint: "fingerprint"))
    }
    #expect(throws: PrivateEndpointError.missingIdentity) {
        try PrivateEndpointPolicy.validate(.init(enabled: true, bindAddress: "10.0.0.1", port: 443, certificateFingerprint: ""))
    }
    try PrivateEndpointPolicy.validate(.init(enabled: true, bindAddress: "10.0.0.1", port: 443, certificateFingerprint: "fingerprint"))
}
