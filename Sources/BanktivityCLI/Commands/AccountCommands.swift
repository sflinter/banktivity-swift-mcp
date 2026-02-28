// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser
import BanktivityLib
import Foundation

struct Accounts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Account operations",
        subcommands: [List.self, Balance.self, NetWorth.self, Spending.self, Income.self, Summary.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all accounts")

        @OptionGroup var parent: VaultOption

        @Flag(name: .long, help: "Include hidden accounts")
        var includeHidden = false

        @Flag(name: .long, help: "Include income/expense categories")
        var includeCategories = false

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let accounts = AccountRepository(container: container)

            var accountList = try accounts.list(includeHidden: includeHidden)

            if !includeCategories {
                accountList = accountList.filter { $0.accountClass < 6000 }
            }

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
                    "formattedBalance": formatCurrency(balance, currency: account.currency ?? "EUR"),
                ]
                if let currency = account.currency {
                    dict["currency"] = currency
                }
                return dict
            }

            try outputJSON(accountsWithBalances)
        }
    }

    struct Balance: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get account balance")

        @OptionGroup var parent: VaultOption

        @Option(name: .long, help: "Account ID")
        var accountId: Int?

        @Option(name: .long, help: "Account name (alternative to --account-id)")
        var accountName: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let accounts = AccountRepository(container: container)

            let resolvedId = try accounts.resolveAccountId(id: accountId, name: accountName)
            let balance = try accounts.getBalance(accountId: resolvedId)
            let account = try accounts.get(accountId: resolvedId)

            try outputJSON([
                "accountId": resolvedId,
                "accountName": account?.name ?? "Unknown",
                "balance": balance,
                "formattedBalance": formatCurrency(balance, currency: account?.currency ?? "EUR"),
            ] as [String: Any])
        }
    }

    struct NetWorth: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Calculate net worth")

        @OptionGroup var parent: VaultOption

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let accounts = AccountRepository(container: container)

            let netWorth = try accounts.getNetWorth()
            try outputJSON(netWorth)
        }
    }

    struct Spending: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get spending by category")

        @OptionGroup var parent: VaultOption

        @Option(name: .long, help: "Start date (YYYY-MM-DD)")
        var startDate: String?

        @Option(name: .long, help: "End date (YYYY-MM-DD)")
        var endDate: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let accounts = AccountRepository(container: container)

            let spending = try accounts.getCategoryAnalysis(
                type: "expense", startDate: startDate, endDate: endDate
            )
            try outputJSON(spending)
        }
    }

    struct Income: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get income by category")

        @OptionGroup var parent: VaultOption

        @Option(name: .long, help: "Start date (YYYY-MM-DD)")
        var startDate: String?

        @Option(name: .long, help: "End date (YYYY-MM-DD)")
        var endDate: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let accounts = AccountRepository(container: container)

            let income = try accounts.getCategoryAnalysis(
                type: "income", startDate: startDate, endDate: endDate
            )
            try outputJSON(income)
        }
    }

    struct Summary: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get vault summary")

        @OptionGroup var parent: VaultOption

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let accounts = AccountRepository(container: container)
            let tags = TagRepository(container: container)

            let allAccounts = try accounts.list(includeHidden: true)
            let netWorth = try accounts.getNetWorth()
            let bankAccounts = allAccounts.filter { $0.accountClass < 6000 }
            let incomeCategories = allAccounts.filter { $0.accountClass == AccountClass.income }
            let expenseCategories = allAccounts.filter { $0.accountClass == AccountClass.expense }
            let tagCount = try tags.list().count

            let accountsSummary: [String: Any] = [
                "total": bankAccounts.count,
                "checking": bankAccounts.filter { $0.accountClass == AccountClass.checking }.count,
                "savings": bankAccounts.filter { $0.accountClass == AccountClass.savings }.count,
                "creditCards": bankAccounts.filter { $0.accountClass == AccountClass.creditCard }.count,
            ]
            let categoriesSummary: [String: Any] = [
                "income": incomeCategories.count,
                "expense": expenseCategories.count,
            ]
            let netWorthSummary: [String: Any] = [
                "assets": netWorth.assets,
                "liabilities": netWorth.liabilities,
                "netWorth": netWorth.netWorth,
                "formattedAssets": netWorth.formattedAssets ?? "",
                "formattedLiabilities": netWorth.formattedLiabilities ?? "",
                "formattedNetWorth": netWorth.formattedNetWorth ?? "",
            ]
            let summary: [String: Any] = [
                "accounts": accountsSummary,
                "categories": categoriesSummary,
                "tags": tagCount,
                "netWorth": netWorthSummary,
            ]
            try outputJSON(summary)
        }
    }
}
