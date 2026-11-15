// Copyright (c) 2026 Steve Flinter. MIT License.

import Foundation

public struct TurtleSerializer: RDFSerializer, Sendable {

    private static let schemaOrg = "http://schema.org/"
    private static let xsd = "http://www.w3.org/2001/XMLSchema#"
    private static let skos = "http://www.w3.org/2004/02/skos/core#"
    private static let pfo = "https://sflinter.github.io/personal-finance-ontology#"
    private static let base = "urn:banktivity:"

    public init() {}

    public func serialize(_ data: VaultExportData) -> String {
        let w = TurtleWriter()
        writePrefixes(w)
        writeAccounts(w, data.accounts)
        writeCategories(w, data.categories)
        writeTags(w, data.tags)
        writeTransactions(w, data.transactions)
        writeStatements(w, data.statements)
        writeTemplates(w, data.templates)
        writeImportRules(w, data.importRules)
        writeScheduled(w, data.scheduled)
        writeSecurities(w, data.securities)
        writeHoldings(w, data.holdings)
        writeTrades(w, data.trades)
        writeSecurityIncome(w, data.income)
        writeSecurityPrices(w, data.prices)
        return w.build()
    }

    // MARK: - Prefixes

    private func writePrefixes(_ w: TurtleWriter) {
        w.addPrefix("schema", Self.schemaOrg)
        w.addPrefix("xsd", Self.xsd)
        w.addPrefix("skos", Self.skos)
        w.addPrefix("pfo", Self.pfo)
    }

    // MARK: - Accounts

    private func writeAccounts(_ w: TurtleWriter, _ accounts: [AccountDTO]) {
        guard !accounts.isEmpty else { return }
        w.addComment("Accounts")
        for a in accounts {
            w.startSubject(accountURI(a.id), types: [accountType(a.accountClass)])
            w.addProperty("schema:name", literal: a.name)
            if a.fullName != a.name {
                w.addProperty("pfo:fullName", literal: a.fullName)
            }
            w.addProperty("pfo:accountType", literal: a.accountType)
            w.addProperty("pfo:accountClass", integer: a.accountClass)
            if let currency = a.currency {
                w.addProperty("schema:currency", literal: currency)
            }
            if let balance = a.balance {
                w.addProperty("pfo:balance", decimal: balance)
            }
            w.addProperty("pfo:hidden", boolean: a.hidden)
            w.endSubject()
        }
    }

    private func accountType(_ accountClass: Int) -> String {
        switch accountClass {
        case AccountClass.checking, AccountClass.savings, AccountClass.cash,
             AccountClass.moneyMarket, AccountClass.certificateOfDeposit,
             AccountClass.healthSavingsAccount, AccountClass.current:
            return "schema:BankAccount"
        case AccountClass.creditCard:
            return "schema:CreditCard"
        case AccountClass.investment, AccountClass.ira, AccountClass.sep,
             AccountClass.fourOhOneK, AccountClass.fourOhThreeB,
             AccountClass.collegeSavings529, AccountClass.mutualFund,
             AccountClass.rrsp, AccountClass.resp, AccountClass.tfsa,
             AccountClass.hsaInvestment:
            return "schema:InvestmentOrDeposit"
        case AccountClass.loan, AccountClass.mortgage, AccountClass.studentLoan,
             AccountClass.autoLoan, AccountClass.revolvingDebt,
             AccountClass.lineOfCredit, AccountClass.heloc:
            return "schema:LoanOrCredit"
        case AccountClass.realEstate:
            return "pfo:RealEstateAccount"
        default:
            return "pfo:Account"
        }
    }

    // MARK: - Categories

    private func writeCategories(_ w: TurtleWriter, _ categories: [CategoryDTO]) {
        guard !categories.isEmpty else { return }
        w.addComment("Categories")
        for c in categories {
            let rdfType = c.type == "income" ? "pfo:IncomeCategory" : "pfo:ExpenseCategory"
            w.startSubject(categoryURI(c.id), types: [rdfType])
            w.addProperty("schema:name", literal: c.name)
            if c.fullName != c.name {
                w.addProperty("pfo:fullName", literal: c.fullName)
            }
            w.addProperty("pfo:categoryType", literal: c.type)
            if let parentId = c.parentId {
                w.addProperty("skos:broader", uri: categoryURI(parentId))
            }
            if let currency = c.currency {
                w.addProperty("schema:currency", literal: currency)
            }
            w.addProperty("pfo:hidden", boolean: c.hidden)
            w.endSubject()
        }
    }

    // MARK: - Tags

    private func writeTags(_ w: TurtleWriter, _ tags: [TagDTO]) {
        guard !tags.isEmpty else { return }
        w.addComment("Tags")
        for t in tags {
            w.startSubject(tagURI(t.id), types: ["schema:DefinedTerm"])
            w.addProperty("schema:name", literal: t.name)
            w.endSubject()
        }
    }

    // MARK: - Transactions

    private func writeTransactions(_ w: TurtleWriter, _ transactions: [TransactionDTO]) {
        guard !transactions.isEmpty else { return }
        w.addComment("Transactions")
        for tx in transactions {
            w.startSubject(transactionURI(tx.id), types: ["pfo:Transaction"])
            w.addProperty("schema:name", literal: tx.title)
            w.addProperty("schema:dateCreated", date: tx.date)
            if let note = tx.note, !note.isEmpty {
                w.addProperty("schema:description", literal: note)
            }
            w.addProperty("pfo:cleared", boolean: tx.cleared)
            w.addProperty("pfo:voided", boolean: tx.voided)
            if let txType = tx.transactionType {
                w.addProperty("pfo:transactionType", literal: txType)
            }
            let lineItemURIs = tx.lineItems.map { lineItemURI($0.id) }
            w.addPropertyList("pfo:lineItem", uris: lineItemURIs)
            w.endSubject()

            for li in tx.lineItems {
                writeLineItem(w, li, transactionId: tx.id)
            }
        }
    }

    private func writeLineItem(_ w: TurtleWriter, _ li: LineItemDTO, transactionId: Int) {
        w.startSubject(lineItemURI(li.id), types: ["pfo:LineItem"])
        w.addProperty("pfo:transaction", uri: transactionURI(transactionId))
        w.addProperty("pfo:account", uri: accountURI(li.accountId))
        w.addProperty("schema:amount", decimal: li.amount)
        if let memo = li.memo, !memo.isEmpty {
            w.addProperty("schema:description", literal: memo)
        }
        w.addProperty("pfo:cleared", boolean: li.cleared)
        if let statementId = li.statementId {
            w.addProperty("pfo:statement", uri: statementURI(statementId))
        }
        if let tags = li.tags {
            w.addPropertyList("pfo:tag", uris: tags.map { tagURI($0.id) })
        }
        w.endSubject()
    }

    // MARK: - Statements

    private func writeStatements(_ w: TurtleWriter, _ statements: [ExportStatementDTO]) {
        guard !statements.isEmpty else { return }
        w.addComment("Statements")
        for s in statements {
            w.startSubject(statementURI(s.id), types: ["pfo:BankStatement"])
            w.addProperty("pfo:account", uri: accountURI(s.accountId))
            if let name = s.name, !name.isEmpty {
                w.addProperty("schema:name", literal: name)
            }
            w.addProperty("schema:startDate", date: s.startDate)
            w.addProperty("schema:endDate", date: s.endDate)
            w.addProperty("pfo:beginningBalance", decimal: s.beginningBalance)
            w.addProperty("pfo:endingBalance", decimal: s.endingBalance)
            w.addProperty("pfo:reconciledLineItemCount", integer: s.reconciledLineItemCount)
            w.addProperty("pfo:isBalanced", boolean: s.isBalanced)
            w.endSubject()
        }
    }

    // MARK: - Templates

    private func writeTemplates(_ w: TurtleWriter, _ templates: [TransactionTemplateDTO]) {
        guard !templates.isEmpty else { return }
        w.addComment("Transaction Templates")
        for t in templates {
            w.startSubject(templateURI(t.id), types: ["pfo:TransactionTemplate"])
            w.addProperty("schema:name", literal: t.title)
            w.addProperty("schema:amount", decimal: t.amount)
            if let currency = t.currencyId {
                w.addProperty("schema:currency", literal: currency)
            }
            if let note = t.note, !note.isEmpty {
                w.addProperty("schema:description", literal: note)
            }
            w.addProperty("pfo:active", boolean: t.active)
            w.addProperty("pfo:fixedAmount", boolean: t.fixedAmount)
            if let lastApplied = t.lastAppliedDate {
                w.addProperty("pfo:lastAppliedDate", date: lastApplied)
            }
            for li in t.lineItems {
                writeLineItemTemplate(w, li, templateId: t.id)
            }
            w.endSubject()
        }
    }

    private func writeLineItemTemplate(_ w: TurtleWriter, _ li: LineItemTemplateDTO, templateId: Int) {
        let uri = "<\(Self.base)lineitemtemplate:\(templateId)-\(li.id)>"
        w.startSubject(uri, types: ["pfo:LineItemTemplate"])
        w.addProperty("pfo:template", uri: templateURI(templateId))
        w.addProperty("pfo:accountRef", literal: li.accountId)
        if let name = li.accountName {
            w.addProperty("pfo:accountName", literal: name)
        }
        w.addProperty("schema:amount", decimal: li.amount)
        if let memo = li.memo, !memo.isEmpty {
            w.addProperty("schema:description", literal: memo)
        }
        w.addProperty("pfo:fixedAmount", boolean: li.fixedAmount)
        w.endSubject()
    }

    // MARK: - Import Rules

    private func writeImportRules(_ w: TurtleWriter, _ rules: [ImportRuleDTO]) {
        guard !rules.isEmpty else { return }
        w.addComment("Import Rules")
        for r in rules {
            w.startSubject(importRuleURI(r.id), types: ["pfo:ImportRule"])
            w.addProperty("pfo:template", uri: templateURI(r.templateId))
            w.addProperty("pfo:pattern", literal: r.pattern)
            if let accountId = r.accountId {
                w.addProperty("pfo:accountRef", literal: accountId)
            }
            if let payee = r.payee {
                w.addProperty("pfo:payee", literal: payee)
            }
            w.endSubject()
        }
    }

    // MARK: - Scheduled Transactions

    private func writeScheduled(_ w: TurtleWriter, _ scheduled: [ScheduledTransactionDTO]) {
        guard !scheduled.isEmpty else { return }
        w.addComment("Scheduled Transactions")
        for s in scheduled {
            w.startSubject(scheduleURI(s.id), types: ["pfo:ScheduledTransaction"])
            w.addProperty("pfo:template", uri: templateURI(s.templateId))
            w.addProperty("schema:amount", decimal: s.amount)
            if let start = s.startDate {
                w.addProperty("schema:startDate", date: start)
            }
            if let next = s.nextDate {
                w.addProperty("pfo:nextDate", date: next)
            }
            if let interval = s.repeatInterval {
                w.addProperty("pfo:repeatInterval", integer: interval)
            }
            if let multiplier = s.repeatMultiplier {
                w.addProperty("pfo:repeatMultiplier", integer: multiplier)
            }
            if let accountId = s.accountId {
                w.addProperty("pfo:accountRef", literal: accountId)
            }
            if let reminder = s.reminderDays {
                w.addProperty("pfo:reminderDays", integer: reminder)
            }
            w.endSubject()
        }
    }

    // MARK: - Securities

    private func writeSecurities(_ w: TurtleWriter, _ securities: [SecurityDTO]) {
        guard !securities.isEmpty else { return }
        w.addComment("Securities")
        for s in securities {
            w.startSubject(securityURI(s.id), types: ["schema:FinancialProduct"])
            w.addProperty("schema:name", literal: s.name)
            w.addProperty("schema:tickerSymbol", literal: s.symbol)
            if let currency = s.currency {
                w.addProperty("schema:currency", literal: currency)
            }
            w.addProperty("pfo:securityType", integer: s.securityType)
            w.endSubject()
        }
    }

    // MARK: - Holdings

    private func writeHoldings(_ w: TurtleWriter, _ holdings: [SecurityHoldingDTO]) {
        guard !holdings.isEmpty else { return }
        w.addComment("Holdings")
        for h in holdings {
            w.startSubject(holdingURI(h.accountId, h.securityId), types: ["pfo:Holding"])
            w.addProperty("pfo:account", uri: accountURI(h.accountId))
            w.addProperty("pfo:security", uri: securityURI(h.securityId))
            w.addProperty("schema:tickerSymbol", literal: h.symbol)
            w.addProperty("pfo:shares", decimal: h.shares)
            w.addProperty("pfo:costBasis", decimal: h.costBasis)
            if let mv = h.marketValue {
                w.addProperty("pfo:marketValue", decimal: mv)
            }
            if let price = h.lastPrice {
                w.addProperty("pfo:lastPrice", decimal: price)
            }
            if let priceDate = h.lastPriceDate {
                w.addProperty("pfo:lastPriceDate", date: priceDate)
            }
            if let currency = h.currency {
                w.addProperty("schema:currency", literal: currency)
            }
            w.endSubject()
        }
    }

    // MARK: - Trades

    private func writeTrades(_ w: TurtleWriter, _ trades: [SecurityTradeDTO]) {
        guard !trades.isEmpty else { return }
        w.addComment("Trades")
        for t in trades {
            w.startSubject(tradeURI(t.id), types: ["schema:TradeAction"])
            w.addProperty("schema:startTime", date: t.date)
            w.addProperty("pfo:tradeType", literal: t.type)
            w.addProperty("schema:tickerSymbol", literal: t.symbol)
            w.addProperty("pfo:shares", decimal: t.shares)
            w.addProperty("schema:price", decimal: t.pricePerShare)
            w.addProperty("schema:amount", decimal: t.amount)
            if t.commission != 0 {
                w.addProperty("pfo:commission", decimal: t.commission)
            }
            w.addProperty("pfo:account", uri: accountURI(t.accountId))
            w.endSubject()
        }
    }

    // MARK: - Security Income

    private func writeSecurityIncome(_ w: TurtleWriter, _ income: [SecurityIncomeDTO]) {
        guard !income.isEmpty else { return }
        w.addComment("Security Income")
        for i in income {
            w.startSubject(securityIncomeURI(i.id), types: ["pfo:SecurityIncome"])
            w.addProperty("schema:dateCreated", date: i.date)
            w.addProperty("pfo:incomeType", literal: i.type)
            w.addProperty("schema:tickerSymbol", literal: i.symbol)
            w.addProperty("schema:amount", decimal: i.amount)
            w.addProperty("pfo:account", uri: accountURI(i.accountId))
            w.endSubject()
        }
    }

    // MARK: - Security Prices

    private func writeSecurityPrices(_ w: TurtleWriter, _ prices: [String: [SecurityPriceDTO]]) {
        let allPrices = prices.values.flatMap { $0 }
        guard !allPrices.isEmpty else { return }
        w.addComment("Security Prices")
        for (symbol, symbolPrices) in prices.sorted(by: { $0.key < $1.key }) {
            for p in symbolPrices {
                w.startSubject(priceURI(p.id), types: ["pfo:SecurityPrice"])
                w.addProperty("schema:tickerSymbol", literal: symbol)
                w.addProperty("schema:dateCreated", date: p.date)
                w.addProperty("pfo:closePrice", decimal: p.closePrice)
                if p.openPrice != 0 {
                    w.addProperty("pfo:openPrice", decimal: p.openPrice)
                }
                if p.highPrice != 0 {
                    w.addProperty("pfo:highPrice", decimal: p.highPrice)
                }
                if p.lowPrice != 0 {
                    w.addProperty("pfo:lowPrice", decimal: p.lowPrice)
                }
                if p.adjustedClosePrice != 0 && p.adjustedClosePrice != p.closePrice {
                    w.addProperty("pfo:adjustedClosePrice", decimal: p.adjustedClosePrice)
                }
                if p.volume != 0 {
                    w.addProperty("pfo:volume", decimal: p.volume)
                }
                w.endSubject()
            }
        }
    }

    // MARK: - URI Helpers

    private func accountURI(_ id: Int) -> String { "<\(Self.base)account:\(id)>" }
    private func categoryURI(_ id: Int) -> String { "<\(Self.base)category:\(id)>" }
    private func tagURI(_ id: Int) -> String { "<\(Self.base)tag:\(id)>" }
    private func transactionURI(_ id: Int) -> String { "<\(Self.base)transaction:\(id)>" }
    private func lineItemURI(_ id: Int) -> String { "<\(Self.base)lineitem:\(id)>" }
    private func statementURI(_ id: Int) -> String { "<\(Self.base)statement:\(id)>" }
    private func templateURI(_ id: Int) -> String { "<\(Self.base)template:\(id)>" }
    private func importRuleURI(_ id: Int) -> String { "<\(Self.base)importrule:\(id)>" }
    private func scheduleURI(_ id: Int) -> String { "<\(Self.base)schedule:\(id)>" }
    private func securityURI(_ id: Int) -> String { "<\(Self.base)security:\(id)>" }
    private func holdingURI(_ accountId: Int, _ securityId: Int) -> String { "<\(Self.base)holding:\(accountId)-\(securityId)>" }
    private func tradeURI(_ id: Int) -> String { "<\(Self.base)trade:\(id)>" }
    private func securityIncomeURI(_ id: Int) -> String { "<\(Self.base)security-income:\(id)>" }
    private func priceURI(_ id: Int) -> String { "<\(Self.base)price:\(id)>" }
}
