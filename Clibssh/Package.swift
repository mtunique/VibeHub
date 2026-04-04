// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clibssh",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Clibssh", targets: ["Clibssh"]),
    ],
    targets: [
        .target(
            name: "Clibssh",
            path: "Sources/Clibssh",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .linkedLibrary("ssh", .when(platforms: [.macOS])),
                .linkedLibrary("mbedcrypto", .when(platforms: [.macOS])),
                .linkedLibrary("mbedtls", .when(platforms: [.macOS])),
                .linkedLibrary("mbedx509", .when(platforms: [.macOS])),
                .linkedLibrary("everest", .when(platforms: [.macOS])),
                .linkedLibrary("p256m", .when(platforms: [.macOS])),
                .unsafeFlags([
                    "-L\(Context.packageDirectory)/libs",
                ]),
            ]
        ),
    ]
)
