// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import Testing
@testable import BanktivityLib

struct NetWorthAggregationTests {
    @Test func missingExchangeRateExcludesAccountAndWarns() {
        let result = AccountRepository.aggregateNetWorth(
            reportingCurrency: "KZT",
            accounts: [
                NetWorthAccountBalance(name: "Local Asset", accountClass: AccountClass.cash, currency: "KZT", balance: 100),
                NetWorthAccountBalance(name: "Foreign Asset", accountClass: AccountClass.cash, currency: "GBP", balance: 50),
            ],
            rates: []
        )

        #expect(result.assets == 100)
        #expect(result.netWorth == 100)
        #expect(result.breakdown.byCurrency["GBP"] == nil)
        #expect(result.warnings.contains("Account Foreign Asset (currency GBP) excluded: no exchange rate available"))
    }

    @Test func reportingCurrencyAccountUsesIdentityRateWithoutWarning() {
        let result = AccountRepository.aggregateNetWorth(
            reportingCurrency: "KZT",
            accounts: [
                NetWorthAccountBalance(name: "Local Asset", accountClass: AccountClass.cash, currency: "KZT", balance: 100),
            ],
            rates: []
        )

        #expect(result.assets == 100)
        #expect(result.breakdown.byCurrency["KZT"]?.rate == 1)
        #expect(result.breakdown.byCurrency["KZT"]?.hops == 0)
        #expect(result.warnings.isEmpty)
    }
}
