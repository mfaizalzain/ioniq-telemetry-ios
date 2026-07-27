// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreDomain",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CoreDomain", targets: ["CoreDomain"])
    ],
    targets: [
        .target(name: "CoreDomain"),
        .testTarget(name: "CoreDomainTests", dependencies: ["CoreDomain"])
    ]
)
