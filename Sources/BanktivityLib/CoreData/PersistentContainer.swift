// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

public enum BanktivityError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case noModelsFound(String)
    case modelMergeFailed
    case storeLoadFailed(String)

    public var description: String {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .noModelsFound(let path):
            return "No .momd model bundles found in: \(path)"
        case .modelMergeFailed:
            return "Failed to merge Core Data models"
        case .storeLoadFailed(let error):
            return "Failed to load persistent store: \(error)"
        }
    }
}

/// Loads and configures an NSPersistentContainer from a .bank8 bundle's compiled Core Data models.
public enum PersistentContainerFactory {

    /// Whether `BANKTIVITY_STORE_READ_ONLY` asks for a read-only store.
    ///
    /// Intended for a caller that already knows an invocation only reads -- a
    /// wrapper script, a CI step, an agent harness classifying its own commands.
    /// The binary honours the variable; deciding which invocations are reads is
    /// the caller's job.
    public static var readOnlyFromEnvironment: Bool {
        let raw = ProcessInfo.processInfo.environment["BANKTIVITY_STORE_READ_ONLY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "1", "true", "yes": return true
        default: return false
        }
    }

    /// Load all .momd model bundles from the StoreContent directory and merge them.
    public static func loadMergedModel(from storeContentURL: URL) throws -> NSManagedObjectModel {
        let contents = try FileManager.default.contentsOfDirectory(
            at: storeContentURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )

        let momdURLs = contents.filter { $0.pathExtension == "momd" }

        guard !momdURLs.isEmpty else {
            throw BanktivityError.noModelsFound(storeContentURL.path)
        }

        let models = momdURLs.compactMap { NSManagedObjectModel(contentsOf: $0) }

        guard !models.isEmpty else {
            throw BanktivityError.noModelsFound(storeContentURL.path)
        }

        guard let merged = NSManagedObjectModel(byMerging: models) else {
            throw BanktivityError.modelMergeFailed
        }

        return merged
    }

    /// Create a configured NSPersistentContainer for the given .bank8 file path.
    ///
    /// - Parameters:
    ///   - bankFilePath: Path to the .bank8 bundle
    ///   - readOnly: Open the SQLite store read-only. A read-write handle can
    ///     checkpoint the WAL and recover a hot journal, so it mutates the vault
    ///     even when no write command runs. Callers that know an invocation only
    ///     reads should pass true to remove the write vector rather than rely on
    ///     the command to behave.
    /// - Returns: A loaded NSPersistentContainer
    public static func create(
        bankFilePath: String,
        readOnly: Bool = false
    ) throws -> NSPersistentContainer {
        let storeContentURL = URL(fileURLWithPath: bankFilePath)
            .appendingPathComponent("StoreContent")

        guard FileManager.default.fileExists(atPath: storeContentURL.path) else {
            throw BanktivityError.fileNotFound(storeContentURL.path)
        }

        let sqlURL = storeContentURL.appendingPathComponent("core.sql")
        guard FileManager.default.fileExists(atPath: sqlURL.path) else {
            throw BanktivityError.fileNotFound(sqlURL.path)
        }

        let mergedModel = try loadMergedModel(from: storeContentURL)

        let container = NSPersistentContainer(
            name: "Banktivity",
            managedObjectModel: mergedModel
        )

        let description = NSPersistentStoreDescription(url: sqlURL)
        description.type = NSSQLiteStoreType
        description.isReadOnly = readOnly
        // Do NOT enable persistent history tracking — Banktivity uses its own sync
        // mechanism (ZSYNCEDENTITY) rather than Core Data's built-in persistent history.
        // Enabling history tracking populates the ATRANSACTION/ACHANGE tables and adds
        // Z_PRIMARYKEY entries (entity IDs 16001-16003) that Banktivity doesn't recognize,
        // causing it to refuse to open the vault.

        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
        }

        if let error = loadError {
            throw BanktivityError.storeLoadFailed(error.localizedDescription)
        }

        container.viewContext.automaticallyMergesChangesFromParent = true

        return container
    }

    /// Dump all entity names, attributes, and relationships from a merged model.
    /// Used as a diagnostic tool to discover property names.
    public static func dumpModelSchema(from storeContentURL: URL) throws -> [[String: Any]] {
        let mergedModel = try loadMergedModel(from: storeContentURL)
        var result: [[String: Any]] = []

        let sortedEntities = mergedModel.entities.sorted { ($0.name ?? "") < ($1.name ?? "") }

        for entity in sortedEntities {
            var entityInfo: [String: Any] = [
                "name": entity.name ?? "unknown",
                "managedObjectClassName": entity.managedObjectClassName ?? "NSManagedObject",
            ]

            // Attributes
            var attributes: [[String: String]] = []
            let sortedAttrs = entity.attributesByName.sorted { $0.key < $1.key }
            for (name, attr) in sortedAttrs {
                attributes.append([
                    "name": name,
                    "type": attr.attributeType.description,
                ])
            }
            entityInfo["attributes"] = attributes

            // Relationships
            var relationships: [[String: String]] = []
            let sortedRels = entity.relationshipsByName.sorted { $0.key < $1.key }
            for (name, rel) in sortedRels {
                var relInfo: [String: String] = [
                    "name": name,
                    "destination": rel.destinationEntity?.name ?? "unknown",
                    "toMany": rel.isToMany ? "true" : "false",
                ]
                if let inverse = rel.inverseRelationship {
                    relInfo["inverse"] = inverse.name
                }
                relationships.append(relInfo)
            }
            entityInfo["relationships"] = relationships

            result.append(entityInfo)
        }

        return result
    }
}

extension NSAttributeType: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .undefinedAttributeType: return "undefined"
        case .integer16AttributeType: return "int16"
        case .integer32AttributeType: return "int32"
        case .integer64AttributeType: return "int64"
        case .decimalAttributeType: return "decimal"
        case .doubleAttributeType: return "double"
        case .floatAttributeType: return "float"
        case .stringAttributeType: return "string"
        case .booleanAttributeType: return "boolean"
        case .dateAttributeType: return "date"
        case .binaryDataAttributeType: return "binaryData"
        case .UUIDAttributeType: return "uuid"
        case .URIAttributeType: return "uri"
        case .transformableAttributeType: return "transformable"
        case .objectIDAttributeType: return "objectID"
        case .compositeAttributeType: return "composite"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}
