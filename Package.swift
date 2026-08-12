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
                // For `ghostty_info()`, which is how the app learns the version
                // of the emulator it claims to be — see `Zmx.emulatorVersion`.
                // GhosttyTerminal links this anyway, so importing it without
                // saying so happens to build; naming it is what keeps that true.
                .product(name: "GhosttyKit", package: "libghostty-spm"),
            ],
            resources: [
                .copy("Resources/icons"),
                // Ghostty's themes and terminfo, so `theme =` resolves and
                // xterm-ghostty exists on machines without Ghostty installed.
                .copy("Resources/ghostty"),
                .copy("Resources/terminfo"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
