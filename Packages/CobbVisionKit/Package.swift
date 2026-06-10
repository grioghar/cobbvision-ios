// swift-tools-version: 5.10
import PackageDescription

// CobbVisionKit — all app logic lives here so it can be unit-tested on the CI
// macOS host (`swift test`) without booting a simulator. CVCore is platform-pure
// and also builds with the Swift toolchain on Windows for fast local feedback.
// iOS-only modules guard their Apple-framework code with `#if os(iOS)` so the
// package still compiles for macOS hosts (the guarded modules become empty).
let package = Package(
    name: "CobbVisionKit",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CVCore", targets: ["CVCore"]),
        .library(name: "CVAPI", targets: ["CVAPI"]),
        .library(name: "CVTelemetry", targets: ["CVTelemetry"]),
        .library(name: "CVCapture", targets: ["CVCapture"]),
        .library(name: "CVStreaming", targets: ["CVStreaming"]),
        .library(name: "CVExternalCam", targets: ["CVExternalCam"]),
        .library(name: "CVSession", targets: ["CVSession"]),
        .library(name: "CVWatchBridge", targets: ["CVWatchBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/HaishinKit/HaishinKit.swift", from: "2.0.0"),
    ],
    targets: [
        .target(name: "CVCore"),
        .target(name: "CVAPI", dependencies: ["CVCore"]),
        .target(name: "CVTelemetry", dependencies: ["CVCore"]),
        .target(name: "CVCapture", dependencies: ["CVCore"]),
        .target(
            name: "CVStreaming",
            dependencies: [
                "CVCore",
                "CVCapture",
                .product(name: "HaishinKit", package: "HaishinKit.swift", condition: .when(platforms: [.iOS])),
                .product(name: "SRTHaishinKit", package: "HaishinKit.swift", condition: .when(platforms: [.iOS])),
            ]
        ),
        .target(name: "CVExternalCam", dependencies: ["CVCore"]),
        .target(
            name: "CVSession",
            dependencies: ["CVCore", "CVAPI", "CVTelemetry", "CVCapture", "CVStreaming", "CVExternalCam"]
        ),
        .target(name: "CVWatchBridge", dependencies: ["CVCore"]),
        .testTarget(name: "CVCoreTests", dependencies: ["CVCore"]),
        .testTarget(name: "CVTelemetryTests", dependencies: ["CVTelemetry"]),
        .testTarget(name: "CVCaptureTests", dependencies: ["CVCapture"]),
        .testTarget(name: "CVAPITests", dependencies: ["CVAPI"]),
        .testTarget(
            name: "CVSessionTests",
            dependencies: ["CVSession", "CVCore", "CVAPI", "CVTelemetry", "CVCapture", "CVStreaming", "CVExternalCam"]
        ),
        .testTarget(name: "CVExternalCamTests", dependencies: ["CVExternalCam"]),
    ]
)
