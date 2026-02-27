import CoreData
import Foundation

/// Repository for categorization operations using Core Data
final class CategorizationRepository: BaseRepository, @unchecked Sendable {
    private let categoryRepo: CategoryRepository
    private let importRuleRepo: ImportRuleRepository

    init(
        container: NSPersistentContainer,
        categoryRepo: CategoryRepository,
        importRuleRepo: ImportRuleRepository
    ) {
        self.categoryRepo = categoryRepo
        self.importRuleRepo = importRuleRepo
        super.init(container: container)
    }

    /// Find uncategorized transactions
    func getUncategorized(
        accountId: Int? = nil,
        startDate: String? = nil,
        endDate: String? = nil,
        limit: Int? = nil,
        excludeTransfers: Bool = true
    ) throws -> [UncategorizedTransactionDTO] {
        // Fetch transactions where at least one line item goes to an income/expense category
        // but another line item has no category assignment
        let request = NSFetchRequest<NSManagedObject>(entityName: "Transaction")

        var predicates: [NSPredicate] = []

        if let startDate = startDate, let ts = DateConversion.fromISO(startDate) {
            predicates.append(NSPredicate(format: "pDate >= %@", DateConversion.toDate(ts) as NSDate))
        }
        if let endDate = endDate, let ts = DateConversion.fromISO(endDate) {
            predicates.append(NSPredicate(format: "pDate <= %@", DateConversion.toDate(ts) as NSDate))
        }

        if !predicates.isEmpty {
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }

        request.sortDescriptors = [NSSortDescriptor(key: "pDate", ascending: false)]
        if let limit = limit { request.fetchLimit = limit * 3 } // fetch extra, filter later

        let transactions = try fetch(request)
        var results: [UncategorizedTransactionDTO] = []

        for tx in transactions {
            if let limit = limit, results.count >= limit { break }

            let lineItems = Self.relatedSet(tx, "lineItems")
            var hasCategory = false
            var hasNonCategory = false
            var primaryAccountName = ""
            var amount = 0.0
            var lineItemDTOs: [LineItemDTO] = []

            for li in lineItems {
                guard let account = Self.relatedObject(li, "pAccount") else { continue }
                let acClass = Self.intValue(account, "pAccountClass")
                let liAmount = Self.doubleValue(li, "pTransactionAmount")

                if acClass == AccountClass.income || acClass == AccountClass.expense {
                    hasCategory = true
                } else {
                    hasNonCategory = true
                    primaryAccountName = Self.stringValue(account, "pName")
                    amount = liAmount
                }

                lineItemDTOs.append(LineItemDTO(
                    id: Self.extractPK(from: li.objectID),
                    accountId: Self.extractPK(from: account.objectID),
                    accountName: Self.stringValue(account, "pName"),
                    amount: liAmount,
                    memo: Self.string(li, "pMemo"),
                    runningBalance: Self.doubleValue(li, "pRunningBalance")
                ))
            }

            // Uncategorized: has non-category line items but no category line items
            if hasNonCategory && !hasCategory {
                if excludeTransfers && lineItems.count == 2 {
                    // Check if it's a transfer (both line items are non-category)
                    let allNonCategory = lineItems.allSatisfy { li in
                        guard let account = Self.relatedObject(li, "pAccount") else { return false }
                        let acClass = Self.intValue(account, "pAccountClass")
                        return acClass != AccountClass.income && acClass != AccountClass.expense
                    }
                    if allNonCategory { continue }
                }

                let dateStr: String
                if let d = Self.dateValue(tx, "pDate") { dateStr = DateConversion.toISO(d) }
                else { dateStr = "unknown" }

                results.append(UncategorizedTransactionDTO(
                    id: Self.extractPK(from: tx.objectID),
                    date: dateStr,
                    title: Self.stringValue(tx, "pTitle"),
                    note: Self.string(tx, "pNote"),
                    accountName: primaryAccountName,
                    amount: amount,
                    lineItems: lineItemDTOs
                ))
            }
        }

        return results
    }

    /// Suggest category for a merchant based on import rules and historical data
    func suggestCategory(merchantName: String) throws -> [CategorySuggestionDTO] {
        var suggestions: [CategorySuggestionDTO] = []

        // Check import rules first
        let matchingRules = try importRuleRepo.match(description: merchantName)
        for rule in matchingRules {
            // The rule's template tells us the category
            if let template = try? fetchByPK(entityName: "TransactionTemplate", pk: rule.templateId) {
                let templateLineItems = Self.relatedSet(template, "pLineItemTemplates")
                for li in templateLineItems {
                    let accountId = Self.stringValue(li, "pAccountID")
                    // Look up the account/category by uniqueID
                    let catRequest = NSFetchRequest<NSManagedObject>(entityName: "Account")
                    catRequest.predicate = NSPredicate(format: "pUniqueID == %@", accountId)
                    catRequest.fetchLimit = 1
                    if let cat = try fetch(catRequest).first {
                        let acClass = Self.intValue(cat, "pAccountClass")
                        if acClass == AccountClass.income || acClass == AccountClass.expense {
                            suggestions.append(CategorySuggestionDTO(
                                categoryId: Self.extractPK(from: cat.objectID),
                                categoryName: Self.stringValue(cat, "pName"),
                                categoryPath: Self.stringValue(cat, "pFullName"),
                                confidence: 0.9,
                                reason: "Matched import rule: \(rule.pattern)",
                                matchCount: 1
                            ))
                        }
                    }
                }
            }
        }

        // Check historical transactions with similar titles
        let searchRequest = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
        searchRequest.predicate = NSPredicate(format: "pTitle LIKE[cd] %@", "*\(merchantName)*")
        searchRequest.sortDescriptors = [NSSortDescriptor(key: "pDate", ascending: false)]
        searchRequest.fetchLimit = 50

        let historicalTx = try fetch(searchRequest)
        var categoryCounts: [Int: (name: String, path: String, count: Int)] = [:]

        for tx in historicalTx {
            let lineItems = Self.relatedSet(tx, "lineItems")
            for li in lineItems {
                guard let account = Self.relatedObject(li, "pAccount") else { continue }
                let acClass = Self.intValue(account, "pAccountClass")
                if acClass == AccountClass.income || acClass == AccountClass.expense {
                    let catId = Self.extractPK(from: account.objectID)
                    let existing = categoryCounts[catId]
                    categoryCounts[catId] = (
                        name: Self.stringValue(account, "pName"),
                        path: Self.stringValue(account, "pFullName"),
                        count: (existing?.count ?? 0) + 1
                    )
                }
            }
        }

        let totalMatches = categoryCounts.values.reduce(0) { $0 + $1.count }
        for (catId, info) in categoryCounts {
            // Skip if already suggested by import rule
            if suggestions.contains(where: { $0.categoryId == catId }) { continue }
            let confidence = min(0.8, Double(info.count) / max(1.0, Double(totalMatches)) * 0.8 + 0.3)
            suggestions.append(CategorySuggestionDTO(
                categoryId: catId,
                categoryName: info.name,
                categoryPath: info.path,
                confidence: confidence,
                reason: "Historical: \(info.count) matching transactions",
                matchCount: info.count
            ))
        }

        suggestions.sort { $0.confidence > $1.confidence }
        return suggestions
    }

    /// Review categorizations for transactions
    func reviewCategorizations(
        accountId: Int? = nil,
        categoryId: Int? = nil,
        payeePattern: String? = nil,
        startDate: String? = nil,
        endDate: String? = nil,
        limit: Int? = nil
    ) throws -> [ReviewedTransactionDTO] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
        var predicates: [NSPredicate] = []

        if let startDate = startDate, let ts = DateConversion.fromISO(startDate) {
            predicates.append(NSPredicate(format: "pDate >= %@", DateConversion.toDate(ts) as NSDate))
        }
        if let endDate = endDate, let ts = DateConversion.fromISO(endDate) {
            predicates.append(NSPredicate(format: "pDate <= %@", DateConversion.toDate(ts) as NSDate))
        }
        if let pattern = payeePattern {
            predicates.append(NSPredicate(format: "pTitle LIKE[cd] %@", "*\(pattern)*"))
        }

        if !predicates.isEmpty {
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }
        request.sortDescriptors = [NSSortDescriptor(key: "pDate", ascending: false)]
        if let limit = limit { request.fetchLimit = limit }

        let transactions = try fetch(request)
        var results: [ReviewedTransactionDTO] = []

        for tx in transactions {
            let lineItems = Self.relatedSet(tx, "lineItems")
            var primaryAccountName = ""
            var amount = 0.0
            var catId: Int? = nil
            var catName: String? = nil
            var catPath: String? = nil

            for li in lineItems {
                guard let account = Self.relatedObject(li, "pAccount") else { continue }
                let acClass = Self.intValue(account, "pAccountClass")
                if acClass == AccountClass.income || acClass == AccountClass.expense {
                    catId = Self.extractPK(from: account.objectID)
                    catName = Self.stringValue(account, "pName")
                    catPath = Self.stringValue(account, "pFullName")
                } else {
                    primaryAccountName = Self.stringValue(account, "pName")
                    amount = Self.doubleValue(li, "pTransactionAmount")
                }
            }

            let dateStr: String
            if let d = Self.dateValue(tx, "pDate") { dateStr = DateConversion.toISO(d) }
            else { dateStr = "unknown" }

            results.append(ReviewedTransactionDTO(
                id: Self.extractPK(from: tx.objectID),
                date: dateStr,
                title: Self.stringValue(tx, "pTitle"),
                note: Self.string(tx, "pNote"),
                accountName: primaryAccountName,
                amount: amount,
                categoryId: catId,
                categoryName: catName,
                categoryPath: catPath
            ))
        }

        return results
    }

    /// Get payee category summary
    func getPayeeCategorySummary(
        accountId: Int? = nil,
        startDate: String? = nil,
        endDate: String? = nil,
        minTransactions: Int = 1
    ) throws -> [PayeeCategorySummaryDTO] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
        var predicates: [NSPredicate] = []

        if let startDate = startDate, let ts = DateConversion.fromISO(startDate) {
            predicates.append(NSPredicate(format: "pDate >= %@", DateConversion.toDate(ts) as NSDate))
        }
        if let endDate = endDate, let ts = DateConversion.fromISO(endDate) {
            predicates.append(NSPredicate(format: "pDate <= %@", DateConversion.toDate(ts) as NSDate))
        }

        if !predicates.isEmpty {
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }

        let transactions = try fetch(request)

        // Group by title (payee)
        var payeeMap: [String: (total: Int, categories: [Int: (name: String, path: String, count: Int)], uncategorized: Int)] = [:]

        for tx in transactions {
            let title = Self.stringValue(tx, "pTitle")
            var entry = payeeMap[title] ?? (total: 0, categories: [:], uncategorized: 0)
            entry.total += 1

            let lineItems = Self.relatedSet(tx, "lineItems")
            var hasCat = false
            for li in lineItems {
                guard let account = Self.relatedObject(li, "pAccount") else { continue }
                let acClass = Self.intValue(account, "pAccountClass")
                if acClass == AccountClass.income || acClass == AccountClass.expense {
                    let catId = Self.extractPK(from: account.objectID)
                    let existing = entry.categories[catId]
                    entry.categories[catId] = (
                        name: Self.stringValue(account, "pName"),
                        path: Self.stringValue(account, "pFullName"),
                        count: (existing?.count ?? 0) + 1
                    )
                    hasCat = true
                }
            }
            if !hasCat { entry.uncategorized += 1 }
            payeeMap[title] = entry
        }

        return payeeMap
            .filter { $0.value.total >= minTransactions }
            .map { (title, entry) in
                PayeeCategorySummaryDTO(
                    title: title,
                    totalTransactions: entry.total,
                    categories: entry.categories.map { (catId, info) in
                        PayeeCategoryEntryDTO(
                            categoryId: catId,
                            categoryName: info.name,
                            categoryPath: info.path,
                            count: info.count
                        )
                    }.sorted { $0.count > $1.count },
                    uncategorizedCount: entry.uncategorized
                )
            }
            .sorted { $0.totalTransactions > $1.totalTransactions }
    }

    // MARK: - Write Operations

    /// Recategorize a single transaction
    func recategorize(transactionId: Int, categoryId: Int) throws -> RecategorizationResultDTO? {
        var oldCategoryName: String?
        var newCategoryName: String = ""

        try performWrite { [self] ctx in
            guard let tx = try fetchByPK(entityName: "Transaction", pk: transactionId, in: ctx) else {
                throw ToolError.notFound("Transaction not found: \(transactionId)")
            }
            guard let categoryAccount = try fetchByPK(entityName: "Account", pk: categoryId, in: ctx) else {
                throw ToolError.notFound("Category not found: \(categoryId)")
            }

            newCategoryName = Self.stringValue(categoryAccount, "pName")
            let lineItems = Self.relatedSet(tx, "lineItems")

            // Find existing category line item, primary line item, and orphaned (null-account) line items
            var categoryLineItem: NSManagedObject?
            var primaryLineItem: NSManagedObject?
            var orphanedLineItems: [NSManagedObject] = []

            for li in lineItems {
                guard let account = Self.relatedObject(li, "pAccount") else {
                    // Line item with no account — orphaned slot
                    orphanedLineItems.append(li)
                    continue
                }
                let acClass = Self.intValue(account, "pAccountClass")
                if acClass == AccountClass.income || acClass == AccountClass.expense {
                    categoryLineItem = li
                    oldCategoryName = Self.stringValue(account, "pName")
                } else {
                    primaryLineItem = li
                }
            }

            if let existingCatLI = categoryLineItem {
                // Update existing category line item to new category
                existingCatLI.setValue(categoryAccount, forKey: "pAccount")
                // Clean up any orphaned line items
                for orphan in orphanedLineItems {
                    ctx.delete(orphan)
                }
            } else if let orphan = orphanedLineItems.first {
                // Reuse orphaned line item as the category slot
                orphan.setValue(categoryAccount, forKey: "pAccount")
                // Delete any additional orphans
                for extra in orphanedLineItems.dropFirst() {
                    ctx.delete(extra)
                }
            } else if let primaryLI = primaryLineItem {
                // Create new category line item with opposite amount
                let amount = Self.doubleValue(primaryLI, "pTransactionAmount")
                let catLI = Self.createObject(entityName: "LineItem", in: ctx)
                catLI.setValue((-amount) as NSNumber, forKey: "pTransactionAmount")
                catLI.setValue(Self.generateUUID(), forKey: "pUniqueID")
                catLI.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
                catLI.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
                catLI.setValue(false, forKey: "pCleared")
                Self.setNow(catLI, "pCreationTime")
                catLI.setValue(categoryAccount, forKey: "pAccount")
                catLI.setValue(tx, forKey: "pTransaction")
            }

            // Mark transaction as modified
            Self.setNow(tx, "pModificationDate")
        }

        return RecategorizationResultDTO(
            transactionId: transactionId,
            title: (try? get(transactionId: transactionId))?.title ?? "",
            oldCategoryName: oldCategoryName,
            newCategoryName: newCategoryName
        )
    }

    /// Bulk recategorize transactions by payee pattern
    func bulkRecategorize(
        payeePattern: String,
        categoryId: Int,
        dryRun: Bool = false,
        uncategorizedOnly: Bool = false
    ) throws -> BulkRecategorizeResultDTO {
        // Find matching transactions
        let request = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
        request.predicate = NSPredicate(format: "pTitle LIKE[cd] %@", "*\(payeePattern)*")
        request.sortDescriptors = [NSSortDescriptor(key: "pDate", ascending: false)]

        let transactions = try fetch(request)
        var results: [RecategorizationResultDTO] = []

        for tx in transactions {
            let txId = Self.extractPK(from: tx.objectID)
            let title = Self.stringValue(tx, "pTitle")

            // Check if already categorized
            let lineItems = Self.relatedSet(tx, "lineItems")
            var hasCat = false
            var oldCatName: String?
            for li in lineItems {
                guard let account = Self.relatedObject(li, "pAccount") else { continue }
                let acClass = Self.intValue(account, "pAccountClass")
                if acClass == AccountClass.income || acClass == AccountClass.expense {
                    hasCat = true
                    oldCatName = Self.stringValue(account, "pName")
                }
            }

            if uncategorizedOnly && hasCat { continue }

            if dryRun {
                let catName = try categoryRepo.get(categoryId: categoryId)?.name ?? "Unknown"
                results.append(RecategorizationResultDTO(
                    transactionId: txId,
                    title: title,
                    oldCategoryName: oldCatName,
                    newCategoryName: catName
                ))
            } else {
                if let result = try recategorize(transactionId: txId, categoryId: categoryId) {
                    results.append(result)
                }
            }
        }

        return BulkRecategorizeResultDTO(affected: results, count: results.count)
    }

    /// Helper to get transaction title by ID (for recategorization results)
    private func get(transactionId: Int) throws -> (title: String, Void)? {
        guard let tx = try fetchByPK(entityName: "Transaction", pk: transactionId) else { return nil }
        return (title: Self.stringValue(tx, "pTitle"), ())
    }
}
