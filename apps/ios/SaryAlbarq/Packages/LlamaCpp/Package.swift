// swift-tools-version:5.9
// «مساعد سرى»: llama.cpp (MIT, ggml-org/llama.cpp) as the official prebuilt XCFramework from its
// GitHub release, pinned by URL + sha256. b10455 (2026-08-17) is the newest release whose
// XCFramework still ships the iOS Simulator slice (later ones are device + macOS only), so the
// app keeps building and testing on the simulator. Metal is on (ggml-metal inside the framework).
import PackageDescription

let package = Package(
    name: "LlamaCpp",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "LlamaCpp", targets: ["llama"]),
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b10455/llama-b10455-xcframework.zip",
            checksum: "9f9bf74f109ed6bb7f3027e2b4e90633aebe03ed7cce4d32a02c43f00724da5d"
        ),
    ]
)
