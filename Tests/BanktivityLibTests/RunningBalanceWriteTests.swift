// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

@Suite("Running balance on write", .serialized)
@MainActor
struct RunningBalanceWriteTests {

    private struct Injected: Error {}

    private func makeRepositories() throws -> (
        vault: TestVaultHelper.TestVault, accounts: AccountRepository, transactions: TransactionRepository
    ) {
        let vault = try TestVaultHelper.createFreshVault()
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedTransactionTypes(in: vault.container)
        let lineItems = LineItemRepository(container: vault.container)
        return (vault, AccountRepository(container: vault.container),
                TransactionRepository(container: vault.container, lineItemRepo: lineItems))
    }

    private final class SaveCounter: @unchecked Sendable {
        var count = 0
        var token: NSObjectProtocol?
        init(coordinator: NSPersistentStoreCoordinator) {
            token = NotificationCenter.default.addObserver(
                forName: .NSManagedObjectContextDidSave, object: nil, queue: nil
            ) { [self] note in
                if (note.object as? NSManagedObjectContext)?.persistentStoreCoordinator === coordinator { count += 1 }
            }
        }
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }

    @Test("A write updates the running balance in a single save")
    func writeUpdatesBalanceInOneSave() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }
        let account = try repos.accounts.create(name: "Checking", accountClass: AccountClass.checking, currencyCode: "USD")

        let counter = SaveCounter(coordinator: repos.vault.container.persistentStoreCoordinator)
        let tx = try repos.transactions.create(
            date: "2026-05-10", title: "Pay",
            lineItems: [(accountId: account.id, amount: -42, memo: nil)])
        #expect(counter.count == 1)

        repos.vault.container.viewContext.refreshAllObjects()
        let stored = try LineItemRepository(container: repos.vault.container).getForTransactionPK(tx.id)
        #expect(stored.first { $0.accountId == account.id }?.runningBalance == -42)
    }

    @Test("A failure after a partial recalculation restores every line's balance and still commits the write")
    func partialRecalculationFailureRestoresBalances() throws {
        let repos = try makeRepositories()
        defer { TestVaultHelper.cleanup(repos.vault) }
        let account = try repos.accounts.create(name: "Checking", accountClass: AccountClass.checking, currencyCode: "USD")
        let coordinator = repos.vault.container.persistentStoreCoordinator
        let later = try repos.transactions.create(
            date: "2026-05-10", title: "Later",
            lineItems: [(accountId: account.id, amount: -42, memo: nil)])

        func balances() throws -> [Int: Double] {
            let ctx = repos.vault.container.newBackgroundContext()
            nonisolated(unsafe) var out: [Int: Double] = [:]
            ctx.performAndWait {
                let rows = (try? ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: "LineItem"))) ?? []
                for row in rows { out[BaseRepository.extractPK(from: row.objectID)] = BaseRepository.doubleValue(row, "pRunningBalance") }
            }
            return out
        }
        let before = try balances()
        #expect(!before.isEmpty)

        // Fails after the recalculation has already rewritten the balances.
        BaseRepository.runningBalanceAfterRecalcHook = { ctx in
            if ctx.persistentStoreCoordinator === coordinator { throw Injected() }
        }
        defer { BaseRepository.runningBalanceAfterRecalcHook = nil }
        // Inserted through the real write path, sorting before the existing line,
        // so a successful recalculation would move that line to -52. The existing
        // line is also edited, so it is an updated object with another changed key.
        let base = BaseRepository(container: repos.vault.container)
        let accountPK = account.id
        try base.performWrite { ctx in
            guard let acct = try base.fetchByPK(entityName: "Account", pk: accountPK, in: ctx) else {
                throw ToolError.notFound("account")
            }
            let line = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
            line.setValue(NSDecimalNumber(value: -10.0), forKey: "pTransactionAmount")
            line.setValue(NSDecimalNumber.one, forKey: "pExchangeRate")
            line.setValue(UUID().uuidString, forKey: "pUniqueID")
            line.setValue(false, forKey: "pCleared")
            line.setValue(NSDecimalNumber.zero, forKey: "pRunningBalance")
            BaseRepository.setNow(line, "pCreationTime")
            line.setValue(acct, forKey: "pAccount")
            let existing = try ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: "LineItem"))
                .first { !$0.isInserted && ($0.value(forKey: "pAccount") as? NSManagedObject) == acct }
            existing?.setValue("edited", forKey: "pMemo")
        }
        BaseRepository.runningBalanceAfterRecalcHook = nil

        let after = try balances()
        #expect(after.count > before.count)
        for (id, value) in before { #expect(after[id] == value) }
        for (id, value) in after where before[id] == nil { #expect(value == 0) }
        repos.vault.container.viewContext.refreshAllObjects()
        #expect(try repos.transactions.get(transactionId: later.id) != nil)
    }
}
