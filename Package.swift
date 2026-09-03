// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FocusGuardApple",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(name: "FocusGuardDomain", targets: ["FocusGuardDomain"]),
        .library(name: "FocusGuardSync", targets: ["FocusGuardSync"])
    ],
    targets: [
        .target(name: "FocusGuardDomain"),
        .target(name: "FocusGuardSync", dependencies: ["FocusGuardDomain"]),
        .testTarget(name: "FocusGuardDomainTests", dependencies: ["FocusGuardDomain"]),
        .testTarget(name: "FocusGuardSyncTests", dependencies: ["FocusGuardSync"])
    ]
)
