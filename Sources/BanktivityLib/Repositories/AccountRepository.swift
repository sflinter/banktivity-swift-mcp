// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

/// Repository for account operations using Core Data
struct NetWorthAccountBalance: Sendable {
    let name: String
    let accountClass: Int
    let currency: String?
    let balance: Double
}

public final class AccountRepository: BaseRepository, @unchecked Sendable {

    /// List all accounts, optionally including hidden ones
    public func list(includeHidden: Bool = false) throws -> [AccountDTO] {
        try performRead { [self] ctx in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Account")

            if !includeHidden {
                request.predicate = NSPredicate(format: "pHidden == NO OR pHidden == nil")
            }

            request.sortDescriptors = [
                NSSortDescriptor(key: "pAccountClass", ascending: true),
                NSSortDescriptor(key: "pName", ascending: true),
            ]

            let results = try ctx.fetch(request)
            return results.map { self.mapToDTO($0) }
        }
    }

    /// Get a single account by its primary key (Z_PK)
    public func get(accountId: Int) throws -> AccountDTO? {
        try performRead { [self] ctx in
            guard let object = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else { return nil }
            return self.mapToDTO(object)
        }
    }

    /// Find an account by name (case-insensitive, checks both pName and pFullName)
    public func findByName(_ name: String) throws -> AccountDTO? {
        try performRead { [self] ctx in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Account")
            request.predicate = NSPredicate(
                format: "pName ==[cd] %@ OR pFullName ==[cd] %@", name, name
            )
            request.fetchLimit = 1

            guard let object = try ctx.fetch(request).first else { return nil }
            return self.mapToDTO(object)
        }
    }

    /// Get account balance: the sum of the account's line items in the
    /// account's currency (amount x exchange rate).
    public func getBalance(accountId: Int) throws -> Double {
        try performRead { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                throw ToolError.notFound("Account not found: \(accountId)")
            }
            return try self.sumLineItemAmounts(predicate: NSPredicate(format: "pAccount == %@", account), in: ctx)
        }
    }

    /// Recompute the cached `LineItem.pRunningBalance` for one account, the way
    /// Banktivity does (`-[IGGCAccountingPrimaryAccount recalculateBalanceForDate:]`):
    /// lines in transaction-date order, each holding the running sum of
    /// `accountAmount` rounded to cents.
    ///
    /// The running balance is a per-device cache that does not travel in sync
    /// records, so nothing is marked modified. The desktop app shows an
    /// account's cash from it, and rows the CLI writes leave it stale.
    ///
    /// Banktivity's within-day order differs between accounts (creation time in
    /// some, row order in others) and only changes intermediate rows, never the
    /// final balance. So an account whose final running balance is already
    /// right is left alone unless `force` is set, and otherwise the within-day
    /// order that best matches the balances Banktivity already wrote is used.
    public func recalculateRunningBalances(accountId: Int, force: Bool = false) throws -> RunningBalanceRecalcDTO {
        try performWriteReturning { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                throw ToolError.notFound("Account not found: \(accountId)")
            }
            let request = NSFetchRequest<NSManagedObject>(entityName: "LineItem")
            request.predicate = NSPredicate(format: "pAccount == %@", account)
            request.relationshipKeyPathsForPrefetching = ["pSecurityLineItem", "pTransaction.pTransactionType"]
            let lines = try ctx.fetch(request)

            func cents(_ value: Double) -> Decimal { Decimal(string: String(format: "%.2f", value)) ?? 0 }
            let amounts = Dictionary(uniqueKeysWithValues: lines.map { ($0.objectID, cents(Self.accountAmount($0))) })
            let date = { (li: NSManagedObject) in Self.relatedObject(li, "pTransaction").flatMap { Self.dateValue($0, "pDate") } ?? 0 }
            let created = { (li: NSManagedObject) in Self.dateValue(li, "pCreationTime") ?? 0 }
            let pk = { (li: NSManagedObject) in Self.extractPK(from: li.objectID) }
            let intraday = { (li: NSManagedObject) in Self.intValue(li, "pIntraDaySortIndex") }
            let byCreation = lines.sorted {
                (date($0), created($0), intraday($0), pk($0)) < (date($1), created($1), intraday($1), pk($1))
            }
            let byRow = lines.sorted { (date($0), intraday($0), pk($0)) < (date($1), intraday($1), pk($1)) }

            func balances(_ ordered: [NSManagedObject]) -> [Decimal] {
                var running = Decimal(0)
                return ordered.map { running += amounts[$0.objectID] ?? 0; return running }
            }
            func matches(_ ordered: [NSManagedObject], _ values: [Decimal]) -> Int {
                zip(ordered, values).filter { Self.decimalValue($0.0, "pRunningBalance") == $0.1 }.count
            }
            let creationValues = balances(byCreation), rowValues = balances(byRow)
            let (ordered, values) = matches(byCreation, creationValues) >= matches(byRow, rowValues)
                ? (byCreation, creationValues) : (byRow, rowValues)

            let total = values.last ?? 0
            // Banktivity's last row (in either order) already holds the total: not stale.
            let lastDate = ordered.last.map(date)
            let finalIsRight = lines.isEmpty || ordered.contains {
                date($0) == lastDate && Self.decimalValue($0, "pRunningBalance") == total
            }
            let previous = byRow.last.map { Self.doubleValue($0, "pRunningBalance") } ?? 0

            var changed = 0
            if force || !finalIsRight {
                for (line, value) in zip(ordered, values) where Self.decimalValue(line, "pRunningBalance") != value {
                    line.setValue(NSDecimalNumber(decimal: value), forKey: "pRunningBalance")
                    changed += 1
                }
            }
            return RunningBalanceRecalcDTO(
                accountId: accountId,
                accountName: Self.stringValue(account, "pName"),
                lineItemCount: lines.count,
                changedCount: changed,
                previousBalance: previous,
                balance: NSDecimalNumber(decimal: total).doubleValue,
                wasStale: !finalIsRight
            )
        }
    }

    /// Market value of an investment account's open security positions.
    ///
    /// For each security: shares held x latest close x the price multiplier of
    /// the most recent trade, summed in `Decimal`. The price multiplier is how
    /// Banktivity converts a security priced in another currency into the
    /// account's currency (1 when they match). A security with no price
    /// contributes 0.
    ///
    /// This is reported beside the cash balance and never added to it.
    /// Returns nil when the account is missing or is not an investment account.
    public func holdingsValue(accountId: Int) throws -> Double? {
        try performRead { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx),
                  Self.isInvestmentAccountClass(Self.intValue(account, "pAccountClass")) else { return nil }
            return NSDecimalNumber(decimal: try self.holdingsValue(account: account, in: ctx)).doubleValue
        }
    }

    /// Get net worth by converting each account's native-currency balance to the reporting currency.
    public func getNetWorth() throws -> NetWorthDTO {
        let accounts = try list(includeHidden: true).filter { account in
            assetClasses.contains(account.accountClass) || liabilityClasses.contains(account.accountClass)
        }
        // Cash plus holdings market value: net worth counts investments, as
        // Banktivity's own net worth does.
        var balances: [Int: Double] = [:]
        for account in accounts {
            balances[account.id] = try getBalance(accountId: account.id) + (try holdingsValue(accountId: account.id) ?? 0)
        }
        let rates = try exchangeRates()

        let accountBalances = accounts.map { account in
            NetWorthAccountBalance(
                name: account.name,
                accountClass: account.accountClass,
                currency: account.currency,
                balance: balances[account.id] ?? 0
            )
        }
        return Self.aggregateNetWorth(
            reportingCurrency: reportingCurrency,
            accounts: accountBalances,
            rates: rates
        )
    }

    /// Get spending or income by category using aggregate queries
    public func getCategoryAnalysis(
        type: String,
        startDate: String? = nil,
        endDate: String? = nil
    ) throws -> [CategorySpendingDTO] {
        try performRead { [self] ctx in
            let accountClass = type == "income" ? AccountClass.income : AccountClass.expense

            let accountRequest = NSFetchRequest<NSManagedObject>(entityName: "Account")
            accountRequest.predicate = NSPredicate(format: "pAccountClass == %d", accountClass)
            let categoryAccounts = try ctx.fetch(accountRequest)

            var results: [CategorySpendingDTO] = []

            for account in categoryAccounts {
                let categoryName = Self.stringValue(account, "pName")

                // Build predicate for line items in this account with date filtering
                var predicates: [NSPredicate] = [
                    NSPredicate(format: "pAccount == %@", account)
                ]

                if let startDate = startDate, let ts = DateConversion.fromISO(startDate) {
                    predicates.append(NSPredicate(
                        format: "pTransaction.pDate >= %@", DateConversion.toDate(ts) as NSDate
                    ))
                }
                if let endDate = endDate, let ts = DateConversion.endOfDayExclusive(endDate) {
                    predicates.append(NSPredicate(
                        format: "pTransaction.pDate < %@", DateConversion.toDate(ts) as NSDate
                    ))
                }

                let compound = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)

                let total = try self.sumLineItemAmounts(predicate: compound, in: ctx)
                let txCount = try self.countDistinctTransactions(predicate: compound, in: ctx)

                if txCount > 0 {
                    results.append(CategorySpendingDTO(
                        category: categoryName,
                        total: total,
                        transactionCount: txCount,
                        formattedTotal: formatCurrency(total, currency: reportingCurrency)
                    ))
                }
            }

            results.sort { $0.total > $1.total }
            return results
        }
    }

    /// List accounts with balances, optionally filtering out categories
    public func listWithBalances(includeHidden: Bool = false, includeCategories: Bool = false) throws -> [AccountDTO] {
        var accountList = try list(includeHidden: includeHidden)
        if !includeCategories {
            accountList = accountList.filter { $0.accountClass < AccountClass.income }
        }
        return try accountList.map { account in
            let balance = try getBalance(accountId: account.id)
            let holdings = try holdingsValue(accountId: account.id)
            return AccountDTO(
                id: account.id,
                name: account.name,
                fullName: account.fullName,
                accountClass: account.accountClass,
                accountType: account.accountType,
                hidden: account.hidden,
                currency: account.currency,
                balance: balance,
                formattedBalance: formatCurrency(balance, currency: account.currency ?? "EUR"),
                holdingsValue: holdings,
                formattedHoldingsValue: holdings.map { formatCurrency($0, currency: account.currency ?? "EUR") }
            )
        }
    }

    /// Get a summary of the vault (account counts by type, category counts, tag count, net worth)
    public func getSummary(tagCount: Int) throws -> SummaryDTO {
        let allAccounts = try list(includeHidden: true)
        let netWorth = try getNetWorth()
        let bankAccounts = allAccounts.filter { $0.accountClass < AccountClass.income }
        let transactionCount = try count(entityName: "Transaction")

        return SummaryDTO(
            accounts: SummaryDTO.AccountSummary(
                total: bankAccounts.count,
                checking: bankAccounts.filter { $0.accountClass == AccountClass.checking }.count,
                savings: bankAccounts.filter { $0.accountClass == AccountClass.savings }.count,
                creditCards: bankAccounts.filter { $0.accountClass == AccountClass.creditCard }.count
            ),
            categories: SummaryDTO.CategorySummary(
                income: allAccounts.filter { $0.accountClass == AccountClass.income }.count,
                expense: allAccounts.filter { $0.accountClass == AccountClass.expense }.count
            ),
            transactions: transactionCount,
            tags: tagCount,
            netWorth: netWorth
        )
    }

    /// Resolve an account from either an ID or a name, preferring ID
    public func resolveAccountId(id: Int?, name: String?) throws -> Int {
        if let id = id {
            guard try get(accountId: id) != nil else {
                throw ToolError.notFound("Account not found: \(id)")
            }
            return id
        }
        if let name = name {
            if let account = try findByName(name) {
                return account.id
            }
            throw ToolError.notFound("Account not found: \(name)")
        }
        throw ToolError.missingParameter("Either account_id or account_name is required")
    }

    // MARK: - Write Operations

    /// Create a new bank account (checking, savings, etc.)
    public func create(
        name: String,
        accountClass: Int = AccountClass.savings,
        currencyCode: String = "EUR",
        hidden: Bool = false
    ) throws -> AccountDTO {
        guard accountClass < AccountClass.income else {
            throw ToolError.invalidInput("Use CategoryRepository to create income/expense categories")
        }

        try performWrite { ctx in
            let account = Self.createObject(entityName: "PrimaryAccount", in: ctx)
            account.setValue(name, forKey: "pName")
            account.setValue(name, forKey: "pFullName")
            account.setValue(accountClass, forKey: "pAccountClass")
            account.setValue(hidden, forKey: "pHidden")
            account.setValue(true, forKey: "pDebit")
            account.setValue(false, forKey: "pTaxable")
            account.setValue(Self.generateUUID(), forKey: "pUniqueID")
            Self.setNow(account, "pCreationTime")
            Self.setNow(account, "pModificationDate")

            let currRequest = NSFetchRequest<NSManagedObject>(entityName: "Currency")
            currRequest.predicate = NSPredicate(format: "pCode ==[cd] %@", currencyCode)
            currRequest.fetchLimit = 1
            if let currency = try ctx.fetch(currRequest).first {
                account.setValue(currency, forKey: "currency")
            }
        }

        if let result = try findByName(name) {
            return result
        }
        throw ToolError.notFound("Failed to retrieve created account")
    }

    // MARK: - Aggregate Helpers

    /// Sum account-currency amounts for LineItems matching a predicate, using
    /// Banktivity's own per-line rule (`BaseRepository.accountAmount`).
    private func sumLineItemAmounts(predicate: NSPredicate, in ctx: NSManagedObjectContext) throws -> Double {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LineItem")
        request.predicate = predicate
        request.relationshipKeyPathsForPrefetching = ["pSecurityLineItem", "pTransaction.pTransactionType"]

        var total = 0.0
        for lineItem in try ctx.fetch(request) {
            total += Self.accountAmount(lineItem)
        }
        return total
    }

    /// Banktivity's investment account classes (2000 investment to 2010).
    static func isInvestmentAccountClass(_ accountClass: Int) -> Bool {
        (2000...2010).contains(accountClass)
    }

    /// Holdings market value for one account, in the account's currency.
    /// Ported from #19's `holdingsValue` (also proposed in #33).
    private func holdingsValue(account: NSManagedObject, in ctx: NSManagedObjectContext) throws -> Decimal {
        struct Position {
            var shares = Decimal(0)
            var multiplier = Decimal(1)
            var multiplierDate = -Double.greatestFiniteMagnitude
            var security: NSManagedObject?
        }

        let request = NSFetchRequest<NSManagedObject>(entityName: "SecurityLineItem")
        request.predicate = NSPredicate(format: "pLineItem.pAccount == %@ AND pShares != nil", account)

        var positions: [Int: Position] = [:]
        for sli in try ctx.fetch(request) {
            guard let security = Self.relatedObject(sli, "pSecurity") else { continue }
            let key = Self.extractPK(from: security.objectID)
            var position = positions[key] ?? Position()
            position.shares += Self.decimalValue(sli, "pShares")
            position.security = security

            // The multiplier of the most recent trade wins.
            let date = Self.relatedObject(sli, "pLineItem")
                .flatMap { Self.relatedObject($0, "pTransaction") }
                .flatMap { Self.dateValue($0, "pDate") } ?? -Double.greatestFiniteMagnitude
            if date >= position.multiplierDate {
                position.multiplierDate = date
                let multiplier = Self.decimalValue(sli, "pPriceMultiplier")
                position.multiplier = multiplier == 0 ? 1 : multiplier
            }
            positions[key] = position
        }

        var total = Decimal(0)
        for position in positions.values {
            guard position.shares != 0, let security = position.security,
                  let close = try latestClosePrice(for: security, in: ctx) else { continue }
            total += position.shares * close * position.multiplier
        }
        return total
    }

    private func latestClosePrice(for security: NSManagedObject, in ctx: NSManagedObjectContext) throws -> Decimal? {
        let priceItemRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityPriceItem")
        priceItemRequest.predicate = NSPredicate(format: "pSecurityID == %@", Self.stringValue(security, "pUniqueID"))
        priceItemRequest.fetchLimit = 1
        guard let priceItem = try ctx.fetch(priceItemRequest).first else { return nil }

        let priceRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityPrice")
        priceRequest.predicate = NSPredicate(format: "pSecurityPriceItem == %@", priceItem)
        priceRequest.sortDescriptors = [NSSortDescriptor(key: "pDate", ascending: false)]
        priceRequest.fetchLimit = 1
        guard let price = try ctx.fetch(priceRequest).first else { return nil }
        return Self.decimalValue(price, "pClosePrice")
    }

    /// Count line items matching a predicate (used as a proxy for transaction count)
    private func countDistinctTransactions(predicate: NSPredicate, in ctx: NSManagedObjectContext) throws -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LineItem")
        request.predicate = predicate
        return try ctx.count(for: request)
    }

    static func aggregateNetWorth(
        reportingCurrency rawReportingCurrency: String,
        accounts: [NetWorthAccountBalance],
        rates: [ExchangeRateRecord],
        now: Date = Date()
    ) -> NetWorthDTO {
        let reportingCurrency = ReportingCurrency.resolve(rawReportingCurrency)
        struct CurrencyTotals {
            var original = Decimal(0)
            var converted = Decimal(0)
            var assets = Decimal(0)
            var liabilities = Decimal(0)
            var lookup: ExchangeRateLookupResult
        }

        var totalsByCurrency: [String: CurrencyTotals] = [:]
        var warnings: [String] = []

        for account in accounts {
            let currency = ReportingCurrency.resolve(account.currency ?? reportingCurrency)
            let balance = Decimal(account.balance)
            guard let lookup = ExchangeRateRepository.resolve(from: currency, to: reportingCurrency, rates: rates) else {
                warnings.append("Account \(account.name) (currency \(currency)) excluded: no exchange rate available")
                continue
            }

            let converted = balance * lookup.rate
            var currencyTotals = totalsByCurrency[currency] ?? CurrencyTotals(
                original: Decimal(0),
                converted: Decimal(0),
                assets: Decimal(0),
                liabilities: Decimal(0),
                lookup: lookup
            )
            currencyTotals.original += balance
            currencyTotals.converted += converted
            if assetClasses.contains(account.accountClass) {
                currencyTotals.assets += converted
            } else if liabilityClasses.contains(account.accountClass) {
                currencyTotals.liabilities += converted
            }
            currencyTotals.lookup = lookup
            totalsByCurrency[currency] = currencyTotals
        }

        var assets = Decimal(0)
        var liabilities = Decimal(0)
        var breakdown: [String: CurrencyBreakdownDTO] = [:]

        for (currency, totals) in totalsByCurrency {
            assets += totals.assets
            liabilities += totals.liabilities
            breakdown[currency] = CurrencyBreakdownDTO(
                originalSum: Self.doubleValue(totals.original),
                rate: Self.doubleValue(totals.lookup.rate),
                rateDate: totals.lookup.effectiveDate.map { Self.isoDate($0) },
                converted: Self.doubleValue(totals.converted),
                hops: totals.lookup.hops,
                path: totals.lookup.path
            )

            if totals.lookup.hops > 0,
               let effectiveDate = totals.lookup.effectiveDate,
               let ageDays = Self.rateAgeDays(effectiveDate, now: now), ageDays >= 1 {
                let route = totals.lookup.path.joined(separator: "→")
                warnings.append("Exchange rate \(route) is \(ageDays) day\(ageDays == 1 ? "" : "s") old (effective \(Self.isoDate(effectiveDate))).")
            }
        }

        let assetDouble = Self.doubleValue(assets)
        let liabilityDouble = Self.doubleValue(liabilities)
        let netWorth = assetDouble + liabilityDouble
        return NetWorthDTO(
            reportingCurrency: reportingCurrency,
            assets: assetDouble,
            liabilities: liabilityDouble,
            netWorth: netWorth,
            formattedAssets: formatCurrency(assetDouble, currency: reportingCurrency),
            formattedLiabilities: formatCurrency(liabilityDouble, currency: reportingCurrency),
            formattedNetWorth: formatCurrency(netWorth, currency: reportingCurrency),
            breakdown: NetWorthBreakdownDTO(byCurrency: breakdown),
            warnings: warnings
        )
    }

    private func exchangeRates() throws -> [ExchangeRateRecord] {
        try performRead { ctx in
            let request = NSFetchRequest<NSManagedObject>(entityName: "ExchangeRate")
            let results = try ctx.fetch(request)
            let currencyCodesById = try ExchangeRateRepository.currencyCodesByUniqueId(in: ctx)
            return results.compactMap { rate in
                guard let sourceId = rate.value(forKey: "pSourceCurrencyID") as? String,
                      let destinationId = rate.value(forKey: "pDestinationCurrencyID") as? String,
                      let source = currencyCodesById[sourceId] ?? (Locale.commonISOCurrencyCodes.contains(sourceId) ? sourceId : nil),
                      let destination = currencyCodesById[destinationId] ?? (Locale.commonISOCurrencyCodes.contains(destinationId) ? destinationId : nil),
                      case let exchangeRate = Self.decimalValue(rate, "pExchangeRate"), exchangeRate != 0
                else { return nil }

                return ExchangeRateRecord(
                    source: source,
                    destination: destination,
                    rate: exchangeRate,
                    effectiveDate: rate.value(forKey: "pEffectiveDate") as? Date
                )
            }
        }
    }

    private static func doubleValue(_ decimal: Decimal) -> Double {
        NSDecimalNumber(decimal: decimal).doubleValue
    }

    private static func isoDate(_ date: Date) -> String {
        DateConversion.toISO(DateConversion.fromDate(date))
    }

    private static func rateAgeDays(_ effectiveDate: Date, now: Date = Date()) -> Int? {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: effectiveDate)
        let end = calendar.startOfDay(for: now)
        return calendar.dateComponents([.day], from: start, to: end).day
    }

    // MARK: - DTO Mapping

    public func mapToDTO(_ object: NSManagedObject) -> AccountDTO {
        let accountClass = Self.intValue(object, "pAccountClass")
        let pk = Self.extractPK(from: object.objectID)

        return AccountDTO(
            id: pk,
            name: Self.stringValue(object, "pName"),
            fullName: Self.stringValue(object, "pFullName"),
            accountClass: accountClass,
            accountType: accountTypeName(for: accountClass),
            hidden: Self.boolValue(object, "pHidden"),
            currency: Self.currencyCode(object),
            balance: nil,
            formattedBalance: nil
        )
    }
}
