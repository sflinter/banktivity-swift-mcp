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

            try outputJSON(["message": "Tagged \(count) line items", "action": action] as [String: Any])
        }
    }

    struct GetByTag: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get-by-tag",
            abstract: "Find transactions with a specific tag"
        )

        @OptionGroup var parent: VaultOption

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

            let resolvedTagId: Int
            if let id = tagId {
                resolvedTagId = id
            } else if let name = tagName {
                guard let tag = try tags.findByName(name) else {
                    throw ToolError.notFound("Tag not found: \(name)")
                }
                resolvedTagId = tag.id
            } else {
                throw ToolError.missingParameter("Either --tag-name or --tag-id is required")
            }

            let txObjects = try tags.getTransactionsByTag(
                tagId: resolvedTagId,
                startDate: startDate,
                endDate: endDate,
                limit: limit
            )

            let txDTOs: [TransactionDTO] = txObjects.compactMap { obj in
                try? transactions.get(transactionId: BaseRepository.extractPK(from: obj.objectID))
            }

            try outputJSON(txDTOs)
        }
    }

    struct BulkTag: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "bulk-tag",
            abstract: "Add or remove a tag from multiple transactions"
        )

        @OptionGroup var parent: VaultOption

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

            let resolvedTagId: Int
            if let id = tagId {
                resolvedTagId = id
            } else if let name = tagName {
                let tag = try tags.create(name: name)
                resolvedTagId = tag.id
            } else {
                throw ToolError.missingParameter("Either --tag-name or --tag-id is required")
            }

            var totalCount = 0
            for txId in ids {
                if action == "remove" {
                    totalCount += try tags.untagTransaction(transactionId: txId, tagId: resolvedTagId)
                } else {
                    totalCount += try tags.tagTransaction(transactionId: txId, tagId: resolvedTagId)
                }
            }

            try outputJSON([
                "message": "\(action == "remove" ? "Removed" : "Added") tag on \(totalCount) line items across \(ids.count) transactions",
                "action": action,
            ] as [String: Any])
        }
    }
}
