// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

public struct VaultExportData: Sendable {
    public let vaultName: String
    public let accounts: [AccountDTO]
    public let transactions: [TransactionDTO]
    public let categories: [CategoryDTO]
    public let tags: [TagDTO]
    public let templates: [TransactionTemplateDTO]
    public let importRules: [ImportRuleDTO]
    public let scheduled: [ScheduledTransactionDTO]
    public let statements: [ExportStatementDTO]

    public let securities: [SecurityDTO]
    public let holdings: [SecurityHoldingDTO]
    public let trades: [SecurityTradeDTO]
    public let income: [SecurityIncomeDTO]
    public let prices: [String: [SecurityPriceDTO]]

    public init(
        vaultName: String,
        accounts: [AccountDTO],
        transactions: [TransactionDTO],
        categories: [CategoryDTO],
        tags: [TagDTO],
        templates: [TransactionTemplateDTO],
        importRules: [ImportRuleDTO],
        scheduled: [ScheduledTransactionDTO],
        statements: [ExportStatementDTO],
        securities: [SecurityDTO],
        holdings: [SecurityHoldingDTO],
        trades: [SecurityTradeDTO],
        income: [SecurityIncomeDTO],
        prices: [String: [SecurityPriceDTO]]
    ) {
        self.vaultName = vaultName
        self.accounts = accounts
        self.transactions = transactions
        self.categories = categories
        self.tags = tags
        self.templates = templates
        self.importRules = importRules
        self.scheduled = scheduled
        self.statements = statements
        self.securities = securities
        self.holdings = holdings
        self.trades = trades
        self.income = income
        self.prices = prices
    }
}

public struct ExportStatementDTO: Sendable {
    public let id: Int
    public let accountId: Int
    public let accountName: String
    public let name: String?
    public let startDate: String
    public let endDate: String
    public let beginningBalance: Double
    public let endingBalance: Double
    public let reconciledLineItemCount: Int
    public let isBalanced: Bool

    public init(accountId: Int, accountName: String, summary: StatementSummaryDTO) {
        self.id = summary.id
        self.accountId = accountId
        self.accountName = accountName
        self.name = summary.name
        self.startDate = summary.startDate
        self.endDate = summary.endDate
        self.beginningBalance = summary.beginningBalance
        self.endingBalance = summary.endingBalance
        self.reconciledLineItemCount = summary.reconciledLineItemCount
        self.isBalanced = summary.isBalanced
    }
}

public protocol RDFSerializer: Sendable {
    func serialize(_ data: VaultExportData) -> String
}
