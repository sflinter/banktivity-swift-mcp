// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import BanktivityLib
import MCP

/// Register line item MCP tools
func registerLineItemTools(
    registry: ToolRegistry,
    lineItems: LineItemRepository,
    accounts: AccountRepository,
    writeGuard: WriteGuard
) {
    // get_line_item
    registry.register(
        name: "get_line_item",
        access: .read,
        description: "Get a specific line item by ID",
        inputSchema: ToolHelpers.schema(
            properties: [
                "line_item_id": ToolHelpers.property(type: "number", description: "The line item ID"),
            ],
            required: ["line_item_id"]
        )
    ) { arguments in
        guard let lineItemId = ToolHelpers.getInt(arguments, key: "line_item_id") else {
            return ToolHelpers.errorResponse("line_item_id is required")
        }

        guard let lineItem = try lineItems.get(lineItemId: lineItemId) else {
            return ToolHelpers.errorResponse("Line item not found: \(lineItemId)")
        }

        return try ToolHelpers.jsonResponse(lineItem)
    }

    // add_line_item
    registry.register(
        name: "add_line_item",
        access: .write,
        description: "Add a new line item to an existing transaction. Live writes require operator_reviewed_target and post_ui_verification_required. Use dry_run to validate without writing.",
        inputSchema: ToolHelpers.schema(
            properties: [
                "transaction_id": ToolHelpers.property(type: "number", description: "The transaction ID to add the line item to"),
                "account_id": ToolHelpers.property(type: "number", description: "The account ID for this line item"),
                "account_name": ToolHelpers.property(type: "string", description: "The account name (alternative to account_id)"),
                "amount": ToolHelpers.property(type: "number", description: "The amount"),
                "memo": ToolHelpers.property(type: "string", description: "Optional memo"),
                "dry_run": ToolHelpers.property(type: "boolean", description: "If true, validate and return the planned mutation without writing"),
                "operator_reviewed_target": ToolHelpers.property(type: "boolean", description: "Must be true for live writes after reviewing the target transaction and account"),
                "post_ui_verification_required": ToolHelpers.property(type: "boolean", description: "Must be true for live writes to acknowledge post-write Banktivity UI inspection"),
            ],
            required: ["transaction_id", "amount"]
        )
    ) { arguments in
        guard let transactionId = ToolHelpers.getInt(arguments, key: "transaction_id") else {
            return ToolHelpers.errorResponse("transaction_id is required")
        }
        guard let amount = ToolHelpers.getDouble(arguments, key: "amount") else {
            return ToolHelpers.errorResponse("amount is required")
        }

        let accountId = try resolveAccountId(accounts: accounts, arguments: arguments)
        let memo = ToolHelpers.getString(arguments, key: "memo")

        if ToolHelpers.getBool(arguments, key: "dry_run") {
            return try ToolHelpers.jsonResponse(lineItems.validateAddToTransaction(
                transactionId: transactionId,
                accountId: accountId
            ))
        }
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        if let msg = lineItemWriteSafetyError(arguments: arguments) {
            return ToolHelpers.errorResponse(msg)
        }

        let updatedItems = try lineItems.addToTransaction(
            transactionId: transactionId,
            accountId: accountId,
            amount: amount,
            memo: memo
        )
        return try ToolHelpers.jsonResponse(updatedItems)
    }

    // update_line_item
    registry.register(
        name: "update_line_item",
        access: .write,
        description: "Update a line item's account, amount, or memo. Live writes require operator_reviewed_target and post_ui_verification_required. Use dry_run to validate without writing.",
        inputSchema: ToolHelpers.schema(
            properties: [
                "line_item_id": ToolHelpers.property(type: "number", description: "The line item ID to update"),
                "account_id": ToolHelpers.property(type: "number", description: "New account ID"),
                "account_name": ToolHelpers.property(type: "string", description: "New account name (alternative to account_id)"),
                "amount": ToolHelpers.property(type: "number", description: "New amount"),
                "memo": ToolHelpers.property(type: "string", description: "New memo"),
                "dry_run": ToolHelpers.property(type: "boolean", description: "If true, validate and return the planned mutation without writing"),
                "operator_reviewed_target": ToolHelpers.property(type: "boolean", description: "Must be true for live writes after reviewing the target line item"),
                "post_ui_verification_required": ToolHelpers.property(type: "boolean", description: "Must be true for live writes to acknowledge post-write Banktivity UI inspection"),
            ],
            required: ["line_item_id"]
        )
    ) { arguments in
        guard let lineItemId = ToolHelpers.getInt(arguments, key: "line_item_id") else {
            return ToolHelpers.errorResponse("line_item_id is required")
        }

        var newAccountId: Int?
        if ToolHelpers.getInt(arguments, key: "account_id") != nil || ToolHelpers.getString(arguments, key: "account_name") != nil {
            newAccountId = try resolveAccountId(accounts: accounts, arguments: arguments)
        }
        let amount = ToolHelpers.getDouble(arguments, key: "amount")
        let memo = ToolHelpers.getString(arguments, key: "memo")

        if ToolHelpers.getBool(arguments, key: "dry_run") {
            return try ToolHelpers.jsonResponse(lineItems.validateUpdate(
                lineItemId: lineItemId,
                accountId: newAccountId
            ))
        }
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        if let msg = lineItemWriteSafetyError(arguments: arguments) {
            return ToolHelpers.errorResponse(msg)
        }

        guard let updated = try lineItems.updateWithRecalculation(
            lineItemId: lineItemId,
            accountId: newAccountId,
            amount: amount,
            memo: memo
        ) else {
            return ToolHelpers.errorResponse("Line item not found after update")
        }
        return try ToolHelpers.jsonResponse(updated)
    }

    // delete_line_item
    registry.register(
        name: "delete_line_item",
        access: .write,
        description: "Delete a line item from a transaction. Live writes require operator_reviewed_target and post_ui_verification_required. Use dry_run to validate without writing.",
        inputSchema: ToolHelpers.schema(
            properties: [
                "line_item_id": ToolHelpers.property(type: "number", description: "The line item ID to delete"),
                "dry_run": ToolHelpers.property(type: "boolean", description: "If true, validate and return the planned mutation without writing"),
                "operator_reviewed_target": ToolHelpers.property(type: "boolean", description: "Must be true for live writes after reviewing the target line item"),
                "post_ui_verification_required": ToolHelpers.property(type: "boolean", description: "Must be true for live writes to acknowledge post-write Banktivity UI inspection"),
            ],
            required: ["line_item_id"]
        )
    ) { arguments in
        guard let lineItemId = ToolHelpers.getInt(arguments, key: "line_item_id") else {
            return ToolHelpers.errorResponse("line_item_id is required")
        }

        if ToolHelpers.getBool(arguments, key: "dry_run") {
            return try ToolHelpers.jsonResponse(lineItems.validateDelete(lineItemId: lineItemId))
        }
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        if let msg = lineItemWriteSafetyError(arguments: arguments) {
            return ToolHelpers.errorResponse(msg)
        }

        guard try lineItems.deleteWithRecalculation(lineItemId: lineItemId) else {
            return ToolHelpers.errorResponse("Line item not found: \(lineItemId)")
        }
        return ToolHelpers.successResponse("Line item \(lineItemId) deleted")
    }
}

private func lineItemWriteSafetyError(arguments: [String: Value]?) -> String? {
    guard ToolHelpers.getBool(arguments, key: "operator_reviewed_target") else {
        return "Line-item writes require operator_reviewed_target=true after reviewing the target transaction/account."
    }
    guard ToolHelpers.getBool(arguments, key: "post_ui_verification_required") else {
        return "Line-item writes require post_ui_verification_required=true because balances and statement membership must be checked in Banktivity UI after writing."
    }
    return nil
}
