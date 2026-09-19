// The system `ssh` deployment exists only on a Mac, which is the only client that shells out to it.
#if os(macOS)
import Foundation
import Testing
@testable import NorthpaneConnection

@Test func aPlatformProbeReadsTheAnswerPastTheWarningsSSHPrintsFirst() {
    let noisy = Data("""
        ** WARNING: connection is not using a post-quantum key exchange algorithm.
        ** The server may need to be upgraded. See https://openssh.com/pq.html
        AMD64

        """.utf8)
    #expect(POSIXSFTPBridgeDeployment.lastLine(noisy) == "amd64")
    #expect(POSIXSFTPBridgeDeployment.lastLine(Data("Darwin arm64\n".utf8)) == "darwin arm64")
    #expect(POSIXSFTPBridgeDeployment.lastLine(Data()) == "")
}
#endif
