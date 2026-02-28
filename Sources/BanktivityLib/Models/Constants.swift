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

/// Account class constants
public enum AccountClass {
    public static let realEstate = 2
    public static let cash = 1000
    public static let checking = 1001
    public static let savings = 1002
    public static let moneyMarket = 1006
    public static let investment = 2000
    public static let retirement = 2001
    public static let education = 2003
    public static let loan = 4001
    public static let creditCard = 5001
    public static let income = 6000
    public static let expense = 7000
}

/// Asset account classes (positive net worth)
public let assetClasses: Set<Int> = [
    AccountClass.realEstate,
    AccountClass.cash,
    AccountClass.checking,
    AccountClass.savings,
    AccountClass.moneyMarket,
    AccountClass.investment,
    AccountClass.retirement,
    AccountClass.education,
]

/// Liability account classes (negative net worth)
public let liabilityClasses: Set<Int> = [
    AccountClass.loan,
    AccountClass.creditCard,
]

/// Account class display names
public let accountClassNames: [Int: String] = [
    AccountClass.realEstate: "Real Estate",
    AccountClass.cash: "Cash",
    AccountClass.checking: "Checking",
    AccountClass.savings: "Savings",
    AccountClass.moneyMarket: "Money Market",
    AccountClass.investment: "Investment",
    AccountClass.retirement: "Retirement",
    AccountClass.education: "Education",
    AccountClass.loan: "Loan",
    AccountClass.creditCard: "Credit Card",
    AccountClass.income: "Income",
    AccountClass.expense: "Expense",
]

/// Get account type display name from account class
public func getAccountTypeName(_ accountClass: Int) -> String {
    accountClassNames[accountClass] ?? "Unknown (\(accountClass))"
}
