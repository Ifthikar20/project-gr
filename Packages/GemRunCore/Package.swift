// swift-tools-version: 5.9
import PackageDescription

// Umbrella package for all Core modules (docs/07). One target per module keeps
// the dependency graph enforced without a manifest per package.
let package = Package(
    name: "GemRunCore",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "CoreModels", targets: ["CoreModels"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "CoreNetworking", targets: ["CoreNetworking"]),
        .library(name: "CorePersistence", targets: ["CorePersistence"]),
        .library(name: "CoreAuth", targets: ["CoreAuth"]),
        .library(name: "CoreLocationKit", targets: ["CoreLocationKit"]),
        .library(name: "CoreMap", targets: ["CoreMap"]),
        .library(name: "GameKitCore", targets: ["GameKitCore"]),
    ],
    targets: [
        // Pure domain types — no dependencies, compiles anywhere.
        .target(name: "CoreModels"),
        .target(name: "DesignSystem", dependencies: ["CoreModels"]),
        .target(name: "CoreNetworking", dependencies: ["CoreModels", "GameKitCore"]),
        .target(name: "CorePersistence",
                dependencies: ["CoreModels", "GameKitCore", "CoreNetworking"]),
        // The auth service (docs/18): provider credential handling, guest
        // identity, server registration, token persistence, launch restore.
        // Sits above persistence + networking so neither of them — and no
        // feature — carries identity logic of its own.
        .target(name: "CoreAuth",
                dependencies: ["CoreModels", "CoreNetworking", "CorePersistence"]),
        .target(name: "CoreLocationKit", dependencies: ["CoreModels", "GameKitCore"]),
        .target(name: "CoreMap", dependencies: ["CoreModels"]),
        // Pure game logic — no UI/IO. The most heavily tested module.
        .target(name: "GameKitCore", dependencies: ["CoreModels"]),
        .testTarget(name: "GameKitCoreTests",
                    dependencies: ["GameKitCore", "CoreModels"]),
    ]
)
