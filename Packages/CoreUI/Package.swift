// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreUI",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "CoreUI", targets: ["CoreUI"])
    ],
    dependencies: [
        .package(path: "../CoreDomain")
    ],
    targets: [
        .target(name: "CoreUI", dependencies: ["CoreDomain"])
    ]
)
