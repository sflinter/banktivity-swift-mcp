// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import BanktivityLib
import MCP

/// Register import rule MCP tools
func registerImportRuleTools(registry: ToolRegistry, importRules: ImportRuleRepository, writeGuard: WriteGuard) {
    // list_import_rules
    registry.register(
        name: "list_import_rules",
        description: "List all import rules (patterns to match and categorize imported transactions)",
        inputSchema: ToolHelpers.schema(properties: [:])
    ) { _ in
        let results = try importRules.list()
        return try ToolHelpers.jsonResponse(results)
    }

    // get_import_rule
    registry.register(
        name: "get_import_rule",
        description: "Get a specific import rule by ID",
        inputSchema: ToolHelpers.schema(
            properties: [
                "rule_id": ToolHelpers.property(type: "number", description: "The import rule ID"),
            ],
            required: ["rule_id"]
        )
    ) { arguments in
        guard let ruleId = ToolHelpers.getInt(arguments, key: "rule_id") else {
            return ToolHelpers.errorResponse("rule_id is required")
        }

        guard let rule = try importRules.get(ruleId: ruleId) else {
            return ToolHelpers.errorResponse("Import rule not found: \(ruleId)")
        }

        return try ToolHelpers.jsonResponse(rule)
    }

    // match_import_rules
    registry.register(
        name: "match_import_rules",
        description: "Test which import rules match a given transaction description",
        inputSchema: ToolHelpers.schema(
            properties: [
                "description": ToolHelpers.property(type: "string", description: "The transaction description to test against import rules"),
            ],
            required: ["description"]
        )
    ) { arguments in
        guard let description = ToolHelpers.getString(arguments, key: "description") else {
            return ToolHelpers.errorResponse("description is required")
        }

        let matches = try importRules.match(description: description)
        return try ToolHelpers.jsonResponse(matches)
    }

    // create_import_rule
    registry.register(
        name: "create_import_rule",
        description: "Create a new import rule to automatically categorize imported transactions based on a regex pattern",
        inputSchema: ToolHelpers.schema(
            properties: [
                "template_id": ToolHelpers.property(type: "number", description: "The transaction template ID to apply when this rule matches"),
                "pattern": ToolHelpers.property(type: "string", description: "Regex pattern to match against transaction descriptions"),
                "account_id": ToolHelpers.property(type: "string", description: "Optional account UUID to filter by"),
            ],
            required: ["template_id", "pattern"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        guard let templateId = ToolHelpers.getInt(arguments, key: "template_id") else {
            return ToolHelpers.errorResponse("template_id is required")
        }
        guard let pattern = ToolHelpers.getString(arguments, key: "pattern") else {
            return ToolHelpers.errorResponse("pattern is required")
        }
        let accountId = ToolHelpers.getString(arguments, key: "account_id")

        let result = try importRules.create(
            templateId: templateId,
            pattern: pattern,
            accountId: accountId
        )
        return try ToolHelpers.jsonResponse(result)
    }

    // update_import_rule
    registry.register(
        name: "update_import_rule",
        description: "Update an existing import rule",
        inputSchema: ToolHelpers.schema(
            properties: [
                "rule_id": ToolHelpers.property(type: "number", description: "The import rule ID to update"),
                "pattern": ToolHelpers.property(type: "string", description: "New regex pattern"),
                "account_id": ToolHelpers.property(type: "string", description: "New account UUID"),
            ],
            required: ["rule_id"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        guard let ruleId = ToolHelpers.getInt(arguments, key: "rule_id") else {
            return ToolHelpers.errorResponse("rule_id is required")
        }

        let pattern = ToolHelpers.getString(arguments, key: "pattern")
        let accountId = ToolHelpers.getString(arguments, key: "account_id")

        let success = try importRules.update(ruleId: ruleId, pattern: pattern, accountId: accountId)
        if success {
            if let updated = try importRules.get(ruleId: ruleId) {
                return try ToolHelpers.jsonResponse(updated)
            }
        }
        return ToolHelpers.errorResponse("Import rule not found: \(ruleId)")
    }

    // delete_import_rule
    registry.register(
        name: "delete_import_rule",
        description: "Delete an import rule",
        inputSchema: ToolHelpers.schema(
            properties: [
                "rule_id": ToolHelpers.property(type: "number", description: "The import rule ID to delete"),
            ],
            required: ["rule_id"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        guard let ruleId = ToolHelpers.getInt(arguments, key: "rule_id") else {
            return ToolHelpers.errorResponse("rule_id is required")
        }

        let deleted = try importRules.delete(ruleId: ruleId)
        if deleted {
            return ToolHelpers.successResponse("Import rule \(ruleId) deleted")
        }
        return ToolHelpers.errorResponse("Import rule not found: \(ruleId)")
    }
}
