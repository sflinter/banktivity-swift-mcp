// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

/// A vault can hold several TransactionType rows that share one base type (base 2
/// can be both "Withdrawal" and "POS"). Which one a write picks must not depend on
/// the order the store happens to return them in.
@MainActor
@Suite("Transaction type selection", .serialized)
struct TransactionTypeSelectionTests {

    /// Insert one row per name, saving after each so the primary keys follow the order given.
    private func seedTypes(_ names: [String], baseType: Int16, in ctx: NSManagedObjectContext) throws {
        for name in names {
            let row = NSEntityDescription.insertNewObject(forEntityName: "TransactionType", into: ctx)
            row.setValue(baseType, forKey: "pBaseType")
            row.setValue(name, forKey: "pName")
            row.setValue(UUID().uuidString, forKey: "pUniqueID")
            row.setValue(Date(), forKey: "pCreationTime")
            row.setValue(Date(), forKey: "pModificationDate")
            try ctx.save()
        }
    }

    private func chosenName(baseType: Int16, in ctx: NSManagedObjectContext) throws -> String? {
        try TransactionRepository.fetchTransactionType(baseType: baseType, in: ctx)
            .map { BaseRepository.stringValue($0, "pName") }
    }

    @Test("the canonical name wins whichever row was inserted first", arguments: [
        ["Withdrawal", "POS"],
        ["POS", "Withdrawal"],
    ])
    func canonicalNameWins(names: [String]) throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let ctx = vault.container.viewContext
        try seedTypes(names, baseType: 2, in: ctx)
        for _ in 0..<5 {
            #expect(try chosenName(baseType: 2, in: ctx) == "Withdrawal")
        }
    }

    @Test("without a canonical name the lowest primary key wins", arguments: [
        ["Zebra", "Alpha"],
        ["Alpha", "Zebra"],
    ])
    func lowestPrimaryKeyWins(names: [String]) throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let ctx = vault.container.viewContext
        try seedTypes(names, baseType: 2, in: ctx)
        #expect(try chosenName(baseType: 2, in: ctx) == names[0])
    }

    @Test("create writes the canonical type when POS was inserted first")
    func createWritesCanonicalType() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)
        try seedTypes(["POS", "Withdrawal"], baseType: 2, in: vault.container.viewContext)

        let accounts = AccountRepository(container: vault.container)
        let checking = try accounts.create(name: "Checking", accountClass: AccountClass.checking, currencyCode: "EUR")
        let groceries = try CategoryRepository(container: vault.container).create(name: "Groceries", type: "expense")
        let transactions = TransactionRepository(
            container: vault.container, lineItemRepo: LineItemRepository(container: vault.container))
        let created = try transactions.create(
            date: "2026-02-01", title: "Shop",
            lineItems: [(accountId: checking.id, amount: -20, memo: nil), (accountId: groceries.id, amount: 20, memo: nil)])

        let stored = try #require(try transactions.get(transactionId: created.id))
        #expect(stored.transactionType?.lowercased() == "withdrawal")
    }
}
