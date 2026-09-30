// swift-tools-version: 6.2
import PackageDescription

let strictCore: [SwiftSetting] = [
    .defaultIsolation(nil)
]

let package = Package(
    name: "directa",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "directa", targets: ["directa"]),
        .executable(name: "ddirecta", targets: ["ddirecta"]),
        .executable(name: "DirectaApp", targets: ["DirectaApp"]),
        .executable(name: "fixture-server", targets: ["fixture-server"]),
        .library(name: "DirectaKit", targets: ["DirectaKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.0"),
        /** Pre-1.0: pinned to the exact commit of tag 0.5 (the tag is not full semver, so a
            revision pin is the strictest available). Isolated behind ProcessLauncher. */
        .package(url: "https://github.com/swiftlang/swift-subprocess", revision: "11633673a41f509f8945f23c96c7acd4adafd679"),
    ],
    targets: [
        .target(
            name: "DirectaKit",
            swiftSettings: strictCore
        ),
        .target(
            name: "DirectaDaemonCore",
            dependencies: [
                "DirectaKit",
                .product(name: "Subprocess", package: "swift-subprocess"),
            ],
            swiftSettings: strictCore
        ),
        .executableTarget(
            name: "ddirecta",
            dependencies: ["DirectaDaemonCore", "DirectaKit"],
            exclude: ["Info.plist"],
            swiftSettings: strictCore,
            linkerSettings: [
                /** Embedded Info.plist for the helper Mach-O identity. Login
                    Items naming for the app install path comes from
                    SMAppService + the responsible app, not this section. */
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Sources/ddirecta/Info.plist",
                ])
            ]
        ),
        .executableTarget(
            name: "directa",
            dependencies: [
                "DirectaKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strictCore
        ),
        .executableTarget(
            name: "DirectaApp",
            dependencies: ["DirectaKit"],
            swiftSettings: [
                .defaultIsolation(MainActor.self)
            ]
        ),
        .executableTarget(
            name: "fixture-server",
            swiftSettings: strictCore
        ),
        /** Test-only helpers shared by every test target (the scoped temporary
            tree). Depended on by test targets alone, so no product links it. */
        .target(
            name: "DirectaTestSupport",
            path: "Tests/DirectaTestSupport",
            swiftSettings: strictCore
        ),
        .testTarget(
            name: "DirectaKitTests",
            dependencies: ["DirectaKit", "DirectaTestSupport"]
        ),
        .testTarget(
            name: "DirectaDaemonCoreTests",
            dependencies: ["DirectaDaemonCore", "DirectaKit", "DirectaTestSupport"]
        ),
        /** The CLI's argument parsing is behavior with a contract (docs/cli-contract.md)
            and no other way to exercise it: a parse defect there silently changes
            what a guarded command receives. */
        .testTarget(
            name: "DirectaCLITests",
            dependencies: [
                "DirectaKit",
                "DirectaTestSupport",
                "directa",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
