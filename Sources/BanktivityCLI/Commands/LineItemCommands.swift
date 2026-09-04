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

        @OptionGroup var parent: GlobalOptions

        @Argument(help: "Line item ID")
        var id: Int

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let lineItems = LineItemRepository(container: container)

            guard let item = try lineItems.get(lineItemId: id) else {
                throw ToolError.notFound("Line item not found: \(id)")
            }
            try outputJSON(item, format: parent.format)
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a line item to a transaction")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Transaction ID")
        var transactionId: Int

        @Option(name: .long, help: "Account ID")
        var accountId: Int?

        @Option(name: .long, help: "Account name (alternative to --account-id)")
        var accountName: String?

        @Option(name: .long, parsing: .unconditional, help: "Amount")
        var amount: Double

        @Option(name: .long, help: "Optional memo")
        var memo: String?

        @Flag(name: .long, help: "Validate and return the planned mutation without writing")
        var dryRun: Bool = false

        @Flag(name: .long, help: "Confirm the operator reviewed the target transaction and account")
        var operatorReviewedTarget: Bool = false

        @Flag(name: .long, help: "Confirm Banktivity UI inspection will be performed after this write")
        var postUIVerificationRequired: Bool = false

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)

            let accounts = AccountRepository(container: container)
            let resolvedId = try accounts.resolveAccountId(id: accountId, name: accountName)

            let lineItems = LineItemRepository(container: container)
            if dryRun {
                try outputJSON(try lineItems.validateAddToTransaction(
                    transactionId: transactionId,
                    accountId: resolvedId
                ), format: parent.format)
                return
            }

            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)
            try requireReviewedWriteConfirmations(
                subject: "Line-item writes",
                target: "transaction/account",
                operatorReviewedTarget: operatorReviewedTarget,
                postUIVerificationRequired: postUIVerificationRequired
            )
            let updatedItems = try lineItems.addToTransaction(
                transactionId: transactionId,
                accountId: resolvedId,
                amount: amount,
                memo: memo
            )
            try outputJSON(updatedItems, format: parent.format)
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Update a line item")

        @OptionGroup var parent: GlobalOptions

        @Argument(help: "Line item ID")
        var id: Int

        @Option(name: .long, help: "New account ID")
        var accountId: Int?

        @Option(name: .long, help: "New account name (alternative to --account-id)")
        var accountName: String?

        @Option(name: .long, parsing: .unconditional, help: "New amount")
        var amount: Double?

        @Option(name: .long, help: "New memo")
        var memo: String?

        @Flag(name: .long, help: "Validate and return the planned mutation without writing")
        var dryRun: Bool = false

        @Flag(name: .long, help: "Confirm the operator reviewed the target line item")
        var operatorReviewedTarget: Bool = false

        @Flag(name: .long, help: "Confirm Banktivity UI inspection will be performed after this write")
        var postUIVerificationRequired: Bool = false

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)

            let accounts = AccountRepository(container: container)
            let resolvedAccountId: Int?
            if accountId != nil || accountName != nil {
                resolvedAccountId = try accounts.resolveAccountId(id: accountId, name: accountName)
            } else {
                resolvedAccountId = nil
            }

            let lineItems = LineItemRepository(container: container)
            if dryRun {
                try outputJSON(try lineItems.validateUpdate(
                    lineItemId: id,
                    accountId: resolvedAccountId
                ), format: parent.format)
                return
            }

            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)
            try requireReviewedWriteConfirmations(
                subject: "Line-item writes",
                target: "transaction/account",
                operatorReviewedTarget: operatorReviewedTarget,
                postUIVerificationRequired: postUIVerificationRequired
            )
            guard let updated = try lineItems.updateWithRecalculation(
                lineItemId: id,
                accountId: resolvedAccountId,
                amount: amount,
                memo: memo
            ) else {
                throw ToolError.notFound("Line item not found after update")
            }
            try outputJSON(updated, format: parent.format)
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a line item")

        @OptionGroup var parent: GlobalOptions

        @Argument(help: "Line item ID")
        var id: Int

        @Flag(name: .long, help: "Validate and return the planned mutation without writing")
        var dryRun: Bool = false

        @Flag(name: .long, help: "Confirm the operator reviewed the target line item")
        var operatorReviewedTarget: Bool = false

        @Flag(name: .long, help: "Confirm Banktivity UI inspection will be performed after this write")
        var postUIVerificationRequired: Bool = false

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let lineItems = LineItemRepository(container: container)
            if dryRun {
                try outputJSON(try lineItems.validateDelete(lineItemId: id), format: parent.format)
                return
            }

            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)
            try requireReviewedWriteConfirmations(
                subject: "Line-item writes",
                target: "transaction/account",
                operatorReviewedTarget: operatorReviewedTarget,
                postUIVerificationRequired: postUIVerificationRequired
            )

            guard try lineItems.deleteWithRecalculation(lineItemId: id) else {
                throw ToolError.notFound("Line item not found: \(id)")
            }
            try outputJSON(["message": "Line item \(id) deleted"] as [String: Any], format: parent.format)
        }
    }
}

