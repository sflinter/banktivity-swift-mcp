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
            shares: shares, date: date, title: title, amount: amount
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
}
