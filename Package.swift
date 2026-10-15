// swift-tools-version:5.9
// The app's platform independent logic lives in SegmentationValidator/Core and is compiled
// into the iPhone app directly. This package exposes the same files as a library so that
// the unit tests can run with `swift test` on macOS or Linux, without a simulator.
import PackageDescription

let package = Package(
    name: "SegmentationCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "SegmentationCore", targets: ["SegmentationCore"]),
    ],
    targets: [
        .target(
            name: "SegmentationCore",
            path: "SegmentationValidator/Core"
        ),
        .testTarget(
            name: "SegmentationCoreTests",
            dependencies: ["SegmentationCore"],
            path: "Tests/SegmentationCoreTests"
        ),
    ]
)
