// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import MCP

/// Register scheduled transaction MCP tools
func registerScheduledTransactionTools(
    registry: ToolRegistry,
    scheduled: ScheduledTransactionRepository,
    writeGuard: WriteGuard
) {
    // list_scheduled_transactions
    registry.register(
        name: "list_scheduled_transactions",
        description: "List all scheduled/recurring transactions",
        inputSchema: ToolHelpers.schema(properties: [:])
    ) { _ in
        let results = try scheduled.list()
        return try ToolHelpers.jsonResponse(results)
    }

    // get_scheduled_transaction
    registry.register(
        name: "get_scheduled_transaction",
        description: "Get a specific scheduled transaction by ID",
        inputSchema: ToolHelpers.schema(
            properties: [
                "schedule_id": ToolHelpers.property(type: "number", description: "The scheduled transaction ID"),
            ],
            required: ["schedule_id"]
        )
    ) { arguments in
        guard let scheduleId = ToolHelpers.getInt(arguments, key: "schedule_id") else {
            return ToolHelpers.errorResponse("schedule_id is required")
        }

        guard let schedule = try scheduled.get(scheduleId: scheduleId) else {
            return ToolHelpers.errorResponse("Scheduled transaction not found: \(scheduleId)")
        }

        return try ToolHelpers.jsonResponse(schedule)
    }

    // create_scheduled_transaction
    registry.register(
        name: "create_scheduled_transaction",
        description: "Create a new scheduled/recurring transaction",
        inputSchema: ToolHelpers.schema(
            properties: [
                "template_id": ToolHelpers.property(type: "number", description: "The transaction template ID to use"),
                "start_date": ToolHelpers.property(type: "string", description: "Start date in ISO format (YYYY-MM-DD)"),
                "account_id": ToolHelpers.property(type: "string", description: "Account UUID for the transaction"),
                "repeat_interval": ToolHelpers.property(type: "number", description: "Repeat interval (1=daily, 7=weekly, 30=monthly)"),
                "repeat_multiplier": ToolHelpers.property(type: "number", description: "Multiplier for repeat interval"),
                "reminder_days": ToolHelpers.property(type: "number", description: "Days in advance to show reminder"),
            ],
            required: ["template_id", "start_date"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        guard let templateId = ToolHelpers.getInt(arguments, key: "template_id") else {
            return ToolHelpers.errorResponse("template_id is required")
        }
        guard let startDate = ToolHelpers.getString(arguments, key: "start_date") else {
            return ToolHelpers.errorResponse("start_date is required")
        }

        let accountId = ToolHelpers.getString(arguments, key: "account_id")
        let repeatInterval = ToolHelpers.getInt(arguments, key: "repeat_interval") ?? 1
        let repeatMultiplier = ToolHelpers.getInt(arguments, key: "repeat_multiplier") ?? 1
        let reminderDays = ToolHelpers.getInt(arguments, key: "reminder_days") ?? 7

        let result = try scheduled.create(
            templateId: templateId,
            startDate: startDate,
            accountId: accountId,
            repeatInterval: repeatInterval,
            repeatMultiplier: repeatMultiplier,
            reminderDays: reminderDays
        )

        return try ToolHelpers.jsonResponse(result)
    }

    // update_scheduled_transaction
    registry.register(
        name: "update_scheduled_transaction",
        description: "Update an existing scheduled transaction",
        inputSchema: ToolHelpers.schema(
            properties: [
                "schedule_id": ToolHelpers.property(type: "number", description: "The scheduled transaction ID to update"),
                "start_date": ToolHelpers.property(type: "string", description: "New start date in ISO format"),
                "next_date": ToolHelpers.property(type: "string", description: "New next occurrence date in ISO format"),
                "repeat_interval": ToolHelpers.property(type: "number", description: "New repeat interval"),
                "repeat_multiplier": ToolHelpers.property(type: "number", description: "New repeat multiplier"),
                "account_id": ToolHelpers.property(type: "string", description: "New account UUID"),
                "reminder_days": ToolHelpers.property(type: "number", description: "New reminder days"),
            ],
            required: ["schedule_id"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        guard let scheduleId = ToolHelpers.getInt(arguments, key: "schedule_id") else {
            return ToolHelpers.errorResponse("schedule_id is required")
        }

        let success = try scheduled.update(
            scheduleId: scheduleId,
            startDate: ToolHelpers.getString(arguments, key: "start_date"),
            nextDate: ToolHelpers.getString(arguments, key: "next_date"),
            repeatInterval: ToolHelpers.getInt(arguments, key: "repeat_interval"),
            repeatMultiplier: ToolHelpers.getInt(arguments, key: "repeat_multiplier"),
            accountId: ToolHelpers.getString(arguments, key: "account_id"),
            reminderDays: ToolHelpers.getInt(arguments, key: "reminder_days")
        )

        if success {
            if let updated = try scheduled.get(scheduleId: scheduleId) {
                return try ToolHelpers.jsonResponse(updated)
            }
        }
        return ToolHelpers.errorResponse("Scheduled transaction not found: \(scheduleId)")
    }

    // delete_scheduled_transaction
    registry.register(
        name: "delete_scheduled_transaction",
        description: "Delete a scheduled transaction",
        inputSchema: ToolHelpers.schema(
            properties: [
                "schedule_id": ToolHelpers.property(type: "number", description: "The scheduled transaction ID to delete"),
            ],
            required: ["schedule_id"]
        )
    ) { arguments in
        if let msg = await writeGuard.guardWriteAccess() {
            return ToolHelpers.errorResponse(msg)
        }
        guard let scheduleId = ToolHelpers.getInt(arguments, key: "schedule_id") else {
            return ToolHelpers.errorResponse("schedule_id is required")
        }

        let deleted = try scheduled.delete(scheduleId: scheduleId)
        if deleted {
            return ToolHelpers.successResponse("Scheduled transaction \(scheduleId) deleted")
        }
        return ToolHelpers.errorResponse("Scheduled transaction not found: \(scheduleId)")
    }
}
