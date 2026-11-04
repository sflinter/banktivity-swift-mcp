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
        try performRead { [self] ctx in
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
                guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                    throw ToolError.notFound("Account not found: \(accountId)")
                }
                predicates.append(NSPredicate(
                    format: "ANY lineItems.pAccount == %@", account
                ))
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

            let results = try ctx.fetch(request)
            return results.map { self.mapToDTO($0) }
        }
    }

    /// Search transactions by title or note (case-insensitive LIKE)
    public func search(query: String, limit: Int = 50) throws -> [TransactionDTO] {
        try performRead { [self] ctx in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
            let pattern = "*\(query)*"
            request.predicate = NSPredicate(
                format: "pTitle LIKE[cd] %@ OR pNote LIKE[cd] %@", pattern, pattern
            )
            request.sortDescriptors = [
                NSSortDescriptor(key: "pDate", ascending: false)
            ]
            request.fetchLimit = limit

            let results = try ctx.fetch(request)
            return results.map { self.mapToDTO($0) }
        }
    }

    /// Get a single transaction by primary key
    public func get(transactionId: Int) throws -> TransactionDTO? {
        try performRead { [self] ctx in
            guard let object = try fetchByPK(entityName: "Transaction", pk: transactionId, in: ctx) else {
                return nil
            }
            return self.mapToDTO(object)
        }
    }

    private func get(uniqueID: String) throws -> TransactionDTO? {
        try performRead { [self] ctx in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
            request.predicate = NSPredicate(format: "pUniqueID == %@", uniqueID)
            request.fetchLimit = 1
            return try ctx.fetch(request).first.map { self.mapToDTO($0) }
        }
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
            let transactionTypeBaseTypeCode: Int16
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

            // Was a switch over base types 0 and 1 that fell through to "deposit"
            // for everything else, so a withdrawal, a transfer or a check each
            // described itself in its own sync record as a deposit. 0 is not a base
            // type at all: Deposit is 1 and Withdrawal is 2.
            let txTypeBaseTypeCode: Int16 = {
                guard let txType = txType else { return 1 }
                // `Int16(_:)` traps out of range, and this value comes from the
                // store rather than from us. 0 is not a base type, so an
                // unreadable one resolves to no enum name and the sync record is
                // skipped -- which is the same answer, without the crash.
                return Int16(exactly: Self.intValue(txType, "pBaseType")) ?? 0
            }()
            let txTypeUUID = txType.map { Self.stringValue($0, "pUniqueID") } ?? ""

            // Create line items
            var currencySet = false
            var currencyUUID = ""
            var syncLineItems: [SyncBlobUpdater.SyncLineItem] = []

            var totalAmount = 0.0

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

                totalAmount += liInput.amount

                syncLineItems.append(SyncBlobUpdater.SyncLineItem(
                    accountUUID: accountUUID, accountAmount: liInput.amount,
                    cleared: false, identifier: liUUID, memo: liInput.memo,
                    securityLineItem: nil, transactionAmount: liInput.amount
                ))
            }

            // Create balancing offset line item if the explicit line items don't sum to zero.
            // Banktivity requires every transaction to have a balancing offset — without it,
            // the transaction won't affect the account's running cash balance.
            if abs(totalAmount) > 0.001 {
                let offsetLi = Self.createObject(entityName: "LineItem", in: ctx)
                let offsetUUID = Self.generateUUID()
                offsetLi.setValue(-totalAmount as NSNumber, forKey: "pTransactionAmount")
                offsetLi.setValue(offsetUUID, forKey: "pUniqueID")
                offsetLi.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
                offsetLi.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
                offsetLi.setValue(false, forKey: "pCleared")
                Self.setNow(offsetLi, "pCreationTime")
                // No pAccount — this is an uncategorized offset
                offsetLi.setValue(tx, forKey: "pTransaction")

                syncLineItems.append(SyncBlobUpdater.SyncLineItem(
                    accountUUID: "", accountAmount: -totalAmount,
                    cleared: false, identifier: offsetUUID, memo: nil,
                    securityLineItem: nil, transactionAmount: -totalAmount
                ))
            }

            return SyncInfo(
                txUUID: txUUID, currencyUUID: currencyUUID,
                transactionTypeBaseTypeCode: txTypeBaseTypeCode,
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
                transactionTypeBaseTypeCode: syncInfo.transactionTypeBaseTypeCode,
                transactionTypeUUID: syncInfo.transactionTypeUUID
            )
        }

        // Recalculate running balances for all affected accounts
        let affectedAccountIds = Set(lineItems.map(\.accountId))
        for accountId in affectedAccountIds {
            try lineItemRepo.recalculateRunningBalances(accountId: accountId)
        }

        guard let created = try get(uniqueID: syncInfo.txUUID) else {
            throw ToolError.notFound("Failed to retrieve created transaction")
        }
        return created
    }

    /// Update an existing transaction
    public func update(transactionId: Int, title: String? = nil, note: String? = nil, date: String? = nil, cleared: Bool? = nil, transactionType: String? = nil) throws -> TransactionDTO? {
        struct UpdateOutcome: Sendable {
            let txUUID: String
            let dateChanged: Bool
            let newTxTypeBaseTypeCode: Int16?
            let newTxTypeUUID: String?
        }

        let outcome: UpdateOutcome = try performWriteReturning { [self] ctx in
            guard let tx = try fetchByPK(entityName: "Transaction", pk: transactionId, in: ctx) else {
                throw ToolError.notFound("Transaction not found: \(transactionId)")
            }

            var dateChanged = false
            var newTxTypeBaseTypeCode: Int16?
            var newTxTypeUUID: String?

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
                    throw ToolError.invalidInput("Unknown transaction type: \(transactionType). Valid types: \(Self.transactionTypeNames)")
                }
                let typeRequest = NSFetchRequest<NSManagedObject>(entityName: "TransactionType")
                typeRequest.predicate = NSPredicate(format: "pBaseType == %d", baseType)
                typeRequest.fetchLimit = 1
                guard let txType = try ctx.fetch(typeRequest).first else {
                    throw ToolError.notFound("TransactionType entity not found for base type \(baseType)")
                }
                tx.setValue(txType, forKey: "pTransactionType")
                newTxTypeBaseTypeCode = Int16(baseType)
                newTxTypeUUID = Self.stringValue(txType, "pUniqueID")
            }
            Self.setNow(tx, "pModificationDate")

            return UpdateOutcome(
                txUUID: Self.stringValue(tx, "pUniqueID"),
                dateChanged: dateChanged,
                newTxTypeBaseTypeCode: newTxTypeBaseTypeCode,
                newTxTypeUUID: newTxTypeUUID
            )
        }

        // If date changed, recalculate running balances for affected accounts
        if outcome.dateChanged {
            if let lineItems = try? lineItemRepo.getForTransactionPK(transactionId) {
                let accountIds = Set(lineItems.map(\.accountId))
                for accountId in accountIds {
                    try lineItemRepo.recalculateRunningBalances(accountId: accountId)
                }
            }
        }

        // Patch sync blob (non-fatal)
        if let updater = syncBlobUpdater {
            updater.updateTransactionBlob(transactionUUID: outcome.txUUID) { xml in
                var result = xml
                if let t = title { result = updater.patchTransactionTitle(xml: result, title: t) }
                if let n = note { result = updater.patchTransactionNote(xml: result, note: n) }
                if let d = date { result = updater.patchTransactionDate(xml: result, date: d + "T00:00:00+0000") }
                if let bt = outcome.newTxTypeBaseTypeCode, let tu = outcome.newTxTypeUUID {
                    result = updater.patchTransactionType(xml: result, baseTypeCode: bt, typeUUID: tu)
                }
                return result
            }
        }

        return try get(transactionId: transactionId)
    }

    /// Delete a transaction and its line items
    public func delete(transactionId: Int) throws -> Bool {
        // Get UUID and affected account IDs on the context's thread before deletion
        let txUUID: String? = try performRead { [self] ctx in
            guard let tx = try fetchByPK(entityName: "Transaction", pk: transactionId, in: ctx) else { return nil }
            return Self.stringValue(tx, "pUniqueID")
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

    /// What `--transaction-type` accepts.
    ///
    /// The set used to live in a `switch` and was restated by hand in the caller's
    /// error message. The two had drifted in both directions: the message omitted
    /// `split-shares`, `transfer-shares`, `dividend` and `transfer`, all of which
    /// worked, while advertising `short-sell` and `buy-to-cover`, which were never
    /// accepted at all. A capability nobody can discover is indistinguishable from
    /// one that is missing -- a consumer read that list, concluded that retyping
    /// some fifty corporate-action rows was impossible without changing this
    /// package, and planned around a limitation that did not exist.
    ///
    /// Both the error message and the `--transaction-type` help are derived from
    /// this map now, so they cannot drift from it again.
    ///
    /// Note that this is the *input* vocabulary, and it is not the sync blob's
    /// enum -- see `SyncBlobUpdater.transactionBaseTypeNames`, which spells three
    /// of these differently and is the authority for what goes on the wire.
    public static let transactionTypeBaseTypes: [String: Int] = [
        "deposit": 1,
        "withdrawal": 2,
        "transfer": 3,
        "check": 4,
        "buy": 100,
        "sell": 101,
        "buy-to-open": 102,
        "buy-to-close": 103,
        "sell-to-open": 104,
        "sell-to-close": 105,
        "move-shares-in": 210,
        "move-shares-out": 211,
        "transfer-shares": 212,
        "split-shares": 250,
        "investment-income": 300,
        "dividend": 301,
        "cap-gains-short": 302,
        "cap-gains-long": 303,
        "interest-income": 304,
        // A spin-off apportions basis by releasing it through Return of Capital
        // and spending it on the child. Without this the second leg cannot be
        // written at all, so the apportionment cannot be recorded.
        "return-of-capital": 310,
    ]

    /// The accepted slugs, sorted, for help text and error messages. Derived rather
    /// than restated so it cannot drift from what is actually accepted.
    public static var transactionTypeNames: String {
        transactionTypeBaseTypes.keys.sorted().joined(separator: ", ")
    }

    static func transactionTypeBaseTypeCode(_ name: String) -> Int? {
        transactionTypeBaseTypes[name.lowercased()]
    }
}
