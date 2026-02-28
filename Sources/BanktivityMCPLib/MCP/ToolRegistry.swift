// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
@_exported import BanktivityLib
import MCP

/// Central registry for all MCP tools.
/// Manages tool definitions and dispatches tool calls to the appropriate handler.
public final class ToolRegistry: @unchecked Sendable {
    private let container: NSPersistentContainer
    private let writeGuard: WriteGuard
    private let bankFilePath: String

    struct ToolDefinition: Sendable {
        let tool: Tool
        let handler: @Sendable ([String: Value]?) async throws -> CallTool.Result
    }

    private var tools: [String: ToolDefinition] = [:]

    public init(container: NSPersistentContainer, writeGuard: WriteGuard, bankFilePath: String) {
        self.container = container
        self.writeGuard = writeGuard
        self.bankFilePath = bankFilePath
    }

    /// Register a tool with its handler
    func register(
        name: String,
        description: String,
        inputSchema: Value,
        handler: @escaping @Sendable ([String: Value]?) async throws -> CallTool.Result
    ) {
        let tool = Tool(
            name: name,
            description: description,
            inputSchema: inputSchema
        )
        tools[name] = ToolDefinition(tool: tool, handler: handler)
    }

    /// Get all registered tool definitions
    public func listTools() -> [Tool] {
        tools.values.map(\.tool).sorted { $0.name < $1.name }
    }

    /// Dispatch a tool call by name
    public func callTool(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        guard let definition = tools[name] else {
            return ToolHelpers.errorResponse("Unknown tool: \(name)")
        }

        do {
            return try await definition.handler(arguments)
        } catch {
            FileHandle.standardError.write(Data("[banktivity-mcp] Tool '\(name)' error: \(error)\n".utf8))
            return ToolHelpers.errorResponse("Tool error: \(error)")
        }
    }

    /// Register the built-in diagnostic tool for dumping the Core Data model schema
    func registerDiagnosticTools() {
        register(
            name: "dump_schema",
            description:
                "Dump the Core Data model schema showing all entity names, attributes, and relationships. Use this to discover property names for querying.",
            inputSchema: ToolHelpers.schema(properties: [
                "entity_name": ToolHelpers.property(
                    type: "string",
                    description:
                        "Optional: filter to a specific entity name (e.g. 'Transaction', 'Account')"
                )
            ])
        ) { [bankFilePath] arguments in
            let storeContentURL = URL(fileURLWithPath: bankFilePath)
                .appendingPathComponent("StoreContent")
            let schema = try PersistentContainerFactory.dumpModelSchema(from: storeContentURL)

            let entityFilter = ToolHelpers.getString(arguments, key: "entity_name")

            if let entityFilter = entityFilter {
                let filtered = schema.filter {
                    ($0["name"] as? String)?.lowercased() == entityFilter.lowercased()
                }
                if filtered.isEmpty {
                    return ToolHelpers.errorResponse(
                        "Entity '\(entityFilter)' not found. Use dump_schema without entity_name to see all entities."
                    )
                }
                return ToolHelpers.jsonResponse(filtered)
            }

            return ToolHelpers.jsonResponse(schema)
        }
    }

    /// Register all tools. Called during server initialization.
    public func registerAllTools() {
        registerDiagnosticTools()

        // Create repositories
        let lineItemRepo = LineItemRepository(container: container)
        let accountRepo = AccountRepository(container: container)
        let transactionRepo = TransactionRepository(container: container, lineItemRepo: lineItemRepo)
        let tagRepo = TagRepository(container: container)
        let categoryRepo = CategoryRepository(container: container)
        let templateRepo = TemplateRepository(container: container)
        let importRuleRepo = ImportRuleRepository(container: container)
        let scheduledRepo = ScheduledTransactionRepository(container: container)
        let categorizationRepo = CategorizationRepository(
            container: container,
            categoryRepo: categoryRepo,
            importRuleRepo: importRuleRepo
        )

        // Account tools
        registerAccountTools(registry: self, accounts: accountRepo, tags: tagRepo)

        // Transaction tools (read + write)
        registerTransactionTools(
            registry: self, transactions: transactionRepo,
            accounts: accountRepo, writeGuard: writeGuard
        )

        // Category tools (read + write)
        registerCategoryTools(registry: self, categories: categoryRepo, writeGuard: writeGuard)

        // Tag tools (read + write)
        registerTagTools(
            registry: self, tags: tagRepo,
            writeGuard: writeGuard, transactions: transactionRepo
        )

        // Template tools (read + write)
        registerTemplateTools(registry: self, templates: templateRepo, writeGuard: writeGuard)

        // Import rule tools (read + write)
        registerImportRuleTools(registry: self, importRules: importRuleRepo, writeGuard: writeGuard)

        // Scheduled transaction tools (read + write)
        registerScheduledTransactionTools(registry: self, scheduled: scheduledRepo, writeGuard: writeGuard)

        // Categorization tools (read + write)
        registerCategorizationTools(
            registry: self, categorization: categorizationRepo,
            categories: categoryRepo, writeGuard: writeGuard
        )

        // Line item tools (read + write)
        registerLineItemTools(
            registry: self, lineItems: lineItemRepo,
            accounts: accountRepo, writeGuard: writeGuard
        )

        // Statement tools (read + write)
        let statementRepo = StatementRepository(container: container, lineItemRepo: lineItemRepo)
        registerStatementTools(
            registry: self, statements: statementRepo,
            accounts: accountRepo, lineItems: lineItemRepo, writeGuard: writeGuard
        )
    }
}
