// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import CryptoKit
import Foundation

public final class StatementRepository: BaseRepository, @unchecked Sendable {
    private let lineItemRepo: LineItemRepository
    private let syncBlobUpdater: SyncBlobUpdater?

    private struct StatementMembershipSyncPatch: Sendable {
        let transactionUUID: String
        let lineItemUUID: String
        let cleared: Bool
        let selectedForReplacement: Bool
    }

    public init(container: NSPersistentContainer, lineItemRepo: LineItemRepository, syncBlobUpdater: SyncBlobUpdater? = nil) {
        self.lineItemRepo = lineItemRepo
        self.syncBlobUpdater = syncBlobUpdater
        super.init(container: container)
    }

    // MARK: - Read Operations

    public func list(accountId: Int, includeInternal: Bool = false) throws -> [StatementSummaryDTO] {
        if includeInternal {
            return try listWithInternalDiagnostics(accountId: accountId).statements
        }
        return try performRead { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                throw ToolError.notFound("Account not found: \(accountId)")
            }

            let request = NSFetchRequest<NSManagedObject>(entityName: "Statement")
            request.predicate = NSPredicate(format: "pAccount == %@", account)
            request.sortDescriptors = [
                NSSortDescriptor(key: "pStartDate", ascending: true),
                NSSortDescriptor(key: "pEndDate", ascending: true),
                NSSortDescriptor(key: "pUniqueID", ascending: true),
            ]

            let statements = try ctx.fetch(request)
            return statements
                .filter { !Self.isInternalInvestmentStatement($0) }
                .map { self.mapToSummaryDTO($0) }
        }
    }

    /// Includes every addressable statement in the requested account and an
    /// explicit record for every line-item statement reference that cannot be
    /// represented there.  This must remain read-only: it is evidence for
    /// planning, never a backdoor to an internal mutation.
    public func listWithInternalDiagnostics(accountId: Int) throws -> StatementInternalListingDTO {
        try performRead { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                throw ToolError.notFound("Account not found: \(accountId)")
            }
            let request = NSFetchRequest<NSManagedObject>(entityName: "Statement")
            request.predicate = NSPredicate(format: "pAccount == %@", account)
            request.sortDescriptors = [
                NSSortDescriptor(key: "pStartDate", ascending: true),
                NSSortDescriptor(key: "pEndDate", ascending: true),
                NSSortDescriptor(key: "pUniqueID", ascending: true),
            ]
            let statements = try ctx.fetch(request)
            let listedIDs = Set(statements.map { Self.extractPK(from: $0.objectID) })
            let lineRequest = NSFetchRequest<NSManagedObject>(entityName: "LineItem")
            lineRequest.predicate = NSPredicate(format: "pAccount == %@ AND pStatement != nil", account)
            let unaddressable = try ctx.fetch(lineRequest).compactMap { line -> StatementUnaddressableReferenceDTO? in
                guard let referenced = Self.relatedObject(line, "pStatement") else { return nil }
                let referencedID = Self.extractPK(from: referenced.objectID)
                guard let referencedAccount = Self.relatedObject(referenced, "pAccount"),
                      referencedAccount.objectID == account.objectID,
                      listedIDs.contains(referencedID) else {
                    return StatementUnaddressableReferenceDTO(
                        lineItemId: Self.extractPK(from: line.objectID),
                        referencedStatementId: referencedID,
                        requestedAccountId: accountId,
                        reason: "referenced_statement_is_not_addressable_in_requested_account"
                    )
                }
                return nil
            }.sorted { lhs, rhs in
                lhs.lineItemId == rhs.lineItemId
                    ? lhs.referencedStatementId < rhs.referencedStatementId
                    : lhs.lineItemId < rhs.lineItemId
            }
            return StatementInternalListingDTO(
                statements: statements.map { self.mapToSummaryDTO($0) },
                unaddressableReferences: unaddressable
            )
        }
    }

    public func warningsForStatementReads(accountId: Int) throws -> [String] {
        try performRead { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                throw ToolError.notFound("Account not found: \(accountId)")
            }
            return Self.statementReadWarnings(accountClass: Self.intValue(account, "pAccountClass"))
        }
    }

    public func get(statementId: Int) throws -> StatementDTO? {
        try performRead { [self] ctx in
            guard let statement = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) else {
                return nil
            }
            return self.mapToDTO(statement)
        }
    }

    /// Inspect a statement reference from the line-item side.  This is the
    /// authoritative diagnostic for hidden investment rows: callers get an
    /// explicit unaddressable record instead of silently losing the reference
    /// in a visible-only statement list.
    public func inspectMembership(lineItemId: Int) throws -> StatementMembershipInspectionDTO {
        try performRead { [self] ctx in
            guard let lineItem = try fetchByPK(entityName: "LineItem", pk: lineItemId, in: ctx) else {
                throw ToolError.notFound("Line item not found: \(lineItemId)")
            }
            guard let statement = Self.relatedObject(lineItem, "pStatement") else {
                return StatementMembershipInspectionDTO(
                    lineItemId: lineItemId, referencedStatementId: nil, stableIdentity: nil,
                    accountId: nil, accountName: nil, startDate: nil, endDate: nil,
                    beginningBalance: nil, endingBalance: nil, membershipLineItemIds: [], membershipCount: 0,
                    visibilityClassification: "unaddressable_reference", positionAnchors: [:],
                    statementPreimage: nil, lineItemMemberships: [], preimageSha256: nil,
                    membershipPreimageSha256: nil,
                    capabilityFlags: ["addressable": false, "reconcilable": false, "restorable": false]
                )
            }
            guard let account = Self.relatedObject(statement, "pAccount") else {
                return StatementMembershipInspectionDTO(
                    lineItemId: lineItemId, referencedStatementId: Self.extractPK(from: statement.objectID),
                    stableIdentity: Self.stringValue(statement, "pUniqueID"), accountId: nil, accountName: nil,
                    startDate: nil, endDate: nil, beginningBalance: nil, endingBalance: nil,
                    membershipLineItemIds: [], membershipCount: 0,
                    visibilityClassification: "unaddressable_reference", positionAnchors: [:],
                    statementPreimage: nil, lineItemMemberships: [], preimageSha256: nil,
                    membershipPreimageSha256: nil,
                    capabilityFlags: ["addressable": false, "reconcilable": false, "restorable": false]
                )
            }
            let statementId = Self.extractPK(from: statement.objectID)
            let accountId = Self.extractPK(from: account.objectID)
            let statementDTO = self.mapToDTO(statement)
            let memberships = Self.relatedSet(statement, "pLineItems")
                .map {
                    StatementLineItemMembershipPreimageDTO(
                        lineItemId: Self.extractPK(from: $0.objectID), statementId: statementId,
                        cleared: $0.value(forKey: "pCleared") as? Bool ?? false
                    )
                }
                .sorted { $0.lineItemId < $1.lineItemId }
            let membershipIds = memberships.map(\.lineItemId)
            let request = NSFetchRequest<NSManagedObject>(entityName: "Statement")
            request.predicate = NSPredicate(format: "pAccount == %@", account)
            request.sortDescriptors = [
                NSSortDescriptor(key: "pStartDate", ascending: true),
                NSSortDescriptor(key: "pEndDate", ascending: true),
                NSSortDescriptor(key: "pUniqueID", ascending: true),
            ]
            let ordered = try ctx.fetch(request)
            guard let index = ordered.firstIndex(where: { Self.extractPK(from: $0.objectID) == statementId }) else {
                throw ToolError.invalidInput("Statement \(statementId) is not addressable in its account chain")
            }
            let before = index > 0 ? Self.extractPK(from: ordered[index - 1].objectID) : nil
            let after = index + 1 < ordered.count ? Self.extractPK(from: ordered[index + 1].objectID) : nil
            let classification = Self.statementRowClassification(statement)
            let hasRestorablePreimage = !Self.stringValue(statement, "pUniqueID").isEmpty
                && !statementDTO.startDate.isEmpty && !statementDTO.endDate.isEmpty
            return StatementMembershipInspectionDTO(
                lineItemId: lineItemId, referencedStatementId: statementId,
                stableIdentity: Self.stringValue(statement, "pUniqueID"), accountId: accountId,
                accountName: Self.stringValue(account, "pName"), startDate: statementDTO.startDate,
                endDate: statementDTO.endDate, beginningBalance: statementDTO.beginningBalance,
                endingBalance: statementDTO.endingBalance, membershipLineItemIds: membershipIds,
                membershipCount: membershipIds.count, visibilityClassification: classification.kind,
                positionAnchors: ["statement_index": index, "before_statement_id": before, "after_statement_id": after],
                statementPreimage: statementDTO, lineItemMemberships: memberships,
                preimageSha256: Self.statementPreimageHash(statementDTO),
                membershipPreimageSha256: Self.membershipPreimageHash(memberships),
                capabilityFlags: [
                    "addressable": true,
                    // This means reconcilable by a typed, inspected route; it
                    // does not grant the generic visible-row reconcile command
                    // authority over an internal row.
                    "reconcilable": classification.isVisibleNamedRow || classification.isInternalRowCandidate,
                    "restorable": classification.isInternalRowCandidate && hasRestorablePreimage,
                ]
            )
        }
    }

    public func visibleRowCorrectionPlan(statementId: Int? = nil, uiStart: Double, uiEnd: Double, uiMissing: Double, correctedStart: Double? = nil) -> VisibleRowCorrectionPlanDTO {
        VisibleRowCorrectionPlanDTO(
            statementId: statementId,
            uiStart: uiStart,
            uiEnd: uiEnd,
            uiMissing: uiMissing,
            correctedStart: correctedStart
        )
    }

    public func getAccountReconciliationStatus(accountId: Int) throws -> AccountReconciliationStatusDTO {
        try performRead { [self] ctx in
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                throw ToolError.notFound("Account not found: \(accountId)")
            }

            let request = NSFetchRequest<NSManagedObject>(entityName: "Statement")
            request.predicate = NSPredicate(format: "pAccount == %@", account)
            request.sortDescriptors = [
                NSSortDescriptor(key: "pEndDate", ascending: false),
                NSSortDescriptor(key: "pStartDate", ascending: false),
            ]

            let statements = try ctx.fetch(request)
            let lastStatement = statements.first
            let lastStatementId = lastStatement.map { Self.extractPK(from: $0.objectID) }
            let lastEndDate: String?
            if let lastStatement, let ts = Self.dateValue(lastStatement, "pEndDate") {
                lastEndDate = DateConversion.toISO(ts)
            } else {
                lastEndDate = nil
            }

            return AccountReconciliationStatusDTO(
                accountId: accountId,
                hasReconciledStatements: !statements.isEmpty,
                statementCount: statements.count,
                lastStatementId: lastStatementId,
                lastReconciledStatementEndDate: lastEndDate
            )
        }
    }

    /// Typed replacement for an inspected unnamed investment row.  It is
    /// intentionally the only automatic route which changes such a row; the
    /// generic --allow-internal flags are not part of this contract.
    public func replaceInternalRowWithVisibleStatement(
        sourceStatementId: Int, accountId: Int, startDate: String, endDate: String,
        beginningBalance: Double, endingBalance: Double, name: String,
        lineItemIds: [Int], preimageSha256: String, membershipPreimageSha256: String,
        replacementMembershipPreimageSha256: String,
        positionIndex: Int, beforeStatementId: Int?, afterStatementId: Int?
    ) throws -> StatementDTO {
        guard let updater = syncBlobUpdater else {
            throw ToolError.invalidInput("Internal statement replacement requires atomic sync metadata updates")
        }
        guard let startTimestamp = DateConversion.fromISO(startDate, timeZone: DateConversion.dateOnlyTimeZone),
              let endTimestamp = DateConversion.fromISO(endDate, timeZone: DateConversion.dateOnlyTimeZone),
              endTimestamp > startTimestamp else {
            throw ToolError.invalidInput("Replacement requires valid ordered statement dates")
        }
        guard beginningBalance.isFinite, endingBalance.isFinite else {
            throw ToolError.invalidInput("Replacement balances must be finite")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.invalidInput("Replacement statement name must be non-empty")
        }
        guard Set(lineItemIds).count == lineItemIds.count else {
            throw ToolError.invalidInput("Replacement line-item IDs must be unique")
        }
        guard Self.replacementMembershipPreimageHash(lineItemIds) == replacementMembershipPreimageSha256 else {
            throw ToolError.invalidInput("Replacement selection preimage hash does not match")
        }
        let selectedIds = Set(lineItemIds)
        let newId: Int = try performWriteReturning { [self] ctx in
            guard let source = try fetchByPK(entityName: "Statement", pk: sourceStatementId, in: ctx),
                  let account = Self.relatedObject(source, "pAccount") else {
                throw ToolError.notFound("Internal statement not found: \(sourceStatementId)")
            }
            guard Self.extractPK(from: account.objectID) == accountId,
                  Self.isInternalInvestmentStatement(source),
                  Self.statementPreimageHash(self.mapToDTO(source)) == preimageSha256 else {
                throw ToolError.invalidInput("Internal statement replacement preimage or account scope does not match")
            }
            try self.validateStatementPosition(source, account: account, expectedIndex: positionIndex, beforeStatementId: beforeStatementId, afterStatementId: afterStatementId, in: ctx)
            let sourceLines = Self.relatedSet(source, "pLineItems")
            let sourceIds = Set(sourceLines.map { Self.extractPK(from: $0.objectID) })
            guard Set(lineItemIds).isSubset(of: sourceIds), !lineItemIds.isEmpty else {
                throw ToolError.invalidInput("Replacement membership is not a non-empty subset of the inspected source row")
            }
            let actualMembership = sourceLines.map {
                StatementLineItemMembershipPreimageDTO(
                    lineItemId: Self.extractPK(from: $0.objectID), statementId: sourceStatementId,
                    cleared: $0.value(forKey: "pCleared") as? Bool ?? false
                )
            }.sorted { $0.lineItemId < $1.lineItemId }
            guard Self.membershipPreimageHash(actualMembership) == membershipPreimageSha256 else {
                throw ToolError.invalidInput("Internal statement replacement membership preimage does not match")
            }
            let sourceStatementUUID = Self.stringValue(source, "pUniqueID")
            guard !sourceStatementUUID.isEmpty else {
                throw ToolError.invalidInput("Internal statement replacement requires the stable source identity")
            }
            let syncPatches = try sourceLines.map { line -> StatementMembershipSyncPatch in
                guard let transaction = Self.relatedObject(line, "pTransaction") else {
                    throw ToolError.invalidInput("Internal statement replacement line item has no transaction")
                }
                let transactionUUID = Self.stringValue(transaction, "pUniqueID")
                let lineItemUUID = Self.stringValue(line, "pUniqueID")
                guard !transactionUUID.isEmpty, !lineItemUUID.isEmpty else {
                    throw ToolError.invalidInput("Internal statement replacement sync identity is missing")
                }
                return StatementMembershipSyncPatch(
                    transactionUUID: transactionUUID,
                    lineItemUUID: lineItemUUID,
                    cleared: line.value(forKey: "pCleared") as? Bool ?? false,
                    selectedForReplacement: selectedIds.contains(Self.extractPK(from: line.objectID))
                )
            }
            let replacement = Self.createObject(entityName: "Statement", in: ctx)
            replacement.setValue(account, forKey: "pAccount")
            Self.setDate(replacement, "pStartDate", isoString: startDate); Self.setDate(replacement, "pEndDate", isoString: endDate)
            replacement.setValue(beginningBalance as NSNumber, forKey: "pBeginningBalance"); replacement.setValue(endingBalance as NSNumber, forKey: "pEndingBalance")
            let replacementUUID = Self.generateUUID()
            replacement.setValue(name, forKey: "pName"); replacement.setValue(replacementUUID, forKey: "pUniqueID")
            Self.setNow(replacement, "pCreationTime"); Self.setNow(replacement, "pModificationDate")
            for line in sourceLines { line.setValue(nil, forKey: "pStatement") }
            for line in sourceLines where selectedIds.contains(Self.extractPK(from: line.objectID)) {
                line.setValue(replacement, forKey: "pStatement"); line.setValue(true, forKey: "pCleared")
            }
            _ = try updater.markStatementSyncRecordDeletedIfPresent(
                entityUUID: sourceStatementUUID,
                in: ctx
            )
            for patch in syncPatches {
                _ = try updater.patchTransactionBlobIfPresent(
                    transactionUUID: patch.transactionUUID,
                    in: ctx
                ) { xml in
                    let statementUUID = patch.selectedForReplacement ? replacementUUID : nil
                    return updater.patchCleared(
                        xml: updater.patchStatement(
                            xml: xml,
                            lineItemUUID: patch.lineItemUUID,
                            statementUUID: statementUUID
                        ),
                        lineItemUUID: patch.lineItemUUID,
                        cleared: patch.selectedForReplacement ? true : patch.cleared
                    )
                }
            }
            ctx.delete(source); try ctx.obtainPermanentIDs(for: [replacement])
            return Self.extractPK(from: replacement.objectID)
        }
        guard let result = try get(statementId: newId) else { throw RepositoryError.unexpectedNilResult }
        return result
    }

    public func restoreInternalRowFromPreimage(
        replacementStatementId: Int, accountId: Int, statementPreimage: StatementDTO,
        memberships: [StatementLineItemMembershipPreimageDTO], preimageSha256: String,
        membershipPreimageSha256: String, replacementLineItemIds: [Int],
        replacementMembershipPreimageSha256: String, replacementPreimageSha256: String,
        positionIndex: Int,
        beforeStatementId: Int?, afterStatementId: Int?
    ) throws -> StatementDTO {
        guard let updater = syncBlobUpdater else {
            throw ToolError.invalidInput("Internal statement restore requires atomic sync metadata updates")
        }
        guard Self.statementPreimageHash(statementPreimage) == preimageSha256 else {
            throw ToolError.invalidInput("Internal statement restore preimage hash does not match the supplied preimage")
        }
        guard !replacementLineItemIds.isEmpty,
              Set(replacementLineItemIds).count == replacementLineItemIds.count,
              Self.replacementMembershipPreimageHash(replacementLineItemIds) == replacementMembershipPreimageSha256 else {
            throw ToolError.invalidInput("Restore replacement selection preimage does not match")
        }
        guard let restoredUniqueId = statementPreimage.uniqueId, !restoredUniqueId.isEmpty else {
            throw ToolError.invalidInput("Internal statement restore requires the stable preimage identity")
        }
        let restoredId: Int = try performWriteReturning { [self] ctx in
            guard let replacement = try fetchByPK(entityName: "Statement", pk: replacementStatementId, in: ctx),
                  let account = Self.relatedObject(replacement, "pAccount") else { throw ToolError.notFound("Replacement statement not found: \(replacementStatementId)") }
            guard Self.extractPK(from: account.objectID) == accountId,
                  statementPreimage.accountId == accountId else { throw ToolError.invalidInput("Restore account scope does not match") }
            guard Self.statementPreimageHash(self.mapToDTO(replacement)) == replacementPreimageSha256 else {
                throw ToolError.invalidInput("Replacement statement preimage has drifted from the exact forward state")
            }
            let sortedMemberships = memberships.sorted { $0.lineItemId < $1.lineItemId }
            guard Self.membershipPreimageHash(sortedMemberships) == membershipPreimageSha256 else { throw ToolError.invalidInput("Restore membership preimage hash does not match") }
            // The replacement occupies the original position during inverse;
            // anchors are checked before mutating so failed restores roll back.
            try self.validateStatementPosition(replacement, account: account, expectedIndex: positionIndex, beforeStatementId: beforeStatementId, afterStatementId: afterStatementId, in: ctx)
            let expectedMembershipIDs = Set(sortedMemberships.map(\.lineItemId))
            let expectedReplacementMembershipIDs = Set(replacementLineItemIds)
            guard expectedReplacementMembershipIDs.isSubset(of: expectedMembershipIDs) else {
                throw ToolError.invalidInput("Restore replacement selection is outside the inspected inverse scope")
            }
            let replacementMembershipIDs = Set(Self.relatedSet(replacement, "pLineItems").map {
                Self.extractPK(from: $0.objectID)
            })
            guard replacementMembershipIDs == expectedReplacementMembershipIDs else {
                throw ToolError.invalidInput("Replacement statement membership has drifted from the inspected inverse scope")
            }
            let membershipLinesAndPatches = try sortedMemberships.map { membership -> (NSManagedObject, StatementMembershipSyncPatch) in
                guard let line = try fetchByPK(entityName: "LineItem", pk: membership.lineItemId, in: ctx),
                      let lineAccount = Self.relatedObject(line, "pAccount"),
                      Self.extractPK(from: lineAccount.objectID) == accountId,
                      let transaction = Self.relatedObject(line, "pTransaction") else {
                    throw ToolError.invalidInput("Restore line item is missing or outside account scope")
                }
                let currentStatement = Self.relatedObject(line, "pStatement")
                let currentCleared = line.value(forKey: "pCleared") as? Bool ?? false
                if expectedReplacementMembershipIDs.contains(membership.lineItemId) {
                    guard currentStatement?.objectID == replacement.objectID, currentCleared else {
                        throw ToolError.invalidInput("Selected replacement membership has drifted from the exact forward state")
                    }
                } else {
                    guard currentStatement == nil, currentCleared == membership.cleared else {
                        throw ToolError.invalidInput("Unselected replacement membership has drifted from the exact forward state")
                    }
                }
                let transactionUUID = Self.stringValue(transaction, "pUniqueID")
                let lineItemUUID = Self.stringValue(line, "pUniqueID")
                guard !transactionUUID.isEmpty, !lineItemUUID.isEmpty else {
                    throw ToolError.invalidInput("Restore line item sync identity is missing")
                }
                return (
                    line,
                    StatementMembershipSyncPatch(
                        transactionUUID: transactionUUID,
                        lineItemUUID: lineItemUUID,
                        cleared: membership.cleared,
                        selectedForReplacement: true
                    )
                )
            }
            let restored = Self.createObject(entityName: "Statement", in: ctx)
            restored.setValue(account, forKey: "pAccount"); Self.setDate(restored, "pStartDate", isoString: statementPreimage.startDate); Self.setDate(restored, "pEndDate", isoString: statementPreimage.endDate)
            restored.setValue(statementPreimage.beginningBalance as NSNumber, forKey: "pBeginningBalance"); restored.setValue(statementPreimage.endingBalance as NSNumber, forKey: "pEndingBalance")
            restored.setValue(statementPreimage.name, forKey: "pName"); restored.setValue(statementPreimage.note, forKey: "pNote")
            restored.setValue(restoredUniqueId, forKey: "pUniqueID")
            if let createdAt = statementPreimage.createdAt { Self.setDate(restored, "pCreationTime", isoString: createdAt) } else { Self.setNow(restored, "pCreationTime") }
            if let modifiedAt = statementPreimage.modifiedAt { Self.setDate(restored, "pModificationDate", isoString: modifiedAt) } else { Self.setNow(restored, "pModificationDate") }
            for (index, membership) in sortedMemberships.enumerated() {
                let line = membershipLinesAndPatches[index].0
                line.setValue(restored, forKey: "pStatement"); line.setValue(membership.cleared, forKey: "pCleared")
            }
            // Sync metadata is part of this reversible operation.  These
            // strict context-local updates execute before the context save, so
            // any failure rolls back the restored row, memberships, and
            // replacement deletion together.
            _ = try updater.restoreDeletedStatementSyncRecordIfPresent(
                entityUUID: restoredUniqueId,
                in: ctx
            )
            for (_, patch) in membershipLinesAndPatches {
                _ = try updater.patchTransactionBlobIfPresent(transactionUUID: patch.transactionUUID, in: ctx) { xml in
                    updater.patchCleared(
                        xml: updater.patchStatement(xml: xml, lineItemUUID: patch.lineItemUUID, statementUUID: restoredUniqueId),
                        lineItemUUID: patch.lineItemUUID,
                        cleared: patch.cleared
                    )
                }
            }
            ctx.delete(replacement); try ctx.obtainPermanentIDs(for: [restored]); return Self.extractPK(from: restored.objectID)
        }
        guard let result = try get(statementId: restoredId) else { throw RepositoryError.unexpectedNilResult }
        return result
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
        guard let startTs = DateConversion.fromISO(startDate, timeZone: DateConversion.dateOnlyTimeZone) else {
            throw ToolError.invalidInput("Invalid start date: \(startDate)")
        }
        guard let endTs = DateConversion.fromISO(endDate, timeZone: DateConversion.dateOnlyTimeZone) else {
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

    public func delete(statementId: Int, allowInternal: Bool = false) throws -> Bool {
        // Gather UUID and blob-patch info on the context's thread
        struct PreReadData: Sendable {
            let statementUUID: String
            let txLineItems: [String: [String]]
            let lineItemObjectIDs: [NSManagedObjectID]
        }
        let preRead: PreReadData? = try performRead { [self] ctx in
            guard let statement = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) else { return nil }
            if !allowInternal {
                try validateVisibleStatement(statement, statementId: statementId)
            }
            let statementUUID = Self.stringValue(statement, "pUniqueID")
            var txLineItems: [String: [String]] = [:]
            let lineItems = Self.relatedSet(statement, "pLineItems")
            for li in lineItems {
                let liUUID = Self.stringValue(li, "pUniqueID")
                if let tx = Self.relatedObject(li, "pTransaction") {
                    let txUUID = Self.stringValue(tx, "pUniqueID")
                    txLineItems[txUUID, default: []].append(liUUID)
                }
            }
            return PreReadData(statementUUID: statementUUID, txLineItems: txLineItems, lineItemObjectIDs: lineItems.map { $0.objectID })
        }
        guard let preRead = preRead else { return false }

        let statementUUID = preRead.statementUUID
        let txLineItems = preRead.txLineItems

        // Cascade: unreconcile all line items first
        let lineItemObjectIDs = preRead.lineItemObjectIDs
        if !lineItemObjectIDs.isEmpty {
            let ids = lineItemObjectIDs
            try performWrite { ctx in
                for objectID in ids {
                    let liInCtx = try ctx.existingObject(with: objectID)
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

        // Patch transaction sync blobs to reflect unreconciled line items (non-fatal)
        if let updater = syncBlobUpdater {
            for (txUUID, liUUIDs) in txLineItems {
                updater.updateTransactionBlob(transactionUUID: txUUID) { xml in
                    var result = xml
                    for liUUID in liUUIDs {
                        result = updater.patchStatement(xml: result, lineItemUUID: liUUID, statementUUID: nil)
                    }
                    return result
                }
            }
        }

        return true
    }

    public func reconcileLineItems(
        statementId: Int,
        lineItemIds: [Int],
        operatorConfirmedVisible: Bool = false
    ) throws -> StatementDTO {
        struct StatementInfo: Sendable {
            let accountId: Int
            let uuid: String
        }
        let info: StatementInfo = try performRead { [self] ctx in
            guard let statement = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) else {
                throw ToolError.notFound("Statement not found: \(statementId)")
            }
            try validateVisibleStatement(
                statement,
                statementId: statementId,
                operatorConfirmedVisible: operatorConfirmedVisible
            )
            guard let account = Self.relatedObject(statement, "pAccount") else {
                throw ToolError.invalidInput("Statement has no associated account")
            }
            return StatementInfo(
                accountId: Self.extractPK(from: account.objectID),
                uuid: Self.stringValue(statement, "pUniqueID")
            )
        }

        let statementAccountId = info.accountId
        let statementUUID = info.uuid

        struct ReconcileLineInfo: Sendable {
            let liUUID: String
            let liId: Int
        }

        // Collect line item UUID → transaction UUID mapping for blob patching
        let txLineItems: [String: [ReconcileLineInfo]] = try performWriteReturning { [self] ctx in
            guard let stmtInCtx = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) else {
                throw ToolError.notFound("Statement not found: \(statementId)")
            }

            var result: [String: [ReconcileLineInfo]] = [:]

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

                // Gather info for blob patching and mark transaction modified
                let liUUID = Self.stringValue(li, "pUniqueID")
                if let tx = Self.relatedObject(li, "pTransaction") {
                    let txUUID = Self.stringValue(tx, "pUniqueID")
                    if result[txUUID] == nil {
                        Self.setNow(tx, "pModificationDate")
                    }
                    result[txUUID, default: []].append(ReconcileLineInfo(liUUID: liUUID, liId: liId))
                }
            }

            if !lineItemIds.isEmpty {
                Self.setNow(stmtInCtx, "pModificationDate")
            }

            return result
        }

        // Patch sync blobs (non-fatal)
        if let updater = syncBlobUpdater {
            for (txUUID, items) in txLineItems {
                updater.updateTransactionBlob(transactionUUID: txUUID) { xml in
                    var result = xml
                    for item in items {
                        result = updater.patchCleared(xml: result, lineItemUUID: item.liUUID, cleared: true)
                        result = updater.patchStatement(xml: result, lineItemUUID: item.liUUID, statementUUID: statementUUID)
                    }
                    return result
                }
            }
        }

        guard let result = try get(statementId: statementId) else {
            throw ToolError.notFound("Statement not found after reconciliation: \(statementId)")
        }
        return result
    }

    public func previewReconcileLineItems(
        statementId: Int,
        lineItemIds: [Int],
        operatorConfirmedVisible: Bool = false
    ) throws -> StatementDTO {
        try performRead { [self] ctx in
            guard let statement = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) else {
                throw ToolError.notFound("Statement not found: \(statementId)")
            }
            try validateVisibleStatement(
                statement,
                statementId: statementId,
                operatorConfirmedVisible: operatorConfirmedVisible
            )
            guard let account = Self.relatedObject(statement, "pAccount") else {
                throw ToolError.invalidInput("Statement has no associated account")
            }
            let statementAccountId = Self.extractPK(from: account.objectID)
            var previewLineItems = Array(Self.relatedSet(statement, "pLineItems"))
            var seen = Set(previewLineItems.map { Self.extractPK(from: $0.objectID) })

            for liId in lineItemIds {
                guard let li = try fetchByPK(entityName: "LineItem", pk: liId, in: ctx) else {
                    throw ToolError.notFound("Line item not found: \(liId)")
                }
                guard let liAccount = Self.relatedObject(li, "pAccount") else {
                    throw ToolError.invalidInput("Line item \(liId) has no account")
                }
                let liAccountId = Self.extractPK(from: liAccount.objectID)
                guard liAccountId == statementAccountId else {
                    throw ToolError.invalidInput("Line item \(liId) belongs to account \(liAccountId), not statement's account \(statementAccountId)")
                }
                if let existingStatement = Self.relatedObject(li, "pStatement") {
                    let existingId = Self.extractPK(from: existingStatement.objectID)
                    guard existingId == statementId else {
                        throw ToolError.invalidInput("Line item \(liId) is already assigned to statement \(existingId)")
                    }
                }
                if !seen.contains(liId) {
                    previewLineItems.append(li)
                    seen.insert(liId)
                }
            }

            return self.mapToDTO(statement, lineItemsOverride: previewLineItems)
        }
    }

    public func unreconcileLineItems(
        statementId: Int,
        lineItemIds: [Int],
        operatorConfirmedVisible: Bool = false
    ) throws -> StatementDTO? {
        let exists: Bool = try performRead { [self] ctx in
            guard let statement = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) else {
                return false
            }
            try validateVisibleStatement(
                statement,
                statementId: statementId,
                operatorConfirmedVisible: operatorConfirmedVisible
            )
            return true
        }
        guard exists else {
            throw ToolError.notFound("Statement not found: \(statementId)")
        }

        let txLineItems: [String: [String]] = try performWriteReturning { [self] ctx in
            var result: [String: [String]] = [:]

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

                let liUUID = Self.stringValue(li, "pUniqueID")
                if let tx = Self.relatedObject(li, "pTransaction") {
                    let txUUID = Self.stringValue(tx, "pUniqueID")
                    if result[txUUID] == nil {
                        Self.setNow(tx, "pModificationDate")
                    }
                    result[txUUID, default: []].append(liUUID)
                }

                li.setValue(nil, forKey: "pStatement")
            }

            return result
        }

        // Patch sync blobs (non-fatal)
        if let updater = syncBlobUpdater {
            for (txUUID, liUUIDs) in txLineItems {
                updater.updateTransactionBlob(transactionUUID: txUUID) { xml in
                    var result = xml
                    for liUUID in liUUIDs {
                        result = updater.patchStatement(xml: result, lineItemUUID: liUUID, statementUUID: nil)
                    }
                    return result
                }
            }
        }

        return try get(statementId: statementId)
    }

    public func update(
        statementId: Int,
        endingBalance: Double,
        beginningBalance: Double? = nil,
        startDate: String? = nil,
        endDate: String? = nil,
        allowInternal: Bool = false,
        operatorConfirmedVisible: Bool = false
    ) throws -> StatementDTO {
        try performWrite { [self] ctx in
            guard let statement = try fetchByPK(entityName: "Statement", pk: statementId, in: ctx) else {
                throw ToolError.notFound("Statement not found: \(statementId)")
            }
            if !allowInternal {
                try validateVisibleStatement(
                    statement,
                    statementId: statementId,
                    operatorConfirmedVisible: operatorConfirmedVisible
                )
            }
            if let beginningBalance {
                statement.setValue(beginningBalance as NSNumber, forKey: "pBeginningBalance")
            }
            if startDate != nil || endDate != nil {
                guard let account = Self.relatedObject(statement, "pAccount") else {
                    throw ToolError.invalidInput("Statement \(statementId) is missing an account")
                }
                let accountId = Self.extractPK(from: account.objectID)
                let currentStart = Self.dateValue(statement, "pStartDate")
                let currentEnd = Self.dateValue(statement, "pEndDate")
                let startTs: Double
                if let startDate {
                    guard let parsed = DateConversion.fromISO(startDate, timeZone: DateConversion.dateOnlyTimeZone) else {
                        throw ToolError.invalidInput("Invalid start date: \(startDate)")
                    }
                    startTs = parsed
                } else if let currentStart {
                    startTs = currentStart
                } else {
                    throw ToolError.invalidInput("Statement \(statementId) is missing a start date")
                }
                let endTs: Double
                if let endDate {
                    guard let parsed = DateConversion.fromISO(endDate, timeZone: DateConversion.dateOnlyTimeZone) else {
                        throw ToolError.invalidInput("Invalid end date: \(endDate)")
                    }
                    endTs = parsed
                } else if let currentEnd {
                    endTs = currentEnd
                } else {
                    throw ToolError.invalidInput("Statement \(statementId) is missing an end date")
                }
                guard endTs > startTs else {
                    throw ToolError.invalidInput("End date must be after start date")
                }
                try validateNoOverlap(accountId: accountId, startTs: startTs, endTs: endTs, ignoringStatementId: statementId, in: ctx)
                if startDate != nil {
                    statement.setValue(DateConversion.toDate(startTs), forKey: "pStartDate")
                }
                if endDate != nil {
                    statement.setValue(DateConversion.toDate(endTs), forKey: "pEndDate")
                }
            }
            statement.setValue(endingBalance as NSNumber, forKey: "pEndingBalance")
            Self.setNow(statement, "pModificationDate")
        }

        guard let result = try get(statementId: statementId) else {
            throw ToolError.notFound("Statement not found after update: \(statementId)")
        }
        return result
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

    private func validateNoOverlap(
        accountId: Int,
        startTs: Double,
        endTs: Double,
        ignoringStatementId: Int? = nil,
        in ctx: NSManagedObjectContext
    ) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Statement")
        // Look up account using fetchByPK which handles entity inheritance
        guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
            return
        }

        // Overlapping: existing.start < newEnd AND existing.end > newStart
        var predicates: [NSPredicate] = [
            NSPredicate(format: "pAccount == %@", account),
            NSPredicate(format: "pStartDate < %@", DateConversion.toDate(endTs) as NSDate),
            NSPredicate(format: "pEndDate > %@", DateConversion.toDate(startTs) as NSDate),
        ]
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)

        let count: Int
        if let ignoringStatementId {
            count = try ctx.fetch(request).filter { Self.extractPK(from: $0.objectID) != ignoringStatementId }.count
        } else {
            count = try ctx.count(for: request)
        }
        guard count == 0 else {
            throw ToolError.invalidInput("Date range overlaps with an existing statement for this account")
        }
    }

    private func validateVisibleStatement(
        _ statement: NSManagedObject,
        statementId: Int,
        operatorConfirmedVisible: Bool = false
    ) throws {
        if Self.isInternalInvestmentStatement(statement) && !operatorConfirmedVisible {
            throw ToolError.invalidInput("Statement \(statementId) is an unnamed investment statement row. Write tools require read diagnostics and Banktivity UI confirmation before mutating this row; rerun with operator-confirmed-visible only after matching it to the intended visible statement.")
        }
    }

    // MARK: - DTO Mapping

    private func mapToDTO(_ object: NSManagedObject, lineItemsOverride: [NSManagedObject]? = nil) -> StatementDTO {
        let pk = Self.extractPK(from: object.objectID)

        let accountId: Int
        let accountName: String
        let accountClass: Int
        let accountType: String
        if let account = Self.relatedObject(object, "pAccount") {
            accountId = Self.extractPK(from: account.objectID)
            accountName = Self.stringValue(account, "pName")
            accountClass = Self.intValue(account, "pAccountClass")
            accountType = getAccountTypeName(accountClass)
        } else {
            accountId = 0
            accountName = "Unknown"
            accountClass = 0
            accountType = "Unknown"
        }

        let beginningBalance = Self.doubleValue(object, "pBeginningBalance")
        let endingBalance = Self.doubleValue(object, "pEndingBalance")

        // ``pLineItems`` is a Core Data set.  The statement preimage includes
        // the derived balance fields below, so calculate them from the same
        // canonical order used by the DTO.  Otherwise an inspect in a read
        // context can hash a different floating-point accumulation from the
        // subsequent write context even when the membership is unchanged.
        let lineItems = (lineItemsOverride ?? Array(Self.relatedSet(object, "pLineItems")))
            .sorted { lhs, rhs in
                let lhsTransaction = Self.relatedObject(lhs, "pTransaction")
                let rhsTransaction = Self.relatedObject(rhs, "pTransaction")
                let lhsDate = lhsTransaction.flatMap { Self.dateValue($0, "pDate") } ?? 0
                let rhsDate = rhsTransaction.flatMap { Self.dateValue($0, "pDate") } ?? 0
                if lhsDate != rhsDate { return lhsDate < rhsDate }

                let lhsTransactionId = lhsTransaction.map { Self.extractPK(from: $0.objectID) } ?? 0
                let rhsTransactionId = rhsTransaction.map { Self.extractPK(from: $0.objectID) } ?? 0
                if lhsTransactionId != rhsTransactionId { return lhsTransactionId < rhsTransactionId }

                return Self.extractPK(from: lhs.objectID) < Self.extractPK(from: rhs.objectID)
            }
        let reconciledBalance = lineItems.reduce(0.0) { sum, li in
            sum + Self.statementBalanceAmount(for: li)
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
        if let ts = Self.dateValue(object, "pModificationDate") {
            modifiedAt = DateConversion.toISODateTime(ts)
        } else {
            modifiedAt = nil
        }

        let lineItemDTOs = lineItems.map { lineItemRepo.mapToDTO($0) }
        let rowClassification = Self.statementRowClassification(object)

        return StatementDTO(
            id: pk,
            accountId: accountId,
            accountName: accountName,
            accountClass: accountClass,
            accountType: accountType,
            uniqueId: Self.stringValue(object, "pUniqueID"),
            rowKind: rowClassification.kind,
            isVisibleNamedRow: rowClassification.isVisibleNamedRow,
            isUnnamedInvestmentRow: rowClassification.isUnnamedInvestmentRow,
            isInternalRowCandidate: rowClassification.isInternalRowCandidate,
            operatorConfirmedVisibleRequired: rowClassification.operatorConfirmedVisibleRequired,
            name: Self.string(object, "pName"),
            note: Self.string(object, "pNote"),
            startDate: startDate,
            endDate: endDate,
            beginningBalance: beginningBalance,
            endingBalance: endingBalance,
            reconciledLineItemCount: lineItems.count,
            reconciledBalance: reconciledBalance,
            difference: difference,
            cashLineBalanced: abs(difference) < 0.005,
            isBalancedAdvisory: abs(difference) < 0.005,
            uiVerificationRequired: Self.isInvestmentAccountClass(accountClass),
            warnings: Self.statementReadWarnings(accountClass: accountClass),
            lineItems: lineItemDTOs,
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )
    }

    private func mapToSummaryDTO(_ object: NSManagedObject) -> StatementSummaryDTO {
        let pk = Self.extractPK(from: object.objectID)
        let accountClass: Int
        if let account = Self.relatedObject(object, "pAccount") {
            accountClass = Self.intValue(account, "pAccountClass")
        } else {
            accountClass = 0
        }
        let beginningBalance = Self.doubleValue(object, "pBeginningBalance")
        let endingBalance = Self.doubleValue(object, "pEndingBalance")

        let lineItems = Self.relatedSet(object, "pLineItems")
        let reconciledBalance = lineItems.reduce(0.0) { sum, li in
            sum + Self.statementBalanceAmount(for: li)
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

        let rowClassification = Self.statementRowClassification(object)

        return StatementSummaryDTO(
            id: pk,
            name: Self.string(object, "pName"),
            rowKind: rowClassification.kind,
            isVisibleNamedRow: rowClassification.isVisibleNamedRow,
            isUnnamedInvestmentRow: rowClassification.isUnnamedInvestmentRow,
            isInternalRowCandidate: rowClassification.isInternalRowCandidate,
            operatorConfirmedVisibleRequired: rowClassification.operatorConfirmedVisibleRequired,
            startDate: startDate,
            endDate: endDate,
            beginningBalance: beginningBalance,
            endingBalance: endingBalance,
            reconciledLineItemCount: lineItems.count,
            cashLineBalanced: abs(difference) < 0.005,
            isBalancedAdvisory: abs(difference) < 0.005,
            uiVerificationRequired: Self.isInvestmentAccountClass(accountClass),
            warnings: Self.statementReadWarnings(accountClass: accountClass)
        )
    }

    private static func statementBalanceAmount(for lineItem: NSManagedObject) -> Double {
        let cashAmount = doubleValue(lineItem, "pTransactionAmount") * doubleValue(lineItem, "pExchangeRate")
        if let securityLineItem = relatedObject(lineItem, "pSecurityLineItem") {
            if abs(cashAmount) >= 0.005 {
                return cashAmount
            }
            if abs(cashAmount) < 0.005,
               let transaction = relatedObject(lineItem, "pTransaction"),
               stringValue(transaction, "pNote").localizedCaseInsensitiveContains("SECURITY ADJUSTMENT") {
                return cashAmount
            }
            return cashAmount + doubleValue(securityLineItem, "pAmount")
        }
        return cashAmount
    }

    private static func isInvestmentAccountClass(_ accountClass: Int) -> Bool {
        (2000...2010).contains(accountClass)
    }

    private static func statementReadWarnings(accountClass: Int) -> [String] {
        guard isInvestmentAccountClass(accountClass) else { return [] }
        return [
            "Investment statement balance fields are advisory cash-line checks only; Banktivity Statements UI verification is required before marking the statement complete."
        ]
    }

    private struct StatementRowClassification {
        let kind: String
        let isVisibleNamedRow: Bool
        let isUnnamedInvestmentRow: Bool
        let isInternalRowCandidate: Bool
        let operatorConfirmedVisibleRequired: Bool
    }

    private static func statementRowClassification(_ statement: NSManagedObject) -> StatementRowClassification {
        let isInvestment = relatedObject(statement, "pAccount")
            .map { isInvestmentAccountClass(intValue($0, "pAccountClass")) } ?? false
        let hasDisplayName = !(string(statement, "pName")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
            || !(string(statement, "pNote")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty

        guard isInvestment else {
            return StatementRowClassification(
                kind: hasDisplayName ? "visible_named" : "visible_unnamed",
                isVisibleNamedRow: hasDisplayName,
                isUnnamedInvestmentRow: false,
                isInternalRowCandidate: false,
                operatorConfirmedVisibleRequired: false
            )
        }

        guard !hasDisplayName else {
            return StatementRowClassification(
                kind: "visible_named_investment",
                isVisibleNamedRow: true,
                isUnnamedInvestmentRow: false,
                isInternalRowCandidate: false,
                operatorConfirmedVisibleRequired: false
            )
        }

        return StatementRowClassification(
            kind: "unnamed_investment_requires_operator_confirmation",
            isVisibleNamedRow: false,
            isUnnamedInvestmentRow: true,
            isInternalRowCandidate: true,
            operatorConfirmedVisibleRequired: true
        )
    }

    private static func isInternalInvestmentStatement(_ statement: NSManagedObject) -> Bool {
        statementRowClassification(statement).isInternalRowCandidate
    }

    private static func statementPreimageHash(_ statement: StatementDTO) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(statement) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // Internal for focused repository tests which prove a rejected restore
    // leaves the replacement row intact.  It is not exposed through the CLI.
    static func membershipPreimageHash(_ memberships: [StatementLineItemMembershipPreimageDTO]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(memberships.sorted { $0.lineItemId < $1.lineItemId }) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Canonical hash used by both the forward operation and its inverse to
    /// bind the exact subset moved onto the visible replacement statement.
    static func replacementMembershipPreimageHash(_ lineItemIds: [Int]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(lineItemIds.sorted()) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256JSONString(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func validateStatementPosition(_ statement: NSManagedObject, account: NSManagedObject, expectedIndex: Int, beforeStatementId: Int?, afterStatementId: Int?, in ctx: NSManagedObjectContext) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Statement")
        request.predicate = NSPredicate(format: "pAccount == %@", account)
        request.sortDescriptors = [
            NSSortDescriptor(key: "pStartDate", ascending: true),
            NSSortDescriptor(key: "pEndDate", ascending: true),
            NSSortDescriptor(key: "pUniqueID", ascending: true),
        ]
        let rows = try ctx.fetch(request)
        guard let index = rows.firstIndex(where: { $0.objectID == statement.objectID }), index == expectedIndex else {
            throw ToolError.invalidInput("Statement position anchor index does not match")
        }
        let actualBefore = index > 0 ? Self.extractPK(from: rows[index - 1].objectID) : nil
        let actualAfter = index + 1 < rows.count ? Self.extractPK(from: rows[index + 1].objectID) : nil
        guard actualBefore == beforeStatementId && actualAfter == afterStatementId else {
            throw ToolError.invalidInput("Statement position anchors do not match")
        }
    }
}
