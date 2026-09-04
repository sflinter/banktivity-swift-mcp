// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib

/// A write is refused because of what it touches, not because of how it was reached.
///
/// Before this, every decision about whether a write may proceed lived either in a
/// shell wrapper or in a per-verb `guardWrite` call, so any route that was neither
/// -- a nested command, a second entrance, a verb nobody annotated -- was unguarded
/// by construction. `reconciliation execute-bundle` is the live example: it never
/// calls `guardWrite` and relies on the command it re-parses to do it.
///
/// `WriteGuardTests` has three tests and all three assert the *allowing* path, so
/// nothing in this suite ever checked that the guard blocks anything.
@Suite("Vault write gate", .serialized)
struct VaultWriteGateTests {

    private struct StubProbe: VaultHolderProbe {
        let result: VaultHolderStatus
        func status(forStorePath path: String) -> VaultHolderStatus { result }
    }

    private func withGate(_ status: VaultHolderStatus, _ body: () throws -> Void) rethrows {
        let monitor = VaultHolderMonitor(dbPath: "/nonexistent.sql", probe: StubProbe(result: status))
        VaultWriteGate.install(monitor.writeRefusal)
        defer { VaultWriteGate.uninstall() }
        try body()
    }

    @Test("an undetermined probe refuses the write rather than allowing it")
    func undeterminedProbeFailsClosed() {
        let monitor = VaultHolderMonitor(
            dbPath: "/nonexistent.sql",
            probe: StubProbe(result: .undetermined(reason: "lsof could not be run"))
        )
        let refusal = monitor.writeRefusal()

        // The whole point of the tri-state. Every failure used to return false,
        // meaning "clear to write", so a guard that could not answer allowed the
        // write it existed to prevent.
        #expect(refusal != nil)
        #expect(refusal?.contains("Cannot determine") == true)
    }

    @Test("a clear probe permits the write")
    func clearProbeAllows() {
        let monitor = VaultHolderMonitor(dbPath: "/nonexistent.sql", probe: StubProbe(result: .clear))
        #expect(monitor.writeRefusal() == nil)
    }

    @Test("a held vault refuses the write and names the holder condition")
    func heldVaultRefuses() {
        let monitor = VaultHolderMonitor(
            dbPath: "/nonexistent.sql",
            probe: StubProbe(result: .heldByBanktivity(details: "Banktivity 12345"))
        )
        #expect(monitor.writeRefusal()?.contains("Banktivity is currently open") == true)
    }

    @Test("a real repository write is refused at the choke point, with no per-verb guard involved")
    func repositoryWriteIsRefusedAtTheChokePoint() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        let account = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)
        let accountPK = BaseRepository.extractPK(from: account.objectID)

        try withGate(.heldByBanktivity(details: "Banktivity 999")) {
            let categories = CategoryRepository(container: vault.container)
            // `createCategory` never consults a WriteGuard itself. Under the old
            // arrangement that made it unguarded; now the refusal comes from the
            // write it performs.
            #expect(throws: (any Error).self) {
                _ = try categories.create(name: "Blocked While Held", type: "expense")
            }
            _ = accountPK
        }
    }

    @Test("reads are unaffected while the gate refuses writes")
    func readsStillWorkWhileWritesAreRefused() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }

        let (_, eur) = try TestVaultHelper.seedCurrencies(in: vault.container)
        _ = try TestVaultHelper.seedInvestmentAccount(in: vault.container, currency: eur)

        try withGate(.heldByBanktivity(details: "Banktivity 999")) {
            // A blanket refusal that also stopped reads would make the guard
            // unusable: the read-only MCP route exists to run while the app is open.
            let accounts = AccountRepository(container: vault.container)
            let listed = try accounts.list()
            #expect(!listed.isEmpty)
        }
    }

    @Test("with no gate installed a write proceeds, and that is the residual hole")
    func withoutAGateWritesProceed() throws {
        let vault = try TestVaultHelper.createFreshVault()
        defer { TestVaultHelper.cleanup(vault) }
        _ = try TestVaultHelper.seedCurrencies(in: vault.container)

        VaultWriteGate.uninstall()
        #expect(VaultWriteGate.isInstalled == false)

        // Documented rather than asserted away. The default has to be permissive
        // for an embeddable library, which means this gate can still be forgotten
        // -- the half of backlog item 31 that a vault handle threaded through
        // repository construction would close.
        let categories = CategoryRepository(container: vault.container)
        _ = try categories.create(name: "Allowed With No Gate", type: "expense")
    }
}
