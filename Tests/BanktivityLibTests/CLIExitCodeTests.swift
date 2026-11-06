// Copyright (c) 2026 Steve Flinter. MIT License.

import Testing
@testable import BanktivityLib

@Suite("CLIExitCodes")
struct CLIExitCodeTests {
    @Test("tool errors map to explicit CLI exit categories")
    func toolErrorsMapToExplicitCLIExitCategories() {
        #expect(ToolError.missingParameter("missing").cliExitCategory == .usageInput)
        #expect(ToolError.invalidInput("invalid").cliExitCategory == .validationFailed)
        #expect(ToolError.notFound("missing row").cliExitCategory == .notFound)
        #expect(ToolError.writeBlocked("blocked").cliExitCategory == .writeBlocked)
    }

    @Test("CLI exit category codes are stable")
    func cliExitCategoryCodesAreStable() {
        #expect(CLIExitCategory.usageInput.exitCode == 64)
        #expect(CLIExitCategory.validationFailed.exitCode == 65)
        #expect(CLIExitCategory.notFound.exitCode == 66)
        #expect(CLIExitCategory.runtimeStoreFailure.exitCode == 70)
        #expect(CLIExitCategory.writeBlocked.exitCode == 77)
    }

    @Test("repository errors map to runtime store failure")
    func repositoryErrorsMapToRuntimeStoreFailure() {
        #expect(RepositoryError.unexpectedNilResult.cliExitCategory == .runtimeStoreFailure)
    }
}
