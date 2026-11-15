// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

/// Core Data entity type constants (Z_ENT values)
public enum ZEntityType {
    public static let account = 1
    public static let category = 2
    public static let primaryAccount = 3
    public static let lineItem = 19
    public static let lineItemTemplate = 21
    public static let payee = 31
    public static let payeeInfo = 33
    public static let recurringTransaction = 35
    public static let tag = 47
    public static let templateSelector = 48
    public static let importSourceTemplateSelector = 49
    public static let scheduledTemplateSelector = 52
    public static let transaction = 53
    public static let transactionTemplate = 54
    public static let transactionType = 55
    public static let syncedHostedEntity = 46
}

/// Maps entity Z_ENT values to sync entity type name strings
public let syncEntityTypeNames: [Int: String] = [
    ZEntityType.account: "Account",
    ZEntityType.category: "Account",
    ZEntityType.primaryAccount: "Account",
    ZEntityType.tag: "Tag",
    ZEntityType.transaction: "Transaction",
    ZEntityType.transactionTemplate: "TransactionTemplate",
    ZEntityType.recurringTransaction: "RecurringTransaction",
]

/// Account class constants from Banktivity's IGGAccounting.framework.
///
/// Source: +[IGGCAccountingAccountBase displayableNameForAccountClass:]
/// for display names and IGGCGetAccountClassInfo for semantic grouping.
public enum AccountClass {
    public static let unknown = 0
    public static let asset = 1
    public static let realEstate = 2
    public static let automobile = 3
    public static let collectible = 4
    public static let artwork = 5
    public static let cash = 1000
    public static let checking = 1001
    public static let savings = 1002
    public static let moneyMarket = 1003
    public static let certificateOfDeposit = 1004
    public static let healthSavingsAccount = 1005
    public static let current = 1006
    public static let investment = 2000
    public static let ira = 2001
    public static let sep = 2002
    public static let fourOhOneK = 2003
    public static let fourOhThreeB = 2004
    public static let collegeSavings529 = 2005
    public static let mutualFund = 2006
    public static let rrsp = 2007
    public static let resp = 2008
    public static let tfsa = 2009
    public static let hsaInvestment = 2010
    public static let liability = 3000
    public static let loan = 4000
    public static let mortgage = 4001
    public static let studentLoan = 4002
    public static let autoLoan = 4003
    public static let revolvingDebt = 5000
    public static let creditCard = 5001
    public static let lineOfCredit = 5002
    public static let heloc = 5003
    public static let income = 6000
    public static let expense = 7000
    public static let equity = 8000
}

/// Asset account classes (positive net worth)
public let assetClasses: Set<Int> = [
    AccountClass.asset, AccountClass.realEstate, AccountClass.automobile,
    AccountClass.collectible, AccountClass.artwork,
    AccountClass.cash, AccountClass.checking, AccountClass.savings,
    AccountClass.moneyMarket, AccountClass.certificateOfDeposit,
    AccountClass.healthSavingsAccount, AccountClass.current,
    AccountClass.investment, AccountClass.ira, AccountClass.sep,
    AccountClass.fourOhOneK, AccountClass.fourOhThreeB,
    AccountClass.collegeSavings529, AccountClass.mutualFund,
    AccountClass.rrsp, AccountClass.resp, AccountClass.tfsa,
    AccountClass.hsaInvestment,
]

/// Liability account classes (negative net worth)
public let liabilityClasses: Set<Int> = [
    AccountClass.liability,
    AccountClass.loan, AccountClass.mortgage,
    AccountClass.studentLoan, AccountClass.autoLoan,
    AccountClass.revolvingDebt, AccountClass.creditCard,
    AccountClass.lineOfCredit, AccountClass.heloc,
]

/// Equity account classes. Kept separate from assets and liabilities.
public let equityClasses: Set<Int> = [
    AccountClass.equity,
]

/// Official Banktivity account class display names.
public let accountClassNames: [Int: String] = [
    AccountClass.unknown: "Unknown",
    AccountClass.asset: "Asset",
    AccountClass.realEstate: "Real Estate",
    AccountClass.automobile: "Automobile",
    AccountClass.collectible: "Collectible",
    AccountClass.artwork: "Artwork",
    AccountClass.cash: "Cash",
    AccountClass.checking: "Checking",
    AccountClass.savings: "Savings",
    AccountClass.moneyMarket: "Money Market",
    AccountClass.certificateOfDeposit: "Certificate of Deposit",
    AccountClass.healthSavingsAccount: "Health Savings Account",
    AccountClass.current: "Current",
    AccountClass.investment: "Investment",
    AccountClass.ira: "IRA",
    AccountClass.sep: "SEP",
    AccountClass.fourOhOneK: "401(k)",
    AccountClass.fourOhThreeB: "403(b)",
    AccountClass.collegeSavings529: "College Savings (529)",
    AccountClass.mutualFund: "Mutual Fund",
    AccountClass.rrsp: "RRSP",
    AccountClass.resp: "RESP",
    AccountClass.tfsa: "TFSA",
    AccountClass.hsaInvestment: "HSA Investment",
    AccountClass.liability: "Liability",
    AccountClass.loan: "Loan",
    AccountClass.mortgage: "Mortgage",
    AccountClass.studentLoan: "Student Loan",
    AccountClass.autoLoan: "Auto Loan",
    AccountClass.revolvingDebt: "Revolving Debt",
    AccountClass.creditCard: "Credit Card",
    AccountClass.lineOfCredit: "Line of Credit",
    AccountClass.heloc: "HELOC",
    AccountClass.income: "Income",
    AccountClass.expense: "Expense",
    AccountClass.equity: "Equity",
]

/// Get the official Banktivity account type display name from account class.
public func accountTypeName(for accountClass: Int) -> String {
    accountClassNames[accountClass] ?? "Unknown (\(accountClass))"
}

/// Backward-compatible wrapper for older internal callers.
public func getAccountTypeName(_ accountClass: Int) -> String {
    accountTypeName(for: accountClass)
}
