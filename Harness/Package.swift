// swift-tools-version: 5.9
import PackageDescription

// Executable that links the LoopKit submodule and emits reference fixtures.
//
// LoopKit's own manifest declares `platforms: [.iOS("15.0")]`, so SwiftPM will
// not build it for a macOS executable as-is. The CI workflow patches
// `.macOS("13.0")` onto that manifest at build time only (the submodule stays
// pristine in git); HealthKit — which LoopKit uses pervasively — is available
// on macOS 13+, and the core `LoopKit` target has no package dependencies.
let package = Package(
    name: "Harness",
    platforms: [.macOS("13.0")],
    dependencies: [
        .package(path: "../LoopWorkspace/LoopKit"),
    ],
    targets: [
        .executableTarget(
            name: "Harness",
            dependencies: [
                .product(name: "LoopKit", package: "LoopKit"),
            ],
            path: "Sources/Harness"
        ),
    ]
)
