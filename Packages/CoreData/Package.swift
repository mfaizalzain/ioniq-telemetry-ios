// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreData",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CoreData", targets: ["CoreData"])
    ],
    dependencies: [
        .package(path: "../CoreDomain")
    ],
    targets: [
        .target(
            name: "CoreData",
            dependencies: ["CoreDomain"],
            linkerSettings: [.linkedFramework("MapKit")]
        ),
        .testTarget(
            name: "CoreDataTests",
            dependencies: ["CoreData"]
        )
    ]
)
