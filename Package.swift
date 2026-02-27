// Copyright (c) 2026 Steve Flinter. MIT License.

// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "banktivity-mcp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
    ],
    targets: [
        .target(
            name: "BanktivityMCPLib",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/BanktivityMCPLib"
        ),
        .executableTarget(
            name: "banktivity-mcp",
            dependencies: ["BanktivityMCPLib"],
            path: "Sources/BanktivityMCP"
        ),
        .testTarget(
            name: "BanktivityMCPTests",
            dependencies: ["BanktivityMCPLib"],
            path: "Tests/BanktivityMCPTests"
        ),
    ]
)
