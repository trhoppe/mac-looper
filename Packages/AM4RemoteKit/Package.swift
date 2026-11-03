// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AM4RemoteKit",
    platforms: [.macOS(.v14), .iOS("18.0")],
    products: [.library(name: "AM4RemoteKit", targets: ["AM4RemoteKit"])],
    targets: [
        .target(name: "AM4RemoteKit", resources: [.process("Resources")],
                linkerSettings: [.linkedFramework("CoreMIDI")]),
        .testTarget(name: "AM4RemoteKitTests", dependencies: ["AM4RemoteKit"], resources: [.process("Fixtures")])
    ]
)
