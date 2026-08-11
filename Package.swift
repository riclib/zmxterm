// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "zmxterm",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.3.2"),
    ],
    targets: [
        .executableTarget(
            name: "zmxterm",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ],
            resources: [.copy("Resources/icons")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
