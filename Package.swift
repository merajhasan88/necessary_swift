// swift-tools-version: 5.9
// Necessary: device integrity for iOS apps. The library has no dependencies; its tests read the
// shared vectors and the measurement contract from this repository.
import PackageDescription

let package = Package(
    name: "Necessary",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(name: "Necessary", targets: ["Necessary"])
    ],
    targets: [
        .target(
            name: "Necessary",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "NecessaryTests",
            dependencies: ["Necessary"]
        ),
    ]
)
