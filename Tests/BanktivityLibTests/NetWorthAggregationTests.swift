// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

struct NetWorthAggregationTests {
    @Test func missingExchangeRateExcludesAccountAndWarns() {
        let result = AccountRepository.aggregateNetWorth(
            reportingCurrency: "KZT",
            accounts: [
                NetWorthAccountBalance(name: "Local Asset", accountClass: AccountClass.cash, currency: "KZT", balance: 100),
                NetWorthAccountBalance(id: 7, name: "Foreign Asset", accountClass: AccountClass.cash, currency: "GBP", balance: 50),
            ],
            rates: []
        )

        #expect(result.assets == 100)
        #expect(result.netWorth == 100)
        #expect(result.breakdown.byCurrency["GBP"] == nil)
        #expect(result.warnings.contains("Account Foreign Asset (currency GBP) excluded: no exchange rate available"))
        #expect(result.complete == false)
        #expect(result.excludedAccounts.count == 1)
        let excluded = result.excludedAccounts[0]
        #expect(excluded.accountId == 7 && excluded.name == "Foreign Asset" && excluded.currency == "GBP")
        #expect(excluded.balance == 50)
        #expect(excluded.reason.contains("GBP->KZT"))
    }

    @Test func reportingCurrencyAccountUsesIdentityRateWithoutWarning() {
        let result = AccountRepository.aggregateNetWorth(
            reportingCurrency: "KZT",
            accounts: [
                NetWorthAccountBalance(name: "Local Asset", accountClass: AccountClass.cash, currency: "KZT", balance: 100),
            ],
            rates: []
        )

        #expect(result.assets == 100)
        #expect(result.breakdown.byCurrency["KZT"]?.rate == 1)
        #expect(result.breakdown.byCurrency["KZT"]?.hops == 0)
        #expect(result.warnings.isEmpty)
        #expect(result.complete)
        #expect(result.excludedAccounts.isEmpty)
    }
}

@Suite("Net worth through the repository", .serialized)
@MainActor
struct NetWorthRepositoryTests {

    private func makeAccount(
        in vault: TestVaultHelper.TestVault, name: String, currency: String, amount: Double
    ) throws {
        let accounts = AccountRepository(container: vault.container, reportingCurrency: "USD")
        let account = try accounts.create(name: name, accountClass: AccountClass.savings, currencyCode: currency)
        let lineItems = LineItemRepository(container: vault.container)
        let transactions = TransactionRepository(container: vault.container, lineItemRepo: lineItems)
        _ = try transactions.create(
            date: "2026-02-01", title: "Deposit \(name)",
            lineItems: [(accountId: account.id, amount: amount, memo: nil)])
    }

    @Test("getNetWorth lists an account with no exchange rate and reports the result incomplete")
    func netWorthReportsExcludedAccount() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedTransactionTypes(in: vault.container)
        try makeAccount(in: vault, name: "US Savings", currency: "USD", amount: 100)
        try makeAccount(in: vault, name: "EU Savings", currency: "EUR", amount: 500)

        let netWorth = try AccountRepository(container: vault.container, reportingCurrency: "USD").getNetWorth()
        #expect(netWorth.assets == 100)
        #expect(netWorth.complete == false)
        #expect(netWorth.excludedAccounts.map(\.name) == ["EU Savings"])
        #expect(netWorth.excludedAccounts.first?.balance == 500)
    }

    @Test("a duplicate currency unique ID is tolerated and resolved to the alphabetically first code")
    func duplicateCurrencyUniqueIdDoesNotCrash() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let (usd, _) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let ctx = vault.container.viewContext
        let duplicate = NSEntityDescription.insertNewObject(forEntityName: "Currency", into: ctx)
        duplicate.setValue("USX", forKey: "pCode")
        duplicate.setValue("Duplicate", forKey: "pName")
        duplicate.setValue(usd.value(forKey: "pUniqueID"), forKey: "pUniqueID")
        duplicate.setValue(Date(), forKey: "pCreationTime")
        duplicate.setValue(Date(), forKey: "pModificationDate")
        try ctx.save()

        let codes = try ExchangeRateRepository.currencyCodesByUniqueId(in: ctx)
        #expect(codes[usd.value(forKey: "pUniqueID") as! String] == "USD")
        _ = try AccountRepository(container: vault.container, reportingCurrency: "USD").getNetWorth()
    }
}
