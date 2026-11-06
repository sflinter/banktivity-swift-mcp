// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
@testable import BanktivityLib

/// Why the Core Data suites are annotated `@MainActor`.
///
/// `viewContext` is `NSMainQueueConcurrencyType` and a Swift Testing test body
/// runs on the cooperative thread pool, not the main thread. Every touch of a
/// view-context object from a test body is therefore the same threading
/// violation #3 fixed in the repositories, and the suite still had it: under
/// `-com.apple.CoreData.ConcurrencyDebug 1` the run traps in
/// `_PFAssertSafeMultiThreadedAccess_impl` inside `seedCurrencies` before a
/// single test finishes.
///
/// Left alone it does not fail cleanly. The context's change-tracking sets get
/// mutated from the test thread while the main runloop processes the merge
/// notifications `automaticallyMergesChangesFromParent` posts after every
/// background write, and a torn `CFBasicHash` surfaces as a nil insert into an
/// `__NSCFSet`, a segfault in `CFSetCreateCopy`, or a divide-by-zero in the
/// bucket search when the table's capacity reads as zero. Measured on `main`:
/// five crashed runs in sixteen.
///
/// `@MainActor` puts the body on the queue the context already belongs to,
/// which makes the existing accesses correct rather than re-routing each one.
/// Any new suite that builds a vault needs the same annotation.
enum TestVaultHelper {
    struct TestVault {
        let path: String
        let container: NSPersistentContainer
    }

    static func createFreshVault() throws -> TestVault {
        let tmpDir = NSTemporaryDirectory()
        let vaultPath = (tmpDir as NSString).appendingPathComponent("test-\(UUID().uuidString).bank8")
        let storeContentPath = (vaultPath as NSString).appendingPathComponent("StoreContent")

        try FileManager.default.createDirectory(atPath: storeContentPath, withIntermediateDirectories: true)

        // Copy .momd fixtures
        let fixturesPath = findFixturesPath()
        let contents = try FileManager.default.contentsOfDirectory(atPath: fixturesPath)
        for item in contents where item.hasSuffix(".momd") {
            let src = (fixturesPath as NSString).appendingPathComponent(item)
            let dst = (storeContentPath as NSString).appendingPathComponent(item)
            try FileManager.default.copyItem(atPath: src, toPath: dst)
        }

        // Create empty core.sql (Core Data will create schema)
        FileManager.default.createFile(atPath: (storeContentPath as NSString).appendingPathComponent("core.sql"), contents: nil)

        let container = try PersistentContainerFactory.create(bankFilePath: vaultPath)
        return TestVault(path: vaultPath, container: container)
    }

    static func cleanup(_ vault: TestVault) {
        try? FileManager.default.removeItem(atPath: vault.path)
    }

    static func seedCurrencies(in container: NSPersistentContainer) throws -> (usd: NSManagedObject, eur: NSManagedObject) {
        let ctx = container.viewContext
        let usd = NSEntityDescription.insertNewObject(forEntityName: "Currency", into: ctx)
        usd.setValue("USD", forKey: "pCode")
        usd.setValue("US Dollar", forKey: "pName")
        usd.setValue(UUID().uuidString, forKey: "pUniqueID")
        usd.setValue(Date(), forKey: "pCreationTime")
        usd.setValue(Date(), forKey: "pModificationDate")

        let eur = NSEntityDescription.insertNewObject(forEntityName: "Currency", into: ctx)
        eur.setValue("EUR", forKey: "pCode")
        eur.setValue("Euro", forKey: "pName")
        eur.setValue(UUID().uuidString, forKey: "pUniqueID")
        eur.setValue(Date(), forKey: "pCreationTime")
        eur.setValue(Date(), forKey: "pModificationDate")

        try ctx.save()
        return (usd, eur)
    }

    static func seedTransactionTypes(in container: NSPersistentContainer) throws -> (buy: NSManagedObject, sell: NSManagedObject) {
        let ctx = container.viewContext
        let buy = NSEntityDescription.insertNewObject(forEntityName: "TransactionType", into: ctx)
        buy.setValue(Int16(100), forKey: "pBaseType")
        buy.setValue("Buy", forKey: "pName")
        buy.setValue(UUID().uuidString, forKey: "pUniqueID")
        buy.setValue(Date(), forKey: "pCreationTime")
        buy.setValue(Date(), forKey: "pModificationDate")

        let sell = NSEntityDescription.insertNewObject(forEntityName: "TransactionType", into: ctx)
        sell.setValue(Int16(101), forKey: "pBaseType")
        sell.setValue("Sell", forKey: "pName")
        sell.setValue(UUID().uuidString, forKey: "pUniqueID")
        sell.setValue(Date(), forKey: "pCreationTime")
        sell.setValue(Date(), forKey: "pModificationDate")

        try ctx.save()
        return (buy, sell)
    }

    static func seedInvestmentAccount(in container: NSPersistentContainer, currency: NSManagedObject) throws -> NSManagedObject {
        let ctx = container.viewContext
        let account = NSEntityDescription.insertNewObject(forEntityName: "PrimaryAccount", into: ctx)
        account.setValue("Test Investment Account", forKey: "pName")
        account.setValue(UUID().uuidString, forKey: "pUniqueID")
        account.setValue(Int16(4), forKey: "pAccountClass") // investment
        account.setValue(false, forKey: "pHidden")
        account.setValue(currency, forKey: "currency")
        account.setValue(Date(), forKey: "pCreationTime")
        account.setValue(Date(), forKey: "pModificationDate")
        try ctx.save()
        return account
    }

    static func seedSecurity(in container: NSPersistentContainer, symbol: String = "TEST", currency: NSManagedObject) throws -> NSManagedObject {
        let ctx = container.viewContext
        let sec = NSEntityDescription.insertNewObject(forEntityName: "Security", into: ctx)
        sec.setValue(symbol, forKey: "pSymbol")
        sec.setValue("Test Security", forKey: "pName")
        sec.setValue(UUID().uuidString, forKey: "pUniqueID")
        sec.setValue(currency, forKey: "pCurrency")
        sec.setValue(false, forKey: "pExcludeFromQuoteUpdates")
        sec.setValue(false, forKey: "pIsIndex")
        sec.setValue(false, forKey: "pTradesInPence")
        sec.setValue(Int16(0), forKey: "pType")
        sec.setValue(Int16(0), forKey: "pRiskType")
        sec.setValue(NSDecimalNumber.one, forKey: "pContractSize")
        sec.setValue(NSDecimalNumber.zero, forKey: "pParValue")
        sec.setValue(Date(), forKey: "pCreationTime")
        sec.setValue(Date(), forKey: "pModificationDate")
        try ctx.save()
        return sec
    }

    static func seedSyncedDocument(in container: NSPersistentContainer) throws -> NSManagedObject {
        let ctx = container.viewContext
        let doc = NSEntityDescription.insertNewObject(forEntityName: "SyncedDocument", into: ctx)
        doc.setValue(UUID().uuidString, forKey: "pDocumentID")
        try ctx.save()
        return doc
    }

    /// The three `SyncedHostedEntity` fields an update must never write:
    /// Banktivity's merge base (`pRemoteEntityData`), `pSyncedState` and
    /// `pSyncedModificationDate`. Compared byte for byte before and after.
    struct SyncRecordSnapshot: Equatable, Sendable {
        let remoteEntityData: Data?
        let syncedState: Int?
        let syncedModificationDate: Date?
    }

    static func syncRecordSnapshot(uuid: String, in container: NSPersistentContainer) -> SyncRecordSnapshot? {
        let ctx = container.newBackgroundContext()
        nonisolated(unsafe) var snapshot: SyncRecordSnapshot?
        ctx.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
            request.predicate = NSPredicate(format: "pLocalID == %@", uuid)
            request.fetchLimit = 1
            guard let record = try? ctx.fetch(request).first else { return }
            snapshot = SyncRecordSnapshot(
                remoteEntityData: record.value(forKey: "pRemoteEntityData") as? Data,
                syncedState: (record.value(forKey: "pSyncedState") as? NSNumber)?.intValue,
                syncedModificationDate: record.value(forKey: "pSyncedModificationDate") as? Date
            )
        }
        return snapshot
    }

    /// A fixed past instant, so a later `pModificationDate` bump is
    /// observable regardless of clock resolution.
    static let pinnedModificationDate = Date(timeIntervalSince1970: 1_600_000_000)

    static func pinModificationDate(entityName: String, uuid: String, in container: NSPersistentContainer) throws {
        let ctx = container.newBackgroundContext()
        nonisolated(unsafe) var writeError: Error?
        ctx.performAndWait {
            do {
                let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                request.predicate = NSPredicate(format: "pUniqueID == %@", uuid)
                request.fetchLimit = 1
                guard let entity = try ctx.fetch(request).first else { return }
                entity.setValue(pinnedModificationDate, forKey: "pModificationDate")
                try ctx.save()
            } catch {
                writeError = error
            }
        }
        if let writeError { throw writeError }
    }

    static func modificationDate(entityName: String, uuid: String, in container: NSPersistentContainer) -> Date? {
        let ctx = container.newBackgroundContext()
        nonisolated(unsafe) var date: Date?
        ctx.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            request.predicate = NSPredicate(format: "pUniqueID == %@", uuid)
            request.fetchLimit = 1
            date = (try? ctx.fetch(request).first)?.value(forKey: "pModificationDate") as? Date
        }
        return date
    }

    /// Stand in for the `SyncedHostedEntity` Banktivity's own sync would have
    /// written for an already-synced row. The CLI never writes one, so tests
    /// that need a synced baseline seed it here. The blob is opaque bytes: the
    /// contract under test is that the CLI leaves it byte-identical.
    @discardableResult
    static func seedSyncRecord(uuid: String, entityType: String, in container: NSPersistentContainer) throws -> SyncRecordSnapshot {
        let blob = Data("<entity type=\"\(entityType)\" id=\"\(uuid)\">base</entity>".utf8)
        let syncedAt = Date(timeIntervalSince1970: 1_650_000_000)
        let ctx = container.newBackgroundContext()
        nonisolated(unsafe) var writeError: Error?
        ctx.performAndWait {
            do {
                let record = NSEntityDescription.insertNewObject(forEntityName: "SyncedHostedEntity", into: ctx)
                record.setValue(uuid, forKey: "pLocalID")
                record.setValue(uuid, forKey: "pRemoteID")
                record.setValue(entityType, forKey: "pHostedEntityType")
                record.setValue(Int16(0), forKey: "pSyncedState")
                record.setValue(syncedAt, forKey: "pSyncedModificationDate")
                record.setValue(blob, forKey: "pRemoteEntityData")
                try ctx.save()
            } catch {
                writeError = error
            }
        }
        if let writeError { throw writeError }
        return SyncRecordSnapshot(remoteEntityData: blob, syncedState: 0, syncedModificationDate: syncedAt)
    }

    static func syncRecordCount(in container: NSPersistentContainer) -> Int {
        let ctx = container.newBackgroundContext()
        nonisolated(unsafe) var count = -1
        ctx.performAndWait {
            count = (try? ctx.count(for: NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity"))) ?? -1
        }
        return count
    }

    static func uniqueID(entityName: String, pk: Int, in container: NSPersistentContainer) throws -> String {
        let base = BaseRepository(container: container)
        return try base.performRead { ctx in
            let object = try base.fetchByPK(entityName: entityName, pk: pk, in: ctx)
            return object.map { BaseRepository.stringValue($0, "pUniqueID") } ?? ""
        }
    }

    static func creationDate(entityName: String, uuid: String, in container: NSPersistentContainer) -> Date? {
        let ctx = container.newBackgroundContext()
        nonisolated(unsafe) var date: Date?
        ctx.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            request.predicate = NSPredicate(format: "pUniqueID == %@", uuid)
            request.fetchLimit = 1
            date = (try? ctx.fetch(request).first)?.value(forKey: "pCreationTime") as? Date
        }
        return date
    }

    private static func findFixturesPath() -> String {
        // Walk up from the build directory to find Tests/Fixtures/StoreContent
        var url = URL(fileURLWithPath: #filePath)
        // #filePath points to Tests/BanktivityLibTests/TestVaultHelper.swift
        // Go up to Tests/, then into Fixtures/StoreContent
        url = url.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("StoreContent")
        return url.path
    }
}
