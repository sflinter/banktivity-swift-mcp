// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import Testing
@testable import BanktivityLib

struct AccountRepositoryBalanceTests {
    @Test func lineItemAccountAmountUsesExchangeRate() {
        let amount = AccountRepository.accountAmount(
            transactionAmount: NSDecimalNumber(string: "100.00"),
            exchangeRate: NSDecimalNumber(string: "10.0")
        )

        #expect(amount == Decimal(1000))
    }

    @Test func lineItemAccountAmountTreatsZeroExchangeRateAsOne() {
        let amount = AccountRepository.accountAmount(
            transactionAmount: NSDecimalNumber(string: "42.50"),
            exchangeRate: NSDecimalNumber.zero
        )

        #expect(amount == Decimal(string: "42.50")!)
    }

    @Test func lineItemAccountAmountIsUnchangedForExchangeRateOne() {
        let amount = AccountRepository.accountAmount(
            transactionAmount: NSDecimalNumber(string: "12.34"),
            exchangeRate: NSDecimalNumber.one
        )

        #expect(amount == Decimal(string: "12.34")!)
    }
}
