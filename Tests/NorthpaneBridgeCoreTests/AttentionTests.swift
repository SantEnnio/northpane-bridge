import Foundation
import Testing
@testable import NorthpaneBridgeCore
@testable import NorthpaneProtocol
@testable import NorthpaneProjection

@Test func onlyTheCurrentAttentionRevisionCanBeActedUpon() {
    let host = HostID()
    let proof = ObservationProof(hostID: host, incarnationID: HerdrSessionIncarnationID(), snapshotID: "s", nextEventSequence: 2)
    var attention = AttentionStore(hostID: host)
    let first = attention.publish(id: "a", revision: 1, proof: proof)
    let current = attention.publish(id: "a", revision: 2, proof: proof)

    #expect(attention.actionability(of: first, against: proof) == .superseded)
    #expect(attention.actionability(of: current, against: proof) == .actionable)
}

@Test func expiryAgentEndAndConcurrentResolutionAreNonActionable() {
    let host = HostID()
    let proof = ObservationProof(hostID: host, incarnationID: HerdrSessionIncarnationID(), snapshotID: "s", nextEventSequence: 2)
    let now = Date()
    var store = AttentionStore(hostID: host)
    let expired = store.publish(id: "expired", revision: 1, proof: proof, agentIncarnationID: "agent", expiresAt: now.addingTimeInterval(-1))
    #expect(store.actionability(of: expired, against: proof, now: now) == .expired)
    let current = store.publish(id: "current", revision: 1, proof: proof, agentIncarnationID: "agent")
    #expect(store.resolve(current, against: proof) == .resolved)
    #expect(store.resolve(current, against: proof) == .rejected(.resolved))
    let ending = store.publish(id: "ending", revision: 1, proof: proof, agentIncarnationID: "ending")
    store.endAgentIncarnation("ending")
    #expect(store.actionability(of: ending, against: proof) == .unknown)
}
