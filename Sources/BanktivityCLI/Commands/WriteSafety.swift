// Copyright (c) 2026 Steve Flinter. MIT License.

import BanktivityLib
import Foundation

/// Shared confirmation gate for destructive or balance-affecting writes.
///
/// Both line-item writes and security-record deletion require the operator to
/// state that they reviewed the target and that they will verify the result in
/// the Banktivity UI. Keeping one implementation means the policy cannot drift
/// between call sites.
func requireReviewedWriteConfirmations(
    subject: String,
    target: String,
    operatorReviewedTarget: Bool,
    postUIVerificationRequired: Bool
) throws {
    guard operatorReviewedTarget else {
        throw ToolError.invalidInput("\(subject) require --operator-reviewed-target after reviewing the target \(target).")
    }
    guard postUIVerificationRequired else {
        throw ToolError.invalidInput("\(subject) require --post-ui-verification-required because balances and statement membership must be checked in Banktivity UI after writing.")
    }
}
