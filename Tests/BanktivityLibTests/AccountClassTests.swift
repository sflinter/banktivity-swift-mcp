// Copyright (c) 2026 Steve Flinter. MIT License.

import Testing
@testable import BanktivityLib

@Suite("AccountClass")
struct AccountClassTests {

    @Test("assetClasses includes all core asset account classes")
    func assetClassesIncludesCoreAssetTypes() {
        #expect(assetClasses.contains(1))
        #expect(assetClasses.contains(2))
        #expect(assetClasses.contains(3))
        #expect(assetClasses.contains(1003))
        #expect(assetClasses.contains(2000))
        #expect(assetClasses.contains(2003))
    }

    @Test("liabilityClasses includes all core liability account classes")
    func liabilityClassesIncludesCoreLiabilityTypes() {
        #expect(liabilityClasses.contains(3000))
        #expect(liabilityClasses.contains(4000))
        #expect(liabilityClasses.contains(5001))
    }

    @Test("accountTypeName returns official Banktivity names")
    func accountTypeNameReturnsOfficialNames() {
        #expect(accountTypeName(for: 1) == "Asset")
        #expect(accountTypeName(for: 1003) == "Money Market")
        #expect(accountTypeName(for: 1006) == "Current")
        #expect(accountTypeName(for: 2003) == "401(k)")
        #expect(accountTypeName(for: 2005) == "College Savings (529)")
        #expect(accountTypeName(for: 4000) == "Loan")
        #expect(accountTypeName(for: 4001) == "Mortgage")
    }

    @Test("accountTypeName falls back for unknown classes")
    func accountTypeNameFallsBackForUnknownClasses() {
        #expect(accountTypeName(for: 9999) == "Unknown (9999)")
    }

    @Test("equityClasses keeps equity separate from assets and liabilities")
    func equityClassesKeepsEquitySeparate() {
        #expect(equityClasses == [8000])
        #expect(!assetClasses.contains(8000))
        #expect(!liabilityClasses.contains(8000))
    }
}
