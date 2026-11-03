// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

public final class SecurityRepository: BaseRepository, @unchecked Sendable {
    private let syncBlobUpdater: SyncBlobUpdater?

    public init(container: NSPersistentContainer, syncBlobUpdater: SyncBlobUpdater? = nil) {
        self.syncBlobUpdater = syncBlobUpdater
        super.init(container: container)
    }

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
        try performRead { [self] ctx in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Security")
            request.sortDescriptors = [NSSortDescriptor(key: "pSymbol", ascending: true)]
            let results = try ctx.fetch(request)
            return results.map { self.mapToSecurityDTO($0) }
        }
    }

    public func getPrices(
        symbol: String? = nil,
        id: Int? = nil,
        startDate: String? = nil,
        endDate: String? = nil,
        limit: Int? = nil
    ) throws -> [SecurityPriceDTO] {
        try performRead { [self] ctx in
            let security: NSManagedObject
            if let id = id {
                guard let s = try fetchByPK(entityName: "Security", pk: id, in: ctx) else {
                    throw ToolError.notFound("Security not found with ID: \(id)")
                }
                security = s
            } else {
                guard let sym = symbol else {
                    throw ToolError.missingParameter("Either symbol or id is required")
                }
                let req = NSFetchRequest<NSManagedObject>(entityName: "Security")
                req.predicate = NSPredicate(format: "pSymbol ==[c] %@", sym)
                req.fetchLimit = 1
                guard let s = try ctx.fetch(req).first else {
                    throw ToolError.notFound("Security not found with symbol: \(sym)")
                }
                security = s
            }
            let uniqueId = Self.stringValue(security, "pUniqueID")

            let priceItemRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityPriceItem")
            priceItemRequest.predicate = NSPredicate(format: "pSecurityID == %@", uniqueId)
            priceItemRequest.fetchLimit = 1
            let priceItems = try ctx.fetch(priceItemRequest)
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

            let prices = try ctx.fetch(priceRequest)
            return prices.map { self.mapToPriceDTO($0) }
        }
    }

    // MARK: - Write Operations

    public func createSecurity(
        symbol: String,
        name: String,
        currencyCode: String = "EUR"
    ) throws -> SecurityDTO {
        try performWriteReturning { ctx in
            let existing = NSFetchRequest<NSManagedObject>(entityName: "Security")
            existing.predicate = NSPredicate(format: "pSymbol ==[c] %@", symbol)
            existing.fetchLimit = 1
            if let _ = try ctx.fetch(existing).first {
                throw ToolError.invalidInput("Security with symbol '\(symbol)' already exists")
            }

            let currRequest = NSFetchRequest<NSManagedObject>(entityName: "Currency")
            currRequest.predicate = NSPredicate(format: "pCode ==[c] %@", currencyCode)
            currRequest.fetchLimit = 1
            let currency = try ctx.fetch(currRequest).first

            let sec = Self.createObject(entityName: "Security", in: ctx)
            let uniqueID = Self.generateUUID()
            sec.setValue(symbol, forKey: "pSymbol")
            sec.setValue(name, forKey: "pName")
            sec.setValue(uniqueID, forKey: "pUniqueID")
            sec.setValue(false, forKey: "pExcludeFromQuoteUpdates")
            sec.setValue(false, forKey: "pIsIndex")
            sec.setValue(false, forKey: "pTradesInPence")
            sec.setValue(Int16(0), forKey: "pType")
            sec.setValue(Int16(0), forKey: "pRiskType")
            sec.setValue(NSDecimalNumber.one, forKey: "pContractSize")
            sec.setValue(NSDecimalNumber.zero, forKey: "pParValue")
            Self.setNow(sec, "pCreationTime")
            Self.setNow(sec, "pModificationDate")
            if let currency = currency { sec.setValue(currency, forKey: "pCurrency") }

            try ctx.obtainPermanentIDs(for: [sec])
            return SecurityDTO(
                id: Self.extractPK(from: sec.objectID),
                name: name,
                symbol: symbol,
                uniqueId: uniqueID,
                currency: currency.flatMap { Self.string($0, "pCode") },
                securityType: 0
            )
        }
    }

    public func createShareAdjustment(
        accountId: Int,
        symbol: String? = nil,
        id: Int? = nil,
        shares: Double,
        date: String,
        title: String? = nil,
        amount: Double? = nil
    ) throws -> SecurityTradeDTO {
        struct SecurityInfo: Sendable {
            let objectID: NSManagedObjectID
            let symbol: String
            let name: String
            let uuid: String
        }

        let secInfo: SecurityInfo = try performRead { [self] ctx in
            let sec: NSManagedObject
            if let id = id {
                guard let s = try fetchByPK(entityName: "Security", pk: id, in: ctx) else {
                    throw ToolError.notFound("Security not found with ID: \(id)")
                }
                sec = s
            } else {
                guard let sym = symbol else {
                    throw ToolError.missingParameter("Either symbol or id is required")
                }
                let req = NSFetchRequest<NSManagedObject>(entityName: "Security")
                req.predicate = NSPredicate(format: "pSymbol ==[c] %@", sym)
                req.fetchLimit = 1
                guard let s = try ctx.fetch(req).first else {
                    throw ToolError.notFound("Security not found: \(sym)")
                }
                sec = s
            }
            return SecurityInfo(
                objectID: sec.objectID,
                symbol: Self.stringValue(sec, "pSymbol"),
                name: Self.stringValue(sec, "pName"),
                uuid: Self.stringValue(sec, "pUniqueID")
            )
        }
        let securityObjectID = secInfo.objectID
        let secSymbol = secInfo.symbol
        let secName = secInfo.name
        let secUUID = secInfo.uuid

        struct SyncInfo: Sendable {
            let txPK: Int
            let txUUID: String
            let txTitle: String
            let liUUID: String
            let accountUUID: String
            let currencyUUID: String
            let transactionTypeBaseType: String
            let transactionTypeUUID: String
        }

        let info: SyncInfo = try performWriteReturning { [self] ctx in
            guard let securityInCtx = try? ctx.existingObject(with: securityObjectID) else {
                throw ToolError.notFound("Security not found in write context")
            }
            guard let account = try fetchByPK(entityName: "Account", pk: accountId, in: ctx) else {
                throw ToolError.notFound("Account not found: \(accountId)")
            }

            // Find the appropriate transaction type: Buy (100) or Sell (101)
            let baseType: Int16 = shares >= 0 ? 100 : 101
            let typeRequest = NSFetchRequest<NSManagedObject>(entityName: "TransactionType")
            typeRequest.predicate = NSPredicate(format: "pBaseType == %d", baseType)
            typeRequest.fetchLimit = 1
            let txType = try ctx.fetch(typeRequest).first

            // Use the account's currency (Account uses "currency" not "pCurrency")
            let currency = Self.relatedObject(account, "currency")
            let accountUUID = Self.stringValue(account, "pUniqueID")
            let currencyUUID = currency.map { Self.stringValue($0, "pUniqueID") } ?? ""
            let txTypeBaseType = shares >= 0 ? "buy" : "sell"
            let txTypeUUID = txType.map { Self.stringValue($0, "pUniqueID") } ?? ""

            // Create Transaction
            let tx = Self.createObject(entityName: "Transaction", in: ctx)
            let txTitle = title ?? "Charge adjustment — \(secSymbol)"
            let txUUID = Self.generateUUID()
            tx.setValue(txTitle, forKey: "pTitle")
            tx.setValue(txUUID, forKey: "pUniqueID")
            tx.setValue(false, forKey: "pCleared")
            tx.setValue(false, forKey: "pVoid")
            tx.setValue(false, forKey: "pAdjustment")
            Self.setDate(tx, "pDate", isoString: date)
            Self.setNow(tx, "pCreationTime")
            Self.setNow(tx, "pModificationDate")
            if let currency = currency { tx.setValue(currency, forKey: "pCurrency") }
            if let txType = txType { tx.setValue(txType, forKey: "pTransactionType") }

            // Create LineItem
            let li = Self.createObject(entityName: "LineItem", in: ctx)
            let liUUID = Self.generateUUID()
            li.setValue(0.0 as NSNumber, forKey: "pTransactionAmount")
            li.setValue(liUUID, forKey: "pUniqueID")
            li.setValue(1.0 as NSNumber, forKey: "pExchangeRate")
            li.setValue(0.0 as NSNumber, forKey: "pRunningBalance")
            li.setValue(false, forKey: "pCleared")
            Self.setNow(li, "pCreationTime")
            li.setValue(account, forKey: "pAccount")
            li.setValue(tx, forKey: "pTransaction")

            // Create SecurityLineItem
            let sli = Self.createObject(entityName: "SecurityLineItem", in: ctx)
            sli.setValue(shares as NSNumber, forKey: "pShares")
            let sliAmount = amount ?? 0.0
            sli.setValue(sliAmount as NSNumber, forKey: "pAmount")
            sli.setValue(0.0 as NSNumber, forKey: "pPricePerShare")
            sli.setValue(0.0 as NSNumber, forKey: "pCommission")
            sli.setValue(0.0 as NSNumber, forKey: "pIncome")
            sli.setValue(1.0 as NSNumber, forKey: "pPriceMultiplier")
            sli.setValue(securityInCtx, forKey: "pSecurity")
            sli.setValue(li, forKey: "pLineItem")

            try ctx.obtainPermanentIDs(for: [tx])
            return SyncInfo(
                txPK: Self.extractPK(from: tx.objectID),
                txUUID: txUUID, txTitle: txTitle, liUUID: liUUID,
                accountUUID: accountUUID, currencyUUID: currencyUUID,
                transactionTypeBaseType: txTypeBaseType, transactionTypeUUID: txTypeUUID
            )
        }

        // Create sync record (non-fatal)
        if let updater = syncBlobUpdater {
            let sliAmount = amount ?? 0.0
            let syncSLI = SyncBlobUpdater.SyncSecurityLineItem(
                amount: sliAmount, commission: 0, pricePerShare: 0,
                priceMultiplier: 1, securityUUID: secUUID,
                shares: shares, hasDistributionType: false
            )
            let syncLI = SyncBlobUpdater.SyncLineItem(
                accountUUID: info.accountUUID, accountAmount: 0,
                cleared: false, identifier: info.liUUID, memo: nil,
                securityLineItem: syncSLI, transactionAmount: 0
            )
            updater.createTransactionSyncRecord(
                transactionUUID: info.txUUID, currencyUUID: info.currencyUUID,
                date: date, title: info.txTitle, note: nil, adjustment: false,
                lineItems: [syncLI],
                transactionTypeBaseType: info.transactionTypeBaseType,
                transactionTypeUUID: info.transactionTypeUUID
            )
        }

        return SecurityTradeDTO(
            id: info.txPK,
            date: date,
            type: shares >= 0 ? "Buy" : "Sell",
            symbol: secSymbol,
            securityName: secName,
            shares: shares,
            pricePerShare: 0,
            amount: amount ?? 0,
            commission: 0,
            accountName: "",
            accountId: accountId
        )
    }

    public func updateSecurityLineItem(
        transactionId: Int,
        shares: Double? = nil,
        pricePerShare: Double? = nil,
        amount: Double? = nil,
        securitySymbol: String? = nil,
        securityId: Int? = nil,
        cashLineItemAmount: Double? = nil
    ) throws -> SecurityTradeDTO {
        // Resolve new security if specified
        struct NewSecInfo: Sendable {
            let objectID: NSManagedObjectID
            let uuid: String
        }

        let newSecInfo: NewSecInfo?
        if securitySymbol != nil || securityId != nil {
            newSecInfo = try performRead { [self] ctx in
                let sec: NSManagedObject
                if let id = securityId {
                    guard let s = try fetchByPK(entityName: "Security", pk: id, in: ctx) else {
                        throw ToolError.notFound("Security not found: \(id)")
                    }
                    sec = s
                } else {
                    guard let sym = securitySymbol else {
                        throw ToolError.missingParameter("Either symbol or id is required")
                    }
                    let req = NSFetchRequest<NSManagedObject>(entityName: "Security")
                    req.predicate = NSPredicate(format: "pSymbol ==[c] %@", sym)
                    req.fetchLimit = 1
                    guard let s = try ctx.fetch(req).first else {
                        throw ToolError.notFound("Security not found: \(sym)")
                    }
                    sec = s
                }
                return NewSecInfo(objectID: sec.objectID, uuid: Self.stringValue(sec, "pUniqueID"))
            }
        } else {
            newSecInfo = nil
        }
        let newSecurityObjectID = newSecInfo?.objectID
        let newSecurityUUID = newSecInfo?.uuid

        struct UpdateResult: Sendable {
            let txUUID: String
            let liUUID: String
            let trade: SecurityTradeDTO
            let cashSync: CashSyncInfo?
        }

        struct CashSyncInfo: Sendable {
            let accountId: Int
            let cashLineItemUUID: String
            let cashAmount: Double
            let offsetLineItemUUID: String
            let offsetAmount: Double
        }

        let result: UpdateResult = try performWriteReturning { [self] ctx in
            guard let tx = try fetchByPK(entityName: "Transaction", pk: transactionId, in: ctx) else {
                throw ToolError.notFound("Transaction not found: \(transactionId)")
            }

            // Find the line item that has a SecurityLineItem, or the first line item
            let lineItems = Self.relatedSet(tx, "lineItems")
            var targetLI: NSManagedObject?
            var existingSLI: NSManagedObject?

            for li in lineItems {
                if let sli = Self.relatedObject(li, "pSecurityLineItem") {
                    targetLI = li
                    existingSLI = sli
                    break
                }
            }

            // If no SecurityLineItem found, use first line item with an account and create one
            if targetLI == nil {
                targetLI = lineItems.first
            }

            guard let li = targetLI else {
                throw ToolError.notFound("No line items found for transaction \(transactionId)")
            }

            let sli: NSManagedObject
            if let existing = existingSLI {
                sli = existing
            } else {
                // Create a new SecurityLineItem
                sli = Self.createObject(entityName: "SecurityLineItem", in: ctx)
                sli.setValue(0.0 as NSNumber, forKey: "pShares")
                sli.setValue(0.0 as NSNumber, forKey: "pAmount")
                sli.setValue(0.0 as NSNumber, forKey: "pPricePerShare")
                sli.setValue(0.0 as NSNumber, forKey: "pCommission")
                sli.setValue(0.0 as NSNumber, forKey: "pIncome")
                sli.setValue(1.0 as NSNumber, forKey: "pPriceMultiplier")
                sli.setValue(li, forKey: "pLineItem")
            }

            if let shares = shares {
                sli.setValue(shares as NSNumber, forKey: "pShares")
            }
            if let pricePerShare = pricePerShare {
                sli.setValue(pricePerShare as NSNumber, forKey: "pPricePerShare")
            }
            if let amount = amount {
                sli.setValue(amount as NSNumber, forKey: "pAmount")
            }
            if let secObjID = newSecurityObjectID,
               let secInCtx = try? ctx.existingObject(with: secObjID) {
                sli.setValue(secInCtx, forKey: "pSecurity")
            }

            let cashSync: CashSyncInfo?
            if let cashLineItemAmount = cashLineItemAmount {
                guard let account = Self.relatedObject(li, "pAccount") else {
                    throw ToolError.invalidInput("Cash line repair requires the security line item to belong to an account")
                }
                let offsetCandidates = lineItems.filter { candidate in
                    candidate.objectID != li.objectID && Self.relatedObject(candidate, "pAccount") == nil
                }
                guard offsetCandidates.count == 1 else {
                    throw ToolError.invalidInput("Cash line repair requires exactly one balancing line item without an account")
                }
                let offsetLI = offsetCandidates.first!
                let offsetAmount = -cashLineItemAmount
                li.setValue(cashLineItemAmount as NSNumber, forKey: "pTransactionAmount")
                offsetLI.setValue(offsetAmount as NSNumber, forKey: "pTransactionAmount")
                cashSync = CashSyncInfo(
                    accountId: Self.extractPK(from: account.objectID),
                    cashLineItemUUID: Self.stringValue(li, "pUniqueID"),
                    cashAmount: cashLineItemAmount,
                    offsetLineItemUUID: Self.stringValue(offsetLI, "pUniqueID"),
                    offsetAmount: offsetAmount
                )
            } else {
                cashSync = nil
            }

            Self.setNow(tx, "pModificationDate")

            // Build return DTO
            let txDate: String
            if let d = Self.dateValue(tx, "pDate") {
                txDate = DateConversion.toISO(d)
            } else {
                txDate = ""
            }

            // ZTRANSACTIONTYPE maps the base type to its name and is Banktivity's
            // own authority for it; read the label rather than re-deriving it.
            let typeName: String = {
                if let txType = Self.relatedObject(tx, "pTransactionType") {
                    return Self.stringValue(txType, "pName")
                }
                return ""
            }()

            let security = Self.relatedObject(sli, "pSecurity")
            let account = Self.relatedObject(li, "pAccount")

            let trade = SecurityTradeDTO(
                id: transactionId,
                date: txDate,
                type: typeName,
                symbol: security.map { Self.stringValue($0, "pSymbol") } ?? "",
                securityName: security.map { Self.stringValue($0, "pName") } ?? "",
                shares: Self.doubleValue(sli, "pShares"),
                pricePerShare: Self.doubleValue(sli, "pPricePerShare"),
                amount: Self.doubleValue(sli, "pAmount"),
                commission: Self.doubleValue(sli, "pCommission"),
                accountName: account.map { Self.stringValue($0, "pName") } ?? "",
                accountId: account.map { Self.extractPK(from: $0.objectID) } ?? 0
            )

            let txUUID = Self.stringValue(tx, "pUniqueID")
            let liUUID = Self.stringValue(li, "pUniqueID")

            return UpdateResult(txUUID: txUUID, liUUID: liUUID, trade: trade, cashSync: cashSync)
        }

        if let cashSync = result.cashSync {
            try LineItemRepository(container: container).recalculateRunningBalances(accountId: cashSync.accountId)
        }

        // Patch sync blob (non-fatal)
        if let updater = syncBlobUpdater {
            // Pre-format values for the sendable closure
            let liUUID = result.liUUID
            let sharesStr = shares.map { updater.formatDecimalPublic($0) }
            let ppsStr = pricePerShare.map { updater.formatDecimalPublic($0) }
            let amountStr = amount.map { updater.formatDecimalPublic($0) }
            let secRef = newSecurityUUID.map { "Security:\($0)" }
            let cashSync = result.cashSync

            updater.updateTransactionBlob(transactionUUID: result.txUUID) { xml in
                var patched = xml
                if let v = sharesStr {
                    patched = SyncBlobUpdater.patchSecurityLineItemFieldStatic(
                        xml: patched, lineItemUUID: liUUID, fieldName: "shares", fieldType: "decimal", value: v)
                }
                if let v = ppsStr {
                    patched = SyncBlobUpdater.patchSecurityLineItemFieldStatic(
                        xml: patched, lineItemUUID: liUUID, fieldName: "pricePerShare", fieldType: "decimal", value: v)
                }
                if let v = amountStr {
                    patched = SyncBlobUpdater.patchSecurityLineItemFieldStatic(
                        xml: patched, lineItemUUID: liUUID, fieldName: "cost", fieldType: "decimal", value: v)
                }
                if let v = secRef {
                    patched = SyncBlobUpdater.patchSecurityLineItemFieldStatic(
                        xml: patched, lineItemUUID: liUUID, fieldName: "security", fieldType: "reference", value: v)
                }
                if let cashSync {
                    patched = updater.patchLineItemAmounts(
                        xml: patched,
                        lineItemUUID: cashSync.cashLineItemUUID,
                        accountAmount: cashSync.cashAmount,
                        transactionAmount: cashSync.cashAmount
                    )
                    patched = updater.patchLineItemAmounts(
                        xml: patched,
                        lineItemUUID: cashSync.offsetLineItemUUID,
                        accountAmount: cashSync.offsetAmount,
                        transactionAmount: cashSync.offsetAmount
                    )
                }
                return patched
            }
        }

        return result.trade
    }

    public func importPricesFromCSV(
        filePath: String,
        symbol: String? = nil,
        id: Int? = nil,
        hasHeader: Bool = true,
        dateFormat: String = "yyyy-MM-dd"
    ) throws -> PriceImportResultDTO {
        struct ImportSecInfo: Sendable {
            let symbol: String
            let uniqueId: String
        }

        let importSecInfo: ImportSecInfo = try performRead { [self] ctx in
            let sec: NSManagedObject
            if let id = id {
                guard let s = try fetchByPK(entityName: "Security", pk: id, in: ctx) else {
                    throw ToolError.notFound("Security not found: \(id)")
                }
                sec = s
            } else {
                guard let sym = symbol else {
                    throw ToolError.missingParameter("Either symbol or id is required")
                }
                let req = NSFetchRequest<NSManagedObject>(entityName: "Security")
                req.predicate = NSPredicate(format: "pSymbol ==[c] %@", sym)
                req.fetchLimit = 1
                guard let s = try ctx.fetch(req).first else {
                    throw ToolError.notFound("Security not found: \(sym)")
                }
                sec = s
            }
            return ImportSecInfo(
                symbol: Self.stringValue(sec, "pSymbol"),
                uniqueId: Self.stringValue(sec, "pUniqueID")
            )
        }
        let securitySymbol = importSecInfo.symbol
        let securityUniqueId = importSecInfo.uniqueId
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

            // Find the latest price to update the Security sync blob
            let allPriceRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityPrice")
            allPriceRequest.predicate = NSPredicate(format: "pSecurityPriceItem == %@", priceItem)
            allPriceRequest.sortDescriptors = [NSSortDescriptor(key: "pDate", ascending: false)]
            allPriceRequest.fetchLimit = 1
            let latestPrice = try ctx.fetch(allPriceRequest).first
            let latestClosePrice = (latestPrice?.value(forKey: "pClosePrice") as? NSNumber)?.doubleValue
            let latestDateDays = (latestPrice?.value(forKey: "pDate") as? Int32)

            let dateRangeBegin: String? = allDates.min().map { Self.daysSinceEpochToISO($0) }
            let dateRangeEnd: String? = allDates.max().map { Self.daysSinceEpochToISO($0) }

            return PriceImportResultDTO(
                securitySymbol: securitySymbol,
                imported: imported,
                skipped: skipped,
                totalPrices: allDates.count,
                dateRangeBegin: dateRangeBegin,
                dateRangeEnd: dateRangeEnd,
                latestClosePrice: latestClosePrice,
                latestDateISO: latestDateDays.map { Self.daysSinceEpochToISO($0) }
            )
        }

        // Fix closePrice=0 records created by the import.
        // Banktivity's custom IGGCAccountingSecurityPrice class resets pClosePrice
        // to 0 on insert, leaving the value only in pAdjustedClosePrice.
        _ = try? fixBrokenPrices(symbol: securitySymbol)

        // Update Security sync blob with latest price
        if let price = result.latestClosePrice, let date = result.latestDateISO {
            syncBlobUpdater?.updateSecurityLatestPrice(
                securityUUID: securityUniqueId, closePrice: price, date: date
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
        let priceItemObjectID: NSManagedObjectID? = try performRead { [self] ctx in
            let security: NSManagedObject
            if let id = id {
                guard let s = try fetchByPK(entityName: "Security", pk: id, in: ctx) else { return nil }
                security = s
            } else {
                guard let sym = symbol else { return nil }
                let req = NSFetchRequest<NSManagedObject>(entityName: "Security")
                req.predicate = NSPredicate(format: "pSymbol ==[c] %@", sym)
                req.fetchLimit = 1
                guard let s = try ctx.fetch(req).first else { return nil }
                security = s
            }
            let uniqueId = Self.stringValue(security, "pUniqueID")
            let piRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityPriceItem")
            piRequest.predicate = NSPredicate(format: "pSecurityID == %@", uniqueId)
            piRequest.fetchLimit = 1
            return try ctx.fetch(piRequest).first?.objectID
        }
        guard let priceItemObjectID = priceItemObjectID else { return 0 }

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

    /// Fix price records where closePrice=0 but adjustedClosePrice has the actual value.
    /// Optionally filter by symbol. Returns per-security fix counts and updates sync blobs.
    public func fixBrokenPrices(symbol: String? = nil) throws -> [(symbol: String, fixed: Int)] {
        // Gather broken price info on the context's thread
        struct BrokenPriceInfo: Sendable {
            let objectIDs: [NSManagedObjectID]
            let piToSymbol: [NSManagedObjectID: String]
            let piToSecurityUUID: [NSManagedObjectID: String]
        }

        let info: BrokenPriceInfo = try performRead { ctx in
            // Find broken prices: closePrice=0 AND adjustedClosePrice != 0
            let priceRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityPrice")
            priceRequest.predicate = NSPredicate(format: "pClosePrice == 0 AND pAdjustedClosePrice != 0")
            let brokenPrices = try ctx.fetch(priceRequest)

            if brokenPrices.isEmpty {
                return BrokenPriceInfo(objectIDs: [], piToSymbol: [:], piToSecurityUUID: [:])
            }

            // Group by security for reporting
            var securityPriceItems = Set<NSManagedObjectID>()
            for price in brokenPrices {
                if let pi = Self.relatedObject(price, "pSecurityPriceItem") {
                    securityPriceItems.insert(pi.objectID)
                }
            }

            // Build mapping of SecurityPriceItem objectID → symbol
            var piToSymbol: [NSManagedObjectID: String] = [:]
            var piToSecurityUUID: [NSManagedObjectID: String] = [:]
            for piObjID in securityPriceItems {
                if let pi = try? ctx.existingObject(with: piObjID) {
                    let securityID = Self.stringValue(pi, "pSecurityID")
                    let secRequest = NSFetchRequest<NSManagedObject>(entityName: "Security")
                    secRequest.predicate = NSPredicate(format: "pUniqueID == %@", securityID)
                    secRequest.fetchLimit = 1
                    if let sec = try ctx.fetch(secRequest).first {
                        let sym = Self.stringValue(sec, "pSymbol")
                        piToSymbol[piObjID] = sym
                        piToSecurityUUID[piObjID] = securityID
                    }
                }
            }

            // Filter by symbol if specified
            let objectIDs: [NSManagedObjectID]
            if let filterSymbol = symbol {
                objectIDs = brokenPrices.filter { price in
                    guard let pi = Self.relatedObject(price, "pSecurityPriceItem") else { return false }
                    return piToSymbol[pi.objectID] == filterSymbol
                }.map(\.objectID)
            } else {
                objectIDs = brokenPrices.map(\.objectID)
            }

            return BrokenPriceInfo(objectIDs: objectIDs, piToSymbol: piToSymbol, piToSecurityUUID: piToSecurityUUID)
        }

        let brokenPriceObjectIDs = info.objectIDs
        if brokenPriceObjectIDs.isEmpty { return [] }

        // Capture as let for Sendable closure
        let symbolLookup = info.piToSymbol
        let uuidLookup = info.piToSecurityUUID

        // Fix in a write context
        struct FixResult: Sendable {
            let counts: [String: Int]
            let latestPrices: [String: (price: Double, date: String)] // securityUUID → latest price
        }

        let fixResult: FixResult = try performWriteReturning { ctx in
            var counts: [String: Int] = [:]
            var latestByUUID: [String: (price: Double, daysSinceEpoch: Int32)] = [:]

            for objID in brokenPriceObjectIDs {
                guard let price = try? ctx.existingObject(with: objID) else { continue }
                let adjClose = Self.doubleValue(price, "pAdjustedClosePrice")
                price.setValue(adjClose as NSNumber, forKey: "pClosePrice")

                if let pi = Self.relatedObject(price, "pSecurityPriceItem") {
                    let sym = symbolLookup[pi.objectID] ?? "unknown"
                    counts[sym, default: 0] += 1

                    let secUUID = uuidLookup[pi.objectID] ?? ""
                    let days = Self.intValue(price, "pDate")
                    if let existing = latestByUUID[secUUID] {
                        if Int32(days) > existing.daysSinceEpoch {
                            latestByUUID[secUUID] = (price: adjClose, daysSinceEpoch: Int32(days))
                        }
                    } else {
                        latestByUUID[secUUID] = (price: adjClose, daysSinceEpoch: Int32(days))
                    }
                }
            }

            // Convert daysSinceEpoch to ISO date strings
            var latestPrices: [String: (price: Double, date: String)] = [:]
            for (uuid, info) in latestByUUID {
                let dateStr = Self.daysSinceEpochToISO(info.daysSinceEpoch)
                latestPrices[uuid] = (price: info.price, date: dateStr)
            }

            return FixResult(counts: counts, latestPrices: latestPrices)
        }

        // Update sync blobs for affected securities
        if let updater = syncBlobUpdater {
            for (uuid, info) in fixResult.latestPrices {
                updater.updateSecurityLatestPrice(
                    securityUUID: uuid, closePrice: info.price, date: info.date
                )
            }
        }

        return fixResult.counts.map { (symbol: $0.key, fixed: $0.value) }.sorted { $0.symbol < $1.symbol }
    }

    // MARK: - Holdings, Trades, Income

    public func getHoldings(
        accountId: Int? = nil,
        symbol: String? = nil,
        id: Int? = nil
    ) throws -> [SecurityHoldingDTO] {
        try performRead { [self] ctx in
            // Optionally resolve a specific security
            var targetSecurity: NSManagedObject?
            if let id = id {
                targetSecurity = try fetchByPK(entityName: "Security", pk: id, in: ctx)
            } else if let sym = symbol {
                let req = NSFetchRequest<NSManagedObject>(entityName: "Security")
                req.predicate = NSPredicate(format: "pSymbol ==[c] %@", sym)
                req.fetchLimit = 1
                targetSecurity = try ctx.fetch(req).first
            }

            // Fetch all SecurityLineItems with non-null pShares
            let request = NSFetchRequest<NSManagedObject>(entityName: "SecurityLineItem")
            var predicates: [NSPredicate] = [
                NSPredicate(format: "pShares != nil")
            ]
            if let targetSecurity = targetSecurity {
                predicates.append(NSPredicate(format: "pSecurity == %@", targetSecurity))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            let items = try ctx.fetch(request)

            // Group by (account PK, security PK)
            struct PositionKey: Hashable {
                let accountPK: Int
                let securityPK: Int
            }
            struct PositionAccum {
                var shares: Double = 0
                var costBasis: Double = 0
                var account: NSManagedObject?
                var security: NSManagedObject?
            }

            var positions: [PositionKey: PositionAccum] = [:]

            for sli in items {
                guard let security = Self.relatedObject(sli, "pSecurity") else { continue }
                guard let lineItem = Self.relatedObject(sli, "pLineItem") else { continue }
                guard let account = Self.relatedObject(lineItem, "pAccount") else { continue }

                let acctPK = Self.extractPK(from: account.objectID)
                if let filterAcct = accountId, acctPK != filterAcct { continue }

                let secPK = Self.extractPK(from: security.objectID)
                let key = PositionKey(accountPK: acctPK, securityPK: secPK)

                let shares = Self.doubleValue(sli, "pShares")
                let amount = Self.doubleValue(sli, "pAmount")

                var accum = positions[key] ?? PositionAccum()
                accum.shares += shares
                // Buy amounts are negative (outflow), so negate for cost basis
                if shares > 0 {
                    accum.costBasis += -amount
                }
                accum.account = account
                accum.security = security
                positions[key] = accum
            }

            // Filter out zero-share positions and build DTOs
            var results: [SecurityHoldingDTO] = []
            for (_, accum) in positions {
                guard abs(accum.shares) > 0.0001 else { continue }
                guard let account = accum.account, let security = accum.security else { continue }

                let securityId = Self.extractPK(from: security.objectID)
                let secSymbol = Self.stringValue(security, "pSymbol")
                let secName = Self.stringValue(security, "pName")
                let uniqueId = Self.stringValue(security, "pUniqueID")

                // Look up latest price
                var lastPrice: Double?
                var lastPriceDate: String?
                let piRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityPriceItem")
                piRequest.predicate = NSPredicate(format: "pSecurityID == %@", uniqueId)
                piRequest.fetchLimit = 1
                if let priceItem = try ctx.fetch(piRequest).first {
                    let priceRequest = NSFetchRequest<NSManagedObject>(entityName: "SecurityPrice")
                    priceRequest.predicate = NSPredicate(format: "pSecurityPriceItem == %@", priceItem)
                    priceRequest.sortDescriptors = [NSSortDescriptor(key: "pDate", ascending: false)]
                    priceRequest.fetchLimit = 1
                    if let latestPrice = try ctx.fetch(priceRequest).first {
                        lastPrice = Self.doubleValue(latestPrice, "pClosePrice")
                        let dateInt = (latestPrice.value(forKey: "pDate") as? Int32) ?? 0
                        lastPriceDate = Self.daysSinceEpochToISO(dateInt)
                    }
                }

                let marketValue = lastPrice.map { $0 * accum.shares }
                let currency: String? = {
                    if let curr = Self.relatedObject(security, "pCurrency") {
                        return Self.string(curr, "pCode")
                    }
                    return nil
                }()

                results.append(SecurityHoldingDTO(
                    accountId: Self.extractPK(from: account.objectID),
                    accountName: Self.stringValue(account, "pName"),
                    securityId: securityId,
                    symbol: secSymbol,
                    securityName: secName,
                    shares: accum.shares,
                    costBasis: accum.costBasis,
                    marketValue: marketValue,
                    lastPrice: lastPrice,
                    lastPriceDate: lastPriceDate,
                    currency: currency
                ))
            }

            return results.sorted { ($0.accountName, $0.symbol) < ($1.accountName, $1.symbol) }
        }
    }

    public func getTrades(
        accountId: Int? = nil,
        symbol: String? = nil,
        id: Int? = nil,
        startDate: String? = nil,
        endDate: String? = nil,
        limit: Int? = nil
    ) throws -> [SecurityTradeDTO] {
        try performRead { [self] ctx in
            var targetSecurity: NSManagedObject?
            if let id = id {
                targetSecurity = try fetchByPK(entityName: "Security", pk: id, in: ctx)
            } else if let sym = symbol {
                let req = NSFetchRequest<NSManagedObject>(entityName: "Security")
                req.predicate = NSPredicate(format: "pSymbol ==[c] %@", sym)
                req.fetchLimit = 1
                targetSecurity = try ctx.fetch(req).first
            }

            let request = NSFetchRequest<NSManagedObject>(entityName: "SecurityLineItem")
            var predicates: [NSPredicate] = [
                NSPredicate(format: "pShares != nil")
            ]
            if let targetSecurity = targetSecurity {
                predicates.append(NSPredicate(format: "pSecurity == %@", targetSecurity))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            let items = try ctx.fetch(request)

            var trades: [SecurityTradeDTO] = []
            for sli in items {
                guard let security = Self.relatedObject(sli, "pSecurity") else { continue }
                guard let lineItem = Self.relatedObject(sli, "pLineItem") else { continue }
                guard let account = Self.relatedObject(lineItem, "pAccount") else { continue }
                guard let transaction = Self.relatedObject(lineItem, "pTransaction") else { continue }

                let acctPK = Self.extractPK(from: account.objectID)
                if let filterAcct = accountId, acctPK != filterAcct { continue }

                guard let txDate = Self.dateValue(transaction, "pDate") else { continue }
                let dateStr = DateConversion.toISO(txDate)

                if let start = startDate, dateStr < start { continue }
                if let end = endDate, dateStr > end { continue }

                // ZTRANSACTIONTYPE maps the base type to its name and is Banktivity's
                // own authority for it; read the label rather than re-deriving it.
                let typeName: String = {
                    if let txType = Self.relatedObject(transaction, "pTransactionType") {
                        return Self.stringValue(txType, "pName")
                    }
                    return ""
                }()

                trades.append(SecurityTradeDTO(
                    id: Self.extractPK(from: transaction.objectID),
                    date: dateStr,
                    type: typeName,
                    symbol: Self.stringValue(security, "pSymbol"),
                    securityName: Self.stringValue(security, "pName"),
                    shares: Self.doubleValue(sli, "pShares"),
                    pricePerShare: Self.doubleValue(sli, "pPricePerShare"),
                    amount: Self.doubleValue(sli, "pAmount"),
                    commission: Self.doubleValue(sli, "pCommission"),
                    accountName: Self.stringValue(account, "pName"),
                    accountId: acctPK
                ))
            }

            trades.sort { $0.date > $1.date }
            if let limit = limit { return Array(trades.prefix(limit)) }
            return trades
        }
    }

    public func getIncome(
        accountId: Int? = nil,
        symbol: String? = nil,
        id: Int? = nil,
        startDate: String? = nil,
        endDate: String? = nil
    ) throws -> [SecurityIncomeDTO] {
        try performRead { [self] ctx in
            var targetSecurity: NSManagedObject?
            if let id = id {
                targetSecurity = try fetchByPK(entityName: "Security", pk: id, in: ctx)
            } else if let sym = symbol {
                let req = NSFetchRequest<NSManagedObject>(entityName: "Security")
                req.predicate = NSPredicate(format: "pSymbol ==[c] %@", sym)
                req.fetchLimit = 1
                targetSecurity = try ctx.fetch(req).first
            }

            let request = NSFetchRequest<NSManagedObject>(entityName: "SecurityLineItem")
            var predicates: [NSPredicate] = [
                NSPredicate(format: "pIncome > 0")
            ]
            if let targetSecurity = targetSecurity {
                predicates.append(NSPredicate(format: "pSecurity == %@", targetSecurity))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            let items = try ctx.fetch(request)

            var incomes: [SecurityIncomeDTO] = []
            for sli in items {
                guard let security = Self.relatedObject(sli, "pSecurity") else { continue }
                guard let lineItem = Self.relatedObject(sli, "pLineItem") else { continue }
                guard let account = Self.relatedObject(lineItem, "pAccount") else { continue }
                guard let transaction = Self.relatedObject(lineItem, "pTransaction") else { continue }

                let acctPK = Self.extractPK(from: account.objectID)
                if let filterAcct = accountId, acctPK != filterAcct { continue }

                guard let txDate = Self.dateValue(transaction, "pDate") else { continue }
                let dateStr = DateConversion.toISO(txDate)

                if let start = startDate, dateStr < start { continue }
                if let end = endDate, dateStr > end { continue }

                // ZTRANSACTIONTYPE maps the base type to its name and is Banktivity's
                // own authority for it; read the label rather than re-deriving it.
                let typeName: String = {
                    if let txType = Self.relatedObject(transaction, "pTransactionType") {
                        return Self.stringValue(txType, "pName")
                    }
                    return ""
                }()

                incomes.append(SecurityIncomeDTO(
                    id: Self.extractPK(from: transaction.objectID),
                    date: dateStr,
                    type: typeName,
                    symbol: Self.stringValue(security, "pSymbol"),
                    securityName: Self.stringValue(security, "pName"),
                    amount: Self.doubleValue(sli, "pIncome"),
                    accountName: Self.stringValue(account, "pName"),
                    accountId: acctPK
                ))
            }

            return incomes.sorted { $0.date > $1.date }
        }
    }

    // MARK: - Transaction Type Mapping


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
