// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

/// Repository for account operations using Core Data
public final class AccountRepository: BaseRepository, @unchecked Sendable {
    private static let shareAdjustmentBaseTypes: Set<Int> = [210, 211, 212, 250]
    private static let investmentAccountClasses: Set<Int> = Set(2000...2010)

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

    /// Get account balance using account-local line item amounts.
    /// Investment accounts add current holdings value to the cash component.
    public func getBalance(accountId: Int) throws -> Double {
        try performRead { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else { return 0 }
            let cash = try self.sumLineItemAmounts(predicate: NSPredicate(format: "pAccount == %@", account), in: ctx)
            guard Self.isInvestmentAccount(account) else { return cash }
            return cash + (try self.holdingsValue(account: account, in: ctx))
        }
    }

    /// Get market value of open security positions for an investment account.
    public func holdingsValue(accountId: Int) throws -> Double {
        try performRead { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else { return 0 }
            return try self.holdingsValue(account: account, in: ctx)
        }
    }

    /// Get net worth using efficient aggregate queries
    public func getNetWorth() throws -> NetWorthDTO {
        try performRead { [self] ctx in
            let assets = try self.sumByAccountClasses(Array(assetClasses), in: ctx)
            let liabilities = try self.sumByAccountClasses(Array(liabilityClasses), in: ctx)

            return NetWorthDTO(
                assets: assets,
                liabilities: liabilities,
                netWorth: assets + liabilities,
                formattedAssets: formatCurrency(assets),
                formattedLiabilities: formatCurrency(liabilities),
                formattedNetWorth: formatCurrency(assets + liabilities)
            )
        }
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
                if let endDate = endDate, let ts = DateConversion.fromISO(endDate) {
                    predicates.append(NSPredicate(
                        format: "pTransaction.pDate <= %@", DateConversion.toDate(ts) as NSDate
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
                        formattedTotal: formatCurrency(total)
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

        let accountIds = Set(accountList.map(\.id))
        let balances = try balancesByAccountId(accountIds)

        return accountList.map { account in
            let balance = balances[account.id] ?? 0
            return AccountDTO(
                id: account.id,
                name: account.name,
                fullName: account.fullName,
                accountClass: account.accountClass,
                accountType: account.accountType,
                hidden: account.hidden,
                currency: account.currency,
                balance: balance,
                formattedBalance: formatCurrency(balance, currency: account.currency ?? "EUR")
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

    /// Sum account-local LineItem amounts matching a predicate.
    ///
    /// Banktivity stores `pTransactionAmount` in the transaction currency. Multiplying by
    /// `pExchangeRate` converts it to the line item's account currency. Investment line items
    /// can also carry account-currency cash offsets on the related `SecurityLineItem.pAmount`.
    private func sumLineItemAmounts(predicate: NSPredicate, in ctx: NSManagedObjectContext) throws -> Double {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LineItem")
        request.predicate = predicate
        request.fetchBatchSize = 1000
        request.relationshipKeyPathsForPrefetching = ["pSecurityLineItem", "pTransaction.pTransactionType"]

        let results = try ctx.fetch(request)
        let total = results.reduce(into: Decimal(0)) { partial, lineItem in
            let securityLineItem = Self.relatedObject(lineItem, "pSecurityLineItem")
            partial += Self.accountAmount(
                transactionAmount: lineItem.value(forKey: "pTransactionAmount"),
                exchangeRate: lineItem.value(forKey: "pExchangeRate"),
                securityAmount: securityLineItem?.value(forKey: "pAmount"),
                transactionBaseType: Self.transactionBaseType(for: lineItem)
            )
        }

        return NSDecimalNumber(decimal: total).doubleValue
    }

    private func balancesByAccountId(_ accountIds: Set<Int>) throws -> [Int: Double] {
        guard !accountIds.isEmpty else { return [:] }

        return try performRead { [self] ctx in
            let accountRequest = NSFetchRequest<NSManagedObject>(entityName: "Account")
            let accounts = try ctx.fetch(accountRequest)
            let accountsById = Dictionary(uniqueKeysWithValues: accounts.compactMap { account -> (Int, NSManagedObject)? in
                let id = Self.extractPK(from: account.objectID)
                return accountIds.contains(id) ? (id, account) : nil
            })

            let request = NSFetchRequest<NSManagedObject>(entityName: "LineItem")
            request.predicate = NSPredicate(format: "pAccount != nil")
            request.fetchBatchSize = 1000
            request.relationshipKeyPathsForPrefetching = ["pAccount", "pSecurityLineItem", "pTransaction.pTransactionType"]

            let results = try ctx.fetch(request)
            var totals = results.reduce(into: [Int: Decimal]()) { partial, lineItem in
                guard let account = Self.relatedObject(lineItem, "pAccount") else { return }
                let accountId = Self.extractPK(from: account.objectID)
                guard accountIds.contains(accountId) else { return }
                let securityLineItem = Self.relatedObject(lineItem, "pSecurityLineItem")

                partial[accountId, default: Decimal(0)] += Self.accountAmount(
                    transactionAmount: lineItem.value(forKey: "pTransactionAmount"),
                    exchangeRate: lineItem.value(forKey: "pExchangeRate"),
                    securityAmount: securityLineItem?.value(forKey: "pAmount"),
                    transactionBaseType: Self.transactionBaseType(for: lineItem)
                )
            }

            for (accountId, account) in accountsById where Self.isInvestmentAccount(account) {
                let holdings = Decimal(try self.holdingsValue(account: account, in: ctx))
                totals[accountId, default: Decimal(0)] += holdings
            }

            return totals.mapValues { NSDecimalNumber(decimal: $0).doubleValue }
        }
    }

    private func holdingsValue(account: NSManagedObject, in ctx: NSManagedObjectContext) throws -> Double {
        guard Self.isInvestmentAccount(account) else { return 0 }
        let accountId = Self.extractPK(from: account.objectID)
        let accountCurrency = Self.currencyCode(account)

        struct PositionKey: Hashable {
            let accountPK: Int
            let securityPK: Int
        }
        struct PositionAccum {
            var shares = Decimal(0)
            var latestMultiplier = Decimal(1)
            var latestDate: Double = -Double.greatestFiniteMagnitude
            var security: NSManagedObject?
        }

        let request = NSFetchRequest<NSManagedObject>(entityName: "SecurityLineItem")
        request.predicate = NSPredicate(format: "pLineItem.pAccount == %@ AND pShares != nil", account)
        request.fetchBatchSize = 1000
        request.relationshipKeyPathsForPrefetching = ["pLineItem", "pLineItem.pTransaction", "pSecurity"]

        let items = try ctx.fetch(request)
        var positions: [PositionKey: PositionAccum] = [:]

        for securityLineItem in items {
            guard let security = Self.relatedObject(securityLineItem, "pSecurity") else { continue }
            guard let lineItem = Self.relatedObject(securityLineItem, "pLineItem") else { continue }
            let securityId = Self.extractPK(from: security.objectID)
            let key = PositionKey(accountPK: accountId, securityPK: securityId)
            let transactionDate = Self.relatedObject(lineItem, "pTransaction").map { Self.doubleValue($0, "pDate") } ?? 0

            var accum = positions[key] ?? PositionAccum()
            accum.shares += Self.decimalValue(securityLineItem.value(forKey: "pShares")) ?? Decimal(0)
            if transactionDate >= accum.latestDate {
                accum.latestDate = transactionDate
                accum.latestMultiplier = Self.decimalValue(securityLineItem.value(forKey: "pPriceMultiplier")) ?? Decimal(1)
            }
            accum.security = security
            positions[key] = accum
        }

        var total = Decimal(0)
        for (_, position) in positions {
            guard let security = position.security else { continue }
            guard position.shares != Decimal(0) else { continue }
            guard let closePrice = try latestClosePrice(for: security, in: ctx) else {
                let securityId = Self.extractPK(from: security.objectID)
                fputs("Warning: Missing latest SecurityPrice for security ID \(securityId); holdings value contributes 0.\n", stderr)
                continue
            }

            if let securityCurrency = Self.relatedObject(security, "pCurrency").flatMap({ Self.string($0, "pCode") }),
               let accountCurrency,
               securityCurrency != accountCurrency {
                let securityId = Self.extractPK(from: security.objectID)
                fputs("Warning: Security ID \(securityId) currency \(securityCurrency) differs from account currency \(accountCurrency); using pPriceMultiplier.\n", stderr)
            }

            total += position.shares * closePrice * position.latestMultiplier
        }

        return NSDecimalNumber(decimal: total).doubleValue
    }

    private func latestClosePrice(for security: NSManagedObject, in ctx: NSManagedObjectContext) throws -> Decimal? {
        let uniqueId = Self.stringValue(security, "pUniqueID")
        let priceItemRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityPriceItem")
        priceItemRequest.predicate = NSPredicate(format: "pSecurityID == %@", uniqueId)
        priceItemRequest.fetchLimit = 1
        guard let priceItem = try ctx.fetch(priceItemRequest).first else { return nil }

        let priceRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityPrice")
        priceRequest.predicate = NSPredicate(format: "pSecurityPriceItem == %@", priceItem)
        priceRequest.sortDescriptors = [NSSortDescriptor(key: "pDate", ascending: false)]
        priceRequest.fetchLimit = 1
        guard let price = try ctx.fetch(priceRequest).first else { return nil }
        return Self.decimalValue(price.value(forKey: "pClosePrice"))
    }

    static func accountAmount(
        transactionAmount: Any?,
        exchangeRate: Any?,
        securityAmount: Any? = nil,
        transactionBaseType: Int? = nil
    ) -> Decimal {
        let amount = decimalValue(transactionAmount) ?? Decimal(0)
        let rate = effectiveExchangeRate(exchangeRate)
        let includeSecurityOffset = transactionBaseType.map { !shareAdjustmentBaseTypes.contains($0) } ?? true
        let offset = includeSecurityOffset ? (decimalValue(securityAmount) ?? Decimal(0)) : Decimal(0)
        return (amount * rate) + offset
    }

    private static func transactionBaseType(for lineItem: NSManagedObject) -> Int? {
        guard let transaction = relatedObject(lineItem, "pTransaction"),
              let transactionType = relatedObject(transaction, "pTransactionType")
        else { return nil }
        return intValue(transactionType, "pBaseType")
    }

    private static func isInvestmentAccount(_ account: NSManagedObject) -> Bool {
        investmentAccountClasses.contains(intValue(account, "pAccountClass"))
    }

    private static func effectiveExchangeRate(_ value: Any?) -> Decimal {
        guard let rate = decimalValue(value), rate != Decimal(0) else {
            fputs("Warning: LineItem has missing or zero pExchangeRate; using 1.\n", stderr)
            return Decimal(1)
        }
        return rate
    }

    private static func decimalValue(_ value: Any?) -> Decimal? {
        switch value {
        case let decimal as Decimal:
            return decimal
        case let number as NSDecimalNumber:
            return number.decimalValue
        case let number as NSNumber:
            return number.decimalValue
        case let string as String:
            return Decimal(string: string)
        default:
            return nil
        }
    }

    /// Count line items matching a predicate (used as a proxy for transaction count)
    private func countDistinctTransactions(predicate: NSPredicate, in ctx: NSManagedObjectContext) throws -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LineItem")
        request.predicate = predicate
        return try ctx.count(for: request)
    }

    /// Sum line item amounts for accounts with the given account classes.
    /// Investment account classes include holdings value in addition to cash.
    private func sumByAccountClasses(_ classes: [Int], in ctx: NSManagedObjectContext) throws -> Double {
        let classSet = Set(classes)
        let predicates = classes.map { cls in
            NSPredicate(format: "pAccount.pAccountClass == %d", cls)
        }
        let compound = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        var total = try sumLineItemAmounts(predicate: compound, in: ctx)

        guard !classSet.isDisjoint(with: Self.investmentAccountClasses) else { return total }
        let accountRequest = NSFetchRequest<NSManagedObject>(entityName: "Account")
        accountRequest.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: classSet.map {
            NSPredicate(format: "pAccountClass == %d", $0)
        })
        for account in try ctx.fetch(accountRequest) where Self.isInvestmentAccount(account) {
            total += try holdingsValue(account: account, in: ctx)
        }
        return total
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
            accountType: getAccountTypeName(accountClass),
            hidden: Self.boolValue(object, "pHidden"),
            currency: Self.currencyCode(object),
            balance: nil,
            formattedBalance: nil
        )
    }
}
