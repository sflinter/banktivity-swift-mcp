// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

public final class SecurityRepository: BaseRepository, @unchecked Sendable {

    // MARK: - Date Helpers (SecurityPrice uses int32 = days since Unix epoch)

    private static func dateToDaysSinceEpoch(_ dateString: String, format: String = "yyyy-MM-dd") -> Int32? {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: dateString) else { return nil }
        let seconds = date.timeIntervalSince1970
        return Int32(seconds / 86400)
    }

    private static func daysSinceEpochToISO(_ days: Int32) -> String {
        let date = Date(timeIntervalSince1970: Double(days) * 86400)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    // MARK: - Read Operations

    public func listSecurities() throws -> [SecurityDTO] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Security")
        request.sortDescriptors = [NSSortDescriptor(key: "pSymbol", ascending: true)]
        let results = try context.fetch(request)
        return results.map { mapToSecurityDTO($0) }
    }

    public func resolveSecurity(symbol: String?, id: Int?) throws -> NSManagedObject {
        if let id = id {
            guard let security = try fetchByPK(entityName: "Security", pk: id) else {
                throw ToolError.notFound("Security not found with ID: \(id)")
            }
            return security
        }
        guard let symbol = symbol else {
            throw ToolError.missingParameter("Either symbol or id is required")
        }
        let request = NSFetchRequest<NSManagedObject>(entityName: "Security")
        request.predicate = NSPredicate(format: "pSymbol ==[c] %@", symbol)
        request.fetchLimit = 1
        let results = try context.fetch(request)
        guard let security = results.first else {
            throw ToolError.notFound("Security not found with symbol: \(symbol)")
        }
        return security
    }

    public func getPrices(
        symbol: String? = nil,
        id: Int? = nil,
        startDate: String? = nil,
        endDate: String? = nil,
        limit: Int? = nil
    ) throws -> [SecurityPriceDTO] {
        let security = try resolveSecurity(symbol: symbol, id: id)
        let uniqueId = Self.stringValue(security, "pUniqueID")

        let priceItemRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityPriceItem")
        priceItemRequest.predicate = NSPredicate(format: "pSecurityID == %@", uniqueId)
        priceItemRequest.fetchLimit = 1
        let priceItems = try context.fetch(priceItemRequest)
        guard let priceItem = priceItems.first else {
            return []
        }

        let priceRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityPrice")
        var predicates: [NSPredicate] = [
            NSPredicate(format: "pSecurityPriceItem == %@", priceItem)
        ]

        if let start = startDate, let days = Self.dateToDaysSinceEpoch(start) {
            predicates.append(NSPredicate(format: "pDate >= %d", days))
        }
        if let end = endDate, let days = Self.dateToDaysSinceEpoch(end) {
            predicates.append(NSPredicate(format: "pDate <= %d", days))
        }

        priceRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        priceRequest.sortDescriptors = [NSSortDescriptor(key: "pDate", ascending: false)]
        if let limit = limit { priceRequest.fetchLimit = limit }

        let prices = try context.fetch(priceRequest)
        return prices.map { mapToPriceDTO($0) }
    }

    // MARK: - Write Operations

    public func importPricesFromCSV(
        filePath: String,
        symbol: String? = nil,
        id: Int? = nil,
        hasHeader: Bool = true,
        dateFormat: String = "yyyy-MM-dd"
    ) throws -> PriceImportResultDTO {
        let security = try resolveSecurity(symbol: symbol, id: id)
        let securitySymbol = Self.stringValue(security, "pSymbol")
        let securityUniqueId = Self.stringValue(security, "pUniqueID")
        let csvContent = try String(contentsOfFile: filePath, encoding: .utf8)
        let parsedRows = Self.parseCSV(csvContent, hasHeader: hasHeader, dateFormat: dateFormat)

        if parsedRows.isEmpty {
            throw ToolError.invalidInput("No valid price rows found in CSV")
        }

        let result: PriceImportResultDTO = try performWriteReturning { ctx in
            // Find or create SecurityPriceItem
            let piRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityPriceItem")
            piRequest.predicate = NSPredicate(format: "pSecurityID == %@", securityUniqueId)
            piRequest.fetchLimit = 1
            let existingItems = try ctx.fetch(piRequest)
            let priceItem: NSManagedObject
            if let existing = existingItems.first {
                priceItem = existing
            } else {
                priceItem = Self.createObject(entityName: "SecurityPriceItem", in: ctx)
                priceItem.setValue(securityUniqueId, forKey: "pSecurityID")
            }

            // Load existing dates for dedup
            let existingPriceRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityPrice")
            existingPriceRequest.predicate = NSPredicate(format: "pSecurityPriceItem == %@", priceItem)
            let existingPrices = try ctx.fetch(existingPriceRequest)
            var existingDates = Set<Int32>()
            for p in existingPrices {
                let d = (p.value(forKey: "pDate") as? Int32) ?? 0
                existingDates.insert(d)
            }

            var imported = 0
            var skipped = 0
            var allDates = existingDates

            for row in parsedRows {
                if existingDates.contains(row.date) {
                    skipped += 1
                    continue
                }

                let price = Self.createObject(entityName: "SecurityPrice", in: ctx)
                price.setValue(row.date, forKey: "pDate")
                price.setValue(row.close as NSNumber, forKey: "pClosePrice")
                price.setValue((row.adjustedClose ?? row.close) as NSNumber, forKey: "pAdjustedClosePrice")
                price.setValue(row.open as NSNumber, forKey: "pOpenPrice")
                price.setValue(row.high as NSNumber, forKey: "pHighPrice")
                price.setValue(row.low as NSNumber, forKey: "pLowPrice")
                price.setValue(row.volume as NSNumber, forKey: "pVolume")
                price.setValue(0 as Int32, forKey: "pDataSource")
                price.setValue(priceItem, forKey: "pSecurityPriceItem")

                allDates.insert(row.date)
                imported += 1
            }

            // Update date range on SecurityPriceItem
            if let minDate = allDates.min(), let maxDate = allDates.max() {
                let minDateObj = Date(timeIntervalSince1970: Double(minDate) * 86400)
                let maxDateObj = Date(timeIntervalSince1970: Double(maxDate) * 86400)
                priceItem.setValue(minDateObj, forKey: "pKnownDateRangeBegin")
                priceItem.setValue(maxDateObj, forKey: "pKnownDateRangeEnd")
            }

            priceItem.setValue(Date(), forKey: "pLatestImportDate")

            let dateRangeBegin: String? = allDates.min().map { Self.daysSinceEpochToISO($0) }
            let dateRangeEnd: String? = allDates.max().map { Self.daysSinceEpochToISO($0) }

            return PriceImportResultDTO(
                securitySymbol: securitySymbol,
                imported: imported,
                skipped: skipped,
                totalPrices: allDates.count,
                dateRangeBegin: dateRangeBegin,
                dateRangeEnd: dateRangeEnd
            )
        }

        return result
    }

    public func deletePrices(
        symbol: String? = nil,
        id: Int? = nil,
        startDate: String? = nil,
        endDate: String? = nil
    ) throws -> Int {
        let security = try resolveSecurity(symbol: symbol, id: id)
        let uniqueId = Self.stringValue(security, "pUniqueID")

        let piRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityPriceItem")
        piRequest.predicate = NSPredicate(format: "pSecurityID == %@", uniqueId)
        piRequest.fetchLimit = 1
        let priceItems = try context.fetch(piRequest)
        guard let priceItem = priceItems.first else {
            return 0
        }
        let priceItemObjectID = priceItem.objectID

        let count: Int = try performWriteReturning { ctx in
            guard let piInCtx = try? ctx.existingObject(with: priceItemObjectID) else { return 0 }

            let priceRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityPrice")
            var predicates: [NSPredicate] = [
                NSPredicate(format: "pSecurityPriceItem == %@", piInCtx)
            ]
            if let start = startDate, let days = Self.dateToDaysSinceEpoch(start) {
                predicates.append(NSPredicate(format: "pDate >= %d", days))
            }
            if let end = endDate, let days = Self.dateToDaysSinceEpoch(end) {
                predicates.append(NSPredicate(format: "pDate <= %d", days))
            }
            priceRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)

            let prices = try ctx.fetch(priceRequest)
            let deleteCount = prices.count
            for price in prices {
                ctx.delete(price)
            }

            // Update date range on SecurityPriceItem
            let remainingRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityPrice")
            remainingRequest.predicate = NSPredicate(format: "pSecurityPriceItem == %@", piInCtx)
            let remaining = try ctx.fetch(remainingRequest)
            if remaining.isEmpty {
                piInCtx.setValue(nil, forKey: "pKnownDateRangeBegin")
                piInCtx.setValue(nil, forKey: "pKnownDateRangeEnd")
            } else {
                var dates: [Int32] = []
                for p in remaining {
                    if let d = p.value(forKey: "pDate") as? Int32 { dates.append(d) }
                }
                if let minDate = dates.min(), let maxDate = dates.max() {
                    piInCtx.setValue(Date(timeIntervalSince1970: Double(minDate) * 86400), forKey: "pKnownDateRangeBegin")
                    piInCtx.setValue(Date(timeIntervalSince1970: Double(maxDate) * 86400), forKey: "pKnownDateRangeEnd")
                }
            }

            return deleteCount
        }

        return count
    }

    // MARK: - CSV Parsing

    private struct ParsedPriceRow {
        let date: Int32
        let open: Double
        let high: Double
        let low: Double
        let close: Double
        let adjustedClose: Double?
        let volume: Double
    }

    private static func parseCSV(_ content: String, hasHeader: Bool, dateFormat: String) -> [ParsedPriceRow] {
        var lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if lines.isEmpty { return [] }

        // Detect format from header or first data line
        var columnMap: ColumnMap = .dateClose
        if hasHeader {
            let header = lines.removeFirst().lowercased()
            columnMap = detectColumnMap(header: header)
        } else if let firstLine = lines.first {
            let cols = firstLine.components(separatedBy: ",").count
            switch cols {
            case 7: columnMap = .yahooFinance
            case 6: columnMap = .dateOHLCV
            default: columnMap = .dateClose
            }
        }

        var rows: [ParsedPriceRow] = []
        for line in lines {
            let cols = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let row = parseRow(cols, map: columnMap, dateFormat: dateFormat) else { continue }
            rows.append(row)
        }
        return rows
    }

    private enum ColumnMap {
        case dateClose          // 2 cols: date, close
        case dateOHLCV          // 6 cols: date, open, high, low, close, volume
        case yahooFinance       // 7 cols: date, open, high, low, close, adj close, volume
    }

    private static func detectColumnMap(header: String) -> ColumnMap {
        let cols = header.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if cols.contains("adj close") || cols.contains("adj_close") || cols.contains("adjusted close") {
            return .yahooFinance
        }
        if cols.count >= 6 && cols.contains("open") && cols.contains("volume") {
            return .dateOHLCV
        }
        return .dateClose
    }

    private static func parseRow(_ cols: [String], map: ColumnMap, dateFormat: String) -> ParsedPriceRow? {
        guard !cols.isEmpty else { return nil }
        guard let date = dateToDaysSinceEpoch(cols[0], format: dateFormat) else { return nil }

        switch map {
        case .dateClose:
            guard cols.count >= 2, let close = Double(cols[1]) else { return nil }
            return ParsedPriceRow(date: date, open: close, high: close, low: close, close: close, adjustedClose: nil, volume: 0)

        case .dateOHLCV:
            guard cols.count >= 6,
                  let open = Double(cols[1]), let high = Double(cols[2]),
                  let low = Double(cols[3]), let close = Double(cols[4]),
                  let volume = Double(cols[5]) else { return nil }
            return ParsedPriceRow(date: date, open: open, high: high, low: low, close: close, adjustedClose: nil, volume: volume)

        case .yahooFinance:
            guard cols.count >= 7,
                  let open = Double(cols[1]), let high = Double(cols[2]),
                  let low = Double(cols[3]), let close = Double(cols[4]),
                  let adjClose = Double(cols[5]), let volume = Double(cols[6]) else { return nil }
            return ParsedPriceRow(date: date, open: open, high: high, low: low, close: close, adjustedClose: adjClose, volume: volume)
        }
    }

    // MARK: - DTO Mapping

    private func mapToSecurityDTO(_ object: NSManagedObject) -> SecurityDTO {
        SecurityDTO(
            id: Self.extractPK(from: object.objectID),
            name: Self.stringValue(object, "pName"),
            symbol: Self.stringValue(object, "pSymbol"),
            uniqueId: Self.stringValue(object, "pUniqueID"),
            currency: {
                if let curr = Self.relatedObject(object, "pCurrency") {
                    return Self.string(curr, "pCode")
                }
                return nil
            }(),
            securityType: Self.intValue(object, "pType")
        )
    }

    private func mapToPriceDTO(_ object: NSManagedObject) -> SecurityPriceDTO {
        let dateInt = (object.value(forKey: "pDate") as? Int32) ?? 0
        return SecurityPriceDTO(
            id: Self.extractPK(from: object.objectID),
            date: Self.daysSinceEpochToISO(dateInt),
            closePrice: Self.doubleValue(object, "pClosePrice"),
            adjustedClosePrice: Self.doubleValue(object, "pAdjustedClosePrice"),
            openPrice: Self.doubleValue(object, "pOpenPrice"),
            highPrice: Self.doubleValue(object, "pHighPrice"),
            lowPrice: Self.doubleValue(object, "pLowPrice"),
            volume: Self.doubleValue(object, "pVolume"),
            dataSource: Self.intValue(object, "pDataSource")
        )
    }
}
