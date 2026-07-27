// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

/// Regression tests for investment-account cash balances.
///
/// Banktivity's native convention stores a security trade's cash leg on
/// `SecurityLineItem.pAmount` and leaves the register `LineItem.pTransactionAmount`
/// at zero. Summing `pTransactionAmount` therefore counts plain cash transfers
/// (deposits into the account, withdrawals out of it) while silently dropping
/// every buy cost and sell proceed — so any account funded by trade proceeds
/// rather than by deposits drifts by the net of all trade cash.
///
/// `pRunningBalance` is maintained by Banktivity itself and is the figure the
/// app displays, so it is authoritative regardless of which convention a given
/// register uses.
@Suite("Balance breakdown")
struct BalanceBreakdownTests {

    /// Mirrors the real Coinbase register: funded once with cash, position bought,
    /// position sold at a gain, then the proceeds withdrawn to checking. Only the
    /// deposit and the withdrawal carry `pTransactionAmount`; the trades carry zero
    /// and live on their `SecurityLineItem`.
    ///
    /// Register ends at zero. Summing `pTransactionAmount` yields 10_000 - 12_000
    /// = -2_000, because the withdrawal is counted but the sell proceeds that
    /// funded it are not.
    @Test("cash follows the register running balance, not the sum of line-item amounts")
    func cashUsesRunningBalanceForNativeSecurityTrades() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let ctx = vault.container.viewContext
        let (usd, _) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let (buyType, sellType) = try TestVaultHelper.seedTransactionTypes(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: usd)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: usd)

        // 1. Cash deposit in — carries pTransactionAmount, register goes to 10_000.
        try makeCashTransaction(
            ctx: ctx, account: account, currency: usd,
            date: "2026-01-01", title: "Funding", amount: 10_000, runningBalance: 10_000
        )

        // 2. Buy — cash leg on the SecurityLineItem, pTransactionAmount stays 0.
        try makeTradeTransaction(
            ctx: ctx, account: account, currency: usd, security: security, txType: buyType,
            date: "2026-01-02", title: "Buy", shares: 100, tradeAmount: -10_000, runningBalance: 0
        )

        // 3. Sell at a gain — again zero on the register line, +12_000 on the trade.
        try makeTradeTransaction(
            ctx: ctx, account: account, currency: usd, security: security, txType: sellType,
            date: "2026-01-03", title: "Sell", shares: -100, tradeAmount: 12_000, runningBalance: 12_000
        )

        // 4. Withdraw the proceeds — carries pTransactionAmount, register back to 0.
        try makeCashTransaction(
            ctx: ctx, account: account, currency: usd,
            date: "2026-01-04", title: "Withdraw to checking", amount: -12_000, runningBalance: 0
        )

        try ctx.save()

        let repo = AccountRepository(container: vault.container)
        let accountId = BaseRepository.extractPK(from: account.objectID)
        let breakdown = try repo.getBalanceBreakdown(accountId: accountId)

        // The position was fully sold and the proceeds withdrawn: cash is zero.
        #expect(abs(breakdown.cash) < 0.005, "cash was \(breakdown.cash), expected 0")
        #expect(abs(breakdown.holdingsValue) < 0.005, "holdings were \(breakdown.holdingsValue), expected 0")
    }

    /// A plain cash account has no security lines, so both the running balance and
    /// the sum of line-item amounts agree. This pins that the fix does not regress
    /// the ordinary checking/savings path.
    @Test("cash accounts are unaffected")
    func cashOnlyAccountStillBalances() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let ctx = vault.container.viewContext
        let (usd, _) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: usd)

        try makeCashTransaction(
            ctx: ctx, account: account, currency: usd,
            date: "2026-01-01", title: "Deposit", amount: 500, runningBalance: 500
        )
        try makeCashTransaction(
            ctx: ctx, account: account, currency: usd,
            date: "2026-01-02", title: "Withdrawal", amount: -125.50, runningBalance: 374.50
        )
        try ctx.save()

        let repo = AccountRepository(container: vault.container)
        let accountId = BaseRepository.extractPK(from: account.objectID)
        let breakdown = try repo.getBalanceBreakdown(accountId: accountId)

        #expect(abs(breakdown.cash - 374.50) < 0.005, "cash was \(breakdown.cash), expected 374.50")
    }

    /// An account with no line items at all must report zero rather than trip over
    /// the empty running-balance lookup.
    @Test("empty account reports zero")
    func emptyAccountReportsZero() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (usd, _) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: usd)

        let repo = AccountRepository(container: vault.container)
        let accountId = BaseRepository.extractPK(from: account.objectID)
        let breakdown = try repo.getBalanceBreakdown(accountId: accountId)

        #expect(breakdown.cash == 0)
        #expect(breakdown.holdingsValue == 0)
    }

    // MARK: - Helpers

    @discardableResult
    private func makeTransaction(
        ctx: NSManagedObjectContext,
        currency: NSManagedObject,
        txType: NSManagedObject?,
        date: String,
        title: String
    ) -> NSManagedObject {
        let tx = BaseRepository.createObject(entityName: "Transaction", in: ctx)
        tx.setValue(title, forKey: "pTitle")
        tx.setValue(UUID().uuidString, forKey: "pUniqueID")
        tx.setValue(false, forKey: "pCleared")
        tx.setValue(false, forKey: "pVoid")
        tx.setValue(false, forKey: "pAdjustment")
        BaseRepository.setDate(tx, "pDate", isoString: date)
        BaseRepository.setNow(tx, "pCreationTime")
        BaseRepository.setNow(tx, "pModificationDate")
        tx.setValue(currency, forKey: "pCurrency")
        if let txType { tx.setValue(txType, forKey: "pTransactionType") }
        return tx
    }

    @discardableResult
    private func makeLineItem(
        ctx: NSManagedObjectContext,
        transaction: NSManagedObject,
        account: NSManagedObject,
        amount: Double,
        runningBalance: Double
    ) -> NSManagedObject {
        let li = BaseRepository.createObject(entityName: "LineItem", in: ctx)
        li.setValue(amount as NSNumber, forKey: "pTransactionAmount")
        li.setValue(runningBalance as NSNumber, forKey: "pRunningBalance")
        li.setValue(UUID().uuidString, forKey: "pUniqueID")
        li.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
        li.setValue(false, forKey: "pCleared")
        BaseRepository.setNow(li, "pCreationTime")
        li.setValue(account, forKey: "pAccount")
        li.setValue(transaction, forKey: "pTransaction")
        return li
    }

    private func makeCashTransaction(
        ctx: NSManagedObjectContext,
        account: NSManagedObject,
        currency: NSManagedObject,
        date: String,
        title: String,
        amount: Double,
        runningBalance: Double
    ) throws {
        let tx = makeTransaction(ctx: ctx, currency: currency, txType: nil, date: date, title: title)
        makeLineItem(
            ctx: ctx, transaction: tx, account: account,
            amount: amount, runningBalance: runningBalance
        )
    }

    /// Native Banktivity trade: register line carries zero, cash lives on the
    /// `SecurityLineItem`, and `pRunningBalance` reflects the resulting cash.
    private func makeTradeTransaction(
        ctx: NSManagedObjectContext,
        account: NSManagedObject,
        currency: NSManagedObject,
        security: NSManagedObject,
        txType: NSManagedObject,
        date: String,
        title: String,
        shares: Double,
        tradeAmount: Double,
        runningBalance: Double
    ) throws {
        let tx = makeTransaction(ctx: ctx, currency: currency, txType: txType, date: date, title: title)
        let li = makeLineItem(
            ctx: ctx, transaction: tx, account: account,
            amount: 0, runningBalance: runningBalance
        )

        let sli = BaseRepository.createObject(entityName: "SecurityLineItem", in: ctx)
        sli.setValue(shares as NSNumber, forKey: "pShares")
        sli.setValue(tradeAmount as NSNumber, forKey: "pAmount")
        sli.setValue(0.0 as NSNumber, forKey: "pPricePerShare")
        sli.setValue(0.0 as NSNumber, forKey: "pCommission")
        sli.setValue(0.0 as NSNumber, forKey: "pIncome")
        sli.setValue(1.0 as NSNumber, forKey: "pPriceMultiplier")
        sli.setValue(security, forKey: "pSecurity")
        sli.setValue(li, forKey: "pLineItem")
    }
}
