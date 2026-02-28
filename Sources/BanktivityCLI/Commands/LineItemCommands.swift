// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser
import BanktivityLib
import Foundation

struct LineItems: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "line-items",
        abstract: "Line item operations",
        subcommands: [Get.self, Add.self, Update.self, Delete.self]
    )

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get a line item by ID")

        @OptionGroup var parent: VaultOption

        @Argument(help: "Line item ID")
        var id: Int

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let lineItems = LineItemRepository(container: container)

            guard let item = try lineItems.get(lineItemId: id) else {
                throw ToolError.notFound("Line item not found: \(id)")
            }
            try outputJSON(item)
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a line item to a transaction")

        @OptionGroup var parent: VaultOption

        @Option(name: .long, help: "Transaction ID")
        var transactionId: Int

        @Option(name: .long, help: "Account ID")
        var accountId: Int

        @Option(name: .long, help: "Amount")
        var amount: Double

        @Option(name: .long, help: "Optional memo")
        var memo: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let lineItems = LineItemRepository(container: container)
            _ = try lineItems.create(
                transactionId: transactionId,
                accountId: accountId,
                amount: amount,
                memo: memo
            )
            try lineItems.recalculateRunningBalances(accountId: accountId)

            let updatedItems = try lineItems.getForTransactionPK(transactionId)
            try outputJSON(updatedItems)
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Update a line item")

        @OptionGroup var parent: VaultOption

        @Argument(help: "Line item ID")
        var id: Int

        @Option(name: .long, help: "New account ID")
        var accountId: Int?

        @Option(name: .long, help: "New amount")
        var amount: Double?

        @Option(name: .long, help: "New memo")
        var memo: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let lineItems = LineItemRepository(container: container)
            let affectedAccounts = try lineItems.update(
                lineItemId: id,
                accountId: accountId,
                amount: amount,
                memo: memo
            )

            for acctId in affectedAccounts {
                try lineItems.recalculateRunningBalances(accountId: acctId)
            }

            guard let updated = try lineItems.get(lineItemId: id) else {
                throw ToolError.notFound("Line item not found after update")
            }
            try outputJSON(updated)
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a line item")

        @OptionGroup var parent: VaultOption

        @Argument(help: "Line item ID")
        var id: Int

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let lineItems = LineItemRepository(container: container)
            guard let info = try lineItems.delete(lineItemId: id) else {
                throw ToolError.notFound("Line item not found: \(id)")
            }
            try lineItems.recalculateRunningBalances(accountId: info.accountId)
            try outputJSON(["message": "Line item \(id) deleted"] as [String: Any])
        }
    }
}
