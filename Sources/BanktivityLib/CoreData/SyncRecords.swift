// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Compression

/// The CLI's only contact with Banktivity's CloudKit sync bookkeeping
/// (`SyncedHostedEntity`): a deletion mark made inside the caller's own
/// context, and a read-only inspection for diagnostics.
///
/// How Banktivity 10 syncs, as observed:
///
/// - **Local changes are found by date.** Banktivity uploads an entity whose
///   `pCreationTime` or `pModificationDate` is later than its last sync.
/// - **`pRemoteEntityData` is the merge base.** That gzipped XML blob is
///   Banktivity's record of what the server holds. It is the base of a
///   three-way merge. Banktivity creates the `SyncedHostedEntity` itself when
///   it first uploads a row, and only its own sync writes the blob.
/// - **`pSyncedState` is only for deletion** (3 = pending delete).
///
/// So the write rules are:
///
/// - **Insert or update:** set `pCreationTime` / `pModificationDate` to now
///   in the same save as the edit. An edit to a line item stamps its parent
///   Transaction, because line items travel inside the Transaction's record.
/// - **Delete:** `markDeletedIfPresent` sets `pSyncedState = 3` and
///   `pSyncedModificationDate` to now, in the same save as the delete. A row
///   with no record never synced, so deleting it is the whole job.
/// - **Never write `pRemoteEntityData`.**
///
/// This replaces `SyncBlobUpdater`, which rewrote the blob to match each CLI
/// edit. Rewriting the merge base told Banktivity the server already had the
/// edit, so when the server sent back its older copy, the older copy won and
/// the CLI edit was silently undone. An edit made in the Banktivity UI, which
/// leaves the base alone, survives the same sync.
public enum SyncRecords {

    /// Mark an entity's sync record as pending deletion, the way Banktivity
    /// does: keep the record (Banktivity needs it to know what to delete), set
    /// `pSyncedState = 3` and `pSyncedModificationDate` to now. Call it in the
    /// same context as the entity delete; it never saves on its own.
    ///
    /// Returns `false` when there is no record: the entity never synced.
    /// Idempotent: a record already pending deletion is left as it is.
    @discardableResult
    public static func markDeletedIfPresent(
        entityUUID: String,
        in context: NSManagedObjectContext
    ) throws -> Bool {
        guard !entityUUID.isEmpty,
              let record = try fetchSyncRecord(entityUUID: entityUUID, in: context) else {
            return false
        }
        if (record.value(forKey: "pSyncedState") as? NSNumber)?.intValue == 3 {
            return true
        }
        record.setValue(Int16(3), forKey: "pSyncedState")
        record.setValue(Date(), forKey: "pSyncedModificationDate")
        return true
    }

    // MARK: - Gzip (diagnostic reads)

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

    // MARK: - Diagnostics

    /// Inspect a sync record for diagnostic purposes (read-only).
    /// Returns a dictionary of key fields, or nil if no record found.
    public static func inspect(entityUUID: String, in container: NSPersistentContainer) -> [String: Any]? {
        let ctx = container.newBackgroundContext()
        nonisolated(unsafe) var result: [String: Any]?
        ctx.performAndWait {
            result = inspect(entityUUID: entityUUID, in: ctx)
        }
        return result
    }

    private static func inspect(entityUUID: String, in ctx: NSManagedObjectContext) -> [String: Any]? {
        guard let record = try? fetchSyncRecord(entityUUID: entityUUID, in: ctx) else { return nil }

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
        if let data = blobData, let decompressed = decompressGzip(data),
           let xml = String(data: decompressed, encoding: .utf8) {
            let preview = String(xml.prefix(300))
            result["blobPreview"] = preview
        }

        return result
    }

    private static func fetchSyncRecord(entityUUID: String, in ctx: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        request.predicate = NSPredicate(format: "pLocalID == %@", entityUUID)
        request.fetchLimit = 1
        return try ctx.fetch(request).first
    }
}
