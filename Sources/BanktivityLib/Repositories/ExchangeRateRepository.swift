// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation

public struct ExchangeRateRecord: Sendable, Equatable {
    public let source: String
    public let destination: String
    public let rate: Decimal
    public let effectiveDate: Date?

    public init(source: String, destination: String, rate: Decimal, effectiveDate: Date?) {
        self.source = source.uppercased()
        self.destination = destination.uppercased()
        self.rate = rate
        self.effectiveDate = effectiveDate
    }
}

public struct ExchangeRateLookupResult: Sendable, Equatable {
    public let rate: Decimal
    public let effectiveDate: Date?
    public let hops: Int
    public let path: [String]

    public init(rate: Decimal, effectiveDate: Date?, hops: Int, path: [String]) {
        self.rate = rate
        self.effectiveDate = effectiveDate
        self.hops = hops
        self.path = path
    }
}

public final class ExchangeRateRepository: BaseRepository, @unchecked Sendable {
    private static let pivotCurrency = "USD"

    public static func resolve(
        from rawFrom: String,
        to rawTo: String,
        rates: [ExchangeRateRecord]
    ) -> ExchangeRateLookupResult? {
        let from = rawFrom.uppercased()
        let to = rawTo.uppercased()
        guard from != to else {
            return ExchangeRateLookupResult(rate: Decimal(1), effectiveDate: nil, hops: 0, path: [to])
        }

        if let directOrReverse = oneHopRate(from: from, to: to, rates: rates) {
            return directOrReverse
        }

        guard from != pivotCurrency, to != pivotCurrency,
              let first = oneHopRate(from: from, to: pivotCurrency, rates: rates),
              let second = oneHopRate(from: pivotCurrency, to: to, rates: rates)
        else { return nil }

        return ExchangeRateLookupResult(
            rate: first.rate * second.rate,
            effectiveDate: oldest(first.effectiveDate, second.effectiveDate),
            hops: 2,
            path: [from, pivotCurrency, to]
        )
    }

    private static func oneHopRate(
        from: String,
        to: String,
        rates: [ExchangeRateRecord]
    ) -> ExchangeRateLookupResult? {
        if let direct = latestRate(source: from, destination: to, rates: rates) {
            return ExchangeRateLookupResult(rate: direct.rate, effectiveDate: direct.effectiveDate, hops: 1, path: [from, to])
        }

        if let reverse = latestRate(source: to, destination: from, rates: rates), reverse.rate != Decimal(0) {
            return ExchangeRateLookupResult(rate: Decimal(1) / reverse.rate, effectiveDate: reverse.effectiveDate, hops: 1, path: [from, to])
        }

        return nil
    }

    private static func latestRate(
        source: String,
        destination: String,
        rates: [ExchangeRateRecord]
    ) -> ExchangeRateRecord? {
        rates
            .filter { $0.source == source && $0.destination == destination && $0.rate != Decimal(0) }
            .sorted { lhs, rhs in
                switch (lhs.effectiveDate, rhs.effectiveDate) {
                case let (l?, r?): return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return false
                }
            }
            .first
    }

    private static func oldest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (l?, r?): return min(l, r)
        case let (l?, nil): return l
        case let (nil, r?): return r
        case (nil, nil): return nil
        }
    }

    static func currencyCodesByUniqueId(in ctx: NSManagedObjectContext) throws -> [String: String] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Currency")
        let currencies = try ctx.fetch(request)
        let pairs: [(String, String)] = currencies.compactMap { currency in
            guard let uniqueId = currency.value(forKey: "pUniqueID") as? String,
                  let code = currency.value(forKey: "pCode") as? String
            else { return nil }
            return (uniqueId, code.uppercased())
        }
        // Two currency rows can share a unique ID. Keep the alphabetically first
        // code so the answer is the same on every run, and say so.
        return Dictionary(pairs, uniquingKeysWith: { first, second in
            FileHandle.standardError.write(Data("warning: duplicate currency unique ID (\(first), \(second)); using \(min(first, second))\n".utf8))
            return min(first, second)
        })
    }

}
