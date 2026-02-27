import CoreData
import Foundation
import Testing
@testable import BanktivityMCPLib

@Suite("PersistentContainer")
struct PersistentContainerTests {

    /// Copy the test vault to a temp location and return the path. Returns nil if vault not found.
    private func makeTestVault() throws -> String? {
        let mpcVault = NSString(string: "~/Documents/Banktivity/Steves Accounts MCP.bank8").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: mpcVault) else {
            return nil
        }
        let tmpDir = NSTemporaryDirectory()
        let testVaultPath = (tmpDir as NSString).appendingPathComponent("test-\(UUID().uuidString).bank8")
        try FileManager.default.copyItem(atPath: mpcVault, toPath: testVaultPath)
        return testVaultPath
    }

    private func cleanup(_ path: String?) {
        if let path, FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - Container Creation

    @Test("Container creation succeeds with valid vault")
    func createContainerSucceeds() throws {
        guard let vaultPath = try makeTestVault() else { return }
        defer { cleanup(vaultPath) }

        let container = try PersistentContainerFactory.create(bankFilePath: vaultPath)
        #expect(!container.persistentStoreDescriptions.isEmpty)
    }

    @Test("Container creation throws for missing file")
    func createContainerThrowsForMissingFile() {
        #expect(throws: (any Error).self) {
            try PersistentContainerFactory.create(bankFilePath: "/nonexistent/path.bank8")
        }
    }

    // MARK: - No History Tracking

    @Test("Container does not enable history tracking")
    func containerDoesNotEnableHistoryTracking() throws {
        guard let vaultPath = try makeTestVault() else { return }
        defer { cleanup(vaultPath) }

        let container = try PersistentContainerFactory.create(bankFilePath: vaultPath)

        let description = try #require(container.persistentStoreDescriptions.first)

        // Verify history tracking is NOT enabled
        let historyOption = description.options[NSPersistentHistoryTrackingKey] as? NSNumber
        #expect(historyOption == nil, "Persistent history tracking must NOT be enabled — it corrupts Banktivity vaults")

        let remoteChangeOption = description.options[NSPersistentStoreRemoteChangeNotificationPostOptionKey] as? NSNumber
        #expect(remoteChangeOption == nil, "Remote change notification must NOT be enabled")
    }

    @Test("Opening store does not add history Z_PRIMARYKEY entries")
    func containerDoesNotAddHistoryPrimaryKeys() throws {
        guard let vaultPath = try makeTestVault() else { return }
        defer { cleanup(vaultPath) }

        let container = try PersistentContainerFactory.create(bankFilePath: vaultPath)
        let context = container.viewContext

        // Do a simple read to trigger any lazy initialization
        let request = NSFetchRequest<NSManagedObject>(entityName: "Transaction")
        request.fetchLimit = 1
        _ = try context.fetch(request)

        if context.hasChanges {
            try context.save()
        }

        // Check the SQLite database directly for Z_PRIMARYKEY entries
        let sqlURL = URL(fileURLWithPath: vaultPath)
            .appendingPathComponent("StoreContent")
            .appendingPathComponent("core.sql")

        // Checkpoint WAL
        let checkpointCoordinator = NSPersistentStoreCoordinator(managedObjectModel: container.managedObjectModel)
        _ = try? checkpointCoordinator.addPersistentStore(type: .sqlite, at: URL(fileURLWithPath: sqlURL.path))

        // Use sqlite3 to check Z_PRIMARYKEY for history entities
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            sqlURL.path,
            "SELECT COUNT(*) FROM Z_PRIMARYKEY WHERE Z_NAME IN ('CHANGE', 'TRANSACTION', 'TRANSACTIONSTRING') AND Z_ENT >= 16000"
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        #expect(output == "0", "Opening the store must not add history tracking Z_PRIMARYKEY entries (found \(output))")
    }

    // MARK: - Model Loading

    @Test("Merged model loads with expected entities")
    func loadMergedModelSucceeds() throws {
        guard let vaultPath = try makeTestVault() else { return }
        defer { cleanup(vaultPath) }

        let storeContentURL = URL(fileURLWithPath: vaultPath)
            .appendingPathComponent("StoreContent")
        let model = try PersistentContainerFactory.loadMergedModel(from: storeContentURL)
        #expect(!model.entities.isEmpty)

        let entityNames = Set(model.entities.compactMap(\.name))
        #expect(entityNames.contains("Transaction"))
        #expect(entityNames.contains("LineItem"))
        #expect(entityNames.contains("Account"))
        #expect(entityNames.contains("PrimaryAccount"))
        #expect(entityNames.contains("Category"))
        #expect(entityNames.contains("Tag"))
    }

    @Test("loadMergedModel throws for empty directory")
    func loadMergedModelThrowsForEmptyDir() throws {
        let emptyDir = NSTemporaryDirectory() + "/empty-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: emptyDir) }

        #expect(throws: (any Error).self) {
            try PersistentContainerFactory.loadMergedModel(from: URL(fileURLWithPath: emptyDir))
        }
    }
}
