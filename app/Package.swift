// swift-tools-version:6.0
import PackageDescription

// Celeritas is built with SwiftPM rather than an Xcode project, so `swift build`
// works with only the Command Line Tools. Scripts/build-app.sh assembles the .app
// around the binary.
//
// The split is the one rule worth keeping from the projects we read: CeleritasKit
// holds everything that is pure Foundation, so it compiles and runs without a
// window server. Celeritas holds only what genuinely needs AppKit, SwiftUI or
// Carbon. Nothing in CeleritasKit may import a UI framework.
let package = Package(
    name: "Celeritas",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Celeritas", targets: ["Celeritas"]),
        .library(name: "CeleritasKit", targets: ["CeleritasKit"]),
    ],
    targets: [
        .target(name: "CeleritasKit", resources: [.process("Resources")]),
        .executableTarget(name: "Celeritas", dependencies: ["CeleritasKit"]),
        // Apple Intelligence behind an OpenAI-shaped endpoint, so the Python
        // benchmark scores it with the same tasks and verifiers as everything else.
        .executableTarget(name: "AppleShim", dependencies: ["CeleritasKit"]),
        // Not a .testTarget: XCTest does not ship with the Command Line Tools, so
        // `swift test` would need a full Xcode. The suite is an executable instead.
        .executableTarget(name: "CeleritasKitTests", dependencies: ["CeleritasKit"]),
    ]
)
