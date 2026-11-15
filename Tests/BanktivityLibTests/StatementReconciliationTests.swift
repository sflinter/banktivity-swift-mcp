// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

/// Statement behaviour ported from #4, and Banktivity's own line amount rule
/// (`-[IGGCAccountingLineItem accountAmount]`) that statement totals and
/// balances now share.
@MainActor
@Suite("Statement reconciliation", .serialized)
struct StatementReconciliationTests {

    // MARK: - Banktivity's line amount rule

    /// One investment line: a transaction of `baseType`, its line amount, and a
    /// security line with the given fields. Returns accountAmount for it.
    private func amount(
        baseType: Int16, line: Double, securityAmount: Double, income: Double = 0,
        distribution: Int16? = nil
    ) throws -> Double {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let ctx = vault.container.viewContext

        let type = NSEntityDescription.insertNewObject(forEntityName: "TransactionType", into: ctx)
        type.setValue(baseType, forKey: "pBaseType")
        type.setValue("T", forKey: "pName")
        type.setValue(UUID().uuidString, forKey: "pUniqueID")
        let tx = NSEntityDescription.insertNewObject(forEntityName: "Transaction", into: ctx)
        tx.setValue(type, forKey: "pTransactionType")
        let li = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
        li.setValue(NSDecimalNumber(value: line), forKey: "pTransactionAmount")
        li.setValue(NSDecimalNumber.one, forKey: "pExchangeRate")
        li.setValue(tx, forKey: "pTransaction")
        let sli = NSEntityDescription.insertNewObject(forEntityName: "SecurityLineItem", into: ctx)
        sli.setValue(NSDecimalNumber(value: securityAmount), forKey: "pAmount")
        sli.setValue(NSDecimalNumber(value: income), forKey: "pIncome")
        if let distribution { sli.setValue(distribution, forKey: "pDistributionType") }
        sli.setValue(li, forKey: "pLineItem")
        return BaseRepository.accountAmount(li)
    }

    @Test("An investment line takes the security line's amount, not its own")
    func securityAmountWins() throws {
        // A buy whose line says -39.18 but whose security line says -39.17:
        // Banktivity counts -39.17 (seen on a real E*Trade row).
        #expect(abs(try amount(baseType: 100, line: -39.18, securityAmount: -39.17) - (-39.17)) < 1e-9)
        // Native form: line 0, cash on the security line.
        #expect(abs(try amount(baseType: 101, line: 0, securityAmount: 500) - 500) < 1e-9)
    }

    @Test("Investment income is counted from the security line's income")
    func incomeCounts() throws {
        #expect(abs(try amount(baseType: 301, line: 12.5, securityAmount: 0, income: 12.5) - 12.5) < 1e-9)
    }

    @Test("Share moves and adjustments carry no cash; a non-cash distribution counts 0")
    func nonCash() throws {
        #expect(try amount(baseType: 210, line: 0, securityAmount: 999, distribution: 1) == 0)
        #expect(try amount(baseType: 212, line: 0, securityAmount: 999) == 0)
        #expect(try amount(baseType: 250, line: 0, securityAmount: 999) == 0)
        #expect(try amount(baseType: 100, line: 0, securityAmount: 999, distribution: 3) == 0)
    }

    @Test("A non-investment line is amount x exchange rate, even with a security line")
    func ordinaryLine() throws {
        #expect(abs(try amount(baseType: 1, line: -20, securityAmount: 999) - (-20)) < 1e-9)
    }

    // MARK: - Statement operations

    private struct Repos {
        let vault: TestVaultHelper.TestVault
        let accounts: AccountRepository
        let categories: CategoryRepository
        let transactions: TransactionRepository
        let statements: StatementRepository
        let lineItems: LineItemRepository
    }

    private func makeRepos() throws -> Repos {
        let vault = try TestVaultHelper.createFreshVault()
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)
        let lineItems = LineItemRepository(container: vault.container)
        return Repos(
            vault: vault,
            accounts: AccountRepository(container: vault.container),
            categories: CategoryRepository(container: vault.container),
            transactions: TransactionRepository(container: vault.container, lineItemRepo: lineItems),
            statements: StatementRepository(container: vault.container, lineItemRepo: lineItems),
            lineItems: lineItems
        )
    }

    private func cleared(_ r: Repos, _ id: Int) throws -> Bool {
        try r.statements.performRead { ctx in
            BaseRepository.boolValue(try #require(try r.statements.fetchByPK(entityName: "LineItem", pk: id, in: ctx)), "pCleared")
        }
    }

    @Test("Unreconcile and statement delete keep the line's cleared tick")
    func keepsCleared() throws {
        let r = try makeRepos()
        defer { TestVaultHelper.cleanup(r.vault) }
        let checking = try r.accounts.create(name: "Checking", accountClass: AccountClass.checking)
        let food = try r.categories.create(name: "Food", type: "expense")
        let a = try r.transactions.create(date: "2026-05-03", title: "A", lineItems: [(checking.id, -10, nil), (food.id, 10, nil)])
        let b = try r.transactions.create(date: "2026-05-04", title: "B", lineItems: [(checking.id, -5, nil), (food.id, 5, nil)])
        let liA = try #require(a.lineItems.first { $0.accountId == checking.id }).id
        let liB = try #require(b.lineItems.first { $0.accountId == checking.id }).id

        let stmt = try r.statements.create(accountId: checking.id, startDate: "2026-05-01", endDate: "2026-05-31",
                                           beginningBalance: 0, endingBalance: -15)
        let reconciled = try r.statements.reconcileLineItems(statementId: stmt.id, lineItemIds: [liA, liB])
        #expect(reconciled.isBalanced)

        _ = try r.statements.unreconcileLineItems(statementId: stmt.id, lineItemIds: [liA])
        #expect(try cleared(r, liA))
        #expect(try r.statements.get(statementId: stmt.id)?.reconciledLineItemCount == 1)

        _ = try r.statements.delete(statementId: stmt.id)
        #expect(try cleared(r, liB))
        #expect(try r.statements.get(statementId: stmt.id) == nil)
    }

    @Test("Get lists the statement's line items; status reports where the account stands")
    func getAndStatus() throws {
        let r = try makeRepos()
        defer { TestVaultHelper.cleanup(r.vault) }
        let checking = try r.accounts.create(name: "Checking", accountClass: AccountClass.checking)
        let food = try r.categories.create(name: "Food", type: "expense")
        let a = try r.transactions.create(date: "2026-05-03", title: "A", lineItems: [(checking.id, -10, nil), (food.id, 10, nil)])
        _ = try r.transactions.create(date: "2026-06-04", title: "Later", lineItems: [(checking.id, -5, nil), (food.id, 5, nil)])
        let liA = try #require(a.lineItems.first { $0.accountId == checking.id }).id

        let stmt = try r.statements.create(accountId: checking.id, startDate: "2026-05-01", endDate: "2026-05-31",
                                           beginningBalance: 0, endingBalance: -12)
        _ = try r.statements.reconcileLineItems(statementId: stmt.id, lineItemIds: [liA])

        let got = try #require(try r.statements.get(statementId: stmt.id))
        #expect(got.lineItems?.map(\.id) == [liA])
        #expect(!got.isBalanced)

        let status = try r.statements.status(accountId: checking.id)
        #expect(status.statementCount == 1)
        #expect(status.unbalancedStatementIds == [stmt.id])
        #expect(status.lastStatementEndDate == "2026-05-31")
        #expect(status.unreconciledLineItemCount == 1)
        #expect(status.unreconciledSinceLastStatement == 1)
    }

    @Test("Update changes a statement's balances in place")
    func updateBalances() throws {
        let r = try makeRepos()
        defer { TestVaultHelper.cleanup(r.vault) }
        let checking = try r.accounts.create(name: "Checking", accountClass: AccountClass.checking)
        let food = try r.categories.create(name: "Food", type: "expense")
        let a = try r.transactions.create(date: "2026-05-03", title: "A", lineItems: [(checking.id, -10, nil), (food.id, 10, nil)])
        let liA = try #require(a.lineItems.first { $0.accountId == checking.id }).id
        let stmt = try r.statements.create(accountId: checking.id, startDate: "2026-05-01", endDate: "2026-05-31",
                                           beginningBalance: 0, endingBalance: -12)
        _ = try r.statements.reconcileLineItems(statementId: stmt.id, lineItemIds: [liA])

        let updated = try r.statements.update(statementId: stmt.id, endingBalance: -10)
        #expect(updated.id == stmt.id)
        #expect(updated.endingBalance == -10)
        #expect(updated.beginningBalance == 0)
        #expect(updated.isBalanced)
        #expect(throws: ToolError.self) { _ = try r.statements.update(statementId: stmt.id) }
    }
}
