// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

// Runs on the main actor: see TestVaultHelper for why every suite that
// touches a view context has to.
@MainActor
@Suite("Reporting currency")
struct ReportingCurrencyTests {

    @Test("validates reporting currency codes with EUR fallback")
    func validatesReportingCurrencyCodes() {
        #expect(ReportingCurrency.resolve(nil) == "EUR")
        #expect(ReportingCurrency.resolve("") == "EUR")
        #expect(ReportingCurrency.resolve(" kzt ") == "KZT")
        #expect(ReportingCurrency.resolve("usd") == "USD")
        #expect(ReportingCurrency.resolve("ZZZ") == "EUR")
    }

    @Test("net worth aggregate formatting uses configured reporting currency")
    func netWorthUsesConfiguredReportingCurrency() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let ctx = vault.container.viewContext
        let account = NSEntityDescription.insertNewObject(forEntityName: "PrimaryAccount", into: ctx)
        account.setValue("KZT Checking", forKey: "pName")
        account.setValue("KZT Checking", forKey: "pFullName")
        account.setValue(UUID().uuidString, forKey: "pUniqueID")
        account.setValue(AccountClass.checking, forKey: "pAccountClass")
        account.setValue(false, forKey: "pHidden")
        account.setValue(Date(), forKey: "pCreationTime")
        account.setValue(Date(), forKey: "pModificationDate")

        let lineItem = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
        lineItem.setValue(account, forKey: "pAccount")
        lineItem.setValue(NSDecimalNumber(value: 12_345.67), forKey: "pTransactionAmount")
        lineItem.setValue(Date(), forKey: "pCreationTime")
        try ctx.save()

        let accounts = AccountRepository(container: vault.container, reportingCurrency: "KZT")
        let netWorth = try accounts.getNetWorth()

        let assets = try #require(netWorth.formattedAssets)
        let total = try #require(netWorth.formattedNetWorth)
        #expect(assets.contains("₸") || assets.contains("KZT"))
        #expect(total.contains("₸") || total.contains("KZT"))
    }
}
