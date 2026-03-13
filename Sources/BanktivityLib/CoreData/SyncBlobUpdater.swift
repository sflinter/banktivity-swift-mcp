// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Compression

public final class SyncBlobUpdater: @unchecked Sendable {
    private let container: NSPersistentContainer

    public init(container: NSPersistentContainer) {
        self.container = container
    }

    // MARK: - Sync Record Creation Structs

    public struct SyncLineItem: Sendable {
        public let accountUUID: String?
        public let accountAmount: Double
        public let cleared: Bool
        public let identifier: String
        public let memo: String?
        public let securityLineItem: SyncSecurityLineItem?
        public let transactionAmount: Double

        public init(accountUUID: String?, accountAmount: Double, cleared: Bool, identifier: String, memo: String?, securityLineItem: SyncSecurityLineItem?, transactionAmount: Double) {
            self.accountUUID = accountUUID
            self.accountAmount = accountAmount
            self.cleared = cleared
            self.identifier = identifier
            self.memo = memo
            self.securityLineItem = securityLineItem
            self.transactionAmount = transactionAmount
        }
    }

    public struct SyncSecurityLineItem: Sendable {
        public let amount: Double
        public let commission: Double
        public let pricePerShare: Double
        public let priceMultiplier: Double
        public let securityUUID: String
        public let shares: Double
        public let hasDistributionType: Bool

        public init(amount: Double, commission: Double, pricePerShare: Double, priceMultiplier: Double, securityUUID: String, shares: Double, hasDistributionType: Bool) {
            self.amount = amount
            self.commission = commission
            self.pricePerShare = pricePerShare
            self.priceMultiplier = priceMultiplier
            self.securityUUID = securityUUID
            self.shares = shares
            self.hasDistributionType = hasDistributionType
        }
    }

    // MARK: - High-level API

    public func updateTransactionBlob(transactionUUID: String, using transform: @Sendable (String) -> String) {
        do {
            try performBlobUpdate(entityUUID: transactionUUID, transform: transform)
        } catch {
            log("Failed to update sync blob for transaction \(transactionUUID): \(error)")
        }
    }

    public func deleteSyncRecord(entityUUID: String) {
        do {
            let bgContext = container.newBackgroundContext()
            nonisolated(unsafe) var writeError: Error?
            bgContext.performAndWait {
                do {
                    guard let record = try self.fetchSyncRecord(entityUUID: entityUUID, in: bgContext) else {
                        return
                    }
                    bgContext.delete(record)
                    try bgContext.save()
                } catch {
                    writeError = error
                }
            }
            if let error = writeError { throw error }
        } catch {
            log("Failed to delete sync record for \(entityUUID): \(error)")
        }
    }

    // MARK: - Sync Record Creation

    public func createTransactionSyncRecord(
        transactionUUID: String, currencyUUID: String, date: String,
        title: String, note: String?, adjustment: Bool,
        lineItems: [SyncLineItem],
        transactionTypeBaseType: String, transactionTypeUUID: String
    ) {
        do {
            let xml = buildTransactionXML(
                transactionUUID: transactionUUID, currencyUUID: currencyUUID, date: date,
                title: title, note: note, adjustment: adjustment,
                lineItems: lineItems,
                transactionTypeBaseType: transactionTypeBaseType,
                transactionTypeUUID: transactionTypeUUID
            )

            guard let xmlData = xml.data(using: .utf8),
                  let compressed = Self.compressGzip(xmlData) else {
                log("Failed to compress sync blob for new transaction \(transactionUUID)")
                return
            }

            let bgContext = container.newBackgroundContext()
            nonisolated(unsafe) var writeError: Error?
            bgContext.performAndWait {
                do {
                    let record = NSEntityDescription.insertNewObject(forEntityName: "SyncedHostedEntity", into: bgContext)
                    record.setValue(transactionUUID, forKey: "pLocalID")
                    record.setValue(transactionUUID, forKey: "pRemoteID")
                    record.setValue("Transaction", forKey: "pHostedEntityType")
                    record.setValue(Int16(0), forKey: "pSyncedState")
                    record.setValue(nil, forKey: "pSyncedModificationDate")
                    record.setValue(compressed, forKey: "pRemoteEntityData")

                    // Link to SyncedDocument if one exists
                    let docRequest = NSFetchRequest<NSManagedObject>(entityName: "SyncedDocument")
                    docRequest.fetchLimit = 1
                    if let doc = try bgContext.fetch(docRequest).first {
                        record.setValue(doc, forKey: "pDocument")
                    }

                    try bgContext.save()
                } catch {
                    writeError = error
                }
            }
            if let error = writeError { throw error }
        } catch {
            log("Failed to create sync record for transaction \(transactionUUID): \(error)")
        }
    }

    private func buildTransactionXML(
        transactionUUID: String, currencyUUID: String, date: String,
        title: String, note: String?, adjustment: Bool,
        lineItems: [SyncLineItem],
        transactionTypeBaseType: String, transactionTypeUUID: String
    ) -> String {
        var xml = "<entity type=\"Transaction\" id=\"\(transactionUUID)\">"
        xml += "<field type=\"bool\" name=\"adjustment\">\(adjustment ? "yes" : "no")</field>"
        xml += "<field type=\"int\" name=\"checkNumber\" null=\"null\"/>"
        xml += "<field type=\"reference\" name=\"currency\">Currency:\(currencyUUID)</field>"
        xml += "<field type=\"date\" name=\"date\">\(date)T00:00:00+0000</field>"
        xml += "<collection type=\"array\" name=\"lineItems\">"

        for li in lineItems {
            xml += "<record type=\"LineItem\" name=\"element\">"
            if let acctUUID = li.accountUUID {
                xml += "<field type=\"reference\" name=\"account\">Account:\(acctUUID)</field>"
            } else {
                xml += "<field type=\"reference\" name=\"account\" null=\"null\"/>"
            }
            xml += "<field type=\"decimal\" name=\"accountAmount\">\(formatDecimal(li.accountAmount))</field>"
            xml += "<field type=\"bool\" name=\"cleared\">\(li.cleared ? "yes" : "no")</field>"
            xml += "<field type=\"string\" name=\"identifier\">\(li.identifier)</field>"
            xml += "<collection type=\"array\" name=\"lineItemSources\" null=\"null\"/>"
            if let memo = li.memo {
                xml += "<field type=\"string\" name=\"memo\">\(escapeXML(memo))</field>"
            } else {
                xml += "<field type=\"string\" name=\"memo\" null=\"null\"/>"
            }

            if let sli = li.securityLineItem {
                xml += "<record type=\"SecurityLineItem\" name=\"securityLineItem\">"
                if sli.hasDistributionType {
                    xml += "<field type=\"decimal\" name=\"commission\">\(formatDecimal(sli.commission))</field>"
                } else {
                    xml += "<field type=\"decimal\" name=\"commission\" null=\"null\"/>"
                }
                xml += "<field type=\"decimal\" name=\"cost\">\(formatDecimal(sli.amount))</field>"
                xml += "<field enum=\"IGGCSyncAccountingSecurityCostBasisMethod\" name=\"costBasisMethod\">unknown</field>"
                if sli.hasDistributionType {
                    xml += "<field enum=\"IGGCSyncAccountingSecurityLineItemDistrbutionType\" name=\"distributionType\">deposit</field>"
                }
                xml += "<field type=\"decimal\" name=\"income\" null=\"null\"/>"
                xml += "<collection type=\"array\" name=\"openingLots\" null=\"null\"/>"
                xml += "<field type=\"date\" name=\"overrideDate\" null=\"null\"/>"
                xml += "<field type=\"decimal\" name=\"pricePerShare\">\(formatDecimal(sli.pricePerShare))</field>"
                xml += "<field type=\"reference\" name=\"security\">Security:\(sli.securityUUID)</field>"
                xml += "<field type=\"decimal\" name=\"shares\">\(formatDecimal(sli.shares))</field>"
                xml += "<field type=\"decimal\" name=\"valueMultiplier\">\(formatDecimal(sli.priceMultiplier))</field>"
                xml += "</record>"
            } else {
                xml += "<record type=\"SecurityLineItem\" name=\"securityLineItem\" null=\"null\"/>"
            }

            xml += "<field type=\"int\" name=\"sortIndex\">0</field>"
            xml += "<field type=\"reference\" name=\"statement\" null=\"null\"/>"
            xml += "<collection type=\"set\" name=\"tags\" null=\"null\"/>"
            xml += "<field type=\"decimal\" name=\"transacitonAmount\">\(formatDecimal(li.transactionAmount))</field>"
            xml += "</record>"
        }

        xml += "</collection>"
        if let note = note {
            xml += "<field type=\"string\" name=\"note\">\(escapeXML(note))</field>"
        } else {
            xml += "<field type=\"string\" name=\"note\" null=\"null\"/>"
        }
        xml += "<field type=\"string\" name=\"title\">\(escapeXML(title))</field>"
        xml += "<record type=\"TransactionType\" name=\"transactionType\">"
        xml += "<field enum=\"IGGCSyncAccountingTransactionBaseType\" name=\"baseType\">\(transactionTypeBaseType)</field>"
        xml += "<field type=\"reference\" name=\"transactionType\">TransactionTypeV2:\(transactionTypeUUID)</field>"
        xml += "</record>"
        xml += "</entity>"
        return xml
    }

    private func formatDecimal(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        let s = String(value)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    // MARK: - XML Patching: Reconciliation

    public func patchCleared(xml: String, lineItemUUID: String, cleared: Bool) -> String {
        guard let range = lineItemRecordRange(in: xml, lineItemUUID: lineItemUUID) else { return xml }
        let record = String(xml[range])
        let value = cleared ? "yes" : "no"

        guard let patched = replaceField(in: record, name: "cleared", type: "bool", newContent: value) else {
            return xml
        }
        return xml.replacingCharacters(in: range, with: patched)
    }

    public func patchStatement(xml: String, lineItemUUID: String, statementUUID: String?) -> String {
        guard let range = lineItemRecordRange(in: xml, lineItemUUID: lineItemUUID) else { return xml }
        let record = String(xml[range])

        let patched: String
        if let uuid = statementUUID {
            // Set statement reference
            let newValue = "Statement:\(uuid)"
            if let result = replaceField(in: record, name: "statement", type: "reference", newContent: newValue) {
                patched = result
            } else if let result = replaceNullField(in: record, name: "statement", type: "reference", newContent: newValue) {
                patched = result
            } else {
                return xml
            }
        } else {
            // Set statement to null
            if let result = setFieldNull(in: record, name: "statement", type: "reference") {
                patched = result
            } else {
                return xml
            }
        }
        return xml.replacingCharacters(in: range, with: patched)
    }

    // MARK: - XML Patching: Recategorize

    public func patchAccount(xml: String, lineItemUUID: String, accountUUID: String) -> String {
        guard let range = lineItemRecordRange(in: xml, lineItemUUID: lineItemUUID) else { return xml }
        let record = String(xml[range])
        let newValue = "Account:\(accountUUID)"

        guard let patched = replaceField(in: record, name: "account", type: "reference", newContent: newValue) else {
            return xml
        }
        return xml.replacingCharacters(in: range, with: patched)
    }

    // MARK: - XML Patching: Tags

    public func patchTags(xml: String, lineItemUUID: String, tagUUIDs: [String]) -> String {
        guard let range = lineItemRecordRange(in: xml, lineItemUUID: lineItemUUID) else { return xml }
        let record = String(xml[range])

        let patched: String
        if tagUUIDs.isEmpty {
            // Set tags to null collection
            if let result = setCollectionNull(in: record, name: "tags") {
                patched = result
            } else {
                return xml
            }
        } else {
            // Build tags collection content
            var elements = ""
            for uuid in tagUUIDs {
                elements += "\n        <field type=\"reference\" name=\"element\">Tag:\(uuid)</field>"
            }
            let newCollection = "<collection type=\"set\" name=\"tags\">\(elements)\n      </collection>"

            if let result = replaceCollection(in: record, name: "tags", newCollection: newCollection) {
                patched = result
            } else if let result = replaceNullCollection(in: record, name: "tags", newCollection: newCollection) {
                patched = result
            } else {
                return xml
            }
        }
        return xml.replacingCharacters(in: range, with: patched)
    }

    // MARK: - XML Patching: Transaction-level fields

    public func patchTransactionTitle(xml: String, title: String) -> String {
        replaceField(in: xml, name: "title", type: "string", newContent: escapeXML(title)) ?? xml
    }

    public func patchTransactionNote(xml: String, note: String?) -> String {
        if let note = note {
            if let result = replaceField(in: xml, name: "note", type: "string", newContent: escapeXML(note)) {
                return result
            }
            return replaceNullField(in: xml, name: "note", type: "string", newContent: escapeXML(note)) ?? xml
        } else {
            return setFieldNull(in: xml, name: "note", type: "string") ?? xml
        }
    }

    public func patchTransactionDate(xml: String, date: String) -> String {
        replaceField(in: xml, name: "date", type: "date", newContent: date) ?? xml
    }

    public func patchTransactionType(xml: String, baseType: String, typeUUID: String) -> String {
        // Replace the entire TransactionType record block
        guard let recordStart = xml.range(of: "<record type=\"TransactionType\" name=\"transactionType\">"),
              let recordEnd = xml.range(of: "</record>", range: recordStart.upperBound..<xml.endIndex) else {
            return xml
        }
        let newRecord = "<record type=\"TransactionType\" name=\"transactionType\">" +
            "<field enum=\"IGGCSyncAccountingTransactionBaseType\" name=\"baseType\">\(baseType)</field>" +
            "<field type=\"reference\" name=\"transactionType\">TransactionTypeV2:\(typeUUID)</field>" +
            "</record>"
        var result = xml
        result.replaceSubrange(recordStart.lowerBound..<recordEnd.upperBound, with: newRecord)
        return result
    }

    // MARK: - XML Patching: SecurityLineItem fields

    public static func patchSecurityLineItemFieldStatic(xml: String, lineItemUUID: String, fieldName: String, fieldType: String, value: String) -> String {
        // Find the line item record by UUID
        let identifierPattern = "<field type=\"string\" name=\"identifier\">\(lineItemUUID)</field>"
        guard let identifierRange = xml.range(of: identifierPattern) else { return xml }

        // Find the SecurityLineItem record within this line item
        let afterIdentifier = xml[identifierRange.upperBound...]
        guard let sliStart = afterIdentifier.range(of: "<record type=\"SecurityLineItem\" name=\"securityLineItem\">") else { return xml }
        guard let sliEnd = xml.range(of: "</record>", range: sliStart.upperBound..<xml.endIndex) else { return xml }

        let sliRecord = String(xml[sliStart.lowerBound..<sliEnd.upperBound])

        // Try replacing the field value within the SecurityLineItem record
        let openTag = "<field type=\"\(fieldType)\" name=\"\(fieldName)\">"
        let closeTag = "</field>"
        var patched = sliRecord

        if let openRange = patched.range(of: openTag),
           let closeRange = patched.range(of: closeTag, range: openRange.upperBound..<patched.endIndex) {
            let newField = "\(openTag)\(value)\(closeTag)"
            patched.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: newField)
        } else {
            // Try replacing null field
            let nullField = "<field type=\"\(fieldType)\" name=\"\(fieldName)\" null=\"null\"/>"
            if let nullRange = patched.range(of: nullField) {
                let newField = "<field type=\"\(fieldType)\" name=\"\(fieldName)\">\(value)</field>"
                patched.replaceSubrange(nullRange, with: newField)
            } else {
                // Also try enum fields (for cost basis method etc.)
                let enumOpenTag = "<field enum=\"\(fieldType)\" name=\"\(fieldName)\">"
                if let openRange = patched.range(of: enumOpenTag),
                   let closeRange = patched.range(of: closeTag, range: openRange.upperBound..<patched.endIndex) {
                    let newField = "\(enumOpenTag)\(value)\(closeTag)"
                    patched.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: newField)
                } else {
                    return xml
                }
            }
        }

        var result = xml
        result.replaceSubrange(sliStart.lowerBound..<sliEnd.upperBound, with: patched)
        return result
    }

    public func formatDecimalPublic(_ value: Double) -> String {
        formatDecimal(value)
    }

    // MARK: - XML Patching: Security latestSecurityPrice

    public func updateSecurityLatestPrice(securityUUID: String, closePrice: Double, date: String) {
        let priceStr = formatDecimal(closePrice)
        let dateStr = date.contains("T") ? date : "\(date)T00:00:00+0100"
        updateTransactionBlob(transactionUUID: securityUUID) { xml in
            // Replace the latestSecurityPrice record contents
            guard let recordStart = xml.range(of: "<record type=\"SecurityPrice\" name=\"latestSecurityPrice\">"),
                  let recordEnd = xml.range(of: "</record>", range: recordStart.upperBound..<xml.endIndex) else {
                return xml
            }

            let newRecord = """
                <record type="SecurityPrice" name="latestSecurityPrice">\
                <field type="decimal" name="adjustedClosePrice" null="null"/>\
                <field type="decimal" name="closePrice">\(priceStr)</field>\
                <field enum="IGGCSyncAccountingSecurityPriceDataSourceType" name="dataSource">user-entered</field>\
                <field type="date" name="date">\(dateStr)</field>\
                <field type="decimal" name="highPrice" null="null"/>\
                <field type="decimal" name="lowPrice" null="null"/>\
                <field type="decimal" name="openPrice" null="null"/>\
                <field type="decimal" name="previousClosePrice" null="null"/>\
                <field type="decimal" name="volume" null="null"/></record>
                """
            var result = xml
            result.replaceSubrange(recordStart.lowerBound..<recordEnd.upperBound, with: newRecord)
            return result
        }
    }

    // MARK: - Gzip

    static func decompressGzip(_ data: Data) -> Data? {
        guard data.count >= 10 else { return nil }
        // Verify gzip magic number
        guard data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else { return nil }

        // Strip gzip header (minimum 10 bytes) and trailer (8 bytes) to get raw deflate
        // Parse header to handle optional fields
        var offset = 10
        let flags = data[data.startIndex + 3]
        if flags & 0x04 != 0 { // FEXTRA
            guard data.count > offset + 2 else { return nil }
            let xlen = Int(data[data.startIndex + offset]) | (Int(data[data.startIndex + offset + 1]) << 8)
            offset += 2 + xlen
        }
        if flags & 0x08 != 0 { // FNAME - null terminated
            while offset < data.count && data[data.startIndex + offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT - null terminated
            while offset < data.count && data[data.startIndex + offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 } // FHCRC

        guard data.count > offset + 8 else { return nil }
        let deflateData = data[data.startIndex + offset ..< data.endIndex - 8]

        // Read uncompressed size from last 4 bytes of trailer
        let sizeOffset = data.endIndex - 4
        let uncompressedSize = Int(data[sizeOffset]) |
            (Int(data[sizeOffset + 1]) << 8) |
            (Int(data[sizeOffset + 2]) << 16) |
            (Int(data[sizeOffset + 3]) << 24)

        // Allocate buffer with some headroom (size field is mod 2^32)
        let bufferSize = max(uncompressedSize, deflateData.count * 4)
        var destination = Data(count: bufferSize)
        let decompressedSize = deflateData.withUnsafeBytes { srcPtr -> Int in
            destination.withUnsafeMutableBytes { dstPtr -> Int in
                guard let src = srcPtr.baseAddress, let dst = dstPtr.baseAddress else { return 0 }
                return compression_decode_buffer(
                    dst.assumingMemoryBound(to: UInt8.self), bufferSize,
                    src.assumingMemoryBound(to: UInt8.self), deflateData.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard decompressedSize > 0 else { return nil }
        return destination.prefix(decompressedSize)
    }

    static func compressGzip(_ data: Data) -> Data? {
        let bufferSize = max(data.count + 512, data.count * 2)
        var compressed = Data(count: bufferSize)
        let compressedSize = data.withUnsafeBytes { srcPtr -> Int in
            compressed.withUnsafeMutableBytes { dstPtr -> Int in
                guard let src = srcPtr.baseAddress, let dst = dstPtr.baseAddress else { return 0 }
                return compression_encode_buffer(
                    dst.assumingMemoryBound(to: UInt8.self), bufferSize,
                    src.assumingMemoryBound(to: UInt8.self), data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard compressedSize > 0 else { return nil }
        let deflateData = compressed.prefix(compressedSize)

        // Build gzip container: header + deflate + trailer
        var gzip = Data()
        // Gzip header (10 bytes)
        gzip.append(contentsOf: [0x1f, 0x8b])  // magic
        gzip.append(0x08)                        // compression method (deflate)
        gzip.append(0x00)                        // flags
        gzip.append(contentsOf: [0, 0, 0, 0])   // mtime
        gzip.append(0x00)                        // extra flags
        gzip.append(0xff)                        // OS (unknown)
        // Deflate data
        gzip.append(deflateData)
        // Trailer: CRC32 + uncompressed size
        let crc = crc32(data)
        gzip.append(contentsOf: withUnsafeBytes(of: crc.littleEndian) { Array($0) })
        let size = UInt32(truncatingIfNeeded: data.count)
        gzip.append(contentsOf: withUnsafeBytes(of: size.littleEndian) { Array($0) })

        return gzip
    }

    // MARK: - Private Implementation

    private func performBlobUpdate(entityUUID: String, transform: @Sendable (String) -> String) throws {
        let bgContext = container.newBackgroundContext()
        nonisolated(unsafe) var writeError: Error?
        bgContext.performAndWait {
            do {
                guard let record = try self.fetchSyncRecord(entityUUID: entityUUID, in: bgContext) else {
                    return // No sync record — skip silently
                }

                guard let blobData = record.value(forKey: "pRemoteEntityData") as? Data else {
                    return // No blob data — skip silently
                }

                guard let decompressed = Self.decompressGzip(blobData) else {
                    self.log("Failed to decompress blob for \(entityUUID)")
                    return
                }

                guard let xml = String(data: decompressed, encoding: .utf8) else {
                    self.log("Failed to decode blob XML for \(entityUUID)")
                    return
                }

                let patched = transform(xml)

                // Validate patch
                guard patched.hasPrefix("<entity") || patched.hasPrefix("<?xml") else {
                    self.log("Patched XML has invalid start for \(entityUUID)")
                    return
                }
                guard patched.hasSuffix("</entity>") || patched.hasSuffix("</entity>\n") else {
                    self.log("Patched XML has invalid end for \(entityUUID)")
                    return
                }

                // Size sanity check (±50% of original)
                let ratio = Double(patched.utf8.count) / Double(xml.utf8.count)
                guard ratio > 0.5 && ratio < 1.5 else {
                    self.log("Patched XML size changed too much (\(Int(ratio * 100))%) for \(entityUUID)")
                    return
                }

                guard let patchedData = patched.data(using: .utf8) else {
                    self.log("Failed to encode patched XML for \(entityUUID)")
                    return
                }

                guard let compressed = Self.compressGzip(patchedData) else {
                    self.log("Failed to compress patched blob for \(entityUUID)")
                    return
                }

                record.setValue(compressed, forKey: "pRemoteEntityData")
                try bgContext.save()
            } catch {
                writeError = error
            }
        }
        if let error = writeError { throw error }
    }

    private func fetchSyncRecord(entityUUID: String, in ctx: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        request.predicate = NSPredicate(format: "pLocalID == %@", entityUUID)
        request.fetchLimit = 1
        return try ctx.fetch(request).first
    }

    // MARK: - XML Field Manipulation

    private func lineItemRecordRange(in xml: String, lineItemUUID: String) -> Range<String.Index>? {
        // Find the identifier field for this line item
        let identifierPattern = "<field type=\"string\" name=\"identifier\">\(lineItemUUID)</field>"
        guard let identifierRange = xml.range(of: identifierPattern) else {
            log("LineItem UUID \(lineItemUUID) not found in blob XML")
            return nil
        }

        // Search backwards for the enclosing <record type="LineItem"
        let beforeIdentifier = xml[xml.startIndex..<identifierRange.lowerBound]
        guard let recordStart = beforeIdentifier.range(of: "<record type=\"LineItem\"", options: .backwards) else {
            return nil
        }

        // Search forwards for the closing </record>
        guard let recordEnd = xml.range(of: "</record>", range: identifierRange.upperBound..<xml.endIndex) else {
            return nil
        }

        return recordStart.lowerBound..<recordEnd.upperBound
    }

    private func replaceField(in xml: String, name: String, type: String, newContent: String) -> String? {
        // Match: <field type="TYPE" name="NAME">OLD_CONTENT</field>
        let openTag = "<field type=\"\(type)\" name=\"\(name)\">"
        let closeTag = "</field>"
        guard let openRange = xml.range(of: openTag) else { return nil }
        guard let closeRange = xml.range(of: closeTag, range: openRange.upperBound..<xml.endIndex) else { return nil }

        let newField = "\(openTag)\(newContent)\(closeTag)"
        var result = xml
        result.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: newField)
        return result
    }

    private func replaceNullField(in xml: String, name: String, type: String, newContent: String) -> String? {
        // Match: <field type="TYPE" name="NAME" null="null"/>
        let nullField = "<field type=\"\(type)\" name=\"\(name)\" null=\"null\"/>"
        guard let range = xml.range(of: nullField) else { return nil }

        let newField = "<field type=\"\(type)\" name=\"\(name)\">\(newContent)</field>"
        var result = xml
        result.replaceSubrange(range, with: newField)
        return result
    }

    private func setFieldNull(in xml: String, name: String, type: String) -> String? {
        // Try replacing a non-null field with null version
        let openTag = "<field type=\"\(type)\" name=\"\(name)\">"
        let closeTag = "</field>"
        let nullField = "<field type=\"\(type)\" name=\"\(name)\" null=\"null\"/>"

        if let openRange = xml.range(of: openTag),
           let closeRange = xml.range(of: closeTag, range: openRange.upperBound..<xml.endIndex)
        {
            var result = xml
            result.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: nullField)
            return result
        }

        // Already null — return unchanged
        if xml.contains(nullField) { return xml }
        return nil
    }

    private func replaceCollection(in xml: String, name: String, newCollection: String) -> String? {
        // Match: <collection type="set" name="NAME">...</collection>
        let openPattern = "<collection type=\"set\" name=\"\(name)\">"
        let closeTag = "</collection>"
        guard let openRange = xml.range(of: openPattern) else { return nil }
        guard let closeRange = xml.range(of: closeTag, range: openRange.upperBound..<xml.endIndex) else { return nil }

        var result = xml
        result.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: newCollection)
        return result
    }

    private func replaceNullCollection(in xml: String, name: String, newCollection: String) -> String? {
        // Match: <collection type="set" name="NAME" null="null"/>
        let nullCollection = "<collection type=\"set\" name=\"\(name)\" null=\"null\"/>"
        guard let range = xml.range(of: nullCollection) else { return nil }

        var result = xml
        result.replaceSubrange(range, with: newCollection)
        return result
    }

    private func setCollectionNull(in xml: String, name: String) -> String? {
        let nullCollection = "<collection type=\"set\" name=\"\(name)\" null=\"null\"/>"

        // Try replacing non-null collection
        let openPattern = "<collection type=\"set\" name=\"\(name)\">"
        let closeTag = "</collection>"
        if let openRange = xml.range(of: openPattern),
           let closeRange = xml.range(of: closeTag, range: openRange.upperBound..<xml.endIndex)
        {
            var result = xml
            result.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: nullCollection)
            return result
        }

        // Already null
        if xml.contains(nullCollection) { return xml }
        return nil
    }

    private func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[banktivity-sync] \(message)\n".utf8))
    }

    // MARK: - CRC32

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB88320 : 0)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}
