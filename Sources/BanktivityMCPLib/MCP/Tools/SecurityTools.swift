// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import BanktivityLib
import MCP

func registerSecurityTools(
    registry: ToolRegistry,
    securities: SecurityRepository,
    writeGuard: WriteGuard
) {
    // list_securities
    registry.register(
        name: "list_securities",
        description: "List all securities (stocks, funds, etc.) in the vault with name, symbol, and currency",
        inputSchema: ToolHelpers.schema(properties: [:])
    ) { _ in
        let results = try securities.listSecurities()
        return try ToolHelpers.jsonResponse(results)
    }

    // create_security
    registry.register(
        name: "create_security",
        description: "Create a new security (stock, fund, etc.) in the vault",
        inputSchema: ToolHelpers.schema(
            properties: [
                "symbol": ToolHelpers.property(type: "string", description: "Ticker symbol (e.g. AAPL, SL-CBF)"),
                "name": ToolHelpers.property(type: "string", description: "Security name"),
                "currency": ToolHelpers.property(type: "string", description: "Currency code (default: EUR)"),
            ],
            required: ["symbol", "name"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }

        guard let symbol = ToolHelpers.getString(arguments, key: "symbol") else {
            return ToolHelpers.errorResponse("symbol is required")
        }
        guard let name = ToolHelpers.getString(arguments, key: "name") else {
            return ToolHelpers.errorResponse("name is required")
        }
        let currency = ToolHelpers.getString(arguments, key: "currency") ?? "EUR"

        let result = try securities.createSecurity(
            symbol: symbol, name: name, currencyCode: currency
        )
        return try ToolHelpers.jsonResponse(result)
    }

    // create_share_adjustment
    registry.register(
        name: "create_share_adjustment",
        description: "Create a share adjustment transaction (e.g. for charges that cancel units, stock splits, or manual position corrections). Use negative shares to reduce a position.",
        inputSchema: ToolHelpers.schema(
            properties: [
                "account_id": ToolHelpers.property(type: "number", description: "Account ID"),
                "symbol": ToolHelpers.property(type: "string", description: "Security ticker symbol"),
                "id": ToolHelpers.property(type: "number", description: "Security ID (alternative to symbol)"),
                "shares": ToolHelpers.property(type: "number", description: "Number of shares to adjust (negative to reduce)"),
                "date": ToolHelpers.property(type: "string", description: "Date of adjustment in YYYY-MM-DD format"),
                "title": ToolHelpers.property(type: "string", description: "Transaction title/memo"),
                "amount": ToolHelpers.property(type: "number", description: "Cash amount (negative for buy outflow, positive for sell inflow)"),
                "transaction_type": ToolHelpers.property(type: "string", description: "Movement type. Accepts: \(SecurityRepository.shareMovementTypeNames). Defaults to buy or sell by the sign of shares"),
            ],
            required: ["account_id", "shares", "date"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }

        guard let accountId = ToolHelpers.getInt(arguments, key: "account_id") else {
            return ToolHelpers.errorResponse("account_id is required")
        }
        guard let shares = ToolHelpers.getDouble(arguments, key: "shares") else {
            return ToolHelpers.errorResponse("shares is required")
        }
        guard let date = ToolHelpers.getString(arguments, key: "date") else {
            return ToolHelpers.errorResponse("date is required")
        }
        let symbol = ToolHelpers.getString(arguments, key: "symbol")
        let id = ToolHelpers.getInt(arguments, key: "id")
        let title = ToolHelpers.getString(arguments, key: "title")
        let amount = ToolHelpers.getDouble(arguments, key: "amount")

        let result = try securities.createShareAdjustment(
            accountId: accountId, symbol: symbol, id: id,
            shares: shares, date: date, title: title, amount: amount,
            transactionType: ToolHelpers.getString(arguments, key: "transaction_type")
        )
        return try ToolHelpers.jsonResponse(result)
    }

    // get_security_prices
    registry.register(
        name: "get_security_prices",
        description: "Get price history for a security. Returns prices sorted by date descending.",
        inputSchema: ToolHelpers.schema(properties: [
            "symbol": ToolHelpers.property(type: "string", description: "Security ticker symbol (e.g. AAPL)"),
            "id": ToolHelpers.property(type: "number", description: "Security ID (alternative to symbol)"),
            "start_date": ToolHelpers.property(type: "string", description: "Start date in YYYY-MM-DD format"),
            "end_date": ToolHelpers.property(type: "string", description: "End date in YYYY-MM-DD format"),
            "limit": ToolHelpers.property(type: "number", description: "Maximum number of prices to return"),
        ])
    ) { arguments in
        let symbol = ToolHelpers.getString(arguments, key: "symbol")
        let id = ToolHelpers.getInt(arguments, key: "id")
        let startDate = ToolHelpers.getString(arguments, key: "start_date")
        let endDate = ToolHelpers.getString(arguments, key: "end_date")
        let limit = ToolHelpers.getInt(arguments, key: "limit")

        let results = try securities.getPrices(
            symbol: symbol, id: id,
            startDate: startDate, endDate: endDate,
            limit: limit
        )
        return try ToolHelpers.jsonResponse(results)
    }

    // import_security_prices
    registry.register(
        name: "import_security_prices",
        description: "Import security prices from a CSV file. Supports Yahoo Finance format (Date,Open,High,Low,Close,Adj Close,Volume), OHLCV (6 cols), or simple Date,Close (2 cols). Duplicate dates are skipped.",
        inputSchema: ToolHelpers.schema(
            properties: [
                "file_path": ToolHelpers.property(type: "string", description: "Path to the CSV file"),
                "symbol": ToolHelpers.property(type: "string", description: "Security ticker symbol (e.g. AAPL)"),
                "id": ToolHelpers.property(type: "number", description: "Security ID (alternative to symbol)"),
                "has_header": ToolHelpers.property(type: "boolean", description: "Whether the CSV has a header row (default: true)"),
                "date_format": ToolHelpers.property(type: "string", description: "Date format string (default: yyyy-MM-dd)"),
            ],
            required: ["file_path"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }

        guard let filePath = ToolHelpers.getString(arguments, key: "file_path") else {
            return ToolHelpers.errorResponse("file_path is required")
        }
        let symbol = ToolHelpers.getString(arguments, key: "symbol")
        let id = ToolHelpers.getInt(arguments, key: "id")
        let hasHeader = ToolHelpers.getBool(arguments, key: "has_header", default: true)
        let dateFormat = ToolHelpers.getString(arguments, key: "date_format") ?? "yyyy-MM-dd"

        let result = try securities.importPricesFromCSV(
            filePath: filePath,
            symbol: symbol, id: id,
            hasHeader: hasHeader,
            dateFormat: dateFormat
        )
        return try ToolHelpers.jsonResponse(result)
    }

    // get_security_holdings
    registry.register(
        name: "get_security_holdings",
        description: "Get current security holdings (share positions) across investment accounts. Shows shares held, cost basis, and current market value.",
        inputSchema: ToolHelpers.schema(properties: [
            "symbol": ToolHelpers.property(type: "string", description: "Security ticker symbol (e.g. AAPL)"),
            "id": ToolHelpers.property(type: "number", description: "Security ID (alternative to symbol)"),
            "account_id": ToolHelpers.property(type: "number", description: "Filter to a specific account"),
        ])
    ) { arguments in
        let symbol = ToolHelpers.getString(arguments, key: "symbol")
        let id = ToolHelpers.getInt(arguments, key: "id")
        let accountId = ToolHelpers.getInt(arguments, key: "account_id")

        let results = try securities.getHoldings(accountId: accountId, symbol: symbol, id: id)
        return try ToolHelpers.jsonResponse(results)
    }

    // get_security_trades
    registry.register(
        name: "get_security_realized_gains",
        description: """
            Compute realised capital gains by matching disposals to opening lots (FIFO). \
            Banktivity does not persist its lot matching, so this recomputes it: splits \
            adjust shares without touching basis, return of capital reduces basis, and \
            money is handled as exact decimals. Refuses rather than guessing if a security \
            uses a cost-basis method other than FIFO.
            """,
        inputSchema: ToolHelpers.schema(properties: [
            "symbol": ToolHelpers.property(type: "string", description: "Security ticker symbol"),
            "id": ToolHelpers.property(type: "integer", description: "Security ID (alternative to symbol)"),
            "account_id": ToolHelpers.property(type: "integer", description: "Filter to a specific account ID"),
            "start_date": ToolHelpers.property(type: "string", description: "Earliest disposal date (YYYY-MM-DD)"),
            "end_date": ToolHelpers.property(type: "string", description: "Latest disposal date (YYYY-MM-DD)"),
            "limit": ToolHelpers.property(type: "integer", description: "Maximum number of rows to return")
        ])
    ) { args in
        let results = try securities.getRealizedGains(
            accountId: ToolHelpers.getInt(args, key: "account_id"),
            symbol: ToolHelpers.getString(args, key: "symbol"),
            id: ToolHelpers.getInt(args, key: "id"),
            startDate: ToolHelpers.getString(args, key: "start_date"),
            endDate: ToolHelpers.getString(args, key: "end_date"),
            limit: ToolHelpers.getInt(args, key: "limit")
        )
        return try ToolHelpers.jsonResponse(results)
    }

    registry.register(
        name: "get_security_trades",
        description: "Get security trade history (buys, sells, transfers). Shows share counts, prices, amounts, and commissions.",
        inputSchema: ToolHelpers.schema(properties: [
            "symbol": ToolHelpers.property(type: "string", description: "Security ticker symbol (e.g. AAPL)"),
            "id": ToolHelpers.property(type: "number", description: "Security ID (alternative to symbol)"),
            "account_id": ToolHelpers.property(type: "number", description: "Filter to a specific account"),
            "start_date": ToolHelpers.property(type: "string", description: "Start date in YYYY-MM-DD format"),
            "end_date": ToolHelpers.property(type: "string", description: "End date in YYYY-MM-DD format"),
            "limit": ToolHelpers.property(type: "number", description: "Maximum number of trades to return"),
        ])
    ) { arguments in
        let symbol = ToolHelpers.getString(arguments, key: "symbol")
        let id = ToolHelpers.getInt(arguments, key: "id")
        let accountId = ToolHelpers.getInt(arguments, key: "account_id")
        let startDate = ToolHelpers.getString(arguments, key: "start_date")
        let endDate = ToolHelpers.getString(arguments, key: "end_date")
        let limit = ToolHelpers.getInt(arguments, key: "limit")

        let results = try securities.getTrades(
            accountId: accountId, symbol: symbol, id: id,
            startDate: startDate, endDate: endDate, limit: limit
        )
        return try ToolHelpers.jsonResponse(results)
    }

    // update_security_trade
    registry.register(
        name: "update_security_trade",
        description: "Update security trade fields on an existing transaction, including shares, price per share, security cost/principal amount, commission, and security.",
        inputSchema: ToolHelpers.schema(
            properties: [
                "transaction_id": ToolHelpers.property(type: "number", description: "Transaction ID"),
                "shares": ToolHelpers.property(type: "number", description: "Number of shares"),
                "price_per_share": ToolHelpers.property(type: "number", description: "Price per share"),
                "amount": ToolHelpers.property(type: "number", description: "Security cost/principal amount. This does not change investment-account cash line items."),
                "commission": ToolHelpers.property(type: "number", description: "Commission or fee amount"),
                "symbol": ToolHelpers.property(type: "string", description: "Security ticker symbol"),
                "security_id": ToolHelpers.property(type: "number", description: "Security ID (alternative to symbol)"),
                "basis_only_transfer": ToolHelpers.property(type: "boolean", description: "Validate a zero-cash transfer-in row and update security basis fields without changing cash line items"),
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
        let shares = ToolHelpers.getDouble(arguments, key: "shares")
        let pricePerShare = ToolHelpers.getDouble(arguments, key: "price_per_share")
        let amount = ToolHelpers.getDouble(arguments, key: "amount")
        let commission = ToolHelpers.getDouble(arguments, key: "commission")
        let symbol = ToolHelpers.getString(arguments, key: "symbol")
        let securityId = ToolHelpers.getInt(arguments, key: "security_id")
        let basisOnlyTransfer = ToolHelpers.getBool(arguments, key: "basis_only_transfer")

        let result = try securities.updateSecurityLineItem(
            transactionId: transactionId,
            shares: shares,
            pricePerShare: pricePerShare,
            amount: amount,
            commission: commission,
            securitySymbol: symbol,
            securityId: securityId,
            basisOnlyTransfer: basisOnlyTransfer
        )
        return try ToolHelpers.jsonResponse(result)
    }

    // create_security_trade
    registry.register(
        name: "create_security_trade",
        description: "Create a security buy/sell transaction with an investment-account cash line and a balancing unknown/category line. Positive shares create a buy; negative shares create a sell.",
        inputSchema: ToolHelpers.schema(
            properties: [
                "account_id": ToolHelpers.property(type: "number", description: "Investment account ID"),
                "symbol": ToolHelpers.property(type: "string", description: "Security ticker symbol"),
                "id": ToolHelpers.property(type: "number", description: "Security ID (alternative to symbol)"),
                "shares": ToolHelpers.property(type: "number", description: "Number of shares. Negative creates a sell; positive creates a buy"),
                "price_per_share": ToolHelpers.property(type: "number", description: "Price per share"),
                "amount": ToolHelpers.property(type: "number", description: "Security trade amount/cost"),
                "commission": ToolHelpers.property(type: "number", description: "Commission or fee amount"),
                "cash_line_amount": ToolHelpers.property(type: "number", description: "Investment account cash line amount. Positive for sell inflow, negative for buy outflow"),
                "date": ToolHelpers.property(type: "string", description: "Trade date in YYYY-MM-DD format"),
                "title": ToolHelpers.property(type: "string", description: "Transaction title"),
                "memo": ToolHelpers.property(type: "string", description: "Cash line memo"),
                "offset_category_id": ToolHelpers.property(type: "number", description: "Income/expense category ID for the balancing line. Omit to create an unknown balancing line"),
            ],
            required: ["account_id", "shares", "price_per_share", "amount", "cash_line_amount", "date"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }

        guard let accountId = ToolHelpers.getInt(arguments, key: "account_id") else {
            return ToolHelpers.errorResponse("account_id is required")
        }
        guard let shares = ToolHelpers.getDouble(arguments, key: "shares") else {
            return ToolHelpers.errorResponse("shares is required")
        }
        guard let pricePerShare = ToolHelpers.getDouble(arguments, key: "price_per_share") else {
            return ToolHelpers.errorResponse("price_per_share is required")
        }
        guard let amount = ToolHelpers.getDouble(arguments, key: "amount") else {
            return ToolHelpers.errorResponse("amount is required")
        }
        guard let cashLineAmount = ToolHelpers.getDouble(arguments, key: "cash_line_amount") else {
            return ToolHelpers.errorResponse("cash_line_amount is required")
        }
        guard let date = ToolHelpers.getString(arguments, key: "date") else {
            return ToolHelpers.errorResponse("date is required")
        }

        let result = try securities.createSecurityTrade(
            accountId: accountId,
            symbol: ToolHelpers.getString(arguments, key: "symbol"),
            id: ToolHelpers.getInt(arguments, key: "id"),
            shares: shares,
            pricePerShare: pricePerShare,
            amount: amount,
            commission: ToolHelpers.getDouble(arguments, key: "commission") ?? 0,
            cashLineItemAmount: cashLineAmount,
            date: date,
            title: ToolHelpers.getString(arguments, key: "title"),
            memo: ToolHelpers.getString(arguments, key: "memo"),
            offsetCategoryId: ToolHelpers.getInt(arguments, key: "offset_category_id")
        )
        return try ToolHelpers.jsonResponse(result)
    }

    // create_security_income
    registry.register(
        name: "create_security_income",
        description: "Create a native investment income transaction for a security. Currently supports dividend income.",
        inputSchema: ToolHelpers.schema(
            properties: [
                "account_id": ToolHelpers.property(type: "number", description: "Investment account ID"),
                "symbol": ToolHelpers.property(type: "string", description: "Security ticker symbol"),
                "id": ToolHelpers.property(type: "number", description: "Security ID (alternative to symbol)"),
                "amount": ToolHelpers.property(type: "number", description: "Positive income amount"),
                "date": ToolHelpers.property(type: "string", description: "Income date in YYYY-MM-DD format"),
                "title": ToolHelpers.property(type: "string", description: "Transaction title"),
                "memo": ToolHelpers.property(type: "string", description: "Cash line memo"),
                "offset_category_id": ToolHelpers.property(type: "number", description: "Income/expense category ID for the balancing line. Omit to create an unknown balancing line"),
                "income_type": ToolHelpers.property(type: "string", description: "Income type. Accepts: \(SecurityRepository.incomeTypeNames)"),
            ],
            required: ["account_id", "amount", "date"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }

        guard let accountId = ToolHelpers.getInt(arguments, key: "account_id") else {
            return ToolHelpers.errorResponse("account_id is required")
        }
        guard let amount = ToolHelpers.getDouble(arguments, key: "amount") else {
            return ToolHelpers.errorResponse("amount is required")
        }
        guard let date = ToolHelpers.getString(arguments, key: "date") else {
            return ToolHelpers.errorResponse("date is required")
        }

        let result = try securities.createSecurityIncome(
            accountId: accountId,
            symbol: ToolHelpers.getString(arguments, key: "symbol"),
            id: ToolHelpers.getInt(arguments, key: "id"),
            amount: amount,
            date: date,
            title: ToolHelpers.getString(arguments, key: "title"),
            memo: ToolHelpers.getString(arguments, key: "memo"),
            offsetCategoryId: ToolHelpers.getInt(arguments, key: "offset_category_id"),
            incomeType: ToolHelpers.getString(arguments, key: "income_type") ?? "dividend"
        )
        return try ToolHelpers.jsonResponse(result)
    }

    // get_security_income
    registry.register(
        name: "get_security_income",
        description: "Get investment income history (dividends, interest, capital gains distributions).",
        inputSchema: ToolHelpers.schema(properties: [
            "symbol": ToolHelpers.property(type: "string", description: "Security ticker symbol (e.g. AAPL)"),
            "id": ToolHelpers.property(type: "number", description: "Security ID (alternative to symbol)"),
            "account_id": ToolHelpers.property(type: "number", description: "Filter to a specific account"),
            "start_date": ToolHelpers.property(type: "string", description: "Start date in YYYY-MM-DD format"),
            "end_date": ToolHelpers.property(type: "string", description: "End date in YYYY-MM-DD format"),
        ])
    ) { arguments in
        let symbol = ToolHelpers.getString(arguments, key: "symbol")
        let id = ToolHelpers.getInt(arguments, key: "id")
        let accountId = ToolHelpers.getInt(arguments, key: "account_id")
        let startDate = ToolHelpers.getString(arguments, key: "start_date")
        let endDate = ToolHelpers.getString(arguments, key: "end_date")

        let results = try securities.getIncome(
            accountId: accountId, symbol: symbol, id: id,
            startDate: startDate, endDate: endDate
        )
        return try ToolHelpers.jsonResponse(results)
    }

    // delete_security_prices
    registry.register(
        name: "delete_security_prices",
        description: "Delete price history for a security, optionally filtered by date range",
        inputSchema: ToolHelpers.schema(properties: [
            "symbol": ToolHelpers.property(type: "string", description: "Security ticker symbol (e.g. AAPL)"),
            "id": ToolHelpers.property(type: "number", description: "Security ID (alternative to symbol)"),
            "start_date": ToolHelpers.property(type: "string", description: "Start date in YYYY-MM-DD format (optional)"),
            "end_date": ToolHelpers.property(type: "string", description: "End date in YYYY-MM-DD format (optional)"),
        ])
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }

        let symbol = ToolHelpers.getString(arguments, key: "symbol")
        let id = ToolHelpers.getInt(arguments, key: "id")
        let startDate = ToolHelpers.getString(arguments, key: "start_date")
        let endDate = ToolHelpers.getString(arguments, key: "end_date")

        let count = try securities.deletePrices(
            symbol: symbol, id: id,
            startDate: startDate, endDate: endDate
        )
        return ToolHelpers.successResponse("Deleted \(count) price(s)")
    }

    // reset_security_price_range
    registry.register(
        name: "reset_security_price_range",
        description: "Forget which price history is known for a security without deleting any of it. Clears the known date range and last import date; every price row is left in place.",
        inputSchema: ToolHelpers.schema(properties: [
            "symbol": ToolHelpers.property(type: "string", description: "Security ticker symbol (e.g. AAPL)"),
            "id": ToolHelpers.property(type: "number", description: "Security ID (alternative to symbol)"),
        ])
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }

        let symbol = ToolHelpers.getString(arguments, key: "symbol")
        let id = ToolHelpers.getInt(arguments, key: "id")

        guard let result = try securities.resetKnownPriceRange(symbol: symbol, id: id) else {
            return ToolHelpers.errorResponse("No price item for that security; there is no known range to forget")
        }
        return try ToolHelpers.jsonResponse(result)
    }

    // rename_security
    registry.register(
        name: "rename_security",
        description: "Rename a security's ticker symbol, display name, or both. Refuses a symbol another security already holds; that is a merge, not a rename.",
        inputSchema: ToolHelpers.schema(
            properties: [
                "symbol": ToolHelpers.property(type: "string", description: "Current ticker symbol"),
                "id": ToolHelpers.property(type: "number", description: "Security ID (alternative to symbol)"),
                "new_symbol": ToolHelpers.property(type: "string", description: "New ticker symbol"),
                "new_name": ToolHelpers.property(type: "string", description: "New display name"),
            ],
            required: []
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        let result = try securities.renameSecurity(
            symbol: ToolHelpers.getString(arguments, key: "symbol"),
            id: ToolHelpers.getInt(arguments, key: "id"),
            newSymbol: ToolHelpers.getString(arguments, key: "new_symbol"),
            newName: ToolHelpers.getString(arguments, key: "new_name")
        )
        return try ToolHelpers.jsonResponse(result)
    }

    // delete_security
    registry.register(
        name: "delete_security",
        description: "Delete a security record that no trade references. Refuses while any trade still points at it: re-point those with update_security_trade first.",
        inputSchema: ToolHelpers.schema(properties: [
            "symbol": ToolHelpers.property(type: "string", description: "Ticker symbol (e.g. AAPL)"),
            "id": ToolHelpers.property(type: "number", description: "Security ID (alternative to symbol)"),
            "with_prices": ToolHelpers.property(type: "boolean", description: "Also delete the security's price history (default false)"),
            "dry_run": ToolHelpers.property(type: "boolean", description: "Report the trade and price counts without writing"),
        ])
    ) { arguments in
        let symbol = ToolHelpers.getString(arguments, key: "symbol")
        let id = ToolHelpers.getInt(arguments, key: "id")
        let withPrices = ToolHelpers.getBool(arguments, key: "with_prices")
        let dryRun = ToolHelpers.getBool(arguments, key: "dry_run")

        guard symbol != nil || id != nil else {
            return ToolHelpers.errorResponse("Provide symbol or id")
        }
        guard let info = try securities.inspectForDeletion(symbol: symbol, id: id) else {
            return ToolHelpers.errorResponse("Security not found")
        }

        if dryRun {
            let blocked = info.tradeCount > 0 || (info.priceCount > 0 && !withPrices)
            return ToolHelpers.successResponse(
                "security \(info.securityId) (\(info.symbol)) — trades \(info.tradeCount), prices \(info.priceCount), wouldDelete \(!blocked)"
            )
        }

        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        let deleted = try securities.deleteSecurity(symbol: symbol, id: id, withPrices: withPrices)
        guard deleted > 0 else {
            return ToolHelpers.errorResponse("Security \(info.securityId) was not deleted")
        }
        return ToolHelpers.successResponse("Security \(info.securityId) (\(info.symbol)) deleted")
    }
}
