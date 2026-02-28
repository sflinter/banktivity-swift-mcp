// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser
import BanktivityLib
import Foundation

struct Templates: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transaction template operations",
        subcommands: [List.self, Get.self, Create.self, Update.self, Delete.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List transaction templates")

        @OptionGroup var parent: GlobalOptions

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let templates = TemplateRepository(container: container)

            let results = try templates.list()
            try outputJSON(results, format: parent.format)
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get a template by ID")

        @OptionGroup var parent: GlobalOptions

        @Argument(help: "Template ID")
        var id: Int

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let templates = TemplateRepository(container: container)

            guard let template = try templates.get(templateId: id) else {
                throw ToolError.notFound("Template not found: \(id)")
            }
            try outputJSON(template, format: parent.format)
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a transaction template")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Template title (payee name)")
        var title: String

        @Option(name: .long, help: "Default amount")
        var amount: Double

        @Option(name: .long, help: "Optional note")
        var note: String?

        @Option(name: .long, help: "Currency UUID")
        var currencyId: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let templates = TemplateRepository(container: container)
            let result = try templates.create(
                title: title,
                amount: amount,
                note: note,
                currencyId: currencyId,
                lineItems: nil
            )
            try outputJSON(result, format: parent.format)
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Update a template")

        @OptionGroup var parent: GlobalOptions

        @Argument(help: "Template ID")
        var id: Int

        @Option(name: .long, help: "New title")
        var title: String?

        @Option(name: .long, help: "New amount")
        var amount: Double?

        @Option(name: .long, help: "New note")
        var note: String?

        @Flag(name: .long, help: "Set active")
        var active: Bool = false

        @Flag(name: .long, help: "Set inactive")
        var inactive: Bool = false

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let templates = TemplateRepository(container: container)
            let activeValue: Bool? = active ? true : (inactive ? false : nil)

            let success = try templates.update(
                templateId: id,
                title: title,
                amount: amount,
                note: note,
                active: activeValue
            )

            if success, let updated = try templates.get(templateId: id) {
                try outputJSON(updated, format: parent.format)
            } else {
                throw ToolError.notFound("Template not found: \(id)")
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a template")

        @OptionGroup var parent: GlobalOptions

        @Argument(help: "Template ID")
        var id: Int

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let templates = TemplateRepository(container: container)
            let deleted = try templates.delete(templateId: id)
            if !deleted {
                throw ToolError.notFound("Template not found: \(id)")
            }
            try outputJSON(["message": "Template \(id) deleted"] as [String: Any], format: parent.format)
        }
    }
}
