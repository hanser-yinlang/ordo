// swift-tools-version: 6.0
//
//  Package.swift
//  Ordo( iOS 端)—— 以 Swift Package 方式声明对 KMP 二进制核心的依赖。
//
//  依赖关系:
//    OrdoCore(XCFramework,由 `./gradlew :shared:core:assembleXCFramework` 生成)
//      └── OrdoKit(本目录下的 Ordo/,纯 SwiftUI + SwiftData,不包含任何业务规则)
//            └── OrdoTests(XCTest,覆盖契约 §4 / §5 / §6 / §7.3)
//
//  使用前必须先生成 XCFramework(详见 README「在 macOS 上构建」):
//    cd <repo>/shared/core
//    ./gradlew :shared:core:assembleXCFramework
//
//  XCFramework 位置可用环境变量覆盖(便于 CI 或自定义产物目录):
//    ORDO_CORE_XCFRAMEWORK=/abs/path/OrdoCore.xcframework swift build
//

import PackageDescription
import Foundation

/// 默认产物路径(Kotlin Multiplatform 的标准输出:shared/core/build/XCFrameworks/release/)。
let defaultCorePath = "../../shared/core/build/XCFrameworks/release/OrdoCore.xcframework"

/// 允许通过环境变量覆盖,便于 CI 或多架构产物目录。
let corePath = ProcessInfo.processInfo.environment["ORDO_CORE_XCFRAMEWORK"] ?? defaultCorePath

let package = Package(
    name: "Ordo",
    defaultLocalization: "zh-Hans",
    platforms: [
        // SwiftData 与 @Observable 需要 iOS 17;契约 §7 写「iOS 16+」,
        // 这一处偏差已在 README「已知偏差」中说明。
        .iOS(.v17)
    ],
    products: [
        .library(name: "OrdoKit", targets: ["OrdoKit"])
    ],
    targets: [
        // KMP 共享核心(Kotlin/Native → XCFramework)
        .binaryTarget(
            name: "OrdoCore",
            path: corePath
        ),
        // iOS 应用层
        .target(
            name: "OrdoKit",
            dependencies: ["OrdoCore"],
            path: "Ordo",
            exclude: ["Resources"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        // 单元测试
        .testTarget(
            name: "OrdoTests",
            dependencies: ["OrdoKit", "OrdoCore"],
            path: "OrdoTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
