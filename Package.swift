// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacTouch",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MacTouchCore", targets: ["MacTouchCore"]),
        .executable(name: "MacTouch", targets: ["MacTouchApp"])
    ],
    targets: [
        .target(name: "MacTouchCore"),
        .executableTarget(name: "MacTouchApp", dependencies: ["MacTouchCore"], linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("IOKit"),
            .linkedFramework("ApplicationServices"), .linkedFramework("ServiceManagement")
        ]),
        .testTarget(name: "MacTouchCoreTests", dependencies: ["MacTouchCore"]),
        .testTarget(name: "MacTouchAppTests", dependencies: ["MacTouchApp", "MacTouchCore"])
    ]
)
