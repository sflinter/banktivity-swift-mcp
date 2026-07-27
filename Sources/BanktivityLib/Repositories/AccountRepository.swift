// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

/// Repository for account operations using Core Data
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

    /// Get account balance: register cash (SUM of plain LineItem amounts) plus the
    /// market value of any security holdings in the account.
    ///
    /// Cash lives on the plain LineItem — the register view, which is what the
    /// Banktivity desktop displays. SecurityLineItem.pAmount is the trade's cash
    /// detail (drives cost basis) and must NOT be added on top of the line items:
    /// doing so double-counts wherever the register lines carry the trade cash
    /// (the repaired/native convention). See the 2026-07-23 Elevated Investments
    /// register repair for the history of this bug.
    public func getBalance(accountId: Int) throws -> Double {
        let breakdown = try getBalanceBreakdown(accountId: accountId)
        return breakdown.cash + breakdown.holdingsValue
    }

    /// Cash / holdings-market-value breakdown for an account.
    public func getBalanceBreakdown(accountId: Int) throws -> (cash: Double, holdingsValue: Double) {
        try performRead { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else { return (0, 0) }
            let cash = try self.latestRunningBalance(account: account, in: ctx)
            let holdings = try self.sumHoldingsMarketValue(
                sliPredicate: NSPredicate(format: "pLineItem.pAccount == %@ AND pShares != nil", account),
                in: ctx)
            return (cash, holdings)
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
        return try accountList.map { account in
            let balance = try getBalance(accountId: account.id)
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

    /// Sum pTransactionAmount for LineItems matching a predicate
    private func sumLineItemAmounts(predicate: NSPredicate, in ctx: NSManagedObjectContext) throws -> Double {
        let request = NSFetchRequest<NSDictionary>(entityName: "LineItem")
        request.predicate = predicate
        request.resultType = .dictionaryResultType

        let sumExpr = NSExpression(forFunction: "sum:", arguments: [
            NSExpression(forKeyPath: "pTransactionAmount")
        ])
        let desc = NSExpressionDescription()
        desc.name = "total"
        desc.expression = sumExpr
        desc.expressionResultType = .decimalAttributeType
        request.propertiesToFetch = [desc]

        let results = try ctx.fetch(request)
        if let result = results.first, let total = result["total"] as? NSDecimalNumber {
            return total.doubleValue
        }
        return 0.0
    }

    /// Count line items matching a predicate (used as a proxy for transaction count)
    private func countDistinctTransactions(predicate: NSPredicate, in ctx: NSManagedObjectContext) throws -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LineItem")
        request.predicate = predicate
        return try ctx.count(for: request)
    }

    /// Banktivity's own register cash balance for an account: the `pRunningBalance`
    /// of its most recent line item.
    ///
    /// This must NOT be computed by summing `pTransactionAmount`. A security trade
    /// in the native convention leaves the register line at zero and carries its
    /// cash on `SecurityLineItem.pAmount`, so such a sum silently drops every buy
    /// cost and sell proceed while still counting plain cash transfers in and out —
    /// leaving any account funded by trade proceeds off by the net of all trade
    /// cash. Registers rewritten to carry trade cash on the line item itself (the
    /// "repaired" convention) break the mirror-image way if that cash is added back.
    /// `pRunningBalance` is maintained by Banktivity and matches what the app shows
    /// under either convention.
    ///
    /// The most recent line item is selected by `pTransaction.pDate` then `pCreationTime`.
    /// `pIntraDaySortIndex` is deliberately not used as a tiebreaker — it is unreliable on
    /// back-dated imports and same-date multi-entry transactions (matching the choice in
    /// upstream PR #27). Including it changed no account balance in a 45-account vault.
    ///
    /// KNOWN LIMITATION: the write paths in this library set `pRunningBalance` to 0
    /// on newly created line items and never recompute the rows after them (see
    /// TransactionRepository.createTransaction, SecurityRepository.createShareAdjustment,
    /// CategorizationRepository). A transaction written through this library therefore
    /// reads back as cash 0 for its account until Banktivity itself reopens the vault
    /// and recalculates. Reads are correct for any app-maintained register; fixing this
    /// properly means recomputing the account's running balances on write.
    private func latestRunningBalance(
        _ accountPredicate: NSPredicate, in ctx: NSManagedObjectContext
    ) throws -> Double {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LineItem")
        request.predicate = accountPredicate
        request.sortDescriptors = [
            NSSortDescriptor(key: "pTransaction.pDate", ascending: false),
            NSSortDescriptor(key: "pCreationTime", ascending: false)
        ]
        request.fetchLimit = 1
        guard let latest = try ctx.fetch(request).first else { return 0.0 }
        return Self.doubleValue(latest, "pRunningBalance")
    }

    private func latestRunningBalance(
        account: NSManagedObject, in ctx: NSManagedObjectContext
    ) throws -> Double {
        try latestRunningBalance(NSPredicate(format: "pAccount == %@", account), in: ctx)
    }

    /// Register cash plus holdings market value for accounts with the given classes.
    /// Cash is summed per account from each register's running balance — see
    /// `latestRunningBalance` for why it cannot be one aggregate sum.
    private func sumByAccountClasses(_ classes: [Int], in ctx: NSManagedObjectContext) throws -> Double {
        let accountRequest = NSFetchRequest<NSManagedObject>(entityName: "Account")
        accountRequest.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: classes.map { cls in
            NSPredicate(format: "pAccountClass == %d", cls)
        })
        var lineItemTotal = 0.0
        for account in try ctx.fetch(accountRequest) {
            lineItemTotal += try latestRunningBalance(account: account, in: ctx)
        }

        let sliPredicates = classes.map { cls in
            NSPredicate(format: "pLineItem.pAccount.pAccountClass == %d AND pShares != nil", cls)
        }
        let sliCompound = NSCompoundPredicate(orPredicateWithSubpredicates: sliPredicates)
        let holdingsTotal = try sumHoldingsMarketValue(sliPredicate: sliCompound, in: ctx)

        return lineItemTotal + holdingsTotal
    }

    /// Market value of security positions whose SecurityLineItems match the
    /// predicate: accumulates net shares per security, then multiplies by the
    /// latest close price. Securities with no price history contribute 0.
    private func sumHoldingsMarketValue(
        sliPredicate: NSPredicate, in ctx: NSManagedObjectContext
    ) throws -> Double {
        let request = NSFetchRequest<NSManagedObject>(entityName: "SecurityLineItem")
        request.predicate = sliPredicate
        let items = try ctx.fetch(request)

        var sharesBySecurity: [String: Double] = [:]  // pUniqueID -> net shares
        for sli in items {
            guard let security = Self.relatedObject(sli, "pSecurity") else { continue }
            let uniqueId = Self.stringValue(security, "pUniqueID")
            guard !uniqueId.isEmpty else { continue }
            sharesBySecurity[uniqueId, default: 0] += Self.doubleValue(sli, "pShares")
        }

        var total = 0.0
        for (uniqueId, shares) in sharesBySecurity {
            guard abs(shares) > 0.0001 else { continue }
            let piRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityPriceItem")
            piRequest.predicate = NSPredicate(format: "pSecurityID == %@", uniqueId)
            piRequest.fetchLimit = 1
            guard let priceItem = try ctx.fetch(piRequest).first else { continue }
            let priceRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityPrice")
            priceRequest.predicate = NSPredicate(format: "pSecurityPriceItem == %@", priceItem)
            priceRequest.sortDescriptors = [NSSortDescriptor(key: "pDate", ascending: false)]
            priceRequest.fetchLimit = 1
            guard let latest = try ctx.fetch(priceRequest).first else { continue }
            total += shares * Self.doubleValue(latest, "pClosePrice")
        }
        return total
    }

    /// Sum pAmount (cash effect) for SecurityLineItems matching a predicate
    private func sumSecurityLineItemCash(predicate: NSPredicate, in ctx: NSManagedObjectContext) throws -> Double {
        let request = NSFetchRequest<NSDictionary>(entityName: "SecurityLineItem")
        request.predicate = predicate
        request.resultType = .dictionaryResultType

        let sumExpr = NSExpression(forFunction: "sum:", arguments: [
            NSExpression(forKeyPath: "pAmount")
        ])
        let desc = NSExpressionDescription()
        desc.name = "total"
        desc.expression = sumExpr
        desc.expressionResultType = .decimalAttributeType
        request.propertiesToFetch = [desc]

        let results = try ctx.fetch(request)
        if let result = results.first, let total = result["total"] as? NSDecimalNumber {
            return total.doubleValue
        }
        return 0.0
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
