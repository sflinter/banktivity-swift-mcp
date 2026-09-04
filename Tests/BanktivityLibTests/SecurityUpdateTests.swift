// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

@Suite("Security updates", .serialized)
struct SecurityUpdateTests {
    @Test("updateSecurityLineItem updates commission and sync blob")
    func updateTradeCommission() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let (_, sellType) = try TestVaultHelper.seedTransactionTypes(in: vault.container)
        _ = try TestVaultHelper.seedSyncedDocument(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)

        let ctx = vault.container.viewContext
        let tx = NSEntityDescription.insertNewObject(forEntityName: "Transaction", into: ctx)
        let txUUID = UUID().uuidString
        tx.setValue(txUUID, forKey: "pUniqueID")
        tx.setValue(Date(), forKey: "pDate")
        tx.setValue("Test sell", forKey: "pTitle")
        tx.setValue(eur, forKey: "pCurrency")
        tx.setValue(sellType, forKey: "pTransactionType")
        tx.setValue(Date(), forKey: "pCreationTime")
        tx.setValue(Date(), forKey: "pModificationDate")

        let li = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
        let liUUID = UUID().uuidString
        li.setValue(liUUID, forKey: "pUniqueID")
        li.setValue(account, forKey: "pAccount")
        li.setValue(tx, forKey: "pTransaction")
        li.setValue(0.0 as NSNumber, forKey: "pTransactionAmount")
        li.setValue(Date(), forKey: "pCreationTime")

        let sli = NSEntityDescription.insertNewObject(forEntityName: "SecurityLineItem", into: ctx)
        sli.setValue(security, forKey: "pSecurity")
        sli.setValue(li, forKey: "pLineItem")
        sli.setValue(-1.0 as NSNumber, forKey: "pShares")
        sli.setValue(100.0 as NSNumber, forKey: "pAmount")
        sli.setValue(100.0 as NSNumber, forKey: "pPricePerShare")
        sli.setValue(100.0 as NSNumber, forKey: "pCommission")
        sli.setValue(0.0 as NSNumber, forKey: "pIncome")
        sli.setValue(1.0 as NSNumber, forKey: "pPriceMultiplier")
        try ctx.save()

        let syncLI = SyncBlobUpdater.SyncLineItem(
            accountUUID: BaseRepository.stringValue(account, "pUniqueID"),
            accountAmount: 100.0,
            cleared: false,
            identifier: liUUID,
            memo: nil,
            securityLineItem: SyncBlobUpdater.SyncSecurityLineItem(
                amount: 100.0,
                commission: 100.0,
                pricePerShare: 100.0,
                priceMultiplier: 1.0,
                securityUUID: BaseRepository.stringValue(security, "pUniqueID"),
                shares: -1.0,
                hasDistributionType: false
            ),
            transactionAmount: 100.0
        )
        let updater = SyncBlobUpdater(container: vault.container)
        updater.createTransactionSyncRecord(
            transactionUUID: txUUID,
            currencyUUID: BaseRepository.stringValue(eur, "pUniqueID"),
            date: "2026-01-01",
            title: "Test sell",
            note: nil,
            adjustment: false,
            lineItems: [syncLI],
            transactionTypeBaseType: "Sell",
            transactionTypeUUID: BaseRepository.stringValue(sellType, "pUniqueID")
        )

        let repo = SecurityRepository(container: vault.container, syncBlobUpdater: updater)
        let txPK = BaseRepository.extractPK(from: tx.objectID)
        let result = try repo.updateSecurityLineItem(
            transactionId: txPK,
            pricePerShare: 12.34,
            amount: 56.78,
            commission: 0.0
        )

        #expect(abs(result.pricePerShare - 12.34) < 0.000001)
        #expect(abs(result.amount - 56.78) < 0.000001)
        #expect(result.commission == 0.0)

        ctx.refreshAllObjects()
        let sliRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityLineItem")
        let updatedSLI = try #require(try ctx.fetch(sliRequest).first)
        #expect(BaseRepository.doubleValue(updatedSLI, "pCommission") == 0.0)

        let syncRequest = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        syncRequest.predicate = NSPredicate(format: "pLocalID == %@", txUUID)
        let record = try #require(try ctx.fetch(syncRequest).first)
        let blobData = try #require(record.value(forKey: "pRemoteEntityData") as? Data)
        let decompressed = try #require(SyncBlobUpdater.decompressGzip(blobData))
        let xml = try #require(String(data: decompressed, encoding: .utf8))

        #expect(xml.contains("name=\"commission\""))
        #expect(xml.contains("<field type=\"decimal\" name=\"commission\">0</field>"))
    }
    @Test("basis-only transfer update requires zero cash line")
    func basisOnlyTransferUpdateRequiresZeroCashLine() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let (buyType, _) = try TestVaultHelper.seedTransactionTypes(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)

        let ctx = vault.container.viewContext
        let tx = NSEntityDescription.insertNewObject(forEntityName: "Transaction", into: ctx)
        tx.setValue(UUID().uuidString, forKey: "pUniqueID")
        tx.setValue(Date(), forKey: "pDate")
        tx.setValue("Transfer in RBLX", forKey: "pTitle")
        tx.setValue("SECURITY ADJUSTMENT", forKey: "pNote")
        tx.setValue(eur, forKey: "pCurrency")
        tx.setValue(buyType, forKey: "pTransactionType")
        tx.setValue(Date(), forKey: "pCreationTime")
        tx.setValue(Date(), forKey: "pModificationDate")

        let lineItem = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
        lineItem.setValue(UUID().uuidString, forKey: "pUniqueID")
        lineItem.setValue(account, forKey: "pAccount")
        lineItem.setValue(tx, forKey: "pTransaction")
        lineItem.setValue(0.0 as NSNumber, forKey: "pTransactionAmount")
        lineItem.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
        lineItem.setValue(Date(), forKey: "pCreationTime")

        let securityLineItem = NSEntityDescription.insertNewObject(forEntityName: "SecurityLineItem", into: ctx)
        securityLineItem.setValue(security, forKey: "pSecurity")
        securityLineItem.setValue(lineItem, forKey: "pLineItem")
        securityLineItem.setValue(20.0 as NSNumber, forKey: "pShares")
        securityLineItem.setValue(0.0 as NSNumber, forKey: "pAmount")
        securityLineItem.setValue(0.0 as NSNumber, forKey: "pPricePerShare")
        securityLineItem.setValue(0.0 as NSNumber, forKey: "pCommission")
        securityLineItem.setValue(0.0 as NSNumber, forKey: "pIncome")
        securityLineItem.setValue(1.0 as NSNumber, forKey: "pPriceMultiplier")
        try ctx.obtainPermanentIDs(for: [tx, lineItem, securityLineItem])
        try ctx.save()

        let repo = SecurityRepository(container: vault.container)
        let txPK = BaseRepository.extractPK(from: tx.objectID)
        let updated = try repo.updateSecurityLineItem(
            transactionId: txPK,
            pricePerShare: 99.3295,
            amount: -1986.59,
            basisOnlyTransfer: true
        )
        #expect(abs(updated.pricePerShare - 99.3295) < 0.000001)
        #expect(abs(updated.amount - -1986.59) < 0.000001)

        let lineItemRepo = LineItemRepository(container: vault.container)
        let lineItems = try lineItemRepo.getForTransactionPK(txPK)
        let accountLine = try #require(lineItems.first { $0.accountId == BaseRepository.extractPK(from: account.objectID) })
        #expect(abs(accountLine.amount) < 0.005)

        lineItem.setValue(1.0 as NSNumber, forKey: "pTransactionAmount")
        try ctx.save()

        #expect(throws: (any Error).self) {
            try repo.updateSecurityLineItem(
                transactionId: txPK,
                amount: -2000,
                basisOnlyTransfer: true
            )
        }
    }
}
