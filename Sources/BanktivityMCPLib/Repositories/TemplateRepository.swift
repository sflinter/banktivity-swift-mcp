import CoreData
import Foundation

/// Repository for transaction template operations using Core Data
final class TemplateRepository: BaseRepository, @unchecked Sendable {

    /// List all transaction templates
    func list() throws -> [TransactionTemplateDTO] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "TransactionTemplate")
        request.sortDescriptors = [NSSortDescriptor(key: "pTitle", ascending: true)]
        let results = try fetch(request)
        return results.map { mapToDTO($0) }
    }

    /// Get a template by PK
    func get(templateId: Int) throws -> TransactionTemplateDTO? {
        guard let object = try fetchByPK(entityName: "TransactionTemplate", pk: templateId) else {
            return nil
        }
        return mapToDTO(object)
    }

    // MARK: - Write Operations

    /// Create a new transaction template
    func create(
        title: String,
        amount: Double,
        note: String? = nil,
        currencyId: String? = nil,
        lineItems: [(accountId: String, amount: Double, memo: String?)]? = nil
    ) throws -> TransactionTemplateDTO {
        try performWrite { ctx in
            let template = Self.createObject(entityName: "TransactionTemplate", in: ctx)
            template.setValue(title, forKey: "pTitle")
            template.setValue(amount as NSNumber, forKey: "pAmount")
            template.setValue(note, forKey: "pNote")
            template.setValue(currencyId, forKey: "pCurrencyID")
            template.setValue(true, forKey: "pActive")
            template.setValue(true, forKey: "pFixedAmount")
            template.setValue(Self.generateUUID(), forKey: "pUniqueID")
            Self.setNow(template, "pCreationTime")
            Self.setNow(template, "pModificationDate")

            // Create line item templates
            if let lineItems = lineItems {
                for liInput in lineItems {
                    let li = Self.createObject(entityName: "LineItemTemplate", in: ctx)
                    li.setValue(liInput.accountId, forKey: "pAccountID")
                    li.setValue(liInput.amount as NSNumber, forKey: "pTransactionAmount")
                    li.setValue(liInput.memo, forKey: "pMemo")
                    li.setValue(true, forKey: "pFixedAmount")
                    Self.setNow(li, "pCreationTime")
                    li.setValue(template, forKey: "pTransactionTemplate")
                }
            }
        }

        // Re-fetch by title
        let all = try list()
        guard let result = all.last(where: { $0.title == title }) else {
            throw ToolError.notFound("Failed to retrieve created template")
        }
        return result
    }

    /// Update an existing template
    func update(templateId: Int, title: String? = nil, amount: Double? = nil, note: String? = nil, active: Bool? = nil) throws -> Bool {
        try performWriteReturning { [self] ctx in
            guard let template = try fetchByPK(entityName: "TransactionTemplate", pk: templateId, in: ctx) else {
                return false
            }

            if let title = title { template.setValue(title, forKey: "pTitle") }
            if let amount = amount { template.setValue(amount as NSNumber, forKey: "pAmount") }
            if let note = note { template.setValue(note, forKey: "pNote") }
            if let active = active { template.setValue(active, forKey: "pActive") }
            Self.setNow(template, "pModificationDate")
            return true
        }
    }

    /// Delete a template and its line item templates
    func delete(templateId: Int) throws -> Bool {
        try performWriteReturning { [self] ctx in
            guard let template = try fetchByPK(entityName: "TransactionTemplate", pk: templateId, in: ctx) else {
                return false
            }

            // Delete line item templates
            let lineItemTemplates = Self.relatedSet(template, "pLineItemTemplates")
            for li in lineItemTemplates {
                ctx.delete(li)
            }

            // Delete associated template selectors (import rules, scheduled transactions)
            let selectors = Self.relatedSet(template, "pTemplateSelectors")
            for sel in selectors {
                ctx.delete(sel)
            }

            ctx.delete(template)
            return true
        }
    }

    // MARK: - DTO Mapping

    func mapToDTO(_ object: NSManagedObject) -> TransactionTemplateDTO {
        let pk = Self.extractPK(from: object.objectID)

        // Get line item templates
        var lineItemDTOs: [LineItemTemplateDTO] = []
        let lineItems = Self.relatedSet(object, "pLineItemTemplates")
        for li in lineItems.sorted(by: { Self.extractPK(from: $0.objectID) < Self.extractPK(from: $1.objectID) }) {
            lineItemDTOs.append(LineItemTemplateDTO(
                id: Self.extractPK(from: li.objectID),
                accountId: Self.stringValue(li, "pAccountID"),
                accountName: nil,
                amount: Self.doubleValue(li, "pTransactionAmount"),
                memo: Self.string(li, "pMemo"),
                fixedAmount: Self.boolValue(li, "pFixedAmount")
            ))
        }

        var lastAppliedDate: String? = nil
        if let dateVal = Self.dateValue(object, "pLastAppliedDate") {
            lastAppliedDate = DateConversion.toISO(dateVal)
        }

        return TransactionTemplateDTO(
            id: pk,
            title: Self.stringValue(object, "pTitle"),
            amount: Self.doubleValue(object, "pAmount"),
            currencyId: Self.string(object, "pCurrencyID"),
            note: Self.string(object, "pNote"),
            active: Self.boolValue(object, "pActive"),
            fixedAmount: Self.boolValue(object, "pFixedAmount"),
            lastAppliedDate: lastAppliedDate,
            lineItems: lineItemDTOs
        )
    }
}
