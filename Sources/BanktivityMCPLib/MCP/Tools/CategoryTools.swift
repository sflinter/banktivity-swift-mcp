// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import MCP

/// Register category-related MCP tools
func registerCategoryTools(registry: ToolRegistry, categories: CategoryRepository, writeGuard: WriteGuard) {
    // list_categories
    registry.register(
        name: "list_categories",
        description: "List income/expense categories with optional type filter",
        inputSchema: ToolHelpers.schema(properties: [
            "type": ToolHelpers.property(type: "string", description: "Filter by category type: 'income' or 'expense'"),
            "include_hidden": ToolHelpers.property(type: "boolean", description: "Include hidden categories (default: false)"),
            "top_level_only": ToolHelpers.property(type: "boolean", description: "Only return top-level categories (default: false)"),
        ])
    ) { arguments in
        let type = ToolHelpers.getString(arguments, key: "type")
        let includeHidden = ToolHelpers.getBool(arguments, key: "include_hidden")
        let topLevelOnly = ToolHelpers.getBool(arguments, key: "top_level_only")

        let results = try categories.list(
            type: type,
            includeHidden: includeHidden,
            topLevelOnly: topLevelOnly
        )

        return try ToolHelpers.jsonResponse(results)
    }

    // get_category
    registry.register(
        name: "get_category",
        description: "Get a category by ID or name/path (e.g., 'Insurance:Life')",
        inputSchema: ToolHelpers.schema(properties: [
            "category_id": ToolHelpers.property(type: "number", description: "The category ID"),
            "category_name": ToolHelpers.property(type: "string", description: "The category name or full path (e.g., 'Insurance:Life')"),
        ])
    ) { arguments in
        if let categoryId = ToolHelpers.getInt(arguments, key: "category_id") {
            guard let category = try categories.get(categoryId: categoryId) else {
                return ToolHelpers.errorResponse("Category not found: \(categoryId)")
            }
            return try ToolHelpers.jsonResponse(category)
        }

        if let categoryName = ToolHelpers.getString(arguments, key: "category_name") {
            if let category = try categories.findByPath(categoryName) {
                return try ToolHelpers.jsonResponse(category)
            }
            let byName = try categories.findByName(categoryName)
            if let first = byName.first {
                if byName.count > 1 {
                    return try ToolHelpers.jsonResponse(byName)
                }
                return try ToolHelpers.jsonResponse(first)
            }
            return ToolHelpers.errorResponse("Category not found: \(categoryName)")
        }

        return ToolHelpers.errorResponse("Either category_id or category_name is required")
    }

    // get_category_tree
    registry.register(
        name: "get_category_tree",
        description: "Get the full category hierarchy as a tree structure",
        inputSchema: ToolHelpers.schema(properties: [
            "type": ToolHelpers.property(type: "string", description: "Filter by category type: 'income' or 'expense'"),
        ])
    ) { arguments in
        let type = ToolHelpers.getString(arguments, key: "type")
        let tree = try categories.getTree(type: type)
        return try ToolHelpers.jsonResponse(tree)
    }

    // create_category
    registry.register(
        name: "create_category",
        description: "Create a new income or expense category",
        inputSchema: ToolHelpers.schema(
            properties: [
                "name": ToolHelpers.property(type: "string", description: "The category name"),
                "type": ToolHelpers.property(type: "string", description: "Category type: 'income' or 'expense'"),
                "parent_id": ToolHelpers.property(type: "number", description: "Parent category ID (for subcategories)"),
                "parent_path": ToolHelpers.property(type: "string", description: "Parent category path (e.g., 'Insurance')"),
                "hidden": ToolHelpers.property(type: "boolean", description: "Whether the category should be hidden (default: false)"),
                "currency_code": ToolHelpers.property(type: "string", description: "Currency code (e.g., 'EUR')"),
            ],
            required: ["name", "type"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        guard let name = ToolHelpers.getString(arguments, key: "name") else {
            return ToolHelpers.errorResponse("name is required")
        }
        guard let type = ToolHelpers.getString(arguments, key: "type"),
              type == "income" || type == "expense" else {
            return ToolHelpers.errorResponse("type must be 'income' or 'expense'")
        }

        // Resolve parent
        var parentId = ToolHelpers.getInt(arguments, key: "parent_id")
        if parentId == nil, let parentPath = ToolHelpers.getString(arguments, key: "parent_path") {
            parentId = try categories.resolveId(categoryName: parentPath)
        }

        let hidden = ToolHelpers.getBool(arguments, key: "hidden")
        let currencyCode = ToolHelpers.getString(arguments, key: "currency_code")

        let result = try categories.create(
            name: name,
            type: type,
            parentId: parentId,
            hidden: hidden,
            currencyCode: currencyCode
        )

        return try ToolHelpers.jsonResponse(result)
    }
}
