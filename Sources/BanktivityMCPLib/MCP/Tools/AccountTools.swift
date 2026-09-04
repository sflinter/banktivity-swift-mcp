// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import BanktivityLib
import MCP

/// Register account-related MCP tools
func registerAccountTools(registry: ToolRegistry, accounts: AccountRepository, tags: TagRepository) {
    // list_accounts
    registry.register(
        name: "list_accounts",
        access: .read,
        description: "List all accounts in Banktivity with their types and current balances",
        inputSchema: ToolHelpers.schema(properties: [
            "include_hidden": ToolHelpers.property(type: "boolean", description: "Include hidden accounts"),
            "include_categories": ToolHelpers.property(type: "boolean", description: "Include income/expense categories"),
        ])
    ) { arguments in
        let includeHidden = ToolHelpers.getBool(arguments, key: "include_hidden")
        let includeCategories = ToolHelpers.getBool(arguments, key: "include_categories")

        let result = try accounts.listWithBalances(
            includeHidden: includeHidden,
            includeCategories: includeCategories
        )
        return try ToolHelpers.jsonResponse(result)
    }

    // get_account_balance
    registry.register(
        name: "get_account_balance",
        access: .read,
        description: "Get the current balance for a specific account",
        inputSchema: ToolHelpers.schema(properties: [
            "account_id": ToolHelpers.property(type: "number", description: "The account ID"),
            "account_name": ToolHelpers.property(type: "string", description: "The account name (alternative to account_id)"),
        ])
    ) { arguments in
        let accountId = try resolveAccountId(accounts: accounts, arguments: arguments)

        let balance = try accounts.getBalance(accountId: accountId)
        let account = try accounts.get(accountId: accountId)

        return ToolHelpers.jsonResponse([
            "accountId": accountId,
            "accountName": account?.name ?? "Unknown",
            "balance": balance,
            "formattedBalance": ToolHelpers.formatCurrency(balance, currency: account?.currency ?? "EUR"),
        ] as [String: Any])
    }

    // get_spending_by_category
    registry.register(
        name: "get_spending_by_category",
        access: .read,
        description: "Get spending breakdown by expense category",
        inputSchema: ToolHelpers.schema(properties: [
            "start_date": ToolHelpers.property(type: "string", description: "Start date in ISO format (YYYY-MM-DD)"),
            "end_date": ToolHelpers.property(type: "string", description: "End date in ISO format (YYYY-MM-DD)"),
        ])
    ) { arguments in
        let startDate = ToolHelpers.getString(arguments, key: "start_date")
        let endDate = ToolHelpers.getString(arguments, key: "end_date")

        let spending = try accounts.getCategoryAnalysis(
            type: "expense", startDate: startDate, endDate: endDate
        )
        return try ToolHelpers.jsonResponse(spending)
    }

    // get_income_by_category
    registry.register(
        name: "get_income_by_category",
        access: .read,
        description: "Get income breakdown by income category",
        inputSchema: ToolHelpers.schema(properties: [
            "start_date": ToolHelpers.property(type: "string", description: "Start date in ISO format (YYYY-MM-DD)"),
            "end_date": ToolHelpers.property(type: "string", description: "End date in ISO format (YYYY-MM-DD)"),
        ])
    ) { arguments in
        let startDate = ToolHelpers.getString(arguments, key: "start_date")
        let endDate = ToolHelpers.getString(arguments, key: "end_date")

        let income = try accounts.getCategoryAnalysis(
            type: "income", startDate: startDate, endDate: endDate
        )
        return try ToolHelpers.jsonResponse(income)
    }

    // get_net_worth
    registry.register(
        name: "get_net_worth",
        access: .read,
        description: "Calculate current net worth (assets minus liabilities)",
        inputSchema: ToolHelpers.schema(properties: [:])
    ) { _ in
        let netWorth = try accounts.getNetWorth()
        return try ToolHelpers.jsonResponse(netWorth)
    }

    // get_summary
    registry.register(
        name: "get_summary",
        access: .read,
        description: "Get a summary of the Banktivity database including account counts and transaction totals",
        inputSchema: ToolHelpers.schema(properties: [:])
    ) { [weak tags] _ in
        let tagCount = try tags?.list().count ?? 0
        let summary = try accounts.getSummary(tagCount: tagCount)
        return try ToolHelpers.jsonResponse(summary)
    }
}

// MARK: - Account Resolution Helper

func resolveAccountId(
    accounts: AccountRepository,
    arguments: [String: Value]?
) throws -> Int {
    try accounts.resolveAccountId(
        id: ToolHelpers.getInt(arguments, key: "account_id"),
        name: ToolHelpers.getString(arguments, key: "account_name")
    )
}
