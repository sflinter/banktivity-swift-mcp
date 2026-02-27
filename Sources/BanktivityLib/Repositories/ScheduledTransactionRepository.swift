// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

/// Repository for scheduled transaction operations using Core Data
public final class ScheduledTransactionRepository: BaseRepository, @unchecked Sendable {

    /// List all scheduled transactions
    public func list() throws -> [ScheduledTransactionDTO] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "ScheduledTemplateSelector")
        let results = try fetch(request)
        return results.compactMap { mapToDTO($0) }
    }

    /// Get a scheduled transaction by PK
    public func get(scheduleId: Int) throws -> ScheduledTransactionDTO? {
        guard let object = try fetchByPK(entityName: "ScheduledTemplateSelector", pk: scheduleId) else {
            return nil
        }
        return mapToDTO(object)
    }

    // MARK: - Write Operations

    /// Create a new scheduled transaction
    public func create(
        templateId: Int,
        startDate: String,
        accountId: String? = nil,
        repeatInterval: Int = 1,
        repeatMultiplier: Int = 1,
        reminderDays: Int = 7
    ) throws -> ScheduledTransactionDTO {
        try performWrite { [self] ctx in
            guard let template = try fetchByPK(entityName: "TransactionTemplate", pk: templateId, in: ctx) else {
                throw ToolError.notFound("Template not found: \(templateId)")
            }

            // Create RecurringTransaction
            let recurring = Self.createObject(entityName: "RecurringTransaction", in: ctx)
            recurring.setValue(1 as Int32, forKey: "pAttributes")
            recurring.setValue(0 as Int32, forKey: "pPriority")
            recurring.setValue(Int16(reminderDays), forKey: "pRemindDaysInAdvance")
            recurring.setValue(Self.generateUUID(), forKey: "pUniqueID")
            Self.setNow(recurring, "pCreationTime")
            Self.setNow(recurring, "pModificationDate")
            Self.setDate(recurring, "pFirstUnprocessedEventDate", isoString: startDate)

            // Create ScheduledTemplateSelector
            let schedule = Self.createObject(entityName: "ScheduledTemplateSelector", in: ctx)
            schedule.setValue(Int16(repeatInterval), forKey: "pRepeatInterval")
            schedule.setValue(Int16(repeatMultiplier), forKey: "pRepeatMultiplier")
            schedule.setValue(accountId, forKey: "pAccountID")
            schedule.setValue(Int16(reminderDays), forKey: "pRemindDaysInAdvance")
            schedule.setValue(Self.generateUUID(), forKey: "pUniqueID")
            Self.setNow(schedule, "pCreationTime")
            Self.setNow(schedule, "pModificationDate")
            Self.setDate(schedule, "pStartDate", isoString: startDate)
            Self.setDate(schedule, "pExternalCalendarNextDate", isoString: startDate)
            schedule.setValue(template, forKey: "pTransactionTemplate")
            schedule.setValue(recurring, forKey: "pRecurringTransaction")
        }

        // Re-fetch
        let all = try list()
        guard let result = all.last(where: { $0.templateId == templateId }) else {
            throw ToolError.notFound("Failed to retrieve created scheduled transaction")
        }
        return result
    }

    /// Update a scheduled transaction
    public func update(
        scheduleId: Int,
        startDate: String? = nil,
        nextDate: String? = nil,
        repeatInterval: Int? = nil,
        repeatMultiplier: Int? = nil,
        accountId: String? = nil,
        reminderDays: Int? = nil
    ) throws -> Bool {
        try performWriteReturning { [self] ctx in
            guard let schedule = try fetchByPK(entityName: "ScheduledTemplateSelector", pk: scheduleId, in: ctx) else {
                return false
            }

            if let startDate = startDate { Self.setDate(schedule, "pStartDate", isoString: startDate) }
            if let nextDate = nextDate { Self.setDate(schedule, "pExternalCalendarNextDate", isoString: nextDate) }
            if let repeatInterval = repeatInterval { schedule.setValue(Int16(repeatInterval), forKey: "pRepeatInterval") }
            if let repeatMultiplier = repeatMultiplier { schedule.setValue(Int16(repeatMultiplier), forKey: "pRepeatMultiplier") }
            if let accountId = accountId { schedule.setValue(accountId, forKey: "pAccountID") }
            if let reminderDays = reminderDays { schedule.setValue(Int16(reminderDays), forKey: "pRemindDaysInAdvance") }
            Self.setNow(schedule, "pModificationDate")
            return true
        }
    }

    /// Delete a scheduled transaction and its recurring transaction
    public func delete(scheduleId: Int) throws -> Bool {
        try performWriteReturning { [self] ctx in
            guard let schedule = try fetchByPK(entityName: "ScheduledTemplateSelector", pk: scheduleId, in: ctx) else {
                return false
            }

            // Also delete the recurring transaction
            if let recurring = Self.relatedObject(schedule, "pRecurringTransaction") {
                ctx.delete(recurring)
            }

            ctx.delete(schedule)
            return true
        }
    }

    // MARK: - DTO Mapping

    public func mapToDTO(_ object: NSManagedObject) -> ScheduledTransactionDTO? {
        let pk = Self.extractPK(from: object.objectID)

        guard let template = Self.relatedObject(object, "pTransactionTemplate") else { return nil }
        let templatePK = Self.extractPK(from: template.objectID)
        let templateTitle = Self.stringValue(template, "pTitle")
        let amount = Self.doubleValue(template, "pAmount")

        var startDate: String? = nil
        if let d = Self.dateValue(object, "pStartDate") { startDate = DateConversion.toISO(d) }

        var nextDate: String? = nil
        if let d = Self.dateValue(object, "pExternalCalendarNextDate") { nextDate = DateConversion.toISO(d) }

        var recurringId: Int? = nil
        if let recurring = Self.relatedObject(object, "pRecurringTransaction") {
            recurringId = Self.extractPK(from: recurring.objectID)
        }

        return ScheduledTransactionDTO(
            id: pk,
            templateId: templatePK,
            templateTitle: templateTitle,
            amount: amount,
            startDate: startDate,
            nextDate: nextDate,
            repeatInterval: Self.optionalInt(object, "pRepeatInterval"),
            repeatMultiplier: Self.optionalInt(object, "pRepeatMultiplier"),
            accountId: Self.string(object, "pAccountID"),
            reminderDays: Self.optionalInt(object, "pRemindDaysInAdvance"),
            recurringTransactionId: recurringId
        )
    }
}
