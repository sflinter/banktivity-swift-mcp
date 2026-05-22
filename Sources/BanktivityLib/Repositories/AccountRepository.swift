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

    /// Get account balance using account-currency line item amounts
    public func getBalance(accountId: Int) throws -> Double {
        try performRead { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else { return 0 }
            return try self.sumLineItemAmounts(predicate: NSPredicate(format: "pAccount == %@", account), in: ctx)
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

    /// Sum account-currency amounts for LineItems matching a predicate
    private func sumLineItemAmounts(predicate: NSPredicate, in ctx: NSManagedObjectContext) throws -> Double {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LineItem")
        request.predicate = predicate

        let lineItems = try ctx.fetch(request)
        var total = 0.0
        for lineItem in lineItems {
            let amount = Self.doubleValue(lineItem, "pTransactionAmount")
            let exchangeRate = Self.doubleValue(lineItem, "pExchangeRate")
            total += amount * exchangeRate
        }
        return total
    }

    /// Count line items matching a predicate (used as a proxy for transaction count)
    private func countDistinctTransactions(predicate: NSPredicate, in ctx: NSManagedObjectContext) throws -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LineItem")
        request.predicate = predicate
        return try ctx.count(for: request)
    }

    /// Sum line item amounts for accounts with the given account classes
    private func sumByAccountClasses(_ classes: [Int], in ctx: NSManagedObjectContext) throws -> Double {
        let predicates = classes.map { cls in
            NSPredicate(format: "pAccount.pAccountClass == %d", cls)
        }
        let compound = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        return try sumLineItemAmounts(predicate: compound, in: ctx)
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
