// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

/// Base repository providing Core Data context access and common helpers
class BaseRepository: @unchecked Sendable {
    let container: NSPersistentContainer

    init(container: NSPersistentContainer) {
        self.container = container
    }

    /// Get the view context for read operations
    var context: NSManagedObjectContext {
        container.viewContext
    }

    /// Perform a fetch request and return results
    func fetch<T: NSFetchRequestResult>(_ request: NSFetchRequest<T>) throws -> [T] {
        try context.fetch(request)
    }

    /// Fetch a single object by entity name and primary key (Z_PK).
    /// Handles entity inheritance by trying the base entity and all subentities.
    func fetchByPK(entityName: String, pk: Int) throws -> NSManagedObject? {
        let coordinator = container.persistentStoreCoordinator
        guard let store = coordinator.persistentStores.first,
              let entity = container.managedObjectModel.entitiesByName[entityName]
        else {
            return nil
        }

        // Collect all entity names to try: the base entity and all subentities.
        // This handles entity inheritance (e.g., Account -> PrimaryAccount).
        var entityNames = [entity.name!]
        func collectSubentities(_ e: NSEntityDescription) {
            for sub in e.subentities {
                if let name = sub.name {
                    entityNames.append(name)
                }
                collectSubentities(sub)
            }
        }
        collectSubentities(entity)

        for name in entityNames {
            let uri = objectURI(store: store, entityName: name, pk: pk)
            if let objectID = coordinator.managedObjectID(forURIRepresentation: uri),
               let object = try? context.existingObject(with: objectID)
            {
                return object
            }
        }

        return nil
    }

    /// Construct the Core Data object URI for a given store, entity, and PK.
    /// Format: x-coredata://<storeUUID>/<entityName>/p<pk>
    func objectURI(store: NSPersistentStore, entityName: String, pk: Int) -> URL {
        var components = URLComponents()
        components.scheme = "x-coredata"
        components.host = store.identifier
        components.path = "/\(entityName)/p\(pk)"
        return components.url!
    }

    /// Count entities matching a predicate
    func count(entityName: String, predicate: NSPredicate? = nil) throws -> Int {
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        request.predicate = predicate
        return try context.count(for: request)
    }

    /// Save the context
    func save() throws {
        if context.hasChanges {
            try context.save()
        }
    }

    /// Perform work on a background context and save
    func performWrite(_ block: @escaping (NSManagedObjectContext) throws -> Void) throws {
        let bgContext = container.newBackgroundContext()
        var writeError: Error?
        bgContext.performAndWait {
            do {
                try block(bgContext)
                if bgContext.hasChanges {
                    try bgContext.save()
                }
            } catch {
                writeError = error
            }
        }
        if let error = writeError {
            throw error
        }
    }

    /// Perform a write that returns a value
    func performWriteReturning<T>(_ block: @escaping (NSManagedObjectContext) throws -> T) throws -> T {
        let bgContext = container.newBackgroundContext()
        var result: T?
        var writeError: Error?
        bgContext.performAndWait {
            do {
                result = try block(bgContext)
                if bgContext.hasChanges {
                    try bgContext.save()
                }
            } catch {
                writeError = error
            }
        }
        if let error = writeError {
            throw error
        }
        return result!
    }

    /// Create a new managed object in the given context
    static func createObject(entityName: String, in context: NSManagedObjectContext) -> NSManagedObject {
        NSEntityDescription.insertNewObject(forEntityName: entityName, into: context)
    }

    /// Generate a UUID string for new entities
    static func generateUUID() -> String {
        UUID().uuidString
    }

    /// Set a date value (as Foundation Date) on a managed object
    static func setDate(_ object: NSManagedObject, _ key: String, isoString: String?) {
        guard let iso = isoString, let ts = DateConversion.fromISO(iso) else { return }
        object.setValue(DateConversion.toDate(ts), forKey: key)
    }

    /// Set current timestamp on a managed object
    static func setNow(_ object: NSManagedObject, _ key: String) {
        object.setValue(Date(), forKey: key)
    }

    /// Fetch an object by PK in a specific context (for write operations on background contexts)
    func fetchByPK(entityName: String, pk: Int, in ctx: NSManagedObjectContext) throws -> NSManagedObject? {
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
            if let objectID = coordinator.managedObjectID(forURIRepresentation: uri),
               let object = try? ctx.existingObject(with: objectID) { return object }
        }
        return nil
    }

    // MARK: - KVC Helpers

    /// Safely get a string value from a managed object
    static func string(_ object: NSManagedObject, _ key: String) -> String? {
        object.value(forKey: key) as? String
    }

    /// Safely get a string value with a default
    static func stringValue(_ object: NSManagedObject, _ key: String, default defaultValue: String = "") -> String {
        (object.value(forKey: key) as? String) ?? defaultValue
    }

    /// Safely get an integer value from a managed object
    static func intValue(_ object: NSManagedObject, _ key: String) -> Int {
        (object.value(forKey: key) as? Int) ?? 0
    }

    /// Safely get an optional integer value
    static func optionalInt(_ object: NSManagedObject, _ key: String) -> Int? {
        object.value(forKey: key) as? Int
    }

    /// Safely get a double value from a managed object
    static func doubleValue(_ object: NSManagedObject, _ key: String) -> Double {
        if let decimal = object.value(forKey: key) as? NSDecimalNumber {
            return decimal.doubleValue
        }
        return (object.value(forKey: key) as? Double) ?? 0.0
    }

    /// Safely get a boolean value from a managed object
    static func boolValue(_ object: NSManagedObject, _ key: String) -> Bool {
        (object.value(forKey: key) as? Bool) ?? false
    }

    /// Safely get a date value (as Core Data timestamp) from a managed object
    static func dateValue(_ object: NSManagedObject, _ key: String) -> Double? {
        if let date = object.value(forKey: key) as? Date {
            return date.timeIntervalSinceReferenceDate
        }
        return nil
    }

    /// Get the currency code from an object that may have a currency relationship
    static func currencyCode(_ object: NSManagedObject) -> String? {
        // PrimaryAccount has "currency" relationship, Account (categories) does not
        if object.entity.relationshipsByName["currency"] != nil,
           let currency = object.value(forKey: "currency") as? NSManagedObject
        {
            return currency.value(forKey: "pCode") as? String
        }
        return nil
    }

    /// Get a to-one related object
    static func relatedObject(_ object: NSManagedObject, _ key: String) -> NSManagedObject? {
        guard object.entity.relationshipsByName[key] != nil else { return nil }
        return object.value(forKey: key) as? NSManagedObject
    }

    /// Extract the Z_PK (primary key) from a Core Data objectID.
    /// The URI format is: x-coredata://<storeID>/<entity>/p<pk>
    static func extractPK(from objectID: NSManagedObjectID) -> Int {
        let uri = objectID.uriRepresentation()
        let lastComponent = uri.lastPathComponent  // "p123"
        if lastComponent.hasPrefix("p"), let pk = Int(lastComponent.dropFirst()) {
            return pk
        }
        return 0
    }

    /// Get a to-many related object set
    static func relatedSet(_ object: NSManagedObject, _ key: String) -> Set<NSManagedObject> {
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
