// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

/// Core Data uses a reference date of January 1, 2001 (Apple epoch).
/// These helpers convert between Core Data's NSTimeInterval and ISO 8601 date strings.
enum DateConversion {
    /// Apple's reference date: January 1, 2001 00:00:00 UTC
    private static let appleReferenceDate: Date = {
        var components = DateComponents()
        components.year = 2001
        components.month = 1
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Convert Core Data timestamp (seconds since 2001-01-01) to ISO 8601 date string (YYYY-MM-DD)
    static func toISO(_ coreDataTimestamp: Double) -> String {
        let date = Date(timeIntervalSinceReferenceDate: coreDataTimestamp)
        return dateOnlyFormatter.string(from: date)
    }

    /// Convert Core Data timestamp to full ISO 8601 datetime string
    static func toISODateTime(_ coreDataTimestamp: Double) -> String {
        let date = Date(timeIntervalSinceReferenceDate: coreDataTimestamp)
        return isoFormatter.string(from: date)
    }

    /// Convert ISO 8601 date string (YYYY-MM-DD) to Core Data timestamp
    static func fromISO(_ isoString: String) -> Double? {
        if let date = dateOnlyFormatter.date(from: isoString) {
            return date.timeIntervalSinceReferenceDate
        }
        if let date = isoFormatter.date(from: isoString) {
            return date.timeIntervalSinceReferenceDate
        }
        return nil
    }

    /// Convert a Date to Core Data timestamp
    static func fromDate(_ date: Date) -> Double {
        date.timeIntervalSinceReferenceDate
    }

    /// Convert Core Data timestamp to Date
    static func toDate(_ coreDataTimestamp: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: coreDataTimestamp)
    }
}
