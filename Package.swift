// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "northpane-bridge",
    defaultLocalization: "en",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "NorthpaneProtocol", targets: ["NorthpaneProtocol"]),
        .library(name: "NorthpaneProjection", targets: ["NorthpaneProjection"]),
        .library(name: "NorthpaneBridgeCore", targets: ["NorthpaneBridgeCore"]),
        .library(name: "NorthpaneHerdrIntegration", targets: ["NorthpaneHerdrIntegration"]),
        .library(name: "NorthpaneHostRuntime", targets: ["NorthpaneHostRuntime"]),
        .library(name: "NorthpaneNativeRuntime", targets: ["NorthpaneNativeRuntime"]),
        .library(name: "NorthpaneSecurity", targets: ["NorthpaneSecurity"]),
        .library(name: "NorthpaneBridgeResources", targets: ["NorthpaneBridgeResources"]),
        .library(name: "NorthpaneDiagnostics", targets: ["NorthpaneDiagnostics"]),
        .library(name: "NorthpaneConnection", targets: ["NorthpaneConnection"]),
        .executable(name: "northpane-bridge", targets: ["NorthpaneBridge"]),
        .executable(name: "northpane", targets: ["NorthpaneCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.1"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.102.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", exact: "0.15.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.4"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.15.0"),
    ],
    targets: [
        .target(name: "NorthpaneProtocol", dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]),
        .target(name: "NorthpaneProjection", dependencies: ["NorthpaneProtocol"]),
        .target(name: "NorthpaneBridgeCore", dependencies: ["NorthpaneProtocol", "NorthpaneProjection", "NorthpaneSecurity"]),
        .target(name: "NorthpaneHostRuntime", dependencies: ["NorthpaneProtocol"]),
        .target(name: "NorthpanePTY", linkerSettings: [.linkedLibrary("util", .when(platforms: [.linux]))]),
        .target(name: "NorthpaneNativeRuntime", dependencies: [
            "NorthpaneHostRuntime", .product(name: "SwiftTerm", package: "SwiftTerm"),
            .target(name: "NorthpanePTY", condition: .when(platforms: [.macOS, .linux])),
        ]),
        .target(name: "NorthpaneHerdrIntegration", dependencies: ["NorthpaneProtocol", "NorthpaneProjection", "NorthpaneHostRuntime"]),
        .target(name: "NorthpaneSecurity", dependencies: ["NorthpaneProtocol", .product(name: "Crypto", package: "swift-crypto")], linkerSettings: [.linkedFramework("Security", .when(platforms: [.iOS, .macOS]))]),
        .target(name: "NorthpaneBridgeResources", dependencies: ["NorthpaneProtocol", "NorthpaneProjection", "NorthpaneSecurity", .product(name: "Crypto", package: "swift-crypto")]),
        .target(name: "NorthpaneConnection", dependencies: [
            "NorthpaneProtocol", "NorthpaneProjection", "NorthpaneSecurity",
            .product(name: "Crypto", package: "swift-crypto"),
            // The native SSH client on iOS; on the Mac the relay that carries a device's own SSH
            // session to a Host (and the same client, for the relay's tests).
            .product(name: "NIOCore", package: "swift-nio", condition: .when(platforms: [.iOS, .macOS])),
            .product(name: "NIOPosix", package: "swift-nio", condition: .when(platforms: [.iOS, .macOS])),
            .product(name: "NIOSSH", package: "swift-nio-ssh", condition: .when(platforms: [.iOS, .macOS])),
        ]),
        .target(name: "NorthpaneDiagnostics", dependencies: ["NorthpaneProtocol", .product(name: "Crypto", package: "swift-crypto")]),
        .executableTarget(name: "NorthpaneBridge", dependencies: [
            "NorthpaneProtocol", "NorthpaneProjection", "NorthpaneBridgeCore", "NorthpaneBridgeResources", "NorthpaneConnection", "NorthpaneDiagnostics", "NorthpaneHerdrIntegration", "NorthpaneHostRuntime", "NorthpaneNativeRuntime", "NorthpaneSecurity",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
            // swift-nio-ssl does not build on Windows: a Windows Host has no Private Bridge endpoint and is reached over SSH.
            .product(name: "NIOSSL", package: "swift-nio-ssl", condition: .when(platforms: [.macOS, .linux])),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .executableTarget(name: "NorthpaneCLI", dependencies: ["NorthpaneProtocol", "NorthpaneConnection"]),
        .testTarget(name: "NorthpaneProtocolTests", dependencies: ["NorthpaneProtocol"], resources: [.copy("Fixtures")]),
        .testTarget(name: "NorthpaneProjectionTests", dependencies: ["NorthpaneProjection"]),
        .testTarget(name: "NorthpaneBridgeCoreTests", dependencies: ["NorthpaneBridgeCore"]),
        .testTarget(name: "NorthpaneHerdrIntegrationTests", dependencies: ["NorthpaneHerdrIntegration"]),
        .testTarget(name: "NorthpaneNativeRuntimeTests", dependencies: ["NorthpaneNativeRuntime", .product(name: "SwiftTerm", package: "SwiftTerm")], resources: [.copy("Fixtures")]),
        .testTarget(name: "NorthpaneBridgeTests", dependencies: ["NorthpaneBridge", "NorthpaneHostRuntime", "NorthpaneHerdrIntegration", "NorthpaneConnection", "NorthpaneSecurity"]),
        .testTarget(name: "NorthpaneSecurityTests", dependencies: ["NorthpaneSecurity"]),
        .testTarget(name: "NorthpaneBridgeResourcesTests", dependencies: ["NorthpaneBridgeResources"]),
        .testTarget(name: "NorthpaneDiagnosticsTests", dependencies: ["NorthpaneDiagnostics"]),
        .testTarget(name: "NorthpaneConnectionTests", dependencies: [
            "NorthpaneConnection", "NorthpaneSecurity", .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "NIOCore", package: "swift-nio", condition: .when(platforms: [.macOS])),
            .product(name: "NIOPosix", package: "swift-nio", condition: .when(platforms: [.macOS])),
            .product(name: "NIOSSH", package: "swift-nio-ssh", condition: .when(platforms: [.macOS])),
        ]),
    ]
)
