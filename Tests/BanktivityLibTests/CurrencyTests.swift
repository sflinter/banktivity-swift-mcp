// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

@Suite("Currency")
struct CurrencyTests {

    @Test("createShareAdjustment uses account currency not first in DB")
    func adjustmentUsesAccountCurrency() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedTransactionTypes(in: vault.container)

        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let accountPK = BaseRepository.extractPK(from: account.objectID)
        let sec = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)

        let secRepo = SecurityRepository(container: vault.container)
        let symbol = BaseRepository.stringValue(sec, "pSymbol")
        let result = try secRepo.createShareAdjustment(
            accountId: accountPK, symbol: symbol, shares: 10, date: "2026-01-15"
        )
        #expect(result.shares == 10)

        // Verify the transaction has EUR currency, not USD
        let txRequest = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
        txRequest.sortDescriptors = [NSSortDescriptor(key: "pCreationTime", ascending: false)]
        txRequest.fetchLimit = 1
        let txs = try vault.container.viewContext.fetch(txRequest)
        let tx = try #require(txs.first)

        let txCurrency = BaseRepository.relatedObject(tx, "pCurrency")
        let txCurrencyCode = txCurrency.map { BaseRepository.stringValue($0, "pCode") }
        #expect(txCurrencyCode == "EUR", "Transaction should use EUR from account, not USD")
    }

    @Test("transaction create uses account currency")
    func transactionCreateUsesAccountCurrency() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedTransactionTypes(in: vault.container)

        // Create a checking account (PrimaryAccount with pAccountClass=1) with EUR
        let ctx = vault.container.viewContext
        let account = NSEntityDescription.insertNewObject(forEntityName: "PrimaryAccount", into: ctx)
        account.setValue("Test Checking", forKey: "pName")
        account.setValue(UUID().uuidString, forKey: "pUniqueID")
        account.setValue(Int16(1), forKey: "pAccountClass")
        account.setValue(false, forKey: "pHidden")
        account.setValue(eur, forKey: "currency")
        account.setValue(Date(), forKey: "pCreationTime")
        account.setValue(Date(), forKey: "pModificationDate")
        try ctx.save()
        let accountPK = BaseRepository.extractPK(from: account.objectID)

        let lineItemRepo = LineItemRepository(container: vault.container)
        let txRepo = TransactionRepository(container: vault.container, lineItemRepo: lineItemRepo)
        let result = try txRepo.create(
            date: "2026-02-01", title: "Test Currency TX",
            lineItems: [(accountId: accountPK, amount: -50.0, memo: nil)]
        )
        #expect(result.title == "Test Currency TX")

        // Verify the transaction has EUR currency
        vault.container.viewContext.refreshAllObjects()
        let txRequest = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
        txRequest.predicate = NSPredicate(format: "pTitle == %@", "Test Currency TX")
        txRequest.fetchLimit = 1
        let txs = try vault.container.viewContext.fetch(txRequest)
        let tx = try #require(txs.first)

        let txCurrency = BaseRepository.relatedObject(tx, "pCurrency")
        let txCurrencyCode = txCurrency.map { BaseRepository.stringValue($0, "pCode") }
        #expect(txCurrencyCode == "EUR")
    }
}
