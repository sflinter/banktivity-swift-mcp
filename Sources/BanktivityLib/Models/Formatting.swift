// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

/// Format currency for display
public func formatCurrency(_ amount: Double, currency: String = "EUR") -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currency
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.usesGroupingSeparator = true
    formatter.groupingSeparator = ","
    formatter.currencyGroupingSeparator = ","
    formatter.decimalSeparator = "."
    formatter.currencyDecimalSeparator = "."
    return formatter.string(from: NSNumber(value: amount)) ?? "\(amount)"
}
