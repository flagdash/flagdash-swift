// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FlagDash",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "FlagDash", targets: ["FlagDash"])],
    targets: [
        .target(name: "FlagDash"),
        .testTarget(name: "FlagDashTests", dependencies: ["FlagDash"])
    ]
)
