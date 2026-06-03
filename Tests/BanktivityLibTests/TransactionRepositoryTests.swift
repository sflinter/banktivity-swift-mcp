// Copyright (c) 2026 Steve Flinter. MIT License.

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

    @Test("List rejects missing account filter instead of returning the whole vault")
    func listRejectsMissingAccountFilter() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }

        let account = try repos.accounts.create(
            name: "Filtered Checking",
            accountClass: AccountClass.checking,
            currencyCode: "USD"
        )
        _ = try repos.transactions.create(
            date: "2026-05-10",
            title: "Should not leak through missing account filter",
            lineItems: [(accountId: account.id, amount: -10.0, memo: nil)]
        )

        do {
            _ = try repos.transactions.list(accountId: 999_999)
            Issue.record("Expected missing account filter to fail")
        } catch let error as ToolError {
            if case .notFound(let message) = error {
                #expect(message == "Account not found: 999999")
            } else {
                Issue.record("Expected notFound, got \(error)")
            }
        } catch {
            Issue.record("Expected ToolError.notFound, got \(error)")
        }

        let filtered = try repos.transactions.list(accountId: account.id)
        #expect(filtered.count == 1)
        #expect(filtered.first?.title == "Should not leak through missing account filter")
    }
}
