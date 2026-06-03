// Copyright (c) 2026 Steve Flinter. MIT License.

import Testing
@testable import BanktivityLib

@Suite("AccountRepository")
struct AccountRepositoryTests {

    private func expectAccountNotFound(accountId: Int, _ action: () throws -> Void) {
        do {
            try action()
            Issue.record("Expected account lookup to fail")
        } catch let error as ToolError {
            if case .notFound(let message) = error {
                #expect(message == "Account not found: \(accountId)")
            } else {
                Issue.record("Expected notFound, got \(error)")
            }
        } catch {
            Issue.record("Expected ToolError.notFound, got \(error)")
        }
    }

    @Test("Missing account IDs fail instead of resolving to zero-balance unknown accounts")
    func missingAccountIdsFailLoudly() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let accounts = AccountRepository(container: vault.container)

        expectAccountNotFound(accountId: 999_999) {
            _ = try accounts.resolveAccountId(id: 999_999, name: nil)
        }
        expectAccountNotFound(accountId: 999_999) {
            _ = try accounts.getBalance(accountId: 999_999)
        }
    }

    @Test("Hidden accounts still resolve when addressed by explicit ID")
    func hiddenAccountsResolveByExplicitId() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        _ = try TestVaultHelper.seedCurrencies(in: vault.container)

        let accounts = AccountRepository(container: vault.container)
        let hidden = try accounts.create(
            name: "Retired But Existing",
            accountClass: AccountClass.checking,
            currencyCode: "USD",
            hidden: true
        )

        let visibleAccounts = try accounts.list()
        #expect(!visibleAccounts.contains { $0.id == hidden.id })
        #expect(try accounts.resolveAccountId(id: hidden.id, name: nil) == hidden.id)
        #expect(try accounts.get(accountId: hidden.id)?.hidden == true)
    }
}
