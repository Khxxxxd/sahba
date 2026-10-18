// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sahba",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Sahba", path: "Sources/Sahba")
    ]
)
