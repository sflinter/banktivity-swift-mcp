import Foundation
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
        description: "Add a new line item to an existing transaction",
        inputSchema: ToolHelpers.schema(
            properties: [
                "transaction_id": ToolHelpers.property(type: "number", description: "The transaction ID to add the line item to"),
                "account_id": ToolHelpers.property(type: "number", description: "The account ID for this line item"),
                "account_name": ToolHelpers.property(type: "string", description: "The account name (alternative to account_id)"),
                "amount": ToolHelpers.property(type: "number", description: "The amount"),
                "memo": ToolHelpers.property(type: "string", description: "Optional memo"),
            ],
            required: ["transaction_id", "amount"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        guard let transactionId = ToolHelpers.getInt(arguments, key: "transaction_id") else {
            return ToolHelpers.errorResponse("transaction_id is required")
        }
        guard let amount = ToolHelpers.getDouble(arguments, key: "amount") else {
            return ToolHelpers.errorResponse("amount is required")
        }

        let accountId = try resolveAccountId(accounts: accounts, arguments: arguments)
        let memo = ToolHelpers.getString(arguments, key: "memo")

        _ = try lineItems.create(
            transactionId: transactionId,
            accountId: accountId,
            amount: amount,
            memo: memo
        )

        try lineItems.recalculateRunningBalances(accountId: accountId)

        // Return the updated line items
        let updatedItems = try lineItems.getForTransactionPK(transactionId)
        return try ToolHelpers.jsonResponse(updatedItems)
    }

    // update_line_item
    registry.register(
        name: "update_line_item",
        description: "Update a line item's account, amount, or memo",
        inputSchema: ToolHelpers.schema(
            properties: [
                "line_item_id": ToolHelpers.property(type: "number", description: "The line item ID to update"),
                "account_id": ToolHelpers.property(type: "number", description: "New account ID"),
                "account_name": ToolHelpers.property(type: "string", description: "New account name (alternative to account_id)"),
                "amount": ToolHelpers.property(type: "number", description: "New amount"),
                "memo": ToolHelpers.property(type: "string", description: "New memo"),
            ],
            required: ["line_item_id"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        guard let lineItemId = ToolHelpers.getInt(arguments, key: "line_item_id") else {
            return ToolHelpers.errorResponse("line_item_id is required")
        }

        var newAccountId: Int?
        if ToolHelpers.getInt(arguments, key: "account_id") != nil || ToolHelpers.getString(arguments, key: "account_name") != nil {
            newAccountId = try resolveAccountId(accounts: accounts, arguments: arguments)
        }
        let amount = ToolHelpers.getDouble(arguments, key: "amount")
        let memo = ToolHelpers.getString(arguments, key: "memo")

        let affectedAccounts = try lineItems.update(
            lineItemId: lineItemId,
            accountId: newAccountId,
            amount: amount,
            memo: memo
        )

        // Recalculate running balances for affected accounts
        for accountId in affectedAccounts {
            try lineItems.recalculateRunningBalances(accountId: accountId)
        }

        guard let updated = try lineItems.get(lineItemId: lineItemId) else {
            return ToolHelpers.errorResponse("Line item not found after update")
        }
        return try ToolHelpers.jsonResponse(updated)
    }

    // delete_line_item
    registry.register(
        name: "delete_line_item",
        description: "Delete a line item from a transaction",
        inputSchema: ToolHelpers.schema(
            properties: [
                "line_item_id": ToolHelpers.property(type: "number", description: "The line item ID to delete"),
            ],
            required: ["line_item_id"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        guard let lineItemId = ToolHelpers.getInt(arguments, key: "line_item_id") else {
            return ToolHelpers.errorResponse("line_item_id is required")
        }

        guard let info = try lineItems.delete(lineItemId: lineItemId) else {
            return ToolHelpers.errorResponse("Line item not found: \(lineItemId)")
        }

        try lineItems.recalculateRunningBalances(accountId: info.accountId)
        return ToolHelpers.successResponse("Line item \(lineItemId) deleted")
    }
}
