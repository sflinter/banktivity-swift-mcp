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
    public let accountAmount: Double
    public let statementBalanceAmount: Double?
    public let exchangeRate: Double
    public let memo: String?
    public let runningBalance: Double?
    public let cleared: Bool
    public let statementId: Int?
    public let tags: [TagDTO]?

    public init(id: Int, accountId: Int, accountName: String, amount: Double, accountAmount: Double? = nil, statementBalanceAmount: Double? = nil, exchangeRate: Double = 1.0, memo: String?, runningBalance: Double?, cleared: Bool = false, statementId: Int? = nil, tags: [TagDTO]? = nil) {
        self.id = id; self.accountId = accountId; self.accountName = accountName
        self.amount = amount; self.accountAmount = accountAmount ?? (amount * exchangeRate)
        self.statementBalanceAmount = statementBalanceAmount
        self.exchangeRate = exchangeRate
        self.memo = memo; self.runningBalance = runningBalance
        self.cleared = cleared; self.statementId = statementId; self.tags = tags
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
    public let statementId: Int
    public let accountId: Int
    public let accountName: String
    public let accountClass: Int
    public let accountType: String
    public let uniqueId: String?
    public let rowKind: String
    public let isVisibleNamedRow: Bool
    public let isUnnamedInvestmentRow: Bool
    public let isInternalRowCandidate: Bool
    public let operatorConfirmedVisibleRequired: Bool
    public let name: String?
    public let note: String?
    public let startDate: String
    public let endDate: String
    public let beginningBalance: Double
    public let endingBalance: Double
    public let reconciledLineItemCount: Int
    public let reconciledBalance: Double
    public let difference: Double
    public let cashLineBalanced: Bool
    public let isBalancedAdvisory: Bool
    public let uiVerificationRequired: Bool
    public let warnings: [String]
    public let lineItems: [LineItemDTO]
    public let createdAt: String?
    public let modifiedAt: String?

    public var isBalanced: Bool { isBalancedAdvisory }

    public init(id: Int, accountId: Int, accountName: String, accountClass: Int, accountType: String, uniqueId: String? = nil, rowKind: String = "visible_named", isVisibleNamedRow: Bool = true, isUnnamedInvestmentRow: Bool = false, isInternalRowCandidate: Bool = false, operatorConfirmedVisibleRequired: Bool = false, name: String?, note: String?, startDate: String, endDate: String, beginningBalance: Double, endingBalance: Double, reconciledLineItemCount: Int, reconciledBalance: Double, difference: Double, cashLineBalanced: Bool, isBalancedAdvisory: Bool, uiVerificationRequired: Bool, warnings: [String], lineItems: [LineItemDTO], createdAt: String?, modifiedAt: String?) {
        self.id = id; self.accountId = accountId; self.accountName = accountName
        self.statementId = id
        self.accountClass = accountClass; self.accountType = accountType; self.uniqueId = uniqueId
        self.rowKind = rowKind
        self.isVisibleNamedRow = isVisibleNamedRow
        self.isUnnamedInvestmentRow = isUnnamedInvestmentRow
        self.isInternalRowCandidate = isInternalRowCandidate
        self.operatorConfirmedVisibleRequired = operatorConfirmedVisibleRequired
        self.name = name; self.note = note; self.startDate = startDate; self.endDate = endDate
        self.beginningBalance = beginningBalance; self.endingBalance = endingBalance
        self.reconciledLineItemCount = reconciledLineItemCount; self.reconciledBalance = reconciledBalance
        self.difference = difference
        self.cashLineBalanced = cashLineBalanced
        self.isBalancedAdvisory = isBalancedAdvisory
        self.uiVerificationRequired = uiVerificationRequired
        self.warnings = warnings
        self.lineItems = lineItems
        self.createdAt = createdAt; self.modifiedAt = modifiedAt
    }
}

/// Read-only proof that a line item's statement reference can be addressed by
/// the runtime and, for an internal row, recreated by the typed restore path.
/// This deliberately contains no write authority.
public struct StatementMembershipInspectionDTO: Codable, Sendable {
    public let lineItemId: Int
    public let referencedStatementId: Int?
    public let stableIdentity: String?
    public let accountId: Int?
    public let accountName: String?
    public let startDate: String?
    public let endDate: String?
    public let beginningBalance: Double?
    public let endingBalance: Double?
    public let membershipLineItemIds: [Int]
    public let membershipCount: Int
    public let visibilityClassification: String
    public let positionAnchors: [String: Int?]
    /// Exact Codable preimage consumed by the typed restore primitive.  It is
    /// read-only evidence, not a generic mutation payload.
    public let statementPreimage: StatementDTO?
    public let lineItemMemberships: [StatementLineItemMembershipPreimageDTO]
    public let preimageSha256: String?
    public let membershipPreimageSha256: String?
    public let capabilityFlags: [String: Bool]

    public init(lineItemId: Int, referencedStatementId: Int?, stableIdentity: String?, accountId: Int?, accountName: String?, startDate: String?, endDate: String?, beginningBalance: Double?, endingBalance: Double?, membershipLineItemIds: [Int], membershipCount: Int, visibilityClassification: String, positionAnchors: [String: Int?], statementPreimage: StatementDTO?, lineItemMemberships: [StatementLineItemMembershipPreimageDTO], preimageSha256: String?, membershipPreimageSha256: String?, capabilityFlags: [String: Bool]) {
        self.lineItemId = lineItemId; self.referencedStatementId = referencedStatementId
        self.stableIdentity = stableIdentity; self.accountId = accountId; self.accountName = accountName
        self.startDate = startDate; self.endDate = endDate
        self.beginningBalance = beginningBalance; self.endingBalance = endingBalance
        self.membershipLineItemIds = membershipLineItemIds; self.membershipCount = membershipCount
        self.visibilityClassification = visibilityClassification; self.positionAnchors = positionAnchors
        self.statementPreimage = statementPreimage; self.lineItemMemberships = lineItemMemberships
        self.preimageSha256 = preimageSha256; self.membershipPreimageSha256 = membershipPreimageSha256
        self.capabilityFlags = capabilityFlags
    }
}

public struct StatementLineItemMembershipPreimageDTO: Codable, Sendable {
    public let lineItemId: Int
    public let statementId: Int
    public let cleared: Bool

    public init(lineItemId: Int, statementId: Int, cleared: Bool) {
        self.lineItemId = lineItemId; self.statementId = statementId; self.cleared = cleared
    }
}

public struct AccountReconciliationStatusDTO: Codable, Sendable {
    public let accountId: Int
    public let hasReconciledStatements: Bool
    public let statementCount: Int
    public let lastStatementId: Int?
    public let lastReconciledStatementEndDate: String?

    public init(accountId: Int, hasReconciledStatements: Bool, statementCount: Int, lastStatementId: Int?, lastReconciledStatementEndDate: String?) {
        self.accountId = accountId
        self.hasReconciledStatements = hasReconciledStatements
        self.statementCount = statementCount
        self.lastStatementId = lastStatementId
        self.lastReconciledStatementEndDate = lastReconciledStatementEndDate
    }
}

public struct SecurityHoldingDTO: Codable, Sendable {
    public let accountId: Int
    public let accountName: String
    public let securityId: Int
    public let symbol: String
    public let securityName: String
    public let shares: Double
    public let costBasis: Double
    public let marketValue: Double?
    public let lastPrice: Double?
    public let lastPriceDate: String?
    public let currency: String?

    public init(accountId: Int, accountName: String, securityId: Int, symbol: String, securityName: String, shares: Double, costBasis: Double, marketValue: Double?, lastPrice: Double?, lastPriceDate: String?, currency: String?) {
        self.accountId = accountId; self.accountName = accountName; self.securityId = securityId
        self.symbol = symbol; self.securityName = securityName; self.shares = shares
        self.costBasis = costBasis; self.marketValue = marketValue; self.lastPrice = lastPrice
        self.lastPriceDate = lastPriceDate; self.currency = currency
    }
}

public struct SecurityTradeDTO: Codable, Sendable {
    public let id: Int
    public let date: String
    public let type: String
    public let symbol: String
    public let securityName: String
    public let shares: Double
    public let pricePerShare: Double
    public let amount: Double
    public let commission: Double
    public let accountName: String
    public let accountId: Int

    public init(id: Int, date: String, type: String, symbol: String, securityName: String, shares: Double, pricePerShare: Double, amount: Double, commission: Double, accountName: String, accountId: Int) {
        self.id = id; self.date = date; self.type = type; self.symbol = symbol
        self.securityName = securityName; self.shares = shares; self.pricePerShare = pricePerShare
        self.amount = amount; self.commission = commission; self.accountName = accountName
        self.accountId = accountId
    }
}

public struct SecurityIncomeDTO: Codable, Sendable {
    public let id: Int
    public let date: String
    public let type: String
    public let symbol: String
    public let securityName: String
    public let amount: Double
    public let accountName: String
    public let accountId: Int

    public init(id: Int, date: String, type: String, symbol: String, securityName: String, amount: Double, accountName: String, accountId: Int) {
        self.id = id; self.date = date; self.type = type; self.symbol = symbol
        self.securityName = securityName; self.amount = amount
        self.accountName = accountName; self.accountId = accountId
    }
}

public struct SecurityDTO: Codable, Sendable {
    public let id: Int
    public let name: String
    public let symbol: String
    public let uniqueId: String
    public let currency: String?
    public let securityType: Int

    public init(id: Int, name: String, symbol: String, uniqueId: String, currency: String?, securityType: Int) {
        self.id = id; self.name = name; self.symbol = symbol; self.uniqueId = uniqueId
        self.currency = currency; self.securityType = securityType
    }
}

public struct SecurityPriceDTO: Codable, Sendable {
    public let id: Int
    public let date: String
    public let closePrice: Double
    public let adjustedClosePrice: Double
    public let openPrice: Double
    public let highPrice: Double
    public let lowPrice: Double
    public let volume: Double
    public let dataSource: Int

    public init(id: Int, date: String, closePrice: Double, adjustedClosePrice: Double, openPrice: Double, highPrice: Double, lowPrice: Double, volume: Double, dataSource: Int) {
        self.id = id; self.date = date; self.closePrice = closePrice
        self.adjustedClosePrice = adjustedClosePrice; self.openPrice = openPrice
        self.highPrice = highPrice; self.lowPrice = lowPrice
        self.volume = volume; self.dataSource = dataSource
    }
}

public struct PriceImportResultDTO: Codable, Sendable {
    public let securitySymbol: String
    public let imported: Int
    public let skipped: Int
    public let totalPrices: Int
    public let dateRangeBegin: String?
    public let dateRangeEnd: String?
    public let latestClosePrice: Double?
    public let latestDateISO: String?

    public init(securitySymbol: String, imported: Int, skipped: Int, totalPrices: Int, dateRangeBegin: String?, dateRangeEnd: String?, latestClosePrice: Double? = nil, latestDateISO: String? = nil) {
        self.securitySymbol = securitySymbol; self.imported = imported; self.skipped = skipped
        self.totalPrices = totalPrices; self.dateRangeBegin = dateRangeBegin
        self.dateRangeEnd = dateRangeEnd; self.latestClosePrice = latestClosePrice
        self.latestDateISO = latestDateISO
    }
}

public struct StatementSummaryDTO: Codable, Sendable {
    public let id: Int
    public let name: String?
    public let rowKind: String
    public let isVisibleNamedRow: Bool
    public let isUnnamedInvestmentRow: Bool
    public let isInternalRowCandidate: Bool
    public let operatorConfirmedVisibleRequired: Bool
    public let startDate: String
    public let endDate: String
    public let beginningBalance: Double
    public let endingBalance: Double
    public let reconciledLineItemCount: Int
    public let cashLineBalanced: Bool
    public let isBalancedAdvisory: Bool
    public let uiVerificationRequired: Bool
    public let warnings: [String]

    public var isBalanced: Bool { isBalancedAdvisory }

    public init(id: Int, name: String?, rowKind: String = "visible_named", isVisibleNamedRow: Bool = true, isUnnamedInvestmentRow: Bool = false, isInternalRowCandidate: Bool = false, operatorConfirmedVisibleRequired: Bool = false, startDate: String, endDate: String, beginningBalance: Double, endingBalance: Double, reconciledLineItemCount: Int, cashLineBalanced: Bool, isBalancedAdvisory: Bool, uiVerificationRequired: Bool, warnings: [String]) {
        self.id = id; self.name = name
        self.rowKind = rowKind
        self.isVisibleNamedRow = isVisibleNamedRow
        self.isUnnamedInvestmentRow = isUnnamedInvestmentRow
        self.isInternalRowCandidate = isInternalRowCandidate
        self.operatorConfirmedVisibleRequired = operatorConfirmedVisibleRequired
        self.startDate = startDate; self.endDate = endDate
        self.beginningBalance = beginningBalance; self.endingBalance = endingBalance
        self.reconciledLineItemCount = reconciledLineItemCount
        self.cashLineBalanced = cashLineBalanced
        self.isBalancedAdvisory = isBalancedAdvisory
        self.uiVerificationRequired = uiVerificationRequired
        self.warnings = warnings
    }

    public init(id: Int, name: String?, startDate: String, endDate: String, beginningBalance: Double, endingBalance: Double, reconciledLineItemCount: Int, isBalanced: Bool) {
        self.init(
            id: id,
            name: name,
            startDate: startDate,
            endDate: endDate,
            beginningBalance: beginningBalance,
            endingBalance: endingBalance,
            reconciledLineItemCount: reconciledLineItemCount,
            cashLineBalanced: isBalanced,
            isBalancedAdvisory: isBalanced,
            uiVerificationRequired: false,
            warnings: []
        )
    }
}

/// A line-item reference which exists in the account graph but cannot safely
/// be addressed as a statement in the requested account.  `--include-internal`
/// reports these explicitly so hidden references can never vanish from a
/// diagnostic listing.
public struct StatementUnaddressableReferenceDTO: Codable, Sendable {
    public let lineItemId: Int
    public let referencedStatementId: Int
    public let requestedAccountId: Int
    public let reason: String
    public let capabilityFlags: [String: Bool]

    public init(lineItemId: Int, referencedStatementId: Int, requestedAccountId: Int, reason: String) {
        self.lineItemId = lineItemId
        self.referencedStatementId = referencedStatementId
        self.requestedAccountId = requestedAccountId
        self.reason = reason
        self.capabilityFlags = ["addressable": false, "reconcilable": false, "restorable": false]
    }
}

/// Complete internal-statement diagnostic listing.  This envelope is emitted
/// only for `--include-internal`; the default statement-list shape remains
/// stable for existing consumers.
public struct StatementInternalListingDTO: Codable, Sendable {
    public let statements: [StatementSummaryDTO]
    public let unaddressableReferences: [StatementUnaddressableReferenceDTO]

    public init(statements: [StatementSummaryDTO], unaddressableReferences: [StatementUnaddressableReferenceDTO]) {
        self.statements = statements
        self.unaddressableReferences = unaddressableReferences
    }
}

public struct VisibleRowCorrectionPlanDTO: Codable, Sendable {
    public let statementId: Int?
    public let inputSource: String
    public let uiStart: Double
    public let uiEnd: Double
    public let uiMissing: Double
    public let correctedStart: Double
    public let uiCompatibleRowDelta: Double
    public let correctedEndingBalance: Double
    public let formula: String
    public let writeTarget: String
    public let backupRequiredBeforeWrite: Bool
    public let postUIVerificationRequired: Bool
    public let uiVerificationRequired: Bool
    public let warnings: [String]

    public init(statementId: Int?, uiStart: Double, uiEnd: Double, uiMissing: Double, correctedStart: Double? = nil) {
        let effectiveStart = correctedStart ?? uiStart
        let rowDelta = uiEnd - uiStart - uiMissing
        self.statementId = statementId
        self.inputSource = "operator_entered_ui_values"
        self.uiStart = uiStart
        self.uiEnd = uiEnd
        self.uiMissing = uiMissing
        self.correctedStart = effectiveStart
        self.uiCompatibleRowDelta = rowDelta
        self.correctedEndingBalance = effectiveStart + rowDelta
        self.formula = "correctedEndingBalance = correctedStart + (uiEnd - uiStart - uiMissing)"
        self.writeTarget = statementId.map { "visible statement id \($0)" } ?? "operator-selected visible statement id"
        self.backupRequiredBeforeWrite = true
        self.postUIVerificationRequired = true
        self.uiVerificationRequired = true
        self.warnings = [
            "This plan uses only operator-entered Banktivity UI START/END/MISSING values; it did not discover or verify UI state.",
            "Apply only to the intended visible statement row after a fresh backup, then reopen Banktivity and verify the Statements tab."
        ]
    }
}
