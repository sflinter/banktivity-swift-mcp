// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import Testing
@testable import BanktivityLib

@Suite("DateConversion")
struct DateConversionTests {

    // MARK: - toISO

    @Test("toISO returns date-only format")
    func toISOReturnsDateOnlyFormat() {
        // 2024-01-15 00:00:00 UTC = 726,969,600 seconds since 2001-01-01
        let timestamp = 726_969_600.0
        let result = DateConversion.toISO(timestamp)
        #expect(result == "2024-01-15")
    }

    @Test("toISO for Core Data reference date")
    func toISOForReferenceDate() {
        // Core Data reference date = 2001-01-01 = 0.0
        let result = DateConversion.toISO(0.0)
        #expect(result == "2001-01-01")
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

    @Test("fromISO parses date-only string")
    func fromISOParsesDateOnly() throws {
        let result = try #require(DateConversion.fromISO("2024-01-15"))
        #expect(DateConversion.toISO(result) == "2024-01-15")
    }

    @Test("fromISO parses full datetime string")
    func fromISOParsesFullDateTime() throws {
        let result = try #require(DateConversion.fromISO("2024-01-15T12:30:00Z"))
        #expect(DateConversion.toISO(result) == "2024-01-15")
    }

    @Test("fromISO returns nil for invalid strings")
    func fromISOReturnsNilForInvalidString() {
        #expect(DateConversion.fromISO("not-a-date") == nil)
        #expect(DateConversion.fromISO("") == nil)
        #expect(DateConversion.fromISO("hello world") == nil)
    }

    // MARK: - Round-trip

    @Test("Round-trip date conversion")
    func roundTripDateConversion() throws {
        let original = "2026-02-27"
        let timestamp = try #require(DateConversion.fromISO(original))
        let roundTripped = DateConversion.toISO(timestamp)
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
}
