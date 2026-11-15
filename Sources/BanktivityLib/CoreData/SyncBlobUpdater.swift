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
        public let income: Double?
        /// nil is written as a null field. Never 0: a receiving device writes a
        /// trade's price into price history for its date, zero included.
        public let pricePerShare: Double?
        public let priceMultiplier: Double
        public let securityUUID: String
        public let shares: Double
        public let hasDistributionType: Bool

        public init(amount: Double, commission: Double, pricePerShare: Double?, priceMultiplier: Double, securityUUID: String, shares: Double, hasDistributionType: Bool, income: Double? = nil) {
            self.amount = amount
            self.commission = commission
            self.income = income
            self.pricePerShare = pricePerShare
            self.priceMultiplier = priceMultiplier
            self.securityUUID = securityUUID
            self.shares = shares
            self.hasDistributionType = hasDistributionType
        }
    }

    // MARK: - High-level API

    /// Mark a sync record for deletion.
    /// Sets pSyncedState = 3 and updates pSyncedModificationDate to trigger
    /// Banktivity's sync to push the deletion to CloudKit.
    /// The blob is preserved so Banktivity knows what to delete.
    public func deleteSyncRecord(entityUUID: String) {
        do {
            try CoreDataWriteCoordinator.perform {
                let bgContext = container.newBackgroundContext()
                nonisolated(unsafe) var writeError: Error?
                bgContext.performAndWait {
                    do {
                        guard let record = try self.fetchSyncRecord(entityUUID: entityUUID, in: bgContext) else {
                            self.log("No SyncedHostedEntity found for UUID \(entityUUID) — deletion will not propagate to CloudKit")
                            return
                        }
                        record.setValue(Int16(3), forKey: "pSyncedState")
                        record.setValue(Date(), forKey: "pSyncedModificationDate")
                        try bgContext.save()
                        self.log("Marked sync record as deleted (state=3) for UUID \(entityUUID)")
                    } catch {
                        writeError = error
                    }
                }
                if let error = writeError { throw error }
            }
        } catch {
            log("Failed to mark sync record as deleted for \(entityUUID): \(error)")
        }
    }

    // MARK: - Sync Record Creation

    // MARK: - Transaction Base Type Vocabulary

    /// The `IGGCSyncAccountingTransactionBaseType` enum, as Banktivity spells it.
    ///
    /// This is **not** the CLI's `--transaction-type` vocabulary and must never be
    /// derived from it. They agree on most values and disagree on three, and every
    /// disagreement writes a sync record that contradicts the row it describes:
    ///
    /// | base type | this enum | the CLI slug |
    /// | --- | --- | --- |
    /// | 250 | `slpit-shares` | `split-shares` |
    /// | 300 | `misc-inv-income` | `investment-income` |
    /// | 304 | `intrest-income` | `interest-income` |
    ///
    /// Two of them are misspelled. They are Banktivity's spellings, read from the
    /// string table in `IGGSyncServices` immediately next to the enum name itself,
    /// and confirmed by what Banktivity wrote into a real vault: of 22,361
    /// transaction sync records there, the share-split rows it created say
    /// `slpit-shares` and the interest rows say `intrest-income`. Correcting the
    /// typos here would emit a value the enum does not contain.
    static let transactionBaseTypeNames: [Int16: String] = [
        1: "deposit", 2: "withdrawal", 3: "transfer", 4: "check",
        5: "charge", 6: "refund", 7: "payment",
        100: "buy", 101: "sell",
        102: "buy-to-open", 103: "buy-to-close",
        104: "sell-to-open", 105: "sell-to-close",
        210: "move-shares-in", 211: "move-shares-out",
        212: "transfer-shares", 250: "slpit-shares",
        300: "misc-inv-income", 301: "dividend",
        302: "cap-gains-short", 303: "cap-gains-long",
        304: "intrest-income", 310: "return-of-capital",
    ]

    /// The enum string for a base type, or `nil` when the vault holds a type this
    /// enum has no name for. `nil` is deliberate: the caller must decide whether to
    /// refuse the write or leave the record alone, because inventing a string the
    /// enum does not contain is what this map exists to prevent.
    public static func syncBaseTypeName(for baseType: Int16) -> String? {
        transactionBaseTypeNames[baseType]
    }

    public func createTransactionSyncRecord(
        transactionUUID: String, currencyUUID: String, date: String,
        title: String, note: String?, adjustment: Bool,
        lineItems: [SyncLineItem],
        transactionTypeBaseTypeCode: Int16, transactionTypeUUID: String
    ) {
        // No timestamp, no record. `create` does not validate its date -- `setDate`
        // silently leaves `pDate` unset for one it cannot parse -- so an
        // unparseable label reaches here, and writing it into the blob's `date`
        // field would describe the row as dated when the row itself is not.
        guard let blobDate = DateConversion.syncBlobTimestamp(dateOnly: date) else {
            log("Unparseable date \(date); skipping sync record for \(transactionUUID)")
            return
        }
        do {
            // A base type the enum cannot name would otherwise be written as some
            // caller's guess. Skip the record instead: an absent sync record is a
            // state the readers already handle, a wrong one is not.
            guard let transactionTypeBaseType = Self.syncBaseTypeName(for: transactionTypeBaseTypeCode) else {
                log("No sync base type name for \(transactionTypeBaseTypeCode); skipping sync record for \(transactionUUID)")
                return
            }
            let xml = buildTransactionXML(
                blobDate: blobDate,
                transactionUUID: transactionUUID, currencyUUID: currencyUUID,
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

            try CoreDataWriteCoordinator.perform {
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
            }
        } catch {
            log("Failed to create sync record for transaction \(transactionUUID): \(error)")
        }
    }

    private func buildTransactionXML(
        blobDate: String,
        transactionUUID: String, currencyUUID: String,
        title: String, note: String?, adjustment: Bool,
        lineItems: [SyncLineItem],
        transactionTypeBaseType: String, transactionTypeUUID: String
    ) -> String {
        var xml = "<entity type=\"Transaction\" id=\"\(transactionUUID)\">"
        xml += "<field type=\"bool\" name=\"adjustment\">\(adjustment ? "yes" : "no")</field>"
        xml += "<field type=\"int\" name=\"checkNumber\" null=\"null\"/>"
        xml += "<field type=\"reference\" name=\"currency\">Currency:\(currencyUUID)</field>"
        xml += "<field type=\"date\" name=\"date\">\(blobDate)</field>"
        xml += buildLineItemsXML(lineItems)
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

    private func buildLineItemsXML(_ lineItems: [SyncLineItem]) -> String {
        var xml = "<collection type=\"array\" name=\"lineItems\">"
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
                xml += "<field type=\"decimal\" name=\"commission\">\(formatDecimal(sli.commission))</field>"
                xml += "<field type=\"decimal\" name=\"cost\">\(formatDecimal(sli.amount))</field>"
                xml += "<field enum=\"IGGCSyncAccountingSecurityCostBasisMethod\" name=\"costBasisMethod\">unknown</field>"
                if sli.hasDistributionType {
                    xml += "<field enum=\"IGGCSyncAccountingSecurityLineItemDistrbutionType\" name=\"distributionType\">deposit</field>"
                }
                if let income = sli.income {
                    xml += "<field type=\"decimal\" name=\"income\">\(formatDecimal(income))</field>"
                } else {
                    xml += "<field type=\"decimal\" name=\"income\" null=\"null\"/>"
                }
                xml += "<collection type=\"array\" name=\"openingLots\" null=\"null\"/>"
                xml += "<field type=\"date\" name=\"overrideDate\" null=\"null\"/>"
                if let price = sli.pricePerShare {
                    xml += "<field type=\"decimal\" name=\"pricePerShare\">\(formatDecimal(price))</field>"
                } else {
                    xml += "<field type=\"decimal\" name=\"pricePerShare\" null=\"null\"/>"
                }
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

    // MARK: - XML Patching: Recategorize

    // MARK: - XML Patching: Tags

    // MARK: - XML Patching: Transaction-level fields

    // MARK: - XML Patching: SecurityLineItem fields

    // MARK: - XML Patching: Security latestSecurityPrice

    // MARK: - XML Patching: Security identity

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

    /// Inspect a sync record for diagnostic purposes.
    /// Returns a dictionary of key fields, or nil if no record found.
    public func inspectSyncRecord(entityUUID: String) -> [String: Any]? {
        let ctx = container.newBackgroundContext()
        nonisolated(unsafe) var result: [String: Any]?
        ctx.performAndWait {
            result = self._inspectSyncRecord(entityUUID: entityUUID, in: ctx)
        }
        return result
    }

    private func _inspectSyncRecord(entityUUID: String, in ctx: NSManagedObjectContext) -> [String: Any]? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        request.predicate = NSPredicate(format: "pLocalID == %@", entityUUID)
        request.fetchLimit = 1
        guard let record = try? ctx.fetch(request).first else { return nil }

        let blobData = record.value(forKey: "pRemoteEntityData") as? Data
        let modDate = record.value(forKey: "pSyncedModificationDate") as? Date
        let syncedState = record.value(forKey: "pSyncedState") as? Int16

        var result: [String: Any] = [
            "pLocalID": record.value(forKey: "pLocalID") as? String ?? "(nil)",
            "pRemoteID": record.value(forKey: "pRemoteID") as? String ?? "(nil)",
            "pHostedEntityType": record.value(forKey: "pHostedEntityType") as? String ?? "(nil)",
            "pSyncedState": syncedState as Any,
            "pSyncedModificationDate": modDate?.description ?? "(nil)",
            "pRemoteEntityDataSize": blobData?.count ?? 0,
            "hasBlobData": blobData != nil
        ]

        // Try to decompress and show first 200 chars of XML
        if let data = blobData, let decompressed = Self.decompressGzip(data),
           let xml = String(data: decompressed, encoding: .utf8) {
            let preview = String(xml.prefix(300))
            result["blobPreview"] = preview
        }

        return result
    }

    private func fetchSyncRecord(entityUUID: String, in ctx: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        request.predicate = NSPredicate(format: "pLocalID == %@", entityUUID)
        request.fetchLimit = 1
        return try ctx.fetch(request).first
    }

    // MARK: - XML Field Manipulation

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
