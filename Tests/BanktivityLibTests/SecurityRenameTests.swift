// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing

@testable import BanktivityLib

/// `securities rename` -- what it changes, and what it refuses.
///
/// `.serialized` because each test stands up its own Core Data stack, and several of
/// those running concurrently crashes the test process.
@Suite("Security rename", .serialized)
struct SecurityRenameTests {

    private struct Fixture {
        let vault: TestVaultHelper.TestVault
        let repo: SecurityRepository
    }

    private func makeFixture(symbols: [String] = ["OLD"]) throws -> Fixture {
        let vault = try TestVaultHelper.createFreshVault()
        let (usd, _) = try TestVaultHelper.seedCurrencies(in: vault.container)
        for symbol in symbols {
            _ = try TestVaultHelper.seedSecurity(
                in: vault.container, symbol: symbol, currency: usd)
        }
        return Fixture(vault: vault, repo: SecurityRepository(container: vault.container))
    }

    private func symbolOf(_ fixture: Fixture, name: String) throws -> String? {
        try fixture.repo.listSecurities().first { $0.name == name }?.symbol
    }

    // MARK: - What it changes

    @Test("Renames the ticker, and the read back reports it")
    func renamesTheTicker() throws {
        let fixture = try makeFixture()
        defer { TestVaultHelper.cleanup(fixture.vault) }

        let result = try fixture.repo.renameSecurity(symbol: "OLD", newSymbol: "NEW")
        #expect(result.symbol == "NEW")
        #expect(try fixture.repo.listSecurities().contains { $0.symbol == "NEW" })
        #expect(try !fixture.repo.listSecurities().contains { $0.symbol == "OLD" })
    }

    @Test("Renames the display name without touching the ticker")
    func renamesTheName() throws {
        let fixture = try makeFixture()
        defer { TestVaultHelper.cleanup(fixture.vault) }

        let result = try fixture.repo.renameSecurity(symbol: "OLD", newName: "Renamed Holding")
        #expect(result.name == "Renamed Holding")
        #expect(result.symbol == "OLD", "a name change must not move the ticker")
    }

    @Test("Finds the security by id as well as by symbol")
    func findsById() throws {
        let fixture = try makeFixture()
        defer { TestVaultHelper.cleanup(fixture.vault) }

        let id = try #require(try fixture.repo.listSecurities().first?.id)
        let result = try fixture.repo.renameSecurity(id: id, newSymbol: "BYID")
        #expect(result.symbol == "BYID")
    }

    // MARK: - What it refuses

    @Test("Refuses a ticker another security already holds")
    func refusesADuplicateTicker() throws {
        // Two securities sharing a ticker cannot be told apart by any reader
        // downstream. That is a merge, and a merge needs different evidence.
        let fixture = try makeFixture(symbols: ["OLD", "TAKEN"])
        defer { TestVaultHelper.cleanup(fixture.vault) }

        #expect(throws: (any Error).self) {
            try fixture.repo.renameSecurity(symbol: "OLD", newSymbol: "TAKEN")
        }
        #expect(try fixture.repo.listSecurities().contains { $0.symbol == "OLD" },
                "a refused rename must leave the original ticker in place")
    }

    @Test("Refuses to blank an identity")
    func refusesBlankValues() throws {
        // A security with no symbol is one of the defects rename exists to repair,
        // so an empty new value is a mistake rather than an instruction.
        let fixture = try makeFixture()
        defer { TestVaultHelper.cleanup(fixture.vault) }

        #expect(throws: (any Error).self) {
            try fixture.repo.renameSecurity(symbol: "OLD", newSymbol: "   ")
        }
        #expect(throws: (any Error).self) {
            try fixture.repo.renameSecurity(symbol: "OLD", newName: "")
        }
        #expect(try fixture.repo.listSecurities().first?.symbol == "OLD")
    }

    @Test("Refuses a call that asks for no change at all")
    func refusesNoOp() throws {
        let fixture = try makeFixture()
        defer { TestVaultHelper.cleanup(fixture.vault) }

        #expect(throws: (any Error).self) {
            try fixture.repo.renameSecurity(symbol: "OLD")
        }
    }

    @Test("Refuses a security that is not there")
    func refusesMissingSecurity() throws {
        let fixture = try makeFixture()
        defer { TestVaultHelper.cleanup(fixture.vault) }

        #expect(throws: (any Error).self) {
            try fixture.repo.renameSecurity(symbol: "NOSUCH", newSymbol: "NEW")
        }
        #expect(throws: (any Error).self) {
            try fixture.repo.renameSecurity(id: 999_999, newSymbol: "NEW")
        }
    }

    @Test("Renaming to its own ticker is allowed, and is not a clash with itself")
    func sameTickerIsNotAClash() throws {
        // The duplicate check walks every security carrying the new symbol; without
        // the objectID comparison the security would collide with itself.
        let fixture = try makeFixture()
        defer { TestVaultHelper.cleanup(fixture.vault) }

        let result = try fixture.repo.renameSecurity(
            symbol: "OLD", newSymbol: "OLD", newName: "Still Here")
        #expect(result.symbol == "OLD")
        #expect(result.name == "Still Here")
    }
}
