// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import Testing
@testable import BanktivityLib

@Suite("TransactionRepository")
struct TransactionRepositoryTests {

    private func makeRepositories() throws -> (
        vault: TestVaultHelper.TestVault,
        accounts: AccountRepository,
        transactions: TransactionRepository
    ) {
        let vault = try TestVaultHelper.createFreshVault()
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedTransactionTypes(in: vault.container)

        let accounts = AccountRepository(container: vault.container)
        let lineItems = LineItemRepository(container: vault.container)
        let transactions = TransactionRepository(container: vault.container, lineItemRepo: lineItems)

        return (vault, accounts, transactions)
    }

    @Test("Create returns the newly inserted transaction, not a title-search match")
    func createReturnsInsertedTransactionWhenLaterMatchingTitleExists() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let account = try repos.accounts.create(
            name: "Synthetic Checking",
            accountClass: AccountClass.checking,
            currencyCode: "USD"
        )

        let existing = try repos.transactions.create(
            date: "2026-05-10",
            title: "Later Vendor Alpha Payment",
            lineItems: [(accountId: account.id, amount: -10.0, memo: nil)]
        )

        let created = try repos.transactions.create(
            date: "2026-04-09",
            title: "Vendor Alpha",
            lineItems: [(accountId: account.id, amount: -20.0, memo: nil)]
        )

        #expect(created.id != existing.id)
        #expect(created.title == "Vendor Alpha")
        #expect(created.date == "2026-04-09")
        #expect(created.lineItems.contains { $0.accountId == account.id && abs($0.amount - -20.0) < 0.005 })
    }
}
