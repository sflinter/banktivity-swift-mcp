// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

/// Core Data entity type constants (Z_ENT values)
enum ZEntityType {
    static let account = 1
    static let category = 2
    static let primaryAccount = 3
    static let lineItem = 19
    static let lineItemTemplate = 21
    static let payee = 31
    static let payeeInfo = 33
    static let recurringTransaction = 35
    static let tag = 47
    static let templateSelector = 48
    static let importSourceTemplateSelector = 49
    static let scheduledTemplateSelector = 52
    static let transaction = 53
    static let transactionTemplate = 54
    static let transactionType = 55
    static let syncedHostedEntity = 46
}

/// Maps entity Z_ENT values to sync entity type name strings
let syncEntityTypeNames: [Int: String] = [
    ZEntityType.account: "Account",
    ZEntityType.category: "Account",
    ZEntityType.primaryAccount: "Account",
    ZEntityType.tag: "Tag",
    ZEntityType.transaction: "Transaction",
    ZEntityType.transactionTemplate: "TransactionTemplate",
    ZEntityType.recurringTransaction: "RecurringTransaction",
]

/// Account class constants
enum AccountClass {
    static let realEstate = 2
    static let cash = 1000
    static let checking = 1001
    static let savings = 1002
    static let moneyMarket = 1006
    static let investment = 2000
    static let retirement = 2001
    static let education = 2003
    static let loan = 4001
    static let creditCard = 5001
    static let income = 6000
    static let expense = 7000
}

/// Asset account classes (positive net worth)
let assetClasses: Set<Int> = [
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
let liabilityClasses: Set<Int> = [
    AccountClass.loan,
    AccountClass.creditCard,
]

/// Account class display names
let accountClassNames: [Int: String] = [
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
func getAccountTypeName(_ accountClass: Int) -> String {
    accountClassNames[accountClass] ?? "Unknown (\(accountClass))"
}
