// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

// MARK: - Response DTOs

public struct AccountDTO: Codable, Sendable {
    public let id: Int
    public let name: String
    public let fullName: String
    public let accountClass: Int
    public let accountType: String
    public let hidden: Bool
    public let currency: String?
    public let balance: Double?
    public let formattedBalance: String?

    public init(id: Int, name: String, fullName: String, accountClass: Int, accountType: String, hidden: Bool, currency: String?, balance: Double?, formattedBalance: String?) {
        self.id = id; self.name = name; self.fullName = fullName; self.accountClass = accountClass
        self.accountType = accountType; self.hidden = hidden; self.currency = currency
        self.balance = balance; self.formattedBalance = formattedBalance
    }
}

public struct TransactionDTO: Codable, Sendable {
    public let id: Int
    public let date: String
    public let title: String
    public let note: String?
    public let cleared: Bool
    public let voided: Bool
    public let transactionType: String?
    public let lineItems: [LineItemDTO]

    public init(id: Int, date: String, title: String, note: String?, cleared: Bool, voided: Bool, transactionType: String?, lineItems: [LineItemDTO]) {
        self.id = id; self.date = date; self.title = title; self.note = note
        self.cleared = cleared; self.voided = voided; self.transactionType = transactionType
        self.lineItems = lineItems
    }
}

public struct LineItemDTO: Codable, Sendable {
    public let id: Int
    public let accountId: Int
    public let accountName: String
    public let amount: Double
    public let memo: String?
    public let runningBalance: Double?
    public let cleared: Bool
    public let statementId: Int?

    public init(id: Int, accountId: Int, accountName: String, amount: Double, memo: String?, runningBalance: Double?, cleared: Bool = false, statementId: Int? = nil) {
        self.id = id; self.accountId = accountId; self.accountName = accountName
        self.amount = amount; self.memo = memo; self.runningBalance = runningBalance
        self.cleared = cleared; self.statementId = statementId
    }
}

public struct CategoryDTO: Codable, Sendable {
    public let id: Int
    public let name: String
    public let fullName: String
    public let type: String // "income" or "expense"
    public let accountClass: Int
    public let parentId: Int?
    public let hidden: Bool
    public let uniqueId: String
    public let currency: String?

    public init(id: Int, name: String, fullName: String, type: String, accountClass: Int, parentId: Int?, hidden: Bool, uniqueId: String, currency: String?) {
        self.id = id; self.name = name; self.fullName = fullName; self.type = type
        self.accountClass = accountClass; self.parentId = parentId; self.hidden = hidden
        self.uniqueId = uniqueId; self.currency = currency
    }
}

public struct CategoryTreeNodeDTO: Codable, Sendable {
    public let id: Int
    public let name: String
    public let fullName: String
    public let type: String
    public let accountClass: Int
    public let parentId: Int?
    public let hidden: Bool
    public let uniqueId: String
    public let currency: String?
    public let children: [CategoryTreeNodeDTO]

    public init(id: Int, name: String, fullName: String, type: String, accountClass: Int, parentId: Int?, hidden: Bool, uniqueId: String, currency: String?, children: [CategoryTreeNodeDTO]) {
        self.id = id; self.name = name; self.fullName = fullName; self.type = type
        self.accountClass = accountClass; self.parentId = parentId; self.hidden = hidden
        self.uniqueId = uniqueId; self.currency = currency; self.children = children
    }
}

public struct CategorySpendingDTO: Codable, Sendable {
    public let category: String
    public let total: Double
    public let transactionCount: Int
    public let formattedTotal: String?

    public init(category: String, total: Double, transactionCount: Int, formattedTotal: String?) {
        self.category = category; self.total = total; self.transactionCount = transactionCount
        self.formattedTotal = formattedTotal
    }
}

public struct NetWorthDTO: Codable, Sendable {
    public let assets: Double
    public let liabilities: Double
    public let netWorth: Double
    public let formattedAssets: String?
    public let formattedLiabilities: String?
    public let formattedNetWorth: String?

    public init(assets: Double, liabilities: Double, netWorth: Double, formattedAssets: String?, formattedLiabilities: String?, formattedNetWorth: String?) {
        self.assets = assets; self.liabilities = liabilities; self.netWorth = netWorth
        self.formattedAssets = formattedAssets; self.formattedLiabilities = formattedLiabilities
        self.formattedNetWorth = formattedNetWorth
    }
}

public struct TagDTO: Codable, Sendable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id; self.name = name
    }
}

public struct TransactionTemplateDTO: Codable, Sendable {
    public let id: Int
    public let title: String
    public let amount: Double
    public let currencyId: String?
    public let note: String?
    public let active: Bool
    public let fixedAmount: Bool
    public let lastAppliedDate: String?
    public let lineItems: [LineItemTemplateDTO]

    public init(id: Int, title: String, amount: Double, currencyId: String?, note: String?, active: Bool, fixedAmount: Bool, lastAppliedDate: String?, lineItems: [LineItemTemplateDTO]) {
        self.id = id; self.title = title; self.amount = amount; self.currencyId = currencyId
        self.note = note; self.active = active; self.fixedAmount = fixedAmount
        self.lastAppliedDate = lastAppliedDate; self.lineItems = lineItems
    }
}

public struct LineItemTemplateDTO: Codable, Sendable {
    public let id: Int
    public let accountId: String
    public let accountName: String?
    public let amount: Double
    public let memo: String?
    public let fixedAmount: Bool

    public init(id: Int, accountId: String, accountName: String?, amount: Double, memo: String?, fixedAmount: Bool) {
        self.id = id; self.accountId = accountId; self.accountName = accountName
        self.amount = amount; self.memo = memo; self.fixedAmount = fixedAmount
    }
}

public struct ImportRuleDTO: Codable, Sendable {
    public let id: Int
    public let templateId: Int
    public let templateTitle: String
    public let pattern: String
    public let accountId: String?
    public let payee: String?

    public init(id: Int, templateId: Int, templateTitle: String, pattern: String, accountId: String?, payee: String?) {
        self.id = id; self.templateId = templateId; self.templateTitle = templateTitle
        self.pattern = pattern; self.accountId = accountId; self.payee = payee
    }
}

public struct ScheduledTransactionDTO: Codable, Sendable {
    public let id: Int
    public let templateId: Int
    public let templateTitle: String
    public let amount: Double
    public let startDate: String?
    public let nextDate: String?
    public let repeatInterval: Int?
    public let repeatMultiplier: Int?
    public let accountId: String?
    public let reminderDays: Int?
    public let recurringTransactionId: Int?

    public init(id: Int, templateId: Int, templateTitle: String, amount: Double, startDate: String?, nextDate: String?, repeatInterval: Int?, repeatMultiplier: Int?, accountId: String?, reminderDays: Int?, recurringTransactionId: Int?) {
        self.id = id; self.templateId = templateId; self.templateTitle = templateTitle
        self.amount = amount; self.startDate = startDate; self.nextDate = nextDate
        self.repeatInterval = repeatInterval; self.repeatMultiplier = repeatMultiplier
        self.accountId = accountId; self.reminderDays = reminderDays
        self.recurringTransactionId = recurringTransactionId
    }
}

public struct SummaryDTO: Codable, Sendable {
    public let accounts: AccountSummary
    public let categories: CategorySummary
    public let transactions: Int
    public let tags: Int
    public let netWorth: NetWorthDTO

    public init(accounts: AccountSummary, categories: CategorySummary, transactions: Int, tags: Int, netWorth: NetWorthDTO) {
        self.accounts = accounts; self.categories = categories
        self.transactions = transactions; self.tags = tags; self.netWorth = netWorth
    }

    public struct AccountSummary: Codable, Sendable {
        public let total: Int
        public let checking: Int
        public let savings: Int
        public let creditCards: Int

        public init(total: Int, checking: Int, savings: Int, creditCards: Int) {
            self.total = total; self.checking = checking; self.savings = savings
            self.creditCards = creditCards
        }
    }

    public struct CategorySummary: Codable, Sendable {
        public let income: Int
        public let expense: Int

        public init(income: Int, expense: Int) {
            self.income = income; self.expense = expense
        }
    }
}

public struct UncategorizedTransactionDTO: Codable, Sendable {
    public let id: Int
    public let date: String
    public let title: String
    public let note: String?
    public let accountName: String
    public let amount: Double
    public let lineItems: [LineItemDTO]

    public init(id: Int, date: String, title: String, note: String?, accountName: String, amount: Double, lineItems: [LineItemDTO]) {
        self.id = id; self.date = date; self.title = title; self.note = note
        self.accountName = accountName; self.amount = amount; self.lineItems = lineItems
    }
}

public struct CategorySuggestionDTO: Codable, Sendable {
    public let categoryId: Int
    public let categoryName: String
    public let categoryPath: String
    public let confidence: Double
    public let reason: String
    public let matchCount: Int

    public init(categoryId: Int, categoryName: String, categoryPath: String, confidence: Double, reason: String, matchCount: Int) {
        self.categoryId = categoryId; self.categoryName = categoryName
        self.categoryPath = categoryPath; self.confidence = confidence
        self.reason = reason; self.matchCount = matchCount
    }
}

public struct PayeeCategorySummaryDTO: Codable, Sendable {
    public let title: String
    public let totalTransactions: Int
    public let categories: [PayeeCategoryEntryDTO]
    public let uncategorizedCount: Int

    public init(title: String, totalTransactions: Int, categories: [PayeeCategoryEntryDTO], uncategorizedCount: Int) {
        self.title = title; self.totalTransactions = totalTransactions
        self.categories = categories; self.uncategorizedCount = uncategorizedCount
    }
}

public struct PayeeCategoryEntryDTO: Codable, Sendable {
    public let categoryId: Int
    public let categoryName: String
    public let categoryPath: String
    public let count: Int

    public init(categoryId: Int, categoryName: String, categoryPath: String, count: Int) {
        self.categoryId = categoryId; self.categoryName = categoryName
        self.categoryPath = categoryPath; self.count = count
    }
}

public struct RecategorizationResultDTO: Codable, Sendable {
    public let transactionId: Int
    public let title: String
    public let oldCategoryName: String?
    public let newCategoryName: String

    public init(transactionId: Int, title: String, oldCategoryName: String?, newCategoryName: String) {
        self.transactionId = transactionId; self.title = title
        self.oldCategoryName = oldCategoryName; self.newCategoryName = newCategoryName
    }
}

public struct BulkRecategorizeResultDTO: Codable, Sendable {
    public let affected: [RecategorizationResultDTO]
    public let count: Int

    public init(affected: [RecategorizationResultDTO], count: Int) {
        self.affected = affected; self.count = count
    }
}

public struct ReviewedTransactionDTO: Codable, Sendable {
    public let id: Int
    public let date: String
    public let title: String
    public let note: String?
    public let accountName: String
    public let amount: Double
    public let categoryId: Int?
    public let categoryName: String?
    public let categoryPath: String?

    public init(id: Int, date: String, title: String, note: String?, accountName: String, amount: Double, categoryId: Int?, categoryName: String?, categoryPath: String?) {
        self.id = id; self.date = date; self.title = title; self.note = note
        self.accountName = accountName; self.amount = amount; self.categoryId = categoryId
        self.categoryName = categoryName; self.categoryPath = categoryPath
    }
}

public struct StatementDTO: Codable, Sendable {
    public let id: Int
    public let accountId: Int
    public let accountName: String
    public let name: String?
    public let note: String?
    public let startDate: String
    public let endDate: String
    public let beginningBalance: Double
    public let endingBalance: Double
    public let reconciledLineItemCount: Int
    public let reconciledBalance: Double
    public let difference: Double
    public let isBalanced: Bool
    public let createdAt: String?
    public let modifiedAt: String?

    public init(id: Int, accountId: Int, accountName: String, name: String?, note: String?, startDate: String, endDate: String, beginningBalance: Double, endingBalance: Double, reconciledLineItemCount: Int, reconciledBalance: Double, difference: Double, isBalanced: Bool, createdAt: String?, modifiedAt: String?) {
        self.id = id; self.accountId = accountId; self.accountName = accountName
        self.name = name; self.note = note; self.startDate = startDate; self.endDate = endDate
        self.beginningBalance = beginningBalance; self.endingBalance = endingBalance
        self.reconciledLineItemCount = reconciledLineItemCount; self.reconciledBalance = reconciledBalance
        self.difference = difference; self.isBalanced = isBalanced
        self.createdAt = createdAt; self.modifiedAt = modifiedAt
    }
}

public struct StatementSummaryDTO: Codable, Sendable {
    public let id: Int
    public let name: String?
    public let startDate: String
    public let endDate: String
    public let beginningBalance: Double
    public let endingBalance: Double
    public let reconciledLineItemCount: Int
    public let isBalanced: Bool

    public init(id: Int, name: String?, startDate: String, endDate: String, beginningBalance: Double, endingBalance: Double, reconciledLineItemCount: Int, isBalanced: Bool) {
        self.id = id; self.name = name; self.startDate = startDate; self.endDate = endDate
        self.beginningBalance = beginningBalance; self.endingBalance = endingBalance
        self.reconciledLineItemCount = reconciledLineItemCount; self.isBalanced = isBalanced
    }
}
