// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

/// Repository for account operations using Core Data
final class AccountRepository: BaseRepository, @unchecked Sendable {

    /// List all accounts, optionally including hidden ones
    func list(includeHidden: Bool = false) throws -> [AccountDTO] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Account")

        if !includeHidden {
            request.predicate = NSPredicate(format: "pHidden == NO OR pHidden == nil")
        }

        request.sortDescriptors = [
            NSSortDescriptor(key: "pAccountClass", ascending: true),
            NSSortDescriptor(key: "pName", ascending: true),
        ]

        let results = try fetch(request)
        return results.map { mapToDTO($0) }
    }

    /// Get a single account by its primary key (Z_PK)
    func get(accountId: Int) throws -> AccountDTO? {
        guard let object = try fetchByPK(entityName: "Account", pk: accountId) else { return nil }
        return mapToDTO(object)
    }

    /// Find an account by name (case-insensitive, checks both pName and pFullName)
    func findByName(_ name: String) throws -> AccountDTO? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Account")
        request.predicate = NSPredicate(
            format: "pName ==[cd] %@ OR pFullName ==[cd] %@", name, name
        )
        request.fetchLimit = 1

        guard let object = try fetch(request).first else { return nil }
        return mapToDTO(object)
    }

    /// Get account balance using an aggregate fetch (SUM of line item amounts)
    func getBalance(accountId: Int) throws -> Double {
        guard let account = try fetchByPK(entityName: "Account", pk: accountId) else { return 0 }
        return try sumLineItemAmounts(predicate: NSPredicate(format: "pAccount == %@", account))
    }

    /// Get net worth using efficient aggregate queries
    func getNetWorth() throws -> NetWorthDTO {
        let assets = try sumByAccountClasses(Array(assetClasses))
        let liabilities = try sumByAccountClasses(Array(liabilityClasses))

        return NetWorthDTO(
            assets: assets,
            liabilities: liabilities,
            netWorth: assets + liabilities,
            formattedAssets: ToolHelpers.formatCurrency(assets),
            formattedLiabilities: ToolHelpers.formatCurrency(liabilities),
            formattedNetWorth: ToolHelpers.formatCurrency(assets + liabilities)
        )
    }

    /// Get spending or income by category using aggregate queries
    func getCategoryAnalysis(
        type: String,
        startDate: String? = nil,
        endDate: String? = nil
    ) throws -> [CategorySpendingDTO] {
        let accountClass = type == "income" ? AccountClass.income : AccountClass.expense

        let accountRequest = NSFetchRequest<NSManagedObject>(entityName: "Account")
        accountRequest.predicate = NSPredicate(format: "pAccountClass == %d", accountClass)
        let categoryAccounts = try fetch(accountRequest)

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

            let total = try sumLineItemAmounts(predicate: compound)
            let txCount = try countDistinctTransactions(predicate: compound)

            if txCount > 0 {
                results.append(CategorySpendingDTO(
                    category: categoryName,
                    total: total,
                    transactionCount: txCount,
                    formattedTotal: ToolHelpers.formatCurrency(total)
                ))
            }
        }

        results.sort { $0.total > $1.total }
        return results
    }

    // MARK: - Aggregate Helpers

    /// Sum pTransactionAmount for LineItems matching a predicate
    private func sumLineItemAmounts(predicate: NSPredicate) throws -> Double {
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

        let results = try context.fetch(request)
        if let result = results.first, let total = result["total"] as? NSDecimalNumber {
            return total.doubleValue
        }
        return 0.0
    }

    /// Count line items matching a predicate (used as a proxy for transaction count)
    private func countDistinctTransactions(predicate: NSPredicate) throws -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: "LineItem")
        request.predicate = predicate
        return try context.count(for: request)
    }

    /// Sum line item amounts for accounts with the given account classes
    private func sumByAccountClasses(_ classes: [Int]) throws -> Double {
        let predicates = classes.map { cls in
            NSPredicate(format: "pAccount.pAccountClass == %d", cls)
        }
        let compound = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        return try sumLineItemAmounts(predicate: compound)
    }

    // MARK: - DTO Mapping

    func mapToDTO(_ object: NSManagedObject) -> AccountDTO {
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
