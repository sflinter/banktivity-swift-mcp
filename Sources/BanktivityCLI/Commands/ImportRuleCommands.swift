// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser
import BanktivityLib
import Foundation

struct ImportRules: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-rules",
        abstract: "Import rule operations",
        subcommands: [List.self, Get.self, Match.self, Create.self, Update.self, Delete.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List import rules")

        @OptionGroup var parent: GlobalOptions

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let importRules = ImportRuleRepository(container: container)

            let results = try importRules.list()
            try outputJSON(results, format: parent.format)
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get an import rule by ID")

        @OptionGroup var parent: GlobalOptions

        @Argument(help: "Import rule ID")
        var id: Int

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let importRules = ImportRuleRepository(container: container)

            guard let rule = try importRules.get(ruleId: id) else {
                throw ToolError.notFound("Import rule not found: \(id)")
            }
            try outputJSON(rule, format: parent.format)
        }
    }

    struct Match: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Test which rules match a description")

        @OptionGroup var parent: GlobalOptions

        @Argument(help: "Transaction description to test")
        var description: String

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let importRules = ImportRuleRepository(container: container)

            let matches = try importRules.match(description: description)
            try outputJSON(matches, format: parent.format)
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create an import rule")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Template ID to apply")
        var templateId: Int

        @Option(name: .long, help: "Regex pattern")
        var pattern: String

        @Option(name: .long, help: "Account UUID filter")
        var accountId: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let importRules = ImportRuleRepository(container: container)
            let result = try importRules.create(
                templateId: templateId,
                pattern: pattern,
                accountId: accountId
            )
            try outputJSON(result, format: parent.format)
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Update an import rule")

        @OptionGroup var parent: GlobalOptions

        @Argument(help: "Import rule ID")
        var id: Int

        @Option(name: .long, help: "New regex pattern")
        var pattern: String?

        @Option(name: .long, help: "New account UUID")
        var accountId: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let importRules = ImportRuleRepository(container: container)
            let success = try importRules.update(ruleId: id, pattern: pattern, accountId: accountId)
            if success, let updated = try importRules.get(ruleId: id) {
                try outputJSON(updated, format: parent.format)
            } else {
                throw ToolError.notFound("Import rule not found: \(id)")
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete an import rule")

        @OptionGroup var parent: GlobalOptions

        @Argument(help: "Import rule ID")
        var id: Int

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let importRules = ImportRuleRepository(container: container)
            let deleted = try importRules.delete(ruleId: id)
            if !deleted {
                throw ToolError.notFound("Import rule not found: \(id)")
            }
            try outputJSON(["message": "Import rule \(id) deleted"] as [String: Any], format: parent.format)
        }
    }
}
