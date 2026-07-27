// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreDomain",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "CoreDomain", targets: ["CoreDomain"])
    ],
    targets: [
        .target(name: "CoreDomain")
    ]
)
