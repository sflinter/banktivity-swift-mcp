import CoreData
import Foundation

/// Repository for tag operations using Core Data
final class TagRepository: BaseRepository, @unchecked Sendable {

    /// List all tags
    func list() throws -> [TagDTO] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Tag")
        request.sortDescriptors = [NSSortDescriptor(key: "pName", ascending: true)]

        let results = try fetch(request)
        return results.map { mapToDTO($0) }
    }

    /// Get a tag by primary key
    func get(tagId: Int) throws -> TagDTO? {
        guard let object = try fetchByPK(entityName: "Tag", pk: tagId) else { return nil }
        return mapToDTO(object)
    }

    /// Find a tag by name (case-insensitive)
    func findByName(_ name: String) throws -> TagDTO? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Tag")
        request.predicate = NSPredicate(format: "pName ==[cd] %@", name)
        request.fetchLimit = 1
        guard let object = try fetch(request).first else { return nil }
        return mapToDTO(object)
    }

    // MARK: - Write Operations

    /// Create a new tag (or return existing if name matches)
    func create(name: String) throws -> TagDTO {
        // Check if tag already exists
        if let existing = try findByName(name) {
            return existing
        }

        let pk = try performWriteReturning { ctx -> Int in
            let tag = Self.createObject(entityName: "Tag", in: ctx)
            tag.setValue(name, forKey: "pName")
            tag.setValue(name.uppercased().trimmingCharacters(in: .whitespaces), forKey: "pCanonicalName")
            tag.setValue(Self.generateUUID(), forKey: "pUniqueID")
            Self.setNow(tag, "pCreationTime")
            Self.setNow(tag, "pModificationDate")
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
    func delete(tagId: Int) throws -> Bool {
        try performWriteReturning { [self] ctx in
            guard let tag = try fetchByPK(entityName: "Tag", pk: tagId, in: ctx) else {
                return false
            }
            ctx.delete(tag)
            return true
        }
    }

    /// Add a tag to all line items of a transaction
    func tagTransaction(transactionId: Int, tagId: Int) throws -> Int {
        try performWriteReturning { [self] ctx in
            guard let tx = try fetchByPK(entityName: "Transaction", pk: transactionId, in: ctx) else {
                throw ToolError.notFound("Transaction not found: \(transactionId)")
            }
            guard let tag = try fetchByPK(entityName: "Tag", pk: tagId, in: ctx) else {
                throw ToolError.notFound("Tag not found: \(tagId)")
            }

            let lineItems = Self.relatedSet(tx, "lineItems")
            var count = 0
            for li in lineItems {
                let tags = li.mutableSetValue(forKey: "pTags")
                if !tags.contains(tag) {
                    tags.add(tag)
                    count += 1
                }
            }
            return count
        }
    }

    /// Remove a tag from all line items of a transaction
    func untagTransaction(transactionId: Int, tagId: Int) throws -> Int {
        try performWriteReturning { [self] ctx in
            guard let tx = try fetchByPK(entityName: "Transaction", pk: transactionId, in: ctx) else {
                throw ToolError.notFound("Transaction not found: \(transactionId)")
            }
            guard let tag = try fetchByPK(entityName: "Tag", pk: tagId, in: ctx) else {
                throw ToolError.notFound("Tag not found: \(tagId)")
            }

            let lineItems = Self.relatedSet(tx, "lineItems")
            var count = 0
            for li in lineItems {
                let tags = li.mutableSetValue(forKey: "pTags")
                if tags.contains(tag) {
                    tags.remove(tag)
                    count += 1
                }
            }
            return count
        }
    }

    /// Get transactions that have a specific tag
    func getTransactionsByTag(
        tagId: Int,
        accountId: Int? = nil,
        startDate: String? = nil,
        endDate: String? = nil,
        limit: Int = 50
    ) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
        var predicates: [NSPredicate] = []

        // Filter by tag through line items
        predicates.append(NSPredicate(format: "ANY lineItems.pTags.@pk == %d", tagId))

        if let startDate = startDate, let ts = DateConversion.fromISO(startDate) {
            predicates.append(NSPredicate(format: "pDate >= %@", DateConversion.toDate(ts) as NSDate))
        }
        if let endDate = endDate, let ts = DateConversion.fromISO(endDate) {
            predicates.append(NSPredicate(format: "pDate <= %@", DateConversion.toDate(ts) as NSDate))
        }

        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [NSSortDescriptor(key: "pDate", ascending: false)]
        request.fetchLimit = limit

        return try fetch(request)
    }

    // MARK: - DTO Mapping

    func mapToDTO(_ object: NSManagedObject) -> TagDTO {
        TagDTO(
            id: Self.extractPK(from: object.objectID),
            name: Self.stringValue(object, "pName")
        )
    }
}
