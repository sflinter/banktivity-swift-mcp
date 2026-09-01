// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import BanktivityLib
import MCP

/// Register transaction-related MCP tools
func registerTransactionTools(
    registry: ToolRegistry,
    transactions: TransactionRepository,
    accounts: AccountRepository,
    writeGuard: WriteGuard
) {
    // get_transactions
    registry.register(
        name: "get_transactions",
        description: "Get transactions with optional filtering by account and date range",
        inputSchema: ToolHelpers.schema(properties: [
            "account_id": ToolHelpers.property(type: "number", description: "Filter by account ID"),
            "account_name": ToolHelpers.property(type: "string", description: "Filter by account name (alternative to account_id)"),
            "start_date": ToolHelpers.property(type: "string", description: "Start date in ISO format (YYYY-MM-DD)"),
            "end_date": ToolHelpers.property(type: "string", description: "End date in ISO format (YYYY-MM-DD)"),
            "limit": ToolHelpers.property(type: "number", description: "Maximum number of transactions to return"),
            "offset": ToolHelpers.property(type: "number", description: "Number of transactions to skip"),
        ])
    ) { arguments in
        let accountId = ToolHelpers.getInt(arguments, key: "account_id")
        let startDate = ToolHelpers.getString(arguments, key: "start_date")
        let endDate = ToolHelpers.getString(arguments, key: "end_date")
        let limit = ToolHelpers.getInt(arguments, key: "limit")
        let offset = ToolHelpers.getInt(arguments, key: "offset")

        let results = try transactions.list(
            accountId: accountId,
            startDate: startDate,
            endDate: endDate,
            limit: limit,
            offset: offset
        )

        return try ToolHelpers.jsonResponse(results)
    }

    // search_transactions
    registry.register(
        name: "search_transactions",
        description: "Search transactions by payee name or notes",
        inputSchema: ToolHelpers.schema(
            properties: [
                "query": ToolHelpers.property(type: "string", description: "Search query (matches payee name and notes)"),
                "limit": ToolHelpers.property(type: "number", description: "Maximum number of results (default 50)"),
            ],
            required: ["query"]
        )
    ) { arguments in
        guard let query = ToolHelpers.getString(arguments, key: "query") else {
            return ToolHelpers.errorResponse("query is required")
        }

        let limit = ToolHelpers.getInt(arguments, key: "limit") ?? 50
        let results = try transactions.search(query: query, limit: limit)

        return try ToolHelpers.jsonResponse(results)
    }

    // get_transaction
    registry.register(
        name: "get_transaction",
        description: "Get a single transaction by ID with all its line items",
        inputSchema: ToolHelpers.schema(
            properties: [
                "transaction_id": ToolHelpers.property(type: "number", description: "The transaction ID"),
            ],
            required: ["transaction_id"]
        )
    ) { arguments in
        guard let transactionId = ToolHelpers.getInt(arguments, key: "transaction_id") else {
            return ToolHelpers.errorResponse("transaction_id is required")
        }

        guard let transaction = try transactions.get(transactionId: transactionId) else {
            return ToolHelpers.errorResponse("Transaction not found: \(transactionId)")
        }

        return try ToolHelpers.jsonResponse(transaction)
    }

    // create_transaction
    registry.register(
        name: "create_transaction",
        description: "Create a new transaction with line items",
        inputSchema: ToolHelpers.schema(
            properties: [
                "date": ToolHelpers.property(type: "string", description: "Transaction date in ISO format (YYYY-MM-DD)"),
                "title": ToolHelpers.property(type: "string", description: "Transaction title/payee"),
                "note": ToolHelpers.property(type: "string", description: "Optional note"),
                "line_items": ToolHelpers.property(type: "array", description: "Line items: [{account_id, amount, memo?}]"),
            ],
            required: ["date", "title", "line_items"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        guard let date = ToolHelpers.getString(arguments, key: "date") else {
            return ToolHelpers.errorResponse("date is required")
        }
        guard let title = ToolHelpers.getString(arguments, key: "title") else {
            return ToolHelpers.errorResponse("title is required")
        }
        guard let lineItemsArray = ToolHelpers.getArray(arguments, key: "line_items") else {
            return ToolHelpers.errorResponse("line_items is required")
        }

        let note = ToolHelpers.getString(arguments, key: "note")

        // Parse line items
        var lineItems: [(accountId: Int, amount: Double, memo: String?)] = []
        for liValue in lineItemsArray {
            guard case .object(let liObj) = liValue else { continue }
            guard let accountId = ToolHelpers.getInt(liObj, key: "account_id") ??
                  ToolHelpers.getInt(liObj, key: "accountId") else {
                // Try resolving by name
                if let name = ToolHelpers.getString(liObj, key: "account_name"),
                   let account = try accounts.findByName(name) {
                    let amount = ToolHelpers.getDouble(liObj, key: "amount") ?? 0.0
                    let memo = ToolHelpers.getString(liObj, key: "memo")
                    lineItems.append((accountId: account.id, amount: amount, memo: memo))
                    continue
                }
                return ToolHelpers.errorResponse("Each line item requires account_id or account_name")
            }
            let amount = ToolHelpers.getDouble(liObj, key: "amount") ?? 0.0
            let memo = ToolHelpers.getString(liObj, key: "memo")
            lineItems.append((accountId: accountId, amount: amount, memo: memo))
        }

        if lineItems.isEmpty {
            return ToolHelpers.errorResponse("At least one line item is required")
        }

        let result = try transactions.create(
            date: date,
            title: title,
            note: note,
            lineItems: lineItems
        )

        return try ToolHelpers.jsonResponse(result)
    }

    // repair_forex_transfer
    registry.register(
        name: "repair_forex_transfer",
        description: "Repair an existing cross-currency transfer using source-currency gross amount, provider fee split, target amount, and exchange rate",
        inputSchema: ToolHelpers.schema(
            properties: [
                "transaction_id": ToolHelpers.property(type: "number", description: "Existing transaction ID to repair"),
                "source_account_id": ToolHelpers.property(type: "number", description: "Source account ID, in the source currency"),
                "target_account_id": ToolHelpers.property(type: "number", description: "Target account ID, in the target currency"),
                "fee_category_id": ToolHelpers.property(type: "number", description: "Expense category/account ID for the source-currency provider fee"),
                "gross_source_amount": ToolHelpers.property(type: "number", description: "Gross source amount debited from the source account"),
                "source_fee_amount": ToolHelpers.property(type: "number", description: "Provider fee in the source currency"),
                "target_amount": ToolHelpers.property(type: "number", description: "Amount received in the target account currency"),
                "exchange_rate": ToolHelpers.property(type: "number", description: "Provider exchange rate from source-after-fee to target currency"),
                "title": ToolHelpers.property(type: "string", description: "Optional replacement title"),
                "note": ToolHelpers.property(type: "string", description: "Optional replacement note"),
                "date": ToolHelpers.property(type: "string", description: "Optional replacement date in ISO format (YYYY-MM-DD)"),
                "source_memo": ToolHelpers.property(type: "string", description: "Optional source line memo"),
                "target_memo": ToolHelpers.property(type: "string", description: "Optional target line memo"),
                "fee_memo": ToolHelpers.property(type: "string", description: "Optional fee line memo"),
            ],
            required: [
                "transaction_id", "source_account_id", "target_account_id", "fee_category_id",
                "gross_source_amount", "source_fee_amount", "target_amount", "exchange_rate",
            ]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        guard let transactionId = ToolHelpers.getInt(arguments, key: "transaction_id"),
              let sourceAccountId = ToolHelpers.getInt(arguments, key: "source_account_id"),
              let targetAccountId = ToolHelpers.getInt(arguments, key: "target_account_id"),
              let feeCategoryId = ToolHelpers.getInt(arguments, key: "fee_category_id"),
              let grossSourceAmount = ToolHelpers.getDouble(arguments, key: "gross_source_amount"),
              let sourceFeeAmount = ToolHelpers.getDouble(arguments, key: "source_fee_amount"),
              let targetAmount = ToolHelpers.getDouble(arguments, key: "target_amount"),
              let exchangeRate = ToolHelpers.getDouble(arguments, key: "exchange_rate") else {
            return ToolHelpers.errorResponse("transaction_id, source_account_id, target_account_id, fee_category_id, gross_source_amount, source_fee_amount, target_amount, and exchange_rate are required")
        }

        guard let repaired = try transactions.repairForexTransfer(
            transactionId: transactionId,
            sourceAccountId: sourceAccountId,
            targetAccountId: targetAccountId,
            feeCategoryId: feeCategoryId,
            grossSourceAmount: grossSourceAmount,
            sourceFeeAmount: sourceFeeAmount,
            targetAmount: targetAmount,
            exchangeRate: exchangeRate,
            title: ToolHelpers.getString(arguments, key: "title"),
            note: ToolHelpers.getString(arguments, key: "note"),
            date: ToolHelpers.getString(arguments, key: "date"),
            sourceMemo: ToolHelpers.getString(arguments, key: "source_memo"),
            targetMemo: ToolHelpers.getString(arguments, key: "target_memo"),
            feeMemo: ToolHelpers.getString(arguments, key: "fee_memo")
        ) else {
            return ToolHelpers.errorResponse("Transaction not found after repair")
        }

        return try ToolHelpers.jsonResponse(repaired)
    }

    // update_transaction
    registry.register(
        name: "update_transaction",
        description: "Update an existing transaction's title, note, date, cleared status, or transaction type",
        inputSchema: ToolHelpers.schema(
            properties: [
                "transaction_id": ToolHelpers.property(type: "number", description: "The transaction ID to update"),
                "title": ToolHelpers.property(type: "string", description: "New title"),
                "note": ToolHelpers.property(type: "string", description: "New note"),
                "date": ToolHelpers.property(type: "string", description: "New date in ISO format (YYYY-MM-DD)"),
                "cleared": ToolHelpers.property(type: "boolean", description: "Set cleared status"),
                "transaction_type": ToolHelpers.property(type: "string", description: "New transaction type: deposit, withdrawal, transfer, check, buy, sell, move-shares-in, move-shares-out, dividend, etc."),
            ],
            required: ["transaction_id"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        guard let transactionId = ToolHelpers.getInt(arguments, key: "transaction_id") else {
            return ToolHelpers.errorResponse("transaction_id is required")
        }

        let title = ToolHelpers.getString(arguments, key: "title")
        let note = ToolHelpers.getString(arguments, key: "note")
        let date = ToolHelpers.getString(arguments, key: "date")
        let cleared: Bool? = arguments?["cleared"].flatMap { v in
            if case .bool(let b) = v { return b }
            return nil
        }
        let transactionType = ToolHelpers.getString(arguments, key: "transaction_type")

        guard let updated = try transactions.update(
            transactionId: transactionId,
            title: title,
            note: note,
            date: date,
            cleared: cleared,
            transactionType: transactionType
        ) else {
            return ToolHelpers.errorResponse("Transaction not found: \(transactionId)")
        }

        return try ToolHelpers.jsonResponse(updated)
    }

    // delete_transaction
    registry.register(
        name: "delete_transaction",
        description: "Delete a transaction and all its line items",
        inputSchema: ToolHelpers.schema(
            properties: [
                "transaction_id": ToolHelpers.property(type: "number", description: "The transaction ID to delete"),
            ],
            required: ["transaction_id"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        guard let transactionId = ToolHelpers.getInt(arguments, key: "transaction_id") else {
            return ToolHelpers.errorResponse("transaction_id is required")
        }

        let deleted = try transactions.delete(transactionId: transactionId)
        if deleted {
            return ToolHelpers.successResponse("Transaction \(transactionId) deleted")
        }
        return ToolHelpers.errorResponse("Transaction not found: \(transactionId)")
    }
}
