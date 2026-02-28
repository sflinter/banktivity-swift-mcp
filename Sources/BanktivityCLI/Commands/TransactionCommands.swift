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

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Filter by account ID")
        var accountId: Int?

        @Option(name: .long, help: "Filter by account name (alternative to --account-id)")
        var accountName: String?

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
            let accounts = AccountRepository(container: container)
            let lineItemRepo = LineItemRepository(container: container)
            let transactions = TransactionRepository(container: container, lineItemRepo: lineItemRepo)

            let resolvedAccountId: Int?
            if accountId != nil || accountName != nil {
                resolvedAccountId = try accounts.resolveAccountId(id: accountId, name: accountName)
            } else {
                resolvedAccountId = nil
            }

            let results = try transactions.list(
                accountId: resolvedAccountId,
                startDate: startDate,
                endDate: endDate,
                limit: limit,
                offset: offset
            )
            try outputJSON(results, format: parent.format)
        }
    }

    struct Search: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Search transactions")

        @OptionGroup var parent: GlobalOptions

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
            try outputJSON(results, format: parent.format)
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get a transaction by ID")

        @OptionGroup var parent: GlobalOptions

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
            try outputJSON(tx, format: parent.format)
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a transaction")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Account ID for the primary line item")
        var accountId: Int?

        @Option(name: .long, help: "Account name (alternative to --account-id)")
        var accountName: String?

        @Option(name: .long, help: "Transaction date (YYYY-MM-DD)")
        var date: String

        @Option(name: .long, help: "Transaction title/payee")
        var title: String

        @Option(name: .long, help: "Transaction amount (required unless --line-items is provided)")
        var amount: Double?

        @Option(name: .long, help: "Category ID for the second line item")
        var categoryId: Int?

        @Option(name: .long, help: "Category name (alternative to --category-id)")
        var categoryName: String?

        @Option(name: .long, help: "Optional note")
        var note: String?

        @Option(name: .long, help: "JSON array of line items, e.g. '[{\"account_id\":1,\"amount\":-50},{\"account_name\":\"Food\",\"amount\":50}]'")
        var lineItems: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let accounts = AccountRepository(container: container)
            let lineItemRepo = LineItemRepository(container: container)
            let transactions = TransactionRepository(container: container, lineItemRepo: lineItemRepo)

            let resolvedLineItems: [(accountId: Int, amount: Double, memo: String?)]

            if let lineItemsJSON = lineItems {
                // Multi-line-item mode
                guard let data = lineItemsJSON.data(using: .utf8),
                      let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    throw ToolError.invalidInput("--line-items must be a valid JSON array")
                }

                resolvedLineItems = try parsed.map { item in
                    let acctId = try accounts.resolveAccountId(
                        id: item["account_id"] as? Int,
                        name: item["account_name"] as? String
                    )
                    guard let amt = item["amount"] as? Double ?? (item["amount"] as? Int).map(Double.init) else {
                        throw ToolError.missingParameter("Each line item requires an 'amount'")
                    }
                    let memo = item["memo"] as? String
                    return (accountId: acctId, amount: amt, memo: memo)
                }
            } else {
                // Simple mode — require account and amount
                let resolvedAccountId = try accounts.resolveAccountId(id: accountId, name: accountName)
                guard let amount = amount else {
                    throw ToolError.missingParameter("--amount is required (or use --line-items for multi-line-item transactions)")
                }

                var items: [(accountId: Int, amount: Double, memo: String?)] = [
                    (accountId: resolvedAccountId, amount: amount, memo: nil)
                ]

                if categoryId != nil || categoryName != nil {
                    let catId = try accounts.resolveAccountId(id: categoryId, name: categoryName)
                    items.append((accountId: catId, amount: -amount, memo: nil))
                }

                resolvedLineItems = items
            }

            let result = try transactions.create(
                date: date,
                title: title,
                note: note,
                lineItems: resolvedLineItems
            )
            try outputJSON(result, format: parent.format)
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Update a transaction")

        @OptionGroup var parent: GlobalOptions

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
            try outputJSON(updated, format: parent.format)
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a transaction")

        @OptionGroup var parent: GlobalOptions

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
            try outputJSON(["message": "Transaction \(id) deleted"] as [String: Any], format: parent.format)
        }
    }
}
