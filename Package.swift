// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SkitchRedux",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SkitchRedux",
            path: "Sources/SkitchRedux"
        )
    ]
)
