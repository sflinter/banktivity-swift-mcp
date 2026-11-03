// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

/// Making a security's price history look unknown should not require deleting it.
///
/// `deletePrices` is the only way to do that today, and it is destructive: you
/// delete the rows that make the history known, and if what comes back is not what
/// you expected there is nothing to go back to. `SecurityPriceItem` records what is
/// known in three fields; clearing those says the same thing and leaves every row
/// in place.
@Suite("Price range reset", .serialized)
struct PriceRangeResetTests {

    private func vaultWithPricedSecurity() throws -> (vault: TestVaultHelper.TestVault, symbol: String, csv: URL) {
        let vault = try TestVaultHelper.createFreshVault()
        let (usd, _) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, symbol: "PRCE", currency: usd)

        let csv = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prices-\(UUID().uuidString).csv")
        try """
        Date,Close
        2026-01-02,10.5
        2026-01-03,10.75
        2026-01-06,11.0
        """.write(to: csv, atomically: true, encoding: .utf8)

        let repo = SecurityRepository(container: vault.container)
        let symbol = BaseRepository.stringValue(security, "pSymbol")
        _ = try repo.importPricesFromCSV(filePath: csv.path, symbol: symbol)
        return (vault, symbol, csv)
    }

    private func priceItem(in container: NSPersistentContainer) throws -> NSManagedObject {
        let request = NSFetchRequest<NSManagedObject>(entityName: "SecurityPriceItem")
        return try #require(try container.viewContext.fetch(request).first)
    }

    private func priceRowCount(in container: NSPersistentContainer) throws -> Int {
        try container.viewContext.count(for: NSFetchRequest<NSManagedObject>(entityName: "SecurityPrice"))
    }

    @Test("the known range is cleared and every price row survives")
    func rangeIsClearedAndRowsSurvive() throws {
        let seeded = try vaultWithPricedSecurity()
        defer {
            TestVaultHelper.cleanup(seeded.vault)
            try? FileManager.default.removeItem(at: seeded.csv)
        }

        let before = try priceItem(in: seeded.vault.container)
        #expect(before.value(forKey: "pKnownDateRangeBegin") != nil)
        #expect(before.value(forKey: "pLatestImportDate") != nil)
        let rowsBefore = try priceRowCount(in: seeded.vault.container)
        #expect(rowsBefore == 3)

        let repo = SecurityRepository(container: seeded.vault.container)
        let result = try #require(try repo.resetKnownPriceRange(symbol: seeded.symbol))

        // The response says what was forgotten, so it can be put back by hand.
        #expect(result.symbol == seeded.symbol)
        #expect(result.priceRowCount == 3)
        #expect(result.previousKnownRangeBegin != nil)
        #expect(result.previousLatestImportDate != nil)

        seeded.vault.container.viewContext.refreshAllObjects()
        let after = try priceItem(in: seeded.vault.container)
        #expect(after.value(forKey: "pKnownDateRangeBegin") == nil)
        #expect(after.value(forKey: "pKnownDateRangeEnd") == nil)
        #expect(after.value(forKey: "pLatestImportDate") == nil)

        // The whole point: nothing was deleted.
        #expect(try priceRowCount(in: seeded.vault.container) == 3)
    }

    @Test("re-importing the same rows restores the range, so the reset is reversible")
    func reimportRestoresTheRange() throws {
        let seeded = try vaultWithPricedSecurity()
        defer {
            TestVaultHelper.cleanup(seeded.vault)
            try? FileManager.default.removeItem(at: seeded.csv)
        }
        let repo = SecurityRepository(container: seeded.vault.container)
        _ = try repo.resetKnownPriceRange(symbol: seeded.symbol)
        _ = try repo.importPricesFromCSV(filePath: seeded.csv.path, symbol: seeded.symbol)

        seeded.vault.container.viewContext.refreshAllObjects()
        let item = try priceItem(in: seeded.vault.container)
        #expect(item.value(forKey: "pKnownDateRangeBegin") != nil)
        #expect(item.value(forKey: "pKnownDateRangeEnd") != nil)
        #expect(try priceRowCount(in: seeded.vault.container) == 3)
    }

    @Test("a security nothing has ever priced is not an error")
    func unpricedSecurityReturnsNil() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let (usd, _) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, symbol: "NONE", currency: usd)

        let repo = SecurityRepository(container: vault.container)
        #expect(try repo.resetKnownPriceRange(symbol: BaseRepository.stringValue(security, "pSymbol")) == nil)
    }
}
