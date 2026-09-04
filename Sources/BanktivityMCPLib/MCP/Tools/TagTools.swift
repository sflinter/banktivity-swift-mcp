// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import BanktivityLib
import MCP

/// Register tag-related MCP tools
func registerTagTools(
    registry: ToolRegistry,
    tags: TagRepository,
    writeGuard: WriteGuard,
    transactions: TransactionRepository
) {
    // get_tags
    registry.register(
        name: "get_tags",
        access: .read,
        description: "List all tags used for transactions",
        inputSchema: ToolHelpers.schema(properties: [:])
    ) { _ in
        let results = try tags.list()
        return try ToolHelpers.jsonResponse(results)
    }

    // create_tag
    registry.register(
        name: "create_tag",
        access: .write,
        description: "Create a new tag for categorizing transactions",
        inputSchema: ToolHelpers.schema(
            properties: [
                "name": ToolHelpers.property(type: "string", description: "The tag name"),
            ],
            required: ["name"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        guard let name = ToolHelpers.getString(arguments, key: "name") else {
            return ToolHelpers.errorResponse("name is required")
        }

        let tag = try tags.create(name: name)
        return try ToolHelpers.jsonResponse(tag)
    }

    // tag_transaction
    registry.register(
        name: "tag_transaction",
        access: .write,
        description: "Add or remove a tag from a transaction",
        inputSchema: ToolHelpers.schema(
            properties: [
                "transaction_id": ToolHelpers.property(type: "number", description: "The transaction ID"),
                "tag_name": ToolHelpers.property(type: "string", description: "The tag name (will be created if it doesn't exist)"),
                "tag_id": ToolHelpers.property(type: "number", description: "The tag ID (alternative to tag_name)"),
                "action": ToolHelpers.property(type: "string", description: "Whether to 'add' or 'remove' the tag (default: add)"),
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

        let tagId = try tags.resolveTagId(
            id: ToolHelpers.getInt(arguments, key: "tag_id"),
            name: ToolHelpers.getString(arguments, key: "tag_name"),
            autoCreate: true
        )
        let action = ToolHelpers.getString(arguments, key: "action") ?? "add"
        _ = try tags.applyTag(transactionId: transactionId, tagId: tagId, action: action)

        if let tx = try transactions.get(transactionId: transactionId) {
            return try ToolHelpers.jsonResponse(tx)
        }
        return ToolHelpers.successResponse("Tag applied")
    }

    // get_transactions_by_tag
    registry.register(
        name: "get_transactions_by_tag",
        access: .read,
        description: "Find transactions that have a specific tag",
        inputSchema: ToolHelpers.schema(properties: [
            "tag_name": ToolHelpers.property(type: "string", description: "The tag name to search for"),
            "tag_id": ToolHelpers.property(type: "number", description: "The tag ID (alternative to tag_name)"),
            "start_date": ToolHelpers.property(type: "string", description: "Start date in ISO format (YYYY-MM-DD)"),
            "end_date": ToolHelpers.property(type: "string", description: "End date in ISO format (YYYY-MM-DD)"),
            "limit": ToolHelpers.property(type: "number", description: "Maximum number of transactions to return (default: 50)"),
        ])
    ) { arguments in
        let results = try tags.getTransactionDTOsByTag(
            tagId: ToolHelpers.getInt(arguments, key: "tag_id"),
            tagName: ToolHelpers.getString(arguments, key: "tag_name"),
            startDate: ToolHelpers.getString(arguments, key: "start_date"),
            endDate: ToolHelpers.getString(arguments, key: "end_date"),
            limit: ToolHelpers.getInt(arguments, key: "limit") ?? 50,
            transactionRepo: transactions
        )
        return try ToolHelpers.jsonResponse(results)
    }

    // bulk_tag_transactions
    registry.register(
        name: "bulk_tag_transactions",
        access: .write,
        description: "Add or remove a tag from multiple transactions at once",
        inputSchema: ToolHelpers.schema(
            properties: [
                "transaction_ids": ToolHelpers.property(type: "array", description: "Array of transaction IDs to tag"),
                "tag_name": ToolHelpers.property(type: "string", description: "The tag name (will be created if it doesn't exist)"),
                "tag_id": ToolHelpers.property(type: "number", description: "The tag ID (alternative to tag_name)"),
                "action": ToolHelpers.property(type: "string", description: "Whether to 'add' or 'remove' the tag (default: add)"),
            ],
            required: ["transaction_ids"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        guard let idsArray = ToolHelpers.getArray(arguments, key: "transaction_ids") else {
            return ToolHelpers.errorResponse("transaction_ids is required")
        }
        let transactionIds = idsArray.compactMap { v -> Int? in
            if case .int(let i) = v { return i }
            if case .double(let d) = v { return Int(d) }
            return nil
        }

        let tagId = try tags.resolveTagId(
            id: ToolHelpers.getInt(arguments, key: "tag_id"),
            name: ToolHelpers.getString(arguments, key: "tag_name"),
            autoCreate: true
        )
        let action = ToolHelpers.getString(arguments, key: "action") ?? "add"
        let totalCount = try tags.bulkApplyTag(transactionIds: transactionIds, tagId: tagId, action: action)

        return ToolHelpers.successResponse("\(action == "remove" ? "Removed" : "Added") tag on \(totalCount) line items across \(transactionIds.count) transactions")
    }
}
