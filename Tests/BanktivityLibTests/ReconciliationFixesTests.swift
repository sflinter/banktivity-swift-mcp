// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

// Runs on the main actor: see TestVaultHelper for why every suite that
// touches a view context has to.
@MainActor
@Suite("Reconciliation fixes")
struct ReconciliationFixesTests {

    private struct Repos {
        let vault: TestVaultHelper.TestVault
        let accounts: AccountRepository
        let categories: CategoryRepository
        let transactions: TransactionRepository
        let tags: TagRepository
        let statements: StatementRepository
    }

    private func makeRepos() throws -> Repos {
        let vault = try TestVaultHelper.createFreshVault()
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)
        try seedCashTransactionTypes(in: vault.container)
        let lineItems = LineItemRepository(container: vault.container)
        return Repos(
            vault: vault,
            accounts: AccountRepository(container: vault.container),
            categories: CategoryRepository(container: vault.container),
            transactions: TransactionRepository(container: vault.container, lineItemRepo: lineItems),
            tags: TagRepository(container: vault.container),
            statements: StatementRepository(container: vault.container, lineItemRepo: lineItems)
        )
    }

    /// The cash and card transaction types a real vault has, deliberately seeded with
    /// Deposit first so a "take the first type" implementation would be caught.
    private func seedCashTransactionTypes(in container: NSPersistentContainer) throws {
        let ctx = container.viewContext
        for (code, name) in [(1, "Deposit"), (2, "Withdrawal"), (2, "POS"), (3, "Transfer"),
                             (5, "Charge"), (6, "Refund"), (7, "Payment")] {
            let t = NSEntityDescription.insertNewObject(forEntityName: "TransactionType", into: ctx)
            t.setValue(Int16(code), forKey: "pBaseType")
            t.setValue(name, forKey: "pName")
            t.setValue(UUID().uuidString, forKey: "pUniqueID")
            t.setValue(Date(), forKey: "pCreationTime")
            t.setValue(Date(), forKey: "pModificationDate")
        }
        try ctx.save()
    }

    @Test("Create picks the transaction type from the accounts and the sign of the amount")
    func createInfersTransactionType() throws {
        let r = try makeRepos()
        defer { TestVaultHelper.cleanup(r.vault) }

        let checking = try r.accounts.create(name: "Checking", accountClass: AccountClass.checking)
        let savings = try r.accounts.create(name: "Savings", accountClass: AccountClass.savings)
        let card = try r.accounts.create(name: "Card", accountClass: AccountClass.creditCard)
        let travel = try r.categories.create(name: "Travel", type: "expense")

        func type(_ items: [(accountId: Int, amount: Double, memo: String?)]) throws -> String? {
            try r.transactions.create(date: "2026-05-02", title: "T", lineItems: items).transactionType
        }

        #expect(try type([(card.id, -21.05, nil), (travel.id, 21.05, nil)]) == "Charge")
        #expect(try type([(card.id, 12.0, nil), (travel.id, -12.0, nil)]) == "Refund")
        #expect(try type([(card.id, 50.0, nil), (checking.id, -50.0, nil)]) == "Payment")
        #expect(try type([(checking.id, -10.0, nil), (travel.id, 10.0, nil)]) == "Withdrawal")
        #expect(try type([(checking.id, 10.0, nil), (travel.id, -10.0, nil)]) == "Deposit")
        #expect(try type([(checking.id, -100.0, nil), (savings.id, 100.0, nil)]) == "Transfer")
    }

    @Test("Transactions can be found by tag (to-many through to-many)")
    func getTransactionsByTag() throws {
        let r = try makeRepos()
        defer { TestVaultHelper.cleanup(r.vault) }

        let checking = try r.accounts.create(name: "Checking", accountClass: AccountClass.checking)
        let food = try r.categories.create(name: "Food", type: "expense")
        let tagged = try r.transactions.create(date: "2026-08-15", title: "Taverna",
                                               lineItems: [(checking.id, -40.0, nil), (food.id, 40.0, nil)])
        _ = try r.transactions.create(date: "2026-08-16", title: "Untagged",
                                      lineItems: [(checking.id, -5.0, nil), (food.id, 5.0, nil)])
        let tag = try r.tags.create(name: "crete 2026")
        _ = try r.tags.tagTransaction(transactionId: tagged.id, tagId: tag.id)

        let ids = try r.tags.getTransactionsByTag(tagId: tag.id)
        #expect(ids == [tagged.id])
        let dtos = try r.tags.getTransactionDTOsByTag(tagName: "crete 2026", transactionRepo: r.transactions)
        #expect(dtos.map(\.title) == ["Taverna"])
    }

    @Test("Reconcile rejects a late-posted item by default and accepts it with allowOutOfRange")
    func reconcileOutOfRange() throws {
        let r = try makeRepos()
        defer { TestVaultHelper.cleanup(r.vault) }

        let card = try r.accounts.create(name: "Card", accountClass: AccountClass.creditCard)
        let travel = try r.categories.create(name: "Travel", type: "expense")
        let late = try r.transactions.create(date: "2026-05-02", title: "Posted late",
                                             lineItems: [(card.id, -21.05, nil), (travel.id, 21.05, nil)])
        let liId = try #require(late.lineItems.first { $0.accountId == card.id }).id
        let stmt = try r.statements.create(accountId: card.id, startDate: "2026-05-08", endDate: "2026-06-08",
                                           beginningBalance: 0, endingBalance: -21.05)

        #expect(throws: ToolError.self) {
            _ = try r.statements.reconcileLineItems(statementId: stmt.id, lineItemIds: [liId])
        }
        let result = try r.statements.reconcileLineItems(statementId: stmt.id, lineItemIds: [liId], allowOutOfRange: true)
        #expect(result.isBalanced)
        #expect(result.reconciledLineItemCount == 1)
    }

    @Test("Categories are created as Category entities and can be deleted once unused")
    func categoryCreateAndDelete() throws {
        let r = try makeRepos()
        defer { TestVaultHelper.cleanup(r.vault) }

        let checking = try r.accounts.create(name: "Checking", accountClass: AccountClass.checking)
        let wines = try r.categories.create(name: "Wines", type: "expense")
        let entityName = try r.categories.performRead { ctx in
            try r.categories.fetchByPK(entityName: "Account", pk: wines.id, in: ctx)?.entity.name
        }
        #expect(entityName == "Category")
        let wines2 = try r.categories.create(name: "Wines", type: "expense")
        #expect(wines2.id != wines.id)
        _ = try r.categories.delete(categoryId: wines2.id)

        let tx = try r.transactions.create(date: "2026-10-01", title: "Wine shop",
                                           lineItems: [(checking.id, -30.0, nil), (wines.id, 30.0, nil)])
        #expect(throws: ToolError.self) { _ = try r.categories.delete(categoryId: wines.id) }

        let groceries = try r.categories.create(name: "Groceries", type: "expense")
        _ = try CategorizationRepository(container: r.vault.container, categoryRepo: r.categories, importRuleRepo: ImportRuleRepository(container: r.vault.container)).recategorize(transactionId: tx.id, categoryId: groceries.id)
        _ = try r.categories.delete(categoryId: wines.id)
        #expect(try r.categories.get(categoryId: wines.id) == nil)
        #expect(throws: ToolError.self) { _ = try r.categories.delete(categoryId: checking.id) }
    }
}

