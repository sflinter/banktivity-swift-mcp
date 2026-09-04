// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser
import BanktivityLib
import Foundation

struct Securities: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Security and price history operations",
        subcommands: [List.self, Create.self, Prices.self, ImportPrices.self, DeletePrices.self, FixPrices.self, Holdings.self, Trades.self, Income.self, Adjust.self, UpdateTrade.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all securities")

        @OptionGroup var parent: GlobalOptions

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let securities = SecurityRepository(container: container)
            let results = try securities.listSecurities()
            try outputJSON(results, format: parent.format)
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a new security")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Ticker symbol")
        var symbol: String

        @Option(name: .long, help: "Security name")
        var name: String

        @Option(name: .long, help: "Currency code (default: EUR)")
        var currency: String = "EUR"

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let securities = SecurityRepository(container: container)
            let result = try securities.createSecurity(
                symbol: symbol, name: name, currencyCode: currency
            )
            try outputJSON(result, format: parent.format)
        }
    }

    struct Prices: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get price history for a security")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Security ticker symbol")
        var symbol: String?

        @Option(name: .long, help: "Security ID (alternative to --symbol)")
        var id: Int?

        @Option(name: .long, help: "Start date (YYYY-MM-DD)")
        var startDate: String?

        @Option(name: .long, help: "End date (YYYY-MM-DD)")
        var endDate: String?

        @Option(name: .long, help: "Maximum number of prices")
        var limit: Int?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let securities = SecurityRepository(container: container)
            let results = try securities.getPrices(
                symbol: symbol, id: id,
                startDate: startDate, endDate: endDate,
                limit: limit
            )
            try outputJSON(results, format: parent.format)
        }
    }

    struct ImportPrices: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import-prices",
            abstract: "Import security prices from a CSV file"
        )

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Security ticker symbol")
        var symbol: String?

        @Option(name: .long, help: "Security ID (alternative to --symbol)")
        var id: Int?

        @Option(name: .long, help: "Path to CSV file")
        var file: String

        @Flag(name: .long, help: "CSV has no header row")
        var noHeader: Bool = false

        @Option(name: .long, help: "Date format (default: yyyy-MM-dd)")
        var dateFormat: String = "yyyy-MM-dd"

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let syncBlobUpdater = SyncBlobUpdater(container: container)
            let securities = SecurityRepository(container: container, syncBlobUpdater: syncBlobUpdater)
            let result = try securities.importPricesFromCSV(
                filePath: file,
                symbol: symbol, id: id,
                hasHeader: !noHeader,
                dateFormat: dateFormat
            )
            try outputJSON(result, format: parent.format)
        }
    }

    struct DeletePrices: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete-prices",
            abstract: "Delete price history for a security"
        )

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Security ticker symbol")
        var symbol: String?

        @Option(name: .long, help: "Security ID (alternative to --symbol)")
        var id: Int?

        @Option(name: .long, help: "Start date (YYYY-MM-DD)")
        var startDate: String?

        @Option(name: .long, help: "End date (YYYY-MM-DD)")
        var endDate: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let securities = SecurityRepository(container: container)
            let count = try securities.deletePrices(
                symbol: symbol, id: id,
                startDate: startDate, endDate: endDate
            )
            try outputJSON(["message": "Deleted \(count) price(s)"] as [String: Any], format: parent.format)
        }
    }

    struct FixPrices: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "fix-prices",
            abstract: "Fix price records where closePrice=0 but adjustedClosePrice has the value"
        )

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Only fix prices for this symbol")
        var symbol: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let syncBlobUpdater = SyncBlobUpdater(container: container)
            let securities = SecurityRepository(container: container, syncBlobUpdater: syncBlobUpdater)
            let results = try securities.fixBrokenPrices(symbol: symbol)

            let total = results.reduce(0) { $0 + $1.fixed }
            var output: [String: Any] = [
                "total": total,
                "securities": results.map { ["symbol": $0.symbol, "fixed": $0.fixed] }
            ]
            if results.isEmpty {
                output["message"] = "No broken prices found"
            } else {
                output["message"] = "Fixed \(total) price(s) across \(results.count) security/securities"
            }
            try outputJSON(output, format: parent.format)
        }
    }

    struct Holdings: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show current security holdings (positions)")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Security ticker symbol")
        var symbol: String?

        @Option(name: .long, help: "Security ID (alternative to --symbol)")
        var id: Int?

        @Option(name: .long, help: "Filter to a specific account ID")
        var accountId: Int?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let securities = SecurityRepository(container: container)
            let results = try securities.getHoldings(accountId: accountId, symbol: symbol, id: id)
            try outputJSON(results, format: parent.format)
        }
    }

    struct Trades: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show security trade history (buys, sells, transfers)")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Security ticker symbol")
        var symbol: String?

        @Option(name: .long, help: "Security ID (alternative to --symbol)")
        var id: Int?

        @Option(name: .long, help: "Filter to a specific account ID")
        var accountId: Int?

        @Option(name: .long, help: "Start date (YYYY-MM-DD)")
        var startDate: String?

        @Option(name: .long, help: "End date (YYYY-MM-DD)")
        var endDate: String?

        @Option(name: .long, help: "Maximum number of trades to return")
        var limit: Int?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let securities = SecurityRepository(container: container)
            let results = try securities.getTrades(
                accountId: accountId, symbol: symbol, id: id,
                startDate: startDate, endDate: endDate, limit: limit
            )
            try outputJSON(results, format: parent.format)
        }
    }

    struct Income: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show investment income (dividends, interest, capital gains)")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Security ticker symbol")
        var symbol: String?

        @Option(name: .long, help: "Security ID (alternative to --symbol)")
        var id: Int?

        @Option(name: .long, help: "Filter to a specific account ID")
        var accountId: Int?

        @Option(name: .long, help: "Start date (YYYY-MM-DD)")
        var startDate: String?

        @Option(name: .long, help: "End date (YYYY-MM-DD)")
        var endDate: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let securities = SecurityRepository(container: container)
            let results = try securities.getIncome(
                accountId: accountId, symbol: symbol, id: id,
                startDate: startDate, endDate: endDate
            )
            try outputJSON(results, format: parent.format)
        }
    }

    struct Adjust: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a share adjustment transaction (e.g. for charges)")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Security ticker symbol")
        var symbol: String?

        @Option(name: .long, help: "Security ID (alternative to --symbol)")
        var id: Int?

        @Option(name: .long, help: "Account ID")
        var accountId: Int

        @Option(name: .long, parsing: .unconditional, help: "Number of shares to adjust (negative to reduce)")
        var shares: Double

        @Option(name: .long, help: "Date of adjustment (YYYY-MM-DD)")
        var date: String

        @Option(name: .long, help: "Transaction title")
        var title: String?

        @Option(name: .long, parsing: .unconditional, help: "Security cost/principal amount. This does not change investment-account cash line items unless --cash-line-amount is also supplied")
        var amount: Double?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let syncBlobUpdater = SyncBlobUpdater(container: container)
            let securities = SecurityRepository(container: container, syncBlobUpdater: syncBlobUpdater)
            let result = try securities.createShareAdjustment(
                accountId: accountId, symbol: symbol, id: id,
                shares: shares, date: date, title: title, amount: amount
            )
            try outputJSON(result, format: parent.format)
        }
    }

    struct UpdateTrade: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "update-trade",
            abstract: "Update security line item fields (shares, price, amount, commission, security, cash line) on an existing transaction"
        )

        @OptionGroup var parent: GlobalOptions

        @Argument(help: "Transaction ID")
        var transactionId: Int

        @Option(name: .long, parsing: .unconditional, help: "Number of shares")
        var shares: Double?

        @Option(name: .long, help: "Price per share")
        var pricePerShare: Double?

        @Option(name: .long, parsing: .unconditional, help: "Security cost/principal amount. This does not change investment-account cash line items unless --cash-line-amount is also supplied")
        var amount: Double?

        @Option(name: .long, help: "Commission or fee amount")
        var commission: Double?

        @Option(name: .long, help: "Security ticker symbol")
        var symbol: String?

        @Option(name: .long, help: "Security ID (alternative to --symbol)")
        var securityId: Int?

        @Option(name: .long, parsing: .unconditional, help: "Also set the investment account cash line item to this amount and the balancing line item to the opposite amount")
        var cashLineAmount: Double?

        @Flag(name: .long, help: "Validate a zero-cash transfer-in row and update security basis fields without changing cash line items")
        var basisOnlyTransfer: Bool = false

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let syncBlobUpdater = SyncBlobUpdater(container: container)
            let securities = SecurityRepository(container: container, syncBlobUpdater: syncBlobUpdater)
            let result = try securities.updateSecurityLineItem(
                transactionId: transactionId,
                shares: shares, pricePerShare: pricePerShare, amount: amount,
                commission: commission,
                securitySymbol: symbol, securityId: securityId,
                cashLineItemAmount: cashLineAmount,
                basisOnlyTransfer: basisOnlyTransfer
            )
            try outputJSON(result, format: parent.format)
        }
    }
}
