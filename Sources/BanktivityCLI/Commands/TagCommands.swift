// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser
import BanktivityLib
import Foundation

struct Tags: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Tag operations",
        subcommands: [List.self, Create.self, TagTransaction.self, GetByTag.self, BulkTag.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all tags")

        @OptionGroup var parent: GlobalOptions

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let tags = TagRepository(container: container)

            let results = try tags.list()
            try outputJSON(results, format: parent.format)
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a tag")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Tag name")
        var name: String

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let tags = TagRepository(container: container)
            let result = try tags.create(name: name)
            try outputJSON(result, format: parent.format)
        }
    }

    struct TagTransaction: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "tag-transaction",
            abstract: "Add or remove a tag from a transaction"
        )

        @OptionGroup var parent: GlobalOptions

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

            let resolvedTagId = try tags.resolveTagId(id: tagId, name: tagName, autoCreate: true)
            let count = try tags.applyTag(transactionId: transactionId, tagId: resolvedTagId, action: action)
            try outputJSON(["message": "Tagged \(count) line items", "action": action] as [String: Any], format: parent.format)
        }
    }

    struct GetByTag: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get-by-tag",
            abstract: "Find transactions with a specific tag"
        )

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Tag name")
        var tagName: String?

        @Option(name: .long, help: "Tag ID")
        var tagId: Int?

        @Option(name: .long, help: "Start date (YYYY-MM-DD)")
        var startDate: String?

        @Option(name: .long, help: "End date (YYYY-MM-DD)")
        var endDate: String?

        @Option(name: .long, help: "Maximum number of transactions (default: 50)")
        var limit: Int = 50

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let tags = TagRepository(container: container)
            let lineItemRepo = LineItemRepository(container: container)
            let transactions = TransactionRepository(container: container, lineItemRepo: lineItemRepo)

            let results = try tags.getTransactionDTOsByTag(
                tagId: tagId,
                tagName: tagName,
                startDate: startDate,
                endDate: endDate,
                limit: limit,
                transactionRepo: transactions
            )
            try outputJSON(results, format: parent.format)
        }
    }

    struct BulkTag: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "bulk-tag",
            abstract: "Add or remove a tag from multiple transactions"
        )

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Comma-separated transaction IDs")
        var transactionIds: String

        @Option(name: .long, help: "Tag name (created if doesn't exist)")
        var tagName: String?

        @Option(name: .long, help: "Tag ID")
        var tagId: Int?

        @Option(name: .long, help: "Action: add or remove (default: add)")
        var action: String = "add"

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let tags = TagRepository(container: container)

            let ids = transactionIds.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !ids.isEmpty else {
                throw ToolError.invalidInput("No valid transaction IDs provided")
            }

            let resolvedTagId = try tags.resolveTagId(id: tagId, name: tagName, autoCreate: true)
            let totalCount = try tags.bulkApplyTag(transactionIds: ids, tagId: resolvedTagId, action: action)

            try outputJSON([
                "message": "\(action == "remove" ? "Removed" : "Added") tag on \(totalCount) line items across \(ids.count) transactions",
                "action": action,
            ] as [String: Any], format: parent.format)
        }
    }
}
