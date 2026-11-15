// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

/// Banktivity does not persist its lot matching — `SecurityLot` exists in the
/// model and holds no rows, because gains are computed when a report is rendered
/// and then discarded. `getRealizedGains` recomputes them, so these tests pin the
/// rules that make the result match Banktivity's own capital-gains export.
///
/// Each case here corresponds to a rule that was established by diffing against
/// that export row by row, and each one cost measurable rows when it was wrong.
@Suite("Security realized gains", .serialized)
@MainActor
struct SecurityRealizedGainsTests {

    // MARK: - Fixture helpers

    /// A transaction type beyond the buy/sell pair the shared helper seeds.
    private func seedType(_ container: NSPersistentContainer, name: String, base: Int16) throws -> NSManagedObject {
        let ctx = container.viewContext
        let type = NSEntityDescription.insertNewObject(forEntityName: "TransactionType", into: ctx)
        type.setValue(base, forKey: "pBaseType")
        type.setValue(name, forKey: "pName")
        type.setValue(UUID().uuidString, forKey: "pUniqueID")
        type.setValue(Date(), forKey: "pCreationTime")
        type.setValue(Date(), forKey: "pModificationDate")
        try ctx.save()
        return type
    }

    /// One security event: a transaction, its line item, and the security line
    /// item that carries the shares and money.
    @discardableResult
    private func seedEvent(
        _ container: NSPersistentContainer,
        type: NSManagedObject,
        account: NSManagedObject,
        security: NSManagedObject,
        day: Int,
        shares: NSDecimalNumber,
        amount: NSDecimalNumber,
        pricePerShare: NSDecimalNumber = .zero,
        income: NSDecimalNumber = .zero,
        costBasisMethod: Int16? = nil
    ) throws -> NSManagedObject {
        let ctx = container.viewContext

        let tx = NSEntityDescription.insertNewObject(forEntityName: "Transaction", into: ctx)
        tx.setValue(Date(timeIntervalSinceReferenceDate: Double(day) * 86_400), forKey: "pDate")
        tx.setValue(type, forKey: "pTransactionType")
        tx.setValue(UUID().uuidString, forKey: "pUniqueID")
        tx.setValue(Date(), forKey: "pCreationTime")
        tx.setValue(Date(), forKey: "pModificationDate")

        // LineItem carries no pModificationDate and SecurityLineItem carries
        // none of the bookkeeping trio -- only the entities that have those
        // attributes get them, or Core Data raises NSUnknownKeyException.
        let line = NSEntityDescription.insertNewObject(forEntityName: "LineItem", into: ctx)
        line.setValue(tx, forKey: "pTransaction")
        line.setValue(account, forKey: "pAccount")
        line.setValue(amount.multiplying(by: NSDecimalNumber(value: -1)), forKey: "pTransactionAmount")
        line.setValue(UUID().uuidString, forKey: "pUniqueID")
        line.setValue(Date(), forKey: "pCreationTime")

        let sli = NSEntityDescription.insertNewObject(forEntityName: "SecurityLineItem", into: ctx)
        sli.setValue(line, forKey: "pLineItem")
        sli.setValue(security, forKey: "pSecurity")
        sli.setValue(shares, forKey: "pShares")
        sli.setValue(amount, forKey: "pAmount")
        sli.setValue(pricePerShare, forKey: "pPricePerShare")
        sli.setValue(NSDecimalNumber.one, forKey: "pPriceMultiplier")
        sli.setValue(NSDecimalNumber.zero, forKey: "pCommission")
        sli.setValue(income, forKey: "pIncome")
        if let method = costBasisMethod { sli.setValue(method, forKey: "pCostBasisMethod") }

        try ctx.save()
        return sli
    }

    private struct Fixture {
        let vault: TestVaultHelper.TestVault
        let container: NSPersistentContainer
        let account: NSManagedObject
        let security: NSManagedObject
        let buy: NSManagedObject
        let sell: NSManagedObject
    }

    private func makeFixture() throws -> Fixture {
        let vault = try TestVaultHelper.createFreshVault()
        let container = vault.container
        let currencies = try TestVaultHelper.seedCurrencies(in: container)
        let types = try TestVaultHelper.seedTransactionTypes(in: container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: container, currency: currencies.usd)
        let security = try TestVaultHelper.seedSecurity(in: container, symbol: "TEST", currency: currencies.usd)
        return Fixture(vault: vault, container: container, account: account,
                       security: security, buy: types.buy, sell: types.sell)
    }

    private func dec(_ s: String) -> NSDecimalNumber { NSDecimalNumber(string: s) }

    // MARK: - Tests

    @Test("A sell is matched against the oldest lot first")
    func fifoOrder() throws {
        let f = try makeFixture()
        defer { TestVaultHelper.cleanup(f.vault) }

        try seedEvent(f.container, type: f.buy, account: f.account, security: f.security,
                      day: 0, shares: dec("10"), amount: dec("-100"))
        try seedEvent(f.container, type: f.buy, account: f.account, security: f.security,
                      day: 10, shares: dec("10"), amount: dec("-200"))
        try seedEvent(f.container, type: f.sell, account: f.account, security: f.security,
                      day: 20, shares: dec("-10"), amount: dec("300"))

        let rows = try SecurityRepository(container: f.container).getRealizedGains()
        #expect(rows.count == 1)
        // The FIRST lot must be consumed: basis 100, not 200.
        #expect(rows[0].costBasis == Decimal(100))
        #expect(rows[0].proceeds == Decimal(300))
        #expect(rows[0].gain == Decimal(200))
    }

    @Test("A sell spanning two lots produces one row per lot")
    func partialLots() throws {
        let f = try makeFixture()
        defer { TestVaultHelper.cleanup(f.vault) }

        try seedEvent(f.container, type: f.buy, account: f.account, security: f.security,
                      day: 0, shares: dec("10"), amount: dec("-100"))
        try seedEvent(f.container, type: f.buy, account: f.account, security: f.security,
                      day: 10, shares: dec("10"), amount: dec("-300"))
        try seedEvent(f.container, type: f.sell, account: f.account, security: f.security,
                      day: 20, shares: dec("-15"), amount: dec("600"))

        let rows = try SecurityRepository(container: f.container).getRealizedGains()
        #expect(rows.count == 2)
        #expect(rows.map(\.shares) == [Decimal(10), Decimal(5)])
        // Proceeds follow the shares: 10/15 and 5/15 of 600.
        #expect(rows[0].proceeds == Decimal(400))
        #expect(rows[1].proceeds == Decimal(200))
        // Half of the second lot's 300 basis follows the 5 shares taken from it.
        #expect(rows[1].costBasis == Decimal(150))
    }

    @Test("Move Shares In opens a lot, like a buy")
    func moveSharesInOpensALot() throws {
        let f = try makeFixture()
        defer { TestVaultHelper.cleanup(f.vault) }
        let moveIn = try seedType(f.container, name: "Move Shares In", base: 102)

        try seedEvent(f.container, type: moveIn, account: f.account, security: f.security,
                      day: 0, shares: dec("10"), amount: dec("-250"))
        try seedEvent(f.container, type: f.sell, account: f.account, security: f.security,
                      day: 10, shares: dec("-10"), amount: dec("400"))

        let rows = try SecurityRepository(container: f.container).getRealizedGains()
        // Ignoring transferred-in shares would leave no lot to match and drop
        // the disposal entirely, or match it against a later unrelated buy.
        #expect(rows.count == 1)
        #expect(rows[0].costBasis == Decimal(250))
        #expect(rows[0].gain == Decimal(150))
    }

    @Test("A split moves shares and leaves total basis alone")
    func splitPreservesBasis() throws {
        let f = try makeFixture()
        defer { TestVaultHelper.cleanup(f.vault) }
        let split = try seedType(f.container, name: "Split Shares", base: 250)

        try seedEvent(f.container, type: f.buy, account: f.account, security: f.security,
                      day: 0, shares: dec("10"), amount: dec("-100"))
        // 2-for-1: the row carries the ADJUSTMENT, with no amount and no price.
        try seedEvent(f.container, type: split, account: f.account, security: f.security,
                      day: 5, shares: dec("10"), amount: .zero)
        try seedEvent(f.container, type: f.sell, account: f.account, security: f.security,
                      day: 10, shares: dec("-20"), amount: dec("300"))

        let rows = try SecurityRepository(container: f.container).getRealizedGains()
        #expect(rows.count == 1)
        #expect(rows[0].shares == Decimal(20))
        // Basis is unchanged by the split — still the original 100.
        #expect(rows[0].costBasis == Decimal(100))
        #expect(rows[0].gain == Decimal(200))
    }

    /// A split that changes the CUSIP arrives as two same-day legs (old shares
    /// out, new shares in). Whichever is fetched first, the lot keeps its basis.
    @Test("Two same-day split legs net to one change, in either fetch order",
          arguments: [true, false])
    func sameDaySplitLegsNet(decreaseFirst: Bool) throws {
        let f = try makeFixture()
        defer { TestVaultHelper.cleanup(f.vault) }
        let split = try seedType(f.container, name: "Split Shares", base: 250)

        try seedEvent(f.container, type: f.buy, account: f.account, security: f.security,
                      day: 0, shares: dec("2.5"), amount: dec("-1000"))
        // 4-for-1 with a CUSIP change: 2.5 out, 10 in, on one day.
        let legs: [(String)] = decreaseFirst ? ["-2.5", "10"] : ["10", "-2.5"]
        for leg in legs {
            try seedEvent(f.container, type: split, account: f.account, security: f.security,
                          day: 5, shares: dec(leg), amount: .zero)
        }
        try seedEvent(f.container, type: f.sell, account: f.account, security: f.security,
                      day: 10, shares: dec("-4"), amount: dec("500"))

        let rows = try SecurityRepository(container: f.container).getRealizedGains()
        #expect(rows.count == 1)
        #expect(rows[0].shares == Decimal(4))
        // 4 of the 10 post-split shares carry 4/10 of the original 1,000.
        #expect(rows[0].costBasis == Decimal(400))
        #expect(rows[0].gain == Decimal(100))
        #expect(rows[0].acquired == DateConversion.toISO(0.0))   // the original lot, not a split-day lot
    }

    @Test("Netting leaves other events and other days alone")
    func nettingIsScoped() {
        struct E: Equatable { let split: Bool; let day: Int; let shares: Decimal }
        let input = [E(split: false, day: 1, shares: 5), E(split: true, day: 2, shares: -2),
                     E(split: false, day: 2, shares: 1), E(split: true, day: 2, shares: 8),
                     E(split: true, day: 3, shares: 4)]
        let out = SecurityRepository.nettingSameDaySplits(
            input, isSplit: { $0.split }, day: { $0.day }, shares: { $0.shares },
            withShares: { E(split: $0.split, day: $0.day, shares: $1) })
        #expect(out == [E(split: false, day: 1, shares: 5), E(split: true, day: 2, shares: 6),
                        E(split: false, day: 2, shares: 1), E(split: true, day: 3, shares: 4)])
    }

    @Test("Return of capital reduces basis, and its amount is in pIncome")
    func returnOfCapitalReducesBasis() throws {
        let f = try makeFixture()
        defer { TestVaultHelper.cleanup(f.vault) }
        let roc = try seedType(f.container, name: "Return Of Capital", base: 310)

        try seedEvent(f.container, type: f.buy, account: f.account, security: f.security,
                      day: 0, shares: dec("10"), amount: dec("-100"))
        // Shares are zero and the amount is zero; the reduction is in pIncome.
        try seedEvent(f.container, type: roc, account: f.account, security: f.security,
                      day: 5, shares: .zero, amount: .zero, income: dec("25"))
        try seedEvent(f.container, type: f.sell, account: f.account, security: f.security,
                      day: 10, shares: dec("-10"), amount: dec("200"))

        let rows = try SecurityRepository(container: f.container).getRealizedGains()
        #expect(rows.count == 1)
        #expect(rows[0].costBasis == Decimal(75))
        #expect(rows[0].gain == Decimal(125))
    }

    @Test("A transfer out moves the lot at its basis and realises nothing")
    func moveSharesOutRealisesNothing() throws {
        let f = try makeFixture()
        defer { TestVaultHelper.cleanup(f.vault) }
        let moveOut = try seedType(f.container, name: "Move Shares Out", base: 211)

        // The CCL shape: bought Tuesday, transferred out Thursday, and the export
        // still reads proceeds == basis, gain 0.00, term "Long". The recorded
        // amount on the row is ignored -- here it is deliberately not the basis,
        // so a proceeds figure taken from `pAmount` would show up as a gain.
        try seedEvent(f.container, type: f.buy, account: f.account, security: f.security,
                      day: 0, shares: dec("7"), amount: dec("-182.32"))
        try seedEvent(f.container, type: moveOut, account: f.account, security: f.security,
                      day: 2, shares: dec("-7"), amount: dec("500"))

        let rows = try SecurityRepository(container: f.container).getRealizedGains()
        #expect(rows.count == 1)
        #expect(rows[0].costBasis == Decimal(string: "182.32"))
        #expect(rows[0].proceeds == Decimal(string: "182.32"))
        #expect(rows[0].gain == 0)
        #expect(rows[0].term == "Long", "held two days, but a transfer reads Long")
    }

    @Test("The holding period is long only beyond 365 days")
    func termBoundary() throws {
        for (heldDays, expected) in [(365, "Short"), (366, "Long")] {
            let f = try makeFixture()
            defer { TestVaultHelper.cleanup(f.vault) }

            try seedEvent(f.container, type: f.buy, account: f.account, security: f.security,
                          day: 0, shares: dec("1"), amount: dec("-10"))
            try seedEvent(f.container, type: f.sell, account: f.account, security: f.security,
                          day: heldDays, shares: dec("-1"), amount: dec("20"))

            let rows = try SecurityRepository(container: f.container).getRealizedGains()
            #expect(rows.count == 1)
            #expect(rows[0].term == expected, "held \(heldDays) days")
        }
    }

    @Test("An unvalidated cost-basis method is refused, not guessed")
    func refusesUnknownCostBasisMethod() throws {
        let f = try makeFixture()
        defer { TestVaultHelper.cleanup(f.vault) }

        // 2 is not FIFO. Emitting numbers for a method this code has not been
        // checked against would produce a schedule someone files.
        try seedEvent(f.container, type: f.buy, account: f.account, security: f.security,
                      day: 0, shares: dec("10"), amount: dec("-100"), costBasisMethod: 2)
        try seedEvent(f.container, type: f.sell, account: f.account, security: f.security,
                      day: 10, shares: dec("-10"), amount: dec("200"))

        #expect(throws: SecurityRepository.RealizedGainError.self) {
            _ = try SecurityRepository(container: f.container).getRealizedGains()
        }
    }

    @Test("A half-cent apportionment rounds the way Banktivity does")
    func decimalExactness() throws {
        let f = try makeFixture()
        defer { TestVaultHelper.cleanup(f.vault) }

        // The SHOP shape from the real vault: a 0.237-share slice of a 2.37-share
        // disposal, where the apportioned proceeds land exactly on a half-cent.
        //
        //   Decimal:  200.45 x (0.237 / 2.37) = 20.045 exactly -> 20.04
        //   Double:   the tie is gone before rounding starts   -> 20.05
        //
        // That is the whole mechanism. Read through `doubleValue`, 0.237 comes
        // back one ULP high, the ratio lands on 0.1 instead of just under it,
        // and the product misses the tie by ~1e-14 -- so the rounding rule never
        // gets a tie to apply and the cent goes the other way.
        //
        // Not every half-cent shape separates them: at 408.05 the residues
        // happen to cancel and both give 40.80. This amount was picked because
        // it does separate them, so a revert of `decimalValue` to `doubleValue`
        // fails here rather than passing.
        try seedEvent(f.container, type: f.buy, account: f.account, security: f.security,
                      day: 0, shares: dec("0.237"), amount: dec("-15"))
        try seedEvent(f.container, type: f.buy, account: f.account, security: f.security,
                      day: 1, shares: dec("2.133"), amount: dec("-200"))
        try seedEvent(f.container, type: f.sell, account: f.account, security: f.security,
                      day: 10, shares: dec("-2.37"), amount: dec("200.45"))

        let rows = try SecurityRepository(container: f.container).getRealizedGains()
        #expect(rows.count == 2)
        #expect(rows[0].proceeds == Decimal(string: "20.04"))
        #expect(rows[0].costBasis == Decimal(string: "15.00"))
        #expect(rows[0].gain == Decimal(string: "5.04"))
    }

    @Test("Rounding is half-to-even")
    func roundingIsBankers() {
        #expect(SecurityRepository.roundToCents(Decimal(string: "40.805")!) == Decimal(string: "40.80"))
        #expect(SecurityRepository.roundToCents(Decimal(string: "40.815")!) == Decimal(string: "40.82"))
        #expect(SecurityRepository.roundToCents(Decimal(string: "-1.005")!) == Decimal(string: "-1.00"))
    }
}
