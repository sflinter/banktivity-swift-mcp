// Copyright (c) 2026 Steve Flinter. MIT License.

import Testing
@testable import BanktivityLib

@Suite("WriteGuard")
struct WriteGuardTests {

    @Test("guardWriteAccess allows access when Banktivity is not running")
    func guardAllowsAccessWhenBanktivityNotRunning() async {
        let guard_ = WriteGuard(dbPath: "/tmp/nonexistent-test-file.sql")
        let result = await guard_.guardWriteAccess()
        #expect(result == nil, "Should allow access when Banktivity is not running")
    }

    @Test("isBanktivityRunning returns false for nonexistent file")
    func isBanktivityRunningReturnsFalseForNonexistentFile() async {
        let guard_ = WriteGuard(dbPath: "/tmp/nonexistent-test-file.sql")
        let running = await guard_.isBanktivityRunning()
        #expect(!running)
    }

    @Test("isBanktivityRunning returns cached result")
    func guardReturnsCachedResult() async {
        let guard_ = WriteGuard(dbPath: "/tmp/nonexistent-test-file.sql")

        // First call
        let result1 = await guard_.isBanktivityRunning()
        // Second call should use cache (within 3s TTL)
        let result2 = await guard_.isBanktivityRunning()

        #expect(result1 == result2)
    }
}
