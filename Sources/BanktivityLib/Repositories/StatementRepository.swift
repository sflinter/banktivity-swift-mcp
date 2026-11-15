// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

public final class StatementRepository: BaseRepository, @unchecked Sendable {
    private let lineItemRepo: LineItemRepository
    private let syncBlobUpdater: SyncBlobUpdater?

    public init(container: NSPersistentContainer, lineItemRepo: LineItemRepository, syncBlobUpdater: SyncBlobUpdater? = nil) {
        self.lineItemRepo = lineItemRepo
        self.syncBlobUpdater = syncBlobUpdater
        super.init(container: container)
    }

    // MARK: - Read Operations

    public func list(accountId: Int) throws -> [StatementSummaryDTO] {
        try performRead { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                throw ToolError.notFound("Account not found: \(accountId)")
            }

            let request = NSFetchRequest<NSManagedObject>(entityName: "Statement")
            request.predicate = NSPredicate(format: "pAccount == %@", account)
            request.sortDescriptors = [NSSortDescriptor(key: "pStartDate", ascending: true)]

            let statements = try ctx.fetch(request)
            return statements.map { self.mapToSummaryDTO($0) }
        }
    }

    public func get(statementId: Int) throws -> StatementDTO? {
        try performRead { [self] ctx in
            guard let statement = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) else {
                return nil
            }
            return self.mapToDTO(statement, includeLineItems: true)
        }
    }

    /// Where an account's reconciliation stands: its statements, which of them
    /// don't add up, and how many line items are not on any statement.
    public func status(accountId: Int) throws -> AccountReconciliationStatusDTO {
        try performRead { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                throw ToolError.notFound("Account not found: \(accountId)")
            }
            let request = NSFetchRequest<NSManagedObject>(entityName: "Statement")
            request.predicate = NSPredicate(format: "pAccount == %@", account)
            request.sortDescriptors = [NSSortDescriptor(key: "pEndDate", ascending: true)]
            let statements = try ctx.fetch(request)
            let summaries = statements.map { self.mapToSummaryDTO($0) }
            let last = statements.last

            let unreconciled = NSFetchRequest<NSManagedObject>(entityName: "LineItem")
            unreconciled.predicate = NSPredicate(format: "pAccount == %@ AND pStatement == nil", account)
            let unreconciledCount = try ctx.count(for: unreconciled)
            var sinceLast = unreconciledCount
            if let lastEnd = last.flatMap({ Self.dateValue($0, "pEndDate") }) {
                unreconciled.predicate = NSPredicate(
                    format: "pAccount == %@ AND pStatement == nil AND pTransaction.pDate > %@",
                    account, DateConversion.toDate(lastEnd) as NSDate)
                sinceLast = try ctx.count(for: unreconciled)
            }

            return AccountReconciliationStatusDTO(
                accountId: accountId,
                accountName: Self.stringValue(account, "pName"),
                statementCount: statements.count,
                unbalancedStatementIds: summaries.filter { !$0.isBalanced }.map(\.id),
                lastStatementId: last.map { Self.extractPK(from: $0.objectID) },
                lastStatementEndDate: last.flatMap { Self.dateValue($0, "pEndDate") }.map { DateConversion.toISO($0) },
                lastStatementEndingBalance: last.map { Self.doubleValue($0, "pEndingBalance") },
                unreconciledLineItemCount: unreconciledCount,
                unreconciledSinceLastStatement: sinceLast
            )
        }
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
        guard let startTs = DateConversion.fromDateOnly(startDate) else {
            throw ToolError.invalidInput("Invalid start date: \(startDate)")
        }
        guard let endTs = DateConversion.fromDateOnly(endDate) else {
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
            Self.setNow(statement, "pModificationDate")

            try ctx.obtainPermanentIDs(for: [statement])
            return Self.extractPK(from: statement.objectID)
        }

        guard let result = try get(statementId: pk) else {
            throw RepositoryError.unexpectedNilResult
        }
        return result
    }

    /// Change a statement's beginning and/or ending balance in place.
    public func update(statementId: Int, beginningBalance: Double? = nil, endingBalance: Double? = nil) throws -> StatementDTO {
        guard beginningBalance != nil || endingBalance != nil else {
            throw ToolError.missingParameter("Give a beginning balance, an ending balance, or both")
        }
        try performWrite { [self] ctx in
            guard let statement = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) else {
                throw ToolError.notFound("Statement not found: \(statementId)")
            }
            if let beginningBalance {
                statement.setValue(beginningBalance as NSNumber, forKey: "pBeginningBalance")
            }
            if let endingBalance {
                statement.setValue(endingBalance as NSNumber, forKey: "pEndingBalance")
            }
            Self.setNow(statement, "pModificationDate")
        }

        guard let result = try get(statementId: statementId) else {
            throw ToolError.notFound("Statement not found after update: \(statementId)")
        }
        return result
    }

    public func delete(statementId: Int) throws -> Bool {
        // Gather UUID and blob-patch info on the context's thread
        struct PreReadData: Sendable {
            let statementUUID: String
            let lineItemObjectIDs: [NSManagedObjectID]
        }
        let preRead: PreReadData? = try performRead { [self] ctx in
            guard let statement = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) else { return nil }
            let lineItems = Self.relatedSet(statement, "pLineItems")
            return PreReadData(statementUUID: Self.stringValue(statement, "pUniqueID"), lineItemObjectIDs: lineItems.map { $0.objectID })
        }
        guard let preRead = preRead else { return false }

        let statementUUID = preRead.statementUUID

        // Cascade: unreconcile all line items first
        let lineItemObjectIDs = preRead.lineItemObjectIDs
        if !lineItemObjectIDs.isEmpty {
            let ids = lineItemObjectIDs
            try performWrite { ctx in
                for objectID in ids {
                    let liInCtx = try ctx.existingObject(with: objectID)
                    // Leaving a statement does not un-tick the line: cleared is kept.
                    liInCtx.setValue(nil, forKey: "pStatement")
                }
            }
        }

        try performWrite { [self] ctx in
            guard let obj = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) else { return }
            ctx.delete(obj)
        }

        // Mark statement sync record as deleted (non-fatal)
        if let updater = syncBlobUpdater, !statementUUID.isEmpty {
            updater.deleteSyncRecord(entityUUID: statementUUID)
        }

        return true
    }

    public func reconcileLineItems(statementId: Int, lineItemIds: [Int], allowOutOfRange: Bool = false) throws -> StatementDTO {
        struct StatementInfo: Sendable {
            let accountId: Int
            let startTs: Double?
            let endTs: Double?
        }
        let info: StatementInfo = try performRead { [self] ctx in
            guard let statement = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) else {
                throw ToolError.notFound("Statement not found: \(statementId)")
            }
            guard let account = Self.relatedObject(statement, "pAccount") else {
                throw ToolError.invalidInput("Statement has no associated account")
            }
            return StatementInfo(
                accountId: Self.extractPK(from: account.objectID),
                startTs: Self.dateValue(statement, "pStartDate"),
                endTs: Self.dateValue(statement, "pEndDate")
            )
        }

        let statementAccountId = info.accountId
        let startTs = info.startTs
        let endTs = info.endTs

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

                // Validate date range (allow 2-day buffer before start for credit card timing)
                if !allowOutOfRange, let startTs = startTs, let endTs = endTs,
                   let tx = Self.relatedObject(li, "pTransaction"),
                   let txDate = Self.dateValue(tx, "pDate") {
                    let bufferSeconds: Double = 2 * 86400
                    guard txDate >= (startTs - bufferSeconds) && txDate <= endTs else {
                        let dateStr = DateConversion.toISO(txDate)
                        throw ToolError.invalidInput("Line item \(liId) transaction date \(dateStr) is outside statement date range (pass allowOutOfRange / --allow-out-of-range for late-posted items)")
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
                // The save hook marks the line's transaction modified.
                Self.setNow(stmtInCtx, "pModificationDate")
            }
        }

        guard let result = try get(statementId: statementId) else {
            throw ToolError.notFound("Statement not found after reconciliation: \(statementId)")
        }
        return result
    }

    public func unreconcileLineItems(statementId: Int, lineItemIds: [Int]) throws -> StatementDTO? {
        let exists: Bool = try performRead { [self] ctx in
            try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) != nil
        }
        guard exists else {
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

                // Leaving a statement does not un-tick the line: cleared is kept.
                // The save hook marks the line's transaction modified.
                li.setValue(nil, forKey: "pStatement")
                if let statement = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) {
                    Self.setNow(statement, "pModificationDate")
                }
            }
        }

        return try get(statementId: statementId)
    }

    public func getUnreconciledLineItems(accountId: Int, startDate: String? = nil, endDate: String? = nil) throws -> [LineItemDTO] {
        try performRead { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
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
            if let end = endDate, let endTs = DateConversion.endOfDayExclusive(end) {
                predicates.append(NSPredicate(format: "pTransaction.pDate < %@", DateConversion.toDate(endTs) as NSDate))
            }

            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [
                NSSortDescriptor(key: "pTransaction.pDate", ascending: true),
            ]

            let lineItems = try ctx.fetch(request)
            return lineItems.map { self.lineItemRepo.mapToDTO($0) }
        }
    }

    // MARK: - Validation

    private func validateBeginningBalance(accountId: Int, startTs: Double, beginningBalance: Double, in ctx: NSManagedObjectContext) throws {
        guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
            return
        }

        let request = NSFetchRequest<NSManagedObject>(entityName: "Statement")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "pAccount == %@", account),
            NSPredicate(format: "pEndDate <= %@", DateConversion.toDate(startTs) as NSDate),
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

    private func mapToDTO(_ object: NSManagedObject, includeLineItems: Bool = false) -> StatementDTO {
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
        // Banktivity's statement total: the sum of each line's account amount.
        let reconciledBalance = lineItems.reduce(0.0) { $0 + Self.accountAmount($1) }
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
        if let ts = Self.dateValue(object, "pModificationDate") {
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
            modifiedAt: modifiedAt,
            lineItems: includeLineItems ? lineItems
                .sorted {
                    let l = Self.relatedObject($0, "pTransaction").flatMap { Self.dateValue($0, "pDate") } ?? 0
                    let r = Self.relatedObject($1, "pTransaction").flatMap { Self.dateValue($0, "pDate") } ?? 0
                    return l != r ? l < r : Self.extractPK(from: $0.objectID) < Self.extractPK(from: $1.objectID)
                }
                .map { lineItemRepo.mapToDTO($0) } : nil
        )
    }

    private func mapToSummaryDTO(_ object: NSManagedObject) -> StatementSummaryDTO {
        let pk = Self.extractPK(from: object.objectID)
        let beginningBalance = Self.doubleValue(object, "pBeginningBalance")
        let endingBalance = Self.doubleValue(object, "pEndingBalance")

        let lineItems = Self.relatedSet(object, "pLineItems")
        // Banktivity's statement total: the sum of each line's account amount.
        let reconciledBalance = lineItems.reduce(0.0) { $0 + Self.accountAmount($1) }
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
