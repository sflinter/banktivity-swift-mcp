// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

/// Repository for line item operations using Core Data
final class LineItemRepository: BaseRepository, @unchecked Sendable {

    /// Get line items for a transaction (by managed object)
    func getForTransaction(_ transaction: NSManagedObject) -> [LineItemDTO] {
        let lineItems = Self.relatedSet(transaction, "lineItems")

        return lineItems
            .sorted { Self.extractPK(from: $0.objectID) < Self.extractPK(from: $1.objectID) }
            .map { mapToDTO($0) }
    }

    /// Get line items for a transaction by primary key
    func getForTransactionPK(_ transactionPK: Int) throws -> [LineItemDTO] {
        guard let txObject = try fetchByPK(entityName: "Transaction", pk: transactionPK) else {
            return []
        }
        return getForTransaction(txObject)
    }

    /// Get a single line item by primary key
    func get(lineItemId: Int) throws -> LineItemDTO? {
        guard let object = try fetchByPK(entityName: "LineItem", pk: lineItemId) else {
            return nil
        }
        return mapToDTO(object)
    }

    // MARK: - Write Operations

    /// Create a new line item for a transaction
    func create(transactionId: Int, accountId: Int, amount: Double, memo: String? = nil) throws -> Int {
        try performWriteReturning { [self] ctx in
            guard let tx = try fetchByPK(entityName: "Transaction", pk: transactionId, in: ctx) else {
                throw ToolError.notFound("Transaction not found: \(transactionId)")
            }
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                throw ToolError.notFound("Account not found: \(accountId)")
            }

            let li = Self.createObject(entityName: "LineItem", in: ctx)
            li.setValue(amount as NSNumber, forKey: "pTransactionAmount")
            li.setValue(memo, forKey: "pMemo")
            li.setValue(Self.generateUUID(), forKey: "pUniqueID")
            li.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
            li.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
            li.setValue(false, forKey: "pCleared")
            Self.setNow(li, "pCreationTime")
            li.setValue(account, forKey: "pAccount")
            li.setValue(tx, forKey: "pTransaction")

            return Self.extractPK(from: li.objectID)
        }
    }

    /// Update a line item's account, amount, or memo
    func update(lineItemId: Int, accountId: Int? = nil, amount: Double? = nil, memo: String? = nil) throws -> Set<Int> {
        try performWriteReturning { [self] ctx in
            guard let li = try fetchByPK(entityName: "LineItem", pk: lineItemId, in: ctx) else {
                throw ToolError.notFound("Line item not found: \(lineItemId)")
            }

            var affectedAccountIds = Set<Int>()

            // Track old account
            if let oldAccount = Self.relatedObject(li, "pAccount") {
                affectedAccountIds.insert(Self.extractPK(from: oldAccount.objectID))
            }

            if let accountId = accountId {
                guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                    throw ToolError.notFound("Account not found: \(accountId)")
                }
                li.setValue(account, forKey: "pAccount")
                affectedAccountIds.insert(accountId)
            }

            if let amount = amount {
                li.setValue(amount as NSNumber, forKey: "pTransactionAmount")
            }

            if let memo = memo {
                li.setValue(memo, forKey: "pMemo")
            }

            return affectedAccountIds
        }
    }

    /// Delete a line item
    func delete(lineItemId: Int) throws -> (accountId: Int, transactionId: Int)? {
        try performWriteReturning { [self] ctx in
            guard let li = try fetchByPK(entityName: "LineItem", pk: lineItemId, in: ctx) else {
                return nil
            }

            var accountId = 0
            var transactionId = 0

            if let account = Self.relatedObject(li, "pAccount") {
                accountId = Self.extractPK(from: account.objectID)
            }
            if let tx = Self.relatedObject(li, "pTransaction") {
                transactionId = Self.extractPK(from: tx.objectID)
            }

            ctx.delete(li)
            return (accountId: accountId, transactionId: transactionId)
        }
    }

    /// Recalculate running balances for all line items in an account
    func recalculateRunningBalances(accountId: Int) throws {
        try performWrite { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                return
            }

            // Fetch all line items for this account, ordered by transaction date then PK
            let request = NSFetchRequest<NSManagedObject>(entityName: "LineItem")
            request.predicate = NSPredicate(format: "pAccount == %@", account)
            request.sortDescriptors = [
                NSSortDescriptor(key: "pTransaction.pDate", ascending: true),
                NSSortDescriptor(key: "pIntraDaySortIndex", ascending: true),
            ]

            let lineItems = try ctx.fetch(request)
            var runningBalance = 0.0

            for li in lineItems {
                let amount = Self.doubleValue(li, "pTransactionAmount")
                runningBalance += amount
                li.setValue(runningBalance as NSNumber, forKey: "pRunningBalance")
            }
        }
    }

    // MARK: - DTO Mapping

    func mapToDTO(_ object: NSManagedObject) -> LineItemDTO {
        let pk = Self.extractPK(from: object.objectID)

        let accountId: Int
        let accountName: String
        if let account = Self.relatedObject(object, "pAccount") {
            accountId = Self.extractPK(from: account.objectID)
            accountName = Self.stringValue(account, "pName")
        } else {
            accountId = 0
            accountName = "Unknown"
        }

        return LineItemDTO(
            id: pk,
            accountId: accountId,
            accountName: accountName,
            amount: Self.doubleValue(object, "pTransactionAmount"),
            memo: Self.string(object, "pMemo"),
            runningBalance: Self.doubleValue(object, "pRunningBalance")
        )
    }
}
