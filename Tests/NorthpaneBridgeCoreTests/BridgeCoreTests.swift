import Testing
@testable import NorthpaneBridgeCore
@testable import NorthpaneProtocol
@testable import NorthpaneProjection

@Test func aCurrentProofWithTheStandardGrantIsAppliedOnce() {
    let host = HostID()
    let device = ClientDeviceID()
    let incarnation = HerdrSessionIncarnationID()
    let proof = ObservationProof(hostID: host, incarnationID: incarnation, snapshotID: "snapshot", nextEventSequence: 7)
    var bridge = BridgeCore(hostID: host)
    bridge.grantStandardControl(to: device)
    bridge.registerCurrent(proof)
    let command = MutationCommand(commandID: CommandID(), clientDeviceID: device, proof: proof, capability: .terminalControl)

    #expect(bridge.execute(command) == .applied)
    #expect(bridge.execute(command) == .applied)
    #expect(bridge.appliedCommandCount == 1)
}

@Test func staleProofIsRejectedBeforeAnyEffect() {
    let host = HostID()
    let device = ClientDeviceID()
    let incarnation = HerdrSessionIncarnationID()
    var bridge = BridgeCore(hostID: host)
    bridge.grantStandardControl(to: device)
    bridge.registerCurrent(ObservationProof(hostID: host, incarnationID: incarnation, snapshotID: "new", nextEventSequence: 7))
    let stale = ObservationProof(hostID: host, incarnationID: incarnation, snapshotID: "old", nextEventSequence: 7)

    #expect(bridge.execute(MutationCommand(commandID: CommandID(), clientDeviceID: device, proof: stale, capability: .terminalControl)) == .rejected(.staleObservation))
    #expect(bridge.appliedCommandCount == 0)
}
