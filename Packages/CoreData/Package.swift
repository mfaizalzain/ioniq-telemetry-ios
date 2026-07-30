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
            dependencies: ["CoreData"],
            // The golden backup fixture is byte-identical to the copy in the Android
            // repo's core-data test resources; both suites decode it so the shared
            // format cannot drift on one platform without a test failing.
            resources: [.copy("Fixtures")]
        )
    ]
)
