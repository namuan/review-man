// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "pr-review",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PRReviewKit", targets: ["PRReviewKit"]),
        .library(name: "PRReviewDesktop", targets: ["PRReviewDesktop"]),
        .executable(name: "pr-review", targets: ["pr-review"]),
        .executable(name: "PRReviewApp", targets: ["PRReviewApp"]),
    ],
    targets: [
        .target(
            name: "PRReviewKit",
            path: "Sources/PRReviewKit"
        ),
        .executableTarget(
            name: "pr-review",
            dependencies: ["PRReviewKit"],
            path: "Sources/pr-review"
        ),
        .executableTarget(
            name: "PRReviewApp",
            dependencies: ["PRReviewKit", "PRReviewDesktop"],
            path: "PRReviewApp",
            exclude: ["Resources"],
            sources: ["App"]
        ),
        .target(
            name: "PRReviewBenchmarkSupport",
            dependencies: ["PRReviewKit"],
            path: "Sources/PRReviewBenchmarkSupport"
        ),
        .target(
            name: "PRReviewDesktop",
            dependencies: ["PRReviewKit"],
            path: "Sources/PRReviewDesktop"
        ),
        .executableTarget(
            name: "PRReviewBench",
            dependencies: ["PRReviewBenchmarkSupport", "PRReviewKit", "PRReviewDesktop"],
            path: "Sources/PRReviewBench"
        ),
        .executableTarget(
            name: "PRReviewSpike",
            dependencies: ["PRReviewBenchmarkSupport", "PRReviewKit"],
            path: "Sources/PRReviewSpike"
        ),
        .testTarget(
            name: "PRReviewKitTests",
            dependencies: ["PRReviewKit", "PRReviewBenchmarkSupport"],
            path: "Tests/PRReviewKitTests"
        ),
        .testTarget(
            name: "PRReviewDesktopTests",
            dependencies: ["PRReviewKit", "PRReviewDesktop"],
            path: "Tests/PRReviewDesktopTests"
        ),
    ]
)
