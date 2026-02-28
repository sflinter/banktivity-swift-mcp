// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

@Suite("Recategorize")
struct RecategorizeTests {

    // MARK: - Helpers

    /// Copy the test vault and create a Core Data container. Returns nil if vault not found.
    private func makeTestVaultAndContainer() throws -> (path: String, container: NSPersistentContainer)? {
        let mpcVault = NSString(string: "~/Documents/Banktivity/Steves Accounts MCP.bank8").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: mpcVault) else {
            return nil
        }
        let tmpDir = NSTemporaryDirectory()
        let testVaultPath = (tmpDir as NSString).appendingPathComponent("test-recat-\(UUID().uuidString).bank8")
        try FileManager.default.copyItem(atPath: mpcVault, toPath: testVaultPath)
        let container = try PersistentContainerFactory.create(bankFilePath: testVaultPath)
        return (testVaultPath, container)
    }

    private func cleanup(_ path: String?) {
        if let path, FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Run a sqlite3 query and return trimmed output
    private func sqlite3(_ vaultPath: String, _ sql: String) -> String {
        let sqlURL = URL(fileURLWithPath: vaultPath)
            .appendingPathComponent("StoreContent/core.sql")
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [sqlURL.path, sql]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func lineItemCount(_ vaultPath: String, transactionPK: Int) -> Int {
        Int(sqlite3(vaultPath, "SELECT COUNT(*) FROM ZLINEITEM WHERE ZPTRANSACTION=\(transactionPK)")) ?? 0
    }

    private func findNullAccountTransaction(_ vaultPath: String) -> Int? {
        Int(sqlite3(vaultPath, """
            SELECT DISTINCT li.ZPTRANSACTION FROM ZLINEITEM li
            WHERE li.ZPACCOUNT IS NULL
            AND li.ZPTRANSACTION IN (
                SELECT li2.ZPTRANSACTION FROM ZLINEITEM li2
                JOIN ZACCOUNT a ON li2.ZPACCOUNT = a.Z_PK
                WHERE a.ZPACCOUNTCLASS NOT IN (6000, 7000)
            )
            LIMIT 1
            """))
    }

    private func findCategorizedTransaction(_ vaultPath: String) -> Int? {
        Int(sqlite3(vaultPath, """
            SELECT t.Z_PK FROM ZTRANSACTION t
            WHERE (SELECT COUNT(*) FROM ZLINEITEM li WHERE li.ZPTRANSACTION = t.Z_PK) = 2
            AND (SELECT COUNT(*) FROM ZLINEITEM li WHERE li.ZPTRANSACTION = t.Z_PK AND li.ZPACCOUNT IS NULL) = 0
            AND (SELECT COUNT(*) FROM ZLINEITEM li
                 JOIN ZACCOUNT a ON li.ZPACCOUNT = a.Z_PK
                 WHERE li.ZPTRANSACTION = t.Z_PK AND a.ZPACCOUNTCLASS IN (6000, 7000)) = 1
            LIMIT 1
            """))
    }

    private func findCategoryPK(_ vaultPath: String) -> Int? {
        Int(sqlite3(vaultPath, "SELECT Z_PK FROM ZACCOUNT WHERE ZPACCOUNTCLASS = 7000 LIMIT 1"))
    }

    private func findDifferentCategoryPK(_ vaultPath: String, notEqualTo: Int) -> Int? {
        Int(sqlite3(vaultPath, "SELECT Z_PK FROM ZACCOUNT WHERE ZPACCOUNTCLASS = 7000 AND Z_PK != \(notEqualTo) LIMIT 1"))
    }

    private func checkpointWAL(_ vaultPath: String) {
        _ = sqlite3(vaultPath, "PRAGMA wal_checkpoint(TRUNCATE)")
    }

    private func makeRepo(_ container: NSPersistentContainer) -> CategorizationRepository {
        let categoryRepo = CategoryRepository(container: container)
        let importRuleRepo = ImportRuleRepository(container: container)
        return CategorizationRepository(
            container: container,
            categoryRepo: categoryRepo,
            importRuleRepo: importRuleRepo
        )
    }

    // MARK: - Tests

    @Test("Recategorize null-account transaction reuses orphaned line item")
    func recategorizeNullAccountTransactionReusesOrphan() throws {
        guard let (vaultPath, container) = try makeTestVaultAndContainer() else { return }
        defer { cleanup(vaultPath) }

        guard let txPK = findNullAccountTransaction(vaultPath) else { return }
        guard let catPK = findCategoryPK(vaultPath) else { return }

        let beforeCount = lineItemCount(vaultPath, transactionPK: txPK)

        let repo = makeRepo(container)
        let result = try repo.recategorize(transactionId: txPK, categoryId: catPK)
        #expect(result != nil)

        checkpointWAL(vaultPath)

        let afterCount = lineItemCount(vaultPath, transactionPK: txPK)
        #expect(afterCount == beforeCount,
            "Recategorize should reuse the orphaned null-account line item, not create a new one. Before: \(beforeCount), After: \(afterCount)")
    }

    @Test("Recategorize categorized transaction updates in place")
    func recategorizeCategorizedTransactionUpdatesInPlace() throws {
        guard let (vaultPath, container) = try makeTestVaultAndContainer() else { return }
        defer { cleanup(vaultPath) }

        guard let txPK = findCategorizedTransaction(vaultPath) else { return }
        guard let catPK = findCategoryPK(vaultPath) else { return }
        guard let differentCatPK = findDifferentCategoryPK(vaultPath, notEqualTo: catPK) else { return }

        let beforeCount = lineItemCount(vaultPath, transactionPK: txPK)
        #expect(beforeCount == 2, "Test expects a 2-line-item transaction")

        let repo = makeRepo(container)
        let result = try repo.recategorize(transactionId: txPK, categoryId: differentCatPK)
        #expect(result != nil)

        checkpointWAL(vaultPath)

        let afterCount = lineItemCount(vaultPath, transactionPK: txPK)
        #expect(afterCount == 2,
            "Recategorize should update the existing category line item, not create a new one")
    }

    @Test("Recategorize returns correct result DTO")
    func recategorizeReturnsCorrectResult() throws {
        guard let (vaultPath, container) = try makeTestVaultAndContainer() else { return }
        defer { cleanup(vaultPath) }

        guard let txPK = findCategorizedTransaction(vaultPath) else { return }
        guard let catPK = findCategoryPK(vaultPath) else { return }

        let repo = makeRepo(container)
        let result = try repo.recategorize(transactionId: txPK, categoryId: catPK)
        let unwrapped = try #require(result)
        #expect(unwrapped.transactionId == txPK)
        #expect(!unwrapped.newCategoryName.isEmpty)
    }

    @Test("Recategorize throws for nonexistent transaction")
    func recategorizeThrowsForNonexistentTransaction() throws {
        guard let (vaultPath, container) = try makeTestVaultAndContainer() else { return }
        defer { cleanup(vaultPath) }

        let repo = makeRepo(container)
        #expect(throws: (any Error).self) {
            try repo.recategorize(transactionId: 999999, categoryId: 1)
        }
    }
}
