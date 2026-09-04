// Copyright (c) 2026 Steve Flinter. MIT License.

import Testing
@testable import BanktivityLib

@Suite("CapabilityRegistry")
struct CapabilityRegistryTests {
    @Test("capability report exposes write mode and safety metadata")
    func capabilityReportExposesWriteMetadata() throws {
        let report = CapabilityRegistry.report()
        #expect(report.schemaVersion == 1)
        #expect(!report.commands.isEmpty)
        #expect(!report.tools.isEmpty)

        let transactionCreate = try #require(report.commands.first { $0.name == "transactions create" })
        #expect(transactionCreate.access == .write)
        #expect(transactionCreate.requiresWriteMode)
        #expect(!transactionCreate.supportsDryRun)

        let bulkRecategorize = try #require(report.tools.first { $0.name == "bulk_recategorize_by_payee" })
        #expect(bulkRecategorize.supportsDryRun)

        let lineItemUpdate = try #require(report.tools.first { $0.name == "update_line_item" })
        #expect(lineItemUpdate.requiredConfirmations.contains("operator_reviewed_target"))
        #expect(lineItemUpdate.uiVerificationRequired)
        #expect(lineItemUpdate.notes.contains { $0.contains("Line-item writes affect balances") })

        let capabilitiesTool = try #require(report.tools.first { $0.name == "get_capabilities" })
        #expect(capabilitiesTool.access == .read)
        #expect(!capabilitiesTool.requiresWriteMode)
    }
}
