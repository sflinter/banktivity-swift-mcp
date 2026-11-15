// Copyright (c) 2026 Steve Flinter. MIT License.

import Testing
@testable import BanktivityMCPLib
import MCP

@Suite("MCP integer arguments")
struct ToolHelpersTests {

    @Test("getInt rejects fractional and out-of-range doubles instead of truncating or trapping")
    func getIntRejectsNonIntegers() {
        #expect(ToolHelpers.getInt(["n": .double(1.5)], key: "n") == nil)
        #expect(ToolHelpers.getInt(["n": .double(.nan)], key: "n") == nil)
        #expect(ToolHelpers.getInt(["n": .double(1e300)], key: "n") == nil)
        #expect(ToolHelpers.getInt(["n": .double(3.0)], key: "n") == 3)
        #expect(ToolHelpers.getInt(["n": .int(7)], key: "n") == 7)
    }

    @Test("intList is all-or-nothing")
    func intListIsAllOrNothing() {
        #expect(ToolHelpers.intList([.int(1), .double(2.5)]) == nil)
        #expect(ToolHelpers.intList([.int(1), .string("2")]) == nil)
        #expect(ToolHelpers.intList([.int(1), .double(.infinity)]) == nil)
        #expect(ToolHelpers.intList([.int(1), .double(2.0)]) == [1, 2])
    }
}
