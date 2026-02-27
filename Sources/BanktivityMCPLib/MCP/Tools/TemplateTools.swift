// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import BanktivityLib
import MCP

/// Register template-related MCP tools
func registerTemplateTools(registry: ToolRegistry, templates: TemplateRepository, writeGuard: WriteGuard) {
    // list_transaction_templates
    registry.register(
        name: "list_transaction_templates",
        description: "List all transaction templates (used for import rules and scheduled transactions)",
        inputSchema: ToolHelpers.schema(properties: [:])
    ) { _ in
        let results = try templates.list()
        return try ToolHelpers.jsonResponse(results)
    }

    // get_transaction_template
    registry.register(
        name: "get_transaction_template",
        description: "Get a specific transaction template by ID",
        inputSchema: ToolHelpers.schema(
            properties: [
                "template_id": ToolHelpers.property(type: "number", description: "The template ID"),
            ],
            required: ["template_id"]
        )
    ) { arguments in
        guard let templateId = ToolHelpers.getInt(arguments, key: "template_id") else {
            return ToolHelpers.errorResponse("template_id is required")
        }

        guard let template = try templates.get(templateId: templateId) else {
            return ToolHelpers.errorResponse("Template not found: \(templateId)")
        }

        return try ToolHelpers.jsonResponse(template)
    }

    // create_transaction_template
    registry.register(
        name: "create_transaction_template",
        description: "Create a new transaction template for use with import rules or scheduled transactions",
        inputSchema: ToolHelpers.schema(
            properties: [
                "title": ToolHelpers.property(type: "string", description: "The template title (payee name)"),
                "amount": ToolHelpers.property(type: "number", description: "The default transaction amount"),
                "note": ToolHelpers.property(type: "string", description: "Optional note"),
                "currency_id": ToolHelpers.property(type: "string", description: "Currency UUID"),
                "line_items": ToolHelpers.property(type: "array", description: "Line items: [{account_id (UUID string), amount, memo?}]"),
            ],
            required: ["title", "amount"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        guard let title = ToolHelpers.getString(arguments, key: "title") else {
            return ToolHelpers.errorResponse("title is required")
        }
        guard let amount = ToolHelpers.getDouble(arguments, key: "amount") else {
            return ToolHelpers.errorResponse("amount is required")
        }

        let note = ToolHelpers.getString(arguments, key: "note")
        let currencyId = ToolHelpers.getString(arguments, key: "currency_id")

        var lineItems: [(accountId: String, amount: Double, memo: String?)]?
        if let liArray = ToolHelpers.getArray(arguments, key: "line_items") {
            lineItems = liArray.compactMap { v -> (accountId: String, amount: Double, memo: String?)? in
                guard case .object(let obj) = v else { return nil }
                guard let accountId = ToolHelpers.getString(obj, key: "account_id") else { return nil }
                let amount = ToolHelpers.getDouble(obj, key: "amount") ?? 0.0
                let memo = ToolHelpers.getString(obj, key: "memo")
                return (accountId: accountId, amount: amount, memo: memo)
            }
        }

        let result = try templates.create(
            title: title,
            amount: amount,
            note: note,
            currencyId: currencyId,
            lineItems: lineItems
        )

        return try ToolHelpers.jsonResponse(result)
    }

    // update_transaction_template
    registry.register(
        name: "update_transaction_template",
        description: "Update an existing transaction template",
        inputSchema: ToolHelpers.schema(
            properties: [
                "template_id": ToolHelpers.property(type: "number", description: "The template ID to update"),
                "title": ToolHelpers.property(type: "string", description: "New title"),
                "amount": ToolHelpers.property(type: "number", description: "New amount"),
                "note": ToolHelpers.property(type: "string", description: "New note"),
                "active": ToolHelpers.property(type: "boolean", description: "Set active status"),
            ],
            required: ["template_id"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        guard let templateId = ToolHelpers.getInt(arguments, key: "template_id") else {
            return ToolHelpers.errorResponse("template_id is required")
        }

        let title = ToolHelpers.getString(arguments, key: "title")
        let amount = ToolHelpers.getDouble(arguments, key: "amount")
        let note = ToolHelpers.getString(arguments, key: "note")
        let active: Bool? = arguments?["active"].flatMap { v in
            if case .bool(let b) = v { return b }
            return nil
        }

        let success = try templates.update(
            templateId: templateId,
            title: title,
            amount: amount,
            note: note,
            active: active
        )

        if success {
            if let updated = try templates.get(templateId: templateId) {
                return try ToolHelpers.jsonResponse(updated)
            }
        }
        return ToolHelpers.errorResponse("Template not found: \(templateId)")
    }

    // delete_transaction_template
    registry.register(
        name: "delete_transaction_template",
        description: "Delete a transaction template (also deletes associated import rules and schedules)",
        inputSchema: ToolHelpers.schema(
            properties: [
                "template_id": ToolHelpers.property(type: "number", description: "The template ID to delete"),
            ],
            required: ["template_id"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        guard let templateId = ToolHelpers.getInt(arguments, key: "template_id") else {
            return ToolHelpers.errorResponse("template_id is required")
        }

        let deleted = try templates.delete(templateId: templateId)
        if deleted {
            return ToolHelpers.successResponse("Template \(templateId) deleted")
        }
        return ToolHelpers.errorResponse("Template not found: \(templateId)")
    }
}
