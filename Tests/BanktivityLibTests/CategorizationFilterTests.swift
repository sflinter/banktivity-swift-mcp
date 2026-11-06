// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing

@testable import BanktivityLib

/// The categorization reads accept account and category filters. They must apply them:
/// a caller who asks for one account and gets the whole vault believes the result is
/// scoped, which matters most just before a bulk recategorize.
// Runs on the main actor: see TestVaultHelper for why every suite that
// touches a view context has to.
@MainActor
@Suite("Categorization filters", .serialized)
struct CategorizationFilterTests {

    private struct Fixture {
        let vault: TestVaultHelper.TestVault
        let repo: CategorizationRepository
        let checkingPK: Int
        let savingsPK: Int
        let groceriesPK: Int
        let diningPK: Int
    }

    private func seedTransaction(in ctx: NSManagedObjectContext, _ title: String, legs: [NSManagedObject?]) {
        let tx = NSEntityDescription.insertNewObject(forEntityName: "Transaction", into: ctx)
        tx.setValue(title, forKey: "pTitle")
        tx.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
        tx.setValue(false, forKey: "pCleared")
        tx.setValue(false, forKey: "pVoid")
        tx.setValue(false, forKey: "pAdjustment")
        BaseRepository.setDate(tx, "pDate", isoString: "2026-03-01")
        BaseRepository.setNow(tx, "pCreationTime")
        BaseRepository.setNow(tx, "pModificationDate")
        for (index, leg) in legs.enumerated() {
            let li = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
            li.setValue(NSDecimalNumber(value: index == 0 ? -10 : 10), forKey: "pTransactionAmount")
            li.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
            li.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
            li.setValue(false, forKey: "pCleared")
            li.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
            BaseRepository.setNow(li, "pCreationTime")
            li.setValue(leg, forKey: "pAccount")
            li.setValue(tx, forKey: "pTransaction")
        }
    }

    /// Four transactions: an uncategorized one and a categorized one on each of two
    /// accounts, with the two categorized ones in different categories.
    private func makeFixture() throws -> Fixture {
        let vault = try TestVaultHelper.createFreshVault()
        let (usd, _) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let ctx = vault.container.viewContext

        func account(_ name: String, _ accountClass: Int, entity: String) -> NSManagedObject {
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

        func transaction(_ title: String, _ legs: [NSManagedObject?]) {
            seedTransaction(in: ctx, title, legs: legs)
        }

        let checking = account("Checking", AccountClass.checking, entity: "PrimaryAccount")
        let savings = account("Savings", AccountClass.savings, entity: "PrimaryAccount")
        let groceries = account("Groceries", AccountClass.expense, entity: "Account")
        let dining = account("Dining", AccountClass.expense, entity: "Account")

        transaction("Checking loose", [checking, nil])
        transaction("Savings loose", [savings, nil])
        transaction("Checking groceries", [checking, groceries])
        transaction("Savings dining", [savings, dining])
        try ctx.save()

        return Fixture(
            vault: vault,
            repo: CategorizationRepository(
                container: vault.container,
                categoryRepo: CategoryRepository(container: vault.container),
                importRuleRepo: ImportRuleRepository(container: vault.container)
            ),
            checkingPK: BaseRepository.extractPK(from: checking.objectID),
            savingsPK: BaseRepository.extractPK(from: savings.objectID),
            groceriesPK: BaseRepository.extractPK(from: groceries.objectID),
            diningPK: BaseRepository.extractPK(from: dining.objectID)
        )
    }

    private func notFound(_ body: () throws -> Void) {
        #expect(performing: body, throws: { error in
            if case ToolError.notFound = error { return true }
            return false
        })
    }

    @Test("uncategorized: an account filter returns only that account")
    func uncategorizedByAccount() throws {
        let f = try makeFixture()
        defer { TestVaultHelper.cleanup(f.vault) }

        #expect(try f.repo.getUncategorized().map(\.title).sorted() == ["Checking loose", "Savings loose"])
        #expect(try f.repo.getUncategorized(accountId: f.checkingPK).map(\.title) == ["Checking loose"])
        notFound { _ = try f.repo.getUncategorized(accountId: 999_999) }
    }

    @Test("review: account and category filters apply, alone and together")
    func reviewByAccountAndCategory() throws {
        let f = try makeFixture()
        defer { TestVaultHelper.cleanup(f.vault) }

        #expect(try f.repo.reviewCategorizations().count == 4)
        #expect(try f.repo.reviewCategorizations(accountId: f.savingsPK).map(\.title).sorted()
            == ["Savings dining", "Savings loose"])
        #expect(try f.repo.reviewCategorizations(categoryId: f.groceriesPK).map(\.title) == ["Checking groceries"])
        #expect(try f.repo.reviewCategorizations(accountId: f.savingsPK, categoryId: f.groceriesPK).isEmpty)
        notFound { _ = try f.repo.reviewCategorizations(accountId: 999_999) }
        notFound { _ = try f.repo.reviewCategorizations(categoryId: 999_999) }
    }

    @Test("review: a category filter refuses an account that is not a category")
    func reviewRefusesNonCategory() throws {
        let f = try makeFixture()
        defer { TestVaultHelper.cleanup(f.vault) }

        #expect(performing: {
            _ = try f.repo.reviewCategorizations(categoryId: f.checkingPK)
        }, throws: { error in
            if case ToolError.invalidInput = error { return true }
            return false
        })
    }

    /// A filtered row must be labelled with the leg the caller asked about. Line items
    /// come from an unordered set, so one row could pass by luck; these use several.
    @Test("a filtered row is labelled with the filtered leg, not whichever came last")
    func rowsAreLabelledWithTheFilteredLeg() throws {
        let f = try makeFixture()
        defer { TestVaultHelper.cleanup(f.vault) }

        let ctx = f.vault.container.viewContext
        let accounts = try ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: "Account"))
        func account(_ pk: Int) throws -> NSManagedObject {
            try #require(accounts.first { BaseRepository.extractPK(from: $0.objectID) == pk })
        }
        let checking = try account(f.checkingPK)
        let savings = try account(f.savingsPK)
        let groceries = try account(f.groceriesPK)
        let dining = try account(f.diningPK)
        for i in 0..<12 {
            seedTransaction(in: ctx, "Transfer \(i)", legs: [checking, savings])
            seedTransaction(in: ctx, "Split \(i)", legs: [checking, groceries, dining])
        }
        try ctx.save()

        let bySavings = try f.repo.reviewCategorizations(accountId: f.savingsPK, payeePattern: "Transfer")
        #expect(bySavings.count == 12)
        #expect(bySavings.allSatisfy { $0.accountName == "Savings" && $0.amount == 10 })

        let byChecking = try f.repo.reviewCategorizations(accountId: f.checkingPK, payeePattern: "Transfer")
        #expect(byChecking.allSatisfy { $0.accountName == "Checking" && $0.amount == -10 })

        let byGroceries = try f.repo.reviewCategorizations(categoryId: f.groceriesPK)
        #expect(byGroceries.filter { $0.title.hasPrefix("Split") }.count == 12)
        #expect(byGroceries.allSatisfy { $0.categoryId == f.groceriesPK })
        let byDining = try f.repo.reviewCategorizations(categoryId: f.diningPK, payeePattern: "Split")
        #expect(byDining.allSatisfy { $0.categoryId == f.diningPK })

        // A category is an account too, so the account filter can name one.
        let byCategoryAsAccount = try f.repo.reviewCategorizations(accountId: f.diningPK, payeePattern: "Split")
        #expect(byCategoryAsAccount.count == 12)
        #expect(byCategoryAsAccount.allSatisfy { $0.categoryId == f.diningPK })

        let loose = try f.repo.getUncategorized(accountId: f.savingsPK, excludeTransfers: false)
            .filter { $0.title.hasPrefix("Transfer") }
        #expect(loose.count == 12)
        #expect(loose.allSatisfy { $0.accountName == "Savings" && $0.amount == 10 })
    }

    @Test("payee summary: an account filter leaves out other accounts' payees")
    func payeeSummaryByAccount() throws {
        let f = try makeFixture()
        defer { TestVaultHelper.cleanup(f.vault) }

        #expect(try f.repo.getPayeeCategorySummary().count == 4)
        #expect(try f.repo.getPayeeCategorySummary(accountId: f.checkingPK).map(\.title).sorted()
            == ["Checking groceries", "Checking loose"])
        notFound { _ = try f.repo.getPayeeCategorySummary(accountId: 999_999) }
    }
}
