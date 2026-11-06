// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

/// A read renders `date` in the reader's zone, which is what makes anchor drift
/// invisible: two machines show the same row differently and neither can see the
/// stored value that explains it. `--show-instant` reports that value.
@Suite("Transaction stored instant", .serialized)
struct TransactionInstantTests {

    private func vaultWithOneTransaction() throws -> (vault: TestVaultHelper.TestVault, id: Int) {
        let vault = try TestVaultHelper.createFreshVault()
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)
        let accounts = AccountRepository(container: vault.container)
        let account = try accounts.create(name: "Instants", accountClass: AccountClass.checking, currencyCode: "USD")
        let transactions = TransactionRepository(
            container: vault.container, lineItemRepo: LineItemRepository(container: vault.container)
        )
        let tx = try transactions.create(
            date: "2026-04-10", title: "Anchored",
            lineItems: [(accountId: account.id, amount: -10, memo: nil)]
        )
        return (vault, tx.id)
    }

    @Test("an anchored row reports the anchor, and only when asked")
    func instantIsReportedOnRequest() throws {
        let seeded = try vaultWithOneTransaction()
        defer { TestVaultHelper.cleanup(seeded.vault) }
        let transactions = TransactionRepository(
            container: seeded.vault.container,
            lineItemRepo: LineItemRepository(container: seeded.vault.container)
        )

        let quiet = try #require(try transactions.get(transactionId: seeded.id))
        #expect(quiet.dateInstant == nil)

        let loud = try #require(try transactions.get(transactionId: seeded.id, includeInstant: true))
        // Written through the anchor, so this is exactly 10:00 UTC wherever the
        // suite runs. A row that reads anything else was not written through it.
        #expect(loud.dateInstant == "2026-04-10T10:00:00Z")
        #expect(loud.date == quiet.date)
    }

    @Test("the field is absent from the encoded form unless requested")
    func absentFieldStaysAbsent() throws {
        let seeded = try vaultWithOneTransaction()
        defer { TestVaultHelper.cleanup(seeded.vault) }
        let transactions = TransactionRepository(
            container: seeded.vault.container,
            lineItemRepo: LineItemRepository(container: seeded.vault.container)
        )

        let quiet = try #require(try transactions.get(transactionId: seeded.id))
        let json = try #require(String(data: try JSONEncoder().encode(quiet), encoding: .utf8))
        #expect(!json.contains("dateInstant"))

        let loud = try #require(try transactions.get(transactionId: seeded.id, includeInstant: true))
        let loudJSON = try #require(String(data: try JSONEncoder().encode(loud), encoding: .utf8))
        #expect(loudJSON.contains("dateInstant"))
    }

    @Test("a list reports it too, since drift is found by scanning rows")
    func listReportsTheInstant() throws {
        let seeded = try vaultWithOneTransaction()
        defer { TestVaultHelper.cleanup(seeded.vault) }
        let transactions = TransactionRepository(
            container: seeded.vault.container,
            lineItemRepo: LineItemRepository(container: seeded.vault.container)
        )
        let rows = try transactions.list(includeInstant: true)
        #expect(rows.allSatisfy { $0.dateInstant?.hasSuffix("T10:00:00Z") == true })
        #expect(try transactions.list().allSatisfy { $0.dateInstant == nil })
    }
}
