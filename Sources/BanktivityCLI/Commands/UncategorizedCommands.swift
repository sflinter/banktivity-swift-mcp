// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser
import BanktivityLib
import Foundation

struct Uncategorized: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Uncategorized transaction operations",
        subcommands: [
            List.self, Suggest.self, Review.self, PayeeSummary.self,
            Recategorize.self, BulkRecategorize.self,
        ]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List uncategorized transactions")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Filter by account ID")
        var accountId: Int?

        @Option(name: .long, help: "Start date (YYYY-MM-DD)")
        var startDate: String?

        @Option(name: .long, help: "End date (YYYY-MM-DD)")
        var endDate: String?

        @Option(name: .long, help: "Maximum number of transactions")
        var limit: Int = 50

        @Flag(name: .long, help: "Exclude transfer transactions")
        var excludeTransfers = true

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let categoryRepo = CategoryRepository(container: container)
            let importRuleRepo = ImportRuleRepository(container: container)
            let categorization = CategorizationRepository(
                container: container, categoryRepo: categoryRepo, importRuleRepo: importRuleRepo
            )

            let results = try categorization.getUncategorized(
                accountId: accountId,
                startDate: startDate,
                endDate: endDate,
                limit: limit,
                excludeTransfers: excludeTransfers
            )
            try outputJSON(results, format: parent.format)
        }
    }

    struct Suggest: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Suggest categories for a merchant")

        @OptionGroup var parent: GlobalOptions

        @Argument(help: "Merchant name")
        var merchantName: String

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let categoryRepo = CategoryRepository(container: container)
            let importRuleRepo = ImportRuleRepository(container: container)
            let categorization = CategorizationRepository(
                container: container, categoryRepo: categoryRepo, importRuleRepo: importRuleRepo
            )

            let suggestions = try categorization.suggestCategory(merchantName: merchantName)
            try outputJSON(suggestions, format: parent.format)
        }
    }

    struct Review: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Review categorizations")

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Filter by account ID")
        var accountId: Int?

        @Option(name: .long, help: "Start date (YYYY-MM-DD)")
        var startDate: String?

        @Option(name: .long, help: "End date (YYYY-MM-DD)")
        var endDate: String?

        @Option(name: .long, help: "Filter by category ID")
        var categoryId: Int?

        @Option(name: .long, help: "Filter by category name")
        var categoryName: String?

        @Option(name: .long, help: "Filter by payee pattern")
        var payeePattern: String?

        @Option(name: .long, help: "Maximum results")
        var limit: Int = 50

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let categoryRepo = CategoryRepository(container: container)
            let importRuleRepo = ImportRuleRepository(container: container)
            let categorization = CategorizationRepository(
                container: container, categoryRepo: categoryRepo, importRuleRepo: importRuleRepo
            )

            let resolvedCategoryId = try categoryRepo.resolveId(
                categoryId: categoryId, categoryName: categoryName
            )

            let results = try categorization.reviewCategorizations(
                accountId: accountId,
                categoryId: resolvedCategoryId,
                payeePattern: payeePattern,
                startDate: startDate,
                endDate: endDate,
                limit: limit
            )
            try outputJSON(results, format: parent.format)
        }
    }

    struct PayeeSummary: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "payee-summary",
            abstract: "Get payee category summary"
        )

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Filter by account ID")
        var accountId: Int?

        @Option(name: .long, help: "Start date (YYYY-MM-DD)")
        var startDate: String?

        @Option(name: .long, help: "End date (YYYY-MM-DD)")
        var endDate: String?

        @Option(name: .long, help: "Minimum transactions per payee")
        var minTransactions: Int = 1

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let categoryRepo = CategoryRepository(container: container)
            let importRuleRepo = ImportRuleRepository(container: container)
            let categorization = CategorizationRepository(
                container: container, categoryRepo: categoryRepo, importRuleRepo: importRuleRepo
            )

            let results = try categorization.getPayeeCategorySummary(
                accountId: accountId,
                startDate: startDate,
                endDate: endDate,
                minTransactions: minTransactions
            )
            try outputJSON(results, format: parent.format)
        }
    }

    struct Recategorize: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Recategorize a single transaction")

        @OptionGroup var parent: GlobalOptions

        @Argument(help: "Transaction ID")
        var transactionId: Int

        @Option(name: .long, help: "Category ID to assign")
        var categoryId: Int?

        @Option(name: .long, help: "Category name or path")
        var categoryName: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let categoryRepo = CategoryRepository(container: container)
            let importRuleRepo = ImportRuleRepository(container: container)
            let categorization = CategorizationRepository(
                container: container, categoryRepo: categoryRepo, importRuleRepo: importRuleRepo
            )

            guard let resolvedId = try categoryRepo.resolveId(
                categoryId: categoryId, categoryName: categoryName
            ) else {
                throw ToolError.missingParameter("Either --category-id or --category-name is required")
            }

            guard let result = try categorization.recategorize(
                transactionId: transactionId, categoryId: resolvedId
            ) else {
                throw ToolError.notFound("Transaction not found: \(transactionId)")
            }
            try outputJSON(result, format: parent.format)
        }
    }

    struct BulkRecategorize: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "bulk-recategorize",
            abstract: "Bulk recategorize by payee pattern"
        )

        @OptionGroup var parent: GlobalOptions

        @Option(name: .long, help: "Payee/title pattern to match")
        var payeePattern: String

        @Option(name: .long, help: "Category ID to assign")
        var categoryId: Int?

        @Option(name: .long, help: "Category name or path")
        var categoryName: String?

        @Flag(name: .long, help: "Preview changes without applying")
        var dryRun = false

        @Flag(name: .long, help: "Only recategorize uncategorized transactions")
        var uncategorizedOnly = false

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)

            if !dryRun {
                try await guardWrite(writeGuard)
            }

            let categoryRepo = CategoryRepository(container: container)
            let importRuleRepo = ImportRuleRepository(container: container)
            let categorization = CategorizationRepository(
                container: container, categoryRepo: categoryRepo, importRuleRepo: importRuleRepo
            )

            guard let resolvedId = try categoryRepo.resolveId(
                categoryId: categoryId, categoryName: categoryName
            ) else {
                throw ToolError.missingParameter("Either --category-id or --category-name is required")
            }

            let result = try categorization.bulkRecategorize(
                payeePattern: payeePattern,
                categoryId: resolvedId,
                dryRun: dryRun,
                uncategorizedOnly: uncategorizedOnly
            )
            try outputJSON(result, format: parent.format)
        }
    }
}
