// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacPulse",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacPulse", targets: ["MacPulse"])
    ],
    targets: [
        .executableTarget(
            name: "MacPulse",
            path: "MyApp",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "MacPulseTests",
            dependencies: ["MacPulse"],
            path: "MyAppTests"
        )
    ]
)
