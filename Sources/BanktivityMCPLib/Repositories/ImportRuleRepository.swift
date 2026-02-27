// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

/// Repository for import rule operations using Core Data
final class ImportRuleRepository: BaseRepository, @unchecked Sendable {

    /// List all import rules
    func list() throws -> [ImportRuleDTO] {
        // Import rules are TemplateSelector entities with a specific Z_ENT
        let request = NSFetchRequest<NSManagedObject>(entityName: "ImportSourceTemplateSelector")
        request.sortDescriptors = [NSSortDescriptor(key: "pDetailsExpression", ascending: true)]
        let results = try fetch(request)
        return try results.compactMap { try mapToDTO($0) }
    }

    /// Get a rule by PK
    func get(ruleId: Int) throws -> ImportRuleDTO? {
        guard let object = try fetchByPK(entityName: "ImportSourceTemplateSelector", pk: ruleId) else {
            return nil
        }
        return try mapToDTO(object)
    }

    /// Match import rules against a description
    func match(description: String) throws -> [ImportRuleDTO] {
        let allRules = try list()
        return allRules.filter { rule in
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else {
                return false
            }
            let range = NSRange(description.startIndex..., in: description)
            return regex.firstMatch(in: description, range: range) != nil
        }
    }

    // MARK: - Write Operations

    /// Create a new import rule
    func create(templateId: Int, pattern: String, accountId: String? = nil, payee: String? = nil) throws -> ImportRuleDTO {
        try performWrite { [self] ctx in
            guard let template = try fetchByPK(entityName: "TransactionTemplate", pk: templateId, in: ctx) else {
                throw ToolError.notFound("Template not found: \(templateId)")
            }

            let rule = Self.createObject(entityName: "ImportSourceTemplateSelector", in: ctx)
            rule.setValue(pattern, forKey: "pDetailsExpression")
            rule.setValue(accountId, forKey: "pAccountID")
            rule.setValue(Self.generateUUID(), forKey: "pUniqueID")
            Self.setNow(rule, "pCreationTime")
            Self.setNow(rule, "pModificationDate")
            rule.setValue(template, forKey: "pTransactionTemplate")
        }

        // Re-fetch
        let all = try list()
        guard let result = all.last(where: { $0.pattern == pattern }) else {
            throw ToolError.notFound("Failed to retrieve created import rule")
        }
        return result
    }

    /// Update an import rule
    func update(ruleId: Int, pattern: String? = nil, accountId: String? = nil) throws -> Bool {
        try performWriteReturning { [self] ctx in
            guard let rule = try fetchByPK(entityName: "ImportSourceTemplateSelector", pk: ruleId, in: ctx) else {
                return false
            }

            if let pattern = pattern { rule.setValue(pattern, forKey: "pDetailsExpression") }
            if let accountId = accountId { rule.setValue(accountId, forKey: "pAccountID") }
            Self.setNow(rule, "pModificationDate")
            return true
        }
    }

    /// Delete an import rule
    func delete(ruleId: Int) throws -> Bool {
        try performWriteReturning { [self] ctx in
            guard let rule = try fetchByPK(entityName: "ImportSourceTemplateSelector", pk: ruleId, in: ctx) else {
                return false
            }
            ctx.delete(rule)
            return true
        }
    }

    // MARK: - DTO Mapping

    func mapToDTO(_ object: NSManagedObject) throws -> ImportRuleDTO? {
        let pk = Self.extractPK(from: object.objectID)

        // Get the linked template
        guard let template = Self.relatedObject(object, "pTransactionTemplate") else { return nil }
        let templatePK = Self.extractPK(from: template.objectID)
        let templateTitle = Self.stringValue(template, "pTitle")

        return ImportRuleDTO(
            id: pk,
            templateId: templatePK,
            templateTitle: templateTitle,
            pattern: Self.stringValue(object, "pDetailsExpression"),
            accountId: Self.string(object, "pAccountID"),
            payee: nil
        )
    }
}
