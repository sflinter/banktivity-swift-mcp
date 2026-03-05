// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

@Suite("SyncRecord")
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

    @Test("deleteSyncRecord removes the record")
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

        // Verify exists
        let request = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        request.predicate = NSPredicate(format: "pLocalID == %@", txUUID)
        #expect(try vault.container.viewContext.fetch(request).count == 1)

        // Delete
        updater.deleteSyncRecord(entityUUID: txUUID)

        // Verify gone
        vault.container.viewContext.refreshAllObjects()
        #expect(try vault.container.viewContext.fetch(request).count == 0)
    }
}
