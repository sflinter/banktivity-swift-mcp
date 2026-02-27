import CoreData
import Foundation

/// Repository for transaction operations using Core Data
final class TransactionRepository: BaseRepository, @unchecked Sendable {
    private let lineItemRepo: LineItemRepository

    init(container: NSPersistentContainer, lineItemRepo: LineItemRepository) {
        self.lineItemRepo = lineItemRepo
        super.init(container: container)
    }

    /// List transactions with optional filtering
    func list(
        accountId: Int? = nil,
        startDate: String? = nil,
        endDate: String? = nil,
        limit: Int? = nil,
        offset: Int? = nil
    ) throws -> [TransactionDTO] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Transaction")

        var predicates: [NSPredicate] = []

        if let startDate = startDate, let ts = DateConversion.fromISO(startDate) {
            predicates.append(NSPredicate(
                format: "pDate >= %@", DateConversion.toDate(ts) as NSDate
            ))
        }

        if let endDate = endDate, let ts = DateConversion.fromISO(endDate) {
            predicates.append(NSPredicate(
                format: "pDate <= %@", DateConversion.toDate(ts) as NSDate
            ))
        }

        if let accountId = accountId {
            // Filter transactions that have at least one line item in this account
            if let account = try fetchByPK(entityName: "Account", pk: accountId) {
                predicates.append(NSPredicate(
                    format: "ANY lineItems.pAccount == %@", account
                ))
            }
        }

        if !predicates.isEmpty {
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }

        request.sortDescriptors = [
            NSSortDescriptor(key: "pDate", ascending: false)
        ]

        if let limit = limit {
            request.fetchLimit = limit
        }

        if let offset = offset {
            request.fetchOffset = offset
        }

        let results = try fetch(request)
        return results.map { mapToDTO($0) }
    }

    /// Search transactions by title or note (case-insensitive LIKE)
    func search(query: String, limit: Int = 50) throws -> [TransactionDTO] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
        let pattern = "*\(query)*"
        request.predicate = NSPredicate(
            format: "pTitle LIKE[cd] %@ OR pNote LIKE[cd] %@", pattern, pattern
        )
        request.sortDescriptors = [
            NSSortDescriptor(key: "pDate", ascending: false)
        ]
        request.fetchLimit = limit

        let results = try fetch(request)
        return results.map { mapToDTO($0) }
    }

    /// Get a single transaction by primary key
    func get(transactionId: Int) throws -> TransactionDTO? {
        guard let object = try fetchByPK(entityName: "Transaction", pk: transactionId) else {
            return nil
        }
        return mapToDTO(object)
    }

    /// Get total transaction count
    func count() throws -> Int {
        try count(entityName: "Transaction")
    }

    // MARK: - Write Operations

    /// Create a new transaction with line items
    func create(
        date: String,
        title: String,
        note: String? = nil,
        lineItems: [(accountId: Int, amount: Double, memo: String?)]
    ) throws -> TransactionDTO {
        // Create the transaction and line items in a background context
        try performWrite { [self] ctx in
            let tx = Self.createObject(entityName: "Transaction", in: ctx)
            tx.setValue(title, forKey: "pTitle")
            tx.setValue(note, forKey: "pNote")
            tx.setValue(Self.generateUUID(), forKey: "pUniqueID")
            tx.setValue(false, forKey: "pCleared")
            tx.setValue(false, forKey: "pVoid")
            tx.setValue(false, forKey: "pAdjustment")
            Self.setNow(tx, "pCreationTime")
            Self.setNow(tx, "pModificationDate")
            Self.setDate(tx, "pDate", isoString: date)

            // Set default currency (fetch the first available)
            let currRequest = NSFetchRequest<NSManagedObject>(entityName: "Currency")
            currRequest.fetchLimit = 1
            if let currency = try ctx.fetch(currRequest).first {
                tx.setValue(currency, forKey: "pCurrency")
            }

            // Set default transaction type (fetch the first available)
            let typeRequest = NSFetchRequest<NSManagedObject>(entityName: "TransactionType")
            typeRequest.fetchLimit = 1
            if let txType = try ctx.fetch(typeRequest).first {
                tx.setValue(txType, forKey: "pTransactionType")
            }

            // Create line items
            for liInput in lineItems {
                guard let account = try fetchByPK(entityName: "Account", pk: liInput.accountId, in: ctx) else {
                    throw ToolError.notFound("Account not found: \(liInput.accountId)")
                }

                let li = Self.createObject(entityName: "LineItem", in: ctx)
                li.setValue(liInput.amount as NSNumber, forKey: "pTransactionAmount")
                li.setValue(liInput.memo, forKey: "pMemo")
                li.setValue(Self.generateUUID(), forKey: "pUniqueID")
                li.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
                li.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
                li.setValue(false, forKey: "pCleared")
                Self.setNow(li, "pCreationTime")
                li.setValue(account, forKey: "pAccount")
                li.setValue(tx, forKey: "pTransaction")
            }
        }

        // Recalculate running balances for all affected accounts
        let affectedAccountIds = Set(lineItems.map(\.accountId))
        for accountId in affectedAccountIds {
            try lineItemRepo.recalculateRunningBalances(accountId: accountId)
        }

        // Fetch the created transaction by searching for the most recent one with this title
        let results = try search(query: title, limit: 1)
        guard let created = results.first else {
            throw ToolError.notFound("Failed to retrieve created transaction")
        }
        return created
    }

    /// Update an existing transaction
    func update(transactionId: Int, title: String? = nil, note: String? = nil, date: String? = nil, cleared: Bool? = nil) throws -> TransactionDTO? {
        var dateChanged = false

        try performWrite { [self] ctx in
            guard let tx = try fetchByPK(entityName: "Transaction", pk: transactionId, in: ctx) else {
                throw ToolError.notFound("Transaction not found: \(transactionId)")
            }

            if let title = title { tx.setValue(title, forKey: "pTitle") }
            if let note = note { tx.setValue(note, forKey: "pNote") }
            if let date = date {
                Self.setDate(tx, "pDate", isoString: date)
                dateChanged = true
            }
            if let cleared = cleared { tx.setValue(cleared, forKey: "pCleared") }
            Self.setNow(tx, "pModificationDate")
        }

        // If date changed, recalculate running balances for affected accounts
        if dateChanged {
            if let lineItems = try? lineItemRepo.getForTransactionPK(transactionId) {
                let accountIds = Set(lineItems.map(\.accountId))
                for accountId in accountIds {
                    try lineItemRepo.recalculateRunningBalances(accountId: accountId)
                }
            }
        }

        return try get(transactionId: transactionId)
    }

    /// Delete a transaction and its line items
    func delete(transactionId: Int) throws -> Bool {
        // Get affected account IDs before deletion
        let lineItems = try lineItemRepo.getForTransactionPK(transactionId)
        let affectedAccountIds = Set(lineItems.map(\.accountId))

        let deleted = try performWriteReturning { [self] ctx -> Bool in
            guard let tx = try fetchByPK(entityName: "Transaction", pk: transactionId, in: ctx) else {
                return false
            }

            // Delete all line items first (Core Data may not cascade automatically for unowned models)
            let txLineItems = Self.relatedSet(tx, "lineItems")
            for li in txLineItems {
                ctx.delete(li)
            }

            ctx.delete(tx)
            return true
        }

        // Recalculate running balances for affected accounts
        if deleted {
            for accountId in affectedAccountIds {
                try lineItemRepo.recalculateRunningBalances(accountId: accountId)
            }
        }

        return deleted
    }

    // MARK: - DTO Mapping

    func mapToDTO(_ object: NSManagedObject) -> TransactionDTO {
        let pk = Self.extractPK(from: object.objectID)

        var transactionTypeName: String? = nil
        if let txType = Self.relatedObject(object, "pTransactionType") {
            transactionTypeName = Self.string(txType, "pName")
        }

        let dateStr: String
        if let dateVal = Self.dateValue(object, "pDate") {
            dateStr = DateConversion.toISO(dateVal)
        } else {
            dateStr = "unknown"
        }

        let lineItems = lineItemRepo.getForTransaction(object)

        return TransactionDTO(
            id: pk,
            date: dateStr,
            title: Self.stringValue(object, "pTitle"),
            note: Self.string(object, "pNote"),
            cleared: Self.boolValue(object, "pCleared"),
            voided: Self.boolValue(object, "pVoid"),
            transactionType: transactionTypeName,
            lineItems: lineItems
        )
    }
}
