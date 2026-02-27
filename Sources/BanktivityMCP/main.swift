// Copyright (c) 2026 Steve Flinter. MIT License.

import BanktivityLib
import BanktivityMCPLib
import CoreData
import Foundation
import MCP

// MARK: - Configuration

guard let bankFilePath = ProcessInfo.processInfo.environment["BANKTIVITY_FILE_PATH"] else {
    FileHandle.standardError.write(
        "Error: BANKTIVITY_FILE_PATH environment variable is required\n".data(using: .utf8)!
    )
    FileHandle.standardError.write(
        "Set it to the path of your .bank8 file\n".data(using: .utf8)!
    )
    exit(1)
}

// Verify the file exists
guard FileManager.default.fileExists(atPath: bankFilePath) else {
    FileHandle.standardError.write(
        "Error: File not found: \(bankFilePath)\n".data(using: .utf8)!
    )
    exit(1)
}

// MARK: - Core Data Setup

let container: NSPersistentContainer
do {
    container = try PersistentContainerFactory.create(bankFilePath: bankFilePath)
    FileHandle.standardError.write(
        "Core Data container loaded successfully\n".data(using: .utf8)!
    )
} catch {
    FileHandle.standardError.write(
        "Failed to initialize Core Data: \(error)\n".data(using: .utf8)!
    )
    exit(1)
}

// MARK: - Write Guard

let dbPath =
    URL(fileURLWithPath: bankFilePath)
    .appendingPathComponent("StoreContent")
    .appendingPathComponent("core.sql")
    .path
let writeGuard = WriteGuard(dbPath: dbPath)

// MARK: - Tool Registry

let registry = ToolRegistry(
    container: container,
    writeGuard: writeGuard,
    bankFilePath: bankFilePath
)
registry.registerAllTools()

// MARK: - MCP Server

let server = Server(
    name: "banktivity-mcp",
    version: "0.1.0",
    capabilities: .init(tools: .init(listChanged: false))
)

await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: registry.listTools())
}

await server.withMethodHandler(CallTool.self) { params in
    await registry.callTool(name: params.name, arguments: params.arguments)
}

// MARK: - Start Server

FileHandle.standardError.write(
    "Banktivity MCP server starting on stdio\n".data(using: .utf8)!
)

let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
