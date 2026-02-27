import Foundation
import MCP

/// Register account-related MCP tools
func registerAccountTools(registry: ToolRegistry, accounts: AccountRepository, tags: TagRepository) {
    // list_accounts
    registry.register(
        name: "list_accounts",
        description: "List all accounts in Banktivity with their types and current balances",
        inputSchema: ToolHelpers.schema(properties: [
            "include_hidden": ToolHelpers.property(type: "boolean", description: "Include hidden accounts"),
            "include_categories": ToolHelpers.property(type: "boolean", description: "Include income/expense categories"),
        ])
    ) { arguments in
        let includeHidden = ToolHelpers.getBool(arguments, key: "include_hidden")
        let includeCategories = ToolHelpers.getBool(arguments, key: "include_categories")

        var accountList = try accounts.list(includeHidden: includeHidden)

        if !includeCategories {
            accountList = accountList.filter { $0.accountClass < 6000 }
        }

        // Add balances
        let accountsWithBalances: [[String: Any]] = try accountList.map { account in
            let balance = try accounts.getBalance(accountId: account.id)
            var dict: [String: Any] = [
                "id": account.id,
                "name": account.name,
                "fullName": account.fullName,
                "accountClass": account.accountClass,
                "accountType": account.accountType,
                "hidden": account.hidden,
                "balance": balance,
                "formattedBalance": ToolHelpers.formatCurrency(balance, currency: account.currency ?? "EUR"),
            ]
            if let currency = account.currency {
                dict["currency"] = currency
            }
            return dict
        }

        return ToolHelpers.jsonResponse(accountsWithBalances)
    }

    // get_account_balance
    registry.register(
        name: "get_account_balance",
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
        description: "Calculate current net worth (assets minus liabilities)",
        inputSchema: ToolHelpers.schema(properties: [:])
    ) { _ in
        let netWorth = try accounts.getNetWorth()
        return try ToolHelpers.jsonResponse(netWorth)
    }

    // get_summary
    registry.register(
        name: "get_summary",
        description: "Get a summary of the Banktivity database including account counts and transaction totals",
        inputSchema: ToolHelpers.schema(properties: [:])
    ) { [weak tags] _ in
        let allAccounts = try accounts.list(includeHidden: true)
        let netWorth = try accounts.getNetWorth()

        let bankAccounts = allAccounts.filter { $0.accountClass < 6000 }
        let incomeCategories = allAccounts.filter { $0.accountClass == AccountClass.income }
        let expenseCategories = allAccounts.filter { $0.accountClass == AccountClass.expense }

        let tagCount = try tags?.list().count ?? 0

        let summary: [String: Any] = [
            "accounts": [
                "total": bankAccounts.count,
                "checking": bankAccounts.filter { $0.accountClass == AccountClass.checking }.count,
                "savings": bankAccounts.filter { $0.accountClass == AccountClass.savings }.count,
                "creditCards": bankAccounts.filter { $0.accountClass == AccountClass.creditCard }.count,
            ],
            "categories": [
                "income": incomeCategories.count,
                "expense": expenseCategories.count,
            ],
            "tags": tagCount,
            "netWorth": [
                "assets": netWorth.assets,
                "liabilities": netWorth.liabilities,
                "netWorth": netWorth.netWorth,
                "formattedAssets": netWorth.formattedAssets ?? "",
                "formattedLiabilities": netWorth.formattedLiabilities ?? "",
                "formattedNetWorth": netWorth.formattedNetWorth ?? "",
            ],
        ]

        return ToolHelpers.jsonResponse(summary)
    }
}

// MARK: - Account Resolution Helper

func resolveAccountId(
    accounts: AccountRepository,
    arguments: [String: Value]?
) throws -> Int {
    if let id = ToolHelpers.getInt(arguments, key: "account_id") {
        return id
    }

    if let name = ToolHelpers.getString(arguments, key: "account_name") {
        if let account = try accounts.findByName(name) {
            return account.id
        }
        throw ToolError.notFound("Account not found: \(name)")
    }

    throw ToolError.missingParameter("Either account_id or account_name is required")
}

enum ToolError: Error, CustomStringConvertible {
    case notFound(String)
    case missingParameter(String)
    case writeBlocked(String)
    case invalidInput(String)

    var description: String {
        switch self {
        case .notFound(let msg): return msg
        case .missingParameter(let msg): return msg
        case .writeBlocked(let msg): return msg
        case .invalidInput(let msg): return msg
        }
    }
}
