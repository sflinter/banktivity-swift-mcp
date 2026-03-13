// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

/// Repository for transaction operations using Core Data
public final class TransactionRepository: BaseRepository, @unchecked Sendable {
    private let lineItemRepo: LineItemRepository
    private let syncBlobUpdater: SyncBlobUpdater?

    public init(container: NSPersistentContainer, lineItemRepo: LineItemRepository, syncBlobUpdater: SyncBlobUpdater? = nil) {
        self.lineItemRepo = lineItemRepo
        self.syncBlobUpdater = syncBlobUpdater
        super.init(container: container)
    }

    /// List transactions with optional filtering
    public func list(
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
    public func search(query: String, limit: Int = 50) throws -> [TransactionDTO] {
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
    public func get(transactionId: Int) throws -> TransactionDTO? {
        guard let object = try fetchByPK(entityName: "Transaction", pk: transactionId) else {
            return nil
        }
        return mapToDTO(object)
    }

    /// Get total transaction count
    public func count() throws -> Int {
        try count(entityName: "Transaction")
    }

    // MARK: - Write Operations

    /// Create a new transaction with line items
    public func create(
        date: String,
        title: String,
        note: String? = nil,
        lineItems: [(accountId: Int, amount: Double, memo: String?)]
    ) throws -> TransactionDTO {
        struct SyncInfo: Sendable {
            let txUUID: String
            let currencyUUID: String
            let transactionTypeBaseType: String
            let transactionTypeUUID: String
            let lineItems: [SyncBlobUpdater.SyncLineItem]
        }

        // Create the transaction and line items in a background context
        let syncInfo: SyncInfo = try performWriteReturning { [self] ctx in
            let tx = Self.createObject(entityName: "Transaction", in: ctx)
            let txUUID = Self.generateUUID()
            tx.setValue(title, forKey: "pTitle")
            tx.setValue(note, forKey: "pNote")
            tx.setValue(txUUID, forKey: "pUniqueID")
            tx.setValue(false, forKey: "pCleared")
            tx.setValue(false, forKey: "pVoid")
            tx.setValue(false, forKey: "pAdjustment")
            Self.setNow(tx, "pCreationTime")
            Self.setNow(tx, "pModificationDate")
            Self.setDate(tx, "pDate", isoString: date)

            // Set default transaction type (fetch the first available)
            let typeRequest = NSFetchRequest<NSManagedObject>(entityName: "TransactionType")
            typeRequest.fetchLimit = 1
            let txType = try ctx.fetch(typeRequest).first
            if let txType = txType {
                tx.setValue(txType, forKey: "pTransactionType")
            }

            let txTypeBaseType: String = {
                guard let txType = txType else { return "deposit" }
                let bt = Self.intValue(txType, "pBaseType")
                switch bt {
                case 0: return "withdrawal"
                case 1: return "deposit"
                default: return "deposit"
                }
            }()
            let txTypeUUID = txType.map { Self.stringValue($0, "pUniqueID") } ?? ""

            // Create line items
            var currencySet = false
            var currencyUUID = ""
            var syncLineItems: [SyncBlobUpdater.SyncLineItem] = []

            for liInput in lineItems {
                guard let account = try fetchByPK(entityName: "Account", pk: liInput.accountId, in: ctx) else {
                    throw ToolError.notFound("Account not found: \(liInput.accountId)")
                }

                let accountUUID = Self.stringValue(account, "pUniqueID")

                // Use the first account's currency for the transaction
                if !currencySet, let currency = Self.relatedObject(account, "currency") {
                    tx.setValue(currency, forKey: "pCurrency")
                    currencyUUID = Self.stringValue(currency, "pUniqueID")
                    currencySet = true
                }

                let li = Self.createObject(entityName: "LineItem", in: ctx)
                let liUUID = Self.generateUUID()
                li.setValue(liInput.amount as NSNumber, forKey: "pTransactionAmount")
                li.setValue(liInput.memo, forKey: "pMemo")
                li.setValue(liUUID, forKey: "pUniqueID")
                li.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
                li.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
                li.setValue(false, forKey: "pCleared")
                Self.setNow(li, "pCreationTime")
                li.setValue(account, forKey: "pAccount")
                li.setValue(tx, forKey: "pTransaction")

                syncLineItems.append(SyncBlobUpdater.SyncLineItem(
                    accountUUID: accountUUID, accountAmount: liInput.amount,
                    cleared: false, identifier: liUUID, memo: liInput.memo,
                    securityLineItem: nil, transactionAmount: liInput.amount
                ))
            }

            return SyncInfo(
                txUUID: txUUID, currencyUUID: currencyUUID,
                transactionTypeBaseType: txTypeBaseType,
                transactionTypeUUID: txTypeUUID,
                lineItems: syncLineItems
            )
        }

        // Create sync record (non-fatal)
        if let updater = syncBlobUpdater {
            updater.createTransactionSyncRecord(
                transactionUUID: syncInfo.txUUID, currencyUUID: syncInfo.currencyUUID,
                date: date, title: title, note: note, adjustment: false,
                lineItems: syncInfo.lineItems,
                transactionTypeBaseType: syncInfo.transactionTypeBaseType,
                transactionTypeUUID: syncInfo.transactionTypeUUID
            )
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
    public func update(transactionId: Int, title: String? = nil, note: String? = nil, date: String? = nil, cleared: Bool? = nil, transactionType: String? = nil) throws -> TransactionDTO? {
        nonisolated(unsafe) var dateChanged = false
        nonisolated(unsafe) var txUUID: String?
        nonisolated(unsafe) var newTxTypeBaseType: String?
        nonisolated(unsafe) var newTxTypeUUID: String?

        try performWrite { [self] ctx in
            guard let tx = try fetchByPK(entityName: "Transaction", pk: transactionId, in: ctx) else {
                throw ToolError.notFound("Transaction not found: \(transactionId)")
            }

            txUUID = Self.stringValue(tx, "pUniqueID")

            if let title = title { tx.setValue(title, forKey: "pTitle") }
            if let note = note { tx.setValue(note, forKey: "pNote") }
            if let date = date {
                Self.setDate(tx, "pDate", isoString: date)
                dateChanged = true
            }
            if let cleared = cleared { tx.setValue(cleared, forKey: "pCleared") }
            if let transactionType = transactionType {
                let baseType = Self.transactionTypeBaseTypeCode(transactionType)
                guard let baseType = baseType else {
                    throw ToolError.invalidInput("Unknown transaction type: \(transactionType). Valid types: deposit, withdrawal, buy, sell, move-shares-in, move-shares-out, short-sell, buy-to-cover")
                }
                let typeRequest = NSFetchRequest<NSManagedObject>(entityName: "TransactionType")
                typeRequest.predicate = NSPredicate(format: "pBaseType == %d", baseType)
                typeRequest.fetchLimit = 1
                guard let txType = try ctx.fetch(typeRequest).first else {
                    throw ToolError.notFound("TransactionType entity not found for base type \(baseType)")
                }
                tx.setValue(txType, forKey: "pTransactionType")
                newTxTypeBaseType = Self.transactionTypeBaseTypeName(baseType)
                newTxTypeUUID = Self.stringValue(txType, "pUniqueID")
            }
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

        // Patch sync blob (non-fatal)
        if let updater = syncBlobUpdater, let uuid = txUUID {
            updater.updateTransactionBlob(transactionUUID: uuid) { xml in
                var result = xml
                if let t = title { result = updater.patchTransactionTitle(xml: result, title: t) }
                if let n = note { result = updater.patchTransactionNote(xml: result, note: n) }
                if let d = date { result = updater.patchTransactionDate(xml: result, date: d + "T00:00:00+0000") }
                if let bt = newTxTypeBaseType, let tu = newTxTypeUUID {
                    result = updater.patchTransactionType(xml: result, baseType: bt, typeUUID: tu)
                }
                return result
            }
        }

        return try get(transactionId: transactionId)
    }

    /// Delete a transaction and its line items
    public func delete(transactionId: Int) throws -> Bool {
        // Get affected account IDs and transaction UUID before deletion
        var txUUID: String?
        if let tx = try fetchByPK(entityName: "Transaction", pk: transactionId) {
            txUUID = Self.stringValue(tx, "pUniqueID")
        }

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
            // Delete sync record (non-fatal)
            if let updater = syncBlobUpdater, let uuid = txUUID {
                updater.deleteSyncRecord(entityUUID: uuid)
            }
        }

        return deleted
    }

    // MARK: - DTO Mapping

    public func mapToDTO(_ object: NSManagedObject) -> TransactionDTO {
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

    // MARK: - Transaction Type Mapping

    static func transactionTypeBaseTypeCode(_ name: String) -> Int? {
        switch name.lowercased() {
        case "deposit": return 1
        case "withdrawal": return 2
        case "transfer": return 3
        case "check": return 4
        case "buy": return 100
        case "sell": return 101
        case "buy-to-open": return 102
        case "buy-to-close": return 103
        case "sell-to-open": return 104
        case "sell-to-close": return 105
        case "move-shares-in": return 210
        case "move-shares-out": return 211
        case "transfer-shares": return 212
        case "split-shares": return 250
        case "dividend": return 301
        default: return nil
        }
    }

    static func transactionTypeBaseTypeName(_ code: Int) -> String {
        switch code {
        case 1: return "deposit"
        case 2: return "withdrawal"
        case 3: return "transfer"
        case 4: return "check"
        case 100: return "buy"
        case 101: return "sell"
        case 102: return "buy-to-open"
        case 103: return "buy-to-close"
        case 104: return "sell-to-open"
        case 105: return "sell-to-close"
        case 210: return "move-shares-in"
        case 211: return "move-shares-out"
        case 212: return "transfer-shares"
        case 250: return "split-shares"
        case 300: return "investment-income"
        case 301: return "dividend"
        case 302: return "cap-gains-short"
        case 303: return "cap-gains-long"
        case 304: return "interest-income"
        case 310: return "return-of-capital"
        default: return "deposit"
        }
    }
}
