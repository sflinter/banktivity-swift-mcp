// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import MCP

/// Helper functions for building MCP tool responses
enum ToolHelpers {

    /// Create a successful JSON response from an Encodable value
    static func jsonResponse<T: Encodable>(_ data: T) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(data)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
        return CallTool.Result(content: [.text(jsonString)])
    }

    /// Create a successful JSON response from a dictionary
    static func jsonResponse(_ data: [String: Any]) -> CallTool.Result {
        if let jsonData = try? JSONSerialization.data(
            withJSONObject: data, options: [.prettyPrinted, .sortedKeys]
        ) {
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            return CallTool.Result(content: [.text(jsonString)])
        }
        return CallTool.Result(content: [.text("{}")], isError: true)
    }

    /// Create a successful JSON response from an array of dictionaries
    static func jsonResponse(_ data: [[String: Any]]) -> CallTool.Result {
        if let jsonData = try? JSONSerialization.data(
            withJSONObject: data, options: [.prettyPrinted, .sortedKeys]
        ) {
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            return CallTool.Result(content: [.text(jsonString)])
        }
        return CallTool.Result(content: [.text("[]")], isError: true)
    }

    /// Create an error response
    static func errorResponse(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(message)], isError: true)
    }

    /// Create a success message response with optional data
    static func successResponse(_ message: String, data: [String: Any]? = nil) -> CallTool.Result {
        var response: [String: Any] = ["message": message]
        if let data = data {
            for (key, value) in data {
                response[key] = value
            }
        }
        return jsonResponse(response)
    }

    /// Format currency for display
    static func formatCurrency(_ amount: Double, currency: String = "EUR") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = Locale(identifier: "nl_NL")
        return formatter.string(from: NSNumber(value: amount)) ?? "\(amount)"
    }

    /// Extract a string value from tool arguments
    static func getString(_ arguments: [String: Value]?, key: String) -> String? {
        guard let value = arguments?[key] else { return nil }
        if case .string(let s) = value { return s }
        return nil
    }

    /// Extract an integer value from tool arguments
    static func getInt(_ arguments: [String: Value]?, key: String) -> Int? {
        guard let value = arguments?[key] else { return nil }
        if case .int(let i) = value { return i }
        if case .double(let d) = value { return Int(d) }
        return nil
    }

    /// Extract a double value from tool arguments
    static func getDouble(_ arguments: [String: Value]?, key: String) -> Double? {
        guard let value = arguments?[key] else { return nil }
        if case .double(let d) = value { return d }
        if case .int(let i) = value { return Double(i) }
        return nil
    }

    /// Extract a boolean value from tool arguments
    static func getBool(_ arguments: [String: Value]?, key: String, default defaultValue: Bool = false) -> Bool {
        guard let value = arguments?[key] else { return defaultValue }
        if case .bool(let b) = value { return b }
        return defaultValue
    }

    /// Extract an array of values from tool arguments
    static func getArray(_ arguments: [String: Value]?, key: String) -> [Value]? {
        guard let value = arguments?[key] else { return nil }
        if case .array(let arr) = value { return arr }
        return nil
    }

    /// Extract an object from tool arguments
    static func getObject(_ arguments: [String: Value]?, key: String) -> [String: Value]? {
        guard let value = arguments?[key] else { return nil }
        if case .object(let obj) = value { return obj }
        return nil
    }

    /// Build a JSON Schema object for tool input
    static func schema(
        properties: [String: Value],
        required: [String] = []
    ) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return .object(schema)
    }

    /// Build a property definition for a JSON Schema
    static func property(
        type: String,
        description: String,
        enumValues: [String]? = nil
    ) -> Value {
        var prop: [String: Value] = [
            "type": .string(type),
            "description": .string(description),
        ]
        if let enumValues = enumValues {
            prop["enum"] = .array(enumValues.map { .string($0) })
        }
        return .object(prop)
    }
}
