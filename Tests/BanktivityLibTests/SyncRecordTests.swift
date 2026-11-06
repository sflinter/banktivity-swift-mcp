// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

/// The sync contract: inserts and updates are signalled only by
/// pCreationTime / pModificationDate in the same save; deletes of a synced
/// row set an idempotent pSyncedState = 3 tombstone; nothing writes
/// pRemoteEntityData (Banktivity's three-way-merge base).
// Runs on the main actor: see TestVaultHelper for why every suite that
// touches a view context has to.
@Suite("SyncRecord", .serialized)
@MainActor
struct SyncRecordTests {

    private func makeAccount(_ vault: TestVaultHelper.TestVault, name: String = "Checking") throws -> Int {
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)
        return try AccountRepository(container: vault.container)
            .create(name: name, accountClass: AccountClass.checking, currencyCode: "EUR").id
    }

    private func makeTransaction(_ vault: TestVaultHelper.TestVault, accountId: Int, title: String) throws -> (repo: TransactionRepository, id: Int, uuid: String) {
        let repo = TransactionRepository(container: vault.container, lineItemRepo: LineItemRepository(container: vault.container))
        let tx = try repo.create(date: "2026-03-01", title: title, lineItems: [(accountId: accountId, amount: -42, memo: nil)])
        let uuid = try TestVaultHelper.uniqueID(entityName: "Transaction", pk: tx.id, in: vault.container)
        return (repo, tx.id, uuid)
    }

    @Test("gzip decoding reads a Banktivity-style blob for inspection")
    func gzipDecode() throws {
        let gzip = Data([31, 139, 8, 0, 0, 0, 0, 0, 2, 19, 179, 73, 205, 43, 201, 44, 169, 180, 75, 74, 44,
                         78, 181, 209, 135, 114, 0, 208, 251, 150, 50, 21, 0, 0, 0])
        let decoded = try #require(SyncRecords.decompressGzip(gzip))
        #expect(String(data: decoded, encoding: .utf8) == "<entity>base</entity>")
    }

    @Test("A created transaction carries both dates and no hand-made sync record")
    func createSignalsByDate() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let accountId = try makeAccount(vault)
        let before = Date()

        let tx = try makeTransaction(vault, accountId: accountId, title: "Created")

        let created = try #require(TestVaultHelper.creationDate(entityName: "Transaction", uuid: tx.uuid, in: vault.container))
        let modified = try #require(TestVaultHelper.modificationDate(entityName: "Transaction", uuid: tx.uuid, in: vault.container))
        #expect(created >= before.addingTimeInterval(-1))
        #expect(modified >= before.addingTimeInterval(-1))
        // Banktivity inserts the SyncedHostedEntity itself when it uploads.
        #expect(TestVaultHelper.syncRecordCount(in: vault.container) == 0)
    }

    @Test("Updating a synced transaction bumps its date and leaves the merge base byte-identical")
    func updateLeavesMergeBaseAlone() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let accountId = try makeAccount(vault)
        let tx = try makeTransaction(vault, accountId: accountId, title: "Before")
        let baseline = try TestVaultHelper.seedSyncRecord(uuid: tx.uuid, entityType: "Transaction", in: vault.container)
        try TestVaultHelper.pinModificationDate(entityName: "Transaction", uuid: tx.uuid, in: vault.container)

        _ = try tx.repo.update(transactionId: tx.id, title: "After", note: "edited")

        let modified = try #require(TestVaultHelper.modificationDate(entityName: "Transaction", uuid: tx.uuid, in: vault.container))
        #expect(modified > TestVaultHelper.pinnedModificationDate)
        #expect(TestVaultHelper.syncRecordSnapshot(uuid: tx.uuid, in: vault.container) == baseline)
    }

    @Test("Editing a line item stamps its parent transaction")
    func lineItemEditStampsTransaction() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let accountId = try makeAccount(vault)
        let tx = try makeTransaction(vault, accountId: accountId, title: "Line edit")
        let baseline = try TestVaultHelper.seedSyncRecord(uuid: tx.uuid, entityType: "Transaction", in: vault.container)
        try TestVaultHelper.pinModificationDate(entityName: "Transaction", uuid: tx.uuid, in: vault.container)

        let lineItems = LineItemRepository(container: vault.container)
        let line = try #require(try lineItems.getForTransactionPK(tx.id).first { $0.accountId == accountId })
        _ = try lineItems.updateWithRecalculation(lineItemId: line.id, memo: "new memo")

        let modified = try #require(TestVaultHelper.modificationDate(entityName: "Transaction", uuid: tx.uuid, in: vault.container))
        #expect(modified > TestVaultHelper.pinnedModificationDate)
        #expect(TestVaultHelper.syncRecordSnapshot(uuid: tx.uuid, in: vault.container) == baseline)
    }

    @Test("Deleting a synced transaction tombstones its record (state 3), keeps the blob, and is idempotent")
    func deleteTombstones() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let accountId = try makeAccount(vault)
        let tx = try makeTransaction(vault, accountId: accountId, title: "To delete")
        let baseline = try TestVaultHelper.seedSyncRecord(uuid: tx.uuid, entityType: "Transaction", in: vault.container)

        #expect(try tx.repo.delete(transactionId: tx.id))

        let after = try #require(TestVaultHelper.syncRecordSnapshot(uuid: tx.uuid, in: vault.container))
        #expect(after.syncedState == 3)
        #expect(after.remoteEntityData == baseline.remoteEntityData)
        let tombstonedAt = try #require(after.syncedModificationDate)
        #expect(tombstonedAt > baseline.syncedModificationDate!)

        // A second mark leaves the tombstone exactly as it was.
        let base = BaseRepository(container: vault.container)
        let uuid = tx.uuid
        let marked = try base.performWriteReturning { ctx in
            try SyncRecords.markDeletedIfPresent(entityUUID: uuid, in: ctx)
        }
        #expect(marked)
        #expect(TestVaultHelper.syncRecordSnapshot(uuid: tx.uuid, in: vault.container) == after)
    }

    @Test("Deleting a transaction that never synced creates no record")
    func deleteUnsyncedCreatesNoRecord() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let accountId = try makeAccount(vault)
        let tx = try makeTransaction(vault, accountId: accountId, title: "Never synced")

        #expect(try tx.repo.delete(transactionId: tx.id))
        #expect(TestVaultHelper.syncRecordCount(in: vault.container) == 0)
    }

    @Test("Deleting a tag tombstones the tag and stamps the transactions that carried it")
    func tagDelete() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let accountId = try makeAccount(vault)
        let tx = try makeTransaction(vault, accountId: accountId, title: "Tagged")
        let tags = TagRepository(container: vault.container)
        let tag = try tags.create(name: "Holiday")
        _ = try tags.tagTransaction(transactionId: tx.id, tagId: tag.id)
        let tagUUID = try TestVaultHelper.uniqueID(entityName: "Tag", pk: tag.id, in: vault.container)
        try TestVaultHelper.seedSyncRecord(uuid: tagUUID, entityType: "Tag", in: vault.container)
        try TestVaultHelper.pinModificationDate(entityName: "Transaction", uuid: tx.uuid, in: vault.container)

        #expect(try tags.delete(tagId: tag.id))

        #expect(TestVaultHelper.syncRecordSnapshot(uuid: tagUUID, in: vault.container)?.syncedState == 3)
        let modified = try #require(TestVaultHelper.modificationDate(entityName: "Transaction", uuid: tx.uuid, in: vault.container))
        #expect(modified > TestVaultHelper.pinnedModificationDate)
    }

    @Test("updateSecurityLineItem repairs the cash line, stamps the transaction, and leaves the merge base alone")
    func updateSecurityLineItemRepairsCashLine() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let txTypes = try TestVaultHelper.seedTransactionTypes(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)
        let accountPK = BaseRepository.extractPK(from: account.objectID)

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
        cashLI.setValue(0.0 as NSNumber, forKey: "pTransactionAmount")
        cashLI.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
        cashLI.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
        cashLI.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
        cashLI.setValue(false, forKey: "pCleared")
        BaseRepository.setNow(cashLI, "pCreationTime")
        cashLI.setValue(account, forKey: "pAccount")
        cashLI.setValue(tx, forKey: "pTransaction")

        let offsetLI = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
        offsetLI.setValue(0.0 as NSNumber, forKey: "pTransactionAmount")
        offsetLI.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
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
        let baseline = try TestVaultHelper.seedSyncRecord(uuid: txUUID, entityType: "Transaction", in: vault.container)
        try TestVaultHelper.pinModificationDate(entityName: "Transaction", uuid: txUUID, in: vault.container)

        let repo = SecurityRepository(container: vault.container)
        let updated = try repo.updateSecurityLineItem(transactionId: txPK, amount: -125, cashLineItemAmount: -125)
        #expect(updated.amount == -125)

        // The repository wrote on a background context, and
        // `automaticallyMergesChangesFromParent` delivers that merge to the view
        // context's queue asynchronously. This body owns that queue, so the merge
        // cannot run until the body yields: the read below has to refresh.
        vault.container.viewContext.refreshAllObjects()
        let lineItems = try LineItemRepository(container: vault.container).getForTransactionPK(txPK)
        let accountLine = try #require(lineItems.first { $0.accountId == accountPK })
        let balancingLine = try #require(lineItems.first { $0.accountId == 0 })
        #expect(accountLine.amount == -125)
        #expect(balancingLine.amount == 125)

        let modified = try #require(TestVaultHelper.modificationDate(entityName: "Transaction", uuid: txUUID, in: vault.container))
        #expect(modified > TestVaultHelper.pinnedModificationDate)
        #expect(TestVaultHelper.syncRecordSnapshot(uuid: txUUID, in: vault.container) == baseline)
    }

    @Test("A share adjustment is created with both dates and no hand-made sync record")
    func shareAdjustmentSignalsByDate() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedTransactionTypes(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)

        let trade = try SecurityRepository(container: vault.container).createShareAdjustment(
            accountId: BaseRepository.extractPK(from: account.objectID),
            symbol: BaseRepository.stringValue(security, "pSymbol"),
            shares: 5,
            date: "2026-03-02"
        )

        let uuid = try TestVaultHelper.uniqueID(entityName: "Transaction", pk: trade.id, in: vault.container)
        #expect(TestVaultHelper.creationDate(entityName: "Transaction", uuid: uuid, in: vault.container) != nil)
        #expect(TestVaultHelper.modificationDate(entityName: "Transaction", uuid: uuid, in: vault.container) != nil)
        #expect(TestVaultHelper.syncRecordCount(in: vault.container) == 0)
    }

    @Test("Deleting prices stamps the security, because its latest price may change; deleting none does not")
    func deletingPricesStampsTheSecurity() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let (usd, _) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, symbol: "STMP", currency: usd)
        let symbol = BaseRepository.stringValue(security, "pSymbol")
        let csv = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prices-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: csv) }
        try "Date,Close\n2026-01-02,10.5\n2026-01-03,10.75\n".write(to: csv, atomically: true, encoding: .utf8)
        let repo = SecurityRepository(container: vault.container)
        _ = try repo.importPricesFromCSV(filePath: csv.path, symbol: symbol)

        let ctx = vault.container.viewContext
        let old = Date(timeIntervalSince1970: 1_000_000)
        func resetStamp() throws {
            ctx.refresh(security, mergeChanges: false)
            security.setValue(old, forKey: "pModificationDate")
            try ctx.save()
        }

        try resetStamp()
        #expect(try repo.deletePrices(symbol: symbol, startDate: "2030-01-01") == 0)
        ctx.refresh(security, mergeChanges: false)
        #expect(security.value(forKey: "pModificationDate") as? Date == old)

        #expect(try repo.deletePrices(symbol: symbol, startDate: "2026-01-03") == 1)
        ctx.refresh(security, mergeChanges: false)
        #expect((security.value(forKey: "pModificationDate") as? Date ?? old) > old)
    }
}
