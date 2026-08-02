// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "pr-review",
    platforms: [.macOS(.v13)],
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
        .testTarget(
            name: "PRReviewKitTests",
            dependencies: ["PRReviewKit"],
            path: "Tests/PRReviewKitTests"
        ),
    ]
)
