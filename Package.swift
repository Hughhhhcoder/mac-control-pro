// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacControlPro",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacControlPro", targets: ["MacControlPro"]),
        .executable(name: "MacControlHelper", targets: ["MacControlHelper"]),
        .library(name: "MacControlCore", targets: ["MacControlCore"])
    ],
    targets: [
        .target(name: "CSMC", publicHeadersPath: "include", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "MacControlCore", dependencies: ["CSMC"], linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "MacControlPro", dependencies: ["MacControlCore"], linkerSettings: [.linkedFramework("SwiftUI"), .linkedFramework("Charts"), .linkedFramework("ServiceManagement")]),
        .executableTarget(name: "MacControlHelper", dependencies: ["MacControlCore"]),
        .testTarget(name: "MacControlCoreTests", dependencies: ["MacControlCore"])
    ]
)
