// swift-tools-version: 5.9
// AppUninstaller — macOS 应用管理 / 卸载工具
// 最低系统版本：macOS 13.0 (Ventura)，向上兼容至最新 macOS
import PackageDescription

let package = Package(
    name: "AppUninstaller",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AppUninstaller", targets: ["AppUninstaller"])
    ],
    targets: [
        .executableTarget(
            name: "AppUninstaller",
            path: "Sources/AppUninstaller",
            swiftSettings: [
                // 使用 Swift 5 语言模式，兼容 Swift 5.9 ~ 6.x 编译器
                .unsafeFlags(["-strict-concurrency=minimal"])
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
