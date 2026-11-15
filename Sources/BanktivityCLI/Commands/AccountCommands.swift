// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser
import BanktivityLib
import Foundation

struct Accounts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Account operations",
        subcommands: [List.self, Balance.self, NetWorth.self, Spending.self, Income.self, Summary.self, Create.self, RecalcBalances.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all accounts")

        @OptionGroup var parent: GlobalOptions

        @Flag(name: .long, help: "Include hidden accounts")
        var includeHidden = false

        @Flag(name: .long, help: "Include income/expense categories")
        var includeCategories = false

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let accounts = AccountRepository(container: container)

            let result = try accounts.listWithBalances(
                includeHidden: includeHidden,
                includeCategories: includeCategories
            )
            try outputJSON(result, format: parent.format)
        }
    }

    struct RecalcBalances: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "recalc-balances",
            abstract: "Recompute cached running balances, as Banktivity does",
            discussion: """
            Banktivity's desktop app shows an account's cash from the running balance
            cached on its latest line item. Rows written by this CLI leave that cache
            stale. This recomputes it in Banktivity's order and with its line amount
            rule. The cache is not synced, so nothing is marked modified.
            """
        )

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Account ID (repeatable)")
        var accountId: [Int] = []

        @Flag(name: .long, help: "Recompute every non-category account")
        var all = false

        @Flag(name: .long, help: "Rewrite intermediate rows even when the final balance is already right")
        var force = false

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let accounts = AccountRepository(container: container)
            var ids = accountId
            if all {
                ids = try accounts.list(includeHidden: true)
                    .filter { $0.accountClass < AccountClass.income }.map(\.id)
            }
            guard !ids.isEmpty else { throw ToolError.missingParameter("Give --account-id or --all") }
            let results = try ids.map { try accounts.recalculateRunningBalances(accountId: $0, force: force) }
            try outputJSON(results, format: parent.format)
        }
    }

    struct Balance: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get account balance")

        @OptionGroup var parent: GlobalOptions

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

            var result: [String: Any] = [
                "accountId": resolvedId,
                "accountName": account?.name ?? "Unknown",
                "balance": balance,
                "formattedBalance": formatCurrency(balance, currency: account?.currency ?? "EUR"),
            ]
            if let holdings = try accounts.holdingsValue(accountId: resolvedId) {
                result["holdingsValue"] = holdings
                result["formattedHoldingsValue"] = formatCurrency(holdings, currency: account?.currency ?? "EUR")
            }
            try outputJSON(result, format: parent.format)
        }
    }

    struct NetWorth: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Calculate net worth")

        @OptionGroup var parent: GlobalOptions

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let accounts = AccountRepository(container: container)

            let netWorth = try accounts.getNetWorth()
            if !netWorth.complete {
                let names = netWorth.excludedAccounts.map { "\($0.name) (\($0.currency))" }.joined(separator: ", ")
                FileHandle.standardError.write(Data("warning: net worth is INCOMPLETE: \(netWorth.excludedAccounts.count) account(s) left out for lack of an exchange rate: \(names)\n".utf8))
            }
            try outputJSON(netWorth, format: parent.format)
        }
    }

    struct Spending: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get spending by category")

        @OptionGroup var parent: GlobalOptions

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
            try outputJSON(spending, format: parent.format)
        }
    }

    struct Income: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get income by category")

        @OptionGroup var parent: GlobalOptions

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
            try outputJSON(income, format: parent.format)
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a bank account")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Account name")
        var name: String

        @Option(name: .long, help: "Account type (checking, savings, cash, money-market, investment, ira, 401k, credit-card, loan, mortgage, real-estate)")
        var type: String = "savings"

        @Option(name: .long, help: "Currency code (e.g. EUR, USD)")
        var currencyCode: String = "EUR"

        @Flag(name: .long, help: "Create as hidden")
        var hidden = false

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let accounts = AccountRepository(container: container)

            let typeMap: [String: Int] = [
                "asset": AccountClass.asset,
                "real-estate": AccountClass.realEstate,
                "automobile": AccountClass.automobile,
                "collectible": AccountClass.collectible,
                "artwork": AccountClass.artwork,
                "cash": AccountClass.cash,
                "checking": AccountClass.checking,
                "savings": AccountClass.savings,
                "money-market": AccountClass.moneyMarket,
                "certificate-of-deposit": AccountClass.certificateOfDeposit,
                "cd": AccountClass.certificateOfDeposit,
                "health-savings-account": AccountClass.healthSavingsAccount,
                "hsa": AccountClass.healthSavingsAccount,
                "current": AccountClass.current,
                "investment": AccountClass.investment,
                "ira": AccountClass.ira,
                "sep": AccountClass.sep,
                "401k": AccountClass.fourOhOneK,
                "403b": AccountClass.fourOhThreeB,
                "college-savings-529": AccountClass.collegeSavings529,
                "529": AccountClass.collegeSavings529,
                "mutual-fund": AccountClass.mutualFund,
                "rrsp": AccountClass.rrsp,
                "resp": AccountClass.resp,
                "tfsa": AccountClass.tfsa,
                "hsa-investment": AccountClass.hsaInvestment,
                "liability": AccountClass.liability,
                "loan": AccountClass.loan,
                "mortgage": AccountClass.mortgage,
                "student-loan": AccountClass.studentLoan,
                "auto-loan": AccountClass.autoLoan,
                "revolving-debt": AccountClass.revolvingDebt,
                "credit-card": AccountClass.creditCard,
                "line-of-credit": AccountClass.lineOfCredit,
                "heloc": AccountClass.heloc,
                "equity": AccountClass.equity,
            ]

            guard let accountClass = typeMap[type] else {
                throw ValidationError("Unknown account type '\(type)'. Valid types: \(typeMap.keys.sorted().joined(separator: ", "))")
            }

            let result = try accounts.create(
                name: name,
                accountClass: accountClass,
                currencyCode: currencyCode,
                hidden: hidden
            )
            try outputJSON(result, format: parent.format)
        }
    }

    struct Summary: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get vault summary")

        @OptionGroup var parent: GlobalOptions

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let accounts = AccountRepository(container: container)
            let tags = TagRepository(container: container)

            let summary = try accounts.getSummary(tagCount: try tags.list().count)
            try outputJSON(summary, format: parent.format)
        }
    }
}
