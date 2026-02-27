// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser
import BanktivityLib
import Foundation

struct Tags: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Tag operations",
        subcommands: [List.self, Create.self, TagTransaction.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all tags")

        @OptionGroup var parent: VaultOption

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let tags = TagRepository(container: container)

            let results = try tags.list()
            try outputJSON(results)
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a tag")

        @OptionGroup var parent: VaultOption

        @Option(name: .long, help: "Tag name")
        var name: String

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let tags = TagRepository(container: container)
            let result = try tags.create(name: name)
            try outputJSON(result)
        }
    }

    struct TagTransaction: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "tag-transaction",
            abstract: "Add or remove a tag from a transaction"
        )

        @OptionGroup var parent: VaultOption

        @Option(name: .long, help: "Transaction ID")
        var transactionId: Int

        @Option(name: .long, help: "Tag name (created if doesn't exist)")
        var tagName: String?

        @Option(name: .long, help: "Tag ID")
        var tagId: Int?

        @Option(name: .long, help: "Action: add or remove")
        var action: String = "add"

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let tags = TagRepository(container: container)

            let resolvedTagId: Int
            if let id = tagId {
                resolvedTagId = id
            } else if let name = tagName {
                let tag = try tags.create(name: name)
                resolvedTagId = tag.id
            } else {
                throw ToolError.missingParameter("Either --tag-name or --tag-id is required")
            }

            let count: Int
            if action == "remove" {
                count = try tags.untagTransaction(transactionId: transactionId, tagId: resolvedTagId)
            } else {
                count = try tags.tagTransaction(transactionId: transactionId, tagId: resolvedTagId)
            }

            outputJSON(["message": "Tagged \(count) line items", "action": action] as [String: Any])
        }
    }
}
