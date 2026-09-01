// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser
import BanktivityLib
import Foundation

struct Statements: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Statement reconciliation operations",
        subcommands: [List.self, Status.self, Get.self, CorrectionPlan.self, Create.self, Update.self, Delete.self, Reconcile.self, Unreconcile.self, Unreconciled.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List statements for an account")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Account ID")
        var accountId: Int?

        @Option(name: .long, help: "Account name (alternative to --account-id)")
        var accountName: String?

        @Flag(name: .long, help: "Include unnamed/internal investment statement diagnostics")
        var includeInternal: Bool = false

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let accountRepo = AccountRepository(container: container)
            let lineItemRepo = LineItemRepository(container: container)
            let statements = StatementRepository(container: container, lineItemRepo: lineItemRepo)

            let resolvedId = try accountRepo.resolveAccountId(id: accountId, name: accountName)
            try emitStatementReadWarnings(try statements.warningsForStatementReads(accountId: resolvedId))
            let results = try statements.list(accountId: resolvedId, includeInternal: includeInternal)
            try outputJSON(results, format: parent.format)
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get statement reconciliation status for an account")

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
            let result = try statements.getAccountReconciliationStatus(accountId: resolvedId)
            try outputJSON(result, format: parent.format)
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get a statement with reconciliation progress and line item membership")

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
            try emitStatementReadWarnings(result.warnings)
            try outputJSON(result, format: parent.format)
        }
    }

    struct CorrectionPlan: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "visible-row-correction-plan",
            abstract: "Generate a visible-row correction plan from operator-entered Banktivity UI START/END/MISSING values"
        )

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Target visible statement ID, if already identified")
        var statementId: Int?

        @Option(name: .long, parsing: .unconditional, help: "START value read by the operator from the Banktivity Statements UI")
        var uiStart: Double

        @Option(name: .long, parsing: .unconditional, help: "END value read by the operator from the Banktivity Statements UI")
        var uiEnd: Double

        @Option(name: .long, parsing: .unconditional, help: "MISSING value read by the operator from the Banktivity Statements UI")
        var uiMissing: Double

        @Option(name: .long, parsing: .unconditional, help: "Corrected row start, usually the prior corrected row ending balance for chained rows")
        var correctedStart: Double?

        func run() async throws {
            let plan = VisibleRowCorrectionPlanDTO(
                statementId: statementId,
                uiStart: uiStart,
                uiEnd: uiEnd,
                uiMissing: uiMissing,
                correctedStart: correctedStart
            )
            try outputJSON(plan, format: parent.format)
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

        @Option(name: .long, parsing: .unconditional, help: "Beginning balance")
        var beginningBalance: Double

        @Option(name: .long, parsing: .unconditional, help: "Ending balance")
        var endingBalance: Double

        @Option(name: .long, help: "Statement name")
        var name: String?

        @Option(name: .long, help: "Note")
        var note: String?

        @Flag(name: .long, help: "Confirm a fresh whole-vault backup exists for this write session")
        var backupConfirmed: Bool = false

        @Flag(name: .long, help: "Confirm Banktivity UI inspection will be performed after this write")
        var postUIVerificationRequired: Bool = false

        @Flag(name: .long, help: "Confirm this unnamed row was matched to the intended statement in the Banktivity UI")
        var operatorConfirmedVisible: Bool = false

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)
            try requireStatementWriteSafety(backupConfirmed: backupConfirmed, postUIVerificationRequired: postUIVerificationRequired)

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

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Update guarded visible-row statement metadata")

        @OptionGroup var parent: GlobalOptions

        @Argument(help: "Visible statement ID")
        var statementId: Int

        @Option(name: .long, parsing: .unconditional, help: "Corrected ending balance")
        var endingBalance: Double

        @Option(name: .long, parsing: .unconditional, help: "Corrected beginning balance for an explicit internal-row repair")
        var beginningBalance: Double?

        @Flag(name: .long, help: "Confirm a fresh whole-vault backup exists for this write session")
        var backupConfirmed: Bool = false

        @Flag(name: .long, help: "Confirm Banktivity UI inspection will be performed after this write")
        var postUIVerificationRequired: Bool = false

        @Flag(name: .long, help: "Deliberately allow ending-balance update on an internal investment statement row")
        var allowInternal: Bool = false

        @Flag(name: .long, help: "Set only after matching an unnamed investment statement row to the intended visible Banktivity Statements UI row")
        var operatorConfirmedVisible: Bool = false

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)
            try requireStatementWriteSafety(backupConfirmed: backupConfirmed, postUIVerificationRequired: postUIVerificationRequired)

            let lineItemRepo = LineItemRepository(container: container)
            let statements = StatementRepository(container: container, lineItemRepo: lineItemRepo)
            let result = try statements.update(
                statementId: statementId,
                endingBalance: endingBalance,
                beginningBalance: beginningBalance,
                allowInternal: allowInternal,
                operatorConfirmedVisible: operatorConfirmedVisible
            )
            try outputJSON(result, format: parent.format)
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a statement and unreconcile its line items")

        @OptionGroup var parent: GlobalOptions

        @Argument(help: "Statement ID")
        var statementId: Int

        @Flag(name: .long, help: "Confirm a fresh whole-vault backup exists for this write session")
        var backupConfirmed: Bool = false

        @Flag(name: .long, help: "Confirm Banktivity UI inspection will be performed after this write")
        var postUIVerificationRequired: Bool = false

        @Flag(name: .long, help: "Confirm this unnamed row was matched to the intended statement in the Banktivity UI")
        var operatorConfirmedVisible: Bool = false

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)
            try requireStatementWriteSafety(backupConfirmed: backupConfirmed, postUIVerificationRequired: postUIVerificationRequired)

            let syncBlobUpdater = SyncBlobUpdater(container: container)
            let lineItemRepo = LineItemRepository(container: container)
            let statements = StatementRepository(container: container, lineItemRepo: lineItemRepo, syncBlobUpdater: syncBlobUpdater)

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

        @Flag(name: .long, help: "Confirm a fresh whole-vault backup exists for this write session")
        var backupConfirmed: Bool = false

        @Flag(name: .long, help: "Confirm Banktivity UI inspection will be performed after this write")
        var postUIVerificationRequired: Bool = false

        @Flag(name: .long, help: "Confirm this unnamed row was matched to the intended statement in the Banktivity UI")
        var operatorConfirmedVisible: Bool = false

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)
            try requireStatementWriteSafety(backupConfirmed: backupConfirmed, postUIVerificationRequired: postUIVerificationRequired)

            let syncBlobUpdater = SyncBlobUpdater(container: container)
            let lineItemRepo = LineItemRepository(container: container)
            let statements = StatementRepository(container: container, lineItemRepo: lineItemRepo, syncBlobUpdater: syncBlobUpdater)

            let ids = lineItemIds.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !ids.isEmpty else {
                throw ToolError.invalidInput("No valid line item IDs provided")
            }

            let result = try statements.reconcileLineItems(
                statementId: statementId,
                lineItemIds: ids,
                operatorConfirmedVisible: operatorConfirmedVisible
            )
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

        @Flag(name: .long, help: "Confirm a fresh whole-vault backup exists for this write session")
        var backupConfirmed: Bool = false

        @Flag(name: .long, help: "Confirm Banktivity UI inspection will be performed after this write")
        var postUIVerificationRequired: Bool = false

        @Flag(name: .long, help: "Confirm this unnamed row was matched to the intended statement in the Banktivity UI")
        var operatorConfirmedVisible: Bool = false

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)
            try requireStatementWriteSafety(backupConfirmed: backupConfirmed, postUIVerificationRequired: postUIVerificationRequired)

            let syncBlobUpdater = SyncBlobUpdater(container: container)
            let lineItemRepo = LineItemRepository(container: container)
            let statements = StatementRepository(container: container, lineItemRepo: lineItemRepo, syncBlobUpdater: syncBlobUpdater)

            let ids = lineItemIds.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !ids.isEmpty else {
                throw ToolError.invalidInput("No valid line item IDs provided")
            }

            guard let result = try statements.unreconcileLineItems(
                statementId: statementId,
                lineItemIds: ids,
                operatorConfirmedVisible: operatorConfirmedVisible
            ) else {
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

private func requireStatementWriteSafety(backupConfirmed: Bool, postUIVerificationRequired: Bool) throws {
    guard backupConfirmed else {
        throw ToolError.invalidInput("Statement writes require --backup-confirmed after creating a fresh whole-vault backup.")
    }
    guard postUIVerificationRequired else {
        throw ToolError.invalidInput("Statement writes require --post-ui-verification-required because Banktivity Statements UI inspection is the post-write authority.")
    }
}

private func emitStatementReadWarnings(_ warnings: [String]) throws {
    for warning in warnings {
        if let data = "warning: \(warning)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
