// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

@Suite("SyncRecord", .serialized)
struct SyncRecordTests {

    @Test("gzip round-trip preserves data")
    func gzipRoundTrip() {
        let original = "Hello, this is a test of gzip compression!".data(using: .utf8)!
        let compressed = SyncBlobUpdater.compressGzip(original)
        #expect(compressed != nil)
        let decompressed = SyncBlobUpdater.decompressGzip(compressed!)
        #expect(decompressed == original)
    }

    @Test("createTransactionSyncRecord creates SyncedHostedEntity")
    func createSyncRecord() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedSyncedDocument(in: vault.container)

        let updater = SyncBlobUpdater(container: vault.container)
        let txUUID = UUID().uuidString
        let eurUUID = BaseRepository.stringValue(eur, "pUniqueID")
        let liUUID = UUID().uuidString

        let syncLI = SyncBlobUpdater.SyncLineItem(
            accountUUID: nil, accountAmount: -100,
            cleared: false, identifier: liUUID, memo: nil,
            securityLineItem: nil, transactionAmount: -100
        )

        updater.createTransactionSyncRecord(
            transactionUUID: txUUID, currencyUUID: eurUUID,
            date: "2026-01-15", title: "Test Sync", note: nil,
            adjustment: false, lineItems: [syncLI],
            transactionTypeBaseType: "deposit", transactionTypeUUID: UUID().uuidString
        )

        // Verify the record was created
        let request = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        request.predicate = NSPredicate(format: "pLocalID == %@", txUUID)
        let records = try vault.container.viewContext.fetch(request)
        #expect(records.count == 1)

        let record = try #require(records.first)
        #expect(BaseRepository.stringValue(record, "pLocalID") == txUUID)
        #expect(BaseRepository.stringValue(record, "pRemoteID") == txUUID)
        #expect(BaseRepository.stringValue(record, "pHostedEntityType") == "Transaction")
        #expect(BaseRepository.intValue(record, "pSyncedState") == 0)

        // pSyncedModificationDate must be NULL for sync pickup
        let syncModDate = record.value(forKey: "pSyncedModificationDate")
        #expect(syncModDate == nil, "pSyncedModificationDate must be NULL")
    }

    @Test("created blob decompresses to valid XML")
    func createdBlobIsValidXML() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)

        let updater = SyncBlobUpdater(container: vault.container)
        let txUUID = UUID().uuidString
        let eurUUID = BaseRepository.stringValue(eur, "pUniqueID")
        let liUUID = UUID().uuidString

        let syncLI = SyncBlobUpdater.SyncLineItem(
            accountUUID: UUID().uuidString, accountAmount: 50,
            cleared: false, identifier: liUUID, memo: nil,
            securityLineItem: nil, transactionAmount: 50
        )

        updater.createTransactionSyncRecord(
            transactionUUID: txUUID, currencyUUID: eurUUID,
            date: "2026-03-01", title: "XML Test", note: "A note",
            adjustment: false, lineItems: [syncLI],
            transactionTypeBaseType: "withdrawal", transactionTypeUUID: UUID().uuidString
        )

        let request = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        request.predicate = NSPredicate(format: "pLocalID == %@", txUUID)
        let record = try #require(try vault.container.viewContext.fetch(request).first)

        let blobData = try #require(record.value(forKey: "pRemoteEntityData") as? Data)
        let decompressed = try #require(SyncBlobUpdater.decompressGzip(blobData))
        let xml = try #require(String(data: decompressed, encoding: .utf8))

        #expect(xml.hasPrefix("<entity type=\"Transaction\""))
        #expect(xml.hasSuffix("</entity>"))
        #expect(xml.contains("id=\"\(txUUID)\""))
        #expect(xml.contains("Currency:\(eurUUID)"))
        #expect(xml.contains("XML Test"))
        #expect(xml.contains("A note"))
        // Verify the typo is preserved
        #expect(xml.contains("transacitonAmount"))
    }

    @Test("createShareAdjustment with syncBlobUpdater creates sync record")
    func adjustmentCreatesSyncRecord() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedTransactionTypes(in: vault.container)
        _ = try TestVaultHelper.seedSyncedDocument(in: vault.container)

        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let accountPK = BaseRepository.extractPK(from: account.objectID)
        let sec = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)
        let symbol = BaseRepository.stringValue(sec, "pSymbol")

        let updater = SyncBlobUpdater(container: vault.container)
        let secRepo = SecurityRepository(container: vault.container, syncBlobUpdater: updater)
        _ = try secRepo.createShareAdjustment(
            accountId: accountPK, symbol: symbol, shares: 5.0, date: "2026-02-15"
        )

        // Should have created exactly one sync record
        let request = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        request.predicate = NSPredicate(format: "pHostedEntityType == %@", "Transaction")
        let records = try vault.container.viewContext.fetch(request)
        #expect(records.count == 1)

        // Verify blob contains security line item data
        let record = try #require(records.first)
        let blobData = try #require(record.value(forKey: "pRemoteEntityData") as? Data)
        let decompressed = try #require(SyncBlobUpdater.decompressGzip(blobData))
        let xml = try #require(String(data: decompressed, encoding: .utf8))

        #expect(xml.contains("SecurityLineItem"))
        #expect(xml.contains("shares"))
        // distType=0 (adjustment) should NOT have distributionType
        #expect(!xml.contains("distributionType"))
    }

    @Test("transaction create with syncBlobUpdater creates sync record")
    func transactionCreateCreatesSyncRecord() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedTransactionTypes(in: vault.container)
        _ = try TestVaultHelper.seedSyncedDocument(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let accountPK = BaseRepository.extractPK(from: account.objectID)
        let accountUUID = BaseRepository.stringValue(account, "pUniqueID")

        let updater = SyncBlobUpdater(container: vault.container)
        let lineItems = LineItemRepository(container: vault.container)
        let transactions = TransactionRepository(
            container: vault.container,
            lineItemRepo: lineItems,
            syncBlobUpdater: updater
        )

        let created = try transactions.create(
            date: "2026-04-01",
            title: "ADVISORY FEE",
            note: "Test fee",
            lineItems: [(accountId: accountPK, amount: -12.34, memo: "fee")]
        )

        let request = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        request.predicate = NSPredicate(format: "pHostedEntityType == %@", "Transaction")
        let records = try vault.container.viewContext.fetch(request)
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(BaseRepository.stringValue(record, "pLocalID") != "")
        #expect(BaseRepository.intValue(record, "pSyncedState") == 0)

        let blobData = try #require(record.value(forKey: "pRemoteEntityData") as? Data)
        let decompressed = try #require(SyncBlobUpdater.decompressGzip(blobData))
        let xml = try #require(String(data: decompressed, encoding: .utf8))
        #expect(xml.contains("ADVISORY FEE"))
        #expect(xml.contains("Test fee"))
        #expect(xml.contains("Account:\(accountUUID)"))
        #expect(xml.contains("<field type=\"decimal\" name=\"accountAmount\">-12.34</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"transacitonAmount\">-12.34</field>"))
        #expect(created.title == "ADVISORY FEE")
    }

    @Test("updateSecurityLineItem can repair cash line item amounts and sync blob")
    func updateSecurityLineItemRepairsCashLineAmounts() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let txTypes = try TestVaultHelper.seedTransactionTypes(in: vault.container)
        _ = try TestVaultHelper.seedSyncedDocument(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)
        let accountPK = BaseRepository.extractPK(from: account.objectID)
        let securityUUID = BaseRepository.stringValue(security, "pUniqueID")
        let accountUUID = BaseRepository.stringValue(account, "pUniqueID")
        let eurUUID = BaseRepository.stringValue(eur, "pUniqueID")
        let buyTypeUUID = BaseRepository.stringValue(txTypes.buy, "pUniqueID")

        let ctx = vault.container.viewContext
        let tx = NSEntityDescription.insertNewObject(forEntityName: "Transaction", into: ctx)
        let txUUID = BaseRepository.generateUUID()
        tx.setValue("TEST BUY", forKey: "pTitle")
        tx.setValue(txUUID, forKey: "pUniqueID")
        tx.setValue(false, forKey: "pCleared")
        tx.setValue(false, forKey: "pVoid")
        tx.setValue(false, forKey: "pAdjustment")
        BaseRepository.setDate(tx, "pDate", isoString: "2026-03-01")
        BaseRepository.setNow(tx, "pCreationTime")
        BaseRepository.setNow(tx, "pModificationDate")
        tx.setValue(eur, forKey: "pCurrency")
        tx.setValue(txTypes.buy, forKey: "pTransactionType")

        let cashLI = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
        let cashLIUUID = BaseRepository.generateUUID()
        cashLI.setValue(0.0 as NSNumber, forKey: "pTransactionAmount")
        cashLI.setValue(cashLIUUID, forKey: "pUniqueID")
        cashLI.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
        cashLI.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
        cashLI.setValue(false, forKey: "pCleared")
        BaseRepository.setNow(cashLI, "pCreationTime")
        cashLI.setValue(account, forKey: "pAccount")
        cashLI.setValue(tx, forKey: "pTransaction")

        let offsetLI = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
        let offsetLIUUID = BaseRepository.generateUUID()
        offsetLI.setValue(0.0 as NSNumber, forKey: "pTransactionAmount")
        offsetLI.setValue(offsetLIUUID, forKey: "pUniqueID")
        offsetLI.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
        offsetLI.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
        offsetLI.setValue(false, forKey: "pCleared")
        BaseRepository.setNow(offsetLI, "pCreationTime")
        offsetLI.setValue(tx, forKey: "pTransaction")

        let sli = NSEntityDescription.insertNewObject(forEntityName: "SecurityLineItem", into: ctx)
        sli.setValue(10.0 as NSNumber, forKey: "pShares")
        sli.setValue(-100.0 as NSNumber, forKey: "pAmount")
        sli.setValue(10.0 as NSNumber, forKey: "pPricePerShare")
        sli.setValue(0.0 as NSNumber, forKey: "pCommission")
        sli.setValue(0.0 as NSNumber, forKey: "pIncome")
        sli.setValue(1.0 as NSNumber, forKey: "pPriceMultiplier")
        sli.setValue(security, forKey: "pSecurity")
        sli.setValue(cashLI, forKey: "pLineItem")

        try ctx.obtainPermanentIDs(for: [tx, cashLI, offsetLI, sli])
        try ctx.save()
        let txPK = BaseRepository.extractPK(from: tx.objectID)

        let updater = SyncBlobUpdater(container: vault.container)
        let syncSLI = SyncBlobUpdater.SyncSecurityLineItem(
            amount: -100, commission: 0, pricePerShare: 10,
            priceMultiplier: 1, securityUUID: securityUUID, shares: 10,
            hasDistributionType: false
        )
        let cashSyncLI = SyncBlobUpdater.SyncLineItem(
            accountUUID: accountUUID, accountAmount: 0,
            cleared: false, identifier: cashLIUUID, memo: nil,
            securityLineItem: syncSLI, transactionAmount: 0
        )
        let offsetSyncLI = SyncBlobUpdater.SyncLineItem(
            accountUUID: nil, accountAmount: 0,
            cleared: false, identifier: offsetLIUUID, memo: nil,
            securityLineItem: nil, transactionAmount: 0
        )
        updater.createTransactionSyncRecord(
            transactionUUID: txUUID, currencyUUID: eurUUID,
            date: "2026-03-01", title: "TEST BUY", note: nil,
            adjustment: false, lineItems: [cashSyncLI, offsetSyncLI],
            transactionTypeBaseType: "buy", transactionTypeUUID: buyTypeUUID
        )

        let repo = SecurityRepository(container: vault.container, syncBlobUpdater: updater)
        let updated = try repo.updateSecurityLineItem(
            transactionId: txPK,
            amount: -125,
            cashLineItemAmount: -125
        )
        #expect(updated.amount == -125)

        let lineItems = try LineItemRepository(container: vault.container).getForTransactionPK(txPK)
        let accountLine = try #require(lineItems.first { $0.accountId == accountPK })
        let balancingLine = try #require(lineItems.first { $0.accountId == 0 })
        #expect(accountLine.amount == -125)
        #expect(balancingLine.amount == 125)
        #expect(accountLine.runningBalance == -125)

        let request = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        request.predicate = NSPredicate(format: "pLocalID == %@", txUUID)
        let record = try #require(try vault.container.viewContext.fetch(request).first)
        let blobData = try #require(record.value(forKey: "pRemoteEntityData") as? Data)
        let decompressed = try #require(SyncBlobUpdater.decompressGzip(blobData))
        let xml = try #require(String(data: decompressed, encoding: .utf8))
        #expect(xml.contains("<field type=\"decimal\" name=\"cost\">-125</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"accountAmount\">-125</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"transacitonAmount\">-125</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"accountAmount\">125</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"transacitonAmount\">125</field>"))
    }

    @Test("updateSecurityLineItem can repair cash line item amounts with category offset")
    func updateSecurityLineItemRepairsCashLineAmountsWithCategoryOffset() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let txTypes = try TestVaultHelper.seedTransactionTypes(in: vault.container)
        _ = try TestVaultHelper.seedSyncedDocument(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)
        let accountPK = BaseRepository.extractPK(from: account.objectID)
        let securityUUID = BaseRepository.stringValue(security, "pUniqueID")
        let accountUUID = BaseRepository.stringValue(account, "pUniqueID")
        let eurUUID = BaseRepository.stringValue(eur, "pUniqueID")
        let sellTypeUUID = BaseRepository.stringValue(txTypes.sell, "pUniqueID")

        let ctx = vault.container.viewContext
        let category = NSEntityDescription.insertNewObject(forEntityName: "PrimaryAccount", into: ctx)
        category.setValue("Dividend Income Tax-Free", forKey: "pName")
        category.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
        category.setValue(Int16(AccountClass.income), forKey: "pAccountClass")
        category.setValue(false, forKey: "pHidden")
        category.setValue(eur, forKey: "currency")
        BaseRepository.setNow(category, "pCreationTime")
        BaseRepository.setNow(category, "pModificationDate")
        let categoryUUID = BaseRepository.stringValue(category, "pUniqueID")

        let tx = NSEntityDescription.insertNewObject(forEntityName: "Transaction", into: ctx)
        let txUUID = BaseRepository.generateUUID()
        tx.setValue("TEST SELL", forKey: "pTitle")
        tx.setValue(txUUID, forKey: "pUniqueID")
        tx.setValue(false, forKey: "pCleared")
        tx.setValue(false, forKey: "pVoid")
        tx.setValue(false, forKey: "pAdjustment")
        BaseRepository.setDate(tx, "pDate", isoString: "2026-04-01")
        BaseRepository.setNow(tx, "pCreationTime")
        BaseRepository.setNow(tx, "pModificationDate")
        tx.setValue(eur, forKey: "pCurrency")
        tx.setValue(txTypes.sell, forKey: "pTransactionType")

        let cashLI = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
        let cashLIUUID = BaseRepository.generateUUID()
        cashLI.setValue(0.0 as NSNumber, forKey: "pTransactionAmount")
        cashLI.setValue(cashLIUUID, forKey: "pUniqueID")
        cashLI.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
        cashLI.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
        cashLI.setValue(false, forKey: "pCleared")
        BaseRepository.setNow(cashLI, "pCreationTime")
        cashLI.setValue(account, forKey: "pAccount")
        cashLI.setValue(tx, forKey: "pTransaction")

        let categoryLI = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
        let categoryLIUUID = BaseRepository.generateUUID()
        categoryLI.setValue(0.0 as NSNumber, forKey: "pTransactionAmount")
        categoryLI.setValue(categoryLIUUID, forKey: "pUniqueID")
        categoryLI.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
        categoryLI.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
        categoryLI.setValue(false, forKey: "pCleared")
        BaseRepository.setNow(categoryLI, "pCreationTime")
        categoryLI.setValue(category, forKey: "pAccount")
        categoryLI.setValue(tx, forKey: "pTransaction")

        let sli = NSEntityDescription.insertNewObject(forEntityName: "SecurityLineItem", into: ctx)
        sli.setValue(-1.0 as NSNumber, forKey: "pShares")
        sli.setValue(100.0 as NSNumber, forKey: "pAmount")
        sli.setValue(100.0 as NSNumber, forKey: "pPricePerShare")
        sli.setValue(0.0 as NSNumber, forKey: "pCommission")
        sli.setValue(0.0 as NSNumber, forKey: "pIncome")
        sli.setValue(1.0 as NSNumber, forKey: "pPriceMultiplier")
        sli.setValue(security, forKey: "pSecurity")
        sli.setValue(cashLI, forKey: "pLineItem")

        try ctx.obtainPermanentIDs(for: [category, tx, cashLI, categoryLI, sli])
        try ctx.save()
        let txPK = BaseRepository.extractPK(from: tx.objectID)

        let updater = SyncBlobUpdater(container: vault.container)
        let syncSLI = SyncBlobUpdater.SyncSecurityLineItem(
            amount: 100, commission: 0, pricePerShare: 100,
            priceMultiplier: 1, securityUUID: securityUUID, shares: -1,
            hasDistributionType: false
        )
        let cashSyncLI = SyncBlobUpdater.SyncLineItem(
            accountUUID: accountUUID, accountAmount: 0,
            cleared: false, identifier: cashLIUUID, memo: nil,
            securityLineItem: syncSLI, transactionAmount: 0
        )
        let categorySyncLI = SyncBlobUpdater.SyncLineItem(
            accountUUID: categoryUUID, accountAmount: 0,
            cleared: false, identifier: categoryLIUUID, memo: nil,
            securityLineItem: nil, transactionAmount: 0
        )
        updater.createTransactionSyncRecord(
            transactionUUID: txUUID, currencyUUID: eurUUID,
            date: "2026-04-01", title: "TEST SELL", note: nil,
            adjustment: false, lineItems: [cashSyncLI, categorySyncLI],
            transactionTypeBaseType: "sell", transactionTypeUUID: sellTypeUUID
        )

        let repo = SecurityRepository(container: vault.container, syncBlobUpdater: updater)
        let updated = try repo.updateSecurityLineItem(
            transactionId: txPK,
            cashLineItemAmount: 596.06
        )
        #expect(updated.amount == 100)

        let lineItems = try LineItemRepository(container: vault.container).getForTransactionPK(txPK)
        let accountLine = try #require(lineItems.first { $0.accountId == accountPK })
        let categoryLine = try #require(lineItems.first { $0.accountId != accountPK })
        #expect(abs(accountLine.amount - 596.06) < 0.000001)
        #expect(abs(categoryLine.amount + 596.06) < 0.000001)

        let request = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        request.predicate = NSPredicate(format: "pLocalID == %@", txUUID)
        let record = try #require(try vault.container.viewContext.fetch(request).first)
        let blobData = try #require(record.value(forKey: "pRemoteEntityData") as? Data)
        let decompressed = try #require(SyncBlobUpdater.decompressGzip(blobData))
        let xml = try #require(String(data: decompressed, encoding: .utf8))
        #expect(xml.contains("<field type=\"string\" name=\"identifier\">\(cashLIUUID)</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"accountAmount\">596.06</field>"))
        #expect(xml.contains("<field type=\"string\" name=\"identifier\">\(categoryLIUUID)</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"accountAmount\">-596.06</field>"))
    }

    @Test("deleteSyncRecord sets state=3 and timestamps for sync deletion")
    func deleteSyncRecord() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)

        let updater = SyncBlobUpdater(container: vault.container)
        let txUUID = UUID().uuidString

        let syncLI = SyncBlobUpdater.SyncLineItem(
            accountUUID: nil, accountAmount: 0,
            cleared: false, identifier: UUID().uuidString, memo: nil,
            securityLineItem: nil, transactionAmount: 0
        )

        updater.createTransactionSyncRecord(
            transactionUUID: txUUID, currencyUUID: BaseRepository.stringValue(eur, "pUniqueID"),
            date: "2026-01-01", title: "To Delete", note: nil,
            adjustment: false, lineItems: [syncLI],
            transactionTypeBaseType: "deposit", transactionTypeUUID: UUID().uuidString
        )

        // Verify exists with blob data and state=0
        let request = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        request.predicate = NSPredicate(format: "pLocalID == %@", txUUID)
        let before = try vault.container.viewContext.fetch(request)
        #expect(before.count == 1)
        #expect(before.first?.value(forKey: "pRemoteEntityData") != nil)
        #expect(before.first?.value(forKey: "pSyncedState") as? Int16 == 0)

        // Mark as deleted
        updater.deleteSyncRecord(entityUUID: txUUID)

        // Record kept with state=3, blob preserved, modification date set
        vault.container.viewContext.refreshAllObjects()
        let after = try vault.container.viewContext.fetch(request)
        #expect(after.count == 1, "Record should be kept for sync propagation")
        let record = try #require(after.first)
        #expect(record.value(forKey: "pSyncedState") as? Int16 == 3, "State must be 3 to signal deletion")
        #expect(record.value(forKey: "pRemoteEntityData") != nil, "Blob should be preserved")
        #expect(record.value(forKey: "pSyncedModificationDate") != nil, "Modification date must be set to trigger sync")
    }
}
