// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

public struct WriteValidationDTO: Codable, Sendable {
    public let operation: String
    public let wouldWrite: Bool
    public let requiresWriteMode: Bool
    public let requiredConfirmations: [String]
    public let uiVerificationRequired: Bool
    public let targetIds: [String: Int]
    public let warnings: [String]

    public init(
        operation: String,
        wouldWrite: Bool,
        requiresWriteMode: Bool = true,
        requiredConfirmations: [String],
        uiVerificationRequired: Bool,
        targetIds: [String: Int],
        warnings: [String]
    ) {
        self.operation = operation
        self.wouldWrite = wouldWrite
        self.requiresWriteMode = requiresWriteMode
        self.requiredConfirmations = requiredConfirmations
        self.uiVerificationRequired = uiVerificationRequired
        self.targetIds = targetIds
        self.warnings = warnings
    }
}
