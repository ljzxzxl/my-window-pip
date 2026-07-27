// swift-tools-version:5.9
import PackageDescription

// 单一可执行模块：捕获、浮窗 UI、输入处理同处一个 target，
// 既支持完整 Xcode 的 `swift build`，也支持仅 Command Line Tools 下用
// scripts/build-app.sh 里的 swiftc 直接编译。
let package = Package(
    name: "MyWindowPip",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "my-window-pip", targets: ["my-window-pip"]),
    ],
    targets: [
        .executableTarget(name: "my-window-pip"),
    ]
)
