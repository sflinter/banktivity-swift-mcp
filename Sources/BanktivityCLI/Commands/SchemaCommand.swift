// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser
import BanktivityLib
import Foundation

struct Schema: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Dump Core Data schema")

    @OptionGroup var parent: VaultOption

    @Option(name: .long, help: "Filter to a specific entity name")
    var entity: String?

    func run() async throws {
        let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
        let storeContentURL = URL(fileURLWithPath: path)
            .appendingPathComponent("StoreContent")
        let schema = try PersistentContainerFactory.dumpModelSchema(from: storeContentURL)

        if let entityFilter = entity {
            let filtered = schema.filter {
                ($0["name"] as? String)?.lowercased() == entityFilter.lowercased()
            }
            if filtered.isEmpty {
                throw ToolError.notFound("Entity '\(entityFilter)' not found")
            }
            try outputJSON(filtered)
        } else {
            try outputJSON(schema)
        }
    }
}
