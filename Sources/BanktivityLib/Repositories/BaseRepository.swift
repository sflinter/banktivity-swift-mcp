// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

/// Base repository providing Core Data context access and common helpers
open class BaseRepository: @unchecked Sendable {
    public let container: NSPersistentContainer

    public init(container: NSPersistentContainer) {
        self.container = container
    }

    /// Get the view context for read operations
    public var context: NSManagedObjectContext {
        container.viewContext
    }

    /// Construct the Core Data object URI for a given store, entity, and PK.
    /// Format: x-coredata://<storeUUID>/<entityName>/p<pk>
    public func objectURI(store: NSPersistentStore, entityName: String, pk: Int) -> URL {
        var components = URLComponents()
        components.scheme = "x-coredata"
        components.host = store.identifier
        components.path = "/\(entityName)/p\(pk)"
        return components.url!
    }

    /// Count entities matching a predicate
    public func count(entityName: String, predicate: NSPredicate? = nil) throws -> Int {
        nonisolated(unsafe) let pred = predicate
        return try performRead { ctx in
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            request.predicate = pred
            return try ctx.count(for: request)
        }
    }

    /// Perform a read on the view context's thread, returning a Sendable value.
    /// Use this for all reads to avoid Core Data threading violations when called
    /// from Swift concurrency cooperative threads.
    public func performRead<T: Sendable>(_ block: @escaping @Sendable (NSManagedObjectContext) throws -> T) throws -> T {
        try perform(on: context, save: false, block)
    }

    /// Save the context
    public func save() throws {
        if context.hasChanges {
            try context.save()
        }
    }

    /// Perform work on a background context and save.
    ///
    /// The viewContext is configured with `automaticallyMergesChangesFromParent = true`,
    /// but the merge happens asynchronously on the main run loop — which doesn't run
    /// in this CLI/MCP-server process. Subsequent reads through `performRead` therefore
    /// re-fetch from the persistent store rather than relying on cached objects in the
    /// viewContext, which is why every read path here goes through `fetchByPK` or a
    /// fresh `NSFetchRequest`. Don't cache `NSManagedObject` instances across calls.
    public func performWrite(_ block: @escaping @Sendable (NSManagedObjectContext) throws -> Void) throws {
        _ = try perform(on: container.newBackgroundContext(), save: true) { ctx in
            try block(ctx)
        }
    }

    /// Perform a write that returns a value. See `performWrite` for context lifecycle notes.
    public func performWriteReturning<T: Sendable>(_ block: @escaping @Sendable (NSManagedObjectContext) throws -> T) throws -> T {
        try perform(on: container.newBackgroundContext(), save: true, block)
    }

    /// Run `block` on `ctx`'s queue via performAndWait, optionally saving on success,
    /// and propagate the result or error back to the caller's thread.
    private func perform<T: Sendable>(
        on ctx: NSManagedObjectContext,
        save: Bool,
        _ block: @escaping @Sendable (NSManagedObjectContext) throws -> T
    ) throws -> T {
        if save {
            return try CoreDataWriteCoordinator.perform {
                try performOnContext(on: ctx, save: save, block)
            }
        }
        return try performOnContext(on: ctx, save: save, block)
    }

    private func performOnContext<T: Sendable>(
        on ctx: NSManagedObjectContext,
        save: Bool,
        _ block: @escaping @Sendable (NSManagedObjectContext) throws -> T
    ) throws -> T {
        nonisolated(unsafe) var outcome: Result<T, Error>!
        ctx.performAndWait {
            outcome = Result {
                let value = try block(ctx)
                if save && ctx.hasChanges {
                    try ctx.save()
                }
                return value
            }
        }
        return try outcome.get()
    }

    /// Create a new managed object in the given context
    public static func createObject(entityName: String, in context: NSManagedObjectContext) -> NSManagedObject {
        NSEntityDescription.insertNewObject(forEntityName: entityName, into: context)
    }

    /// Generate a UUID string for new entities
    public static func generateUUID() -> String {
        UUID().uuidString
    }

    /// Set a date value (as Foundation Date) on a managed object
    public static func setDate(_ object: NSManagedObject, _ key: String, isoString: String?) {
        guard let iso = isoString, let ts = DateConversion.fromISO(iso) else { return }
        object.setValue(DateConversion.toDate(ts), forKey: key)
    }

    /// Set current timestamp on a managed object
    public static func setNow(_ object: NSManagedObject, _ key: String) {
        object.setValue(Date(), forKey: key)
    }

    /// Fetch an object by PK in a specific context (for write operations on background contexts)
    public func fetchByPK(entityName: String, pk: Int, in ctx: NSManagedObjectContext) throws -> NSManagedObject? {
        let coordinator = container.persistentStoreCoordinator
        guard let store = coordinator.persistentStores.first,
              let entity = container.managedObjectModel.entitiesByName[entityName]
        else { return nil }

        var entityNames = [entity.name!]
        func collectSubentities(_ e: NSEntityDescription) {
            for sub in e.subentities {
                if let name = sub.name { entityNames.append(name) }
                collectSubentities(sub)
            }
        }
        collectSubentities(entity)

        for name in entityNames {
            let uri = objectURI(store: store, entityName: name, pk: pk)
            guard let objectID = coordinator.managedObjectID(forURIRepresentation: uri) else { continue }
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            request.predicate = NSPredicate(format: "SELF == %@", objectID)
            request.fetchLimit = 1
            if let obj = try? ctx.fetch(request).first { return obj }
        }
        return nil
    }

    // MARK: - KVC Helpers

    /// Safely get a string value from a managed object
    public static func string(_ object: NSManagedObject, _ key: String) -> String? {
        object.value(forKey: key) as? String
    }

    /// Safely get a string value with a default
    public static func stringValue(_ object: NSManagedObject, _ key: String, default defaultValue: String = "") -> String {
        (object.value(forKey: key) as? String) ?? defaultValue
    }

    /// Safely get an integer value from a managed object
    public static func intValue(_ object: NSManagedObject, _ key: String) -> Int {
        (object.value(forKey: key) as? Int) ?? 0
    }

    /// Safely get an optional integer value
    public static func optionalInt(_ object: NSManagedObject, _ key: String) -> Int? {
        object.value(forKey: key) as? Int
    }

    /// Safely get a double value from a managed object
    public static func doubleValue(_ object: NSManagedObject, _ key: String) -> Double {
        if let decimal = object.value(forKey: key) as? NSDecimalNumber {
            return decimal.doubleValue
        }
        return (object.value(forKey: key) as? Double) ?? 0.0
    }

    /// Safely get a boolean value from a managed object
    public static func boolValue(_ object: NSManagedObject, _ key: String) -> Bool {
        (object.value(forKey: key) as? Bool) ?? false
    }

    /// Safely get a date value (as Core Data timestamp) from a managed object
    public static func dateValue(_ object: NSManagedObject, _ key: String) -> Double? {
        if let date = object.value(forKey: key) as? Date {
            return date.timeIntervalSinceReferenceDate
        }
        return nil
    }

    /// Get the currency code from an object that may have a currency relationship
    public static func currencyCode(_ object: NSManagedObject) -> String? {
        // PrimaryAccount has "currency" relationship, Account (categories) does not
        if object.entity.relationshipsByName["currency"] != nil,
           let currency = object.value(forKey: "currency") as? NSManagedObject
        {
            return currency.value(forKey: "pCode") as? String
        }
        return nil
    }

    /// Get a to-one related object
    public static func relatedObject(_ object: NSManagedObject, _ key: String) -> NSManagedObject? {
        guard object.entity.relationshipsByName[key] != nil else { return nil }
        return object.value(forKey: key) as? NSManagedObject
    }

    /// Extract the Z_PK (primary key) from a Core Data objectID.
    /// The URI format is: x-coredata://<storeID>/<entity>/p<pk>
    public static func extractPK(from objectID: NSManagedObjectID) -> Int {
        let uri = objectID.uriRepresentation()
        let lastComponent = uri.lastPathComponent  // "p123"
        if lastComponent.hasPrefix("p"), let pk = Int(lastComponent.dropFirst()) {
            return pk
        }
        return 0
    }

    /// Get a to-many related object set
    public static func relatedSet(_ object: NSManagedObject, _ key: String) -> Set<NSManagedObject> {
        guard object.entity.relationshipsByName[key] != nil else { return [] }
        if let set = object.value(forKey: key) as? Set<NSManagedObject> {
            return set
        }
        if let nsSet = object.value(forKey: key) as? NSSet {
            return nsSet as! Set<NSManagedObject>
        }
        return []
    }
}
