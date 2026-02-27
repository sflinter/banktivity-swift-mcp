// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

// MARK: - Response DTOs

struct AccountDTO: Codable, Sendable {
    let id: Int
    let name: String
    let fullName: String
    let accountClass: Int
    let accountType: String
    let hidden: Bool
    let currency: String?
    let balance: Double?
    let formattedBalance: String?
}

struct TransactionDTO: Codable, Sendable {
    let id: Int
    let date: String
    let title: String
    let note: String?
    let cleared: Bool
    let voided: Bool
    let transactionType: String?
    let lineItems: [LineItemDTO]
}

struct LineItemDTO: Codable, Sendable {
    let id: Int
    let accountId: Int
    let accountName: String
    let amount: Double
    let memo: String?
    let runningBalance: Double?
}

struct CategoryDTO: Codable, Sendable {
    let id: Int
    let name: String
    let fullName: String
    let type: String // "income" or "expense"
    let accountClass: Int
    let parentId: Int?
    let hidden: Bool
    let uniqueId: String
    let currency: String?
}

struct CategoryTreeNodeDTO: Codable, Sendable {
    let id: Int
    let name: String
    let fullName: String
    let type: String
    let accountClass: Int
    let parentId: Int?
    let hidden: Bool
    let uniqueId: String
    let currency: String?
    let children: [CategoryTreeNodeDTO]
}

struct CategorySpendingDTO: Codable, Sendable {
    let category: String
    let total: Double
    let transactionCount: Int
    let formattedTotal: String?
}

struct NetWorthDTO: Codable, Sendable {
    let assets: Double
    let liabilities: Double
    let netWorth: Double
    let formattedAssets: String?
    let formattedLiabilities: String?
    let formattedNetWorth: String?
}

struct TagDTO: Codable, Sendable {
    let id: Int
    let name: String
}

struct TransactionTemplateDTO: Codable, Sendable {
    let id: Int
    let title: String
    let amount: Double
    let currencyId: String?
    let note: String?
    let active: Bool
    let fixedAmount: Bool
    let lastAppliedDate: String?
    let lineItems: [LineItemTemplateDTO]
}

struct LineItemTemplateDTO: Codable, Sendable {
    let id: Int
    let accountId: String
    let accountName: String?
    let amount: Double
    let memo: String?
    let fixedAmount: Bool
}

struct ImportRuleDTO: Codable, Sendable {
    let id: Int
    let templateId: Int
    let templateTitle: String
    let pattern: String
    let accountId: String?
    let payee: String?
}

struct ScheduledTransactionDTO: Codable, Sendable {
    let id: Int
    let templateId: Int
    let templateTitle: String
    let amount: Double
    let startDate: String?
    let nextDate: String?
    let repeatInterval: Int?
    let repeatMultiplier: Int?
    let accountId: String?
    let reminderDays: Int?
    let recurringTransactionId: Int?
}

struct SummaryDTO: Codable, Sendable {
    let accounts: AccountSummary
    let categories: CategorySummary
    let transactions: Int
    let tags: Int
    let netWorth: NetWorthDTO

    struct AccountSummary: Codable, Sendable {
        let total: Int
        let checking: Int
        let savings: Int
        let creditCards: Int
    }

    struct CategorySummary: Codable, Sendable {
        let income: Int
        let expense: Int
    }
}

struct UncategorizedTransactionDTO: Codable, Sendable {
    let id: Int
    let date: String
    let title: String
    let note: String?
    let accountName: String
    let amount: Double
    let lineItems: [LineItemDTO]
}

struct CategorySuggestionDTO: Codable, Sendable {
    let categoryId: Int
    let categoryName: String
    let categoryPath: String
    let confidence: Double
    let reason: String
    let matchCount: Int
}

struct PayeeCategorySummaryDTO: Codable, Sendable {
    let title: String
    let totalTransactions: Int
    let categories: [PayeeCategoryEntryDTO]
    let uncategorizedCount: Int
}

struct PayeeCategoryEntryDTO: Codable, Sendable {
    let categoryId: Int
    let categoryName: String
    let categoryPath: String
    let count: Int
}

struct RecategorizationResultDTO: Codable, Sendable {
    let transactionId: Int
    let title: String
    let oldCategoryName: String?
    let newCategoryName: String
}

struct BulkRecategorizeResultDTO: Codable, Sendable {
    let affected: [RecategorizationResultDTO]
    let count: Int
}

struct ReviewedTransactionDTO: Codable, Sendable {
    let id: Int
    let date: String
    let title: String
    let note: String?
    let accountName: String
    let amount: Double
    let categoryId: Int?
    let categoryName: String?
    let categoryPath: String?
}
