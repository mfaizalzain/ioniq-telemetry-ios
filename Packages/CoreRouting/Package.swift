// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreRouting",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "CoreRouting", targets: ["CoreRouting"])
    ],
    dependencies: [
        .package(path: "../CoreDomain")
    ],
    targets: [
        .target(name: "CoreRouting", dependencies: ["CoreDomain"])
    ]
)
