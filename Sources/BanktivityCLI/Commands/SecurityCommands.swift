// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser
import BanktivityLib
import Foundation

struct Securities: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Security and price history operations",
        subcommands: [List.self, Create.self, Delete.self, Rename.self, Prices.self, ImportPrices.self, DeletePrices.self, ResetPriceRange.self, FixPrices.self, Holdings.self, Trades.self, RealizedGains.self, Income.self, CreateTrade.self, CreateIncome.self, Adjust.self, UpdateTrade.self]
    )

    struct Rename: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rename",
            abstract: "Rename a security's ticker, display name, or both",
            discussion: """
            The only way to correct a security's identity. `pSymbol` and `pName`
            were otherwise written only when the security was created, so one that
            arrived wrong stayed wrong.

            Refuses a symbol another security already holds -- that is a merge,
            which is a different operation with different evidence -- and refuses
            a blank value, because a security with no symbol is one of the defects
            this repairs.
            """
        )

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Current ticker symbol")
        var symbol: String?

        @Option(name: .long, help: "Security ID (alternative to --symbol)")
        var id: Int?

        @Option(name: .long, help: "New ticker symbol")
        var newSymbol: String?

        @Option(name: .long, help: "New display name")
        var newName: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let securities = SecurityRepository(
                container: container,
                syncBlobUpdater: SyncBlobUpdater(container: container)
            )
            let result = try securities.renameSecurity(
                symbol: symbol, id: id, newSymbol: newSymbol, newName: newName
            )
            try outputJSON(result, format: parent.format)
        }
    }

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

    struct ResetPriceRange: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "reset-price-range",
            abstract: "Forget which price history is known for a security, without deleting any of it",
            discussion: """
            Clears pKnownDateRangeBegin, pKnownDateRangeEnd and pLatestImportDate on
            the security's SecurityPriceItem. Every SecurityPrice row stays exactly
            where it is; only the record of what is known is cleared. The response
            reports the previous values and the surviving row count.
            """
        )

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Security ticker symbol")
        var symbol: String?

        @Option(name: .long, help: "Security ID (alternative to --symbol)")
        var id: Int?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let securities = SecurityRepository(container: container)
            guard let result = try securities.resetKnownPriceRange(symbol: symbol, id: id) else {
                throw ToolError.notFound("No price item for security: \(symbol ?? id.map(String.init) ?? "<none>")")
            }
            try outputJSON(result, format: parent.format)
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete a security record that no trade references",
            discussion: """
            Removes a security identity from the vault. A security that any trade
            still points at is refused: deleting it would orphan the line items
            carrying its cost basis and realized gain. Merge those trades onto the
            surviving security with 'securities update-trade --security-id' first.

            Price history is kept unless --with-prices is given, so a security that
            still has prices is refused rather than silently losing them.

            Use --dry-run to see what would be removed before writing.
            """
        )

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Security ticker symbol")
        var symbol: String?

        @Option(name: .long, help: "Security ID (alternative to --symbol)")
        var id: Int?

        @Flag(name: .long, help: "Also delete the security's price history")
        var withPrices: Bool = false

        @Flag(name: .long, help: "Report what would be deleted without writing")
        var dryRun: Bool = false

        func run() async throws {
            guard symbol != nil || id != nil else {
                throw ValidationError("Provide --symbol or --id")
            }
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let syncBlobUpdater = SyncBlobUpdater(container: container)
            let securities = SecurityRepository(container: container, syncBlobUpdater: syncBlobUpdater)

            guard let info = try securities.inspectForDeletion(symbol: symbol, id: id) else {
                throw ToolError.notFound("Security not found: \(symbol ?? String(id ?? 0))")
            }

            if dryRun {
                let refusal: String?
                if info.tradeCount > 0 {
                    refusal = "\(info.tradeCount) trade line item(s) reference this security. Re-point them with 'securities update-trade --security-id' first."
                } else if info.priceCount > 0 && !withPrices {
                    refusal = "\(info.priceCount) price record(s) would be left behind. Pass --with-prices to remove them along with the security."
                } else {
                    refusal = nil
                }
                try outputJSON([
                    "operation": "securities.delete",
                    "securityId": info.securityId,
                    "symbol": info.symbol,
                    "name": info.name,
                    "tradeCount": info.tradeCount,
                    "priceCount": info.priceCount,
                    "withPrices": withPrices,
                    "wouldWrite": refusal == nil,
                    "warnings": refusal.map { ["Deletion refused: \($0)"] }
                        ?? ["Dry-run only; no Core Data write was performed."],
                ] as [String: Any], format: parent.format)
                return
            }

            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let deleted = try securities.deleteSecurity(symbol: symbol, id: id, withPrices: withPrices)
            guard deleted > 0 else {
                throw ToolError.notFound("Security \(info.securityId) was not deleted")
            }
            try outputJSON([
                "securityId": info.securityId,
                "symbol": info.symbol,
                "deleted": true,
                "pricesDeleted": withPrices ? info.priceCount : 0,
                "message": "Security \(info.securityId) (\(info.symbol)) deleted",
            ] as [String: Any], format: parent.format)
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

    struct RealizedGains: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "realized-gains",
            abstract: "Compute realised capital gains by matching disposals to opening lots (FIFO)")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Security ticker symbol")
        var symbol: String?

        @Option(name: .long, help: "Security ID (alternative to --symbol)")
        var id: Int?

        @Option(name: .long, help: "Filter to a specific account ID")
        var accountId: Int?

        @Option(name: .long, help: "Earliest disposal date (YYYY-MM-DD)")
        var startDate: String?

        @Option(name: .long, help: "Latest disposal date (YYYY-MM-DD)")
        var endDate: String?

        @Option(name: .long, help: "Maximum number of rows to return")
        var limit: Int?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let securities = SecurityRepository(container: container)
            let results = try securities.getRealizedGains(
                accountId: accountId, symbol: symbol, id: id,
                startDate: startDate, endDate: endDate, limit: limit
            )
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

    struct CreateTrade: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create-trade",
            abstract: "Create a security buy/sell transaction with cash and balancing line items"
        )

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Investment account ID")
        var accountId: Int

        @Option(name: .long, help: "Security ticker symbol")
        var symbol: String?

        @Option(name: .long, help: "Security ID (alternative to --symbol)")
        var id: Int?

        @Option(name: .long, parsing: .unconditional, help: "Number of shares. Negative creates a sell; positive creates a buy")
        var shares: Double

        @Option(name: .long, help: "Price per share")
        var pricePerShare: Double

        @Option(name: .long, parsing: .unconditional, help: "Security trade amount/cost")
        var amount: Double

        @Option(name: .long, help: "Commission or fee amount")
        var commission: Double = 0

        @Option(name: .long, parsing: .unconditional, help: "Investment account cash line amount. Positive for sell inflow, negative for buy outflow")
        var cashLineAmount: Double

        @Option(name: .long, help: "Date of trade (YYYY-MM-DD)")
        var date: String

        @Option(name: .long, help: "Transaction title")
        var title: String?

        @Option(name: .long, help: "Cash line memo")
        var memo: String?

        @Option(name: .long, help: "Income/expense category ID for the balancing line. Defaults to an unknown balancing line")
        var offsetCategoryId: Int?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let syncBlobUpdater = SyncBlobUpdater(container: container)
            let securities = SecurityRepository(container: container, syncBlobUpdater: syncBlobUpdater)
            let result = try securities.createSecurityTrade(
                accountId: accountId,
                symbol: symbol,
                id: id,
                shares: shares,
                pricePerShare: pricePerShare,
                amount: amount,
                commission: commission,
                cashLineItemAmount: cashLineAmount,
                date: date,
                title: title,
                memo: memo,
                offsetCategoryId: offsetCategoryId
            )
            try outputJSON(result, format: parent.format)
        }
    }

    struct CreateIncome: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create-income",
            abstract: "Create a native investment income transaction for a security"
        )

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Investment account ID")
        var accountId: Int

        @Option(name: .long, help: "Security ticker symbol")
        var symbol: String?

        @Option(name: .long, help: "Security ID (alternative to --symbol)")
        var id: Int?

        @Option(name: .long, parsing: .unconditional, help: "Positive income amount")
        var amount: Double

        @Option(name: .long, help: "Income date (YYYY-MM-DD)")
        var date: String

        @Option(name: .long, help: "Transaction title")
        var title: String?

        @Option(name: .long, help: "Cash line memo")
        var memo: String?

        @Option(name: .long, help: "Income/expense category ID for the balancing line. Defaults to an unknown balancing line")
        var offsetCategoryId: Int?

        @Option(name: .long, help: "Income type. Accepts: \(SecurityRepository.incomeTypeNames)")
        var incomeType: String = "dividend"

        @Option(name: .long, help: "Tax withheld at source. --amount stays the GROSS: the account receives the net, the income category is credited the gross, and this sits on its own line")
        var withheldAmount: Double?

        @Option(name: .long, help: "Category ID for the withheld tax line (required with --withheld-amount)")
        var withholdingCategoryId: Int?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let syncBlobUpdater = SyncBlobUpdater(container: container)
            let securities = SecurityRepository(container: container, syncBlobUpdater: syncBlobUpdater)
            let result = try securities.createSecurityIncome(
                accountId: accountId,
                symbol: symbol,
                id: id,
                amount: amount,
                date: date,
                title: title,
                memo: memo,
                offsetCategoryId: offsetCategoryId,
                incomeType: incomeType,
                withheldAmount: withheldAmount,
                withholdingCategoryId: withholdingCategoryId
            )
            try outputJSON(result, format: parent.format)
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

        @Option(name: .long, help: "Movement type. Accepts: \(SecurityRepository.shareMovementTypeNames). Defaults to buy or sell by the sign of --shares")
        var transactionType: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let syncBlobUpdater = SyncBlobUpdater(container: container)
            let securities = SecurityRepository(container: container, syncBlobUpdater: syncBlobUpdater)
            let result = try securities.createShareAdjustment(
                accountId: accountId, symbol: symbol, id: id,
                shares: shares, date: date, title: title, amount: amount,
                transactionType: transactionType
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
