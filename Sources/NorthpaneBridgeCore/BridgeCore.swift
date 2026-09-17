import Foundation
import NorthpaneProtocol
import NorthpaneProjection
import NorthpaneSecurity

public struct CommandID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct MutationCommand: Equatable, Codable, Sendable {
    public let commandID: CommandID
    public let clientDeviceID: ClientDeviceID
    public let proof: ObservationProof
    public let capability: Capability
    public init(commandID: CommandID, clientDeviceID: ClientDeviceID, proof: ObservationProof, capability: Capability) {
        self.commandID = commandID; self.clientDeviceID = clientDeviceID; self.proof = proof; self.capability = capability
    }
}

public enum MutationRejection: String, Codable, Sendable { case unknownDevice, missingGrant, staleObservation, unsupportedCapability }
public enum MutationReceipt: Equatable, Codable, Sendable { case applied, rejected(MutationRejection), notApplied }

public struct BridgeCore: Sendable {
    public let hostID: HostID
    private var knownDevices: Set<ClientDeviceID> = []
    private var grants: [ClientDeviceID: DeviceGrant] = [:]
    private var currentProof: ObservationProof?
    private var receipts: [CommandID: MutationReceipt] = [:]
    public private(set) var appliedCommandCount = 0

    public init(hostID: HostID) { self.hostID = hostID }
    public mutating func pair(_ device: ClientDeviceID) { knownDevices.insert(device) }
    public mutating func setGrant(_ grant: DeviceGrant, for device: ClientDeviceID) { knownDevices.insert(device); grants[device] = grant }
    public mutating func grantStandardControl(to device: ClientDeviceID) { setGrant(.standard, for: device) }
    public mutating func revoke(device: ClientDeviceID) { grants.removeValue(forKey: device) }
    public mutating func registerCurrent(_ proof: ObservationProof) { currentProof = proof }
    public func receipt(for commandID: CommandID) -> MutationReceipt? { receipts[commandID] }

    @discardableResult
    public mutating func execute(_ command: MutationCommand) -> MutationReceipt {
        if let receipt = receipts[command.commandID] { return receipt }
        let receipt: MutationReceipt
        guard command.proof.hostID == hostID else { receipt = .rejected(.staleObservation); receipts[command.commandID] = receipt; return receipt }
        guard knownDevices.contains(command.clientDeviceID) else { receipt = .rejected(.unknownDevice); receipts[command.commandID] = receipt; return receipt }
        guard grants[command.clientDeviceID]?.permits(command.capability) == true else { receipt = .rejected(.missingGrant); receipts[command.commandID] = receipt; return receipt }
        guard currentProof == command.proof else { receipt = .rejected(.staleObservation); receipts[command.commandID] = receipt; return receipt }
        guard command.capability == .terminalControl else { receipt = .rejected(.unsupportedCapability); receipts[command.commandID] = receipt; return receipt }
        appliedCommandCount += 1
        receipt = .applied
        receipts[command.commandID] = receipt
        return receipt
    }
}
