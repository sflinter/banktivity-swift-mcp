// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser
import BanktivityLib
import Foundation

struct Statements: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Statement reconciliation operations",
        subcommands: [List.self, Get.self, Create.self, Delete.self, Reconcile.self, Unreconcile.self, Unreconciled.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List statements for an account")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Account ID")
        var accountId: Int?

        @Option(name: .long, help: "Account name (alternative to --account-id)")
        var accountName: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let accountRepo = AccountRepository(container: container)
            let lineItemRepo = LineItemRepository(container: container)
            let statements = StatementRepository(container: container, lineItemRepo: lineItemRepo)

            let resolvedId = try accountRepo.resolveAccountId(id: accountId, name: accountName)
            let results = try statements.list(accountId: resolvedId)
            try outputJSON(results, format: parent.format)
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get a statement with reconciliation progress")

        @OptionGroup var parent: GlobalOptions

        @Argument(help: "Statement ID")
        var statementId: Int

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let lineItemRepo = LineItemRepository(container: container)
            let statements = StatementRepository(container: container, lineItemRepo: lineItemRepo)

            guard let result = try statements.get(statementId: statementId) else {
                throw ToolError.notFound("Statement not found: \(statementId)")
            }
            try outputJSON(result, format: parent.format)
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a statement")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Account ID")
        var accountId: Int?

        @Option(name: .long, help: "Account name (alternative to --account-id)")
        var accountName: String?

        @Option(name: .long, help: "Start date (YYYY-MM-DD)")
        var startDate: String

        @Option(name: .long, help: "End date (YYYY-MM-DD)")
        var endDate: String

        @Option(name: .long, help: "Beginning balance")
        var beginningBalance: Double

        @Option(name: .long, help: "Ending balance")
        var endingBalance: Double

        @Option(name: .long, help: "Statement name")
        var name: String?

        @Option(name: .long, help: "Note")
        var note: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let accountRepo = AccountRepository(container: container)
            let lineItemRepo = LineItemRepository(container: container)
            let statements = StatementRepository(container: container, lineItemRepo: lineItemRepo)

            let resolvedId = try accountRepo.resolveAccountId(id: accountId, name: accountName)
            let result = try statements.create(
                accountId: resolvedId,
                startDate: startDate,
                endDate: endDate,
                beginningBalance: beginningBalance,
                endingBalance: endingBalance,
                name: name,
                note: note
            )
            try outputJSON(result, format: parent.format)
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a statement and unreconcile its line items")

        @OptionGroup var parent: GlobalOptions

        @Argument(help: "Statement ID")
        var statementId: Int

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let lineItemRepo = LineItemRepository(container: container)
            let statements = StatementRepository(container: container, lineItemRepo: lineItemRepo)

            let deleted = try statements.delete(statementId: statementId)
            if deleted {
                try outputJSON(["message": "Statement \(statementId) deleted, line items unreconciled"] as [String: Any], format: parent.format)
            } else {
                throw ToolError.notFound("Statement not found: \(statementId)")
            }
        }
    }

    struct Reconcile: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Reconcile line items to a statement")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Statement ID")
        var statementId: Int

        @Option(name: .long, help: "Comma-separated line item IDs")
        var lineItemIds: String

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let lineItemRepo = LineItemRepository(container: container)
            let statements = StatementRepository(container: container, lineItemRepo: lineItemRepo)

            let ids = lineItemIds.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !ids.isEmpty else {
                throw ToolError.invalidInput("No valid line item IDs provided")
            }

            let result = try statements.reconcileLineItems(statementId: statementId, lineItemIds: ids)
            try outputJSON(result, format: parent.format)
        }
    }

    struct Unreconcile: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Unreconcile line items from a statement")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Statement ID")
        var statementId: Int

        @Option(name: .long, help: "Comma-separated line item IDs")
        var lineItemIds: String

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let lineItemRepo = LineItemRepository(container: container)
            let statements = StatementRepository(container: container, lineItemRepo: lineItemRepo)

            let ids = lineItemIds.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !ids.isEmpty else {
                throw ToolError.invalidInput("No valid line item IDs provided")
            }

            guard let result = try statements.unreconcileLineItems(statementId: statementId, lineItemIds: ids) else {
                throw ToolError.notFound("Statement not found: \(statementId)")
            }
            try outputJSON(result, format: parent.format)
        }
    }

    struct Unreconciled: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List unreconciled line items for an account")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Account ID")
        var accountId: Int?

        @Option(name: .long, help: "Account name (alternative to --account-id)")
        var accountName: String?

        @Option(name: .long, help: "Start date (YYYY-MM-DD)")
        var startDate: String?

        @Option(name: .long, help: "End date (YYYY-MM-DD)")
        var endDate: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let accountRepo = AccountRepository(container: container)
            let lineItemRepo = LineItemRepository(container: container)
            let statements = StatementRepository(container: container, lineItemRepo: lineItemRepo)

            let resolvedId = try accountRepo.resolveAccountId(id: accountId, name: accountName)
            let results = try statements.getUnreconciledLineItems(
                accountId: resolvedId,
                startDate: startDate,
                endDate: endDate
            )
            try outputJSON(results, format: parent.format)
        }
    }
}
