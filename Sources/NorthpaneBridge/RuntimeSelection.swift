import Foundation
import NorthpaneHostRuntime
import NorthpaneHerdrIntegration
import NorthpaneNativeRuntime
import NorthpaneProtocol

/// Selection is based on installation, never on a transient Herdr error. The
/// chosen adapter owns all later operations; no fallback can change its scope.
struct RuntimeSelection: Equatable, Sendable {
    let kind: RuntimeKind
    let herdrExecutable: URL?

    static func resolve(environment: [String: String], homeDirectory: String,
                        nativeSupported: Bool = supportsNative,
                        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) throws -> Self {
        let requested = environment["NORTHPANE_RUNTIME"] ?? ""
        guard ["", "herdr", "native"].contains(requested) else {
            throw NativeSelectionError.invalidOverride
        }
        if requested == "native" {
            guard nativeSupported else { throw NativeSelectionError.unsupportedPlatform }
            return .init(kind: .native, herdrExecutable: nil)
        }
        let path = HerdrProcessRunner.resolveExecutable(environment: environment,
            homeDirectory: homeDirectory, isExecutable: isExecutable)
        if let path { return .init(kind: .herdr, herdrExecutable: URL(fileURLWithPath: path)) }
        if requested == "herdr" || !nativeSupported { throw HerdrRuntimeError.executableUnavailable }
        return .init(kind: .native, herdrExecutable: nil)
    }

    func makeRuntime(stateDirectory: URL, hostID: HostID, executableURL: URL,
                     sessionName: String?, incarnationID: String) throws -> any HostRuntime {
        switch kind {
        case .herdr:
            return try HerdrHostRuntime(executableURL: herdrExecutable, sessionName: sessionName, incarnationID: incarnationID)
        case .native:
            #if os(macOS) || os(Linux)
            guard sessionName == nil || sessionName?.isEmpty == true else { throw NativeSelectionError.namedSessionRequiresHerdr }
            return NativeHostRuntime(stateDirectory: stateDirectory, hostID: hostID, executableURL: executableURL)
            #else
            throw NativeSelectionError.unsupportedPlatform
            #endif
        }
    }
    static var supportsNative: Bool {
        #if os(macOS) || os(Linux)
        true
        #else
        false
        #endif
    }
}

enum NativeSelectionError: Error, Equatable {
    case invalidOverride
    case unsupportedPlatform
    case namedSessionRequiresHerdr
}
