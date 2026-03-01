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
