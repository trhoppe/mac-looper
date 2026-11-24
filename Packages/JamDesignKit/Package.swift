// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "JamDesignKit", platforms: [.macOS(.v14), .iOS("18.0")],
    products: [.library(name: "JamDesignKit", targets: ["JamDesignKit"])],
    targets: [.target(name: "JamDesignKit")])
