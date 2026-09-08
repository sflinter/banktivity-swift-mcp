// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

@Suite("Security updates", .serialized)
struct SecurityUpdateTests {

    @Test("getTrades maps transfer shares transaction type")
    func getTradesMapsTransferSharesTransactionType() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)

        let ctx = vault.container.viewContext
        let transferSharesType = NSEntityDescription.insertNewObject(forEntityName: "TransactionType", into: ctx)
        transferSharesType.setValue(Int16(212), forKey: "pBaseType")
        transferSharesType.setValue("Transfer Shares", forKey: "pName")
        transferSharesType.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
        BaseRepository.setNow(transferSharesType, "pCreationTime")
        BaseRepository.setNow(transferSharesType, "pModificationDate")

        let tx = NSEntityDescription.insertNewObject(forEntityName: "Transaction", into: ctx)
        tx.setValue("Opening DELL lot", forKey: "pTitle")
        tx.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
        tx.setValue(false, forKey: "pCleared")
        tx.setValue(false, forKey: "pVoid")
        tx.setValue(false, forKey: "pAdjustment")
        tx.setValue(transferSharesType, forKey: "pTransactionType")
        tx.setValue(eur, forKey: "pCurrency")
        BaseRepository.setDate(tx, "pDate", isoString: "2025-01-02")
        BaseRepository.setNow(tx, "pCreationTime")
        BaseRepository.setNow(tx, "pModificationDate")

        let lineItem = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
        lineItem.setValue(0.0 as NSNumber, forKey: "pTransactionAmount")
        lineItem.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
        lineItem.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
        lineItem.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
        lineItem.setValue(false, forKey: "pCleared")
        lineItem.setValue(account, forKey: "pAccount")
        lineItem.setValue(tx, forKey: "pTransaction")
        BaseRepository.setNow(lineItem, "pCreationTime")

        let securityLineItem = NSEntityDescription.insertNewObject(forEntityName: "SecurityLineItem", into: ctx)
        securityLineItem.setValue(10.0 as NSNumber, forKey: "pShares")
        securityLineItem.setValue(50.0 as NSNumber, forKey: "pPricePerShare")
        securityLineItem.setValue(500.0 as NSNumber, forKey: "pAmount")
        securityLineItem.setValue(0.0 as NSNumber, forKey: "pCommission")
        securityLineItem.setValue(security, forKey: "pSecurity")
        securityLineItem.setValue(lineItem, forKey: "pLineItem")
        try ctx.save()

        let repo = SecurityRepository(container: vault.container)
        let trades = try repo.getTrades(
            accountId: BaseRepository.extractPK(from: account.objectID),
            symbol: BaseRepository.stringValue(security, "pSymbol")
        )
        let trade = try #require(trades.first)

        #expect(trades.count == 1)
        #expect(trade.type == "Transfer Shares")
        #expect(trade.shares == 10.0)
        #expect(trade.amount == 500.0)
    }

    @Test("createSecurityTrade creates sell with category offset and sync blob")
    func createSecurityTradeSellWithCategoryOffset() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedTransactionTypes(in: vault.container)
        _ = try TestVaultHelper.seedSyncedDocument(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)

        let ctx = vault.container.viewContext
        let category = NSEntityDescription.insertNewObject(forEntityName: "PrimaryAccount", into: ctx)
        category.setValue("Realized Gain", forKey: "pName")
        category.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
        category.setValue(Int16(AccountClass.income), forKey: "pAccountClass")
        category.setValue(false, forKey: "pHidden")
        category.setValue(eur, forKey: "currency")
        BaseRepository.setNow(category, "pCreationTime")
        BaseRepository.setNow(category, "pModificationDate")
        try ctx.save()

        let updater = SyncBlobUpdater(container: vault.container)
        let repo = SecurityRepository(container: vault.container, syncBlobUpdater: updater)
        let accountPK = BaseRepository.extractPK(from: account.objectID)
        let categoryPK = BaseRepository.extractPK(from: category.objectID)
        let result = try repo.createSecurityTrade(
            accountId: accountPK,
            symbol: BaseRepository.stringValue(security, "pSymbol"),
            shares: -2.5,
            pricePerShare: 12.34,
            amount: 30.85,
            commission: 1.23,
            cashLineItemAmount: 596.06,
            date: "2026-04-15",
            title: "TEST SELL CREATE",
            memo: "provider sell",
            offsetCategoryId: categoryPK
        )

        #expect(result.type == "Sell")
        #expect(result.shares == -2.5)
        #expect(abs(result.pricePerShare - 12.34) < 0.000001)
        #expect(abs(result.amount - 30.85) < 0.000001)
        #expect(abs(result.commission - 1.23) < 0.000001)

        let lineItems = try LineItemRepository(container: vault.container).getForTransactionPK(result.id)
        #expect(lineItems.count == 2)
        let accountLine = try #require(lineItems.first { $0.accountId == accountPK })
        let categoryLine = try #require(lineItems.first { $0.accountId == categoryPK })
        #expect(abs(accountLine.amount - 596.06) < 0.000001)
        #expect(abs(categoryLine.amount + 596.06) < 0.000001)
        #expect(accountLine.memo == "provider sell")

        let sliRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityLineItem")
        let securityLineItems = try ctx.fetch(sliRequest)
        let createdSLI = try #require(securityLineItems.first)
        #expect(abs(BaseRepository.doubleValue(createdSLI, "pShares") + 2.5) < 0.000001)
        #expect(abs(BaseRepository.doubleValue(createdSLI, "pPricePerShare") - 12.34) < 0.000001)
        #expect(abs(BaseRepository.doubleValue(createdSLI, "pAmount") - 30.85) < 0.000001)
        #expect(abs(BaseRepository.doubleValue(createdSLI, "pCommission") - 1.23) < 0.000001)

        let txRequest = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
        txRequest.predicate = NSPredicate(format: "pTitle == %@", "TEST SELL CREATE")
        let tx = try #require(try ctx.fetch(txRequest).first)
        let txUUID = BaseRepository.stringValue(tx, "pUniqueID")
        let syncRequest = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        syncRequest.predicate = NSPredicate(format: "pLocalID == %@", txUUID)
        let record = try #require(try ctx.fetch(syncRequest).first)
        let blobData = try #require(record.value(forKey: "pRemoteEntityData") as? Data)
        let decompressed = try #require(SyncBlobUpdater.decompressGzip(blobData))
        let xml = try #require(String(data: decompressed, encoding: .utf8))

        #expect(xml.contains("<field enum=\"IGGCSyncAccountingTransactionBaseType\" name=\"baseType\">sell</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"shares\">-2.5</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"pricePerShare\">12.34</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"cost\">30.85</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"commission\">1.23</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"accountAmount\">596.06</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"accountAmount\">-596.06</field>"))
        #expect(xml.contains("Account:\(BaseRepository.stringValue(category, "pUniqueID"))"))
    }

    @Test("createSecurityTrade creates buy with negative cash line and readback identifiers")
    func createSecurityTradeBuyWithNegativeCashLine() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedTransactionTypes(in: vault.container)
        _ = try TestVaultHelper.seedSyncedDocument(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, symbol: "OGVXX", currency: eur)

        let updater = SyncBlobUpdater(container: vault.container)
        let repo = SecurityRepository(container: vault.container, syncBlobUpdater: updater)
        let accountPK = BaseRepository.extractPK(from: account.objectID)
        let result = try repo.createSecurityTrade(
            accountId: accountPK,
            symbol: "OGVXX",
            shares: 250000,
            pricePerShare: 1,
            amount: 250000,
            cashLineItemAmount: -250000,
            date: "2026-05-29",
            title: "BUY OGVXX",
            memo: "provider sweep purchase"
        )

        #expect(result.id > 0)
        #expect(result.type == "Buy")
        #expect(result.symbol == "OGVXX")
        #expect(result.securityName == BaseRepository.stringValue(security, "pName"))
        #expect(abs(result.shares - 250000) < 0.000001)
        #expect(abs(result.pricePerShare - 1) < 0.000001)
        #expect(abs(result.amount - 250000) < 0.000001)

        let lineItems = try LineItemRepository(container: vault.container).getForTransactionPK(result.id)
        #expect(lineItems.count == 2)
        let accountLine = try #require(lineItems.first { $0.accountId == accountPK })
        let balancingLine = try #require(lineItems.first { $0.accountId == 0 })
        #expect(abs(accountLine.amount + 250000) < 0.000001)
        #expect(abs(balancingLine.amount - 250000) < 0.000001)
        #expect(accountLine.memo == "provider sweep purchase")

        let trades = try repo.getTrades(
            accountId: accountPK,
            symbol: "OGVXX",
            startDate: "2026-05-01",
            endDate: "2026-05-31"
        )
        let trade = try #require(trades.first { $0.id == result.id })
        #expect(trade.type == "Buy")
        #expect(abs(trade.shares - 250000) < 0.000001)
        #expect(abs(trade.amount - 250000) < 0.000001)

        let ctx = vault.container.viewContext
        let txRequest = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
        txRequest.predicate = NSPredicate(format: "pTitle == %@", "BUY OGVXX")
        let tx = try #require(try ctx.fetch(txRequest).first)
        let txUUID = BaseRepository.stringValue(tx, "pUniqueID")
        let syncRequest = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        syncRequest.predicate = NSPredicate(format: "pLocalID == %@", txUUID)
        let record = try #require(try ctx.fetch(syncRequest).first)
        let blobData = try #require(record.value(forKey: "pRemoteEntityData") as? Data)
        let decompressed = try #require(SyncBlobUpdater.decompressGzip(blobData))
        let xml = try #require(String(data: decompressed, encoding: .utf8))

        #expect(xml.contains("<field enum=\"IGGCSyncAccountingTransactionBaseType\" name=\"baseType\">buy</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"shares\">250000</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"pricePerShare\">1</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"cost\">250000</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"accountAmount\">-250000</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"accountAmount\">250000</field>"))
    }

    @Test("createSecurityIncome creates native dividend income")
    func createSecurityIncomeDividend() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedSyncedDocument(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)

        let ctx = vault.container.viewContext
        let dividendType = NSEntityDescription.insertNewObject(forEntityName: "TransactionType", into: ctx)
        dividendType.setValue(Int16(301), forKey: "pBaseType")
        dividendType.setValue("Dividend", forKey: "pName")
        dividendType.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
        dividendType.setValue(Date(), forKey: "pCreationTime")
        dividendType.setValue(Date(), forKey: "pModificationDate")

        let category = NSEntityDescription.insertNewObject(forEntityName: "PrimaryAccount", into: ctx)
        category.setValue("Dividend Income", forKey: "pName")
        category.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
        category.setValue(Int16(AccountClass.income), forKey: "pAccountClass")
        category.setValue(false, forKey: "pHidden")
        category.setValue(eur, forKey: "currency")
        BaseRepository.setNow(category, "pCreationTime")
        BaseRepository.setNow(category, "pModificationDate")
        try ctx.save()

        let updater = SyncBlobUpdater(container: vault.container)
        let repo = SecurityRepository(container: vault.container, syncBlobUpdater: updater)
        let accountPK = BaseRepository.extractPK(from: account.objectID)
        let categoryPK = BaseRepository.extractPK(from: category.objectID)
        let result = try repo.createSecurityIncome(
            accountId: accountPK,
            symbol: BaseRepository.stringValue(security, "pSymbol"),
            amount: 93.07,
            date: "2026-01-21",
            title: "Qualified Dividend TEST",
            memo: "provider dividend",
            offsetCategoryId: categoryPK
        )

        #expect(result.type == "Dividend")
        #expect(result.amount == 93.07)
        #expect(result.symbol == BaseRepository.stringValue(security, "pSymbol"))

        let lineItems = try LineItemRepository(container: vault.container).getForTransactionPK(result.id)
        #expect(lineItems.count == 2)
        let accountLine = try #require(lineItems.first { $0.accountId == accountPK })
        let categoryLine = try #require(lineItems.first { $0.accountId == categoryPK })
        #expect(abs(accountLine.amount - 93.07) < 0.000001)
        #expect(abs(categoryLine.amount + 93.07) < 0.000001)
        #expect(accountLine.memo == "provider dividend")

        let incomeRows = try repo.getIncome(
            accountId: accountPK,
            symbol: BaseRepository.stringValue(security, "pSymbol"),
            startDate: "2026-01-01",
            endDate: "2026-01-31"
        )
        let incomeRow = try #require(incomeRows.first)
        #expect(incomeRows.count == 1)
        #expect(incomeRow.id == result.id)
        #expect(incomeRow.type == "Dividend")
        #expect(abs(incomeRow.amount - 93.07) < 0.000001)

        let sliRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityLineItem")
        let createdSLI = try #require(try ctx.fetch(sliRequest).first)
        #expect(abs(BaseRepository.doubleValue(createdSLI, "pIncome") - 93.07) < 0.000001)
        #expect(BaseRepository.doubleValue(createdSLI, "pShares") == 0.0)
        #expect(BaseRepository.doubleValue(createdSLI, "pAmount") == 0.0)

        let txRequest = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
        txRequest.predicate = NSPredicate(format: "pTitle == %@", "Qualified Dividend TEST")
        let tx = try #require(try ctx.fetch(txRequest).first)
        let txUUID = BaseRepository.stringValue(tx, "pUniqueID")
        let syncRequest = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        syncRequest.predicate = NSPredicate(format: "pLocalID == %@", txUUID)
        let record = try #require(try ctx.fetch(syncRequest).first)
        let blobData = try #require(record.value(forKey: "pRemoteEntityData") as? Data)
        let decompressed = try #require(SyncBlobUpdater.decompressGzip(blobData))
        let xml = try #require(String(data: decompressed, encoding: .utf8))

        #expect(xml.contains("<field enum=\"IGGCSyncAccountingTransactionBaseType\" name=\"baseType\">dividend</field>"))
        #expect(xml.contains("<field enum=\"IGGCSyncAccountingSecurityLineItemDistrbutionType\" name=\"distributionType\">deposit</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"income\">93.07</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"accountAmount\">93.07</field>"))
        #expect(xml.contains("<field type=\"decimal\" name=\"accountAmount\">-93.07</field>"))
        #expect(xml.contains("Account:\(BaseRepository.stringValue(category, "pUniqueID"))"))
    }


    // MARK: - Security deletion

    /// Attach a SecurityLineItem to a security so it counts as referenced.
    private func seedTrade(
        in container: NSPersistentContainer,
        security: NSManagedObject,
        account: NSManagedObject,
        currency: NSManagedObject
    ) throws {
        let ctx = container.viewContext
        let txType = NSEntityDescription.insertNewObject(forEntityName: "TransactionType", into: ctx)
        txType.setValue(Int16(200), forKey: "pBaseType")
        txType.setValue("Buy", forKey: "pName")
        txType.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
        BaseRepository.setNow(txType, "pCreationTime")
        BaseRepository.setNow(txType, "pModificationDate")

        let tx = NSEntityDescription.insertNewObject(forEntityName: "Transaction", into: ctx)
        tx.setValue("Buy TEST", forKey: "pTitle")
        tx.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
        tx.setValue(false, forKey: "pCleared")
        tx.setValue(false, forKey: "pVoid")
        tx.setValue(false, forKey: "pAdjustment")
        tx.setValue(txType, forKey: "pTransactionType")
        tx.setValue(currency, forKey: "pCurrency")
        BaseRepository.setDate(tx, "pDate", isoString: "2025-03-01")
        BaseRepository.setNow(tx, "pCreationTime")
        BaseRepository.setNow(tx, "pModificationDate")

        let lineItem = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
        lineItem.setValue(100.0 as NSNumber, forKey: "pTransactionAmount")
        lineItem.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
        lineItem.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
        lineItem.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
        lineItem.setValue(false, forKey: "pCleared")
        lineItem.setValue(account, forKey: "pAccount")
        lineItem.setValue(tx, forKey: "pTransaction")
        BaseRepository.setNow(lineItem, "pCreationTime")

        let sli = NSEntityDescription.insertNewObject(forEntityName: "SecurityLineItem", into: ctx)
        sli.setValue(5.0 as NSNumber, forKey: "pShares")
        sli.setValue(20.0 as NSNumber, forKey: "pPricePerShare")
        sli.setValue(100.0 as NSNumber, forKey: "pAmount")
        sli.setValue(0.0 as NSNumber, forKey: "pCommission")
        sli.setValue(security, forKey: "pSecurity")
        sli.setValue(lineItem, forKey: "pLineItem")
        try ctx.save()
    }

    /// Give a security a SecurityPriceItem holding `count` SecurityPrice rows.
    private func seedPrices(
        in container: NSPersistentContainer,
        security: NSManagedObject,
        count: Int
    ) throws {
        let ctx = container.viewContext
        let uniqueId = BaseRepository.stringValue(security, "pUniqueID")
        let priceItem = BaseRepository.createObject(entityName: "SecurityPriceItem", in: ctx)
        priceItem.setValue(uniqueId, forKey: "pSecurityID")
        for i in 0..<count {
            let price = BaseRepository.createObject(entityName: "SecurityPrice", in: ctx)
            price.setValue(Int32(20000 + i), forKey: "pDate")
            price.setValue(10.0 as NSNumber, forKey: "pClosePrice")
            price.setValue(10.0 as NSNumber, forKey: "pAdjustedClosePrice")
            price.setValue(10.0 as NSNumber, forKey: "pOpenPrice")
            price.setValue(10.0 as NSNumber, forKey: "pHighPrice")
            price.setValue(10.0 as NSNumber, forKey: "pLowPrice")
            price.setValue(0.0 as NSNumber, forKey: "pVolume")
            price.setValue(0 as Int32, forKey: "pDataSource")
            price.setValue(priceItem, forKey: "pSecurityPriceItem")
        }
        try ctx.save()
    }

    private func securityCount(in container: NSPersistentContainer) throws -> Int {
        try container.viewContext.count(for: NSFetchRequest<NSManagedObject>(entityName: "Security"))
    }

    @Test("inspectForDeletion counts referencing trades and prices")
    func inspectForDeletionCounts() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)
        try seedTrade(in: vault.container, security: security, account: account, currency: eur)
        try seedPrices(in: vault.container, security: security, count: 3)

        let repo = SecurityRepository(container: vault.container)
        let info = try #require(try repo.inspectForDeletion(symbol: "TEST"))

        #expect(info.symbol == "TEST")
        #expect(info.tradeCount == 1)
        #expect(info.priceCount == 3)
        #expect(info.uniqueID == BaseRepository.stringValue(security, "pUniqueID"))
        #expect(try repo.inspectForDeletion(symbol: "NOSUCH") == nil)
    }

    @Test("deleteSecurity refuses a security that trades still reference")
    func deleteSecurityRefusesReferencedSecurity() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)
        try seedTrade(in: vault.container, security: security, account: account, currency: eur)

        let repo = SecurityRepository(container: vault.container)
        #expect(throws: (any Error).self) {
            _ = try repo.deleteSecurity(symbol: "TEST")
        }
        // withPrices does not override the trade invariant.
        #expect(throws: (any Error).self) {
            _ = try repo.deleteSecurity(symbol: "TEST", withPrices: true)
        }
        #expect(try securityCount(in: vault.container) == 1)
    }

    @Test("deleteSecurity refuses price history unless withPrices is set")
    func deleteSecurityRefusesPriceHistory() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)
        try seedPrices(in: vault.container, security: security, count: 2)

        let repo = SecurityRepository(container: vault.container)
        #expect(throws: (any Error).self) {
            _ = try repo.deleteSecurity(symbol: "TEST")
        }

        let ctx = vault.container.viewContext
        ctx.refreshAllObjects()
        #expect(try securityCount(in: vault.container) == 1)
        #expect(try ctx.count(for: NSFetchRequest<NSManagedObject>(entityName: "SecurityPrice")) == 2)
    }

    @Test("deleteSecurity removes a security nothing references")
    func deleteSecurityRemovesCleanSecurity() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedSecurity(in: vault.container, symbol: "KEEP", currency: eur)
        _ = try TestVaultHelper.seedSecurity(in: vault.container, symbol: "TEST", currency: eur)

        let repo = SecurityRepository(container: vault.container)
        #expect(try repo.deleteSecurity(symbol: "TEST") == 1)

        let ctx = vault.container.viewContext
        ctx.refreshAllObjects()
        #expect(try securityCount(in: vault.container) == 1)
        #expect(try repo.inspectForDeletion(symbol: "TEST") == nil)
        // The unrelated security is untouched.
        #expect(try repo.inspectForDeletion(symbol: "KEEP") != nil)
    }

    @Test("deleteSecurity with prices leaves no orphaned SecurityPriceItem")
    func deleteSecurityWithPricesLeavesNoOrphan() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)
        try seedPrices(in: vault.container, security: security, count: 4)

        let repo = SecurityRepository(container: vault.container)
        #expect(try repo.deleteSecurity(symbol: "TEST", withPrices: true) == 1)

        let ctx = vault.container.viewContext
        ctx.refreshAllObjects()
        #expect(try securityCount(in: vault.container) == 0)
        #expect(try ctx.count(for: NSFetchRequest<NSManagedObject>(entityName: "SecurityPrice")) == 0)
        // The price item is keyed by pSecurityID, so leaving it behind would strand it.
        #expect(try ctx.count(for: NSFetchRequest<NSManagedObject>(entityName: "SecurityPriceItem")) == 0)
    }

    @Test("deleteSecurity marks the security's sync record deleted")
    func deleteSecurityTombstonesSyncRecord() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)
        let uniqueId = BaseRepository.stringValue(security, "pUniqueID")

        let ctx = vault.container.viewContext
        let record = NSEntityDescription.insertNewObject(forEntityName: "SyncedHostedEntity", into: ctx)
        record.setValue(uniqueId, forKey: "pLocalID")
        record.setValue(uniqueId, forKey: "pRemoteID")
        record.setValue("Security", forKey: "pHostedEntityType")
        record.setValue(Int16(0), forKey: "pSyncedState")
        try ctx.save()

        let repo = SecurityRepository(
            container: vault.container,
            syncBlobUpdater: SyncBlobUpdater(container: vault.container)
        )
        #expect(try repo.deleteSecurity(symbol: "TEST") == 1)

        ctx.refreshAllObjects()
        let request = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        request.predicate = NSPredicate(format: "pLocalID == %@", uniqueId)
        let saved = try #require(try ctx.fetch(request).first)
        // pSyncedState 3 is the tombstone that propagates the delete, as used by
        // transaction deletion. Without it the blob can resurrect the security.
        #expect(saved.value(forKey: "pSyncedState") as? Int16 == 3)
    }
}
