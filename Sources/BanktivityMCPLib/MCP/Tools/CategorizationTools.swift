import Foundation
import MCP

/// Register categorization-related MCP tools
func registerCategorizationTools(
    registry: ToolRegistry,
    categorization: CategorizationRepository,
    categories: CategoryRepository,
    writeGuard: WriteGuard
) {
    // get_uncategorized_transactions
    registry.register(
        name: "get_uncategorized_transactions",
        description: "Find transactions without any category assigned. Useful for finding transactions that need categorization.",
        inputSchema: ToolHelpers.schema(properties: [
            "account_id": ToolHelpers.property(type: "number", description: "Filter by account ID"),
            "start_date": ToolHelpers.property(type: "string", description: "Start date in ISO format (YYYY-MM-DD)"),
            "end_date": ToolHelpers.property(type: "string", description: "End date in ISO format (YYYY-MM-DD)"),
            "limit": ToolHelpers.property(type: "number", description: "Maximum number of transactions to return (default: 50)"),
            "exclude_transfers": ToolHelpers.property(type: "boolean", description: "Exclude transfer transactions (default: true)"),
        ])
    ) { arguments in
        let accountId = ToolHelpers.getInt(arguments, key: "account_id")
        let startDate = ToolHelpers.getString(arguments, key: "start_date")
        let endDate = ToolHelpers.getString(arguments, key: "end_date")
        let limit = ToolHelpers.getInt(arguments, key: "limit") ?? 50
        let excludeTransfers = ToolHelpers.getBool(arguments, key: "exclude_transfers", default: true)

        let results = try categorization.getUncategorized(
            accountId: accountId,
            startDate: startDate,
            endDate: endDate,
            limit: limit,
            excludeTransfers: excludeTransfers
        )

        return try ToolHelpers.jsonResponse(results)
    }

    // suggest_category_for_merchant
    registry.register(
        name: "suggest_category_for_merchant",
        description: "Given a merchant name, suggest categories based on import rules and historical transaction patterns.",
        inputSchema: ToolHelpers.schema(
            properties: [
                "merchant_name": ToolHelpers.property(type: "string", description: "The merchant/payee name to look up"),
            ],
            required: ["merchant_name"]
        )
    ) { arguments in
        guard let merchantName = ToolHelpers.getString(arguments, key: "merchant_name") else {
            return ToolHelpers.errorResponse("merchant_name is required")
        }

        let suggestions = try categorization.suggestCategory(merchantName: merchantName)
        return try ToolHelpers.jsonResponse(suggestions)
    }

    // review_categorizations
    registry.register(
        name: "review_categorizations",
        description: "List transactions with their current category for review. Useful for spotting miscategorized transactions.",
        inputSchema: ToolHelpers.schema(properties: [
            "account_id": ToolHelpers.property(type: "number", description: "Filter by account ID"),
            "start_date": ToolHelpers.property(type: "string", description: "Start date in ISO format (YYYY-MM-DD)"),
            "end_date": ToolHelpers.property(type: "string", description: "End date in ISO format (YYYY-MM-DD)"),
            "category_id": ToolHelpers.property(type: "number", description: "Filter by category ID"),
            "category_name": ToolHelpers.property(type: "string", description: "Filter by category name or path"),
            "payee_pattern": ToolHelpers.property(type: "string", description: "Filter by payee/title pattern (partial match)"),
            "limit": ToolHelpers.property(type: "number", description: "Maximum number of transactions to return (default: 50)"),
        ])
    ) { arguments in
        let accountId = ToolHelpers.getInt(arguments, key: "account_id")
        let startDate = ToolHelpers.getString(arguments, key: "start_date")
        let endDate = ToolHelpers.getString(arguments, key: "end_date")
        let payeePattern = ToolHelpers.getString(arguments, key: "payee_pattern")
        let limit = ToolHelpers.getInt(arguments, key: "limit") ?? 50

        let categoryId = try categories.resolveId(
            categoryId: ToolHelpers.getInt(arguments, key: "category_id"),
            categoryName: ToolHelpers.getString(arguments, key: "category_name")
        )

        let results = try categorization.reviewCategorizations(
            accountId: accountId,
            categoryId: categoryId,
            payeePattern: payeePattern,
            startDate: startDate,
            endDate: endDate,
            limit: limit
        )

        return try ToolHelpers.jsonResponse(results)
    }

    // get_payee_category_summary
    registry.register(
        name: "get_payee_category_summary",
        description: "Aggregate view: for each distinct payee, show which categories were used and how often. Surfaces inconsistencies and uncategorized counts.",
        inputSchema: ToolHelpers.schema(properties: [
            "account_id": ToolHelpers.property(type: "number", description: "Filter by account ID"),
            "start_date": ToolHelpers.property(type: "string", description: "Start date in ISO format (YYYY-MM-DD)"),
            "end_date": ToolHelpers.property(type: "string", description: "End date in ISO format (YYYY-MM-DD)"),
            "min_transactions": ToolHelpers.property(type: "number", description: "Minimum number of transactions for a payee to be included (default: 1)"),
        ])
    ) { arguments in
        let accountId = ToolHelpers.getInt(arguments, key: "account_id")
        let startDate = ToolHelpers.getString(arguments, key: "start_date")
        let endDate = ToolHelpers.getString(arguments, key: "end_date")
        let minTransactions = ToolHelpers.getInt(arguments, key: "min_transactions") ?? 1

        let results = try categorization.getPayeeCategorySummary(
            accountId: accountId,
            startDate: startDate,
            endDate: endDate,
            minTransactions: minTransactions
        )

        return try ToolHelpers.jsonResponse(results)
    }

    // recategorize_transaction
    registry.register(
        name: "recategorize_transaction",
        description: "Change or assign a category on a single transaction",
        inputSchema: ToolHelpers.schema(
            properties: [
                "transaction_id": ToolHelpers.property(type: "number", description: "The transaction ID to recategorize"),
                "category_id": ToolHelpers.property(type: "number", description: "The category ID to assign"),
                "category_name": ToolHelpers.property(type: "string", description: "The category name or path (alternative to category_id)"),
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

        guard let categoryId = try categories.resolveId(
            categoryId: ToolHelpers.getInt(arguments, key: "category_id"),
            categoryName: ToolHelpers.getString(arguments, key: "category_name")
        ) else {
            return ToolHelpers.errorResponse("Either category_id or category_name is required")
        }

        guard let result = try categorization.recategorize(transactionId: transactionId, categoryId: categoryId) else {
            return ToolHelpers.errorResponse("Transaction not found: \(transactionId)")
        }

        return try ToolHelpers.jsonResponse(result)
    }

    // bulk_recategorize_by_payee
    registry.register(
        name: "bulk_recategorize_by_payee",
        description: "Recategorize all transactions matching a payee pattern. Supports dry_run mode to preview changes.",
        inputSchema: ToolHelpers.schema(
            properties: [
                "payee_pattern": ToolHelpers.property(type: "string", description: "Payee/title pattern to match"),
                "category_id": ToolHelpers.property(type: "number", description: "The category ID to assign"),
                "category_name": ToolHelpers.property(type: "string", description: "The category name or path (alternative to category_id)"),
                "dry_run": ToolHelpers.property(type: "boolean", description: "If true, return what would change without making changes"),
                "uncategorized_only": ToolHelpers.property(type: "boolean", description: "If true, only recategorize uncategorized transactions"),
            ],
            required: ["payee_pattern"]
        )
    ) { arguments in
        guard let payeePattern = ToolHelpers.getString(arguments, key: "payee_pattern") else {
            return ToolHelpers.errorResponse("payee_pattern is required")
        }
        guard let categoryId = try categories.resolveId(
            categoryId: ToolHelpers.getInt(arguments, key: "category_id"),
            categoryName: ToolHelpers.getString(arguments, key: "category_name")
        ) else {
            return ToolHelpers.errorResponse("Either category_id or category_name is required")
        }

        let dryRun = ToolHelpers.getBool(arguments, key: "dry_run")
        let uncategorizedOnly = ToolHelpers.getBool(arguments, key: "uncategorized_only")

        if !dryRun {
            if let msg = await writeGuard.guardWriteAccess() {
                return ToolHelpers.errorResponse(msg)
            }
        }

        let result = try categorization.bulkRecategorize(
            payeePattern: payeePattern,
            categoryId: categoryId,
            dryRun: dryRun,
            uncategorizedOnly: uncategorizedOnly
        )

        return try ToolHelpers.jsonResponse(result)
    }
}
