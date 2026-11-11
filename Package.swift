// swift-tools-version:5.9
import PackageDescription

// 结构照抄 ~/Documents/Hermes/manatee：单 executableTarget + testTarget。
// 用 5.9 的语言模式而不是 6.0：P0 还没引入并发模型，6.0 的严格并发检查
// 会把 AppKit 回调全部报成错，等 P1 真上音频再单独迁移。
let package = Package(
    name: "Handy",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Handy",
            path: "Sources/Handy",
            linkerSettings: [
                .linkedFramework("AppKit"),
                // P1：录音用 AVFoundation，全局热键用 Carbon（RegisterEventHotKey，零 TCC）。
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
            ]),
        .testTarget(
            name: "HandyTests",
            dependencies: ["Handy"],
            path: "Tests/HandyTests"
        ),
    ]
)
