// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import Testing
@testable import BanktivityLib

struct ExchangeRateRepositoryTests {
    @Test func lookupUsesLatestDirectRate() {
        let older = Date(timeIntervalSinceReferenceDate: 100)
        let newer = Date(timeIntervalSinceReferenceDate: 200)
        let result = ExchangeRateRepository.resolve(
            from: "USD",
            to: "KZT",
            rates: [
                ExchangeRateRecord(source: "USD", destination: "KZT", rate: Decimal(466), effectiveDate: older),
                ExchangeRateRecord(source: "USD", destination: "KZT", rate: Decimal(562), effectiveDate: newer),
            ]
        )

        #expect(result?.rate == Decimal(562))
        #expect(result?.effectiveDate == newer)
        #expect(result?.hops == 1)
        #expect(result?.path == ["USD", "KZT"])
    }

    @Test func lookupFallsBackToReverseRate() {
        let date = Date(timeIntervalSinceReferenceDate: 300)
        let result = ExchangeRateRepository.resolve(
            from: "USD",
            to: "KZT",
            rates: [
                ExchangeRateRecord(source: "KZT", destination: "USD", rate: Decimal(string: "0.002")!, effectiveDate: date),
            ]
        )

        #expect(result?.rate == Decimal(500))
        #expect(result?.effectiveDate == date)
        #expect(result?.hops == 1)
        #expect(result?.path == ["USD", "KZT"])
    }

    @Test func lookupFallsBackThroughUSDPivot() {
        let firstDate = Date(timeIntervalSinceReferenceDate: 400)
        let secondDate = Date(timeIntervalSinceReferenceDate: 500)
        let result = ExchangeRateRepository.resolve(
            from: "EUR",
            to: "KZT",
            rates: [
                ExchangeRateRecord(source: "EUR", destination: "USD", rate: Decimal(string: "1.2")!, effectiveDate: firstDate),
                ExchangeRateRecord(source: "USD", destination: "KZT", rate: Decimal(500), effectiveDate: secondDate),
            ]
        )

        #expect(result?.rate == Decimal(600))
        #expect(result?.effectiveDate == firstDate)
        #expect(result?.hops == 2)
        #expect(result?.path == ["EUR", "USD", "KZT"])
    }

    @Test func lookupReturnsNilWhenNoRateAvailable() {
        let result = ExchangeRateRepository.resolve(
            from: "GBP",
            to: "KZT",
            rates: [
                ExchangeRateRecord(source: "EUR", destination: "USD", rate: Decimal(string: "1.2")!, effectiveDate: nil),
            ]
        )

        #expect(result == nil)
    }

    @Test func lookupSameCurrencyUsesIdentityRate() {
        let result = ExchangeRateRepository.resolve(from: "KZT", to: "KZT", rates: [])

        #expect(result?.rate == Decimal(1))
        #expect(result?.effectiveDate == nil)
        #expect(result?.hops == 0)
        #expect(result?.path == ["KZT"])
    }
}
