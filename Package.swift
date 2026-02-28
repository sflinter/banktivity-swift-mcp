// Copyright (c) 2026 Steve Flinter. MIT License.

// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "banktivity-mcp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "BanktivityLib",
            path: "Sources/BanktivityLib"
        ),
        .target(
            name: "BanktivityMCPLib",
            dependencies: [
                "BanktivityLib",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/BanktivityMCPLib"
        ),
        .executableTarget(
            name: "banktivity-mcp",
            dependencies: ["BanktivityMCPLib"],
            path: "Sources/BanktivityMCP"
        ),
        .executableTarget(
            name: "banktivity-cli",
            dependencies: [
                "BanktivityLib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/BanktivityCLI"
        ),
        .testTarget(
            name: "BanktivityLibTests",
            dependencies: ["BanktivityLib"],
            path: "Tests/BanktivityLibTests"
        ),
    ]
)
