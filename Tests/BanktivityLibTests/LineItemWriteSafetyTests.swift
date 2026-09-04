// Copyright (c) 2026 Steve Flinter. MIT License.

import Testing
@testable import BanktivityLib

@Suite("LineItemWriteSafety")
struct LineItemWriteSafetyTests {
    private func makeRepositories() throws -> (
        vault: TestVaultHelper.TestVault,
        accounts: AccountRepository,
        transactions: TransactionRepository,
        lineItems: LineItemRepository
    ) {
        let vault = try TestVaultHelper.createFreshVault()
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedTransactionTypes(in: vault.container)

        let accounts = AccountRepository(container: vault.container)
        let lineItems = LineItemRepository(container: vault.container)
        let transactions = TransactionRepository(container: vault.container, lineItemRepo: lineItems)

        return (vault, accounts, transactions, lineItems)
    }

    @Test("line item dry-run validation resolves targets without writing")
    func lineItemDryRunValidationResolvesTargets() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let account = try repos.accounts.create(name: "Dry Run Checking", accountClass: AccountClass.checking, currencyCode: "USD")
        let transaction = try repos.transactions.create(
            date: "2026-06-01",
            title: "Dry run transaction",
            lineItems: [(accountId: account.id, amount: 10, memo: nil)]
        )
        let lineItemId = try #require(transaction.lineItems.first?.id)
        let beforeCount = transaction.lineItems.count

        let addPlan = try repos.lineItems.validateAddToTransaction(
            transactionId: transaction.id,
            accountId: account.id
        )
        #expect(addPlan.operation == "line_items.add")
        #expect(!addPlan.wouldWrite)
        #expect(addPlan.requiredConfirmations == LineItemRepository.writeConfirmations)
        #expect(addPlan.targetIds["transactionId"] == transaction.id)
        #expect(addPlan.targetIds["accountId"] == account.id)

        let updatePlan = try repos.lineItems.validateUpdate(lineItemId: lineItemId, accountId: account.id)
        #expect(updatePlan.operation == "line_items.update")
        #expect(updatePlan.targetIds["lineItemId"] == lineItemId)
        #expect(updatePlan.uiVerificationRequired)

        let deletePlan = try repos.lineItems.validateDelete(lineItemId: lineItemId)
        #expect(deletePlan.operation == "line_items.delete")
        #expect(deletePlan.targetIds["lineItemId"] == lineItemId)

        let after = try repos.lineItems.getForTransactionPK(transaction.id)
        #expect(after.count == beforeCount)
        #expect(after.contains { $0.id == lineItemId })
    }

    @Test("line item dry-run validation fails for missing targets")
    func lineItemDryRunValidationFailsForMissingTargets() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        #expect(throws: (any Error).self) {
            try repos.lineItems.validateAddToTransaction(transactionId: 999_001, accountId: 999_002)
        }
        #expect(throws: (any Error).self) {
            try repos.lineItems.validateUpdate(lineItemId: 999_003)
        }
        #expect(throws: (any Error).self) {
            try repos.lineItems.validateDelete(lineItemId: 999_004)
        }
    }

    @Test("capabilities mark line-item writes as dry-run capable")
    func capabilitiesMarkLineItemWritesAsDryRunCapable() throws {
        let report = CapabilityRegistry.report()
        let cliUpdate = try #require(report.commands.first { $0.name == "line-items update" })
        #expect(cliUpdate.supportsDryRun)
        #expect(cliUpdate.requiredConfirmations == LineItemRepository.writeConfirmations)

        let mcpDelete = try #require(report.tools.first { $0.name == "delete_line_item" })
        #expect(mcpDelete.supportsDryRun)
        #expect(mcpDelete.requiredConfirmations == LineItemRepository.writeConfirmations)
    }
}
