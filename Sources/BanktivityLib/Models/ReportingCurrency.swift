// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

/// Runtime reporting currency configuration for aggregate values.
public enum ReportingCurrency {
    public static let defaultCode = "EUR"

    /// Normalize and validate an optional ISO 4217 currency code.
    /// Unknown or empty values fall back to the current default, EUR.
    public static func resolve(_ rawValue: String?) -> String {
        guard let rawValue else { return defaultCode }

        let code = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else { return defaultCode }

        if Locale.commonISOCurrencyCodes.contains(code) {
            return code
        }

        return defaultCode
    }
}
