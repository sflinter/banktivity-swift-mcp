// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import Testing
@testable import BanktivityLib

@Suite("DateConversion")
struct DateConversionTests {

    // MARK: - toISO

    @Test("toISO returns date-only format for UTC midnight")
    func toISOReturnsDateOnlyFormat() {
        // 2024-01-15 00:00:00 UTC = 726,969,600 seconds since 2001-01-01
        let timestamp = 726_969_600.0
        let result = DateConversion.toISO(timestamp, timeZone: TimeZone(identifier: "UTC")!)
        #expect(result == "2024-01-15")
    }

    @Test("toISO for Core Data reference date")
    func toISOForReferenceDate() {
        // Core Data reference date = 2001-01-01 = 0.0
        let result = DateConversion.toISO(0.0, timeZone: TimeZone(identifier: "UTC")!)
        #expect(result == "2001-01-01")
    }

    @Test("toISO preserves an east-of-UTC Banktivity calendar day")
    func toISOPreservesEastOfUTCCalendarDay() throws {
        let sydney = try #require(TimeZone(identifier: "Australia/Sydney"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sydney
        let localMidnight = try #require(
            calendar.date(from: DateComponents(year: 2024, month: 12, day: 2))
        )
        let timestamp = DateConversion.fromDate(localMidnight)

        #expect(DateConversion.toISO(timestamp, timeZone: sydney) == "2024-12-02")
        #expect(DateConversion.toISO(timestamp, timeZone: TimeZone(identifier: "UTC")!) == "2024-12-01")
    }

    // MARK: - toISODateTime

    @Test("toISODateTime returns full ISO 8601 format")
    func toISODateTimeReturnsFullFormat() {
        let timestamp = 726_969_600.0
        let result = DateConversion.toISODateTime(timestamp)
        #expect(result.hasPrefix("2024-01-15T"))
        #expect(result.hasSuffix("Z"))
    }

    // MARK: - fromISO

    @Test("fromISO parses date-only string in the given zone")
    func fromISOParsesDateOnly() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let result = try #require(DateConversion.fromISO("2024-01-15", timeZone: utc))
        #expect(DateConversion.toISO(result, timeZone: utc) == "2024-01-15")
    }

    @Test("fromISO preserves a west-of-UTC transaction date")
    func fromISOPreservesWestOfUTCTransactionDate() throws {
        let lima = try #require(TimeZone(identifier: "America/Lima"))
        let timestamp = try #require(DateConversion.fromISO("2026-04-06", timeZone: lima))

        #expect(DateConversion.toISO(timestamp, timeZone: lima) == "2026-04-06")
        #expect(DateConversion.toISO(timestamp, timeZone: TimeZone(identifier: "UTC")!) == "2026-04-06")
    }

    @Test("fromISO accepts a valid date whose zone skips local midnight")
    func fromISOAcceptsDateWhoseZoneSkipsMidnight() throws {
        let saoPaulo = try #require(TimeZone(identifier: "America/Sao_Paulo"))
        let timestamp = try #require(
            DateConversion.fromISO("2018-11-04", timeZone: saoPaulo)
        )

        #expect(DateConversion.toISO(timestamp, timeZone: saoPaulo) == "2018-11-04")
        #expect(DateConversion.toISODateTime(timestamp) == "2018-11-04T03:00:00Z")
    }

    @Test("fromISO parses full datetime string")
    func fromISOParsesFullDateTime() throws {
        let result = try #require(DateConversion.fromISO("2024-01-15T12:30:00Z"))
        #expect(DateConversion.toISO(result, timeZone: TimeZone(identifier: "UTC")!) == "2024-01-15")
    }

    @Test("fromISO returns nil for invalid strings")
    func fromISOReturnsNilForInvalidString() {
        #expect(DateConversion.fromISO("not-a-date") == nil)
        #expect(DateConversion.fromISO("") == nil)
        #expect(DateConversion.fromISO("hello world") == nil)
        #expect(DateConversion.fromISO("2024-02-30") == nil)
        #expect(DateConversion.fromISO("2024-01-15junk") == nil)
    }

    // MARK: - Round-trip

    @Test("Round-trip date conversion")
    func roundTripDateConversion() throws {
        let original = "2026-02-27"
        let sydney = try #require(TimeZone(identifier: "Australia/Sydney"))
        let timestamp = try #require(DateConversion.fromISO(original, timeZone: sydney))
        let roundTripped = DateConversion.toISO(timestamp, timeZone: sydney)
        #expect(roundTripped == original)
    }

    // MARK: - toDate / fromDate

    @Test("toDate returns correct Date")
    func toDateReturnsCorrectDate() {
        let timestamp = 0.0
        let date = DateConversion.toDate(timestamp)
        #expect(date == Date(timeIntervalSinceReferenceDate: 0))
    }

    @Test("fromDate returns timestamp")
    func fromDateReturnsTimestamp() {
        let date = Date(timeIntervalSinceReferenceDate: 12345.0)
        let timestamp = DateConversion.fromDate(date)
        #expect(timestamp == 12345.0)
    }

    // MARK: - Date-only anchor (added 2026-09-02)
    //
    // These two cover the whole of the date-anchor change. Before they existed
    // the entire suite passed with the change reverted, because every other
    // DateConversion test passes an explicit `timeZone` and so is blind to what
    // the anchor does.

    @Test("the defaults stay host-local; only writers anchor")
    func defaultsRemainHostLocal() throws {
        // This is the contract that caused the 2026-09-02 rollback. Anchoring the
        // read/query defaults re-dated every not-yet-restamped row and every
        // statement period. If someone changes either default to dateOnlyTimeZone,
        // this fails -- which nothing else in the suite would catch.
        let label = "2026-06-08"
        let viaDefault = try #require(DateConversion.fromISO(label))
        let viaHost = try #require(DateConversion.fromISO(label, timeZone: .current))
        #expect(viaDefault == viaHost)

        let ts = 800_000_000.0
        #expect(DateConversion.toISO(ts) == DateConversion.toISO(ts, timeZone: .current))

        // And the anchor itself is 10:00 UTC, which is what write paths opt into.
        let anchored = try #require(
            DateConversion.fromISO(label, timeZone: DateConversion.dateOnlyTimeZone)
        )
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let parts = utcCalendar.dateComponents(
            [.hour, .minute], from: Date(timeIntervalSinceReferenceDate: anchored)
        )
        #expect(parts.hour == 10)
        #expect(parts.minute == 0)
    }

    @Test("the sync blob timestamp describes the same instant as the Core Data write")
    func syncBlobTimestampMatchesTheStoredInstant() throws {
        let dateOnly = "2026-06-08"
        let stored = try #require(
            DateConversion.fromISO(dateOnly, timeZone: DateConversion.dateOnlyTimeZone)
        )

        let blob = DateConversion.syncBlobTimestamp(dateOnly: dateOnly)
        #expect(blob == "2026-06-08T10:00:00+0000")

        // Round-trip: the blob string must parse back to the very instant Core Data
        // holds. If these two ever disagree a sync can silently move the date.
        let reparsed = try #require(DateConversion.fromISO(blob))
        #expect(reparsed == stored)
    }
}
