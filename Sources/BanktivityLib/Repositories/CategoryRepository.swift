// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

/// Repository for category operations using Core Data
public final class CategoryRepository: BaseRepository, @unchecked Sendable {

    /// List categories with optional filtering
    public func list(type: String? = nil, includeHidden: Bool = false, topLevelOnly: Bool = false) throws -> [CategoryDTO] {
        try performRead { [self] ctx in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Account")

            var predicates: [NSPredicate] = []

            if let type = type {
                let accountClass = type == "income" ? AccountClass.income : AccountClass.expense
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
            guard let object = try fetchByPK(entityName: "Account", pk: categoryId, in: ctx) else { return nil }
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
            let request = NSFetchRequest<NSManagedObject>(entityName: "Account")
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
            let request = NSFetchRequest<NSManagedObject>(entityName: "Account")
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

    // MARK: - Write Operations

    /// Creating a category via the CLI/MCP is intentionally disabled — fails safely instead of
    /// corrupting the vault. See issue #26.
    ///
    /// The previous implementation created a `PrimaryAccount` entity (an account) rather than a
    /// `Category`, producing an account/category hybrid that shows up as an account **and freezes
    /// Banktivity's report engine**. A correct implementation must create a `Category` (Z_ENT=2)
    /// with proper income/expense-tree placement *and* emit a matching `Category` sync blob
    /// (`SyncBlobUpdater` only knows how to build `Transaction` records today) — otherwise the new
    /// category would never reach the user's other devices and would leave dangling references
    /// once transactions are filed into it. Until that exists, refuse rather than corrupt: create
    /// categories in Banktivity, then recategorise into them via the CLI (which works correctly).
    public func create(
        name: String,
        type: String,
        parentId: Int? = nil,
        hidden: Bool = false,
        currencyCode: String? = nil
    ) throws -> CategoryDTO {
        throw ToolError.invalidInput(
            "Creating categories via the CLI is not supported: it would create a malformed entity "
            + "that appears as an account and freezes Banktivity's reports. Create the category in "
            + "Banktivity, then recategorise into it. See issue #26.")
    }

    // MARK: - DTO Mapping

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
