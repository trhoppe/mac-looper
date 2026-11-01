// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacLooper",
    platforms: [.macOS(.v14), .iOS("18.0")],
    products: [
        .executable(name: "MacLooper", targets: ["MacLooper"]),
        .library(name: "JamCore", targets: ["JamCore"]),
        .library(name: "LooperCore", targets: ["LooperCore"]),
        .library(name: "LooperAudioUnit", targets: ["LooperAudioUnit"])
    ],
    targets: [
        .target(name: "LooperCore", publicHeadersPath: "include", linkerSettings: [
            .linkedFramework("AudioToolbox"), .linkedFramework("CoreAudio", .when(platforms: [.macOS]))
        ]),
        .target(name: "JamCore"),
        .target(name: "LooperAudioUnit", dependencies: ["LooperCore"], publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("AudioToolbox")]),
        .executableTarget(name: "MacLooper", dependencies: ["LooperCore", "LooperAudioUnit", "JamCore"], linkerSettings: [
            .linkedFramework("SwiftUI"), .linkedFramework("AVFoundation")
        ]),
        .testTarget(name: "LooperCoreTests", dependencies: ["LooperCore", "LooperAudioUnit"]),
        .testTarget(name: "MacLooperTests", dependencies: ["MacLooper"]),
        .testTarget(name: "JamCoreTests", dependencies: ["JamCore"])
    ]
)
