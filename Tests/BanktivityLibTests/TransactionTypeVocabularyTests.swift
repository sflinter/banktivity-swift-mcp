// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

/// There are two transaction-type vocabularies here and they are not the same one.
///
/// `--transaction-type` takes a kebab-case slug. The sync blob's `baseType` field
/// takes a value from `IGGCSyncAccountingTransactionBaseType`. They agree on most
/// values and disagree on three, so deriving either from the other writes a sync
/// record that contradicts the row it is attached to.
@Suite("Transaction type vocabularies", .serialized)
struct TransactionTypeVocabularyTests {

    // MARK: - What the CLI accepts

    @Test("the advertised set and the accepted set are the same set")
    func advertisedMatchesAccepted() {
        for slug in TransactionRepository.transactionTypeNames.split(separator: ", ") {
            #expect(
                TransactionRepository.transactionTypeBaseTypeCode(String(slug)) != nil,
                "advertised \(slug) but it is not accepted"
            )
        }
        for slug in TransactionRepository.transactionTypeBaseTypes.keys {
            #expect(
                TransactionRepository.transactionTypeNames.contains(slug),
                "accepts \(slug) but does not advertise it"
            )
        }
    }

    /// Both were previously advertised and neither was ever accepted. A consumer
    /// read that list and planned around a limitation that did not exist.
    @Test("the two slugs that were advertised but never accepted are gone",
          arguments: ["short-sell", "buy-to-cover"])
    func retiredSlugsAreNotAdvertised(slug: String) {
        #expect(!TransactionRepository.transactionTypeNames.contains(slug))
        #expect(TransactionRepository.transactionTypeBaseTypeCode(slug) == nil)
    }

    /// A spin-off apportions basis by releasing it through Return of Capital and
    /// spending it on the child. Without 310 the second leg cannot be written.
    @Test("the income and corporate-action types are reachable",
          arguments: [("investment-income", 300), ("cap-gains-short", 302),
                      ("cap-gains-long", 303), ("interest-income", 304),
                      ("return-of-capital", 310)])
    func incomeTypesAreAccepted(slug: String, code: Int) {
        #expect(TransactionRepository.transactionTypeBaseTypeCode(slug) == code)
    }

    // MARK: - What goes on the wire

    /// Two of these are misspelled and both are load-bearing: they are the enum's
    /// own spellings, and a corrected one is a value the enum does not contain.
    @Test("the sync enum keeps Banktivity's spelling, typos included",
          arguments: [(Int16(250), "slpit-shares"), (Int16(300), "misc-inv-income"),
                      (Int16(304), "intrest-income"), (Int16(301), "dividend"),
                      (Int16(302), "cap-gains-short"), (Int16(303), "cap-gains-long"),
                      (Int16(310), "return-of-capital"), (Int16(2), "withdrawal")])
    func syncEnumSpelling(baseType: Int16, expected: String) {
        #expect(SyncBlobUpdater.syncBaseTypeName(for: baseType) == expected)
    }

    /// This is the defect in one assertion: the CLI slug is not the wire value for
    /// these three, so a sync record derived from the slug describes the wrong type.
    @Test("the CLI slug is not the sync value for the three that differ",
          arguments: [("split-shares", 250), ("investment-income", 300), ("interest-income", 304)])
    func theVocabulariesDifferWhereTheyDiffer(slug: String, code: Int) {
        #expect(TransactionRepository.transactionTypeBaseTypeCode(slug) == code)
        #expect(SyncBlobUpdater.syncBaseTypeName(for: Int16(code)) != slug)
    }

    @Test("a base type the enum cannot name writes no record rather than a guess")
    func unknownBaseTypeWritesNothing() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let (usd, _) = try TestVaultHelper.seedCurrencies(in: vault.container)

        let txUUID = UUID().uuidString
        SyncBlobUpdater(container: vault.container).createTransactionSyncRecord(
            transactionUUID: txUUID,
            currencyUUID: BaseRepository.stringValue(usd, "pUniqueID"),
            date: "2026-03-01", title: "Unnameable", note: nil, adjustment: false,
            lineItems: [SyncBlobUpdater.SyncLineItem(
                accountUUID: UUID().uuidString, accountAmount: 1, cleared: false,
                identifier: UUID().uuidString, memo: nil, securityLineItem: nil,
                transactionAmount: 1
            )],
            transactionTypeBaseTypeCode: 999, transactionTypeUUID: UUID().uuidString
        )

        let request = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        request.predicate = NSPredicate(format: "pLocalID == %@", txUUID)
        #expect(try vault.container.viewContext.fetch(request).isEmpty)
    }

    // MARK: - The write path that got it wrong

    /// `create` switched over base types 0 and 1 and fell through to `deposit`, so
    /// a withdrawal described itself as a deposit in its own sync record.
    @Test("a withdrawal is described to sync as a withdrawal")
    func createDescribesTheTypeItWasGiven() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)

        let ctx = vault.container.viewContext
        let type = NSEntityDescription.insertNewObject(forEntityName: "TransactionType", into: ctx)
        type.setValue(Int16(2), forKey: "pBaseType")
        type.setValue("Withdrawal", forKey: "pName")
        type.setValue(UUID().uuidString, forKey: "pUniqueID")
        type.setValue(Date(), forKey: "pCreationTime")
        type.setValue(Date(), forKey: "pModificationDate")
        try ctx.save()

        let accounts = AccountRepository(container: vault.container)
        let account = try accounts.create(name: "Chequing", accountClass: AccountClass.checking, currencyCode: "USD")
        let lineItems = LineItemRepository(container: vault.container)
        let transactions = TransactionRepository(
            container: vault.container, lineItemRepo: lineItems,
            syncBlobUpdater: SyncBlobUpdater(container: vault.container)
        )
        // `create` assigns the first transaction type it finds, and this vault has
        // exactly one, so the row is a Withdrawal. Before the fix its sync record
        // said `deposit` anyway.
        let created = try transactions.create(
            date: "2026-04-10", title: "Rent",
            lineItems: [(accountId: account.id, amount: -1200, memo: nil)]
        )

        let rows = try ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: "Transaction"))
        let row = try #require(rows.first { BaseRepository.extractPK(from: $0.objectID) == created.id })
        let uuid = BaseRepository.stringValue(row, "pUniqueID")

        let request = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        request.predicate = NSPredicate(format: "pLocalID == %@", uuid)
        let record = try #require(try ctx.fetch(request).first)
        let blob = try #require(record.value(forKey: "pRemoteEntityData") as? Data)
        let decompressed = try #require(SyncBlobUpdater.decompressGzip(blob))
        let xml = try #require(String(data: decompressed, encoding: .utf8))

        #expect(xml.contains("name=\"baseType\">withdrawal</field>"))
        #expect(!xml.contains("name=\"baseType\">deposit</field>"))
    }

    // MARK: - The primitive that could not name its type

    /// `createShareAdjustment` chose Buy or Sell by the sign of `shares` and had
    /// no way to say anything else, so a split could not be written in its own
    /// shape through the only primitive that moves shares. The sync value for 250
    /// is `slpit-shares`, which is the enum's spelling, not the CLI's.
    @Test("a share movement is written and synced as the type it was given")
    func shareMovementNamesItsType() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedSyncedDocument(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)

        let ctx = vault.container.viewContext
        for (code, name) in [(Int16(100), "Buy"), (Int16(101), "Sell"), (Int16(250), "Split Shares")] {
            let type = NSEntityDescription.insertNewObject(forEntityName: "TransactionType", into: ctx)
            type.setValue(code, forKey: "pBaseType")
            type.setValue(name, forKey: "pName")
            type.setValue(BaseRepository.generateUUID(), forKey: "pUniqueID")
            type.setValue(Date(), forKey: "pCreationTime")
            type.setValue(Date(), forKey: "pModificationDate")
        }
        try ctx.save()

        let repo = SecurityRepository(
            container: vault.container, syncBlobUpdater: SyncBlobUpdater(container: vault.container)
        )
        let split = try repo.createShareAdjustment(
            accountId: BaseRepository.extractPK(from: account.objectID),
            symbol: BaseRepository.stringValue(security, "pSymbol"),
            shares: 10, date: "2026-02-02", transactionType: "split-shares"
        )

        let rows = try ctx.fetch(NSFetchRequest<NSManagedObject>(entityName: "Transaction"))
        let row = try #require(rows.first { BaseRepository.extractPK(from: $0.objectID) == split.id })
        let type = try #require(BaseRepository.relatedObject(row, "pTransactionType"))
        #expect(BaseRepository.intValue(type, "pBaseType") == 250)

        let request = NSFetchRequest<NSManagedObject>(entityName: "SyncedHostedEntity")
        request.predicate = NSPredicate(format: "pLocalID == %@", BaseRepository.stringValue(row, "pUniqueID"))
        let record = try #require(try ctx.fetch(request).first)
        let blob = try #require(record.value(forKey: "pRemoteEntityData") as? Data)
        let decompressed = try #require(SyncBlobUpdater.decompressGzip(blob))
        let xml = try #require(String(data: decompressed, encoding: .utf8))
        #expect(xml.contains("name=\"baseType\">slpit-shares</field>"))
    }

    @Test("an unknown movement type is refused rather than silently becoming a buy")
    func unknownMovementTypeIsRefused() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let security = try TestVaultHelper.seedSecurity(in: vault.container, currency: eur)

        let repo = SecurityRepository(container: vault.container)
        #expect(throws: ToolError.self) {
            _ = try repo.createShareAdjustment(
                accountId: BaseRepository.extractPK(from: account.objectID),
                symbol: BaseRepository.stringValue(security, "pSymbol"),
                shares: 1, date: "2026-02-02", transactionType: "reverse-split"
            )
        }
    }

    /// The base type is read from the store, so the conversion to `Int16` has to
    /// be total: a trapping initialiser would turn unreadable data into a crash.
    /// 0 is not a base type, so it resolves to no name and the record is skipped.
    @Test("a base type outside the enum resolves to no name rather than trapping")
    func outOfRangeBaseTypeHasNoName() {
        #expect(SyncBlobUpdater.syncBaseTypeName(for: 0) == nil)
        #expect(SyncBlobUpdater.syncBaseTypeName(for: Int16.max) == nil)
        #expect(SyncBlobUpdater.syncBaseTypeName(for: -1) == nil)
    }
}
