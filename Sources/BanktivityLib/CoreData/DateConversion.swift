// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

/// Core Data uses a reference date of January 1, 2001 (Apple epoch).
/// These helpers convert between Core Data's NSTimeInterval and ISO 8601 date strings.
///
/// Banktivity date-only fields are calendar labels, but Core Data stores them as
/// instants. Storing one at *host-local* midnight makes the rendered calendar date
/// depend on where the reader is sitting: a row written at midnight in Melbourne
/// reads as the previous day in Denver. Measured on the production vault on
/// 2026-09-02, that put 1,992 investment transactions on a weekend when read in
/// Denver and 30 when read in Melbourne -- the same rows, the same file.
///
/// Date-only values are therefore anchored to a fixed offset **at the point of
/// write** -- see `dateOnlyTimeZone` and its use in `BaseRepository.setDate`.
/// Reads and query boundaries deliberately keep the host zone: anchoring those
/// too was implemented, reviewed and rejected on 2026-09-02 because it re-dated
/// every not-yet-restamped row and every statement period. Full ISO 8601
/// timestamps are unaffected and remain UTC.
public enum DateConversion {
    /// The fixed anchor for date-only values: UTC-10, so a date-only label is
    /// stored at **10:00 UTC**.
    ///
    /// Derivation. For a date `D` stored at time `T` to render as `D` everywhere
    /// the vault is read, `T` must clear midnight in both directions:
    /// the westmost reader (Denver at UTC-7, its standard offset) needs `T >= 07:00`,
    /// and the eastmost (Melbourne at UTC+11 in DST) needs `T < 13:00`. `T = 10:00 UTC`
    /// sits mid-window and holds from UTC-10 (Hawaii) through UTC+13 (Auckland
    /// in DST).
    ///
    /// A fixed offset is used rather than a named zone so no daylight-saving
    /// transition can move it. Do not replace this with `.current`: that is the
    /// defect this constant exists to prevent.
    public static let dateOnlyTimeZone: TimeZone = TimeZone(secondsFromGMT: -10 * 3600)!

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

    private static func dateOnlyFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    private static func dateOnlyDate(
        from isoString: String,
        timeZone: TimeZone
    ) -> Date? {
        let parts = isoString.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].utf8.count == 4,
              parts[1].utf8.count == 2,
              parts[2].utf8.count == 2,
              parts.allSatisfy({ part in
                  part.utf8.allSatisfy { byte in (48...57).contains(byte) }
              }),
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(
            from: DateComponents(year: year, month: month, day: day)
        ) else {
            return nil
        }

        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year,
              resolved.month == month,
              resolved.day == day else {
            return nil
        }
        return date
    }

    /// Convert a Core Data timestamp to a date-only `YYYY-MM-DD` calendar label.
    public static func toISO(
        _ coreDataTimestamp: Double,
        timeZone: TimeZone = .current
    ) -> String {
        let date = Date(timeIntervalSinceReferenceDate: coreDataTimestamp)
        return dateOnlyFormatter(timeZone: timeZone).string(from: date)
    }

    /// Convert a Core Data timestamp to a full ISO 8601 datetime string in UTC.
    public static func toISODateTime(_ coreDataTimestamp: Double) -> String {
        let date = Date(timeIntervalSinceReferenceDate: coreDataTimestamp)
        return isoFormatter.string(from: date)
    }

    /// Convert a date-only `YYYY-MM-DD` label or full ISO 8601 timestamp to Core Data time.
    ///
    /// Date-only values become midnight in `timeZone`, which **defaults to the host
    /// zone**. Write paths pass `dateOnlyTimeZone` explicitly; read and query paths
    /// intentionally do not. Full timestamps retain their explicit offset and
    /// continue to use ISO 8601 instant semantics.
    public static func fromISO(
        _ isoString: String,
        timeZone: TimeZone = .current
    ) -> Double? {
        if isoString.count == 10 {
            guard let date = dateOnlyDate(from: isoString, timeZone: timeZone) else {
                return nil
            }
            return date.timeIntervalSinceReferenceDate
        }
        if let date = isoFormatter.date(from: isoString) {
            return date.timeIntervalSinceReferenceDate
        }
        return nil
    }

    /// The exclusive upper bound for a date window ending on `dateOnly`.
    ///
    /// Midnight is the *start* of a day. A predicate built as
    /// `pDate <= midnight(endDate)` therefore admits only rows stored at or before
    /// the end day's first moment and silently drops every row stored later in it.
    /// Measured on the production vault on 2026-09-02: two of three sampled rows
    /// were already missing from a same-day window, before any anchoring work.
    ///
    /// Use with a strict `<`. Returns midnight of the following day, added through
    /// the calendar so a DST-shortened or -lengthened day stays correct -- which
    /// adding 86,400 seconds would not.
    public static func endOfDayExclusive(
        _ dateOnly: String,
        timeZone: TimeZone = .current
    ) -> Double? {
        guard let startOfDay = fromISO(dateOnly, timeZone: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let next = calendar.date(
            byAdding: .day, value: 1, to: Date(timeIntervalSinceReferenceDate: startOfDay)
        ) else { return nil }
        return next.timeIntervalSinceReferenceDate
    }

    /// Render a date-only label as the sync-blob timestamp for the same instant
    /// the Core Data write uses.
    ///
    /// The blob and Core Data must describe the same moment. When they disagreed,
    /// a row could be written correctly and then described as UTC midnight in the
    /// blob, letting a sync round-trip move the date.
    ///
    /// This runs the *same* conversion the Core Data write runs and formats the
    /// result, rather than deriving an hour arithmetically -- so the two cannot
    /// drift apart, and the result stays correct if `dateOnlyTimeZone` is ever
    /// changed to a positive or half-hour offset.
    public static func syncBlobTimestamp(dateOnly: String) -> String {
        guard let ts = fromISO(dateOnly, timeZone: dateOnlyTimeZone) else { return dateOnly }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZ"
        return formatter.string(from: Date(timeIntervalSinceReferenceDate: ts))
    }

    /// Convert a Date to Core Data timestamp
    public static func fromDate(_ date: Date) -> Double {
        date.timeIntervalSinceReferenceDate
    }

    /// Convert Core Data timestamp to Date
    public static func toDate(_ coreDataTimestamp: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: coreDataTimestamp)
    }
}
