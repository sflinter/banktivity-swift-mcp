import CoreData
import Foundation

/// Repository for category operations using Core Data
final class CategoryRepository: BaseRepository, @unchecked Sendable {

    /// List categories with optional filtering
    func list(type: String? = nil, includeHidden: Bool = false, topLevelOnly: Bool = false) throws -> [CategoryDTO] {
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

        let results = try fetch(request)
        return results.map { mapToDTO($0) }
    }

    /// Get a single category by ID
    func get(categoryId: Int) throws -> CategoryDTO? {
        guard let object = try fetchByPK(entityName: "Account", pk: categoryId) else { return nil }
        let accountClass = Self.intValue(object, "pAccountClass")
        guard accountClass == AccountClass.income || accountClass == AccountClass.expense else {
            return nil
        }
        return mapToDTO(object)
    }

    /// Find a category by path (colon-separated, e.g., "Insurance:Life")
    func findByPath(_ path: String) throws -> CategoryDTO? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Account")
        request.predicate = NSPredicate(
            format: "(pAccountClass == %d OR pAccountClass == %d) AND pFullName ==[cd] %@",
            AccountClass.income, AccountClass.expense, path
        )
        request.fetchLimit = 1
        guard let object = try fetch(request).first else { return nil }
        return mapToDTO(object)
    }

    /// Find categories by name (case-insensitive)
    func findByName(_ name: String) throws -> [CategoryDTO] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Account")
        request.predicate = NSPredicate(
            format: "(pAccountClass == %d OR pAccountClass == %d) AND pName ==[cd] %@",
            AccountClass.income, AccountClass.expense, name
        )
        let results = try fetch(request)
        return results.map { mapToDTO($0) }
    }

    /// Build category tree
    func getTree(type: String? = nil) throws -> [CategoryTreeNodeDTO] {
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
    func resolveId(categoryId: Int? = nil, categoryName: String? = nil) throws -> Int? {
        if let id = categoryId { return id }
        if let name = categoryName {
            if let cat = try findByPath(name) { return cat.id }
            let byName = try findByName(name)
            if let first = byName.first { return first.id }
        }
        return nil
    }

    // MARK: - Write Operations

    /// Create a new category (income or expense)
    func create(
        name: String,
        type: String,
        parentId: Int? = nil,
        hidden: Bool = false,
        currencyCode: String? = nil
    ) throws -> CategoryDTO {
        try performWrite { [self] ctx in
            // Categories are stored as PrimaryAccount entities
            let cat = Self.createObject(entityName: "PrimaryAccount", in: ctx)
            let accountClass = type == "income" ? AccountClass.income : AccountClass.expense
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
                if let parent = try fetchByPK(entityName: "Account", pk: parentId, in: ctx) {
                    cat.setValue(parent, forKey: "pParentAccount")
                    let parentFullName = Self.stringValue(parent, "pFullName")
                    fullName = parentFullName.isEmpty ? name : "\(parentFullName):\(name)"
                }
            }
            cat.setValue(fullName, forKey: "pFullName")

            // Set currency
            if let code = currencyCode {
                let currRequest = NSFetchRequest<NSManagedObject>(entityName: "Currency")
                currRequest.predicate = NSPredicate(format: "pCode ==[cd] %@", code)
                currRequest.fetchLimit = 1
                if let currency = try ctx.fetch(currRequest).first {
                    cat.setValue(currency, forKey: "currency")
                }
            } else {
                // Use default currency (first available)
                let currRequest = NSFetchRequest<NSManagedObject>(entityName: "Currency")
                currRequest.fetchLimit = 1
                if let currency = try ctx.fetch(currRequest).first {
                    cat.setValue(currency, forKey: "currency")
                }
            }
        }

        // Re-fetch by name
        if let result = try findByPath(parentId != nil ? "" : name) ?? findByName(name).last {
            return result
        }
        throw ToolError.notFound("Failed to retrieve created category")
    }

    // MARK: - DTO Mapping

    func mapToDTO(_ object: NSManagedObject) -> CategoryDTO {
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
