// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import BanktivityLib
import MCP

func registerStatementTools(
    registry: ToolRegistry,
    statements: StatementRepository,
    accounts: AccountRepository,
    lineItems: LineItemRepository,
    writeGuard: WriteGuard
) {
    // list_statements
    registry.register(
        name: "list_statements",
        description: "List statements for an account, sorted by start date",
        inputSchema: ToolHelpers.schema(properties: [
            "account_id": ToolHelpers.property(type: "number", description: "The account ID"),
            "account_name": ToolHelpers.property(type: "string", description: "The account name (alternative to account_id)"),
        ])
    ) { arguments in
        let accountId = try resolveAccountId(accounts: accounts, arguments: arguments)
        let results = try statements.list(accountId: accountId)
        return try ToolHelpers.jsonResponse(results)
    }

    // get_statement
    registry.register(
        name: "get_statement",
        description: "Get a statement with reconciliation progress (reconciled balance, difference, isBalanced)",
        inputSchema: ToolHelpers.schema(
            properties: [
                "statement_id": ToolHelpers.property(type: "number", description: "The statement ID"),
            ],
            required: ["statement_id"]
        )
    ) { arguments in
        guard let statementId = ToolHelpers.getInt(arguments, key: "statement_id") else {
            return ToolHelpers.errorResponse("statement_id is required")
        }

        guard let statement = try statements.get(statementId: statementId) else {
            return ToolHelpers.errorResponse("Statement not found: \(statementId)")
        }

        return try ToolHelpers.jsonResponse(statement)
    }

    // create_statement
    registry.register(
        name: "create_statement",
        description: "Create a new statement for an account with beginning/ending balance validation",
        inputSchema: ToolHelpers.schema(
            properties: [
                "account_id": ToolHelpers.property(type: "number", description: "The account ID"),
                "account_name": ToolHelpers.property(type: "string", description: "The account name (alternative to account_id)"),
                "start_date": ToolHelpers.property(type: "string", description: "Start date in ISO format (YYYY-MM-DD)"),
                "end_date": ToolHelpers.property(type: "string", description: "End date in ISO format (YYYY-MM-DD)"),
                "beginning_balance": ToolHelpers.property(type: "number", description: "Beginning balance"),
                "ending_balance": ToolHelpers.property(type: "number", description: "Ending balance"),
                "name": ToolHelpers.property(type: "string", description: "Optional statement name"),
                "note": ToolHelpers.property(type: "string", description: "Optional note"),
            ],
            required: ["start_date", "end_date", "beginning_balance", "ending_balance"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }

        let accountId = try resolveAccountId(accounts: accounts, arguments: arguments)

        guard let startDate = ToolHelpers.getString(arguments, key: "start_date") else {
            return ToolHelpers.errorResponse("start_date is required")
        }
        guard let endDate = ToolHelpers.getString(arguments, key: "end_date") else {
            return ToolHelpers.errorResponse("end_date is required")
        }
        guard let beginningBalance = ToolHelpers.getDouble(arguments, key: "beginning_balance") else {
            return ToolHelpers.errorResponse("beginning_balance is required")
        }
        guard let endingBalance = ToolHelpers.getDouble(arguments, key: "ending_balance") else {
            return ToolHelpers.errorResponse("ending_balance is required")
        }

        let name = ToolHelpers.getString(arguments, key: "name")
        let note = ToolHelpers.getString(arguments, key: "note")

        let result = try statements.create(
            accountId: accountId,
            startDate: startDate,
            endDate: endDate,
            beginningBalance: beginningBalance,
            endingBalance: endingBalance,
            name: name,
            note: note
        )
        return try ToolHelpers.jsonResponse(result)
    }

    // delete_statement
    registry.register(
        name: "delete_statement",
        description: "Delete a statement and unreconcile all its line items",
        inputSchema: ToolHelpers.schema(
            properties: [
                "statement_id": ToolHelpers.property(type: "number", description: "The statement ID to delete"),
            ],
            required: ["statement_id"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        guard let statementId = ToolHelpers.getInt(arguments, key: "statement_id") else {
            return ToolHelpers.errorResponse("statement_id is required")
        }

        let deleted = try statements.delete(statementId: statementId)
        if deleted {
            return ToolHelpers.successResponse("Statement \(statementId) deleted, line items unreconciled")
        }
        return ToolHelpers.errorResponse("Statement not found: \(statementId)")
    }

    // reconcile_line_items
    registry.register(
        name: "reconcile_line_items",
        description: "Assign line items to a statement (sets pCleared=true). Validates account ownership, date range, and no double-assignment.",
        inputSchema: ToolHelpers.schema(
            properties: [
                "statement_id": ToolHelpers.property(type: "number", description: "The statement ID"),
                "line_item_ids": ToolHelpers.property(type: "array", description: "Array of line item IDs to reconcile"),
            ],
            required: ["statement_id", "line_item_ids"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        guard let statementId = ToolHelpers.getInt(arguments, key: "statement_id") else {
            return ToolHelpers.errorResponse("statement_id is required")
        }
        guard let idsArray = ToolHelpers.getArray(arguments, key: "line_item_ids") else {
            return ToolHelpers.errorResponse("line_item_ids is required")
        }
        let lineItemIds = idsArray.compactMap { v -> Int? in
            if case .int(let i) = v { return i }
            if case .double(let d) = v { return Int(d) }
            return nil
        }

        let result = try statements.reconcileLineItems(statementId: statementId, lineItemIds: lineItemIds)
        return try ToolHelpers.jsonResponse(result)
    }

    // unreconcile_line_items
    registry.register(
        name: "unreconcile_line_items",
        description: "Remove line items from a statement (sets pCleared=false)",
        inputSchema: ToolHelpers.schema(
            properties: [
                "statement_id": ToolHelpers.property(type: "number", description: "The statement ID"),
                "line_item_ids": ToolHelpers.property(type: "array", description: "Array of line item IDs to unreconcile"),
            ],
            required: ["statement_id", "line_item_ids"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        guard let statementId = ToolHelpers.getInt(arguments, key: "statement_id") else {
            return ToolHelpers.errorResponse("statement_id is required")
        }
        guard let idsArray = ToolHelpers.getArray(arguments, key: "line_item_ids") else {
            return ToolHelpers.errorResponse("line_item_ids is required")
        }
        let lineItemIds = idsArray.compactMap { v -> Int? in
            if case .int(let i) = v { return i }
            if case .double(let d) = v { return Int(d) }
            return nil
        }

        guard let result = try statements.unreconcileLineItems(statementId: statementId, lineItemIds: lineItemIds) else {
            return ToolHelpers.errorResponse("Statement not found: \(statementId)")
        }
        return try ToolHelpers.jsonResponse(result)
    }

    // get_unreconciled_line_items
    registry.register(
        name: "get_unreconciled_line_items",
        description: "List unreconciled line items for an account, optionally filtered by date range",
        inputSchema: ToolHelpers.schema(properties: [
            "account_id": ToolHelpers.property(type: "number", description: "The account ID"),
            "account_name": ToolHelpers.property(type: "string", description: "The account name (alternative to account_id)"),
            "start_date": ToolHelpers.property(type: "string", description: "Start date in ISO format (YYYY-MM-DD)"),
            "end_date": ToolHelpers.property(type: "string", description: "End date in ISO format (YYYY-MM-DD)"),
        ])
    ) { arguments in
        let accountId = try resolveAccountId(accounts: accounts, arguments: arguments)
        let startDate = ToolHelpers.getString(arguments, key: "start_date")
        let endDate = ToolHelpers.getString(arguments, key: "end_date")

        let results = try statements.getUnreconciledLineItems(
            accountId: accountId,
            startDate: startDate,
            endDate: endDate
        )
        return try ToolHelpers.jsonResponse(results)
    }
}
