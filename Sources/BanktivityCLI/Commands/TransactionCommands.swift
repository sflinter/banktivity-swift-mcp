// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser
import BanktivityLib
import Foundation

struct Transactions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transaction operations",
        subcommands: [List.self, Search.self, Get.self, Create.self, Update.self, Delete.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List transactions")

        @OptionGroup var parent: VaultOption

        @Option(name: .long, help: "Filter by account ID")
        var accountId: Int?

        @Option(name: .long, help: "Start date (YYYY-MM-DD)")
        var startDate: String?

        @Option(name: .long, help: "End date (YYYY-MM-DD)")
        var endDate: String?

        @Option(name: .long, help: "Maximum number of transactions")
        var limit: Int?

        @Option(name: .long, help: "Number of transactions to skip")
        var offset: Int?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let lineItemRepo = LineItemRepository(container: container)
            let transactions = TransactionRepository(container: container, lineItemRepo: lineItemRepo)

            let results = try transactions.list(
                accountId: accountId,
                startDate: startDate,
                endDate: endDate,
                limit: limit,
                offset: offset
            )
            try outputJSON(results)
        }
    }

    struct Search: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Search transactions")

        @OptionGroup var parent: VaultOption

        @Option(name: .long, help: "Search query")
        var query: String

        @Option(name: .long, help: "Maximum number of results")
        var limit: Int = 50

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let lineItemRepo = LineItemRepository(container: container)
            let transactions = TransactionRepository(container: container, lineItemRepo: lineItemRepo)

            let results = try transactions.search(query: query, limit: limit)
            try outputJSON(results)
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get a transaction by ID")

        @OptionGroup var parent: VaultOption

        @Argument(help: "Transaction ID")
        var id: Int

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let lineItemRepo = LineItemRepository(container: container)
            let transactions = TransactionRepository(container: container, lineItemRepo: lineItemRepo)

            guard let tx = try transactions.get(transactionId: id) else {
                throw ToolError.notFound("Transaction not found: \(id)")
            }
            try outputJSON(tx)
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a transaction")

        @OptionGroup var parent: VaultOption

        @Option(name: .long, help: "Account ID for the primary line item")
        var accountId: Int

        @Option(name: .long, help: "Transaction date (YYYY-MM-DD)")
        var date: String

        @Option(name: .long, help: "Transaction title/payee")
        var title: String

        @Option(name: .long, help: "Transaction amount")
        var amount: Double

        @Option(name: .long, help: "Category ID for the second line item")
        var categoryId: Int?

        @Option(name: .long, help: "Optional note")
        var note: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let lineItemRepo = LineItemRepository(container: container)
            let transactions = TransactionRepository(container: container, lineItemRepo: lineItemRepo)

            var lineItems: [(accountId: Int, amount: Double, memo: String?)] = [
                (accountId: accountId, amount: amount, memo: nil)
            ]

            if let catId = categoryId {
                lineItems.append((accountId: catId, amount: -amount, memo: nil))
            }

            let result = try transactions.create(
                date: date,
                title: title,
                note: note,
                lineItems: lineItems
            )
            try outputJSON(result)
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Update a transaction")

        @OptionGroup var parent: VaultOption

        @Argument(help: "Transaction ID")
        var id: Int

        @Option(name: .long, help: "New title")
        var title: String?

        @Option(name: .long, help: "New note")
        var note: String?

        @Option(name: .long, help: "New date (YYYY-MM-DD)")
        var date: String?

        @Flag(name: .long, help: "Mark as cleared")
        var cleared: Bool = false

        @Flag(name: .long, help: "Mark as uncleared")
        var uncleared: Bool = false

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let lineItemRepo = LineItemRepository(container: container)
            let transactions = TransactionRepository(container: container, lineItemRepo: lineItemRepo)

            let clearedValue: Bool? = cleared ? true : (uncleared ? false : nil)

            guard let updated = try transactions.update(
                transactionId: id,
                title: title,
                note: note,
                date: date,
                cleared: clearedValue
            ) else {
                throw ToolError.notFound("Transaction not found: \(id)")
            }
            try outputJSON(updated)
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a transaction")

        @OptionGroup var parent: VaultOption

        @Argument(help: "Transaction ID")
        var id: Int

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let lineItemRepo = LineItemRepository(container: container)
            let transactions = TransactionRepository(container: container, lineItemRepo: lineItemRepo)

            let deleted = try transactions.delete(transactionId: id)
            if !deleted {
                throw ToolError.notFound("Transaction not found: \(id)")
            }
            outputJSON(["message": "Transaction \(id) deleted"] as [String: Any])
        }
    }
}
