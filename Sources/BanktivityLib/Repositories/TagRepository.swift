// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

/// Repository for tag operations using Core Data
public final class TagRepository: BaseRepository, @unchecked Sendable {
    private let syncBlobUpdater: SyncBlobUpdater?

    public init(container: NSPersistentContainer, syncBlobUpdater: SyncBlobUpdater? = nil) {
        self.syncBlobUpdater = syncBlobUpdater
        super.init(container: container)
    }

    /// List all tags
    public func list() throws -> [TagDTO] {
        try performRead { [self] ctx in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Tag")
            request.sortDescriptors = [NSSortDescriptor(key: "pName", ascending: true)]

            let results = try ctx.fetch(request)
            return results.map { self.mapToDTO($0) }
        }
    }

    /// Get a tag by primary key
    public func get(tagId: Int) throws -> TagDTO? {
        try performRead { [self] ctx in
            guard let object = try fetchByPK(entityName: "Tag", pk: tagId, in: ctx) else { return nil }
            return self.mapToDTO(object)
        }
    }

    /// Find a tag by name (case-insensitive)
    public func findByName(_ name: String) throws -> TagDTO? {
        try performRead { [self] ctx in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Tag")
            request.predicate = NSPredicate(format: "pName ==[cd] %@", name)
            request.fetchLimit = 1
            guard let object = try ctx.fetch(request).first else { return nil }
            return self.mapToDTO(object)
        }
    }

    // MARK: - Write Operations

    /// Create a new tag (or return existing if name matches)
    public func create(name: String) throws -> TagDTO {
        // Check if tag already exists
        if let existing = try findByName(name) {
            return existing
        }

        _ = try performWriteReturning { ctx -> Int in
            let tag = Self.createObject(entityName: "Tag", in: ctx)
            tag.setValue(name, forKey: "pName")
            tag.setValue(name.uppercased().trimmingCharacters(in: .whitespaces), forKey: "pCanonicalName")
            tag.setValue(Self.generateUUID(), forKey: "pUniqueID")
            Self.setNow(tag, "pCreationTime")
            Self.setNow(tag, "pModificationDate")
            try ctx.obtainPermanentIDs(for: [tag])
            return Self.extractPK(from: tag.objectID)
        }

        // Re-fetch from view context to get the saved data
        // The PK from a background context may be temporary, so re-fetch by name
        guard let result = try findByName(name) else {
            throw ToolError.notFound("Failed to retrieve created tag")
        }
        return result
    }

    /// Delete a tag by ID
    public func delete(tagId: Int) throws -> Bool {
        try performWriteReturning { [self] ctx in
            guard let tag = try fetchByPK(entityName: "Tag", pk: tagId, in: ctx) else {
                return false
            }
            ctx.delete(tag)
            return true
        }
    }

    /// Add a tag to all line items of a transaction
    public func tagTransaction(transactionId: Int, tagId: Int) throws -> Int {
        let outcome = try applyTagOutcome(transactionId: transactionId, tagId: tagId, add: true)
        applyTagSyncBlob(outcome: outcome)
        return outcome.count
    }

    /// Remove a tag from all line items of a transaction
    public func untagTransaction(transactionId: Int, tagId: Int) throws -> Int {
        let outcome = try applyTagOutcome(transactionId: transactionId, tagId: tagId, add: false)
        applyTagSyncBlob(outcome: outcome)
        return outcome.count
    }

    private struct LineItemTagInfo: Sendable {
        let liUUID: String
        let tagUUIDs: [String]
    }

    private struct TagOutcome: Sendable {
        let count: Int
        let txUUID: String
        let lineItemTagInfo: [LineItemTagInfo]
        var didChange: Bool { count > 0 }
    }

    private func applyTagOutcome(transactionId: Int, tagId: Int, add: Bool) throws -> TagOutcome {
        try performWriteReturning { [self] ctx in
            guard let tx = try fetchByPK(entityName: "Transaction", pk: transactionId, in: ctx) else {
                throw ToolError.notFound("Transaction not found: \(transactionId)")
            }
            guard let tag = try fetchByPK(entityName: "Tag", pk: tagId, in: ctx) else {
                throw ToolError.notFound("Tag not found: \(tagId)")
            }

            let lineItems = Self.relatedSet(tx, "lineItems")
            var count = 0
            var info: [LineItemTagInfo] = []

            for li in lineItems {
                let tags = li.mutableSetValue(forKey: "pTags")
                if add, !tags.contains(tag) {
                    tags.add(tag)
                    count += 1
                } else if !add, tags.contains(tag) {
                    tags.remove(tag)
                    count += 1
                }
                // Collect current tag UUIDs for blob patching
                let liUUID = Self.stringValue(li, "pUniqueID")
                let currentTagUUIDs = (tags as? Set<NSManagedObject>)?.map { Self.stringValue($0, "pUniqueID") } ?? []
                info.append(LineItemTagInfo(liUUID: liUUID, tagUUIDs: currentTagUUIDs))
            }

            if count > 0 {
                Self.setNow(tx, "pModificationDate")
            }

            return TagOutcome(
                count: count,
                txUUID: Self.stringValue(tx, "pUniqueID"),
                lineItemTagInfo: info
            )
        }
    }

    private func applyTagSyncBlob(outcome: TagOutcome) {
        guard outcome.didChange, let updater = syncBlobUpdater else { return }
        updater.updateTransactionBlob(transactionUUID: outcome.txUUID) { xml in
            var result = xml
            for item in outcome.lineItemTagInfo {
                result = updater.patchTags(xml: result, lineItemUUID: item.liUUID, tagUUIDs: item.tagUUIDs)
            }
            return result
        }
    }

    /// Resolve a tag ID from either an ID or a name (auto-creates if name given)
    public func resolveTagId(id: Int? = nil, name: String? = nil, autoCreate: Bool = false) throws -> Int {
        if let id = id { return id }
        if let name = name {
            if autoCreate {
                return try create(name: name).id
            }
            guard let tag = try findByName(name) else {
                throw ToolError.notFound("Tag not found: \(name)")
            }
            return tag.id
        }
        throw ToolError.missingParameter("Either tag_id or tag_name is required")
    }

    /// Add or remove a tag from a transaction by action string
    public func applyTag(transactionId: Int, tagId: Int, action: String = "add") throws -> Int {
        if action == "remove" {
            return try untagTransaction(transactionId: transactionId, tagId: tagId)
        }
        return try tagTransaction(transactionId: transactionId, tagId: tagId)
    }

    /// Bulk add or remove a tag across multiple transactions
    public func bulkApplyTag(transactionIds: [Int], tagId: Int, action: String = "add") throws -> Int {
        var totalCount = 0
        for txId in transactionIds {
            totalCount += try applyTag(transactionId: txId, tagId: tagId, action: action)
        }
        return totalCount
    }

    /// Get transactions that have a specific tag as DTOs
    public func getTransactionDTOsByTag(
        tagId: Int? = nil,
        tagName: String? = nil,
        startDate: String? = nil,
        endDate: String? = nil,
        limit: Int = 50,
        transactionRepo: TransactionRepository
    ) throws -> [TransactionDTO] {
        let resolvedId = try resolveTagId(id: tagId, name: tagName)
        let txIds = try getTransactionsByTag(
            tagId: resolvedId,
            startDate: startDate,
            endDate: endDate,
            limit: limit
        )
        return txIds.compactMap { try? transactionRepo.get(transactionId: $0) }
    }

    /// Get primary keys of transactions that have a specific tag.
    /// Returns PKs rather than NSManagedObjects so callers don't need to handle
    /// Core Data thread confinement.
    public func getTransactionsByTag(
        tagId: Int,
        accountId: Int? = nil,
        startDate: String? = nil,
        endDate: String? = nil,
        limit: Int = 50
    ) throws -> [Int] {
        try performRead { ctx in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
            var predicates: [NSPredicate] = [
                NSPredicate(format: "ANY lineItems.pTags.@pk == %d", tagId)
            ]

            if let startDate = startDate, let ts = DateConversion.fromISO(startDate) {
                predicates.append(NSPredicate(format: "pDate >= %@", DateConversion.toDate(ts) as NSDate))
            }
            if let endDate = endDate, let ts = DateConversion.endOfDayExclusive(endDate) {
                predicates.append(NSPredicate(format: "pDate < %@", DateConversion.toDate(ts) as NSDate))
            }

            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [NSSortDescriptor(key: "pDate", ascending: false)]
            request.fetchLimit = limit

            let results = try ctx.fetch(request)
            return results.map { Self.extractPK(from: $0.objectID) }
        }
    }

    // MARK: - DTO Mapping

    public func mapToDTO(_ object: NSManagedObject) -> TagDTO {
        TagDTO(
            id: Self.extractPK(from: object.objectID),
            name: Self.stringValue(object, "pName")
        )
    }
}
