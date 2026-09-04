// Copyright (c) 2026 Steve Flinter. MIT License.

import CoreData
import Foundation
import Testing
@testable import BanktivityLib
@testable import BanktivityMCPLib

/// What a registered tool actually is, against what the capability report says it is.
///
/// `mcpCapabilities()` is a hand-written literal array and `registerAllTools()` is
/// imperative registration, so the two drifted in both directions with nothing to
/// notice: names were advertised that no tool implemented, and tools were reachable
/// over stdio that the report never mentioned -- several of them writes.
///
/// The existing `CapabilityRegistryTests` could not catch either, because it
/// asserted a count and spot-checked names. A count says something moved; it never
/// says what, and it passes happily while a phantom name sits in the list.
@Suite("MCP tool registration drift", .serialized)
struct MCPToolRegistrationDriftTests {

    private func makeRegistry() throws -> (ToolRegistry, TestVaultHelper.TestVault) {
        let vault = try TestVaultHelper.createFreshVault()
        let registry = ToolRegistry(
            container: vault.container,
            writeGuard: WriteGuard(dbPath: vault.path),
            bankFilePath: vault.path
        )
        registry.registerAllTools()
        return (registry, vault)
    }

    @Test("every registered tool is declared, and every declared tool is registered")
    func registrationAndDeclarationAgree() throws {
        let (registry, vault) = try makeRegistry()
        defer { TestVaultHelper.cleanup(vault) }

        let registered = registry.registeredToolAccess()
        let declared = Dictionary(
            uniqueKeysWithValues: CapabilityRegistry.mcpCapabilities().map { ($0.name, $0.access) }
        )

        let undeclared = Set(registered.keys).subtracting(declared.keys).sorted()
        let unregistered = Set(declared.keys).subtracting(registered.keys).sorted()

        #expect(undeclared.isEmpty, "registered but never declared: \(undeclared)")
        #expect(unregistered.isEmpty, "declared but never registered: \(unregistered)")
    }

    @Test("a tool's declared access matches the access it is registered under")
    func declaredAccessMatchesRegisteredAccess() throws {
        let (registry, vault) = try makeRegistry()
        defer { TestVaultHelper.cleanup(vault) }

        let registered = registry.registeredToolAccess()
        let declared = Dictionary(
            uniqueKeysWithValues: CapabilityRegistry.mcpCapabilities().map { ($0.name, $0.access) }
        )

        // The dangerous direction is declared-read / registered-write: the read-only
        // proxy builds its allowlist from the declaration, so a write advertised as
        // a read is a write let through the transport.
        let disagreements = registered
            .compactMap { name, access -> String? in
                guard let expected = declared[name], expected != access else { return nil }
                return "\(name): registered \(access.rawValue), declared \(expected.rawValue)"
            }
            .sorted()

        #expect(disagreements.isEmpty, "\(disagreements)")
    }

    @Test("requiresWriteMode is never at odds with access")
    func requiresWriteModeFollowsAccess() {
        for capability in CapabilityRegistry.report().commands + CapabilityRegistry.report().tools {
            #expect(
                capability.requiresWriteMode == (capability.access == .write),
                "\(capability.name) declares access \(capability.access.rawValue) with requiresWriteMode \(capability.requiresWriteMode)"
            )
        }
    }

    @Test("a declared dry-run is a dry-run the tool actually accepts")
    func declaredDryRunMatchesToolSchema() throws {
        let (registry, vault) = try makeRegistry()
        defer { TestVaultHelper.cleanup(vault) }

        // supportsDryRun is a promise a caller plans around: an agent told a write
        // previews first will run it expecting nothing to change. Three line-item
        // tools advertised it while accepting no such argument.
        let acceptsDryRun = Set(
            registry.listTools()
                .filter { tool in
                    guard case let .object(schema) = tool.inputSchema,
                          case let .object(properties)? = schema["properties"] else { return false }
                    return properties["dry_run"] != nil
                }
                .map { $0.name }
        )
        let declaresDryRun = Set(
            CapabilityRegistry.mcpCapabilities().filter(\.supportsDryRun).map { $0.name }
        )

        #expect(
            declaresDryRun.subtracting(acceptsDryRun).isEmpty,
            "declares dry-run but takes no dry_run argument: \(declaresDryRun.subtracting(acceptsDryRun).sorted())"
        )
        #expect(
            acceptsDryRun.subtracting(declaresDryRun).isEmpty,
            "takes dry_run but never declares it: \(acceptsDryRun.subtracting(declaresDryRun).sorted())"
        )
    }
}
