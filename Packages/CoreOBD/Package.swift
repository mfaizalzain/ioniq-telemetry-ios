// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreOBD",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "CoreOBD", targets: ["CoreOBD"])
    ],
    dependencies: [
        .package(path: "../CoreDomain")
    ],
    targets: [
        .target(name: "CoreOBD", dependencies: ["CoreDomain"])
    ]
)
