// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing

@testable import BanktivityLib

/// What `recategorize` must refuse.
///
/// These build their own vault rather than copying one, because the existing
/// `RecategorizeTests` return early when a particular developer's vault is absent --
/// so on any other machine they pass without asserting anything. A guard proved only
/// on the author's laptop is not proved.
/// `.serialized` because each test stands up its own Core Data stack, and running four of
/// those concurrently -- with the other Core Data suites also in flight -- crashes the test
/// process. Serialising this suite costs about a second and keeps the fix provable without
/// pulling the wider Core Data threading work into a categorization change.
@Suite("Categorize safety", .serialized)
struct CategorizeSafetyTests {

    // MARK: - Fixture

    private struct Fixture {
        let vault: TestVaultHelper.TestVault
        let repo: CategorizationRepository
        let checkingPK: Int
        let savingsPK: Int
        let expensePK: Int
    }

    private func makeFixture() throws -> Fixture {
        let vault = try TestVaultHelper.createFreshVault()
        let (usd, _) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let ctx = vault.container.viewContext

        func account(_ name: String, _ accountClass: Int, entity: String) throws -> NSManagedObject {
            let a = NSEntityDescription.insertNewObject(forEntityName: entity, into: ctx)
            a.setValue(name, forKey: "pName")
            a.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
            a.setValue(Int16(accountClass), forKey: "pAccountClass")
            a.setValue(false, forKey: "pHidden")
            if entity == "PrimaryAccount" { a.setValue(usd, forKey: "currency") }
            BaseRepository.setNow(a, "pCreationTime")
            BaseRepository.setNow(a, "pModificationDate")
            return a
        }

        let checking = try account("Checking", AccountClass.checking, entity: "PrimaryAccount")
        let savings = try account("Savings", AccountClass.savings, entity: "PrimaryAccount")
        let expense = try account("Groceries", AccountClass.expense, entity: "Account")
        try ctx.save()

        let repo = CategorizationRepository(
            container: vault.container,
            categoryRepo: CategoryRepository(container: vault.container),
            importRuleRepo: ImportRuleRepository(container: vault.container)
        )
        return Fixture(
            vault: vault,
            repo: repo,
            checkingPK: BaseRepository.extractPK(from: checking.objectID),
            savingsPK: BaseRepository.extractPK(from: savings.objectID),
            expensePK: BaseRepository.extractPK(from: expense.objectID)
        )
    }

    /// A transaction with one line item per supplied (account pk, amount).
    /// A nil account makes an orphaned slot.
    @discardableResult
    private func seedTransaction(
        _ fixture: Fixture, title: String, legs: [(pk: Int?, amount: NSDecimalNumber)]
    ) throws -> Int {
        let ctx = fixture.vault.container.viewContext
        let tx = NSEntityDescription.insertNewObject(forEntityName: "Transaction", into: ctx)
        tx.setValue(title, forKey: "pTitle")
        tx.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
        tx.setValue(false, forKey: "pCleared")
        tx.setValue(false, forKey: "pVoid")
        tx.setValue(false, forKey: "pAdjustment")
        BaseRepository.setDate(tx, "pDate", isoString: "2026-03-01")
        BaseRepository.setNow(tx, "pCreationTime")
        BaseRepository.setNow(tx, "pModificationDate")

        for leg in legs {
            let li = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
            li.setValue(leg.amount, forKey: "pTransactionAmount")
            li.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
            li.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
            li.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
            li.setValue(false, forKey: "pCleared")
            BaseRepository.setNow(li, "pCreationTime")
            li.setValue(tx, forKey: "pTransaction")
            if let pk = leg.pk {
                let request = NSFetchRequest<NSManagedObject>(entityName: "Account")
                let all = try ctx.fetch(request)
                if let account = all.first(where: { BaseRepository.extractPK(from: $0.objectID) == pk }) {
                    li.setValue(account, forKey: "pAccount")
                }
            }
        }
        try ctx.save()
        return BaseRepository.extractPK(from: tx.objectID)
    }

    private func lineItemCount(_ fixture: Fixture, transactionPK: Int) throws -> Int {
        let ctx = fixture.vault.container.viewContext
        let all = try ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: "Transaction"))
        guard let tx = all.first(where: { BaseRepository.extractPK(from: $0.objectID) == transactionPK })
        else { return 0 }
        return BaseRepository.relatedSet(tx, "lineItems").count
    }

    // MARK: - Tests

    @Test("A transfer is refused, and keeps both its legs")
    func transferIsRefused() throws {
        let fixture = try makeFixture()
        defer { TestVaultHelper.cleanup(fixture.vault) }

        // Checking -> Savings. Two posting legs, no category slot, no orphan: before the
        // guard this fell through to "create a category line item" and added a third leg
        // offsetting only one side, which unbalances the double entry.
        let txPK = try seedTransaction(
            fixture, title: "Move to savings",
            legs: [
                (fixture.checkingPK, NSDecimalNumber(string: "-500.00")),
                (fixture.savingsPK, NSDecimalNumber(string: "500.00")),
            ])

        #expect(throws: (any Error).self) {
            try fixture.repo.recategorize(transactionId: txPK, categoryId: fixture.expensePK)
        }
        #expect(try lineItemCount(fixture, transactionPK: txPK) == 2,
                "a refused transfer must not gain a fabricated category leg")
    }

    @Test("An account that is not a category is refused as the target")
    func nonCategoryTargetIsRefused() throws {
        let fixture = try makeFixture()
        defer { TestVaultHelper.cleanup(fixture.vault) }

        let txPK = try seedTransaction(
            fixture, title: "Card payment",
            legs: [(fixture.checkingPK, NSDecimalNumber(string: "-42.00"))])

        // A category *is* an Account in Banktivity, so a checking-account id resolves
        // perfectly well here. Writing it into the category slot would quietly convert
        // this into a second transfer.
        #expect(throws: (any Error).self) {
            try fixture.repo.recategorize(transactionId: txPK, categoryId: fixture.savingsPK)
        }
        #expect(try lineItemCount(fixture, transactionPK: txPK) == 1)
    }

    @Test("A bulk dry run reports the transfer it would refuse, not as affected")
    func bulkDryRunAgreesWithApply() throws {
        let fixture = try makeFixture()
        defer { TestVaultHelper.cleanup(fixture.vault) }

        try seedTransaction(
            fixture, title: "ACME transfer",
            legs: [
                (fixture.checkingPK, NSDecimalNumber(string: "-100.00")),
                (fixture.savingsPK, NSDecimalNumber(string: "100.00")),
            ])
        try seedTransaction(
            fixture, title: "ACME purchase",
            legs: [(fixture.checkingPK, NSDecimalNumber(string: "-25.00"))])

        // A plan that promises a row the write then refuses is worse than one that
        // promises nothing: the operator approves a count that never lands.
        let dry = try fixture.repo.bulkRecategorize(
            payeePattern: "ACME", categoryId: fixture.expensePK, dryRun: true)
        #expect(dry.count == 1)
        #expect(dry.skippedTransfers == 1)

        let applied = try fixture.repo.bulkRecategorize(
            payeePattern: "ACME", categoryId: fixture.expensePK, dryRun: false)
        #expect(applied.count == dry.count, "the apply must land exactly what the dry run promised")
        #expect(applied.skippedTransfers == dry.skippedTransfers)
    }

    @Test("A bulk run with a non-category target writes nothing")
    func bulkRefusesNonCategoryTarget() throws {
        let fixture = try makeFixture()
        defer { TestVaultHelper.cleanup(fixture.vault) }

        let txPK = try seedTransaction(
            fixture, title: "ACME purchase",
            legs: [(fixture.checkingPK, NSDecimalNumber(string: "-25.00"))])

        #expect(throws: (any Error).self) {
            try fixture.repo.bulkRecategorize(
                payeePattern: "ACME", categoryId: fixture.checkingPK, dryRun: false)
        }
        #expect(try lineItemCount(fixture, transactionPK: txPK) == 1)
    }
}
