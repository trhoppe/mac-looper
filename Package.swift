// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacLooper",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacLooper", targets: ["MacLooper"])],
    targets: [
        .target(name: "LooperCore", publicHeadersPath: "include", linkerSettings: [
            .linkedFramework("AudioToolbox"), .linkedFramework("CoreAudio")
        ]),
        .executableTarget(name: "MacLooper", dependencies: ["LooperCore"], linkerSettings: [
            .linkedFramework("SwiftUI"), .linkedFramework("AVFoundation")
        ]),
        .testTarget(name: "LooperCoreTests", dependencies: ["LooperCore"])
    ]
)
