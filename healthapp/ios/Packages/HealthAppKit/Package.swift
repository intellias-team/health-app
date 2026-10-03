// swift-tools-version: 5.10
// HealthAppKit — one library product per module. Swift 5 language mode (tools-version 5.10).
//
// Dependency rules:
// * CoreModels has no dependencies (pure value types + service protocols / "ports").
// * AnalyticsKit depends only on CoreModels.
// * CoreModels, AnalyticsKit, NutritionKit, FoodScaleKit (parsing/drivers), SyncKit (merge/engine) and MockData
//   use Foundation only; Apple-framework code is wrapped in `#if canImport(...)` so the package builds and
//   tests on Linux too.
// * Feature UI (app target) depends on the protocols in CoreModels, never on concrete adapters; the
//   composition root (`AppEnvironment`) wires concrete types.

import PackageDescription

let package = Package(
    name: "HealthAppKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CoreModels", targets: ["CoreModels"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "Networking", targets: ["Networking"]),
        .library(name: "AuthKit", targets: ["AuthKit"]),
        .library(name: "HealthKitModule", targets: ["HealthKitModule"]),
        .library(name: "OuraModule", targets: ["OuraModule"]),
        .library(name: "BodyScaleKit", targets: ["BodyScaleKit"]),
        .library(name: "FoodScaleKit", targets: ["FoodScaleKit"]),
        .library(name: "NutritionKit", targets: ["NutritionKit"]),
        .library(name: "FoodRecognitionKit", targets: ["FoodRecognitionKit"]),
        .library(name: "SyncKit", targets: ["SyncKit"]),
        .library(name: "AnalyticsKit", targets: ["AnalyticsKit"]),
        .library(name: "NotificationsKit", targets: ["NotificationsKit"]),
        .library(name: "MockData", targets: ["MockData"]),
    ],
    targets: [
        .target(name: "CoreModels", dependencies: []),
        .target(name: "AnalyticsKit", dependencies: ["CoreModels"]),
        .target(name: "Networking", dependencies: ["CoreModels"]),
        .target(name: "NutritionKit", dependencies: ["CoreModels", "Networking"]),
        .target(name: "FoodScaleKit", dependencies: []),
        .target(name: "DesignSystem", dependencies: ["CoreModels"]),
        .target(name: "AuthKit", dependencies: ["CoreModels"]),
        .target(name: "HealthKitModule", dependencies: ["CoreModels"]),
        .target(name: "OuraModule", dependencies: ["CoreModels", "Networking", "AuthKit"]),
        .target(name: "BodyScaleKit", dependencies: ["CoreModels", "FoodScaleKit"]),
        .target(name: "FoodRecognitionKit", dependencies: ["CoreModels", "Networking", "NutritionKit"]),
        .target(name: "SyncKit", dependencies: ["CoreModels", "Networking", "AnalyticsKit"]),
        .target(name: "NotificationsKit", dependencies: ["CoreModels"]),
        .target(name: "MockData", dependencies: ["CoreModels", "AnalyticsKit", "NutritionKit"]),

        .testTarget(name: "CoreModelsTests", dependencies: ["CoreModels"]),
        .testTarget(name: "AnalyticsKitTests", dependencies: ["AnalyticsKit", "CoreModels", "MockData"]),
        .testTarget(name: "NutritionKitTests", dependencies: ["NutritionKit", "CoreModels"]),
        .testTarget(name: "FoodScaleKitTests", dependencies: ["FoodScaleKit"]),
        .testTarget(name: "SyncKitTests", dependencies: ["SyncKit", "CoreModels", "Networking"]),
    ]
)
