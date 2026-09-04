// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation
import Testing
@testable import BanktivityLib

/// The CLI half of the capability report, checked against the CLI itself.
///
/// `MCPToolRegistrationDriftTests` does this for the MCP surface by asking the
/// registry what it registered. There is no equivalent to ask here: the command
/// tree lives in the `banktivity-cli` executable, which a test target cannot
/// import. So this asks the binary, the same way a user would -- by reading
/// `--help` -- and compares that against `CapabilityRegistry.cliCapabilities()`.
///
/// The report is meant to be trusted by a caller deciding what is safe to run
/// unattended. A command it omits is a command such a caller believes does not
/// exist; a command it invents is one that caller will try to run.
@Suite("CLI capability drift", .serialized)
struct CLICapabilityDriftTests {

    /// The built CLI, or nil when this configuration did not build it.
    ///
    /// `swift test` alone does not necessarily produce the executable, so its
    /// absence is "not checkable here", not "broken". The test is skipped rather
    /// than failed; `make test` builds the product first and does run it.
    private static func cliURL() -> URL? {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        #if DEBUG
        let expectedBuildDirectory = "/debug/"
        #else
        let expectedBuildDirectory = "/release/"
        #endif
        guard let enumerator = FileManager.default.enumerator(
            at: packageRoot.appendingPathComponent(".build"),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let candidate as URL in enumerator
        where candidate.lastPathComponent == "banktivity-cli"
            && candidate.path.contains(expectedBuildDirectory)
            && !candidate.path.contains(".dSYM/") {
            if (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return candidate
            }
        }
        return nil
    }

    private func help(_ binary: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = binary
        process.arguments = arguments + ["--help"]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Names listed under SUBCOMMANDS, which are indented exactly two spaces.
    /// A wrapped description line is indented far further, so matching on the
    /// exact indent keeps continuation text from being read as a command.
    private func subcommands(_ binary: URL, _ path: [String]) throws -> [String] {
        let text = try help(binary, path)
        guard let range = text.range(of: "SUBCOMMANDS:\n") else { return [] }
        var names: [String] = []
        for line in text[range.upperBound...].components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            guard line.hasPrefix("  "), !line.hasPrefix("   ") else { continue }
            let name = line.dropFirst(2).prefix { !$0.isWhitespace }
            if !name.isEmpty, name != "See" { names.append(String(name)) }
        }
        return names
    }

    @Test("every CLI command is declared, and every declared command exists", .enabled(if: cliURL() != nil))
    func cliRegistrationAndDeclarationAgree() throws {
        let binary = try #require(Self.cliURL())

        var real: Set<String> = []
        for group in try subcommands(binary, []) {
            let leaves = try subcommands(binary, [group])
            if leaves.isEmpty {
                real.insert(group)
            } else {
                for leaf in leaves { real.insert("\(group) \(leaf)") }
            }
        }
        #expect(!real.isEmpty, "could not read any command out of --help")

        let declared = Set(CapabilityRegistry.cliCapabilities().map { $0.name })

        #expect(
            declared.subtracting(real).isEmpty,
            "declared but not a real command: \(declared.subtracting(real).sorted())"
        )
        #expect(
            real.subtracting(declared).isEmpty,
            "real command but never declared: \(real.subtracting(declared).sorted())"
        )
    }
}
