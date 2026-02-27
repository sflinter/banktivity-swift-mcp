// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser
import BanktivityLib
import Foundation

struct Scheduled: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scheduled transaction operations",
        subcommands: [List.self, Get.self, Create.self, Update.self, Delete.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List scheduled transactions")

        @OptionGroup var parent: VaultOption

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let scheduled = ScheduledTransactionRepository(container: container)

            let results = try scheduled.list()
            try outputJSON(results)
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get a scheduled transaction by ID")

        @OptionGroup var parent: VaultOption

        @Argument(help: "Schedule ID")
        var id: Int

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let scheduled = ScheduledTransactionRepository(container: container)

            guard let schedule = try scheduled.get(scheduleId: id) else {
                throw ToolError.notFound("Scheduled transaction not found: \(id)")
            }
            try outputJSON(schedule)
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a scheduled transaction")

        @OptionGroup var parent: VaultOption

        @Option(name: .long, help: "Template ID")
        var templateId: Int

        @Option(name: .long, help: "Start date (YYYY-MM-DD)")
        var startDate: String

        @Option(name: .long, help: "Account UUID")
        var accountId: String?

        @Option(name: .long, help: "Repeat interval (1=daily, 7=weekly, 30=monthly)")
        var repeatInterval: Int = 1

        @Option(name: .long, help: "Repeat multiplier")
        var repeatMultiplier: Int = 1

        @Option(name: .long, help: "Reminder days in advance")
        var reminderDays: Int = 7

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let scheduled = ScheduledTransactionRepository(container: container)
            let result = try scheduled.create(
                templateId: templateId,
                startDate: startDate,
                accountId: accountId,
                repeatInterval: repeatInterval,
                repeatMultiplier: repeatMultiplier,
                reminderDays: reminderDays
            )
            try outputJSON(result)
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Update a scheduled transaction")

        @OptionGroup var parent: VaultOption

        @Argument(help: "Schedule ID")
        var id: Int

        @Option(name: .long, help: "New start date (YYYY-MM-DD)")
        var startDate: String?

        @Option(name: .long, help: "New next date (YYYY-MM-DD)")
        var nextDate: String?

        @Option(name: .long, help: "New repeat interval")
        var repeatInterval: Int?

        @Option(name: .long, help: "New repeat multiplier")
        var repeatMultiplier: Int?

        @Option(name: .long, help: "New account UUID")
        var accountId: String?

        @Option(name: .long, help: "New reminder days")
        var reminderDays: Int?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let scheduled = ScheduledTransactionRepository(container: container)
            let success = try scheduled.update(
                scheduleId: id,
                startDate: startDate,
                nextDate: nextDate,
                repeatInterval: repeatInterval,
                repeatMultiplier: repeatMultiplier,
                accountId: accountId,
                reminderDays: reminderDays
            )

            if success, let updated = try scheduled.get(scheduleId: id) {
                try outputJSON(updated)
            } else {
                throw ToolError.notFound("Scheduled transaction not found: \(id)")
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a scheduled transaction")

        @OptionGroup var parent: VaultOption

        @Argument(help: "Schedule ID")
        var id: Int

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let scheduled = ScheduledTransactionRepository(container: container)
            let deleted = try scheduled.delete(scheduleId: id)
            if !deleted {
                throw ToolError.notFound("Scheduled transaction not found: \(id)")
            }
            outputJSON(["message": "Scheduled transaction \(id) deleted"] as [String: Any])
        }
    }
}
