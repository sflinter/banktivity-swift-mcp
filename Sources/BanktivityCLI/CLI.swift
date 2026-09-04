// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser
import BanktivityLib
import CoreData
import Foundation

@main
struct BanktivityCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "banktivity-cli",
        abstract: "Read and manage a Banktivity personal-finance vault",
        discussion: """
        Use a command group to inspect accounts, transactions, statements, securities,
        and other parts of a Banktivity vault. Read commands return JSON on standard
        output. Commands that change financial data are writes; back up the vault and
        review the command-specific safeguards before using them.

        Supply a vault with --vault /path/to/Ledger.bank8 or set
        BANKTIVITY_FILE_PATH. Run banktivity-cli <group> --help for focused options
        and examples.

        Examples:
          banktivity-cli accounts list
          banktivity-cli transactions list --account-name "Checking" --limit 20
          banktivity-cli statements get --statement-id 42
        """,
        version: version,
        subcommands: [
            Accounts.self,
            Transactions.self,
            Categories.self,
            Tags.self,
            Uncategorized.self,
            LineItems.self,
            Templates.self,
            ImportRules.self,
            Scheduled.self,
            Statements.self,
            Securities.self,
            Schema.self,
            Export.self,
        ]
    )

    /// Resolve the vault path from --vault or BANKTIVITY_FILE_PATH
    static func resolveVaultPath(vault: String?) throws -> String {
        if let path = vault ?? ProcessInfo.processInfo.environment["BANKTIVITY_FILE_PATH"] {
            guard FileManager.default.fileExists(atPath: path) else {
                throw ValidationError("File not found: \(path)")
            }
            return path
        }
        throw ValidationError("Provide --vault or set BANKTIVITY_FILE_PATH")
    }

    /// Create a Core Data container for the given vault path
    static func createContainer(vaultPath: String) throws -> NSPersistentContainer {
        try PersistentContainerFactory.create(
            bankFilePath: vaultPath,
            readOnly: PersistentContainerFactory.readOnlyFromEnvironment
        )
    }

    /// Create a WriteGuard for the given vault path
    static func createWriteGuard(vaultPath: String) -> WriteGuard {
        let dbPath = URL(fileURLWithPath: vaultPath)
            .appendingPathComponent("StoreContent")
            .appendingPathComponent("core.sql")
            .path
        return WriteGuard(dbPath: dbPath)
    }
}

// MARK: - JSON Output

func outputJSON<T: Encodable>(_ value: T, format: OutputFormat = .json) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = format == .json ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

func outputJSON(_ value: [String: Any], format: OutputFormat = .json) throws {
    let options: JSONSerialization.WritingOptions = format == .json ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    let data = try JSONSerialization.data(withJSONObject: value, options: options)
    print(String(data: data, encoding: .utf8) ?? "{}")
}

func outputJSON(_ value: [[String: Any]], format: OutputFormat = .json) throws {
    let options: JSONSerialization.WritingOptions = format == .json ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    let data = try JSONSerialization.data(withJSONObject: value, options: options)
    print(String(data: data, encoding: .utf8) ?? "[]")
}

/// Check write guard and throw if blocked
func guardWrite(_ writeGuard: WriteGuard) async throws {
    if let msg = await writeGuard.guardWriteAccess() {
        throw ToolError.writeBlocked(msg)
    }
}
