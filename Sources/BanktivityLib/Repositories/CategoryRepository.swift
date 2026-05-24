// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

/// Repository for category operations using Core Data
public final class CategoryRepository: BaseRepository, @unchecked Sendable {

    /// List categories with optional filtering
    public func list(type: String? = nil, includeHidden: Bool = false, topLevelOnly: Bool = false) throws -> [CategoryDTO] {
        try performRead { [self] ctx in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Category")

            var predicates: [NSPredicate] = []

            if let type = type {
                let accountClass = try Self.categoryClass(for: type)
                predicates.append(NSPredicate(format: "pAccountClass == %d", accountClass))
            } else {
                // Only categories (income or expense)
                predicates.append(NSPredicate(
                    format: "pAccountClass == %d OR pAccountClass == %d",
                    AccountClass.income, AccountClass.expense
                ))
            }

            if !includeHidden {
                predicates.append(NSPredicate(format: "pHidden == NO OR pHidden == nil"))
            }

            if topLevelOnly {
                predicates.append(NSPredicate(format: "pParentAccount == nil"))
            }

            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [NSSortDescriptor(key: "pName", ascending: true)]

            let results = try ctx.fetch(request)
            return results.map { self.mapToDTO($0) }
        }
    }

    /// Get a single category by ID
    public func get(categoryId: Int) throws -> CategoryDTO? {
        try performRead { [self] ctx in
            guard let object = try fetchByPK(entityName: "Category", pk: categoryId, in: ctx) else { return nil }
            let accountClass = Self.intValue(object, "pAccountClass")
            guard accountClass == AccountClass.income || accountClass == AccountClass.expense else {
                return nil
            }
            return self.mapToDTO(object)
        }
    }

    /// Find a category by path (colon-separated, e.g., "Insurance:Life")
    public func findByPath(_ path: String) throws -> CategoryDTO? {
        try performRead { [self] ctx in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Category")
            request.predicate = NSPredicate(
                format: "(pAccountClass == %d OR pAccountClass == %d) AND pFullName ==[cd] %@",
                AccountClass.income, AccountClass.expense, path
            )
            request.fetchLimit = 1
            guard let object = try ctx.fetch(request).first else { return nil }
            return self.mapToDTO(object)
        }
    }

    /// Find categories by name (case-insensitive)
    public func findByName(_ name: String) throws -> [CategoryDTO] {
        try performRead { [self] ctx in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Category")
            request.predicate = NSPredicate(
                format: "(pAccountClass == %d OR pAccountClass == %d) AND pName ==[cd] %@",
                AccountClass.income, AccountClass.expense, name
            )
            let results = try ctx.fetch(request)
            return results.map { self.mapToDTO($0) }
        }
    }

    /// Build category tree
    public func getTree(type: String? = nil) throws -> [CategoryTreeNodeDTO] {
        let allCategories = try list(type: type, includeHidden: true)

        // Build tree from flat list
        var childrenMap: [Int: [CategoryDTO]] = [:]
        var topLevel: [CategoryDTO] = []

        for cat in allCategories {
            if let parentId = cat.parentId {
                childrenMap[parentId, default: []].append(cat)
            } else {
                topLevel.append(cat)
            }
        }

        func buildNode(_ cat: CategoryDTO) -> CategoryTreeNodeDTO {
            let children = (childrenMap[cat.id] ?? []).map { buildNode($0) }
            return CategoryTreeNodeDTO(
                id: cat.id, name: cat.name, fullName: cat.fullName,
                type: cat.type, accountClass: cat.accountClass,
                parentId: cat.parentId, hidden: cat.hidden,
                uniqueId: cat.uniqueId, currency: cat.currency,
                children: children
            )
        }

        return topLevel.map { buildNode($0) }
    }

    /// Resolve category ID from ID or name
    public func resolveId(categoryId: Int? = nil, categoryName: String? = nil) throws -> Int? {
        if let id = categoryId { return id }
        if let name = categoryName {
            if let cat = try findByPath(name) { return cat.id }
            let byName = try findByName(name)
            if let first = byName.first { return first.id }
        }
        return nil
    }

    /// Find income/expense rows that are not stored as Category entities.
    public func auditCategoryEntities() throws -> [CategoryEntityAuditDTO] {
        try performRead { ctx in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Account")
            request.predicate = NSPredicate(
                format: "pAccountClass == %d OR pAccountClass == %d",
                AccountClass.income, AccountClass.expense
            )
            request.sortDescriptors = [NSSortDescriptor(key: "pFullName", ascending: true)]

            return try ctx.fetch(request).compactMap { object in
                guard object.entity.name != "Category" else { return nil }
                let accountClass = Self.intValue(object, "pAccountClass")
                return CategoryEntityAuditDTO(
                    id: Self.extractPK(from: object.objectID),
                    name: Self.stringValue(object, "pName"),
                    fullName: Self.stringValue(object, "pFullName"),
                    type: accountClass == AccountClass.income ? "income" : "expense",
                    accountClass: accountClass,
                    actualEntity: object.entity.name ?? "Unknown",
                    expectedEntity: "Category"
                )
            }
        }
    }

    // MARK: - Write Operations

    /// Create a new category (income or expense)
    public func create(
        name: String,
        type: String,
        parentId: Int? = nil,
        hidden: Bool = false,
        currencyCode: String? = nil
    ) throws -> CategoryDTO {
        try performWriteReturning { [self] ctx in
            let accountClass = try Self.categoryClass(for: type)

            // Categories are concrete Category entities. Creating them as
            // PrimaryAccount corrupts Banktivity's category tree in the UI.
            let cat = Self.createObject(entityName: "Category", in: ctx)
            cat.setValue(accountClass, forKey: "pAccountClass")
            cat.setValue(name, forKey: "pName")
            cat.setValue(true, forKey: "pDebit")
            cat.setValue(hidden, forKey: "pHidden")
            cat.setValue(false, forKey: "pTaxable")
            cat.setValue(Self.generateUUID(), forKey: "pUniqueID")
            Self.setNow(cat, "pCreationTime")
            Self.setNow(cat, "pModificationDate")

            // Set parent and full name
            var fullName = name
            if let parentId = parentId {
                guard let parent = try fetchByPK(entityName: "Category", pk: parentId, in: ctx) else {
                    throw ToolError.invalidInput("Parent category not found: \(parentId)")
                }
                let parentClass = Self.intValue(parent, "pAccountClass")
                guard parentClass == AccountClass.income || parentClass == AccountClass.expense else {
                    throw ToolError.invalidInput("Parent must be an income or expense category: \(parentId)")
                }
                cat.setValue(parent, forKey: "pParentAccount")
                let parentFullName = Self.stringValue(parent, "pFullName")
                fullName = parentFullName.isEmpty ? name : "\(parentFullName):\(name)"
            }
            cat.setValue(fullName, forKey: "pFullName")

            if let code = currencyCode, cat.entity.relationshipsByName["currency"] != nil {
                let currRequest = NSFetchRequest<NSManagedObject>(entityName: "Currency")
                currRequest.predicate = NSPredicate(format: "pCode ==[cd] %@", code)
                currRequest.fetchLimit = 1
                if let currency = try ctx.fetch(currRequest).first {
                    cat.setValue(currency, forKey: "currency")
                }
            }

            try ctx.obtainPermanentIDs(for: [cat])
            return self.mapToDTO(cat)
        }
    }

    // MARK: - DTO Mapping

    private static func categoryClass(for type: String) throws -> Int {
        switch type {
        case "income": return AccountClass.income
        case "expense": return AccountClass.expense
        default: throw ToolError.invalidInput("type must be 'income' or 'expense'")
        }
    }

    public func mapToDTO(_ object: NSManagedObject) -> CategoryDTO {
        let accountClass = Self.intValue(object, "pAccountClass")
        let pk = Self.extractPK(from: object.objectID)

        var parentId: Int? = nil
        if let parent = Self.relatedObject(object, "pParentAccount") {
            parentId = Self.extractPK(from: parent.objectID)
        }

        return CategoryDTO(
            id: pk,
            name: Self.stringValue(object, "pName"),
            fullName: Self.stringValue(object, "pFullName"),
            type: accountClass == AccountClass.income ? "income" : "expense",
            accountClass: accountClass,
            parentId: parentId,
            hidden: Self.boolValue(object, "pHidden"),
            uniqueId: Self.stringValue(object, "pUniqueID"),
            currency: Self.currencyCode(object)
        )
    }
}
