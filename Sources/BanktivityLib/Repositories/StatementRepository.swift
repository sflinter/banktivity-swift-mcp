// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

public final class StatementRepository: BaseRepository, @unchecked Sendable {
    private let lineItemRepo: LineItemRepository

    public init(container: NSPersistentContainer, lineItemRepo: LineItemRepository) {
        self.lineItemRepo = lineItemRepo
        super.init(container: container)
    }

    // MARK: - Read Operations

    public func list(accountId: Int) throws -> [StatementSummaryDTO] {
        guard let account = try fetchByPK(entityName: "Account", pk: accountId) else {
            throw ToolError.notFound("Account not found: \(accountId)")
        }

        let request = NSFetchRequest<NSManagedObject>(entityName: "Statement")
        request.predicate = NSPredicate(format: "pAccount == %@", account)
        request.sortDescriptors = [NSSortDescriptor(key: "pStartDate", ascending: true)]

        let statements = try context.fetch(request)
        return statements.map { mapToSummaryDTO($0) }
    }

    public func get(statementId: Int) throws -> StatementDTO? {
        guard let statement = try fetchByPK(entityName: "Statement", pk: statementId) else {
            return nil
        }
        return mapToDTO(statement)
    }

    // MARK: - Write Operations

    public func create(
        accountId: Int,
        startDate: String,
        endDate: String,
        beginningBalance: Double,
        endingBalance: Double,
        name: String? = nil,
        note: String? = nil
    ) throws -> StatementDTO {
        guard let startTs = DateConversion.fromISO(startDate) else {
            throw ToolError.invalidInput("Invalid start date: \(startDate)")
        }
        guard let endTs = DateConversion.fromISO(endDate) else {
            throw ToolError.invalidInput("Invalid end date: \(endDate)")
        }
        guard endTs > startTs else {
            throw ToolError.invalidInput("End date must be after start date")
        }

        let pk: Int = try performWriteReturning { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                throw ToolError.notFound("Account not found: \(accountId)")
            }

            try validateNoOverlap(accountId: accountId, startTs: startTs, endTs: endTs, in: ctx)
            try validateBeginningBalance(accountId: accountId, startTs: startTs, beginningBalance: beginningBalance, in: ctx)

            let statement = Self.createObject(entityName: "Statement", in: ctx)
            statement.setValue(account, forKey: "pAccount")
            statement.setValue(DateConversion.toDate(startTs), forKey: "pStartDate")
            statement.setValue(DateConversion.toDate(endTs), forKey: "pEndDate")
            statement.setValue(beginningBalance as NSNumber, forKey: "pBeginningBalance")
            statement.setValue(endingBalance as NSNumber, forKey: "pEndingBalance")
            statement.setValue(name, forKey: "pName")
            statement.setValue(note, forKey: "pNote")
            statement.setValue(Self.generateUUID(), forKey: "pUniqueID")
            Self.setNow(statement, "pCreationTime")
            Self.setNow(statement, "pModificationTime")

            return Self.extractPK(from: statement.objectID)
        }

        guard let result = try get(statementId: pk) else {
            throw RepositoryError.unexpectedNilResult
        }
        return result
    }

    public func delete(statementId: Int) throws -> Bool {
        guard let statement = try fetchByPK(entityName: "Statement", pk: statementId) else {
            return false
        }

        // Cascade: unreconcile all line items first
        let lineItemObjectIDs = Self.relatedSet(statement, "pLineItems").map { $0.objectID }
        if !lineItemObjectIDs.isEmpty {
            let ids = lineItemObjectIDs
            try performWrite { ctx in
                for objectID in ids {
                    let liInCtx = try ctx.existingObject(with: objectID)
                    liInCtx.setValue(nil, forKey: "pStatement")
                    liInCtx.setValue(false, forKey: "pCleared")
                }
            }
        }

        try performWrite { [self] ctx in
            guard let obj = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) else { return }
            ctx.delete(obj)
        }
        return true
    }

    public func reconcileLineItems(statementId: Int, lineItemIds: [Int]) throws -> StatementDTO {
        guard let statement = try fetchByPK(entityName: "Statement", pk: statementId) else {
            throw ToolError.notFound("Statement not found: \(statementId)")
        }

        let statementAccountId: Int
        if let account = Self.relatedObject(statement, "pAccount") {
            statementAccountId = Self.extractPK(from: account.objectID)
        } else {
            throw ToolError.invalidInput("Statement has no associated account")
        }

        let startTs = Self.dateValue(statement, "pStartDate")
        let endTs = Self.dateValue(statement, "pEndDate")

        try performWrite { [self] ctx in
            guard let stmtInCtx = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) else {
                throw ToolError.notFound("Statement not found: \(statementId)")
            }

            for liId in lineItemIds {
                guard let li = try fetchByPK(entityName: "LineItem", pk: liId, in: ctx) else {
                    throw ToolError.notFound("Line item not found: \(liId)")
                }

                // Validate account ownership
                if let liAccount = Self.relatedObject(li, "pAccount") {
                    let liAccountId = Self.extractPK(from: liAccount.objectID)
                    guard liAccountId == statementAccountId else {
                        throw ToolError.invalidInput("Line item \(liId) belongs to account \(liAccountId), not statement's account \(statementAccountId)")
                    }
                } else {
                    throw ToolError.invalidInput("Line item \(liId) has no account")
                }

                // Validate date range
                if let startTs = startTs, let endTs = endTs,
                   let tx = Self.relatedObject(li, "pTransaction"),
                   let txDate = Self.dateValue(tx, "pDate") {
                    guard txDate >= startTs && txDate <= endTs else {
                        let dateStr = DateConversion.toISO(txDate)
                        throw ToolError.invalidInput("Line item \(liId) transaction date \(dateStr) is outside statement date range")
                    }
                }

                // Validate no double-assignment to a different statement
                if let existingStatement = Self.relatedObject(li, "pStatement") {
                    let existingId = Self.extractPK(from: existingStatement.objectID)
                    guard existingId == statementId else {
                        throw ToolError.invalidInput("Line item \(liId) is already assigned to statement \(existingId)")
                    }
                    continue // already assigned to this statement
                }

                li.setValue(stmtInCtx, forKey: "pStatement")
                li.setValue(true, forKey: "pCleared")
            }
        }

        guard let result = try get(statementId: statementId) else {
            throw ToolError.notFound("Statement not found after reconciliation: \(statementId)")
        }
        return result
    }

    public func unreconcileLineItems(statementId: Int, lineItemIds: [Int]) throws -> StatementDTO? {
        guard try fetchByPK(entityName: "Statement", pk: statementId) != nil else {
            throw ToolError.notFound("Statement not found: \(statementId)")
        }

        try performWrite { [self] ctx in
            for liId in lineItemIds {
                guard let li = try fetchByPK(entityName: "LineItem", pk: liId, in: ctx) else {
                    throw ToolError.notFound("Line item not found: \(liId)")
                }

                // Verify line item belongs to this statement
                if let existingStatement = Self.relatedObject(li, "pStatement") {
                    let existingId = Self.extractPK(from: existingStatement.objectID)
                    guard existingId == statementId else {
                        throw ToolError.invalidInput("Line item \(liId) belongs to statement \(existingId), not \(statementId)")
                    }
                } else {
                    continue // not assigned to any statement
                }

                li.setValue(nil, forKey: "pStatement")
                li.setValue(false, forKey: "pCleared")
            }
        }

        return try get(statementId: statementId)
    }

    public func getUnreconciledLineItems(accountId: Int, startDate: String? = nil, endDate: String? = nil) throws -> [LineItemDTO] {
        guard let account = try fetchByPK(entityName: "Account", pk: accountId) else {
            throw ToolError.notFound("Account not found: \(accountId)")
        }

        let request = NSFetchRequest<NSManagedObject>(entityName: "LineItem")
        var predicates: [NSPredicate] = [
            NSPredicate(format: "pAccount == %@", account),
            NSPredicate(format: "pStatement == nil"),
        ]

        if let start = startDate, let startTs = DateConversion.fromISO(start) {
            predicates.append(NSPredicate(format: "pTransaction.pDate >= %@", DateConversion.toDate(startTs) as NSDate))
        }
        if let end = endDate, let endTs = DateConversion.fromISO(end) {
            predicates.append(NSPredicate(format: "pTransaction.pDate <= %@", DateConversion.toDate(endTs) as NSDate))
        }

        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [
            NSSortDescriptor(key: "pTransaction.pDate", ascending: true),
        ]

        let lineItems = try context.fetch(request)
        return lineItems.map { lineItemRepo.mapToDTO($0) }
    }

    // MARK: - Validation

    private func validateBeginningBalance(accountId: Int, startTs: Double, beginningBalance: Double, in ctx: NSManagedObjectContext) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Statement")
        let accountURI = objectURI(
            store: container.persistentStoreCoordinator.persistentStores.first!,
            entityName: "PrimaryAccount", pk: accountId
        )
        guard let accountObjID = container.persistentStoreCoordinator.managedObjectID(forURIRepresentation: accountURI),
              let account = try? ctx.existingObject(with: accountObjID) else {
            // No account in write context — try Account entity
            let accountURI2 = objectURI(
                store: container.persistentStoreCoordinator.persistentStores.first!,
                entityName: "Account", pk: accountId
            )
            guard let accountObjID2 = container.persistentStoreCoordinator.managedObjectID(forURIRepresentation: accountURI2),
                  let account2 = try? ctx.existingObject(with: accountObjID2) else {
                return // first statement for account, no constraint
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "pAccount == %@", account2),
                NSPredicate(format: "pEndDate < %@", DateConversion.toDate(startTs) as NSDate),
            ])
            request.sortDescriptors = [NSSortDescriptor(key: "pEndDate", ascending: false)]
            request.fetchLimit = 1
            let previous = try ctx.fetch(request)
            guard let prev = previous.first else { return }
            let prevEndingBalance = Self.doubleValue(prev, "pEndingBalance")
            guard abs(prevEndingBalance - beginningBalance) < 0.005 else {
                throw ToolError.invalidInput("Beginning balance \(beginningBalance) doesn't match previous statement's ending balance \(prevEndingBalance)")
            }
            return
        }

        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "pAccount == %@", account),
            NSPredicate(format: "pEndDate < %@", DateConversion.toDate(startTs) as NSDate),
        ])
        request.sortDescriptors = [NSSortDescriptor(key: "pEndDate", ascending: false)]
        request.fetchLimit = 1
        let previous = try ctx.fetch(request)
        guard let prev = previous.first else { return }
        let prevEndingBalance = Self.doubleValue(prev, "pEndingBalance")
        guard abs(prevEndingBalance - beginningBalance) < 0.005 else {
            throw ToolError.invalidInput("Beginning balance \(beginningBalance) doesn't match previous statement's ending balance \(prevEndingBalance)")
        }
    }

    private func validateNoOverlap(accountId: Int, startTs: Double, endTs: Double, in ctx: NSManagedObjectContext) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Statement")
        // Look up account using fetchByPK which handles entity inheritance
        guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
            return
        }

        // Overlapping: existing.start < newEnd AND existing.end > newStart
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "pAccount == %@", account),
            NSPredicate(format: "pStartDate < %@", DateConversion.toDate(endTs) as NSDate),
            NSPredicate(format: "pEndDate > %@", DateConversion.toDate(startTs) as NSDate),
        ])

        let count = try ctx.count(for: request)
        guard count == 0 else {
            throw ToolError.invalidInput("Date range overlaps with an existing statement for this account")
        }
    }

    // MARK: - DTO Mapping

    private func mapToDTO(_ object: NSManagedObject) -> StatementDTO {
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

        let beginningBalance = Self.doubleValue(object, "pBeginningBalance")
        let endingBalance = Self.doubleValue(object, "pEndingBalance")

        let lineItems = Self.relatedSet(object, "pLineItems")
        let reconciledBalance = lineItems.reduce(0.0) { sum, li in
            sum + Self.doubleValue(li, "pTransactionAmount")
        }
        let expectedChange = endingBalance - beginningBalance
        let difference = expectedChange - reconciledBalance

        let startDate: String
        if let ts = Self.dateValue(object, "pStartDate") {
            startDate = DateConversion.toISO(ts)
        } else {
            startDate = ""
        }

        let endDate: String
        if let ts = Self.dateValue(object, "pEndDate") {
            endDate = DateConversion.toISO(ts)
        } else {
            endDate = ""
        }

        let createdAt: String?
        if let ts = Self.dateValue(object, "pCreationTime") {
            createdAt = DateConversion.toISODateTime(ts)
        } else {
            createdAt = nil
        }

        let modifiedAt: String?
        if let ts = Self.dateValue(object, "pModificationTime") {
            modifiedAt = DateConversion.toISODateTime(ts)
        } else {
            modifiedAt = nil
        }

        return StatementDTO(
            id: pk,
            accountId: accountId,
            accountName: accountName,
            name: Self.string(object, "pName"),
            note: Self.string(object, "pNote"),
            startDate: startDate,
            endDate: endDate,
            beginningBalance: beginningBalance,
            endingBalance: endingBalance,
            reconciledLineItemCount: lineItems.count,
            reconciledBalance: reconciledBalance,
            difference: difference,
            isBalanced: abs(difference) < 0.005,
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )
    }

    private func mapToSummaryDTO(_ object: NSManagedObject) -> StatementSummaryDTO {
        let pk = Self.extractPK(from: object.objectID)
        let beginningBalance = Self.doubleValue(object, "pBeginningBalance")
        let endingBalance = Self.doubleValue(object, "pEndingBalance")

        let lineItems = Self.relatedSet(object, "pLineItems")
        let reconciledBalance = lineItems.reduce(0.0) { sum, li in
            sum + Self.doubleValue(li, "pTransactionAmount")
        }
        let expectedChange = endingBalance - beginningBalance
        let difference = expectedChange - reconciledBalance

        let startDate: String
        if let ts = Self.dateValue(object, "pStartDate") {
            startDate = DateConversion.toISO(ts)
        } else {
            startDate = ""
        }

        let endDate: String
        if let ts = Self.dateValue(object, "pEndDate") {
            endDate = DateConversion.toISO(ts)
        } else {
            endDate = ""
        }

        return StatementSummaryDTO(
            id: pk,
            name: Self.string(object, "pName"),
            startDate: startDate,
            endDate: endDate,
            beginningBalance: beginningBalance,
            endingBalance: endingBalance,
            reconciledLineItemCount: lineItems.count,
            isBalanced: abs(difference) < 0.005
        )
    }
}
