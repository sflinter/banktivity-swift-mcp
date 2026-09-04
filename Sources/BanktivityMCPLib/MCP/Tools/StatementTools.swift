// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import BanktivityLib
import MCP

private struct StatementListResponse: Codable {
    let warnings: [String]
    let statements: [StatementSummaryDTO]
    let unaddressableReferences: [StatementUnaddressableReferenceDTO]
}

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
        description: "List statements for an account, sorted by start date. Investment account balance fields are advisory and require Banktivity UI verification.",
        inputSchema: ToolHelpers.schema(properties: [
            "account_id": ToolHelpers.property(type: "number", description: "The account ID"),
            "account_name": ToolHelpers.property(type: "string", description: "The account name (alternative to account_id)"),
            "include_internal": ToolHelpers.property(type: "boolean", description: "Include unnamed/internal investment statement diagnostics"),
        ])
    ) { arguments in
        let accountId = try resolveAccountId(accounts: accounts, arguments: arguments)
        let includeInternal = ToolHelpers.getBool(arguments, key: "include_internal")
        let diagnostic = includeInternal
            ? try statements.listWithInternalDiagnostics(accountId: accountId)
            : StatementInternalListingDTO(
                statements: try statements.list(accountId: accountId),
                unaddressableReferences: []
            )
        let warnings = try statements.warningsForStatementReads(accountId: accountId)
        return try ToolHelpers.jsonResponse(StatementListResponse(
            warnings: warnings,
            statements: diagnostic.statements,
            unaddressableReferences: diagnostic.unaddressableReferences
        ))
    }

    // get_account_reconciliation_status
    registry.register(
        name: "get_account_reconciliation_status",
        description: "Get account statement reconciliation status derived only from active statements",
        inputSchema: ToolHelpers.schema(properties: [
            "account_id": ToolHelpers.property(type: "number", description: "The account ID"),
            "account_name": ToolHelpers.property(type: "string", description: "The account name (alternative to account_id)"),
        ])
    ) { arguments in
        let accountId = try resolveAccountId(accounts: accounts, arguments: arguments)
        let result = try statements.getAccountReconciliationStatus(accountId: accountId)
        return try ToolHelpers.jsonResponse(result)
    }

    // get_statement
    registry.register(
        name: "get_statement",
        description: "Get a statement with reconciliation progress and line item membership. Balance fields are cash-line/advisory for investment accounts; uiVerificationRequired=true means the Banktivity Statements UI is required.",
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

    // plan_statement_visible_row_correction
    registry.register(
        name: "plan_statement_visible_row_correction",
        description: "Generate a visible-row correction plan from operator-entered Banktivity UI START/END/MISSING values. This helper does not discover or verify UI state.",
        inputSchema: ToolHelpers.schema(
            properties: [
                "statement_id": ToolHelpers.property(type: "number", description: "Optional target visible statement ID"),
                "ui_start": ToolHelpers.property(type: "number", description: "START value read by the operator from the Banktivity Statements UI"),
                "ui_end": ToolHelpers.property(type: "number", description: "END value read by the operator from the Banktivity Statements UI"),
                "ui_missing": ToolHelpers.property(type: "number", description: "MISSING value read by the operator from the Banktivity Statements UI"),
                "corrected_start": ToolHelpers.property(type: "number", description: "Optional corrected row start, usually the previous corrected row ending balance for chained rows"),
            ],
            required: ["ui_start", "ui_end", "ui_missing"]
        )
    ) { arguments in
        guard let uiStart = ToolHelpers.getDouble(arguments, key: "ui_start"),
              let uiEnd = ToolHelpers.getDouble(arguments, key: "ui_end"),
              let uiMissing = ToolHelpers.getDouble(arguments, key: "ui_missing") else {
            return ToolHelpers.errorResponse("ui_start, ui_end, and ui_missing are required")
        }

        let plan = statements.visibleRowCorrectionPlan(
            statementId: ToolHelpers.getInt(arguments, key: "statement_id"),
            uiStart: uiStart,
            uiEnd: uiEnd,
            uiMissing: uiMissing,
            correctedStart: ToolHelpers.getDouble(arguments, key: "corrected_start")
        )
        return try ToolHelpers.jsonResponse(plan)
    }

    // create_statement
    registry.register(
        name: "create_statement",
        description: "Create a new statement for an account with beginning/ending balance validation. Requires a fresh backup and post-write Banktivity UI verification.",
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
                "backup_confirmed": ToolHelpers.property(type: "boolean", description: "Must be true after creating a fresh whole-vault backup"),
                "post_ui_verification_required": ToolHelpers.property(type: "boolean", description: "Must be true to acknowledge post-write Banktivity UI inspection is required"),
            ],
            required: ["start_date", "end_date", "beginning_balance", "ending_balance", "backup_confirmed", "post_ui_verification_required"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        if let msg = statementWriteSafetyError(arguments: arguments) {
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

    // update_statement
    registry.register(
        name: "update_statement",
        description: "Update a visible statement row's ending balance after an operator-entered UI correction plan. Unnamed investment statement rows require operator_confirmed_visible=true after UI matching; requires backup plus post-write Banktivity UI verification.",
        inputSchema: ToolHelpers.schema(
            properties: [
                "statement_id": ToolHelpers.property(type: "number", description: "The visible statement ID to update"),
                "ending_balance": ToolHelpers.property(type: "number", description: "Corrected ending balance"),
                "backup_confirmed": ToolHelpers.property(type: "boolean", description: "Must be true after creating a fresh whole-vault backup"),
                "post_ui_verification_required": ToolHelpers.property(type: "boolean", description: "Must be true to acknowledge post-write Banktivity UI inspection is required"),
                "operator_confirmed_visible": ToolHelpers.property(type: "boolean", description: "Set true only after matching an unnamed investment statement row to the intended visible Banktivity Statements UI row"),
            ],
            required: ["statement_id", "ending_balance", "backup_confirmed", "post_ui_verification_required"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        if let msg = statementWriteSafetyError(arguments: arguments) {
            return ToolHelpers.errorResponse(msg)
        }
        guard let statementId = ToolHelpers.getInt(arguments, key: "statement_id") else {
            return ToolHelpers.errorResponse("statement_id is required")
        }
        guard let endingBalance = ToolHelpers.getDouble(arguments, key: "ending_balance") else {
            return ToolHelpers.errorResponse("ending_balance is required")
        }

        let result = try statements.update(
            statementId: statementId,
            endingBalance: endingBalance,
            operatorConfirmedVisible: ToolHelpers.getBool(arguments, key: "operator_confirmed_visible")
        )
        return try ToolHelpers.jsonResponse(result)
    }

    // delete_statement
    registry.register(
        name: "delete_statement",
        description: "Delete a visible statement and remove statement links from its line items while preserving their cleared state. Rejects internal investment statement rows unless allow_internal=true is supplied from a diagnostic repair plan; requires backup plus post-write Banktivity UI verification.",
        inputSchema: ToolHelpers.schema(
            properties: [
                "statement_id": ToolHelpers.property(type: "number", description: "The statement ID to delete"),
                "backup_confirmed": ToolHelpers.property(type: "boolean", description: "Must be true after creating a fresh whole-vault backup"),
                "post_ui_verification_required": ToolHelpers.property(type: "boolean", description: "Must be true to acknowledge post-write Banktivity UI inspection is required"),
                "allow_internal": ToolHelpers.property(type: "boolean", description: "Deliberately allow deleting an internal investment statement row after a diagnostic repair plan"),
            ],
            required: ["statement_id", "backup_confirmed", "post_ui_verification_required"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        if let msg = statementWriteSafetyError(arguments: arguments) {
            return ToolHelpers.errorResponse(msg)
        }
        guard let statementId = ToolHelpers.getInt(arguments, key: "statement_id") else {
            return ToolHelpers.errorResponse("statement_id is required")
        }

        let deleted = try statements.delete(
            statementId: statementId,
            allowInternal: ToolHelpers.getBool(arguments, key: "allow_internal")
        )
        if deleted {
            return ToolHelpers.successResponse("Statement \(statementId) deleted, line items unreconciled")
        }
        return ToolHelpers.errorResponse("Statement not found: \(statementId)")
    }

    // reconcile_line_items
    registry.register(
        name: "reconcile_line_items",
        description: "Assign explicitly selected line items to a visible statement (sets pCleared=true). Unnamed investment statement rows require operator_confirmed_visible=true after UI matching; validates account ownership and no double-assignment, and requires backup plus post-write Banktivity UI verification.",
        inputSchema: ToolHelpers.schema(
            properties: [
                "statement_id": ToolHelpers.property(type: "number", description: "The statement ID"),
                "line_item_ids": ToolHelpers.property(type: "array", description: "Array of line item IDs to reconcile"),
                "backup_confirmed": ToolHelpers.property(type: "boolean", description: "Must be true after creating a fresh whole-vault backup"),
                "post_ui_verification_required": ToolHelpers.property(type: "boolean", description: "Must be true to acknowledge post-write Banktivity UI inspection is required"),
                "operator_confirmed_visible": ToolHelpers.property(type: "boolean", description: "Set true only after matching an unnamed investment statement row to the intended visible Banktivity Statements UI row"),
            ],
            required: ["statement_id", "line_item_ids", "backup_confirmed", "post_ui_verification_required"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        if let msg = statementWriteSafetyError(arguments: arguments) {
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

        let result = try statements.reconcileLineItems(
            statementId: statementId,
            lineItemIds: lineItemIds,
            operatorConfirmedVisible: ToolHelpers.getBool(arguments, key: "operator_confirmed_visible")
        )
        return try ToolHelpers.jsonResponse(result)
    }

    // unreconcile_line_items
    registry.register(
        name: "unreconcile_line_items",
        description: "Remove line items from a visible statement while preserving their cleared state. Unnamed investment statement rows require operator_confirmed_visible=true after UI matching and require backup plus post-write Banktivity UI verification.",
        inputSchema: ToolHelpers.schema(
            properties: [
                "statement_id": ToolHelpers.property(type: "number", description: "The statement ID"),
                "line_item_ids": ToolHelpers.property(type: "array", description: "Array of line item IDs to unreconcile"),
                "backup_confirmed": ToolHelpers.property(type: "boolean", description: "Must be true after creating a fresh whole-vault backup"),
                "post_ui_verification_required": ToolHelpers.property(type: "boolean", description: "Must be true to acknowledge post-write Banktivity UI inspection is required"),
                "operator_confirmed_visible": ToolHelpers.property(type: "boolean", description: "Set true only after matching an unnamed investment statement row to the intended visible Banktivity Statements UI row"),
            ],
            required: ["statement_id", "line_item_ids", "backup_confirmed", "post_ui_verification_required"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        if let msg = statementWriteSafetyError(arguments: arguments) {
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

        guard let result = try statements.unreconcileLineItems(
            statementId: statementId,
            lineItemIds: lineItemIds,
            operatorConfirmedVisible: ToolHelpers.getBool(arguments, key: "operator_confirmed_visible")
        ) else {
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

private func statementWriteSafetyError(arguments: [String: Value]?) -> String? {
    guard ToolHelpers.getBool(arguments, key: "backup_confirmed") else {
        return "Statement writes require backup_confirmed=true after creating a fresh whole-vault backup."
    }
    guard ToolHelpers.getBool(arguments, key: "post_ui_verification_required") else {
        return "Statement writes require post_ui_verification_required=true because Banktivity Statements UI inspection is the post-write authority."
    }
    return nil
}
