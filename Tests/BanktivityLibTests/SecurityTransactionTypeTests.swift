// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

/// The label a trade reads back with must be the one the vault stores.
///
/// `transactionTypeName` mapped base types to names in a hand-written switch that
/// disagreed with `ZTRANSACTIONTYPE`. It was wrong from 302 upward and omitted
/// 250 entirely, so a correctly recorded row read back mislabelled -- or as
/// `Unknown (250)`, which looks like a data defect when the data is fine.
@Suite("Security transaction type", .serialized)
struct SecurityTransactionTypeTests {

    @Test(
        "a trade reads back with the vault's own transaction type name",
        arguments: [
            (Int16(250), "Split Shares"),
            (Int16(302), "Cap. Gains Short"),
            (Int16(212), "Transfer Shares"),
        ]
    )
    func tradeReadsBackVaultTypeName(baseType: Int16, expected: String) throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let ctx = vault.container.viewContext
        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)

        // The vault's own table is the authority, so seed it and expect it back.
        let txType = NSEntityDescription.insertNewObject(forEntityName: "TransactionType", into: ctx)
        txType.setValue(baseType, forKey: "pBaseType")
        txType.setValue(expected, forKey: "pName")
        txType.setValue(UUID().uuidString, forKey: "pUniqueID")
        txType.setValue(Date(), forKey: "pCreationTime")
        txType.setValue(Date(), forKey: "pModificationDate")

        let tx = NSEntityDescription.insertNewObject(forEntityName: "Transaction", into: ctx)
        tx.setValue(UUID().uuidString, forKey: "pUniqueID")
        tx.setValue(Date(), forKey: "pDate")
        tx.setValue("Corporate action", forKey: "pTitle")
        tx.setValue(txType, forKey: "pTransactionType")
        tx.setValue(Date(), forKey: "pCreationTime")
        tx.setValue(Date(), forKey: "pModificationDate")

        let lineItem = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
        lineItem.setValue(UUID().uuidString, forKey: "pUniqueID")
        lineItem.setValue(tx, forKey: "pTransaction")
        lineItem.setValue(account, forKey: "pAccount")
        lineItem.setValue(Date(), forKey: "pCreationTime")

        let sli = NSEntityDescription.insertNewObject(forEntityName: "SecurityLineItem", into: ctx)
        sli.setValue(lineItem, forKey: "pLineItem")
        sli.setValue(security, forKey: "pSecurity")
        sli.setValue(NSDecimalNumber(value: 10), forKey: "pShares")

        try ctx.save()

        let trades = try SecurityRepository(container: vault.container).getTrades()
        let trade = try #require(trades.first)
        #expect(trade.type == expected)
    }
}
