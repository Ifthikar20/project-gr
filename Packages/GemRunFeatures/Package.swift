// swift-tools-version: 5.9
import PackageDescription

// Umbrella package for feature modules (docs/07): one target per docs/03 area.
// Features depend on Core products only — never on each other. Cross-feature
// presentation (start run, create route) goes through SessionStore triggers.
let package = Package(
    name: "GemRunFeatures",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "FeatureOnboarding", targets: ["FeatureOnboarding"]),
        .library(name: "FeatureExplore", targets: ["FeatureExplore"]),
        .library(name: "FeatureRouteCreation", targets: ["FeatureRouteCreation"]),
        .library(name: "FeatureActiveRun", targets: ["FeatureActiveRun"]),
        .library(name: "FeatureStash", targets: ["FeatureStash"]),
        .library(name: "FeatureCompete", targets: ["FeatureCompete"]),
        .library(name: "FeatureProfile", targets: ["FeatureProfile"]),
    ],
    dependencies: [
        .package(path: "../GemRunCore"),
    ],
    targets: [
        .target(name: "FeatureOnboarding", dependencies: [
            .product(name: "CoreModels", package: "GemRunCore"),
            .product(name: "DesignSystem", package: "GemRunCore"),
            .product(name: "CorePersistence", package: "GemRunCore"),
        ]),
        .target(name: "FeatureExplore", dependencies: [
            .product(name: "CoreModels", package: "GemRunCore"),
            .product(name: "DesignSystem", package: "GemRunCore"),
            .product(name: "CoreMap", package: "GemRunCore"),
            .product(name: "CorePersistence", package: "GemRunCore"),
            .product(name: "CoreNetworking", package: "GemRunCore"),
            .product(name: "GameKitCore", package: "GemRunCore"),
        ]),
        .target(name: "FeatureRouteCreation", dependencies: [
            .product(name: "CoreModels", package: "GemRunCore"),
            .product(name: "DesignSystem", package: "GemRunCore"),
            .product(name: "CoreMap", package: "GemRunCore"),
            .product(name: "GameKitCore", package: "GemRunCore"),
            .product(name: "CorePersistence", package: "GemRunCore"),
            .product(name: "CoreNetworking", package: "GemRunCore"),
        ]),
        .target(name: "FeatureActiveRun", dependencies: [
            .product(name: "CoreModels", package: "GemRunCore"),
            .product(name: "DesignSystem", package: "GemRunCore"),
            .product(name: "CoreMap", package: "GemRunCore"),
            .product(name: "CoreLocationKit", package: "GemRunCore"),
            .product(name: "GameKitCore", package: "GemRunCore"),
            .product(name: "CorePersistence", package: "GemRunCore"),
        ]),
        .target(name: "FeatureStash", dependencies: [
            .product(name: "CoreModels", package: "GemRunCore"),
            .product(name: "DesignSystem", package: "GemRunCore"),
            .product(name: "CorePersistence", package: "GemRunCore"),
        ]),
        .target(name: "FeatureCompete", dependencies: [
            .product(name: "CoreModels", package: "GemRunCore"),
            .product(name: "DesignSystem", package: "GemRunCore"),
            .product(name: "CorePersistence", package: "GemRunCore"),
            .product(name: "CoreNetworking", package: "GemRunCore"),
        ]),
        .target(name: "FeatureProfile", dependencies: [
            .product(name: "CoreModels", package: "GemRunCore"),
            .product(name: "DesignSystem", package: "GemRunCore"),
            .product(name: "CorePersistence", package: "GemRunCore"),
        ]),
    ]
)
