// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
@testable import BanktivityLib

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
