// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreOBD",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "CoreOBD", targets: ["CoreOBD"])
    ],
    targets: [
        .target(name: "CoreOBD")
    ]
)
