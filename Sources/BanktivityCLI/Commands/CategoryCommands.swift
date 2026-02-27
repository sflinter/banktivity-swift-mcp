// Copyright (c) 2026 Steve Flinter. MIT License.

import ArgumentParser
import BanktivityLib
import Foundation

struct Categories: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Category operations",
        subcommands: [List.self, Get.self, Tree.self, Create.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List categories")

        @OptionGroup var parent: VaultOption

        @Option(name: .long, help: "Filter by type: income or expense")
        var type: String?

        @Flag(name: .long, help: "Include hidden categories")
        var includeHidden = false

        @Flag(name: .long, help: "Only return top-level categories")
        var topLevelOnly = false

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let categories = CategoryRepository(container: container)

            let results = try categories.list(
                type: type,
                includeHidden: includeHidden,
                topLevelOnly: topLevelOnly
            )
            try outputJSON(results)
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get a category by ID or name")

        @OptionGroup var parent: VaultOption

        @Argument(help: "Category ID or name/path (e.g. 'Insurance:Life')")
        var identifier: String

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let categories = CategoryRepository(container: container)

            if let id = Int(identifier) {
                guard let category = try categories.get(categoryId: id) else {
                    throw ToolError.notFound("Category not found: \(id)")
                }
                try outputJSON(category)
            } else {
                if let category = try categories.findByPath(identifier) {
                    try outputJSON(category)
                } else {
                    let byName = try categories.findByName(identifier)
                    guard !byName.isEmpty else {
                        throw ToolError.notFound("Category not found: \(identifier)")
                    }
                    if byName.count == 1 {
                        try outputJSON(byName[0])
                    } else {
                        try outputJSON(byName)
                    }
                }
            }
        }
    }

    struct Tree: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get category tree")

        @OptionGroup var parent: VaultOption

        @Option(name: .long, help: "Filter by type: income or expense")
        var type: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let categories = CategoryRepository(container: container)

            let tree = try categories.getTree(type: type)
            try outputJSON(tree)
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a category")

        @OptionGroup var parent: VaultOption

        @Option(name: .long, help: "Category name")
        var name: String

        @Option(name: .long, help: "Category type: income or expense")
        var type: String

        @Option(name: .long, help: "Parent category ID")
        var parentId: Int?

        @Option(name: .long, help: "Parent category path")
        var parentPath: String?

        @Flag(name: .long, help: "Create as hidden")
        var hidden = false

        @Option(name: .long, help: "Currency code (e.g. EUR)")
        var currencyCode: String?

        func run() async throws {
            let path = try BanktivityCLI.resolveVaultPath(vault: parent.vault)
            let container = try BanktivityCLI.createContainer(vaultPath: path)
            let writeGuard = BanktivityCLI.createWriteGuard(vaultPath: path)
            try await guardWrite(writeGuard)

            let categories = CategoryRepository(container: container)

            var resolvedParentId = parentId
            if resolvedParentId == nil, let parentPath = parentPath {
                resolvedParentId = try categories.resolveId(categoryName: parentPath)
            }

            let result = try categories.create(
                name: name,
                type: type,
                parentId: resolvedParentId,
                hidden: hidden,
                currencyCode: currencyCode
            )
            try outputJSON(result)
        }
    }
}
