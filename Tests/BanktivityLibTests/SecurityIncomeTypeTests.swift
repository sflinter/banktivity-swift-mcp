// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

/// `create-income` writes the income type it was asked for, and says so on the
/// wire.
///
/// It accepted only `dividend` before, so a spin-off's basis release -- recorded
/// as Return of Capital -- could not be written at all, and the apportionment it
/// belongs to could not be recorded.
@Suite("Security income types", .serialized)
struct SecurityIncomeTypeTests {

    private func seededVault() throws -> (vault: TestVaultHelper.TestVault, accountId: Int, categoryId: Int, symbol: String) {
        let vault = try TestVaultHelper.createFreshVault()
        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedSyncedDocument(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)

        let ctx = vault.container.viewContext
        for (code, name) in [(Int16(301), "Dividend"), (Int16(310), "Return Of Capital"), (Int16(304), "Interest Inc.")] {
            let type = NSEntityDescription.insertNewObject(forEntityName: "TransactionType", into: ctx)
            type.setValue(code, forKey: "pBaseType")
            type.setValue(name, forKey: "pName")
            type.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
            type.setValue(Date(), forKey: "pCreationTime")
            type.setValue(Date(), forKey: "pModificationDate")
        }
        let category = NSEntityDescription.insertNewObject(forEntityName: "PrimaryAccount", into: ctx)
        category.setValue("Investment Income", forKey: "pName")
        category.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
        category.setValue(Int16(AccountClass.income), forKey: "pAccountClass")
        category.setValue(false, forKey: "pHidden")
        category.setValue(eur, forKey: "currency")
        BaseRepository.setNow(category, "pCreationTime")
        BaseRepository.setNow(category, "pModificationDate")
        try ctx.save()

        return (vault,
                BaseRepository.extractPK(from: account.objectID),
                BaseRepository.extractPK(from: category.objectID),
                BaseRepository.stringValue(security, "pSymbol"))
    }

    private func syncXML(forTransaction id: Int, in container: NSPersistentContainer) throws -> String {
        let rows = try container.viewContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "Transaction"))
        let row = try #require(rows.first { BaseRepository.extractPK(from: $0.objectID) == id })
        let request = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        request.predicate = NSPredicate(format: "pLocalID == %@", BaseRepository.stringValue(row, "pUniqueID"))
        let record = try #require(try container.viewContext.fetch(request).first)
        let blob = try #require(record.value(forKey: "pRemoteEntityData") as? Data)
        let decompressed = try #require(SyncBlobUpdater.decompressGzip(blob))
        return try #require(String(data: decompressed, encoding: .utf8))
    }

    /// The wire value is not the `--income-type` slug. 304 is `intrest-income` in
    /// the enum -- misspelled, and still the value the enum contains.
    @Test("income is written, echoed and synced as the type it was asked for",
          arguments: [("return-of-capital", "Return Of Capital", "return-of-capital"),
                      ("interest-income", "Interest Inc.", "intrest-income"),
                      ("interest", "Interest Inc.", "intrest-income"),
                      ("dividend", "Dividend", "dividend")])
    func incomeTypeIsHonoured(slug: String, label: String, syncValue: String) throws {
        let seeded = try seededVault()
        defer { TestVaultHelper.cleanup(seeded.vault) }

        let repo = SecurityRepository(
            container: seeded.vault.container,
            syncBlobUpdater: SyncBlobUpdater(container: seeded.vault.container)
        )
        let income = try repo.createSecurityIncome(
            accountId: seeded.accountId, symbol: seeded.symbol,
            amount: 12.34, date: "2026-01-21",
            offsetCategoryId: seeded.categoryId, incomeType: slug
        )

        // The echo is the vault's own label, so a create agrees with its readback.
        #expect(income.type == label)

        let readBack = try #require(try repo.getIncome(
            accountId: seeded.accountId, symbol: seeded.symbol,
            startDate: "2026-01-01", endDate: "2026-01-31"
        ).first)
        #expect(readBack.type == label)

        let xml = try syncXML(forTransaction: income.id, in: seeded.vault.container)
        #expect(xml.contains("name=\"baseType\">\(syncValue)</field>"))
    }

    @Test("an unknown income type is refused, and the refusal lists what is accepted")
    func unknownIncomeTypeIsRefused() throws {
        let seeded = try seededVault()
        defer { TestVaultHelper.cleanup(seeded.vault) }

        let repo = SecurityRepository(container: seeded.vault.container)
        #expect(throws: ToolError.self) {
            _ = try repo.createSecurityIncome(
                accountId: seeded.accountId, symbol: seeded.symbol,
                amount: 1, date: "2026-01-21",
                offsetCategoryId: seeded.categoryId, incomeType: "not-a-type"
            )
        }
        #expect(SecurityRepository.incomeTypeNames.contains("return-of-capital"))
        for slug in SecurityRepository.incomeBaseTypes.keys {
            #expect(SecurityRepository.incomeTypeNames.contains(slug))
        }
    }

    /// Both spellings reach the same base type. `securities income` reads these
    /// back as display names, so a caller writing one and reading the other has to
    /// be able to spell it either way.
    @Test("the long and short spellings agree",
          arguments: [("cap-gains-short", "capital-gains-short"),
                      ("cap-gains-long", "capital-gains-long"),
                      ("interest-income", "interest")])
    func spellingsAgree(short: String, long: String) {
        #expect(SecurityRepository.incomeBaseTypes[short] == SecurityRepository.incomeBaseTypes[long])
        #expect(SecurityRepository.incomeBaseTypes[short] != nil)
    }

    /// Every accepted type must have a wire name, or its sync record is skipped
    /// silently. This is the assertion that keeps the two maps in step.
    @Test("every accepted income type has a sync enum value")
    func everyAcceptedTypeHasAWireName() {
        for (slug, code) in SecurityRepository.incomeBaseTypes {
            #expect(SecurityRepository.incomeSyncBaseTypeNames[code] != nil,
                    "\(slug) resolves to \(code) with no sync enum value")
        }
    }
}
