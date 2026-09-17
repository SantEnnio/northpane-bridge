import Foundation
import NorthpaneProjection
import NorthpaneProtocol

public struct TerminalAttachmentID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public enum ControlLeaseState: Equatable, Sendable { case available, ownedHere, ownedElsewhere, unknown }
public enum TerminalError: Error, Equatable, Sendable { case staleObservation, attachmentNotFound, leaseOwnedElsewhere, leaseRequired, sequenceGap, invalidTakeover }

public struct TerminalAttachment: Equatable, Sendable {
    public let id: TerminalAttachmentID
    public let connectionID: ConnectionID
    public let paneID: String
    public let deviceID: ClientDeviceID
    public let proof: ObservationProof
    public fileprivate(set) var acceptedThroughSequence: Int
}

public struct TerminalCoordinator: Sendable {
    private var currentProof: ObservationProof?
    private var attachments: [TerminalAttachmentID: TerminalAttachment] = [:]
    private var leaseOwner: TerminalAttachmentID?
    public private(set) var deliveredInput: [Data] = []

    public init() {}

    public mutating func registerCurrent(_ proof: ObservationProof) {
        guard currentProof == proof else {
            attachments.removeAll(); leaseOwner = nil; deliveredInput.removeAll()
            currentProof = proof
            return
        }
    }

    public mutating func invalidate() {
        currentProof = nil; attachments.removeAll(); leaseOwner = nil; deliveredInput.removeAll()
    }

    public mutating func attach(connectionID: ConnectionID, paneID: String, deviceID: ClientDeviceID, proof: ObservationProof) throws -> TerminalAttachment {
        guard currentProof == proof else { throw TerminalError.staleObservation }
        let attachment = TerminalAttachment(id: TerminalAttachmentID(), connectionID: connectionID, paneID: paneID, deviceID: deviceID, proof: proof, acceptedThroughSequence: -1)
        attachments[attachment.id] = attachment
        return attachment
    }

    public func leaseState(for attachmentID: TerminalAttachmentID) -> ControlLeaseState {
        guard currentProof != nil, attachments[attachmentID] != nil else { return .unknown }
        guard let leaseOwner else { return .available }
        return leaseOwner == attachmentID ? .ownedHere : .ownedElsewhere
    }

    public mutating func acquire(_ attachmentID: TerminalAttachmentID, proof: ObservationProof) throws {
        try validate(attachmentID, proof: proof)
        guard leaseOwner == nil || leaseOwner == attachmentID else { throw TerminalError.leaseOwnedElsewhere }
        leaseOwner = attachmentID
    }

    public mutating func release(_ attachmentID: TerminalAttachmentID, proof: ObservationProof) throws {
        try validate(attachmentID, proof: proof)
        guard leaseOwner == attachmentID else { throw TerminalError.leaseRequired }
        leaseOwner = nil
    }

    public mutating func takeover(_ attachmentID: TerminalAttachmentID, proof: ObservationProof, confirmed: Bool) throws {
        try validate(attachmentID, proof: proof)
        guard confirmed, leaseOwner != attachmentID else { throw TerminalError.invalidTakeover }
        leaseOwner = attachmentID
    }

    @discardableResult
    public mutating func acceptInput(_ frame: TerminalInputFrame, proof: ObservationProof) throws -> TerminalInputAcknowledgement {
        let id = TerminalAttachmentID(rawValue: frame.attachmentID)
        try validate(id, proof: proof)
        guard leaseOwner == id else { throw TerminalError.leaseRequired }
        guard var attachment = attachments[id] else { throw TerminalError.attachmentNotFound }
        if frame.sequence <= attachment.acceptedThroughSequence {
            return .init(attachmentID: frame.attachmentID, acceptedThroughSequence: attachment.acceptedThroughSequence)
        }
        guard frame.sequence == attachment.acceptedThroughSequence + 1 else { throw TerminalError.sequenceGap }
        deliveredInput.append(frame.bytes)
        attachment.acceptedThroughSequence = frame.sequence
        attachments[id] = attachment
        return .init(attachmentID: frame.attachmentID, acceptedThroughSequence: frame.sequence)
    }

    private func validate(_ attachmentID: TerminalAttachmentID, proof: ObservationProof) throws {
        guard currentProof == proof else { throw TerminalError.staleObservation }
        guard let attachment = attachments[attachmentID] else { throw TerminalError.attachmentNotFound }
        guard attachment.proof == proof else { throw TerminalError.staleObservation }
    }
}

/// Where a scroll goes. Herdr streams a rendered viewport, never raw output, so scrolling a pane is
/// normally something the Host does to the scrollback it keeps — but a pane whose app draws on the
/// alternate screen owns the whole screen, Herdr keeps nothing above it, and the `terminal.scroll`
/// it would be sent is dropped without a word. Such an app scrolls itself, through the mouse it
/// asked for (OpenCode does; Codex and Claude Code ask for no mouse at all and write their
/// transcript into the normal buffer, where Herdr's scrollback is exactly right).
///
/// Nothing here guesses which app is running: Herdr says how many lines it is holding, and holding
/// none is the whole signal. The agent test is the guard on the other side — wheel bytes typed at a
/// shell are rubbish on its command line, so a pane running no agent keeps paging the Host even
/// while there is nothing up there yet.
public enum TerminalScrollRouting: Equatable, Sendable {
    case hostScrollback
    case paneWheel

    public static func choose(heldOnHost: Int, paneRunsAnAgent: Bool) -> TerminalScrollRouting {
        heldOnHost <= 0 && paneRunsAnAgent ? .paneWheel : .hostScrollback
    }

    /// One SGR wheel event per line, at the middle of the viewport, capped at a screenful so a
    /// flick arrives as a handful of events rather than a burst the Bridge has to order.
    public static func wheel(_ direction: TerminalScrollDirection, lines: Int, columns: Int, rows: Int) -> Data {
        let button = direction == .up ? 64 : 65
        let column = max(1, columns / 2), row = max(1, rows / 2)
        let event = "\u{1b}[<\(button);\(column);\(row)M"
        return Data(String(repeating: event, count: min(max(1, lines), 20)).utf8)
    }
}
